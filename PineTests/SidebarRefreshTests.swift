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
        // With fix: FSEvents latency (~0.15s) + no extra debounce = ~0.3s max
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
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
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
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
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
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

        // Wait for watcher + refresh
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if manager.rootNodes.count >= 2 { break }
        }

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

        // Wait for watcher + refresh
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if manager.rootNodes.contains(where: { $0.name == "Sources" }) { break }
        }

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
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if manager.rootNodes.contains(where: { $0.name == "to_delete.txt" }) { break }
        }

        #expect(manager.rootNodes.contains { $0.name == "to_delete.txt" })

        // Delete the file
        try FileManager.default.removeItem(at: fileURL)

        // Wait for watcher to detect deletion
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
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
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if manager.externalChangeToken > initialToken { break }
        }

        #expect(
            manager.externalChangeToken > initialToken,
            "externalChangeToken should increment after file creation"
        )
    }

    // MARK: - No double debounce in FileSystemWatcher

    @Test("FileSystemWatcher responds within reasonable time (no double debounce)")
    @MainActor
    func noDoubleDebounceTiming() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        var callbackTime: Date?
        let watcher = FileSystemWatcher(debounceInterval: 0.2) {
            if callbackTime == nil {
                callbackTime = Date()
            }
        }
        watcher.watch(directory: dir)

        // Small delay to let FSEvents stream fully start
        try await Task.sleep(for: .milliseconds(100))

        let createTime = Date()
        try "test".write(
            to: dir.appendingPathComponent("timing_test.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Wait for callback
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if callbackTime != nil { break }
        }

        watcher.stop()

        guard let received = callbackTime else {
            Issue.record("Callback never fired")
            return
        }

        let elapsed = received.timeIntervalSince(createTime)
        // With proper single debounce: should respond within ~0.5s
        // With double debounce bug: would take ~0.8s+
        #expect(elapsed < 0.6, "Callback should fire within 0.6s, got \(elapsed)s — double debounce suspected")
    }
}
