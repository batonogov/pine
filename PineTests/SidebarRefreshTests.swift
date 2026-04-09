//
//  SidebarRefreshTests.swift
//  PineTests
//
//  Tests for issue #439: new files not appearing in sidebar until manual interaction.
//  Verifies that FileSystemWatcher triggers tree refresh and new FileNodes appear.
//

import Foundation
import Testing

@testable import Pine

@Suite("Sidebar Refresh Tests — Issue #439")
struct SidebarRefreshTests {

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - FileSystemWatcher callback fires for new file

    @Test("FileSystemWatcher fires callback when a new file is created")
    @MainActor
    func watcherFiresCallbackOnNewFile() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        var callbackFired = false
        let watcher = FileSystemWatcher(debounceInterval: 0.15) {
            callbackFired = true
        }
        watcher.watch(directory: dir)

        // Create a new file — watcher should detect it
        try "hello".write(
            to: dir.appendingPathComponent("new_file.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Wait for FSEvents + debounce to deliver callback
        // FSEvents can take 20-30s on CI runners, so poll generously
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            if callbackFired { break }
        }

        watcher.stop()

        #expect(callbackFired == true, "Watcher callback should fire when a new file is created")
    }

    // MARK: - WorkspaceManager updates tree via watcher callback

    @Test("WorkspaceManager refreshes file tree when watcher detects new file")
    @MainActor
    func workspaceManagerRefreshesOnWatcherEvent() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        // Create initial file
        try "initial".write(
            to: dir.appendingPathComponent("existing.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for initial async load to complete
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            if !manager.rootNodes.isEmpty { break }
        }

        #expect(manager.rootNodes.contains { $0.name == "existing.txt" })

        // Create a new file externally — watcher should trigger tree refresh
        try "new content".write(
            to: dir.appendingPathComponent("brand_new.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Wait for watcher + async reload to pick up the new file
        // FSEvents can take 20-30s on CI runners, so poll generously
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            if manager.rootNodes.contains(where: { $0.name == "brand_new.txt" }) { break }
        }

        #expect(
            manager.rootNodes.contains { $0.name == "brand_new.txt" },
            "New file should appear in rootNodes after watcher-triggered refresh"
        )
    }

    // MARK: - New FileNode appears in tree after external file creation

    @Test("New FileNode appears in tree after file is created on disk")
    @MainActor
    func newFileNodeAppearsAfterCreation() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for initial load
        try await Task.sleep(for: .milliseconds(300))

        // Initially empty
        #expect(manager.rootNodes.isEmpty)

        // Create multiple files
        try "file a".write(
            to: dir.appendingPathComponent("alpha.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "file b".write(
            to: dir.appendingPathComponent("beta.swift"),
            atomically: true,
            encoding: .utf8
        )

        // Trigger refresh directly instead of relying on FSEvents.
        // FSEvents latency is unreliable on CI runners (observed 20-30s),
        // so this test exercises WorkspaceManager.refreshFileTree() directly.
        // The watcher → refresh wiring is covered separately by
        // workspaceManagerRefreshesOnWatcherEvent and externalChangeTokenIncrements.
        manager.refreshFileTree()

        let names = manager.rootNodes.map(\.name)
        #expect(names.contains("alpha.swift"), "alpha.swift should appear in tree")
        #expect(names.contains("beta.swift"), "beta.swift should appear in tree")
    }

    // MARK: - New directory appears in sidebar

    @Test("New directory appears in sidebar after creation")
    @MainActor
    func newDirectoryAppearsAfterCreation() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        try await Task.sleep(for: .milliseconds(300))
        #expect(manager.rootNodes.isEmpty)

        // Create a directory with a file inside
        let subdir = dir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "code".write(
            to: subdir.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )

        // Trigger refresh directly instead of relying on FSEvents.
        // FSEvents latency is unreliable on CI runners (observed 20-30s),
        // so this test exercises WorkspaceManager.refreshFileTree() directly.
        // The watcher → refresh wiring is covered separately by
        // workspaceManagerRefreshesOnWatcherEvent and externalChangeTokenIncrements.
        manager.refreshFileTree()

        let sourcesNode = manager.rootNodes.first { $0.name == "Sources" }
        #expect(sourcesNode != nil, "Sources directory should appear in tree")
        #expect(sourcesNode?.isDirectory == true)
    }

    // MARK: - Deleted file disappears from sidebar

    @Test("Deleted file disappears from sidebar after watcher refresh")
    @MainActor
    func deletedFileDisappearsFromSidebar() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let fileURL = dir.appendingPathComponent("to_delete.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for initial load
        // FSEvents can take 20-30s on CI runners, so poll generously
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            if manager.rootNodes.contains(where: { $0.name == "to_delete.txt" }) { break }
        }

        #expect(manager.rootNodes.contains { $0.name == "to_delete.txt" })

        // Delete the file
        try FileManager.default.removeItem(at: fileURL)

        // Wait for watcher to detect deletion
        // FSEvents can take 20-30s on CI runners, so poll generously
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            if !manager.rootNodes.contains(where: { $0.name == "to_delete.txt" }) { break }
        }

        #expect(
            !manager.rootNodes.contains { $0.name == "to_delete.txt" },
            "Deleted file should disappear from tree"
        )
    }

    // MARK: - ExternalChangeToken increments on watcher event

    @Test("externalChangeToken increments when watcher detects changes")
    @MainActor
    func externalChangeTokenIncrements() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for initial load + watcher start
        try await Task.sleep(for: .milliseconds(500))

        let initialToken = manager.externalChangeToken

        // Create a file to trigger watcher
        try "trigger".write(
            to: dir.appendingPathComponent("trigger.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Wait for watcher callback
        // FSEvents can take 20-30s on CI runners, so poll generously
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            if manager.externalChangeToken > initialToken { break }
        }

        #expect(
            manager.externalChangeToken > initialToken,
            "externalChangeToken should increment after file creation"
        )
    }

    // Note: a previous "no double debounce" timing test (added in #493,
    // disabled in #566) was removed in #758. It asserted that the watcher
    // callback fired within 0.6 s of a file write, but FSEvents latency on
    // CI runners ranges from <0.5 s to 30 s+ — the assertion is
    // fundamentally incompatible with the environment it ran in. The
    // `externalChangeToken` test above already covers the "watcher fires
    // after file creation" invariant with a generous poll timeout. If we
    // ever need to guard against a double-debounce regression, it should
    // be a direct unit test of the debouncer, not an end-to-end FSEvents
    // test.
}
