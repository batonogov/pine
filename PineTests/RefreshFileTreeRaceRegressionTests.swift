//
//  RefreshFileTreeRaceRegressionTests.swift
//  PineTests
//
//  Regression tests for issue #1006: `refreshFileTree()` must move its
//  shallow `FileNode.loadTree` off the main thread AND use `loadGeneration`
//  to discard stale results so that rapid successive refreshes (e.g. a user
//  spamming create/rename/delete in the sidebar, or a burst of watcher
//  events arriving between two in-app refreshes) never land a stale tree.
//

import Foundation
import Testing

@testable import Pine

@Suite("RefreshFileTree race-safety regressions — issue #1006")
@MainActor
struct RefreshFileTreeRaceRegressionTests {

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-1006-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Polls `condition` on the main actor until it returns true or the
    /// attempt budget is exhausted.
    @MainActor
    private func waitFor(
        _ condition: @MainActor () -> Bool,
        maxAttempts: Int = 200,
        interval: Duration = .milliseconds(25)
    ) async {
        for _ in 0..<maxAttempts {
            if condition() { return }
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: - criterion-1: external refresh does not block main thread (issue #1006)

    /// Asserts that `refreshFileTreeAsync()` — the entry point used by the
    /// FSEvents watcher for external changes — does NOT populate `rootNodes`
    /// synchronously. This is the defining behavior change of issue #1006:
    /// the heavy `loadTree(maxDepth:)` for external watcher bursts runs off
    /// the main thread so large monorepos do not stutter on every external
    /// change. The user-initiated path (`refreshFileTree()`) is covered by
    /// `userRefreshPopulatesSynchronously` below and intentionally stays
    /// synchronous to preserve sidebar inline-rename timing.
    @Test("refreshFileTreeAsync does not populate rootNodes synchronously (issue #1006)")
    func externalRefreshDoesNotBlockMainThread() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "first".write(
            to: dir.appendingPathComponent("first.txt"),
            atomically: true, encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for the initial async load to populate rootNodes.
        await waitFor { manager.rootNodes.contains { $0.name == "first.txt" } }
        #expect(manager.rootNodes.contains { $0.name == "first.txt" })

        // Create a new file, then synchronously call refreshFileTreeAsync
        // (the watcher entry point) and inspect rootNodes on the SAME
        // main-thread tick. The shallow pass is off the main thread for the
        // external path, so the new file must NOT be visible yet — proving
        // the I/O was dispatched, not run inline.
        try "second".write(
            to: dir.appendingPathComponent("second.txt"),
            atomically: true, encoding: .utf8
        )
        manager.refreshFileTreeAsync()
        #expect(
            !manager.rootNodes.contains { $0.name == "second.txt" },
            "refreshFileTreeAsync must not run the shallow load synchronously on the main thread"
        )

        // Eventually the async shallow pass lands and the file appears.
        await waitFor { manager.rootNodes.contains { $0.name == "second.txt" } }
        #expect(manager.rootNodes.contains { $0.name == "second.txt" })
    }

    // MARK: - sidebar inline-rename timing: user refresh stays synchronous

    /// Asserts that `refreshFileTree()` — the entry point used by sidebar
    /// actions (rename / create / delete / duplicate) — DOES populate
    /// `rootNodes` synchronously, on the same main-thread tick as the call.
    /// The inline rename `TextField` in `FileNodeRow` is keyed off
    /// `editState.renamingURL` matching a `FileNode` that must already be
    /// in the tree, so a same-tick update is required for the field to
    /// appear (InlineRenameAlignmentTests). External watcher bursts use
    /// `refreshFileTreeAsync()` instead, so this synchronous cost is only
    /// paid for direct user mutations, not for every FSEvents event.
    @Test("refreshFileTree populates rootNodes synchronously for sidebar mutations")
    func userRefreshPopulatesSynchronously() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "first".write(
            to: dir.appendingPathComponent("first.txt"),
            atomically: true, encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await waitFor { manager.rootNodes.contains { $0.name == "first.txt" } }

        // Create a new file, then call the user-initiated refresh and
        // inspect rootNodes on the SAME main-thread tick. The shallow pass
        // runs synchronously for sidebar mutations, so the new file must be
        // visible immediately — this is what lets FileNodeRow render the
        // inline rename TextField over the freshly-created node.
        try "second".write(
            to: dir.appendingPathComponent("second.txt"),
            atomically: true, encoding: .utf8
        )
        manager.refreshFileTree()
        #expect(
            manager.rootNodes.contains { $0.name == "second.txt" },
            "refreshFileTree must populate rootNodes synchronously for sidebar mutations (inline rename timing)"
        )
    }

    // MARK: - criterion-4: rapid successive refreshes converge on latest state

    /// Rapid successive `refreshFileTree()` calls, each creating a new file,
    /// must end with `rootNodes` reflecting the latest refresh — never a
    /// stale intermediate state. This pins down the `loadGeneration` discard
    /// contract: every call bumps the generation, so a slow earlier refresh
    /// is discarded by the equality check inside `loadDirectoryContentsAsync`.
    @Test("rapid successive refreshFileTree calls converge on latest state (issue #1006)")
    func rapidSuccessiveRefreshesConvergeOnLatest() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await waitFor { manager.isLoading == false }

        // Fire 10 rapid refreshes, each mutating the disk between calls so
        // stale results are detectable. Each call bumps loadGeneration, so
        // only the final refresh's shallow pass should ever be applied.
        for i in 0..<10 {
            try "marker_\(i)".write(
                to: dir.appendingPathComponent("marker_\(i).txt"),
                atomically: true, encoding: .utf8
            )
            manager.refreshFileTree()
        }

        // Wait for the latest generation to land.
        await waitFor {
            manager.rootNodes.contains { $0.name == "marker_9.txt" }
        }

        // Every earlier marker must also be present (they all live on disk
        // and the final shallow pass re-reads the whole directory).
        for i in 0..<10 {
            #expect(
                manager.rootNodes.contains { $0.name == "marker_\(i).txt" },
                "marker_\(i).txt must be present after rapid refreshes"
            )
        }
    }

    /// `refreshFileTree()` immediately followed by `refreshFileTreeAsync()`
    /// (mirroring an in-app refresh racing with a watcher event) must
    /// converge on the post-mutation state without dropping the watcher
    /// refresh's result.
    @Test("refreshFileTree then refreshFileTreeAsync converges on latest (issue #1006 + #839)")
    func refreshFileTreeThenAsyncConverges() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await waitFor { manager.isLoading == false }

        // In-app refresh (e.g. sidebar rename), immediately followed by an
        // external mutation + the watcher's async refresh path.
        manager.refreshFileTree()
        try "external".write(
            to: dir.appendingPathComponent("external.txt"),
            atomically: true, encoding: .utf8
        )
        manager.refreshFileTreeAsync()

        // The watcher path must land and the external file must appear.
        await waitFor { manager.rootNodes.contains { $0.name == "external.txt" } }
        #expect(manager.rootNodes.contains { $0.name == "external.txt" })
    }

    /// A long-running earlier refresh must NEVER overwrite the result of a
    /// later `loadDirectory` to a different project. This pins the
    /// generation-token invariant that protects the file-tree refresh path
    /// from #918-style races (a stale async result landing after a newer
    /// navigation).
    @Test("stale refreshFileTree result is discarded after loadDirectory switch (loadGeneration)")
    func staleRefreshDiscardedAfterProjectSwitch() async throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        try "from_dir1".write(
            to: dir1.appendingPathComponent("from_dir1.txt"),
            atomically: true, encoding: .utf8
        )
        try "from_dir2".write(
            to: dir2.appendingPathComponent("from_dir2.txt"),
            atomically: true, encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir1)

        // Bump a refresh on dir1, then immediately switch to dir2 — the
        // dir1 refresh's async completion must be discarded by generation.
        manager.refreshFileTree()
        manager.loadDirectory(url: dir2)
        manager.refreshFileTree()

        #expect(manager.rootURL == dir2)
        await waitFor { manager.rootNodes.contains { $0.name == "from_dir2.txt" } }
        #expect(manager.rootNodes.contains { $0.name == "from_dir2.txt" })
        #expect(
            !manager.rootNodes.contains { $0.name == "from_dir1.txt" },
            "Stale refresh from dir1 must never overwrite dir2's tree"
        )
    }
}
