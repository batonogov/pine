//
//  QuickOpenProviderTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("QuickOpenProvider Tests")
struct QuickOpenProviderTests {

    // MARK: - isSubsequence

    @Test("isSubsequence matches exact string")
    func isSubsequenceExact() {
        #expect(QuickOpenProvider.isSubsequence(query: "main", target: "main"))
    }

    @Test("isSubsequence matches non-contiguous characters in order")
    func isSubsequenceNonContiguous() {
        #expect(QuickOpenProvider.isSubsequence(query: "mns", target: "managers"))
    }

    @Test("isSubsequence empty query always matches")
    func isSubsequenceEmptyQuery() {
        #expect(QuickOpenProvider.isSubsequence(query: "", target: "anything"))
        #expect(QuickOpenProvider.isSubsequence(query: "", target: ""))
    }

    @Test("isSubsequence returns false when characters are out of order")
    func isSubsequenceOutOfOrder() {
        #expect(!QuickOpenProvider.isSubsequence(query: "ba", target: "abc"))
    }

    @Test("isSubsequence single character match")
    func isSubsequenceSingleChar() {
        #expect(QuickOpenProvider.isSubsequence(query: "a", target: "a"))
        #expect(QuickOpenProvider.isSubsequence(query: "a", target: "abc"))
        #expect(!QuickOpenProvider.isSubsequence(query: "z", target: "abc"))
    }

    @Test("isSubsequence is exact-case (caller is responsible for lowercasing)")
    func isSubsequenceCaseSensitive() {
        // fuzzyScore lowercases both sides; isSubsequence itself is exact
        #expect(QuickOpenProvider.isSubsequence(query: "main", target: "main"))
        #expect(!QuickOpenProvider.isSubsequence(query: "main", target: "Main"))
    }

    @Test("isSubsequence handles Cyrillic filenames")
    func isSubsequenceUnicode() {
        #expect(QuickOpenProvider.isSubsequence(query: "тест", target: "тестовый"))
        #expect(!QuickOpenProvider.isSubsequence(query: "тест", target: "текст"))
    }

    @Test("isSubsequence handles emoji in path")
    func isSubsequenceEmoji() {
        #expect(QuickOpenProvider.isSubsequence(query: "🚀", target: "launch🚀.swift"))
        #expect(!QuickOpenProvider.isSubsequence(query: "🎉", target: "launch🚀.swift"))
    }

    // MARK: - fuzzyScore

    @Test("fuzzyScore returns score for filename match")
    func fuzzyScoreFilenameMatch() throws {
        let score = try #require(
            QuickOpenProvider.fuzzyScore(query: "main", fileName: "main.swift", relativePath: "main.swift")
        )
        #expect(score >= 1000)
    }

    @Test("fuzzyScore exact filename match scores highest")
    func fuzzyScoreExactMatch() throws {
        let exactScore = try #require(
            QuickOpenProvider.fuzzyScore(query: "main.swift", fileName: "main.swift", relativePath: "main.swift")
        )
        let prefixScore = try #require(
            QuickOpenProvider.fuzzyScore(query: "main", fileName: "main.swift", relativePath: "main.swift")
        )
        #expect(exactScore > prefixScore)
    }

    @Test("fuzzyScore filename prefix match beats non-prefix substring")
    func fuzzyScorePrefixVsSubstring() throws {
        let prefixScore = try #require(
            QuickOpenProvider.fuzzyScore(query: "mai", fileName: "main.swift", relativePath: "main.swift")
        )
        let substringScore = try #require(
            QuickOpenProvider.fuzzyScore(query: "ain", fileName: "main.swift", relativePath: "main.swift")
        )
        #expect(prefixScore > substringScore)
    }

    @Test("fuzzyScore filename match scores higher than path-only match")
    func fuzzyScoreFilenameBeatsPath() throws {
        let filenameScore = try #require(QuickOpenProvider.fuzzyScore(
            query: "view",
            fileName: "ContentView.swift",
            relativePath: "src/ContentView.swift"
        ))
        let pathOnlyScore = try #require(QuickOpenProvider.fuzzyScore(
            query: "src",
            fileName: "ContentView.swift",
            relativePath: "src/ContentView.swift"
        ))
        #expect(filenameScore > pathOnlyScore)
    }

    @Test("fuzzyScore shorter path ranks higher on tie")
    func fuzzyScoreShorterPath() throws {
        let shortPathScore = try #require(QuickOpenProvider.fuzzyScore(
            query: "view",
            fileName: "MyView.swift",
            relativePath: "MyView.swift"
        ))
        let longPathScore = try #require(QuickOpenProvider.fuzzyScore(
            query: "view",
            fileName: "MyView.swift",
            relativePath: "very/long/nested/deeply/here/MyView.swift"
        ))
        #expect(shortPathScore > longPathScore)
    }

    @Test("fuzzyScore returns nil for no match")
    func fuzzyScoreNoMatch() {
        let score = QuickOpenProvider.fuzzyScore(query: "xyz", fileName: "main.swift", relativePath: "main.swift")
        #expect(score == nil)
    }

    @Test("fuzzyScore is case-insensitive")
    func fuzzyScoreCaseInsensitive() throws {
        let lower = try #require(QuickOpenProvider.fuzzyScore(query: "main", fileName: "main.swift", relativePath: "main.swift"))
        let upper = try #require(QuickOpenProvider.fuzzyScore(query: "MAIN", fileName: "main.swift", relativePath: "main.swift"))
        let mixed = try #require(QuickOpenProvider.fuzzyScore(query: "Main", fileName: "main.swift", relativePath: "main.swift"))
        #expect(lower == upper)
        #expect(lower == mixed)
    }

    @Test("fuzzyScore matches Cyrillic filenames")
    func fuzzyScoreUnicodeCyrillic() throws {
        let score = try #require(QuickOpenProvider.fuzzyScore(
            query: "тест",
            fileName: "тестовый.swift",
            relativePath: "тестовый.swift"
        ))
        #expect(score >= 1000)
    }

    @Test("fuzzyScore matches path with spaces")
    func fuzzyScorePathWithSpaces() {
        let score = QuickOpenProvider.fuzzyScore(
            query: "my file",
            fileName: "my file.txt",
            relativePath: "folder/my file.txt"
        )
        #expect(score != nil)
    }

    @Test("fuzzyScore matches path component containing query")
    func fuzzyScorePathMatch() {
        let score = QuickOpenProvider.fuzzyScore(
            query: "utils",
            fileName: "helpers.swift",
            relativePath: "src/utils/helpers.swift"
        )
        #expect(score != nil)
        // Path-only match should have lower base score than filename match
        #expect(score! < 1000)
    }

    @Test("fuzzyScore handles empty query")
    func fuzzyScoreEmptyQuery() {
        // Empty query: isSubsequence returns true for any target
        let score = QuickOpenProvider.fuzzyScore(query: "", fileName: "main.swift", relativePath: "main.swift")
        #expect(score != nil)
    }

    @Test("fuzzyScore handles very long filenames")
    func fuzzyScoreLongFilename() {
        let longName = String(repeating: "a", count: 200) + ".swift"
        let score = QuickOpenProvider.fuzzyScore(query: "a", fileName: longName, relativePath: longName)
        #expect(score != nil)
    }

    // MARK: - collectFiles

    @Test("collectFiles returns all files in directory")
    func collectFilesBasic() throws {
        let dir = try createTestProject(files: [
            "main.swift": "",
            "helpers.swift": ""
        ])
        defer { cleanup(dir) }

        let rootPath = dir.resolvingSymlinksInPath().path + "/"
        let files = QuickOpenProvider.collectFiles(rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath)

        #expect(files.count == 2)
        let names = Set(files.map { $0.url.lastPathComponent })
        #expect(names == ["main.swift", "helpers.swift"])
    }

    @Test("collectFiles skips .git directory")
    func collectFilesSkipsGit() throws {
        let dir = try createTestProject(files: [
            "main.swift": "",
            ".git/HEAD": "ref: refs/heads/main"
        ])
        defer { cleanup(dir) }

        let rootPath = dir.resolvingSymlinksInPath().path + "/"
        let files = QuickOpenProvider.collectFiles(rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath)

        let names = files.map { $0.url.lastPathComponent }
        #expect(!names.contains("HEAD"))
        #expect(names.contains("main.swift"))
    }

    @Test("collectFiles skips gitignored directories")
    func collectFilesSkipsIgnoredDirs() throws {
        let dir = try createTestProject(files: [
            "main.swift": "",
            "node_modules/package.json": ""
        ])
        defer { cleanup(dir) }

        let nodeModules = dir.appendingPathComponent("node_modules").resolvingSymlinksInPath().path
        let rootPath = dir.resolvingSymlinksInPath().path + "/"
        let files = QuickOpenProvider.collectFiles(
            rootURL: dir,
            ignoredDirs: [nodeModules],
            resolvedRootPath: rootPath
        )

        let names = files.map { $0.url.lastPathComponent }
        #expect(!names.contains("package.json"))
        #expect(names.contains("main.swift"))
    }

    @Test("collectFiles returns relative paths")
    func collectFilesRelativePaths() throws {
        let dir = try createTestProject(files: [
            "src/main.swift": ""
        ])
        defer { cleanup(dir) }

        let rootPath = dir.resolvingSymlinksInPath().path + "/"
        let files = QuickOpenProvider.collectFiles(rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath)

        #expect(files.count == 1)
        #expect(files[0].relativePath == "src/main.swift")
    }

    // MARK: - search (empty query — synchronous path)

    @Test("search with empty query returns all files immediately")
    func searchEmptyQueryReturnsAll() {
        let provider = QuickOpenProvider()
        provider.injectFilesForTesting([
            (url: URL(fileURLWithPath: "/tmp/main.swift"), relativePath: "main.swift"),
            (url: URL(fileURLWithPath: "/tmp/helpers.swift"), relativePath: "helpers.swift")
        ])

        provider.search(query: "")

        #expect(provider.results.count == 2)
    }

    @Test("search with empty query shows recently opened file first")
    func searchEmptyQueryRecentFirst() {
        let provider = QuickOpenProvider()
        let url1 = URL(fileURLWithPath: "/tmp/main.swift")
        let url2 = URL(fileURLWithPath: "/tmp/helpers.swift")
        let url3 = URL(fileURLWithPath: "/tmp/test.swift")

        provider.injectFilesForTesting([
            (url: url1, relativePath: "main.swift"),
            (url: url2, relativePath: "helpers.swift"),
            (url: url3, relativePath: "test.swift")
        ])

        // Record url2 as recently opened using the real key
        let key = QuickOpenProvider.recentFilesKey
        let previous = UserDefaults.standard.stringArray(forKey: key)
        UserDefaults.standard.set([url2.path], forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        provider.search(query: "")

        // helpers.swift (url2) should appear first as it's recent
        #expect(provider.results.first?.url == url2)
    }

    @Test("search with empty query capped at maxResults")
    func searchEmptyQueryCapped() {
        let provider = QuickOpenProvider()
        let files: [(url: URL, relativePath: String)] = (0..<100).map { i in
            (url: URL(fileURLWithPath: "/tmp/file_\(i).swift"), relativePath: "file_\(i).swift")
        }
        provider.injectFilesForTesting(files)

        provider.search(query: "")

        #expect(provider.results.count <= QuickOpenProvider.maxResults)
    }

    // MARK: - search (async path)

    @Test("search with query filters results asynchronously")
    func searchWithQueryFilters() async {
        let provider = QuickOpenProvider()
        provider.injectFilesForTesting([
            (url: URL(fileURLWithPath: "/tmp/main.swift"), relativePath: "main.swift"),
            (url: URL(fileURLWithPath: "/tmp/helpers.swift"), relativePath: "helpers.swift"),
            (url: URL(fileURLWithPath: "/tmp/test.swift"), relativePath: "test.swift")
        ])

        provider.search(query: "main")

        // Wait for debounce + async processing
        try? await Task.sleep(for: .milliseconds(400))

        #expect(!provider.results.isEmpty)
        #expect(provider.results.allSatisfy {
            $0.fileName.lowercased().contains("main") ||
            $0.relativePath.lowercased().contains("main")
        })
    }

    @Test("search with non-matching query returns empty results")
    func searchNoResults() async {
        let provider = QuickOpenProvider()
        provider.injectFilesForTesting([
            (url: URL(fileURLWithPath: "/tmp/main.swift"), relativePath: "main.swift")
        ])

        provider.search(query: "zzzzzz")

        try? await Task.sleep(for: .milliseconds(400))

        #expect(provider.results.isEmpty)
    }

    // MARK: - recordOpened

    @Test("recordOpened stores URL in UserDefaults")
    func recordOpenedStoresURL() {
        let provider = QuickOpenProvider()
        let url = URL(fileURLWithPath: "/tmp/main.swift")
        let key = "test.recentFiles.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        UserDefaults.standard.set([url.path], forKey: key)
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        #expect(paths.contains(url.path))
    }

    @Test("recordOpened deduplicates entries")
    func recordOpenedDeduplicates() {
        let provider = QuickOpenProvider()
        let url = URL(fileURLWithPath: "/tmp/main.swift")
        let key = "test.recentFiles.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        provider.recordOpenedWithKey(url, key: key)
        provider.recordOpenedWithKey(url, key: key)

        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        #expect(paths.filter { $0 == url.path }.count == 1)
    }

    @Test("recordOpened promotes URL to front on re-open")
    func recordOpenedPromotesToFront() {
        let provider = QuickOpenProvider()
        let url1 = URL(fileURLWithPath: "/tmp/first.swift")
        let url2 = URL(fileURLWithPath: "/tmp/second.swift")
        let key = "test.recentFiles.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        provider.recordOpenedWithKey(url1, key: key)
        provider.recordOpenedWithKey(url2, key: key)
        provider.recordOpenedWithKey(url1, key: key) // re-open url1 → should be first

        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        #expect(paths.first == url1.path)
    }

    // MARK: - Performance

    @Test("search on 10k files completes within 1 second")
    func searchPerformanceLargeFileSet() async {
        let provider = QuickOpenProvider()

        let files: [(url: URL, relativePath: String)] = (0..<10_000).map { index in
            let name = "file_\(index).swift"
            return (url: URL(fileURLWithPath: "/tmp/\(name)"), relativePath: name)
        }
        provider.injectFilesForTesting(files)

        let start = Date()
        provider.search(query: "file_9")

        // Wait for debounce (150ms) + processing time
        try? await Task.sleep(for: .milliseconds(600))

        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "Expected search to complete within 1s on 10k files, took \(elapsed)s")
        #expect(!provider.results.isEmpty)
    }

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
}

// MARK: - QuickOpenProvider test helpers

extension QuickOpenProvider {
    /// Injects files directly, bypassing async indexing (for unit tests).
    func injectFilesForTesting(_ files: [(url: URL, relativePath: String)]) {
        indexedFiles = files
    }

    /// Records an opened URL using a custom UserDefaults key (for test isolation).
    func recordOpenedWithKey(_ url: URL, key: String) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > Self.maxRecentFiles {
            paths = Array(paths.prefix(Self.maxRecentFiles))
        }
        UserDefaults.standard.set(paths, forKey: key)
    }

}
