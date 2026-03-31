//
//  IntegrationSearchTests.swift
//  PineTests
//
//  Created by Claude on 24.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("Integration Search Tests")
@MainActor
struct IntegrationSearchTests {

    // MARK: - Helpers

    /// Creates a temporary directory with test files.
    private func createTestProject(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineIntegrationSearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            let fileURL = dir.appendingPathComponent(name)
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Creates a temporary directory with files containing raw Data.
    private func createTestProjectWithData(files: [String: Data]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineIntegrationSearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files {
            let fileURL = dir.appendingPathComponent(name)
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Parallel search correctness across many files

    @Test("Parallel search finds correct results across 200 files")
    func parallelSearchCorrectness200Files() async throws {
        // Generate 200 files, half containing the search term
        var files: [String: String] = [:]
        for index in 0..<200 {
            let name = "file\(String(format: "%03d", index)).swift"
            if index.isMultiple(of: 2) {
                files[name] = "let marker_\(index) = SEARCHTERM\nlet other = 42"
            } else {
                files[name] = "let value_\(index) = 999\nlet nothing = 0"
            }
        }
        let dir = try createTestProject(files: files)
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "SEARCHTERM",
            isCaseSensitive: true,
            rootURL: dir
        )

        // Exactly 100 files should match (even-indexed)
        #expect(groups.count == 100)
        let totalMatches = groups.flatMap(\.matches).count
        #expect(totalMatches == 100)

        // Each matched file should have exactly 1 match on line 1
        for group in groups {
            #expect(group.matches.count == 1)
            #expect(group.matches[0].lineNumber == 1)
        }
    }

    @Test("Parallel search results are sorted by relative path regardless of completion order")
    func parallelSearchResultsSorted() async throws {
        var files: [String: String] = [:]
        let names = ["z_last.txt", "a_first.txt", "m_middle.txt", "b_second.txt"]
        for name in names {
            files[name] = "NEEDLE inside \(name)"
        }
        let dir = try createTestProject(files: files)
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "NEEDLE",
            isCaseSensitive: true,
            rootURL: dir
        )

        #expect(groups.count == 4)

        // Results should be sorted by relativePath (localizedStandardCompare)
        let paths = groups.map(\.relativePath)
        let sorted = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        #expect(paths == sorted)
    }

    // MARK: - Concurrent searches don't conflict

    @Test("Multiple concurrent searches produce independent correct results")
    func concurrentSearchesIndependent() async throws {
        let files: [String: String] = [
            "alpha.txt": "ALPHA content here",
            "beta.txt": "BETA content here",
            "gamma.txt": "GAMMA content here",
            "mixed.txt": "ALPHA and BETA and GAMMA"
        ]
        let dir = try createTestProject(files: files)
        defer { cleanup(dir) }

        // Run 3 searches concurrently with different queries
        async let searchAlpha = ProjectSearchProvider.performSearch(
            query: "ALPHA", isCaseSensitive: true, rootURL: dir
        )
        async let searchBeta = ProjectSearchProvider.performSearch(
            query: "BETA", isCaseSensitive: true, rootURL: dir
        )
        async let searchGamma = ProjectSearchProvider.performSearch(
            query: "GAMMA", isCaseSensitive: true, rootURL: dir
        )

        let (alphaResults, betaResults, gammaResults) = await (searchAlpha, searchBeta, searchGamma)

        // ALPHA: alpha.txt + mixed.txt = 2 files
        #expect(alphaResults.count == 2)
        let alphaFiles = Set(alphaResults.map(\.url.lastPathComponent))
        #expect(alphaFiles.contains("alpha.txt"))
        #expect(alphaFiles.contains("mixed.txt"))

        // BETA: beta.txt + mixed.txt = 2 files
        #expect(betaResults.count == 2)
        let betaFiles = Set(betaResults.map(\.url.lastPathComponent))
        #expect(betaFiles.contains("beta.txt"))
        #expect(betaFiles.contains("mixed.txt"))

        // GAMMA: gamma.txt + mixed.txt = 2 files
        #expect(gammaResults.count == 2)
        let gammaFiles = Set(gammaResults.map(\.url.lastPathComponent))
        #expect(gammaFiles.contains("gamma.txt"))
        #expect(gammaFiles.contains("mixed.txt"))
    }

    @Test("Repeated identical searches produce identical results")
    func repeatedSearchesIdentical() async throws {
        var files: [String: String] = [:]
        for index in 0..<50 {
            files["file\(index).txt"] = "line with TOKEN here\nsecond line\nthird TOKEN line"
        }
        let dir = try createTestProject(files: files)
        defer { cleanup(dir) }

        let result1 = await ProjectSearchProvider.performSearch(
            query: "TOKEN", isCaseSensitive: true, rootURL: dir
        )
        let result2 = await ProjectSearchProvider.performSearch(
            query: "TOKEN", isCaseSensitive: true, rootURL: dir
        )

        // Same number of groups
        #expect(result1.count == result2.count)
        // Same total matches
        #expect(result1.flatMap(\.matches).count == result2.flatMap(\.matches).count)
        // Same relative paths in same order
        #expect(result1.map(\.relativePath) == result2.map(\.relativePath))
    }

    // MARK: - Partial file load (huge files > 10 MB)

    @Test("Partial file load reads only first 1 MB from huge file")
    func partialFileLoadReadsFirst1MB() throws {
        let totalSize = TabManager.hugeFileThreshold + 1 // 10 MB + 1
        let partialSize = TabManager.hugeFilePartialLoadSize  // 1 MB

        // Fill first 1 MB with 'A', rest with 'B'
        var data = Data(repeating: UInt8(ascii: "A"), count: partialSize)
        data.append(Data(repeating: UInt8(ascii: "B"), count: totalSize - partialSize))

        let dir = try createTestProjectWithData(files: ["huge.txt": data])
        defer { cleanup(dir) }

        let handle = try FileHandle(forReadingFrom: dir.appendingPathComponent("huge.txt"))
        defer { handle.closeFile() }
        let partialData = handle.readData(ofLength: partialSize)
        let (decoded, _) = String.Encoding.detect(from: partialData)

        // The decoded content should contain only 'A's, no 'B's
        #expect(decoded.contains("A"))
        #expect(!decoded.contains("B"))
        #expect(partialData.count == partialSize)
    }

    @Test("TabManager marks huge file as truncated with syntax highlighting disabled")
    func tabManagerMarksHugeFileAsTruncated() throws {
        let totalSize = TabManager.hugeFileThreshold + 1
        let data = Data(repeating: UInt8(ascii: "X"), count: totalSize)

        let dir = try createTestProjectWithData(files: ["huge.txt": data])
        defer { cleanup(dir) }

        let manager = TabManager()
        manager.openTab(url: dir.appendingPathComponent("huge.txt"))

        let tab = manager.activeTab
        #expect(tab != nil)
        #expect(tab?.isTruncated == true)
        #expect(tab?.syntaxHighlightingDisabled == true)
        #expect(tab?.fileSizeBytes == totalSize)
    }

    @Test("Saving truncated file is blocked to prevent data corruption")
    func savingTruncatedFileBlocked() throws {
        let totalSize = TabManager.hugeFileThreshold + 1
        let data = Data(repeating: UInt8(ascii: "Z"), count: totalSize)

        let dir = try createTestProjectWithData(files: ["huge.txt": data])
        defer { cleanup(dir) }

        let manager = TabManager()
        manager.openTab(url: dir.appendingPathComponent("huge.txt"))

        #expect(manager.activeTab?.isTruncated == true)

        // trySaveTab should throw for truncated file
        #expect(throws: (any Error).self) {
            try manager.trySaveTab(at: 0)
        }

        // Original file should remain untouched
        let originalData = try Data(contentsOf: dir.appendingPathComponent("huge.txt"))
        #expect(originalData.count == totalSize)
    }

    // MARK: - Search in partial-loaded file

    @Test("Search skips files larger than maxFileSize (1 MB)")
    func searchSkipsFilesLargerThanMaxFileSize() async throws {
        let largeSize = ProjectSearchProvider.maxFileSize + 1 // 1 MB + 1

        // Create a large file that contains a search term in the first bytes
        var content = "FINDME_IN_LARGE_FILE\n"
        let padding = String(repeating: "x", count: largeSize - content.utf8.count)
        content += padding

        let dir = try createTestProject(files: [
            "small.txt": "FINDME_IN_LARGE_FILE is here too",
            "large.txt": content
        ])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "FINDME_IN_LARGE_FILE",
            isCaseSensitive: true,
            rootURL: dir
        )

        // Only small.txt should appear — large.txt exceeds maxFileSize
        #expect(groups.count == 1)
        #expect(groups[0].url.lastPathComponent == "small.txt")
    }

    @Test("Search does not find matches in portion beyond 1 MB boundary")
    func searchDoesNotFindBeyond1MBBoundary() async throws {
        // Place the search term after the 1 MB boundary
        let prefixSize = ProjectSearchProvider.maxFileSize - 10
        let prefix = String(repeating: "a", count: prefixSize)
        let content = prefix + "\nFINDME_BEYOND_BOUNDARY\n"

        // This file is > 1 MB total, so collectSearchableFiles will skip it
        let dir = try createTestProject(files: ["beyond.txt": content])
        defer { cleanup(dir) }

        let groups = await ProjectSearchProvider.performSearch(
            query: "FINDME_BEYOND_BOUNDARY",
            isCaseSensitive: true,
            rootURL: dir
        )

        // File exceeds maxFileSize, search should skip it entirely
        #expect(groups.isEmpty)
    }

    @Test("Partial load content ends within first 1 MB and appends truncation notice")
    func partialLoadContentHasTruncationNotice() throws {
        let totalSize = TabManager.hugeFileThreshold + 100
        // Write recognizable content at the start
        let marker = "START_OF_HUGE_FILE"
        var data = Data(marker.utf8)
        data.append(Data(repeating: UInt8(ascii: "."), count: totalSize - data.count))

        let dir = try createTestProjectWithData(files: ["huge.txt": data])
        defer { cleanup(dir) }

        let manager = TabManager()
        manager.openTab(url: dir.appendingPathComponent("huge.txt"))

        let tab = manager.activeTab
        #expect(tab != nil)
        // Content should start with our marker
        #expect(tab?.content.hasPrefix(marker) == true)
        // Content should end with truncation notice
        #expect(tab?.content.contains("File truncated") == true)
    }

    @Test("File at exact 10 MB boundary triggers partial load")
    func fileAtExact10MBBoundaryTriggersPartialLoad() throws {
        let exactSize = TabManager.hugeFileThreshold // exactly 10 MB
        let data = Data(repeating: UInt8(ascii: "Q"), count: exactSize)

        let dir = try createTestProjectWithData(files: ["exact.txt": data])
        defer { cleanup(dir) }

        let manager = TabManager()
        manager.openTab(url: dir.appendingPathComponent("exact.txt"))

        let tab = manager.activeTab
        #expect(tab != nil)
        #expect(tab?.isTruncated == true)
        #expect(tab?.syntaxHighlightingDisabled == true)
    }

    @Test("File just below 10 MB does not trigger partial load")
    func fileBelowThresholdNotTruncated() throws {
        let belowSize = TabManager.hugeFileThreshold - 1
        // Use valid UTF-8 text content
        let line = String(repeating: "q", count: 100) + "\n"
        let lineData = Data(line.utf8)
        let lineCount = belowSize / lineData.count
        var data = Data()
        for _ in 0..<lineCount {
            data.append(lineData)
        }
        // Pad remaining bytes
        let remaining = belowSize - data.count
        if remaining > 0 {
            data.append(Data(String(repeating: "q", count: remaining).utf8))
        }

        let dir = try createTestProjectWithData(files: ["notbig.txt": data])
        defer { cleanup(dir) }

        let manager = TabManager()
        // This file is below hugeFileThreshold but above largeFileThreshold
        // openTab shows an NSAlert for large files, so use the explicit override
        manager.openTab(url: dir.appendingPathComponent("notbig.txt"), syntaxHighlightingDisabled: false)

        let tab = manager.activeTab
        #expect(tab != nil)
        #expect(tab?.isTruncated == false)
    }
}
