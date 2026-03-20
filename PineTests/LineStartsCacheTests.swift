//
//  LineStartsCacheTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct LineStartsCacheTests {

    // MARK: - Basic construction

    @Test func emptyText() {
        let cache = LineStartsCache(text: "")
        #expect(cache.lineCount == 1)
        #expect(cache.lineNumber(at: 0) == 1)
    }

    @Test func singleLine() {
        let cache = LineStartsCache(text: "hello")
        #expect(cache.lineCount == 1)
        #expect(cache.lineNumber(at: 0) == 1)
        #expect(cache.lineNumber(at: 4) == 1)
    }

    @Test func multipleLines() {
        let cache = LineStartsCache(text: "abc\ndef\nghi")
        #expect(cache.lineCount == 3)
        #expect(cache.lineNumber(at: 0) == 1) // 'a'
        #expect(cache.lineNumber(at: 3) == 1) // '\n'
        #expect(cache.lineNumber(at: 4) == 2) // 'd'
        #expect(cache.lineNumber(at: 8) == 3) // 'g'
    }

    @Test func trailingNewline() {
        let cache = LineStartsCache(text: "abc\n")
        #expect(cache.lineCount == 2)
        #expect(cache.lineNumber(at: 3) == 1) // '\n'
        #expect(cache.lineNumber(at: 4) == 2) // past end of '\n'
    }

    @Test func onlyNewlines() {
        let cache = LineStartsCache(text: "\n\n\n")
        #expect(cache.lineCount == 4)
        #expect(cache.lineNumber(at: 0) == 1)
        #expect(cache.lineNumber(at: 1) == 2)
        #expect(cache.lineNumber(at: 2) == 3)
        #expect(cache.lineNumber(at: 3) == 4)
    }

    // MARK: - Boundary conditions

    @Test func lineNumberAtCharIndexBeyondEnd() {
        let cache = LineStartsCache(text: "abc\ndef")
        // Beyond end should clamp to last line
        #expect(cache.lineNumber(at: 100) == 2)
    }

    // MARK: - Performance characteristic — binary search

    @Test func largeTextPerformance() {
        // Build a text with 10_000 lines
        let line = String(repeating: "x", count: 80) + "\n"
        let text = String(repeating: line, count: 10_000)
        let cache = LineStartsCache(text: text)
        #expect(cache.lineCount == 10_001) // 10_000 newlines → 10_001 lines

        // Last line
        let lastLineStart = 10_000 * 81  // each line is 81 chars (80 + \n)
        #expect(cache.lineNumber(at: lastLineStart) == 10_001)

        // Mid-file
        let midChar = 5000 * 81
        #expect(cache.lineNumber(at: midChar) == 5001)
    }
}
