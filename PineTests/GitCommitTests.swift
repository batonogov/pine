//
//  GitCommitTests.swift
//  PineTests
//
//  Tests for git staging, unstaging, commit operations, and CommitFileEntry model.
//

import Foundation
import Testing

@testable import Pine

@Suite("Git Commit Operations")
struct GitCommitTests {

    // MARK: - Helpers

    private func makeGitRepo() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-commit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        let dir = try resolveURL(rawDir)

        try runShell("git init", at: dir)
        try runShell("git config user.email 'test@test.com'", at: dir)
        try runShell("git config user.name 'Test'", at: dir)

        try "initial".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git add .", at: dir)
        try runShell("git commit -m 'initial'", at: dir)

        return dir
    }

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

    // MARK: - parseStagedAndUnstaged

    @Test("parseStagedAndUnstaged parses staged added file")
    func parseStagedAdded() {
        let output = "A  newfile.swift\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.staged["newfile.swift"] == .added)
        #expect(result.unstaged.isEmpty)
    }

    @Test("parseStagedAndUnstaged parses staged modified file")
    func parseStagedModified() {
        let output = "M  changed.swift\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.staged["changed.swift"] == .staged)
        #expect(result.unstaged.isEmpty)
    }

    @Test("parseStagedAndUnstaged parses unstaged modified file")
    func parseUnstagedModified() {
        let output = " M changed.swift\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.unstaged["changed.swift"] == .modified)
        #expect(result.staged.isEmpty)
    }

    @Test("parseStagedAndUnstaged parses untracked file")
    func parseUntracked() {
        let output = "?? newfile.swift\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.unstaged["newfile.swift"] == .untracked)
        #expect(result.staged.isEmpty)
    }

    @Test("parseStagedAndUnstaged parses both staged and unstaged changes")
    func parseMixed() {
        let output = "MM both.swift\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.staged["both.swift"] == .staged)
        #expect(result.unstaged["both.swift"] == .modified)
    }

    @Test("parseStagedAndUnstaged parses staged deleted file")
    func parseStagedDeleted() {
        let output = "D  removed.swift\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.staged["removed.swift"] == .deleted)
    }

    @Test("parseStagedAndUnstaged parses unstaged deleted file")
    func parseUnstagedDeleted() {
        let output = " D removed.swift\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.unstaged["removed.swift"] == .deleted)
    }

    @Test("parseStagedAndUnstaged handles renamed files")
    func parseRenamed() {
        let output = "R  old.swift -> new.swift\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.staged["new.swift"] == .staged)
    }

    @Test("parseStagedAndUnstaged ignores ignored entries")
    func parseIgnored() {
        let output = "!! ignored.swift\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.staged.isEmpty)
        #expect(result.unstaged.isEmpty)
    }

    @Test("parseStagedAndUnstaged handles empty output")
    func parseEmpty() {
        let result = GitStatusProvider.parseStagedAndUnstaged("")
        #expect(result.staged.isEmpty)
        #expect(result.unstaged.isEmpty)
    }

    @Test("parseStagedAndUnstaged handles multiple files")
    func parseMultiple() {
        let output = """
        A  new.swift
         M modified.swift
        ?? untracked.txt
        D  deleted.swift
        """
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.staged.count == 2) // new.swift (added) + deleted.swift (deleted)
        #expect(result.unstaged.count == 2) // modified.swift + untracked.txt
    }

    @Test("parseStagedAndUnstaged handles quoted paths")
    func parseQuotedPaths() {
        let output = "A  \"path with spaces/file.swift\"\n"
        let result = GitStatusProvider.parseStagedAndUnstaged(output)
        #expect(result.staged["path with spaces/file.swift"] == .added)
    }

    // MARK: - Integration: stageFile / unstageFile

    @Test("stageFile stages a modified file")
    func stageFileIntegration() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "modified".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = GitStatusProvider.stageFile("README.md", at: dir)
        #expect(result.success)

        let files = GitStatusProvider.fetchStagedAndUnstaged(at: dir)
        #expect(files.staged["README.md"] == .staged)
    }

    @Test("unstageFile unstages a staged file")
    func unstageFileIntegration() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "modified".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = GitStatusProvider.stageFile("README.md", at: dir)
        let result = GitStatusProvider.unstageFile("README.md", at: dir)
        #expect(result.success)

        let files = GitStatusProvider.fetchStagedAndUnstaged(at: dir)
        #expect(files.staged["README.md"] == nil)
        #expect(files.unstaged["README.md"] == .modified)
    }

    @Test("stageFiles stages multiple files at once")
    func stageMultipleFiles() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let result = GitStatusProvider.stageFiles(["a.txt", "b.txt"], at: dir)
        #expect(result.success)

        let files = GitStatusProvider.fetchStagedAndUnstaged(at: dir)
        #expect(files.staged["a.txt"] == .added)
        #expect(files.staged["b.txt"] == .added)
    }

    @Test("unstageFiles unstages multiple files at once")
    func unstageMultipleFiles() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = GitStatusProvider.stageFiles(["a.txt", "b.txt"], at: dir)

        let result = GitStatusProvider.unstageFiles(["a.txt", "b.txt"], at: dir)
        #expect(result.success)

        let files = GitStatusProvider.fetchStagedAndUnstaged(at: dir)
        #expect(files.staged["a.txt"] == nil)
        #expect(files.staged["b.txt"] == nil)
    }

    // MARK: - Integration: commit

    @Test("commit creates a commit with staged files")
    func commitIntegration() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "new content".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = GitStatusProvider.stageFile("README.md", at: dir)

        let result = GitStatusProvider.commit(message: "test commit", at: dir)
        #expect(result.success)

        // Verify no staged files after commit
        let files = GitStatusProvider.fetchStagedAndUnstaged(at: dir)
        #expect(files.staged.isEmpty)
        #expect(files.unstaged.isEmpty)

        // Verify commit message in log
        let log = try runShell("git log --oneline -1", at: dir)
        #expect(log.contains("test commit"))
    }

    @Test("commit fails with no staged files")
    func commitNoStagedFiles() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let result = GitStatusProvider.commit(message: "empty commit", at: dir)
        #expect(!result.success)
    }

    @Test("commit with multiline message")
    func commitMultilineMessage() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "updated".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = GitStatusProvider.stageFile("README.md", at: dir)

        let message = "feat: add feature\n\nThis is the body of the commit message."
        let result = GitStatusProvider.commit(message: message, at: dir)
        #expect(result.success)
    }

    // MARK: - Integration: diff methods

    @Test("diffForCommitFile returns diff for unstaged changes")
    func diffForUnstagedFile() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "changed content".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let diff = GitStatusProvider.diffForCommitFile("README.md", at: dir)
        #expect(diff.contains("changed content"))
    }

    @Test("diffForStagedFile returns diff for staged changes")
    func diffForStagedFileTest() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        try "staged content".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = GitStatusProvider.stageFile("README.md", at: dir)

        let diff = GitStatusProvider.diffForStagedFile("README.md", at: dir)
        #expect(diff.contains("staged content"))
    }

    @Test("diffForCommitFile returns empty for clean file")
    func diffForCleanFile() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let diff = GitStatusProvider.diffForCommitFile("README.md", at: dir)
        #expect(diff.isEmpty)
    }

    // MARK: - CommitFileEntry model

    @Test("CommitFileEntry statusLabel for added")
    func statusLabelAdded() {
        let entry = CommitFileEntry(id: "test", path: "file.swift", status: .added, isStaged: true)
        #expect(entry.statusLabel == "A")
    }

    @Test("CommitFileEntry statusLabel for modified")
    func statusLabelModified() {
        let entry = CommitFileEntry(id: "test", path: "file.swift", status: .modified, isStaged: false)
        #expect(entry.statusLabel == "M")
    }

    @Test("CommitFileEntry statusLabel for deleted")
    func statusLabelDeleted() {
        let entry = CommitFileEntry(id: "test", path: "file.swift", status: .deleted, isStaged: true)
        #expect(entry.statusLabel == "D")
    }

    @Test("CommitFileEntry statusLabel for untracked")
    func statusLabelUntracked() {
        let entry = CommitFileEntry(id: "test", path: "file.swift", status: .untracked, isStaged: false)
        #expect(entry.statusLabel == "?")
    }

    @Test("CommitFileEntry statusLabel for conflict")
    func statusLabelConflict() {
        let entry = CommitFileEntry(id: "test", path: "file.swift", status: .conflict, isStaged: false)
        #expect(entry.statusLabel == "C")
    }

    @Test("CommitFileEntry statusLabel for staged")
    func statusLabelStaged() {
        let entry = CommitFileEntry(id: "test", path: "file.swift", status: .staged, isStaged: true)
        #expect(entry.statusLabel == "M")
    }

    @Test("CommitFileEntry statusLabel for mixed")
    func statusLabelMixed() {
        let entry = CommitFileEntry(id: "test", path: "file.swift", status: .mixed, isStaged: false)
        #expect(entry.statusLabel == "M")
    }

    @Test("CommitFileEntry equality")
    func entryEquality() {
        let entry1 = CommitFileEntry(id: "a", path: "file.swift", status: .added, isStaged: true)
        let entry2 = CommitFileEntry(id: "a", path: "file.swift", status: .added, isStaged: true)
        let entry3 = CommitFileEntry(id: "b", path: "file.swift", status: .modified, isStaged: false)
        #expect(entry1 == entry2)
        #expect(entry1 != entry3)
    }

    // MARK: - fetchStagedAndUnstaged integration

    @Test("fetchStagedAndUnstaged returns correct file lists")
    func fetchStagedAndUnstagedIntegration() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        // Create modified file
        try "modified".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        // Create new file and stage it
        try "new".write(
            to: dir.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runShell("git add new.txt", at: dir)

        let files = GitStatusProvider.fetchStagedAndUnstaged(at: dir)
        #expect(files.staged["new.txt"] == .added)
        #expect(files.unstaged["README.md"] == .modified)
    }

    @Test("fetchStagedAndUnstaged returns empty for clean repo")
    func fetchCleanRepo() throws {
        let dir = try makeGitRepo()
        defer { cleanup(dir) }

        let files = GitStatusProvider.fetchStagedAndUnstaged(at: dir)
        #expect(files.staged.isEmpty)
        #expect(files.unstaged.isEmpty)
    }
}
