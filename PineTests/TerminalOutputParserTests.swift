//
//  TerminalOutputParserTests.swift
//  PineTests
//
//  Tests for TerminalOutputParser — detects file:line references in
//  terminal output and resolves them against the working directory.
//

import Testing
import Foundation
@testable import Pine

@Suite("Terminal Output Parser Tests")
struct TerminalOutputParserTests {

    // MARK: - Test fixtures

    /// Creates a temporary directory with the given relative files, returns
    /// the directory URL. Files are cleaned up automatically by `TempDir`.
    private func makeWorkDir(with files: [String]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for file in files {
            let url = tempDir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Standard patterns

    @Test func parsesSimpleFileNameWithLine() throws {
        let dir = try makeWorkDir(with: ["Server.swift"])
        defer { cleanup(dir) }

        let text = "Error in Server.swift:42"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.line == 42)
        #expect(link.column == nil)
        #expect(link.fileURL.lastPathComponent == "Server.swift")
        #expect(link.fileURL.deletingLastPathComponent().path == dir.path)
    }

    @Test func parsesAbsolutePathWithLineAndColumn() throws {
        let dir = try makeWorkDir(with: [])
        let absFile = dir.appendingPathComponent("Module.swift")
        try Data().write(to: absFile)
        defer { cleanup(dir) }

        let text = "\(absFile.path):10:5"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.line == 10)
        #expect(link.column == 5)
        #expect(link.fileURL.path == absFile.path)
    }

    @Test func parsesRelativePathWithSubdirectory() throws {
        let dir = try makeWorkDir(with: ["src/config.yml"])
        defer { cleanup(dir) }

        let text = "Check src/config.yml:3"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.line == 3)
        #expect(link.column == nil)
        #expect(link.fileURL.lastPathComponent == "config.yml")
    }

    @Test func parsesLineOnlyWithoutColumn() throws {
        let dir = try makeWorkDir(with: ["app.ts"])
        defer { cleanup(dir) }

        let text = "app.ts:100"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.line == 100)
        #expect(link.column == nil)
    }

    @Test func parsesLineAndColumn() throws {
        let dir = try makeWorkDir(with: ["app.ts"])
        defer { cleanup(dir) }

        let text = "app.ts:100:25"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.line == 100)
        #expect(link.column == 25)
    }

    // MARK: - Non-file rejection

    @Test func rejectsHttpURLs() throws {
        let dir = try makeWorkDir(with: [])
        defer { cleanup(dir) }

        let text = "Visit https://example.com/page for docs"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.isEmpty)
    }

    @Test func rejectsNonExistentFile() throws {
        let dir = try makeWorkDir(with: [])
        defer { cleanup(dir) }

        let text = "Missing.swift:42 does not exist"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.isEmpty)
    }

    @Test func rejectsPlainWordsThatLookLikeReferences() throws {
        let dir = try makeWorkDir(with: [])
        defer { cleanup(dir) }

        // "warning:42" — no file called "warning" exists, so no link.
        let text = "warning:42 this is not a file path"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.isEmpty)
    }

    // MARK: - Multiline / multiple references

    @Test func parsesMultipleReferencesInMultilineText() throws {
        let dir = try makeWorkDir(with: ["Alpha.swift", "Beta.swift", "Gamma.swift"])
        defer { cleanup(dir) }

        let text = """
        Compiling...
        Error in Alpha.swift:10
        Warning in Beta.swift:25:5
        Also see Gamma.swift:3
        """
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 3)
        #expect(links[0].line == 10)
        #expect(links[1].line == 25)
        #expect(links[1].column == 5)
        #expect(links[2].line == 3)
    }

    @Test func parsesReferenceInSentenceWithSurroundingPunctuation() throws {
        let dir = try makeWorkDir(with: ["main.py"])
        defer { cleanup(dir) }

        // Trailing comma and closing parenthesis should not break the match.
        let text = "See (main.py:7), for details."
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.line == 7)
    }

    // MARK: - NSRange correctness

    @Test func nsrangePointsToExactTokenInText() throws {
        let dir = try makeWorkDir(with: ["index.js"])
        defer { cleanup(dir) }

        let text = "See index.js:15 here"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        let nsText = text as NSString
        let extracted = nsText.substring(with: link.range)
        #expect(extracted == "index.js:15")
    }

    @Test func nsrangeHandlesMultibyteText() throws {
        let dir = try makeWorkDir(with: ["main.swift"])
        defer { cleanup(dir) }

        // Leading multibyte characters shift byte offsets; NSString ranges
        // must be character-based, not byte-based.
        let text = "エラー main.swift:42 発生"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        let nsText = text as NSString
        let extracted = nsText.substring(with: link.range)
        #expect(extracted == "main.swift:42")
    }

    // MARK: - Edge cases

    @Test func doesNotMatchLineZero() throws {
        let dir = try makeWorkDir(with: ["edge.txt"])
        defer { cleanup(dir) }

        // Line 0 is not a valid compiler reference — most tools use 1-based lines.
        let text = "edge.txt:0"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.isEmpty)
    }

    @Test func matchesFilesWithoutExtension() throws {
        let dir = try makeWorkDir(with: ["Makefile"])
        defer { cleanup(dir) }

        let text = "Makefile:15"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.line == 15)
    }

    @Test func matchesDeeplyNestedRelativePath() throws {
        let dir = try makeWorkDir(with: ["Sources/App/Models/User.swift"])
        defer { cleanup(dir) }

        let text = "Sources/App/Models/User.swift:30:12"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.line == 30)
        #expect(link.column == 12)
    }

    @Test func matchesFileWithDashesAndUnderscores() throws {
        let dir = try makeWorkDir(with: ["my-cool_file.spec.ts"])
        defer { cleanup(dir) }

        let text = "my-cool_file.spec.ts:8"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        #expect(links.count == 1)
        #expect(links.first?.line == 8)
    }

    // MARK: - link(atColumn:) helper

    @Test func linkAtColumnFindsLinkUnderCursor() throws {
        let dir = try makeWorkDir(with: ["app.ts"])
        defer { cleanup(dir) }

        let text = "app.ts:100"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)

        // "app.ts:100" starts at index 0, length 11.
        // Column 5 should be inside the range.
        #expect(TerminalOutputParser.link(atColumn: 5, in: links) != nil)
        // Column 0 should be inside the range.
        #expect(TerminalOutputParser.link(atColumn: 0, in: links) != nil)
        // Column 11 (past the end) should be nil.
        #expect(TerminalOutputParser.link(atColumn: 11, in: links) == nil)
    }

    @Test func linkAtColumnReturnsNilForEmptyLinks() {
        #expect(TerminalOutputParser.link(atColumn: 0, in: []) == nil)
    }

    // MARK: - Empty input

    @Test func returnsEmptyForEmptyText() throws {
        let dir = try makeWorkDir(with: [])
        defer { cleanup(dir) }

        let links = TerminalOutputParser.parseFilePaths(in: "", workingDirectory: dir)
        #expect(links.isEmpty)
    }

    @Test func returnsEmptyForTextWithNoReferences() throws {
        let dir = try makeWorkDir(with: [])
        defer { cleanup(dir) }

        let text = "Just some regular terminal output without any file references"
        let links = TerminalOutputParser.parseFilePaths(in: text, workingDirectory: dir)
        #expect(links.isEmpty)
    }

    // MARK: - resolvePath

    @Test func resolvePathHandlesAbsolutePaths() {
        let dir = URL(fileURLWithPath: "/tmp")
        let resolved = TerminalOutputParser.resolvePath("/usr/local/bin/file", workingDirectory: dir)
        #expect(resolved.path == "/usr/local/bin/file")
    }

    @Test func resolvePathHandlesRelativePaths() {
        let dir = URL(fileURLWithPath: "/projects/pine")
        let resolved = TerminalOutputParser.resolvePath("src/main.swift", workingDirectory: dir)
        #expect(resolved.path == "/projects/pine/src/main.swift")
    }

    @Test func resolvePathExpandsHomeTilde() {
        let dir = URL(fileURLWithPath: "/tmp")
        let resolved = TerminalOutputParser.resolvePath("~/file.swift", workingDirectory: dir)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        #expect(resolved.path == "\(home)/file.swift")
    }
}
