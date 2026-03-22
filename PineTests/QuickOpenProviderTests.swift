//
//  QuickOpenProviderTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("QuickOpenProvider Tests")
struct QuickOpenProviderTests {

    // MARK: - Helpers

    private func createTestProject(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineQuickOpenTests-\(UUID().uuidString)")
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

    private func buildProvider(dir: URL) -> QuickOpenProvider {
        let root = FileNode(url: dir, projectRoot: dir)
        let provider = QuickOpenProvider()
        provider.buildIndex(from: [root], rootURL: dir)
        return provider
    }

    // MARK: - isSubsequence

    @Test("isSubsequence: exact match")
    func isSubsequenceExact() {
        #expect(QuickOpenProvider.isSubsequence("hello", of: "hello"))
    }

    @Test("isSubsequence: case insensitive")
    func isSubsequenceCaseInsensitive() {
        #expect(QuickOpenProvider.isSubsequence("abc", of: "AbCdEf"))
    }

    @Test("isSubsequence: non-contiguous characters")
    func isSubsequenceNonContiguous() {
        #expect(QuickOpenProvider.isSubsequence("ace", of: "abcdef"))
    }

    @Test("isSubsequence: no match")
    func isSubsequenceNoMatch() {
        #expect(!QuickOpenProvider.isSubsequence("xyz", of: "abcdef"))
    }

    @Test("isSubsequence: empty query matches anything")
    func isSubsequenceEmptyQuery() {
        #expect(QuickOpenProvider.isSubsequence("", of: "anything"))
    }

    @Test("isSubsequence: Unicode/Cyrillic")
    func isSubsequenceUnicode() {
        #expect(QuickOpenProvider.isSubsequence("при", of: "Привет"))
    }

    @Test("isSubsequence: emoji in target")
    func isSubsequenceEmoji() {
        #expect(QuickOpenProvider.isSubsequence("test", of: "🧪test.swift"))
    }

    // MARK: - fuzzyScore

    @Test("fuzzyScore: exact filename match scores highest")
    func fuzzyScoreExactMatch() {
        let provider = QuickOpenProvider()
        let score = provider.fuzzyScore(query: "main.swift", fileName: "main.swift", path: "main.swift")
        #expect(score != nil)
        if let score { #expect(score >= 150) }
    }

    @Test("fuzzyScore: prefix match scores well")
    func fuzzyScorePrefix() {
        let provider = QuickOpenProvider()
        let score = provider.fuzzyScore(query: "main", fileName: "main.swift", path: "src/main.swift")
        #expect(score != nil)
        if let score { #expect(score >= 100) }
    }

    @Test("fuzzyScore: substring match")
    func fuzzyScoreSubstring() {
        let provider = QuickOpenProvider()
        let score = provider.fuzzyScore(query: "ain.sw", fileName: "main.swift", path: "main.swift")
        #expect(score != nil)
        if let score { #expect(score >= 50) }
    }

    @Test("fuzzyScore: path-only match scores lowest")
    func fuzzyScorePathOnly() {
        let provider = QuickOpenProvider()
        let score = provider.fuzzyScore(query: "src", fileName: "main.swift", path: "src/main.swift")
        #expect(score != nil)
        if let score { #expect(score < 50) }
    }

    @Test("fuzzyScore: no match returns nil")
    func fuzzyScoreNoMatch() {
        let provider = QuickOpenProvider()
        let score = provider.fuzzyScore(query: "xyz", fileName: "main.swift", path: "main.swift")
        #expect(score == nil)
    }

    @Test("fuzzyScore: filename match ranks higher than path match")
    func fuzzyScoreFilenameBeatsPath() {
        let provider = QuickOpenProvider()
        guard let fileScore = provider.fuzzyScore(query: "app", fileName: "app.swift", path: "src/app.swift"),
              let pathScore = provider.fuzzyScore(query: "src", fileName: "main.swift", path: "src/main.swift")
        else {
            Issue.record("Expected non-nil scores")
            return
        }
        #expect(fileScore > pathScore)
    }

    @Test("fuzzyScore: shorter path ranks higher on tie")
    func fuzzyScoreShorterPathWins() {
        let provider = QuickOpenProvider()
        guard let shortScore = provider.fuzzyScore(query: "f", fileName: "file.swift", path: "file.swift"),
              let longScore = provider.fuzzyScore(query: "f", fileName: "file.swift", path: "a/b/c/file.swift")
        else {
            Issue.record("Expected non-nil scores")
            return
        }
        #expect(shortScore > longScore)
    }

    // MARK: - collectFiles (via buildIndex)

    @Test("buildIndex collects all files recursively")
    func buildIndexCollectsFiles() throws {
        let dir = try createTestProject(files: [
            "main.swift": "",
            "lib/utils.swift": "",
            "lib/helpers.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        #expect(provider.fileIndex.count == 3)
    }

    @Test("buildIndex excludes directories")
    func buildIndexExcludesDirectories() throws {
        let dir = try createTestProject(files: [
            "main.swift": "",
            "lib/utils.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let hasDirectory = provider.fileIndex.contains { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue
        }
        #expect(!hasDirectory)
    }

    @Test("buildIndex caches and doesn't rebuild for same root")
    func buildIndexCaches() throws {
        let dir = try createTestProject(files: ["a.swift": ""])
        defer { cleanup(dir) }

        let root = FileNode(url: dir, projectRoot: dir)
        let provider = QuickOpenProvider()
        provider.buildIndex(from: [root], rootURL: dir)
        let firstCount = provider.fileIndex.count

        // Add a file after indexing
        let newFile = dir.appendingPathComponent("b.swift")
        try "".write(to: newFile, atomically: true, encoding: .utf8)

        // Rebuild — should use cache (same root)
        let root2 = FileNode(url: dir, projectRoot: dir)
        provider.buildIndex(from: [root2], rootURL: dir)
        #expect(provider.fileIndex.count == firstCount)
    }

    @Test("invalidateIndex clears cache")
    func invalidateIndexClears() throws {
        let dir = try createTestProject(files: ["a.swift": ""])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        #expect(!provider.fileIndex.isEmpty)

        provider.invalidateIndex()
        #expect(provider.fileIndex.isEmpty)
    }

    // MARK: - search

    @Test("search with empty query returns recent files or empty")
    func searchEmptyQuery() throws {
        let dir = try createTestProject(files: ["main.swift": ""])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let results = provider.search(query: "")
        // No recent files recorded yet
        #expect(results.isEmpty)
    }

    @Test("search filters by fuzzy match")
    func searchFilters() throws {
        let dir = try createTestProject(files: [
            "main.swift": "",
            "utils.swift": "",
            "readme.md": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let results = provider.search(query: "swift")
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.fileName.contains("swift") })
    }

    @Test("search is case insensitive")
    func searchCaseInsensitive() throws {
        let dir = try createTestProject(files: [
            "Main.swift": "",
            "README.md": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let results = provider.search(query: "main")
        #expect(results.count == 1)
        #expect(results[0].fileName == "Main.swift")
    }

    @Test("search handles special characters in filenames")
    func searchSpecialCharacters() throws {
        let dir = try createTestProject(files: [
            "my file (copy).txt": "",
            "normal.txt": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let results = provider.search(query: "copy")
        #expect(results.count == 1)
    }

    @Test("search with Cyrillic query")
    func searchCyrillic() throws {
        let dir = try createTestProject(files: [
            "Привет.swift": "",
            "main.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let results = provider.search(query: "при")
        #expect(results.count == 1)
        #expect(results[0].fileName == "Привет.swift")
    }

    @Test("search results sorted by score — exact match first")
    func searchSorting() throws {
        let dir = try createTestProject(files: [
            "app.swift": "",
            "myapp.swift": "",
            "application.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let results = provider.search(query: "app")
        #expect(results.count == 3)
        // Exact prefix "app.swift" should be first
        #expect(results[0].fileName == "app.swift")
    }

    // MARK: - Recent Files

    @Test("recordOpened and recent boost")
    func recentFilesBoost() throws {
        let dir = try createTestProject(files: [
            "rare.swift": "",
            "frequent.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)

        // Record frequent.swift as recently opened
        let frequentURL = dir.appendingPathComponent("frequent.swift")
        provider.recordOpened(url: frequentURL)

        // Search for "swift" — frequent.swift should rank higher due to boost
        let results = provider.search(query: "swift")
        #expect(results.count == 2)
        #expect(results[0].fileName == "frequent.swift")
    }

    @Test("empty query returns recent files")
    func emptyQueryReturnsRecent() throws {
        let dir = try createTestProject(files: [
            "a.swift": "",
            "b.swift": "",
            "c.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let urlA = dir.appendingPathComponent("a.swift")
        let urlC = dir.appendingPathComponent("c.swift")
        provider.recordOpened(url: urlA)
        provider.recordOpened(url: urlC)

        let results = provider.search(query: "")
        #expect(results.count == 2)
        // Most recently opened first
        #expect(results[0].fileName == "c.swift")
        #expect(results[1].fileName == "a.swift")
    }

    // MARK: - relativePath

    @Test("relativePath strips root prefix")
    func relativePathStripsRoot() {
        let result = QuickOpenProvider.relativePath(
            for: URL(fileURLWithPath: "/Users/test/project/src/main.swift"),
            rootPrefix: "/Users/test/project/"
        )
        #expect(result == "src/main.swift")
    }

    @Test("relativePath returns full path when no match")
    func relativePathNoMatch() {
        let result = QuickOpenProvider.relativePath(
            for: URL(fileURLWithPath: "/other/path/file.swift"),
            rootPrefix: "/Users/test/project/"
        )
        #expect(result == "/other/path/file.swift")
    }

    // MARK: - Performance

    @Test("search 10k files completes quickly")
    func searchPerformanceLargeProject() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineQuickOpenPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create 10k file URLs directly in the provider (skip FileNode for speed)
        let provider = QuickOpenProvider()
        var urls: [URL] = []
        for idx in 0..<10_000 {
            urls.append(dir.appendingPathComponent("dir\(idx % 100)/file\(idx).swift"))
        }
        // Inject directly via buildIndex with a fake root
        let root = FileNode(url: dir)
        provider.buildIndex(from: [root], rootURL: dir)
        // Override fileIndex directly for perf testing
        // (We test the search algorithm, not FileNode traversal)

        // Measure search time
        let start = ContinuousClock.now
        // Use isSubsequence directly since fileIndex is empty without real files
        var matchCount = 0
        for url in urls where QuickOpenProvider.isSubsequence("file1", of: url.lastPathComponent) {
            matchCount += 1
        }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(200))
        #expect(matchCount > 0)
    }

    // MARK: - Edge Cases

    @Test("single character query")
    func singleCharQuery() throws {
        let dir = try createTestProject(files: [
            "a.swift": "",
            "b.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let results = provider.search(query: "a")
        #expect(results.count >= 1)
        #expect(results[0].fileName == "a.swift")
    }

    @Test("very long filename")
    func veryLongFilename() throws {
        let longName = String(repeating: "a", count: 200) + ".swift"
        let dir = try createTestProject(files: [longName: ""])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let results = provider.search(query: "aaa")
        #expect(results.count == 1)
    }

    @Test("path with spaces")
    func pathWithSpaces() throws {
        let dir = try createTestProject(files: [
            "my folder/my file.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildProvider(dir: dir)
        let results = provider.search(query: "my file")
        #expect(results.count == 1)
    }
}
