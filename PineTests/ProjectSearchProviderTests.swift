//
//  ProjectSearchProviderTests.swift
//  PineTests
//
//  Created by Claude on 18.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("ProjectSearchProvider Tests")
struct ProjectSearchProviderTests {

    /// Creates a temporary directory with test files.
    private func createTestProject(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineSearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            let fileURL = dir.appendingPathComponent(name)
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Helper to resolve root path for collectSearchableFiles.
    private func resolvedRootPath(for dir: URL) -> String {
        let resolved = dir.resolvingSymlinksInPath().path
        return resolved.hasSuffix("/") ? resolved : resolved + "/"
    }

    // MARK: - searchFile tests

    @Test("searchFile finds matches in file content")
    func searchFileFindsMatches() throws {
        let dir = try createTestProject(files: ["test.swift": "let x = 1\nlet y = 2\nlet x = 3"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.swift"),
            query: "let x",
            isCaseSensitive: false
        )

        #expect(matches.count == 2)
        #expect(matches[0].lineNumber == 1)
        #expect(matches[1].lineNumber == 3)
    }

    @Test("searchFile case-insensitive finds mixed case")
    func searchFileCaseInsensitive() throws {
        let dir = try createTestProject(files: ["test.txt": "Hello World\nhello world\nHELLO WORLD"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "hello",
            isCaseSensitive: false
        )

        #expect(matches.count == 3)
    }

    @Test("searchFile case-sensitive only finds exact case")
    func searchFileCaseSensitive() throws {
        let dir = try createTestProject(files: ["test.txt": "Hello World\nhello world\nHELLO WORLD"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "hello",
            isCaseSensitive: true
        )

        #expect(matches.count == 1)
        #expect(matches[0].lineNumber == 2)
    }

    @Test("searchFile returns empty for no matches")
    func searchFileNoMatches() throws {
        let dir = try createTestProject(files: ["test.txt": "some content here"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "notfound",
            isCaseSensitive: false
        )

        #expect(matches.isEmpty)
    }

    @Test("searchFile respects remaining capacity")
    func searchFileRespectsCapacity() throws {
        let dir = try createTestProject(files: ["test.txt": "aaa\naaa\naaa\naaa\naaa"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "aaa",
            isCaseSensitive: false,
            remainingCapacity: 2
        )

        #expect(matches.count == 2)
    }

    @Test("searchFile finds multiple matches on same line")
    func searchFileMultipleMatchesSameLine() throws {
        let dir = try createTestProject(files: ["test.txt": "foo bar foo baz foo"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "foo",
            isCaseSensitive: false
        )

        #expect(matches.count == 3)
        #expect(matches.allSatisfy { $0.lineNumber == 1 })
    }

    @Test("searchFile returns correct line numbers (1-based)")
    func searchFileLineNumbers() throws {
        let dir = try createTestProject(files: ["test.txt": "a\nb\nc\nd\ne"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.txt"),
            query: "c",
            isCaseSensitive: false
        )

        #expect(matches.count == 1)
        #expect(matches[0].lineNumber == 3)
    }

    @Test("searchFile handles special characters without crashing")
    func searchFileSpecialCharacters() throws {
        let dir = try createTestProject(files: ["test.swift": "func foo() { }\nfunc bar() { }"])
        defer { cleanup(dir) }

        let matches = ProjectSearchProvider.searchFile(
            at: dir.appendingPathComponent("test.swift"),
            query: "func(",
            isCaseSensitive: false
        )

        // "func(" doesn't match because of space before (
        #expect(matches.isEmpty)
    }

    // MARK: - collectSearchableFiles tests

    @Test("collectSearchableFiles skips .git directory")
    func collectSkipsGitDir() throws {
        let dir = try createTestProject(files: [
            "main.swift": "code",
            ".git/config": "git config"
        ])
        defer { cleanup(dir) }

        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )
        let names = Set(files.map(\.0.lastPathComponent))

        #expect(names.contains("main.swift"))
        #expect(!names.contains("config"))
    }

    @Test("collectSearchableFiles skips binary files")
    func collectSkipsBinaryFiles() throws {
        let dir = try createTestProject(files: [
            "main.swift": "code",
            "image.png": "fake png"
        ])
        defer { cleanup(dir) }

        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )
        let names = Set(files.map(\.0.lastPathComponent))

        #expect(names.contains("main.swift"))
        #expect(!names.contains("image.png"))
    }

    @Test("collectSearchableFiles skips ignored directories")
    func collectSkipsIgnoredDirs() throws {
        let dir = try createTestProject(files: [
            "main.swift": "code",
            "build/output.txt": "build output"
        ])
        defer { cleanup(dir) }

        let buildPath = dir.appendingPathComponent("build").resolvingSymlinksInPath().path
        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [buildPath], resolvedRootPath: rootPath
        )
        let names = Set(files.map(\.0.lastPathComponent))

        #expect(names.contains("main.swift"))
        #expect(!names.contains("output.txt"))
    }

    @Test("collectSearchableFiles skips large files")
    func collectSkipsLargeFiles() throws {
        let dir = try createTestProject(files: ["main.swift": "code"])
        defer { cleanup(dir) }

        // Create a file larger than 1MB
        let largeURL = dir.appendingPathComponent("large.txt")
        let largeData = Data(count: ProjectSearchProvider.maxFileSize + 1)
        try largeData.write(to: largeURL)

        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )
        let names = Set(files.map(\.0.lastPathComponent))

        #expect(names.contains("main.swift"))
        #expect(!names.contains("large.txt"))
    }

    @Test("collectSearchableFiles returns relative paths")
    func collectReturnsRelativePaths() throws {
        let dir = try createTestProject(files: ["sub/file.txt": "content"])
        defer { cleanup(dir) }

        let rootPath = resolvedRootPath(for: dir)
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )

        #expect(files.count == 1)
        #expect(files[0].1 == "sub/file.txt")
    }

    // MARK: - performSearch integration tests

    @Test("performSearch returns grouped results")
    func performSearchGroupedResults() async throws {
        let dir = try createTestProject(files: [
            "a.swift": "let foo = 1",
            "b.swift": "var foo = 2\nlet bar = 3",
            "c.txt": "no match here"
        ])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "foo",
            isCaseSensitive: false,
            rootURL: dir
        )

        #expect(groups.count == 2)
        let totalMatches = groups.reduce(0) { $0 + $1.matches.count }
        #expect(totalMatches == 2)
    }

    @Test("performSearch with empty query returns empty results")
    func performSearchEmptyQuery() async {
        let groups = await ProjectSearchProvider.performSearch(
            query: "",
            isCaseSensitive: false,
            rootURL: URL(fileURLWithPath: "/tmp")
        )

        #expect(groups.isEmpty)
    }

    @Test("performSearch uses relative paths")
    func performSearchRelativePaths() async throws {
        let dir = try createTestProject(files: ["sub/file.txt": "hello"])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "hello",
            isCaseSensitive: false,
            rootURL: dir
        )

        #expect(groups.count == 1)
        #expect(groups[0].relativePath == "sub/file.txt")
    }

    // MARK: - isBinaryFile tests

    @Test("isBinaryFile detects image files")
    func isBinaryDetectsImages() {
        let url = URL(fileURLWithPath: "/tmp/test.png")
        #expect(ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test("isBinaryFile allows text files")
    func isBinaryAllowsText() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    @Test("isBinaryFile allows unknown extensions")
    func isBinaryAllowsUnknown() {
        let url = URL(fileURLWithPath: "/tmp/test.xyz123")
        #expect(!ProjectSearchProvider.isBinaryFile(url: url))
    }

    // MARK: - SearchMatch identity tests

    @Test("SearchMatch id is deterministic from lineNumber and matchRangeStart")
    func searchMatchIdDeterministic() {
        let match1 = SearchMatch(lineNumber: 5, lineContent: "test", matchRangeStart: 10, matchRangeLength: 4)
        let match2 = SearchMatch(lineNumber: 5, lineContent: "test", matchRangeStart: 10, matchRangeLength: 4)
        #expect(match1.id == match2.id)
    }

    @Test("SearchMatch id differs for different positions")
    func searchMatchIdDiffers() {
        let match1 = SearchMatch(lineNumber: 5, lineContent: "test", matchRangeStart: 10, matchRangeLength: 4)
        let match2 = SearchMatch(lineNumber: 6, lineContent: "test", matchRangeStart: 10, matchRangeLength: 4)
        #expect(match1.id != match2.id)
    }

    // MARK: - Provider state tests

    @Test("Empty query clears results")
    func emptyQueryClearsResults() {
        let provider = ProjectSearchProvider()
        provider.query = ""
        provider.search(in: URL(fileURLWithPath: "/tmp"))
        #expect(provider.results.isEmpty)
        #expect(provider.totalMatchCount == 0)
        #expect(!provider.isSearching)
    }

    @Test("Cancel stops search")
    func cancelStopsSearch() {
        let provider = ProjectSearchProvider()
        provider.query = "test"
        provider.search(in: URL(fileURLWithPath: "/tmp"))
        provider.cancel()
        #expect(!provider.isSearching)
    }
}
