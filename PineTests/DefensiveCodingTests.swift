//
//  DefensiveCodingTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct DefensiveCodingTests {

    // MARK: - QuickOpenProvider depth limit

    @Test func collectFilesRespectsDepthLimit() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-defensive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create a deeply nested directory: depth 0/1/2/.../150
        var current = tmp
        for i in 0..<150 {
            current = current.appendingPathComponent("d\(i)")
        }
        try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        // Put a file at the bottom
        FileManager.default.createFile(atPath: current.appendingPathComponent("deep.txt").path, contents: nil)

        let root = FileNode(url: tmp, projectRoot: tmp, ignoredPaths: [], maxDepth: 5)
        let provider = QuickOpenProvider()
        provider.buildIndex(from: [root], rootURL: tmp)

        // The file at depth 150 should NOT be indexed because FileNode stops at maxDepth 5
        let deepFiles = provider.fileIndex.filter { $0.lastPathComponent == "deep.txt" }
        #expect(deepFiles.isEmpty)
    }

    @Test func collectFilesWithDepthLimitDoesNotCrash() {
        let provider = QuickOpenProvider()
        // Building index from empty roots should not crash
        provider.buildIndex(from: [], rootURL: URL(fileURLWithPath: "/nonexistent"))
        #expect(provider.fileIndex.isEmpty)
    }

    // MARK: - BracketMatcher iteration limit

    @Test func bracketMatcherHandlesLargeInput() {
        // Create a string with 50,000 unmatched opening brackets
        let text = String(repeating: "(", count: 50_000)
        // Should not hang or crash — returns nil for unmatched bracket
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result == nil)
    }

    @Test func bracketMatcherMaxIterationsReturnsNil() {
        // Create a string with an opening bracket, then maxIterations+1 non-bracket chars, then closing
        // The match should fail because the scan exceeds the iteration limit
        let padding = String(repeating: "x", count: BracketMatcher.maxScanIterations + 1)
        let text = "(" + padding + ")"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        // Match should be nil because scan was cut short by iteration limit
        #expect(result == nil)
    }

    @Test func bracketMatcherWithinLimitFindsMatch() {
        // Within the limit, matching should still work
        let padding = String(repeating: "x", count: 100)
        let text = "(" + padding + ")"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result != nil)
        #expect(result?.opener == 0)
        #expect(result?.closer == 101)
    }

    // MARK: - FoldRangeCalculator stack limit

    @Test func foldCalculatorHandlesDeeplyNestedBrackets() {
        // Create 600 levels of nested braces (each on its own line)
        var text = ""
        for _ in 0..<600 {
            text += "{\n"
        }
        for _ in 0..<600 {
            text += "}\n"
        }
        // Should not crash; the stack is bounded by maxStackDepth
        let results = FoldRangeCalculator.calculate(text: text)
        // Some fold ranges should exist, but inner ones beyond stack limit are ignored
        #expect(results.count <= FoldRangeCalculator.maxStackDepth)
    }

    // MARK: - TabManager bounds assertions

    @Test func closeTabWithInvalidIDIsNoOp() {
        let manager = TabManager()
        // Closing a non-existent tab should not crash
        manager.closeTab(id: UUID())
        #expect(manager.tabs.isEmpty)
    }

    @Test func updateContentWithNoActiveTabIsNoOp() {
        let manager = TabManager()
        // Updating content with no active tab should not crash
        manager.updateContent("hello")
        #expect(manager.tabs.isEmpty)
    }

    @Test func trySaveTabAtValidIndex() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-tab-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "hello".write(to: tmp, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: tmp)
        #expect(manager.tabs.count == 1)

        // Saving at valid index should work
        let result = try manager.trySaveTab(at: 0)
        #expect(result == true)
    }

    // MARK: - ProjectSearchProvider max results guard

    @Test func searchRespectsMaxResultsPerFile() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-search-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create a file with many matches
        let line = "match match match match match\n"
        let content = String(repeating: line, count: 200)
        try? content.write(to: tmp, atomically: true, encoding: .utf8)

        let matches = ProjectSearchProvider.searchFile(
            at: tmp, query: "match", isCaseSensitive: false,
            remainingCapacity: 50
        )
        #expect(matches.count <= 50)
    }
}
