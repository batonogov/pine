//
//  DefensiveCodingTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct DefensiveCodingTests {

    // MARK: - FileNode depth limit

    @Test func fileNodeRespectsDepthLimit() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-defensive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var current = tmp
        for i in 0..<150 {
            current = current.appendingPathComponent("d\(i)")
        }
        try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: current.appendingPathComponent("deep.txt").path, contents: nil)

        let root = FileNode(url: tmp, projectRoot: tmp, ignoredPaths: [], maxDepth: 5)
        func containsDeepFile(_ node: FileNode) -> Bool {
            if node.url.lastPathComponent == "deep.txt" { return true }
            return node.children?.contains(where: containsDeepFile) ?? false
        }
        #expect(!containsDeepFile(root))
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

}
