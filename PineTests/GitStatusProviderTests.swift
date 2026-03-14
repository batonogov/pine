//
//  GitStatusProviderTests.swift
//  PineTests
//
//  Created by Claude on 14.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("GitStatusProvider Integration Tests")
struct GitStatusProviderTests {

    /// Creates a temporary git repository for testing.
    /// Returns the canonical (realpath) URL to match git's `--show-toplevel` output.
    private func makeGitRepo() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-git-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        // Resolve firmlinks (/var -> /private/var) so paths match git's output
        let dir = try resolveURL(rawDir)

        try runShell("git init", at: dir)
        try runShell("git config user.email 'test@test.com'", at: dir)
        try runShell("git config user.name 'Test'", at: dir)

        // Create initial commit so HEAD exists
        try "initial".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git add .", at: dir)
        try runShell("git commit -m 'initial'", at: dir)

        return dir
    }

    /// Resolves firmlinks (/var -> /private/var) using realpath.
    private func resolveURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func runShell(_ command: String, at dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - setup

    @Test("setup detects git repository")
    func setupDetectsGitRepo() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        #expect(provider.isGitRepository == true)
        #expect(provider.gitRootPath != nil)
        #expect(provider.currentBranch.isEmpty == false)
    }

    @Test("setup detects non-git directory")
    func setupDetectsNonGitDir() throws {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        #expect(provider.isGitRepository == false)
        #expect(provider.currentBranch == "")
        #expect(provider.fileStatuses.isEmpty)
        #expect(provider.branches.isEmpty)
    }

    @Test("setup populates branches")
    func setupPopulatesBranches() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        #expect(!provider.branches.isEmpty)
        #expect(provider.branches.contains(provider.currentBranch))
    }

    // MARK: - statusForFile

    @Test("statusForFile returns nil for clean file")
    func statusForFileClean() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let status = provider.statusForFile(at: dir.appendingPathComponent("README.md"))
        #expect(status == nil)
    }

    @Test("statusForFile returns modified for changed file")
    func statusForFileModified() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "changed".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let status = provider.statusForFile(at: dir.appendingPathComponent("README.md"))
        #expect(status == .modified)
    }

    @Test("statusForFile returns untracked for new file")
    func statusForFileUntracked() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "new".write(
            to: dir.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let status = provider.statusForFile(at: dir.appendingPathComponent("new.txt"))
        #expect(status == .untracked)
    }

    @Test("statusForFile returns staged for added file")
    func statusForFileStaged() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "staged".write(
            to: dir.appendingPathComponent("staged.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git add staged.txt", at: dir)

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let status = provider.statusForFile(at: dir.appendingPathComponent("staged.txt"))
        #expect(status == .added)
    }

    @Test("statusForFile returns nil for file outside repo")
    func statusForFileOutsideRepo() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let outsideURL = URL(fileURLWithPath: "/tmp/nonexistent.txt")
        let status = provider.statusForFile(at: outsideURL)
        #expect(status == nil)
    }

    // MARK: - statusForDirectory

    @Test("statusForDirectory returns status for directory with modified files")
    func statusForDirectoryModified() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let subdir = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        try "code".write(
            to: subdir.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git add .", at: dir)
        try runShell("git commit -m 'add src'", at: dir)

        // Modify the file
        try "modified code".write(
            to: subdir.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let status = provider.statusForDirectory(at: subdir)
        #expect(status == .modified)
    }

    @Test("statusForDirectory returns nil for clean directory")
    func statusForDirectoryClean() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let subdir = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        try "code".write(
            to: subdir.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git add .", at: dir)
        try runShell("git commit -m 'add src'", at: dir)

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let status = provider.statusForDirectory(at: subdir)
        #expect(status == nil)
    }

    @Test("statusForDirectory returns untracked for new files in directory")
    func statusForDirectoryUntracked() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let subdir = dir.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        try "new".write(
            to: subdir.appendingPathComponent("util.swift"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let status = provider.statusForDirectory(at: subdir)
        #expect(status == .untracked)
    }

    // MARK: - diffForFile

    @Test("diffForFile returns diffs for modified file")
    func diffForFileModified() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        // Modify the committed file
        try "line1\nline2\nline3\n".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let diffs = provider.diffForFile(at: dir.appendingPathComponent("README.md"))
        #expect(!diffs.isEmpty)
    }

    @Test("diffForFile returns empty for clean file")
    func diffForFileClean() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let diffs = provider.diffForFile(at: dir.appendingPathComponent("README.md"))
        #expect(diffs.isEmpty)
    }

    @Test("diffForFile returns empty for non-git directory")
    func diffForFileNonGit() throws {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let diffs = provider.diffForFile(at: dir.appendingPathComponent("file.txt"))
        #expect(diffs.isEmpty)
    }

    // MARK: - checkoutBranch

    @Test("checkoutBranch switches to existing branch")
    func checkoutBranchSuccess() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try runShell("git branch test-branch", at: dir)

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let result = provider.checkoutBranch("test-branch")
        #expect(result.success == true)
        #expect(result.error.isEmpty)
        #expect(provider.currentBranch == "test-branch")
    }

    @Test("checkoutBranch fails for non-existent branch")
    func checkoutBranchFailure() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let result = provider.checkoutBranch("nonexistent-branch")
        #expect(result.success == false)
        #expect(!result.error.isEmpty)
    }

    @Test("checkoutBranch fails without repository")
    func checkoutBranchNoRepo() {
        let provider = GitStatusProvider()
        let result = provider.checkoutBranch("main")
        #expect(result.success == false)
    }

    // MARK: - refresh

    @Test("refresh updates fileStatuses after external changes")
    func refreshUpdatesStatuses() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        #expect(provider.fileStatuses.isEmpty)

        // Create a new file externally
        try "new".write(
            to: dir.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        provider.refresh()
        #expect(!provider.fileStatuses.isEmpty)
        #expect(provider.fileStatuses["new.txt"] == .untracked)
    }

    @Test("refresh does nothing without repository")
    func refreshNoRepo() {
        let provider = GitStatusProvider()
        provider.refresh() // Should not crash
        #expect(provider.fileStatuses.isEmpty)
    }
}
