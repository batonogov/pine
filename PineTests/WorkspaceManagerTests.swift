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
