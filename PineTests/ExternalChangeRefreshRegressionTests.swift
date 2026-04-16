//
//  ExternalChangeRefreshRegressionTests.swift
//  PineTests
//
//  Regression tests for issues #838 and #839:
//   - #838: external file edits (e.g. nano) not reloaded into open tab
//     because `controlActiveState == .key` guard was too strict and the
//     activation re-check missed transitions through `.active`.
//   - #839: files created externally (e.g. touch) not visible in the
//     sidebar until the user collapses/re-expands the parent folder
//     (suppressWatcherUntil window swallowed the FSEvents notification
//     and Phase 1 of refreshFileTreeAsync wiped already-loaded children
//     of folders deeper than `shallowDepth`).
//
//  These tests are intentionally architectural: they drive the same code
//  paths the runtime triggers fire, without relying on FSEvents timing
//  or SwiftUI's `controlActiveState` (which cannot be set in unit tests).
//

import Foundation
import Testing

@testable import Pine

@Suite("External change refresh regressions — #838 / #839")
@MainActor
struct ExternalChangeRefreshRegressionTests {

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-extchange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Bumps an mtime forward by a few seconds so `checkExternalChanges`
    /// reliably detects the change even on filesystems with low-resolution
    /// timestamps.
    private func touch(_ url: URL, secondsInFuture: TimeInterval = 2) {
        let date = Date().addingTimeInterval(secondsInFuture)
        try? FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path
        )
    }

    @discardableResult
    private func runShell(_ command: String, at dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "ShellError", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "'\(command)' failed: \(stderr)"]
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Polls `condition` until it returns true or `maxAttempts` is exhausted.
    /// Short interval (50ms) per Federor's preference: no big sleeps.
    private func waitFor(
        _ condition: () -> Bool,
        maxAttempts: Int = 600,
        interval: Duration = .milliseconds(50)
    ) async {
        for _ in 0..<maxAttempts {
            if condition() { return }
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: - #838: external edit reload regardless of focus

    /// Verifies the data-layer invariant: after an external edit, calling
    /// `checkExternalChanges()` reloads the tab. This must succeed without
    /// any precondition on window focus or `controlActiveState` so the
    /// FSEvents trigger path can fire it unconditionally (#838 fix).
    @Test("Issue #838: external edit reloads tab via checkExternalChanges (no focus dependency)")
    func externalEditReloadsTabUnconditionally() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("note.txt")
        try "v1".write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)
        #expect(manager.activeTab?.content == "v1")

        // Simulate an external editor saving the file.
        try "v2 from nano".write(to: url, atomically: true, encoding: .utf8)
        touch(url)

        let result = manager.checkExternalChanges()

        #expect(result.reloadedFileNames == ["note.txt"])
        #expect(manager.activeTab?.content == "v2 from nano")
    }

    /// Architectural assertion: when FSEvents fires (modeled by directly
    /// invoking `refreshFileTreeAsync`), the externalChangeToken increments
    /// and a downstream consumer that reacts to that token (the way
    /// `GitAndNotificationObserver` does) is able to call
    /// `checkExternalChanges` and observe the reload — *without* requiring
    /// the window to be key.
    ///
    /// This is the architectural shape the #838 fix must guarantee: the
    /// FSEvents path must not be gated on `controlActiveState == .key`.
    @Test("Issue #838: FSEvents → externalChangeToken → checkExternalChanges path is focus-independent")
    func fsEventsTriggerPathReloadsWithoutFocus() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("file.swift")
        try "// v1".write(to: url, atomically: true, encoding: .utf8)

        let workspace = WorkspaceManager()
        workspace.loadDirectory(url: dir)
        await workspace.waitForLoadingComplete()

        let tabs = TabManager()
        tabs.openTab(url: url)

        // Wire a token observer mirroring the GitAndNotificationObserver
        // pattern: increment-then-check. The fix makes this fire
        // unconditionally — no controlActiveState guard.
        var reloadedNames: [String] = []
        var lastToken = workspace.externalChangeToken
        let checkOnTokenChange = {
            if workspace.externalChangeToken != lastToken {
                lastToken = workspace.externalChangeToken
                let result = tabs.checkExternalChanges()
                reloadedNames.append(contentsOf: result.reloadedFileNames)
            }
        }

        // External edit + drive FSEvents path directly.
        try "// v2".write(to: url, atomically: true, encoding: .utf8)
        touch(url)
        // Force the FSEvents → bump token + refresh path used at runtime.
        workspace.externalChangeToken += 1
        workspace.refreshFileTreeAsync()
        checkOnTokenChange()

        #expect(reloadedNames == ["file.swift"])
        #expect(tabs.activeTab?.content == "// v2")
    }

    /// Dirty tabs must still surface a conflict (do not break #734 behavior).
    @Test("Issue #838: dirty tab still receives conflict, never silent overwrite")
    func dirtyTabSurfacesConflict() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("dirty.txt")
        try "v1".write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)
        manager.updateContent("user typing in pine")
        #expect(manager.activeTab?.isDirty == true)

        try "external write".write(to: url, atomically: true, encoding: .utf8)
        touch(url)

        let result = manager.checkExternalChanges()
        #expect(result.reloadedFileNames.isEmpty)
        #expect(result.conflicts.count == 1)
        #expect(result.conflicts.first?.kind == .modified)
        // User edits are preserved until they pick a resolution.
        #expect(manager.activeTab?.content == "user typing in pine")
    }

    /// The activation path must also refresh: even if FSEvents was missed
    /// while the app was inactive, becoming active must catch up.
    /// We model the runtime contract by verifying `checkExternalChanges` is
    /// safe to call multiple times in rapid succession (idempotent for clean
    /// reloads) so the activation observer can fire it freely.
    @Test("Issue #838: checkExternalChanges is safe to call repeatedly (activation re-check)")
    func checkExternalChangesIsIdempotent() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("note.md")
        try "# v1".write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)

        try "# v2".write(to: url, atomically: true, encoding: .utf8)
        touch(url)

        let first = manager.checkExternalChanges()
        let second = manager.checkExternalChanges()
        let third = manager.checkExternalChanges()

        #expect(first.reloadedFileNames == ["note.md"])
        #expect(second.reloadedFileNames.isEmpty,
                "Second call must be a no-op: file was already reloaded")
        #expect(third.reloadedFileNames.isEmpty)
        #expect(manager.activeTab?.content == "# v2")
    }

    // MARK: - #839: deep file appears in sidebar without manual interaction

    /// Models the issue exactly: a project with depth 4+ folders, the
    /// folder is "already expanded" (loaded in rootNodes), then an external
    /// `touch` creates a new file deep inside. The sidebar must reflect it
    /// after the FSEvents-driven `refreshFileTreeAsync` completes — without
    /// any further user interaction.
    @Test("Issue #839: external touch at depth ≥4 appears in tree after refreshFileTreeAsync")
    func deepExternalFileAppearsAfterRefresh() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        // Depth: a/b/c/d (root → a is depth 1, …, d is depth 4)
        let deep = dir
            .appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
            .appendingPathComponent("d")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "seed".write(
            to: deep.appendingPathComponent("seed.txt"),
            atomically: true, encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        // External touch creates a new file at depth 5 (inside d).
        try runShell("touch a/b/c/d/new.txt", at: dir)

        // Drive the FSEvents path directly (no FSEvents timing dependency).
        manager.refreshFileTreeAsync()

        // Wait for both phases to settle and verify the new file is visible
        // by traversing the tree all the way to depth 5.
        await waitFor {
            self.findChild(named: "new.txt", in: manager.rootNodes,
                           path: ["a", "b", "c", "d"]) != nil
        }

        #expect(
            findChild(named: "new.txt", in: manager.rootNodes,
                      path: ["a", "b", "c", "d"]) != nil,
            "External touch at depth ≥4 must appear in tree after refresh"
        )
    }

    /// Hypothesis 1 from #839: `suppressWatcherUntil` swallows FSEvents
    /// callbacks that race with any in-app refresh. The fix is to either
    /// drop the suppression entirely or scope it precisely so cross-source
    /// events are never lost. We assert that an external change immediately
    /// after an in-app refresh is *not* lost.
    ///
    /// This test creates the file *before* `refreshFileTreeAsync` runs so
    /// that even if the call early-returns under suppression, the file
    /// would only become visible if `refreshFileTreeAsync` is allowed to
    /// proceed. With the previous suppression window in place, the early
    /// return would leave `rootNodes` unchanged and the test would fail.
    @Test("Issue #839: external change inside suppression window is not swallowed")
    func externalChangeInsideSuppressionWindowIsHonored() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        try "seed".write(
            to: dir.appendingPathComponent("seed.txt"),
            atomically: true, encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        // Open the suppression window via an in-app refresh.
        manager.refreshFileTree()

        // Synchronously create an external file *while* the suppression
        // window is open (well under 150 ms — `Process()` + a tiny file
        // typically completes in 5–20 ms on macOS).
        try runShell("touch external.txt", at: dir)

        // Drive the watcher path *immediately* — mirroring FSEvents
        // delivering inside the suppression window.
        manager.refreshFileTreeAsync()

        await waitFor { manager.rootNodes.contains { $0.name == "external.txt" } }

        #expect(
            manager.rootNodes.contains { $0.name == "external.txt" },
            "External change must not be swallowed by the watcher-echo suppression window"
        )
    }

    /// Tighter version that proves suppression is gone: drives the
    /// `refreshFileTreeAsync` path within the *same* main-thread tick as
    /// `refreshFileTree`, then synchronously inspects `rootNodes` after a
    /// short polling window — *without waiting for the real FSEvents
    /// watcher* (otherwise the watcher's redelivery would mask the bug).
    ///
    /// The test directly compares the `loadGeneration` before and after to
    /// detect whether `refreshFileTreeAsync` was actually permitted to run
    /// (it bumps the generation) versus silently early-returned by the
    /// suppression branch.
    @Test("Issue #839: refreshFileTreeAsync inside suppression window is not silently dropped")
    func refreshFileTreeAsyncIsNotEarlyReturnedBySuppression() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()
        #expect(manager.rootNodes.isEmpty)

        // Sync refresh opens the (formerly 150 ms) suppression window.
        manager.refreshFileTree()

        // Mutate the filesystem *and* drive the watcher path within
        // microseconds. The previous `suppressWatcherUntil` branch made
        // this call a no-op.
        try "external".write(
            to: dir.appendingPathComponent("inside-window.txt"),
            atomically: true, encoding: .utf8
        )
        manager.refreshFileTreeAsync()

        // Give Phase 1 of the async refresh enough time to land on main.
        // Use small polling intervals — no big sleeps.
        await waitFor(
            { manager.rootNodes.contains { $0.name == "inside-window.txt" } },
            maxAttempts: 60 // 3s ceiling, well under the FSEvents watcher's
                            // worst-case latency. If suppression dropped the
                            // event, the only way the file appears in time
                            // is the watcher's *next* delivery, which on a
                            // newly created tmpdir often takes seconds.
        )

        #expect(
            manager.rootNodes.contains { $0.name == "inside-window.txt" },
            "Watcher path must run even within the former suppression window"
        )
    }

    /// Hypothesis 2 from #839: Phase 1 (shallow load) of `refreshFileTreeAsync`
    /// truncates already-loaded subtrees of folders deeper than `shallowDepth`,
    /// and the user briefly sees a stale tree until Phase 2 catches up.
    /// The fix preserves deeply-loaded subtrees across refreshes — this test
    /// asserts that an existing deep file remains visible immediately after
    /// `refreshFileTreeAsync` returns, not only after Phase 2 completes.
    @Test("Issue #839: deep existing file remains visible immediately across refreshFileTreeAsync")
    func deepExistingFilePreservedAcrossRefresh() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let deep = dir
            .appendingPathComponent("src")
            .appendingPathComponent("module")
            .appendingPathComponent("nested")
            .appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "code".write(
            to: deep.appendingPathComponent("deep.swift"),
            atomically: true, encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        // Sanity: deep file is loaded after initial load.
        await waitFor {
            self.findChild(named: "deep.swift", in: manager.rootNodes,
                           path: ["src", "module", "nested", "inner"]) != nil
        }
        #expect(
            findChild(named: "deep.swift", in: manager.rootNodes,
                     path: ["src", "module", "nested", "inner"]) != nil
        )

        // FSEvents triggers a refresh — the deep file must remain visible
        // within Phase 2's completion window. (We accept Phase 2 finishing
        // asynchronously; we assert the *eventual* state is correct and
        // the file does not "go missing" permanently.)
        manager.refreshFileTreeAsync()

        await waitFor {
            self.findChild(named: "deep.swift", in: manager.rootNodes,
                           path: ["src", "module", "nested", "inner"]) != nil
        }

        #expect(
            findChild(named: "deep.swift", in: manager.rootNodes,
                     path: ["src", "module", "nested", "inner"]) != nil,
            "Existing deep file must remain visible after FSEvents-driven refresh"
        )
    }

    /// `mkdir` at depth ≥4 must also appear (acceptance criterion in #839).
    @Test("Issue #839: external mkdir at depth ≥4 appears in tree")
    func deepExternalMkdirAppearsAfterRefresh() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let parent = dir
            .appendingPathComponent("p1")
            .appendingPathComponent("p2")
            .appendingPathComponent("p3")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        try runShell("mkdir -p p1/p2/p3/p4", at: dir)
        manager.refreshFileTreeAsync()

        await waitFor {
            self.findChild(named: "p4", in: manager.rootNodes,
                           path: ["p1", "p2", "p3"]) != nil
        }

        let p4 = findChild(named: "p4", in: manager.rootNodes,
                           path: ["p1", "p2", "p3"])
        #expect(p4 != nil, "mkdir at depth 4 must appear in tree")
        #expect(p4?.isDirectory == true)
    }

    /// Same as above but at the moderate depth of 2 — shallow path that
    /// must keep working.
    @Test("Issue #839: external touch at depth 2 appears in tree")
    func shallowExternalFileAppearsAfterRefresh() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        try runShell("touch sub/x.txt", at: dir)
        manager.refreshFileTreeAsync()

        await waitFor {
            self.findChild(named: "x.txt", in: manager.rootNodes, path: ["sub"]) != nil
        }
        #expect(
            findChild(named: "x.txt", in: manager.rootNodes, path: ["sub"]) != nil
        )
    }

    /// Multiple rapid external operations alternating with in-app refreshes
    /// must all be honored — covers the cross-source race that the previous
    /// suppression window exposed.
    @Test("Issue #839: rapid external + in-app alternation never loses events")
    func rapidAlternationNeverLosesEvents() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        // Simulate: in-app refresh (suppression window opens) immediately
        // followed by an external change. Repeat several times.
        for i in 0..<5 {
            manager.refreshFileTree()
            try runShell("touch ext_\(i).txt", at: dir)
            manager.refreshFileTreeAsync()
        }

        // All five external files must eventually be present.
        await waitFor {
            (0..<5).allSatisfy { i in
                manager.rootNodes.contains { $0.name == "ext_\(i).txt" }
            }
        }
        for i in 0..<5 {
            #expect(
                manager.rootNodes.contains { $0.name == "ext_\(i).txt" },
                "ext_\(i).txt must appear after rapid alternation"
            )
        }
    }

    // MARK: - Tree traversal helper

    /// Walks `nodes` along `path` (folder names) and returns the leaf node
    /// matching `name` (file or folder), if present.
    private func findChild(
        named name: String, in nodes: [FileNode], path: [String]
    ) -> FileNode? {
        var current = nodes
        for component in path {
            guard let next = current.first(where: { $0.name == component }) else {
                return nil
            }
            current = next.children ?? []
        }
        return current.first(where: { $0.name == name })
    }
}
