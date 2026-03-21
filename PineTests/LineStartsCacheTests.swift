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

    // MARK: - Incremental update

    @Test func updateInsertNewlineInMiddle() {
        // "abc\ndef\nghi" → insert "\n" at position 5 → "abc\nd\nef\nghi"
        var cache = LineStartsCache(text: "abc\ndef\nghi")
        #expect(cache.lineCount == 3)

        cache.update(editedRange: NSRange(location: 5, length: 1), changeInLength: 1, in: "abc\nd\nef\nghi" as NSString)
        #expect(cache.lineCount == 4)
        #expect(cache.lineNumber(at: 0) == 1) // 'a'
        #expect(cache.lineNumber(at: 4) == 2) // 'd'
        #expect(cache.lineNumber(at: 6) == 3) // 'e'
        #expect(cache.lineNumber(at: 9) == 4) // 'g'
    }

    @Test func updateDeleteNewline() {
        // "abc\ndef\nghi" → delete '\n' at position 3 → "abcdef\nghi"
        var cache = LineStartsCache(text: "abc\ndef\nghi")
        #expect(cache.lineCount == 3)

        cache.update(editedRange: NSRange(location: 3, length: 0), changeInLength: -1, in: "abcdef\nghi" as NSString)
        #expect(cache.lineCount == 2)
        #expect(cache.lineNumber(at: 0) == 1)
        #expect(cache.lineNumber(at: 6) == 1) // '\n'
        #expect(cache.lineNumber(at: 7) == 2) // 'g'
    }

    @Test func updateInsertTextWithoutNewline() {
        // "abc\ndef" → insert "XY" at position 1 → "aXYbc\ndef"
        var cache = LineStartsCache(text: "abc\ndef")
        #expect(cache.lineCount == 2)

        cache.update(editedRange: NSRange(location: 1, length: 2), changeInLength: 2, in: "aXYbc\ndef" as NSString)
        #expect(cache.lineCount == 2)
        #expect(cache.lineNumber(at: 0) == 1)
        #expect(cache.lineNumber(at: 5) == 1) // '\n'
        #expect(cache.lineNumber(at: 6) == 2) // 'd'
    }

    @Test func updateInsertMultipleNewlines() {
        // "abc" → insert "\n\n" at position 1 → "a\n\nbc"
        var cache = LineStartsCache(text: "abc")
        #expect(cache.lineCount == 1)

        cache.update(editedRange: NSRange(location: 1, length: 2), changeInLength: 2, in: "a\n\nbc" as NSString)
        #expect(cache.lineCount == 3)
        #expect(cache.lineNumber(at: 0) == 1)
        #expect(cache.lineNumber(at: 2) == 2)
        #expect(cache.lineNumber(at: 3) == 3)
    }

    @Test func updateReplaceTextWithNewlines() {
        // "abcdef" → replace "cd" (pos 2, len 2) with "X\nY\nZ" → "abX\nY\nZef"
        var cache = LineStartsCache(text: "abcdef")
        #expect(cache.lineCount == 1)

        cache.update(editedRange: NSRange(location: 2, length: 5), changeInLength: 3, in: "abX\nY\nZef" as NSString)
        #expect(cache.lineCount == 3)
        #expect(cache.lineNumber(at: 0) == 1)
        #expect(cache.lineNumber(at: 4) == 2)
        #expect(cache.lineNumber(at: 6) == 3)
    }

    @Test func updateAtBeginning() {
        // "\nabc" → insert "X\n" at position 0 → "X\n\nabc"
        var cache = LineStartsCache(text: "\nabc")
        #expect(cache.lineCount == 2)

        cache.update(editedRange: NSRange(location: 0, length: 2), changeInLength: 2, in: "X\n\nabc" as NSString)
        #expect(cache.lineCount == 3)
        #expect(cache.lineNumber(at: 0) == 1)
        #expect(cache.lineNumber(at: 2) == 2)
        #expect(cache.lineNumber(at: 3) == 3)
    }

    @Test func updateAtEnd() {
        // "abc" → append "\ndef" → "abc\ndef"
        var cache = LineStartsCache(text: "abc")
        #expect(cache.lineCount == 1)

        cache.update(editedRange: NSRange(location: 3, length: 4), changeInLength: 4, in: "abc\ndef" as NSString)
        #expect(cache.lineCount == 2)
        #expect(cache.lineNumber(at: 4) == 2)
    }

    @Test func updateMatchesFullRebuild() {
        // Verify that incremental update produces the same result as full rebuild
        let original = "line1\nline2\nline3\nline4\nline5"
        var cache = LineStartsCache(text: original)

        // Insert "\nNEW" at position 11 (middle of "line2\n")
        let modified = "line1\nline2\nNEW\nline3\nline4\nline5"
        cache.update(
            editedRange: NSRange(location: 12, length: 4),
            changeInLength: 4,
            in: modified as NSString
        )

        let fresh = LineStartsCache(text: modified)
        #expect(cache.lineCount == fresh.lineCount)
        for i in 0..<(modified as NSString).length {
            #expect(cache.lineNumber(at: i) == fresh.lineNumber(at: i), "Mismatch at index \(i)")
        }
    }

    @Test func updateDeleteEntireLine() {
        // "abc\ndef\nghi" → delete "def\n" (pos 4, len 4) → "abc\nghi"
        var cache = LineStartsCache(text: "abc\ndef\nghi")
        #expect(cache.lineCount == 3)

        cache.update(editedRange: NSRange(location: 4, length: 0), changeInLength: -4, in: "abc\nghi" as NSString)
        let fresh = LineStartsCache(text: "abc\nghi")
        #expect(cache.lineCount == fresh.lineCount)
        #expect(cache.lineNumber(at: 4) == fresh.lineNumber(at: 4))
    }

    @Test func updateReplaceNewlineContainingText() {
        // "ab\ncd\nef" → replace "\ncd\n" (pos 2, len 4) with "XY" → "abXYef"
        // Old text has \n inside replaced region — those line starts must be removed
        var cache = LineStartsCache(text: "ab\ncd\nef")
        #expect(cache.lineCount == 3)

        // editedRange in new text: (2, 2), changeInLength = -2
        cache.update(editedRange: NSRange(location: 2, length: 2), changeInLength: -2, in: "abXYef" as NSString)
        let fresh = LineStartsCache(text: "abXYef")
        #expect(cache.lineCount == fresh.lineCount)
        for i in 0..<("abXYef" as NSString).length {
            #expect(cache.lineNumber(at: i) == fresh.lineNumber(at: i), "Mismatch at index \(i)")
        }
    }

    @Test func updateReplaceNewlinesWithNewlines() {
        // "a\nb\nc" → replace "\nb\n" (pos 1, len 3) with "X\nY\nZ\n" → "aX\nY\nZ\nc"
        // Both old and new text contain newlines
        var cache = LineStartsCache(text: "a\nb\nc")
        #expect(cache.lineCount == 3)

        // editedRange in new text: (1, 7), changeInLength = 4
        cache.update(editedRange: NSRange(location: 1, length: 7), changeInLength: 4, in: "aX\nY\nZ\nc" as NSString)
        let fresh = LineStartsCache(text: "aX\nY\nZ\nc")
        #expect(cache.lineCount == fresh.lineCount)
        for i in 0..<("aX\nY\nZ\nc" as NSString).length {
            #expect(cache.lineNumber(at: i) == fresh.lineNumber(at: i), "Mismatch at index \(i)")
        }
    }

    @Test func updateZeroLengthEditedRangeWithPositiveChange() {
        // Simulates NSTextStorage reporting editedRange.length == 0 with positive changeInLength
        // "abc" → insert "X" at position 1 → "aXbc", but editedRange = (1, 0)
        var cache = LineStartsCache(text: "abc")
        #expect(cache.lineCount == 1)

        cache.update(editedRange: NSRange(location: 1, length: 0), changeInLength: 1, in: "aXbc" as NSString)
        let fresh = LineStartsCache(text: "aXbc")
        #expect(cache.lineCount == fresh.lineCount)
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
