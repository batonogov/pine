//
//  GitFileRevertTests.swift
//  PineTests
//
//  Tests for GitFileRevert (issue #1073): reverting tracked files to their
//  committed (HEAD) state via `git checkout --` against a temporary git repo.
//
//  `TempRepo` is a top-level type (not nested) because a throwing method on a
//  nested type trips a Swift Testing macro-expansion bug where `#expect`
//  incorrectly inherits the throwing context.
//

import Foundation
import Testing
@testable import Pine

@Suite("GitFileRevert")
struct GitFileRevertTests {

    /// Reverts a modified tracked file back to its committed contents.
    @Test func revertsModifiedFileToHEAD() throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo.url) }

        try repo.write(file: "notes.txt", contents: "committed\n")
        try repo.git(["add", "notes.txt"])
        try repo.git(["commit", "-m", "initial"])

        try repo.write(file: "notes.txt", contents: "committed\nagent change\n")
        let modified = try repo.read(file: "notes.txt")
        #expect(modified.contains("agent change"))

        let results = GitFileRevert.revert(relativePaths: ["notes.txt"], in: repo.url)
        #expect(results.count == 1)
        #expect(results.first?.success == true)
        let reverted = try repo.read(file: "notes.txt")
        #expect(reverted == "committed\n")
    }

    /// Reverting multiple files in one call reports one result per path, in
    /// input order.
    @Test func revertsMultipleFilesInOrder() throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo.url) }

        try repo.write(file: "a.txt", contents: "A\n")
        try repo.write(file: "b.txt", contents: "B\n")
        try repo.git(["add", "a.txt", "b.txt"])
        try repo.git(["commit", "-m", "two files"])

        try repo.write(file: "a.txt", contents: "A\nA\n")
        try repo.write(file: "b.txt", contents: "B\nB\n")

        let results = GitFileRevert.revert(relativePaths: ["a.txt", "b.txt"], in: repo.url)
        #expect(results.count == 2)
        #expect(results[0].relativePath == "a.txt")
        #expect(results[1].relativePath == "b.txt")
        #expect(results[0].success && results[1].success)
        let a = try repo.read(file: "a.txt")
        let b = try repo.read(file: "b.txt")
        #expect(a == "A\n")
        #expect(b == "B\n")
    }

    /// Reverting a path nested in a subdirectory works.
    @Test func revertsNestedPath() throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo.url) }

        try repo.write(file: "src/deep/file.swift", contents: "v1\n")
        try repo.git(["add", "src/deep/file.swift"])
        try repo.git(["commit", "-m", "nested"])

        try repo.write(file: "src/deep/file.swift", contents: "v2\n")
        let results = GitFileRevert.revert(relativePaths: ["src/deep/file.swift"], in: repo.url)
        #expect(results.first?.success == true)
        let nested = try repo.read(file: "src/deep/file.swift")
        #expect(nested == "v1\n")
    }

    /// Reverting a file outside a git repo reports failure rather than
    /// throwing (the history store relies on this for graceful degradation).
    @Test func revertsOutsideRepoReportsFailure() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-revert-nogit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try "x\n".write(to: temp.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)

        let results = GitFileRevert.revert(relativePaths: ["x.txt"], in: temp)
        #expect(results.count == 1)
        #expect(results.first?.success == false)
    }

    @discardableResult
    private func makeTempGitRepo() throws -> TempRepo {
        try TempRepo.make()
    }
}

/// Minimal temporary git repository. Top-level (not nested in the test type)
/// to avoid a Swift Testing macro-expansion bug where throwing methods on a
/// nested type make `#expect` inherit a throwing context it cannot satisfy.
private struct TempRepo {
    let url: URL

    static func make() throws -> TempRepo {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-revert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let repo = TempRepo(url: url)
        try repo.git(["init"])
        // Stable identity required to commit on CI runners without git config.
        try repo.git(["config", "user.email", "test@pine.local"])
        try repo.git(["config", "user.name", "Pine Test"])
        // Deterministic default branch regardless of git version.
        try repo.git(["symbolic-ref", "HEAD", "refs/heads/main"])
        return repo
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitFileRevertTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
    }

    func write(file: String, contents: String) throws {
        let fileURL = url.appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func read(file: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
    }
}
