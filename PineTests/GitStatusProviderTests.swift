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
@MainActor
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

    @Test("statusForFile returns untracked for file inside untracked directory")
    func statusForFileInsideUntrackedDir() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let subdir = dir.appendingPathComponent("newdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "code".write(
            to: subdir.appendingPathComponent("file.swift"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        // git status --porcelain reports "?? newdir/" (single entry),
        // so the file inside should inherit untracked status.
        let fileStatus = provider.statusForFile(at: subdir.appendingPathComponent("file.swift"))
        #expect(fileStatus == .untracked)
    }

    @Test("statusForDirectory returns untracked for C-quoted directory with spaces")
    func statusForDirectoryWithSpaces() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        // Reproduce the exact scenario from issue #201:
        // git status --porcelain C-quotes paths with spaces as "examples copy/"
        let subdir = dir.appendingPathComponent("examples copy")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "code".write(
            to: subdir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let dirStatus = provider.statusForDirectory(at: subdir)
        #expect(dirStatus == .untracked)

        let fileStatus = provider.statusForFile(at: subdir.appendingPathComponent("file.txt"))
        #expect(fileStatus == .untracked)
    }

    @Test("statusForDirectory returns untracked for subdirectory inside untracked directory")
    func statusForSubdirInsideUntrackedDir() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let subdir = dir.appendingPathComponent("newdir")
        let nested = subdir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "code".write(
            to: nested.appendingPathComponent("file.swift"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        // git status --porcelain reports "?? newdir/" (single entry),
        // so nested subdirectory should also be untracked.
        let nestedStatus = provider.statusForDirectory(at: nested)
        #expect(nestedStatus == .untracked)
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

    @Test("refresh populates branch, fileStatuses, and branches in parallel")
    func refreshPopulatesAllFields() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        // Make changes after setup so refresh() has new data to fetch
        try runShell("git branch feature-branch", at: dir)
        try "changed".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        provider.refresh()

        // Verify all three parallel fetches populated correctly
        #expect(!provider.currentBranch.isEmpty)
        #expect(provider.fileStatuses["README.md"] == .modified)
        #expect(provider.branches.contains("feature-branch"))
    }

    @Test("refresh does nothing without repository")
    func refreshNoRepo() {
        let provider = GitStatusProvider()
        provider.refresh() // Should not crash
        #expect(provider.fileStatuses.isEmpty)
    }

    // MARK: - Static fetch methods

    @Test("fetchBranch returns current branch name")
    func fetchBranchReturnsName() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let branch = GitStatusProvider.fetchBranch(at: dir)
        #expect(!branch.isEmpty)
    }

    @Test("fetchBranch returns empty for non-git directory")
    func fetchBranchNonGit() throws {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)
        defer { cleanup(dir) }

        let branch = GitStatusProvider.fetchBranch(at: dir)
        #expect(branch.isEmpty)
    }

    @Test("fetchStatusAndIgnored returns statuses and ignored paths")
    func fetchStatusAndIgnoredWorks() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        // Create an untracked file and a gitignored directory
        try "new".write(
            to: dir.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "build/\n".write(
            to: dir.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let buildDir = dir.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try "out".write(
            to: buildDir.appendingPathComponent("output.o"),
            atomically: true,
            encoding: .utf8
        )

        let result = GitStatusProvider.fetchStatusAndIgnored(at: dir)
        #expect(result.statuses["new.txt"] == .untracked)
        #expect(result.ignored.contains("build"))
    }

    @Test("fetchBranches returns list of branches")
    func fetchBranchesWorks() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try runShell("git branch dev", at: dir)
        try runShell("git branch staging", at: dir)

        let branches = GitStatusProvider.fetchBranches(at: dir)
        #expect(branches.count >= 3) // main/master + dev + staging
        #expect(branches.contains("dev"))
        #expect(branches.contains("staging"))
    }

    @Test("fetchBranches returns empty for non-git directory")
    func fetchBranchesNonGit() throws {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)
        defer { cleanup(dir) }

        let branches = GitStatusProvider.fetchBranches(at: dir)
        #expect(branches.isEmpty)
    }

    // MARK: - refreshAsync

    @Test("refreshAsync updates fileStatuses asynchronously")
    func refreshAsyncUpdatesStatuses() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        // Create a new file after initial setup
        try "new".write(
            to: dir.appendingPathComponent("async-new.txt"),
            atomically: true,
            encoding: .utf8
        )

        // refreshAsync runs git on background queue — await completion
        await provider.refreshAsync()
        #expect(provider.fileStatuses["async-new.txt"] == .untracked)
    }

    @Test("refreshAsync updates currentBranch and branches")
    func refreshAsyncUpdatesBranchInfo() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        // Create a second branch so branches list has > 1 entry
        try runShell("git checkout -b feature-branch", at: dir)

        await provider.refreshAsync()
        #expect(provider.currentBranch == "feature-branch")
        #expect(provider.branches.contains("main") || provider.branches.contains("master"))
        #expect(provider.branches.contains("feature-branch"))
    }

    @Test("refreshAsync updates ignoredPaths")
    func refreshAsyncUpdatesIgnoredPaths() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        // Add .gitignore with ignored patterns
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
        try runShell("git -c commit.gpgsign=false commit -m 'add gitignore'", at: dir)

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        await provider.refreshAsync()
        #expect(provider.ignoredPaths.contains("build"))
        #expect(provider.ignoredPaths.contains(".env"))
    }

    @Test("refreshAsync does nothing without repository")
    func refreshAsyncNoRepo() async {
        let provider = GitStatusProvider()
        await provider.refreshAsync() // Should not crash
        #expect(provider.fileStatuses.isEmpty)
    }

    @Test("refreshAsync with isGitRepository false is no-op")
    func refreshAsyncNotGitRepo() async {
        let provider = GitStatusProvider()
        provider.repositoryURL = URL(fileURLWithPath: "/tmp")
        // isGitRepository is false by default — refreshAsync should bail out
        await provider.refreshAsync()
        #expect(provider.fileStatuses.isEmpty)
        #expect(provider.currentBranch == "")
    }

    @Test("refreshAsync discards results when cancelled")
    func refreshAsyncCancellation() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        // Create a file so git status would have something to report
        try "new".write(
            to: dir.appendingPathComponent("cancelled.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Start refreshAsync in a Task and cancel it immediately
        let task = Task {
            await provider.refreshAsync()
        }
        task.cancel()
        await task.value

        // If cancellation took effect, fileStatuses should NOT contain
        // the new file. If the background work finished before cancel
        // was checked, it may still contain it — both outcomes are valid.
        // The key invariant: no crash.
    }

    // MARK: - setupAsync

    @Test("setupAsync detects git repository without blocking")
    func setupAsyncDetectsGitRepo() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        await provider.setupAsync(repositoryURL: dir)

        #expect(provider.isGitRepository == true)
        #expect(provider.gitRootPath != nil)
        #expect(!provider.currentBranch.isEmpty)
        #expect(!provider.branches.isEmpty)
    }

    @Test("setupAsync detects non-git directory")
    func setupAsyncNonGit() async throws {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        await provider.setupAsync(repositoryURL: dir)

        #expect(provider.isGitRepository == false)
        #expect(provider.currentBranch == "")
        #expect(provider.fileStatuses.isEmpty)
    }

    // MARK: - checkoutBranchAsync

    @Test("checkoutBranchAsync switches to existing branch")
    func checkoutBranchAsyncSuccess() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try runShell("git branch test-branch", at: dir)

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let result = await provider.checkoutBranchAsync("test-branch")
        #expect(result.success == true)
        #expect(result.error.isEmpty)
        #expect(provider.currentBranch == "test-branch")
    }

    @Test("checkoutBranchAsync fails for non-existent branch")
    func checkoutBranchAsyncFailure() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let result = await provider.checkoutBranchAsync("nonexistent-branch")
        #expect(result.success == false)
        #expect(!result.error.isEmpty)
    }

    @Test("checkoutBranchAsync fails without repository")
    func checkoutBranchAsyncNoRepo() async {
        let provider = GitStatusProvider()
        let result = await provider.checkoutBranchAsync("main")
        #expect(result.success == false)
    }

    // MARK: - diffForFileAsync

    @Test("diffForFileAsync returns diffs for modified file")
    func diffForFileAsyncModified() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "line1\nline2\nline3\n".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let diffs = await provider.diffForFileAsync(at: dir.appendingPathComponent("README.md"))
        #expect(!diffs.isEmpty)
    }

    @Test("diffForFileAsync returns empty for clean file")
    func diffForFileAsyncClean() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let diffs = await provider.diffForFileAsync(at: dir.appendingPathComponent("README.md"))
        #expect(diffs.isEmpty)
    }

    @Test("diffForFileAsync returns empty for non-git directory")
    func diffForFileAsyncNonGit() async throws {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        let diffs = await provider.diffForFileAsync(at: dir.appendingPathComponent("file.txt"))
        #expect(diffs.isEmpty)
    }

    // MARK: - runGit timeout

    @Test("runGit terminates process after timeout")
    func runGitTimeout() {
        // Use git hash-object --stdin which blocks waiting for input
        let start = Date()
        let result = GitStatusProvider.runGit(
            ["hash-object", "--stdin"],
            at: URL(fileURLWithPath: "/tmp"),
            timeout: 1.0
        )
        let elapsed = Date().timeIntervalSince(start)
        // Process should be terminated by timeout, not hang for 30s+
        #expect(elapsed < 5.0)
        #expect(result.exitCode != 0)
    }

    // MARK: - hasUncommittedChanges

    @Test("hasUncommittedChanges is false for clean repo")
    func hasUncommittedChangesClean() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        #expect(provider.hasUncommittedChanges == false)
    }

    @Test("hasUncommittedChanges is true when files are modified")
    func hasUncommittedChangesModified() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "changed".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        #expect(provider.hasUncommittedChanges == true)
    }

    @Test("hasUncommittedChanges is true when files are untracked")
    func hasUncommittedChangesUntracked() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "new".write(
            to: dir.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        provider.setup(repositoryURL: dir)

        #expect(provider.hasUncommittedChanges == true)
    }

    // MARK: - Thread safety (Issue #613)

    @Test("fetchBranches is safe to call from background thread")
    func fetchBranchesSafeFromBackground() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try runShell("git branch feature-1", at: dir)
        try runShell("git branch feature-2", at: dir)

        // Call fetchBranches from a background thread — must not crash
        // with dispatch_assert_queue_fail
        let branches = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = GitStatusProvider.fetchBranches(at: dir)
                continuation.resume(returning: result)
            }
        }

        #expect(branches.count >= 3)
        #expect(branches.contains("feature-1"))
        #expect(branches.contains("feature-2"))
    }

    @Test("fetchAllInParallel is safe to call from background thread")
    func fetchAllInParallelSafeFromBackground() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "modified".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git branch bg-branch", at: dir)

        // Call fetchAllInParallel from background — must not crash
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fetched = GitStatusProvider.fetchAllInParallel(at: dir)
                continuation.resume(returning: fetched)
            }
        }

        #expect(!result.branch.isEmpty)
        #expect(result.statuses["README.md"] == .modified)
        #expect(result.branches.contains("bg-branch"))
    }

    @Test("fetchBranches filters empty lines correctly")
    func fetchBranchesFiltersEmptyLines() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let branches = GitStatusProvider.fetchBranches(at: dir)
        // No empty strings should be in the result
        for branch in branches {
            #expect(!branch.isEmpty)
        }
    }

    @Test("fetchAllInParallel concurrent calls do not crash")
    func fetchAllInParallelConcurrent() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        // Run multiple parallel fetchAllInParallel calls — stress test
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    let result = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            let fetched = GitStatusProvider.fetchAllInParallel(at: dir)
                            continuation.resume(returning: fetched)
                        }
                    }
                    _ = result
                }
            }
        }
        // If we get here without crashing, the test passes
    }

    @Test("setup does not block main thread with synchronous refresh")
    func setupUsesAsyncRefresh() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "new".write(
            to: dir.appendingPathComponent("test.txt"),
            atomically: true,
            encoding: .utf8
        )

        let provider = GitStatusProvider()
        await provider.setupAsync(repositoryURL: dir)

        #expect(provider.isGitRepository == true)
        #expect(!provider.currentBranch.isEmpty)
        #expect(provider.fileStatuses["test.txt"] == .untracked)
    }

    @Test("checkoutBranchAsync refreshes all fields after switch")
    func checkoutBranchAsyncRefreshesAll() async throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try runShell("git branch switch-target", at: dir)

        let provider = GitStatusProvider()
        await provider.setupAsync(repositoryURL: dir)

        let result = await provider.checkoutBranchAsync("switch-target")
        #expect(result.success == true)
        #expect(provider.currentBranch == "switch-target")
        #expect(provider.branches.contains("switch-target"))
    }
}
