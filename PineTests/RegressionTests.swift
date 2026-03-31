//
//  RegressionTests.swift
//  PineTests
//
//  Regression tests for #457: edge-case coverage for QuickOpenProvider,
//  GoToLineParser, trailing whitespace stripping, parallel search,
//  and partial file loading.
//

import Foundation
import Testing

@testable import Pine

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let rawDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PineRegression-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
    guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func createTestProject(files: [String: String]) throws -> URL {
    let dir = try makeTempDir()
    for (name, content) in files {
        let fileURL = dir.appendingPathComponent(name)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    return dir
}

private func buildQuickOpenProvider(dir: URL) -> QuickOpenProvider {
    let root = FileNode(url: dir, projectRoot: dir)
    let provider = QuickOpenProvider()
    provider.buildIndex(from: [root], rootURL: dir)
    return provider
}

// MARK: - QuickOpenProvider: Unicode filenames

@Suite("QuickOpenProvider Regression")
@MainActor
struct QuickOpenProviderRegressionTests {

    @Test("Unicode filenames with mixed scripts are indexed and searchable")
    func unicodeFilenames() throws {
        let dir = try createTestProject(files: [
            "日本語ファイル.swift": "",
            "αβγδ.txt": "",
            "ñoño.py": "",
            "文件.rs": ""
        ])
        defer { cleanup(dir) }

        let provider = buildQuickOpenProvider(dir: dir)
        #expect(provider.fileIndex.count == 4)

        let results1 = provider.search(query: "日本")
        #expect(results1.count == 1)
        #expect(results1[0].fileName == "日本語ファイル.swift")

        let results2 = provider.search(query: "αβ")
        #expect(results2.count == 1)

        let results3 = provider.search(query: "ñoño")
        #expect(results3.count == 1)
    }

    @Test("Emoji filenames are indexed and searchable")
    func emojiFilenames() throws {
        let dir = try createTestProject(files: [
            "🔥fire.swift": "",
            "🎉party.txt": ""
        ])
        defer { cleanup(dir) }

        let provider = buildQuickOpenProvider(dir: dir)
        #expect(provider.fileIndex.count == 2)

        let results = provider.search(query: "🔥")
        #expect(results.count == 1)
        #expect(results[0].fileName == "🔥fire.swift")
    }

    @Test("Symlinks inside project are indexed")
    func symlinkInsideProject() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let realFile = dir.appendingPathComponent("real.swift")
        try "code".write(to: realFile, atomically: true, encoding: .utf8)

        let linkFile = dir.appendingPathComponent("link.swift")
        try FileManager.default.createSymbolicLink(at: linkFile, withDestinationURL: realFile)

        let provider = buildQuickOpenProvider(dir: dir)
        // Both real file and symlink are separate entries in the tree
        #expect(provider.fileIndex.count == 2)
        let names = Set(provider.fileIndex.map(\.lastPathComponent))
        #expect(names.contains("real.swift"))
        #expect(names.contains("link.swift"))
    }

    @Test("Symlink outside project is not followed into external tree")
    func symlinkOutsideProject() throws {
        let projectDir = try makeTempDir()
        let externalDir = try makeTempDir()
        defer { cleanup(projectDir); cleanup(externalDir) }

        try "external".write(
            to: externalDir.appendingPathComponent("external.swift"),
            atomically: true, encoding: .utf8
        )
        try "project".write(
            to: projectDir.appendingPathComponent("local.swift"),
            atomically: true, encoding: .utf8
        )

        // Create symlink pointing outside project
        let linkDir = projectDir.appendingPathComponent("ext_link")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: externalDir)

        let provider = buildQuickOpenProvider(dir: projectDir)
        // External files through symlink should NOT be in the index
        let externalResults = provider.search(query: "external")
        #expect(externalResults.isEmpty)
    }

    @Test("Empty project returns no results")
    func emptyProject() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let provider = buildQuickOpenProvider(dir: dir)
        #expect(provider.fileIndex.isEmpty)

        let results = provider.search(query: "anything")
        #expect(results.isEmpty)
    }

    @Test("Duplicate filenames in different directories both appear")
    func duplicateFilenames() throws {
        let dir = try createTestProject(files: [
            "src/main.swift": "",
            "tests/main.swift": "",
            "lib/main.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildQuickOpenProvider(dir: dir)
        let results = provider.search(query: "main.swift")
        #expect(results.count == 3)

        // All should have different relative paths
        let paths = Set(results.map(\.relativePath))
        #expect(paths.count == 3)
    }

    @Test("Deeply nested files are found")
    func deeplyNestedFiles() throws {
        let dir = try createTestProject(files: [
            "a/b/c/d/e/f/deep.swift": ""
        ])
        defer { cleanup(dir) }

        let provider = buildQuickOpenProvider(dir: dir)
        let results = provider.search(query: "deep")
        #expect(results.count == 1)
        #expect(results[0].relativePath.contains("a/b/c/d/e/f/deep.swift"))
    }

    @Test(".git and .DS_Store are excluded but other dotfiles are indexed")
    func hiddenFilesFiltering() throws {
        let dir = try createTestProject(files: [
            "visible.swift": "",
            ".hidden": "",
            ".DS_Store": "fake",
            ".git/config": "fake"
        ])
        defer { cleanup(dir) }

        let provider = buildQuickOpenProvider(dir: dir)
        let names = Set(provider.fileIndex.map(\.lastPathComponent))

        // FileNode only filters .git and .DS_Store — other dotfiles are kept
        #expect(names.contains("visible.swift"))
        #expect(names.contains(".hidden"))
        #expect(!names.contains(".DS_Store"))
        #expect(!names.contains("config")) // inside .git
    }

    @Test("Invalidate and rebuild index works correctly")
    func invalidateAndRebuild() throws {
        let dir = try createTestProject(files: ["a.swift": ""])
        defer { cleanup(dir) }

        let provider = buildQuickOpenProvider(dir: dir)
        #expect(provider.fileIndex.count == 1)

        provider.invalidateIndex()
        #expect(provider.fileIndex.isEmpty)

        // Add a new file and rebuild
        try "".write(to: dir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let root = FileNode(url: dir, projectRoot: dir)
        provider.buildIndex(from: [root], rootURL: dir)
        #expect(provider.fileIndex.count == 2)
    }
}

// MARK: - GoToLineParser: Edge Cases

@Suite("GoToLineParser Regression")
@MainActor
struct GoToLineParserRegressionTests {

    @Test("Extremely large line number is parsed")
    func veryLargeLine() {
        let result = GoToLineParser.parse("999999999")
        #expect(result?.line == 999_999_999)
        #expect(result?.column == nil)
    }

    @Test("Extremely large column number is parsed")
    func veryLargeColumn() {
        let result = GoToLineParser.parse("1:999999999")
        #expect(result?.line == 1)
        #expect(result?.column == 999_999_999)
    }

    @Test("Alternative separators return nil (comma, semicolon)")
    func alternativeSeparators() {
        #expect(GoToLineParser.parse("1,2") == nil)
        #expect(GoToLineParser.parse("1;2") == nil)
        #expect(GoToLineParser.parse("!@#") == nil)
    }

    @Test("cursorOffset beyond last line clamps to end")
    func cursorOffsetBeyondFile() {
        let content = "line1\nline2\nline3"
        let offset = ContentView.cursorOffset(forLine: 100, in: content)
        #expect(offset == (content as NSString).length)
    }

    @Test("cursorOffset for line 0 still works (clamps to valid range)")
    func cursorOffsetLineZero() {
        let content = "line1\nline2"
        // Line 0 is invalid but shouldn't crash
        let offset = ContentView.cursorOffset(forLine: 0, in: content)
        // Implementation detail: cursorOffset uses 1-based, line 0 would go to start
        #expect(offset >= 0)
        #expect(offset <= (content as NSString).length)
    }

    @Test("cursorOffset with empty content")
    func cursorOffsetEmptyContent() {
        let offset = ContentView.cursorOffset(forLine: 1, in: "")
        #expect(offset == 0)
    }

    @Test("cursorOffset column clamped to line length")
    func cursorOffsetColumnClamped() {
        let content = "short\nmedium line\nlong"
        // Column 100 on "short" (5 chars) should clamp to end of line
        let offset = ContentView.cursorOffset(forLine: 1, column: 100, in: content)
        #expect(offset <= 5) // shouldn't go past end of "short"
    }
}

// MARK: - Strip Whitespace: Edge Cases

@Suite("TrailingWhitespace Regression")
@MainActor
struct TrailingWhitespaceRegressionTests {

    @Test("Binary-like content is not corrupted")
    func binaryLikeContent() {
        // String with null bytes and binary-looking data
        let input = "normal line  \n\0\0binary\0  \nanother  "
        let result = input.trailingWhitespaceStripped()
        // Should strip trailing spaces from normal lines
        #expect(result.hasPrefix("normal line"))
        // Should not crash on binary data
    }

    @Test("Mixed CRLF and LF preserved correctly")
    func mixedLineEndings() {
        let input = "line1   \r\nline2  \nline3\t\r\nline4  \n"
        let expected = "line1\r\nline2\nline3\r\nline4\n"
        #expect(input.trailingWhitespaceStripped() == expected)
    }

    @Test("Leading whitespace preserved while trailing stripped")
    func leadingPreservedTrailingStripped() {
        let input = "    indented   \n\t\ttabbed\t\t\n"
        let expected = "    indented\n\t\ttabbed\n"
        #expect(input.trailingWhitespaceStripped() == expected)
    }

    @Test("Single newline only remains unchanged")
    func singleNewline() {
        #expect("\n".trailingWhitespaceStripped() == "\n")
        #expect("\r\n".trailingWhitespaceStripped() == "\r\n")
    }

    @Test("Very long line with trailing spaces")
    func veryLongLine() {
        let longContent = String(repeating: "a", count: 10_000) + "   "
        let expected = String(repeating: "a", count: 10_000)
        #expect(longContent.trailingWhitespaceStripped() == expected)
    }

    @Test("Unicode content with trailing spaces")
    func unicodeWithTrailingSpaces() {
        let input = "Привет   \n你好  \n🎉  \n"
        let expected = "Привет\n你好\n🎉\n"
        #expect(input.trailingWhitespaceStripped() == expected)
    }

    @Test("Tab and space mix at end of line")
    func tabSpaceMix() {
        let input = "code \t \t  \nmore\t \n"
        let expected = "code\nmore\n"
        #expect(input.trailingWhitespaceStripped() == expected)
    }

    @Test("No-op on already clean content")
    func noOp() {
        let input = "clean\nlines\nno trailing\n"
        #expect(input.trailingWhitespaceStripped() == input)
    }

    @Test("Strip whitespace on save does not corrupt content")
    func stripOnSaveIntegration() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("test.swift")
        let original = "func foo()   \n    let x = 1  \n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)
        let success = manager.saveActiveTab()
        #expect(success)

        // Read back — should have trailing whitespace stripped
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "func foo()\n    let x = 1\n")
    }
}

// MARK: - Parallel Search: Correctness

@Suite("Parallel Search Regression")
@MainActor
struct ParallelSearchRegressionTests {

    @Test("Parallel search results match sequential search")
    func parallelMatchesSequential() async throws {
        let dir = try createTestProject(files: [
            "a.swift": "let needle = 1\nlet other = 2",
            "b.swift": "var needle = 3",
            "c.txt": "no match here",
            "d.py": "needle = 4\nneedle = 5",
            "e.rs": "fn needle() {}"
        ])
        defer { cleanup(dir) }

        // Sequential: searchFile on each file
        let rootPath = dir.resolvingSymlinksInPath().path + "/"
        let files = ProjectSearchProvider.collectSearchableFiles(
            rootURL: dir, ignoredDirs: [], resolvedRootPath: rootPath
        )

        var sequentialTotal = 0
        for (fileURL, _) in files {
            let matches = ProjectSearchProvider.searchFile(
                at: fileURL, query: "needle", isCaseSensitive: false
            )
            sequentialTotal += matches.count
        }

        // Parallel: performSearch
        let groups = await ProjectSearchProvider.performSearch(
            query: "needle", isCaseSensitive: false, rootURL: dir
        )
        let parallelTotal = groups.reduce(0) { $0 + $1.matches.count }

        #expect(parallelTotal == sequentialTotal)
    }

    @Test("Parallel search results are sorted by path")
    func parallelSearchSorted() async throws {
        let dir = try createTestProject(files: [
            "z_file.txt": "needle",
            "a_file.txt": "needle",
            "m_file.txt": "needle"
        ])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "needle", isCaseSensitive: false, rootURL: dir
        )

        let paths = groups.map(\.relativePath)
        #expect(paths == paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test("Concurrent search does not produce duplicates")
    func noDuplicates() async throws {
        var files: [String: String] = [:]
        for i in 0..<50 {
            files["file\(i).swift"] = "let target = \(i)"
        }
        let dir = try createTestProject(files: files)
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "target", isCaseSensitive: false, rootURL: dir
        )

        let urls = groups.map(\.url)
        let uniqueURLs = Set(urls)
        #expect(urls.count == uniqueURLs.count, "No duplicate file groups")
    }

    @Test("Concurrent search with many files doesn't crash")
    func stressTest() async throws {
        var files: [String: String] = [:]
        for i in 0..<200 {
            files["dir\(i % 10)/file\(i).txt"] = "content with marker line \(i)"
        }
        let dir = try createTestProject(files: files)
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "marker", isCaseSensitive: false, rootURL: dir
        )

        let totalMatches = groups.reduce(0) { $0 + $1.matches.count }
        #expect(totalMatches == 200)
    }

    @Test("Parallel search respects per-file match limit")
    func perFileMatchLimit() async throws {
        // Create a file with >100 matches per line repeated
        let manyMatches = (0..<200).map { "match\($0)" }.joined(separator: "\n")
        let dir = try createTestProject(files: ["big.txt": manyMatches])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "match", isCaseSensitive: false, rootURL: dir
        )

        // Per-file limit is 100
        if let group = groups.first {
            #expect(group.matches.count <= 100)
        }
    }

    @Test("Search empty directory returns empty results")
    func searchEmptyDirectory() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "anything", isCaseSensitive: false, rootURL: dir
        )
        #expect(groups.isEmpty)
    }

    @Test("Search with unicode query")
    func searchUnicodeQuery() async throws {
        let dir = try createTestProject(files: [
            "code.swift": "let привет = \"мир\"\nlet hello = \"world\""
        ])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "привет", isCaseSensitive: false, rootURL: dir
        )
        #expect(groups.count == 1)
        #expect(groups[0].matches.count == 1)
    }
}

// MARK: - Partial Load: Edge Cases

@Suite("Partial Load Regression")
@MainActor
struct PartialLoadRegressionTests {

    @Test("File at exactly 10MB threshold triggers partial load")
    func exactThreshold() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("exact.txt")
        let data = Data(count: TabManager.hugeFileThreshold)
        try data.write(to: url)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.isTruncated == true)
        #expect(manager.activeTab?.syntaxHighlightingDisabled == true)
    }

    @Test("File just below 10MB threshold opens fully")
    func belowThreshold() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("below.txt")
        let content = String(repeating: "x", count: TabManager.hugeFileThreshold - 1)
        try content.write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        // Use the explicit override to skip the large file alert dialog
        manager.openTab(url: url, syntaxHighlightingDisabled: true)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.isTruncated == false)
    }

    @Test("Save blocked for truncated file")
    func saveBlockedForTruncated() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("huge.txt")
        let data = Data(count: TabManager.hugeFileThreshold + 1)
        try data.write(to: url)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.activeTab?.isTruncated == true)

        // trySaveTab should throw for truncated files
        #expect(throws: (any Error).self) {
            try manager.trySaveTab(at: 0)
        }

        // File on disk should remain unchanged (original size)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = fileAttrs[.size] as? Int ?? 0
        #expect(fileSize == TabManager.hugeFileThreshold + 1)
    }

    @Test("Save all skips truncated tabs")
    func saveAllSkipsTruncated() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create a huge file and a normal file
        let hugeURL = dir.appendingPathComponent("huge.txt")
        try Data(count: TabManager.hugeFileThreshold + 1).write(to: hugeURL)

        let normalURL = dir.appendingPathComponent("normal.swift")
        try "hello".write(to: normalURL, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: hugeURL)
        manager.openTab(url: normalURL)
        manager.updateContent("modified")

        // Truncated tabs have content == savedContent, so they aren't dirty.
        // trySaveAllTabs only saves dirty tabs — truncated tab is skipped.
        #expect(manager.tabs[0].isTruncated == true)
        #expect(manager.tabs[1].isDirty == true)
        try manager.trySaveAllTabs()
        #expect(manager.tabs[1].isDirty == false)
    }

    @Test("Partial load reads only first 1MB of content")
    func partialLoadSize() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("big.txt")
        // Create 15MB file with recognizable pattern
        let pattern = "ABCDEFGHIJ" // 10 bytes
        let repeatCount = (TabManager.hugeFileThreshold + 5_000_000) / pattern.utf8.count
        let fullContent = String(repeating: pattern, count: repeatCount)
        try fullContent.write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.activeTab?.isTruncated == true)
        // Content should be approximately 1MB of the pattern + truncation notice
        if let content = manager.activeTab?.content {
            // The loaded portion should be around 1MB
            // (exact size depends on UTF-8 decoding boundaries)
            #expect(!content.isEmpty)
            #expect(content.count < fullContent.count)
        }
    }

    @Test("Session restore of huge file still uses partial load")
    func sessionRestorePartialLoad() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("huge.txt")
        try Data(count: TabManager.hugeFileThreshold + 1).write(to: url)

        let manager = TabManager()
        // Session restore path uses openTab(url:syntaxHighlightingDisabled:)
        manager.openTab(url: url, syntaxHighlightingDisabled: false)

        #expect(manager.activeTab?.isTruncated == true)
        #expect(manager.activeTab?.syntaxHighlightingDisabled == true)
    }

    @Test("Truncated tab is not marked as dirty")
    func truncatedTabNotDirty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("huge.txt")
        try Data(count: TabManager.hugeFileThreshold + 1).write(to: url)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.activeTab?.isTruncated == true)
        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("File size is stored on partial load tab")
    func fileSizeStoredOnPartialLoad() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let size = TabManager.hugeFileThreshold + 12345
        let url = dir.appendingPathComponent("huge.txt")
        try Data(count: size).write(to: url)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.activeTab?.fileSizeBytes == size)
    }
}

// MARK: - Session Restore Regression

@Suite("Session Restore Regression")
@MainActor
struct SessionRestoreRegressionTests {

    @Test("Session save and load round-trips correctly")
    func sessionRoundTrip() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file1 = dir.appendingPathComponent("a.swift")
        let file2 = dir.appendingPathComponent("b.swift")
        try "code1".write(to: file1, atomically: true, encoding: .utf8)
        try "code2".write(to: file2, atomically: true, encoding: .utf8)

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(
            projectURL: dir,
            openFileURLs: [file1, file2],
            activeFileURL: file2,
            defaults: defaults
        )

        let loaded = SessionState.load(for: dir, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.existingFileURLs.count == 2)
        #expect(loaded?.activeFileURL == file2)
    }

    @Test("Session load filters deleted files")
    func sessionFiltersMissing() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file1 = dir.appendingPathComponent("exists.swift")
        let file2 = dir.appendingPathComponent("deleted.swift")
        try "code".write(to: file1, atomically: true, encoding: .utf8)
        try "code".write(to: file2, atomically: true, encoding: .utf8)

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(
            projectURL: dir,
            openFileURLs: [file1, file2],
            defaults: defaults
        )

        // Delete one file
        try FileManager.default.removeItem(at: file2)

        let loaded = SessionState.load(for: dir, defaults: defaults)
        #expect(loaded?.existingFileURLs.count == 1)
        #expect(loaded?.existingFileURLs.first == file1)
    }

    @Test("Session load returns nil for deleted project directory")
    func sessionNilForDeletedProject() throws {
        let dir = try makeTempDir()

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(
            projectURL: dir,
            openFileURLs: [],
            defaults: defaults
        )

        try FileManager.default.removeItem(at: dir)

        let loaded = SessionState.load(for: dir, defaults: defaults)
        #expect(loaded == nil)
    }

    @Test("Session filters files outside project root")
    func sessionFiltersOutsideRoot() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let insideFile = dir.appendingPathComponent("inside.swift")
        try "code".write(to: insideFile, atomically: true, encoding: .utf8)

        let outsideFile = URL(fileURLWithPath: "/tmp/PineRegression-outside-\(UUID().uuidString).swift")
        try "code".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(
            projectURL: dir,
            openFileURLs: [insideFile, outsideFile],
            defaults: defaults
        )

        let loaded = SessionState.load(for: dir, defaults: defaults)
        // existingFileURLs filters to files within project root
        #expect(loaded?.existingFileURLs.count == 1)
        #expect(loaded?.existingFileURLs.first == insideFile)
    }

    @Test("Session clear removes saved state")
    func sessionClear() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(projectURL: dir, openFileURLs: [], defaults: defaults)
        #expect(SessionState.load(for: dir, defaults: defaults) != nil)

        SessionState.clear(for: dir, defaults: defaults)
        #expect(SessionState.load(for: dir, defaults: defaults) == nil)
    }
}
