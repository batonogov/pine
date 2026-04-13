//
//  QuickOpenProviderEdgeTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@Suite("QuickOpenProvider Edge Case Tests")
@MainActor
struct QuickOpenProviderEdgeTests {

    // MARK: - relativePath with originalRootPrefix fallback

    @Test func relativePath_fallbackToOriginalRootPrefix() {
        // When resolvedPath doesn't match but originalRootPrefix does
        let result = QuickOpenProvider.relativePath(
            for: URL(fileURLWithPath: "/var/folders/project/src/main.swift"),
            rootPrefix: "/private/var/folders/project/",
            originalRootPrefix: "/var/folders/project/"
        )
        #expect(result == "src/main.swift")
    }

    @Test func relativePath_neitherPrefixMatches() {
        let result = QuickOpenProvider.relativePath(
            for: URL(fileURLWithPath: "/other/path/file.swift"),
            rootPrefix: "/usr/local/",
            originalRootPrefix: "/usr/share/"
        )
        #expect(result == "/other/path/file.swift")
    }

    @Test func relativePath_emptyOriginalRootPrefix() {
        let result = QuickOpenProvider.relativePath(
            for: URL(fileURLWithPath: "/other/path/file.swift"),
            rootPrefix: "/usr/local/",
            originalRootPrefix: ""
        )
        #expect(result == "/other/path/file.swift")
    }

    // MARK: - isSubsequence edge cases

    @Test func isSubsequence_emptyTarget() {
        #expect(!QuickOpenProvider.isSubsequence("a", of: ""))
    }

    @Test func isSubsequence_bothEmpty() {
        #expect(QuickOpenProvider.isSubsequence("", of: ""))
    }

    @Test func isSubsequence_queryLongerThanTarget() {
        #expect(!QuickOpenProvider.isSubsequence("abcdef", of: "abc"))
    }

    @Test func isSubsequence_singleCharMatch() {
        #expect(QuickOpenProvider.isSubsequence("a", of: "abc"))
    }

    @Test func isSubsequence_singleCharNoMatch() {
        #expect(!QuickOpenProvider.isSubsequence("z", of: "abc"))
    }

    // MARK: - fuzzyScore edge cases

    @Test func fuzzyScore_exactMatchScoredHighest() {
        let provider = QuickOpenProvider()
        guard let exact = provider.fuzzyScore(
            queryLower: "main.swift",
            fileNameLower: "main.swift",
            pathLower: "main.swift",
            pathLength: 10
        ) else {
            Issue.record("Expected non-nil exact score")
            return
        }
        guard let prefix = provider.fuzzyScore(
            queryLower: "main",
            fileNameLower: "main.swift",
            pathLower: "main.swift",
            pathLength: 10
        ) else {
            Issue.record("Expected non-nil prefix score")
            return
        }
        #expect(exact > prefix)
    }

    @Test func fuzzyScore_fileSubsequenceMatchLower() {
        let provider = QuickOpenProvider()
        guard let subseq = provider.fuzzyScore(
            queryLower: "mn",
            fileNameLower: "main.swift",
            pathLower: "main.swift",
            pathLength: 10
        ) else {
            Issue.record("Expected non-nil subseq score")
            return
        }
        guard let prefixScore = provider.fuzzyScore(
            queryLower: "mai",
            fileNameLower: "main.swift",
            pathLower: "main.swift",
            pathLength: 10
        ) else {
            Issue.record("Expected non-nil prefix score")
            return
        }
        #expect(prefixScore > subseq)
    }

    @Test func fuzzyScore_pathOnlyMatchLowestScore() {
        let provider = QuickOpenProvider()
        let score = provider.fuzzyScore(
            queryLower: "sr",
            fileNameLower: "file.swift",
            pathLower: "src/file.swift",
            pathLength: 14
        )
        #expect(score != nil)
        if let score {
            // Path-only match: 10 - pathLength
            #expect(score < 50)
        }
    }

    // MARK: - maxIndexDepth

    @Test func maxIndexDepth_isReasonable() {
        #expect(QuickOpenProvider.maxIndexDepth == 100)
    }

    // MARK: - Multiple recordOpened deduplicates

    @Test func recordOpened_deduplicates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineQOEdge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("test.swift")
        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let root = FileNode(url: dir, projectRoot: dir)
        let provider = QuickOpenProvider()
        provider.buildIndex(from: [root], rootURL: dir)

        // Record same file multiple times
        provider.recordOpened(url: fileURL)
        provider.recordOpened(url: fileURL)
        provider.recordOpened(url: fileURL)

        let results = provider.search(query: "")
        // Should only appear once in recent results
        #expect(results.count == 1)
    }

    // MARK: - Empty index search

    @Test func search_emptyIndex_returnsEmpty() {
        let provider = QuickOpenProvider()
        let results = provider.search(query: "anything")
        #expect(results.isEmpty)
    }

    // MARK: - Result struct

    @Test func result_urlEqualsId() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let result = QuickOpenProvider.Result(
            id: url,
            fileName: "test.swift",
            relativePath: "test.swift",
            score: 100
        )
        #expect(result.url == url)
        #expect(result.id == url)
    }
}
