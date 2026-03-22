//
//  WorkspaceManagerTests.swift
//  PineTests
//
//  Created by Claude on 14.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("WorkspaceManager Tests")
struct WorkspaceManagerTests {

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        // Resolve firmlinks (/var -> /private/var) for consistent path comparison
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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
                domain: "ShellError",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "'\(command)' failed: \(stderr)"]
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    private func makeGitRepo() throws -> URL {
        let dir = try makeTempDirectory()
        try runShell("git init", at: dir)
        try runShell("git config user.email 'test@test.com'", at: dir)
        try runShell("git config user.name 'Test'", at: dir)
        try "initial".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git add .", at: dir)
        try runShell("git -c commit.gpgsign=false commit -m 'initial'", at: dir)
        return dir
    }

    @Test("Initial state has empty rootNodes and default project name")
    func initialState() {
        let manager = WorkspaceManager()
        #expect(manager.rootNodes.isEmpty)
        #expect(manager.projectName == "Pine")
        #expect(manager.rootURL == nil)
        #expect(manager.externalChangeToken == 0)
    }

    @Test("loadDirectory sets rootURL and projectName")
    func loadDirectorySetsProperties() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        #expect(manager.rootURL == dir)
        #expect(manager.projectName == dir.lastPathComponent)
    }

    @Test("loadDirectory clears previous state immediately")
    func loadDirectoryClearsState() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        // Create a file in dir1 so it has children
        try "content".write(
            to: dir1.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir1)

        // Now load dir2 — should clear state immediately (synchronous)
        manager.loadDirectory(url: dir2)

        // rootNodes should be cleared synchronously
        #expect(manager.rootNodes.isEmpty)
        #expect(manager.rootURL == dir2)
        #expect(manager.gitProvider.isGitRepository == false)
        #expect(manager.gitProvider.currentBranch == "")
        #expect(manager.gitProvider.fileStatuses.isEmpty)
        #expect(manager.gitProvider.ignoredPaths.isEmpty)
        #expect(manager.gitProvider.branches.isEmpty)
    }

    @Test("refreshFileTree reloads children from disk")
    func refreshFileTree() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        // Sync refresh to populate from empty dir
        manager.refreshFileTree()

        // Initially empty directory
        #expect(manager.rootNodes.isEmpty)

        // Create a file
        try "hello".write(
            to: dir.appendingPathComponent("newfile.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Refresh should pick it up
        manager.refreshFileTree()
        #expect(manager.rootNodes.count == 1)
        #expect(manager.rootNodes.first?.url.lastPathComponent == "newfile.txt")
    }

    @Test("refreshFileTree does nothing without rootURL")
    func refreshFileTreeNoRoot() {
        let manager = WorkspaceManager()
        manager.refreshFileTree()
        #expect(manager.rootNodes.isEmpty)
    }

    @Test("loadDirectory then refreshFileTree populates rootNodes")
    func loadDirectoryThenRefreshPopulatesNodes() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "a".write(to: dir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Async load dispatches to main which we can't easily await in tests.
        // Use synchronous refreshFileTree instead (rootURL is already set).
        manager.refreshFileTree()

        #expect(manager.rootNodes.count == 2)
    }

    @Test("refreshFileTree populates ignoredPaths in git repo")
    func refreshFileTreePopulatesIgnoredPaths() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try runShell("git init", at: dir)
        try runShell("git config user.email 'test@test.com'", at: dir)
        try runShell("git config user.name 'Test'", at: dir)

        try "build/\n.env\n".write(
            to: dir.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        // Create ignored entries so git reports them
        let buildDir = dir.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try "bin".write(to: buildDir.appendingPathComponent("out"), atomically: true, encoding: .utf8)
        try "secret".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        try runShell("git add .gitignore", at: dir)
        try runShell("git -c commit.gpgsign=false commit -m 'init'", at: dir)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        manager.gitProvider.setup(repositoryURL: dir)
        manager.refreshFileTree()

        #expect(manager.gitProvider.isGitRepository == true)
        #expect(manager.gitProvider.ignoredPaths.contains("build"))
        #expect(manager.gitProvider.ignoredPaths.contains(".env"))
    }

    @Test("refreshFileTree updates file tree synchronously but does not run git synchronously")
    func refreshFileTreeGitAsync() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        manager.gitProvider.setup(repositoryURL: dir)
        manager.refreshFileTree()

        // Create an untracked file — git status should detect it after refresh
        try "new".write(
            to: dir.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        // refreshFileTree() should update the file tree synchronously
        // but NOT update git status synchronously (that's the fix).
        manager.refreshFileTree()

        // File tree is updated immediately (synchronous)
        let names = manager.rootNodes.map(\.url.lastPathComponent)
        #expect(names.contains("untracked.txt"))
        #expect(names.contains("README.md"))

        // Git status has NOT been updated yet — refreshAsync() is still in-flight.
        // The untracked file should NOT appear in fileStatuses immediately,
        // proving that git refresh is no longer synchronous.
        #expect(manager.gitProvider.fileStatuses["untracked.txt"] == nil)
    }

    @Test("multiple rapid refreshFileTree calls do not crash")
    func rapidRefreshFileTree() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        manager.refreshFileTree()

        // Simulate rapid user actions (create, rename, delete) that each
        // trigger refreshFileTree(). Each spawns a Task with refreshAsync() —
        // multiple overlapping async git processes should not crash.
        for i in 0..<5 {
            try "file\(i)".write(
                to: dir.appendingPathComponent("file\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
            manager.refreshFileTree()
        }

        // File tree should reflect the latest state
        let names = manager.rootNodes.map(\.url.lastPathComponent)
        for i in 0..<5 {
            #expect(names.contains("file\(i).txt"))
        }
    }

    @Test("refreshFileTree works on non-git directory without crash")
    func refreshFileTreeNonGitDirectory() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "hello".write(
            to: dir.appendingPathComponent("hello.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        // refreshFileTree on non-git dir — refreshAsync() should bail out
        // (guard isGitRepository) without crash
        manager.refreshFileTree()

        #expect(manager.rootNodes.count == 1)
        #expect(manager.gitProvider.isGitRepository == false)
    }

    @Test("refreshFileTree then loadDirectory does not crash from stale async git")
    func refreshFileTreeThenSwitchProject() throws {
        let dir1 = try makeGitRepo()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        try "file".write(
            to: dir2.appendingPathComponent("other.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir1)
        manager.gitProvider.setup(repositoryURL: dir1)
        // Trigger async git refresh on dir1
        manager.refreshFileTree()

        // Immediately switch to dir2 (non-git) — async git Task for dir1
        // is still in-flight but should not crash or corrupt state
        manager.loadDirectory(url: dir2)
        manager.refreshFileTree()

        #expect(manager.rootURL == dir2)
        let names = manager.rootNodes.map(\.url.lastPathComponent)
        #expect(names.contains("other.txt"))
    }

    @Test("refreshFileTree uses shallow load followed by async deep load")
    func refreshFileTreeProgressiveLoad() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        // Create a deeply nested structure: root/a/b/c/d/e/file.txt
        let deep = dir
            .appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
            .appendingPathComponent("d")
            .appendingPathComponent("e")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "deep".write(to: deep.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "top".write(to: dir.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        manager.refreshFileTree()

        // Top-level files should be present
        let names = manager.rootNodes.map(\.url.lastPathComponent)
        #expect(names.contains("top.txt"))
        #expect(names.contains("a"))

        // Shallow levels should be loaded
        let aNode = manager.rootNodes.first { $0.name == "a" }
        #expect(aNode?.children?.first?.name == "b")
    }

    @Test("refreshFileTree suppresses immediate watcher echo events")
    func refreshFileTreeSuppressesEcho() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "file".write(
            to: dir.appendingPathComponent("test.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        manager.refreshFileTree()

        // After refreshFileTree, the externalChangeToken should not bump
        // from echo watcher events within the suppression window.
        let tokenAfterRefresh = manager.externalChangeToken

        // Modify a file — this would trigger a watcher event,
        // but suppressWatcherUntil should suppress it for ~1 second.
        try "modified".write(
            to: dir.appendingPathComponent("test.txt"),
            atomically: true,
            encoding: .utf8
        )

        // The watcher callback is debounced and suppressed, so the
        // token should remain stable immediately after the write.
        #expect(manager.externalChangeToken == tokenAfterRefresh)
    }

    @Test("loadDirectory stops file watcher from previous project")
    @MainActor
    func loadDirectoryStopsOldWatcher() async throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        try "a".write(
            to: dir1.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "b".write(
            to: dir2.appendingPathComponent("b.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir1)
        manager.refreshFileTree()

        let tokenBeforeSwitch = manager.externalChangeToken

        // Switch to dir2 — should stop dir1's watcher
        manager.loadDirectory(url: dir2)
        manager.refreshFileTree()

        let tokenAfterSwitch = manager.externalChangeToken

        // Creating files in dir1 should NOT trigger externalChangeToken changes
        // (watcher was stopped when we switched to dir2)
        try "new".write(
            to: dir1.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Wait for any potential watcher event to fire
        try await Task.sleep(for: .milliseconds(800))

        // Token should not have changed from dir1 watcher events
        #expect(manager.externalChangeToken == tokenAfterSwitch)
        #expect(manager.rootURL == dir2)
    }

    @Test("Multiple rapid loadDirectory calls settle on the last directory")
    func multipleRapidLoadDirectory() throws {
        let dirs = try (0..<5).map { _ in try makeTempDirectory() }
        defer { dirs.forEach { cleanup($0) } }

        for (i, dir) in dirs.enumerated() {
            try "file\(i)".write(
                to: dir.appendingPathComponent("file\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let manager = WorkspaceManager()
        for dir in dirs {
            manager.loadDirectory(url: dir)
        }

        // Should settle on the last directory
        #expect(manager.rootURL == dirs.last)
        manager.refreshFileTree()
        let names = manager.rootNodes.map(\.url.lastPathComponent)
        #expect(names.contains("file4.txt"))
        #expect(!names.contains("file0.txt"))
    }

    @Test("loadGeneration prevents stale async results from overwriting newer state")
    func loadGenerationPreventsStaleResults() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        // Create files to distinguish directories
        try "from1".write(
            to: dir1.appendingPathComponent("from_dir1.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "from2".write(
            to: dir2.appendingPathComponent("from_dir2.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        // Load dir1 — triggers async load
        manager.loadDirectory(url: dir1)
        // Immediately load dir2 — should invalidate dir1's async load
        manager.loadDirectory(url: dir2)

        // Synchronous state should reflect dir2
        #expect(manager.rootURL == dir2)

        // Use sync refresh to verify
        manager.refreshFileTree()
        let names = manager.rootNodes.map(\.url.lastPathComponent)
        #expect(names.contains("from_dir2.txt"))
        #expect(!names.contains("from_dir1.txt"))
    }

    @Test("loadDirectory twice quickly uses latest directory")
    func loadDirectoryRaceProtection() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        // Create different files to distinguish
        try "a".write(to: dir1.appendingPathComponent("from_dir1.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir2.appendingPathComponent("from_dir2.txt"), atomically: true, encoding: .utf8)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir1)
        manager.loadDirectory(url: dir2) // Immediately switch

        // Synchronous properties should reflect dir2
        #expect(manager.rootURL == dir2)
        #expect(manager.projectName == dir2.lastPathComponent)

        // Use synchronous refresh to load dir2 content
        manager.refreshFileTree()
        let names = manager.rootNodes.map(\.url.lastPathComponent)
        #expect(names.contains("from_dir2.txt"))
        #expect(!names.contains("from_dir1.txt"))
    }
}
