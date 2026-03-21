//
//  MultiCursorLogicTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct MultiCursorLogicTests {

    // MARK: - Cursor model

    @Test func cursorWithoutSelection() {
        let cursor = MultiCursorLogic.Cursor(location: 5)
        #expect(cursor.range == NSRange(location: 5, length: 0))
        #expect(!cursor.hasSelection)
    }

    @Test func cursorWithSelection() {
        let cursor = MultiCursorLogic.Cursor(location: 3, selection: NSRange(location: 3, length: 4))
        #expect(cursor.hasSelection)
        #expect(cursor.selection == NSRange(location: 3, length: 4))
    }

    // MARK: - Insert text at multiple cursors

    @Test func insertAtSingleCursor() {
        let text = "hello world"
        let cursors = [MultiCursorLogic.Cursor(location: 5)]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: "X")
        #expect(result.newText == "helloX world")
        #expect(result.newCursors.count == 1)
        #expect(result.newCursors[0].location == 6)
    }

    @Test func insertAtTwoCursors() {
        // "ab|cd|ef" — cursors at positions 2 and 4
        let text = "abcdef"
        let cursors = [
            MultiCursorLogic.Cursor(location: 2),
            MultiCursorLogic.Cursor(location: 4)
        ]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: "X")
        #expect(result.newText == "abXcdXef")
        #expect(result.newCursors.count == 2)
        #expect(result.newCursors[0].location == 3)
        #expect(result.newCursors[1].location == 6)
    }

    @Test func insertAtThreeCursors() {
        let text = "aaa"
        let cursors = [
            MultiCursorLogic.Cursor(location: 0),
            MultiCursorLogic.Cursor(location: 1),
            MultiCursorLogic.Cursor(location: 2)
        ]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: ".")
        #expect(result.newText == ".a.a.a")
        #expect(result.newCursors.count == 3)
        #expect(result.newCursors[0].location == 1)
        #expect(result.newCursors[1].location == 3)
        #expect(result.newCursors[2].location == 5)
    }

    @Test func insertReplacesSelection() {
        let text = "hello world"
        let cursors = [
            MultiCursorLogic.Cursor(location: 0, selection: NSRange(location: 0, length: 5))
        ]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: "hi")
        #expect(result.newText == "hi world")
        #expect(result.newCursors[0].location == 2)
        #expect(!result.newCursors[0].hasSelection)
    }

    @Test func insertReplacesMultipleSelections() {
        // "hello world hello" — select both "hello"
        let text = "hello world hello"
        let cursors = [
            MultiCursorLogic.Cursor(location: 0, selection: NSRange(location: 0, length: 5)),
            MultiCursorLogic.Cursor(location: 12, selection: NSRange(location: 12, length: 5))
        ]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: "hi")
        #expect(result.newText == "hi world hi")
        #expect(result.newCursors[0].location == 2)
        #expect(result.newCursors[1].location == 11)
    }

    @Test func insertMultiCharString() {
        let text = "ab"
        let cursors = [
            MultiCursorLogic.Cursor(location: 1),
            MultiCursorLogic.Cursor(location: 2)
        ]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: "XYZ")
        #expect(result.newText == "aXYZbXYZ")
        #expect(result.newCursors[0].location == 4)
        #expect(result.newCursors[1].location == 8)
    }

    // MARK: - Delete backward at multiple cursors

    @Test func deleteBackwardSingleCursor() {
        let text = "hello"
        let cursors = [MultiCursorLogic.Cursor(location: 3)]
        let result = MultiCursorLogic.deleteBackward(in: text, cursors: cursors)
        #expect(result.newText == "helo")
        #expect(result.newCursors[0].location == 2)
    }

    @Test func deleteBackwardAtStart() {
        let text = "hello"
        let cursors = [MultiCursorLogic.Cursor(location: 0)]
        let result = MultiCursorLogic.deleteBackward(in: text, cursors: cursors)
        #expect(result.newText == "hello")
        #expect(result.newCursors[0].location == 0)
    }

    @Test func deleteBackwardMultipleCursors() {
        // "abcdef" — cursors at 2 and 5
        let text = "abcdef"
        let cursors = [
            MultiCursorLogic.Cursor(location: 2),
            MultiCursorLogic.Cursor(location: 5)
        ]
        let result = MultiCursorLogic.deleteBackward(in: text, cursors: cursors)
        #expect(result.newText == "acdf")
        #expect(result.newCursors[0].location == 1)
        #expect(result.newCursors[1].location == 3)
    }

    @Test func deleteBackwardWithSelection() {
        let text = "hello world"
        let cursors = [
            MultiCursorLogic.Cursor(location: 0, selection: NSRange(location: 0, length: 5))
        ]
        let result = MultiCursorLogic.deleteBackward(in: text, cursors: cursors)
        #expect(result.newText == " world")
        #expect(result.newCursors[0].location == 0)
    }

    // MARK: - Delete forward at multiple cursors

    @Test func deleteForwardSingleCursor() {
        let text = "hello"
        let cursors = [MultiCursorLogic.Cursor(location: 2)]
        let result = MultiCursorLogic.deleteForward(in: text, cursors: cursors)
        #expect(result.newText == "helo")
        #expect(result.newCursors[0].location == 2)
    }

    @Test func deleteForwardAtEnd() {
        let text = "hello"
        let cursors = [MultiCursorLogic.Cursor(location: 5)]
        let result = MultiCursorLogic.deleteForward(in: text, cursors: cursors)
        #expect(result.newText == "hello")
        #expect(result.newCursors[0].location == 5)
    }

    @Test func deleteForwardMultipleCursors() {
        let text = "abcdef"
        let cursors = [
            MultiCursorLogic.Cursor(location: 1),
            MultiCursorLogic.Cursor(location: 4)
        ]
        let result = MultiCursorLogic.deleteForward(in: text, cursors: cursors)
        #expect(result.newText == "acdf")
        #expect(result.newCursors[0].location == 1)
        #expect(result.newCursors[1].location == 3)
    }

    // MARK: - Select next occurrence (Cmd+D)

    @Test func selectNextOccurrenceFromWord() {
        let text = "foo bar foo baz foo"
        // Cursor inside first "foo" (no selection) → selects "foo"
        let cursors = [MultiCursorLogic.Cursor(location: 1)]
        let result = MultiCursorLogic.selectNextOccurrence(in: text, cursors: cursors)
        #expect(result.count == 1)
        #expect(result[0].selection == NSRange(location: 0, length: 3))
    }

    @Test func selectNextOccurrenceAddsSecond() {
        let text = "foo bar foo baz foo"
        // First "foo" selected → adds second "foo"
        let cursors = [
            MultiCursorLogic.Cursor(location: 3, selection: NSRange(location: 0, length: 3))
        ]
        let result = MultiCursorLogic.selectNextOccurrence(in: text, cursors: cursors)
        #expect(result.count == 2)
        #expect(result[0].selection == NSRange(location: 0, length: 3))
        #expect(result[1].selection == NSRange(location: 8, length: 3))
    }

    @Test func selectNextOccurrenceAddsThird() {
        let text = "foo bar foo baz foo"
        let cursors = [
            MultiCursorLogic.Cursor(location: 3, selection: NSRange(location: 0, length: 3)),
            MultiCursorLogic.Cursor(location: 11, selection: NSRange(location: 8, length: 3))
        ]
        let result = MultiCursorLogic.selectNextOccurrence(in: text, cursors: cursors)
        #expect(result.count == 3)
        #expect(result[2].selection == NSRange(location: 16, length: 3))
    }

    @Test func selectNextOccurrenceWrapsAround() {
        let text = "foo bar foo"
        // Last "foo" selected, wraps to find the first one
        let cursors = [
            MultiCursorLogic.Cursor(location: 11, selection: NSRange(location: 8, length: 3))
        ]
        let result = MultiCursorLogic.selectNextOccurrence(in: text, cursors: cursors)
        #expect(result.count == 2)
        #expect(result[0].selection == NSRange(location: 0, length: 3))
        #expect(result[1].selection == NSRange(location: 8, length: 3))
    }

    @Test func selectNextOccurrenceNoMoreMatches() {
        let text = "foo bar baz"
        let cursors = [
            MultiCursorLogic.Cursor(location: 3, selection: NSRange(location: 0, length: 3))
        ]
        let result = MultiCursorLogic.selectNextOccurrence(in: text, cursors: cursors)
        // No more "foo" → cursors unchanged
        #expect(result.count == 1)
    }

    @Test func selectNextOccurrenceCaseSensitive() {
        let text = "foo Foo FOO foo"
        let cursors = [
            MultiCursorLogic.Cursor(location: 3, selection: NSRange(location: 0, length: 3))
        ]
        let result = MultiCursorLogic.selectNextOccurrence(in: text, cursors: cursors)
        #expect(result.count == 2)
        #expect(result[1].selection == NSRange(location: 12, length: 3))
    }

    // MARK: - Split selection into lines (Cmd+Shift+L)

    @Test func splitSelectionIntoLines() {
        let text = "line1\nline2\nline3"
        // Select all text
        let cursors = [
            MultiCursorLogic.Cursor(location: 0, selection: NSRange(location: 0, length: 17))
        ]
        let result = MultiCursorLogic.splitSelectionIntoLines(in: text, cursors: cursors)
        #expect(result.count == 3)
        // Each cursor at end of its line
        #expect(result[0].location == 5)
        #expect(result[1].location == 11)
        #expect(result[2].location == 17)
    }

    @Test func splitSelectionPartialLines() {
        let text = "aaa\nbbb\nccc"
        // Select from middle of line1 to middle of line3
        let cursors = [
            MultiCursorLogic.Cursor(location: 1, selection: NSRange(location: 1, length: 9))
        ]
        let result = MultiCursorLogic.splitSelectionIntoLines(in: text, cursors: cursors)
        #expect(result.count == 3)
        #expect(result[0].location == 3) // end of "aaa"
        #expect(result[1].location == 7) // end of "bbb"
        #expect(result[2].location == 10) // position 1+9=10 (within "ccc")
    }

    @Test func splitSelectionSingleLineNoop() {
        let text = "hello world"
        let cursors = [
            MultiCursorLogic.Cursor(location: 0, selection: NSRange(location: 0, length: 5))
        ]
        let result = MultiCursorLogic.splitSelectionIntoLines(in: text, cursors: cursors)
        // Single line → no split, keep original
        #expect(result.count == 1)
    }

    @Test func splitSelectionNoCursorSelection() {
        let text = "hello\nworld"
        let cursors = [MultiCursorLogic.Cursor(location: 3)]
        let result = MultiCursorLogic.splitSelectionIntoLines(in: text, cursors: cursors)
        // No selection → no split
        #expect(result.count == 1)
        #expect(result[0].location == 3)
    }

    // MARK: - Add cursor (Option+Click)

    @Test func addCursorAtNewPosition() {
        let cursors = [MultiCursorLogic.Cursor(location: 5)]
        let result = MultiCursorLogic.addCursor(to: cursors, at: 10)
        #expect(result.count == 2)
        #expect(result[0].location == 5)
        #expect(result[1].location == 10)
    }

    @Test func addCursorSortedByLocation() {
        let cursors = [MultiCursorLogic.Cursor(location: 10)]
        let result = MultiCursorLogic.addCursor(to: cursors, at: 3)
        #expect(result.count == 2)
        #expect(result[0].location == 3)
        #expect(result[1].location == 10)
    }

    @Test func addCursorRemovesDuplicate() {
        let cursors = [MultiCursorLogic.Cursor(location: 5)]
        let result = MultiCursorLogic.addCursor(to: cursors, at: 5)
        // Clicking on existing cursor removes it → back to single
        #expect(result.count == 1)
    }

    // MARK: - Merge overlapping cursors

    @Test func mergeOverlappingSelections() {
        let cursors = [
            MultiCursorLogic.Cursor(location: 3, selection: NSRange(location: 0, length: 5)),
            MultiCursorLogic.Cursor(location: 7, selection: NSRange(location: 3, length: 5))
        ]
        let result = MultiCursorLogic.mergeCursors(cursors)
        #expect(result.count == 1)
        #expect(result[0].selection == NSRange(location: 0, length: 8))
    }

    @Test func mergeAdjacentCursorsWithoutSelection() {
        let cursors = [
            MultiCursorLogic.Cursor(location: 5),
            MultiCursorLogic.Cursor(location: 5)
        ]
        let result = MultiCursorLogic.mergeCursors(cursors)
        #expect(result.count == 1)
    }

    @Test func noMergeForDistantCursors() {
        let cursors = [
            MultiCursorLogic.Cursor(location: 2),
            MultiCursorLogic.Cursor(location: 10)
        ]
        let result = MultiCursorLogic.mergeCursors(cursors)
        #expect(result.count == 2)
    }

    // MARK: - Edge cases

    @Test func insertInEmptyText() {
        let text = ""
        let cursors = [MultiCursorLogic.Cursor(location: 0)]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: "X")
        #expect(result.newText == "X")
        #expect(result.newCursors[0].location == 1)
    }

    @Test func insertAtEndOfText() {
        let text = "abc"
        let cursors = [MultiCursorLogic.Cursor(location: 3)]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: "!")
        #expect(result.newText == "abc!")
        #expect(result.newCursors[0].location == 4)
    }

    @Test func deleteBackwardEmptyText() {
        let text = ""
        let cursors = [MultiCursorLogic.Cursor(location: 0)]
        let result = MultiCursorLogic.deleteBackward(in: text, cursors: cursors)
        #expect(result.newText == "")
        #expect(result.newCursors[0].location == 0)
    }

    // MARK: - Unicode / emoji

    @Test func insertWithEmoji() {
        let text = "a🎉b"
        // 🎉 is 2 UTF-16 code units, so 'b' is at offset 4
        let cursors = [
            MultiCursorLogic.Cursor(location: 1),
            MultiCursorLogic.Cursor(location: 4)
        ]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: "X")
        #expect(result.newText == "aX🎉bX")
        #expect(result.newCursors[0].location == 2)
        #expect(result.newCursors[1].location == 6)
    }

    @Test func selectNextOccurrenceWithEmoji() {
        let text = "🎉foo🎉foo"
        // Select first "foo" (starts at offset 2, 🎉 is 2 UTF-16 units)
        let cursors = [
            MultiCursorLogic.Cursor(location: 5, selection: NSRange(location: 2, length: 3))
        ]
        let result = MultiCursorLogic.selectNextOccurrence(in: text, cursors: cursors)
        #expect(result.count == 2)
        #expect(result[1].selection == NSRange(location: 7, length: 3))
    }

    // MARK: - Cursor sorting

    @Test func cursorsAlwaysSorted() {
        let text = "abcdef"
        let cursors = [
            MultiCursorLogic.Cursor(location: 5),
            MultiCursorLogic.Cursor(location: 1),
            MultiCursorLogic.Cursor(location: 3)
        ]
        let result = MultiCursorLogic.insert(in: text, cursors: cursors, string: ".")
        // Cursors processed in sorted order
        #expect(result.newText == "a.bc.de.f")
        #expect(result.newCursors[0].location == 2)
        #expect(result.newCursors[1].location == 5)
        #expect(result.newCursors[2].location == 8)
    }

    // MARK: - Word boundary detection

    @Test func wordAtPositionMiddleOfWord() {
        let text = "hello world"
        let range = MultiCursorLogic.wordRange(in: text, at: 2)
        #expect(range == NSRange(location: 0, length: 5)) // "hello"
    }

    @Test func wordAtPositionStartOfWord() {
        let text = "hello world"
        let range = MultiCursorLogic.wordRange(in: text, at: 6)
        #expect(range == NSRange(location: 6, length: 5)) // "world"
    }

    @Test func wordAtPositionOnSpace() {
        let text = "hello world"
        let range = MultiCursorLogic.wordRange(in: text, at: 5)
        // On a non-word character → nil or empty
        #expect(range == nil)
    }

    @Test func wordAtPositionEmptyText() {
        let text = ""
        let range = MultiCursorLogic.wordRange(in: text, at: 0)
        #expect(range == nil)
    }
}
