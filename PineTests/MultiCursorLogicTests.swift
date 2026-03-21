//
//  MultiCursorLogicTests.swift
//  PineTests
//
//  Unit tests for MultiCursorLogic: findNextOccurrence, mergeOverlapping,
//  splitSelectionIntoLineRanges, and newCursorPositions.
//

import Testing
import AppKit
@testable import Pine

struct MultiCursorLogicTests {

    // MARK: - findNextOccurrence

    @Test func findNext_returnsFirstOccurrenceAfterOffset() {
        let text = "foo bar foo baz" as NSString
        let result = MultiCursorLogic.findNextOccurrence(of: "foo", in: text, after: 3)
        #expect(result?.location == 8)
        #expect(result?.length == 3)
    }

    @Test func findNext_wrapsAroundToBeginning() {
        let text = "foo bar baz" as NSString
        // searchStart is past the only occurrence
        let result = MultiCursorLogic.findNextOccurrence(of: "foo", in: text, after: 3)
        #expect(result?.location == 0)
        #expect(result?.length == 3)
    }

    @Test func findNext_returnsNilForEmptySearchText() {
        let text = "hello world" as NSString
        let result = MultiCursorLogic.findNextOccurrence(of: "", in: text, after: 0)
        #expect(result == nil)
    }

    @Test func findNext_returnsNilForEmptyDocument() {
        let text = "" as NSString
        let result = MultiCursorLogic.findNextOccurrence(of: "foo", in: text, after: 0)
        #expect(result == nil)
    }

    @Test func findNext_returnsNilWhenTextNotPresent() {
        let text = "hello world" as NSString
        let result = MultiCursorLogic.findNextOccurrence(of: "xyz", in: text, after: 0)
        #expect(result == nil)
    }

    @Test func findNext_findsSingleOccurrenceFromStart() {
        let text = "hello world" as NSString
        let result = MultiCursorLogic.findNextOccurrence(of: "world", in: text, after: 0)
        #expect(result?.location == 6)
        #expect(result?.length == 5)
    }

    @Test func findNext_handlesSearchStartAtEnd() {
        let text = "abc" as NSString
        // searchStart == length → wraps to find from beginning
        let result = MultiCursorLogic.findNextOccurrence(of: "abc", in: text, after: 3)
        #expect(result?.location == 0)
    }

    @Test func findNext_chainsThreeOccurrences() {
        let text = "x x x" as NSString
        let r1 = MultiCursorLogic.findNextOccurrence(of: "x", in: text, after: 0)
        #expect(r1?.location == 0)

        let after1 = r1.map { NSMaxRange($0) } ?? 1
        let r2 = MultiCursorLogic.findNextOccurrence(of: "x", in: text, after: after1)
        #expect(r2?.location == 2)

        let after2 = r2.map { NSMaxRange($0) } ?? 3
        let r3 = MultiCursorLogic.findNextOccurrence(of: "x", in: text, after: after2)
        #expect(r3?.location == 4)

        // Wrap around
        let after3 = r3.map { NSMaxRange($0) } ?? 5
        let r4 = MultiCursorLogic.findNextOccurrence(of: "x", in: text, after: after3)
        #expect(r4?.location == 0)
    }

    @Test func findNext_isCaseSensitive() {
        let text = "Foo foo FOO" as NSString
        let result = MultiCursorLogic.findNextOccurrence(of: "foo", in: text, after: 0)
        #expect(result?.location == 4)
    }

    // MARK: - mergeOverlapping

    @Test func merge_singleRangeReturnsItself() {
        let ranges = [NSRange(location: 5, length: 3)]
        let result = MultiCursorLogic.mergeOverlapping(ranges)
        #expect(result.count == 1)
        #expect(result[0].location == 5 && result[0].length == 3)
    }

    @Test func merge_nonOverlappingRangesPreservedSorted() {
        let ranges = [NSRange(location: 10, length: 2), NSRange(location: 0, length: 3)]
        let result = MultiCursorLogic.mergeOverlapping(ranges)
        #expect(result.count == 2)
        #expect(result[0].location == 0)
        #expect(result[1].location == 10)
    }

    @Test func merge_overlappingRangesMerged() {
        let ranges = [NSRange(location: 0, length: 5), NSRange(location: 3, length: 5)]
        let result = MultiCursorLogic.mergeOverlapping(ranges)
        #expect(result.count == 1)
        #expect(result[0].location == 0)
        #expect(result[0].length == 8)
    }

    @Test func merge_adjacentRangesMerged() {
        let ranges = [NSRange(location: 0, length: 3), NSRange(location: 3, length: 3)]
        let result = MultiCursorLogic.mergeOverlapping(ranges)
        #expect(result.count == 1)
        #expect(result[0].location == 0)
        #expect(result[0].length == 6)
    }

    @Test func merge_duplicateCursorsMerged() {
        let ranges = [NSRange(location: 5, length: 0), NSRange(location: 5, length: 0)]
        let result = MultiCursorLogic.mergeOverlapping(ranges)
        #expect(result.count == 1)
        #expect(result[0].location == 5 && result[0].length == 0)
    }

    @Test func merge_threeRangesPartiallyOverlapping() {
        let ranges = [
            NSRange(location: 0, length: 4),
            NSRange(location: 2, length: 4),
            NSRange(location: 10, length: 3)
        ]
        let result = MultiCursorLogic.mergeOverlapping(ranges)
        #expect(result.count == 2)
        #expect(result[0].location == 0 && result[0].length == 6)
        #expect(result[1].location == 10 && result[1].length == 3)
    }

    @Test func merge_emptyInputReturnsEmpty() {
        let result = MultiCursorLogic.mergeOverlapping([])
        #expect(result.isEmpty)
    }

    // MARK: - splitSelectionIntoLineRanges

    @Test func split_emptySelectionReturnsItself() {
        let text = "hello\nworld" as NSString
        let selection = NSRange(location: 3, length: 0)
        let result = MultiCursorLogic.splitSelectionIntoLineRanges(selection: selection, in: text)
        #expect(result.count == 1)
        #expect(result[0].location == 3 && result[0].length == 0)
    }

    @Test func split_singleLineSelectionReturnsSingleCursor() {
        let text = "hello\nworld" as NSString
        let selection = NSRange(location: 0, length: 5)  // "hello"
        let result = MultiCursorLogic.splitSelectionIntoLineRanges(selection: selection, in: text)
        // Cursor at end of "hello" (before newline), which is position 5
        #expect(result.count == 1)
        #expect(result[0].location == 5 && result[0].length == 0)
    }

    @Test func split_twoLineSelectionReturnsTwoCursors() {
        let text = "hello\nworld\n" as NSString
        // Select "hello\nworld"
        let selection = NSRange(location: 0, length: 11)
        let result = MultiCursorLogic.splitSelectionIntoLineRanges(selection: selection, in: text)
        #expect(result.count == 2)
        // First cursor: end of "hello" (position 5)
        #expect(result[0].location == 5 && result[0].length == 0)
        // Second cursor: end of "world" (position 11)
        #expect(result[1].location == 11 && result[1].length == 0)
    }

    @Test func split_threeLineSelection() {
        let text = "abc\ndef\nghi\n" as NSString
        let selection = NSRange(location: 0, length: 11)  // "abc\ndef\nghi"
        let result = MultiCursorLogic.splitSelectionIntoLineRanges(selection: selection, in: text)
        #expect(result.count == 3)
        #expect(result[0].location == 3)  // end of "abc"
        #expect(result[1].location == 7)  // end of "def"
        #expect(result[2].location == 11) // end of "ghi"
    }

    @Test func split_selectionDoesNotIncludeNewline() {
        let text = "line1\nline2" as NSString
        // "line1\n" - selection includes the newline
        let selection = NSRange(location: 0, length: 6)
        let result = MultiCursorLogic.splitSelectionIntoLineRanges(selection: selection, in: text)
        // Cursor should be at position 5 (before the newline), clamped to selection end (6)
        #expect(result[0].location <= 6)
    }

    // MARK: - newCursorPositions

    @Test func newCursorPositions_singleInsertionAtCursor() {
        // Insert 1 char at position 5 (cursor, no selection)
        let edits: [(range: NSRange, replacementLength: Int, cursorOffset: Int)] = [
            (range: NSRange(location: 5, length: 0), replacementLength: 1, cursorOffset: 1)
        ]
        let result = MultiCursorLogic.newCursorPositions(edits: edits)
        #expect(result == [6])
    }

    @Test func newCursorPositions_threeInsertionsEndToStart() {
        // Three cursors at [5, 10, 15], insert 1 char each
        // edits must be sorted end-to-start
        let edits: [(range: NSRange, replacementLength: Int, cursorOffset: Int)] = [
            (range: NSRange(location: 15, length: 0), replacementLength: 1, cursorOffset: 1),
            (range: NSRange(location: 10, length: 0), replacementLength: 1, cursorOffset: 1),
            (range: NSRange(location: 5, length: 0), replacementLength: 1, cursorOffset: 1)
        ]
        let result = MultiCursorLogic.newCursorPositions(edits: edits)
        #expect(result == [6, 12, 18])
    }

    @Test func newCursorPositions_deleteBackward() {
        // Two cursors at [5, 10], delete backward (each deletes char at loc-1)
        // Ranges are (4,1) and (9,1), sorted end-to-start
        let edits: [(range: NSRange, replacementLength: Int, cursorOffset: Int)] = [
            (range: NSRange(location: 9, length: 1), replacementLength: 0, cursorOffset: 0),
            (range: NSRange(location: 4, length: 1), replacementLength: 0, cursorOffset: 0)
        ]
        let result = MultiCursorLogic.newCursorPositions(edits: edits)
        // After deleting at 9: cursor at 9. After deleting at 4: cursor at 4, adjust 9→8.
        #expect(result == [4, 8])
    }

    @Test func newCursorPositions_replaceSelectionWithText() {
        // Cursor with 3-char selection at [2,3], replaced by 1 char
        // edits sorted end-to-start (only one edit)
        let edits: [(range: NSRange, replacementLength: Int, cursorOffset: Int)] = [
            (range: NSRange(location: 2, length: 3), replacementLength: 1, cursorOffset: 1)
        ]
        let result = MultiCursorLogic.newCursorPositions(edits: edits)
        #expect(result == [3])
    }

    @Test func newCursorPositions_noOpAtDocumentStart() {
        // Cursor at position 0, nothing to delete (no-op represented as (0,0) → 0 replacement)
        let edits: [(range: NSRange, replacementLength: Int, cursorOffset: Int)] = [
            (range: NSRange(location: 0, length: 0), replacementLength: 0, cursorOffset: 0)
        ]
        let result = MultiCursorLogic.newCursorPositions(edits: edits)
        #expect(result == [0])
    }

    // MARK: - GutterTextView integration tests

    /// Builds a minimal text stack with a GutterTextView for integration testing.
    private func makeGutterTextView(text: String) -> GutterTextView {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        let textView = GutterTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
        return textView
    }

    @Test func gutterView_hasMultipleCursors_falseForSingle() {
        let tv = makeGutterTextView(text: "hello world")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!tv.hasMultipleCursors)
    }

    @Test func gutterView_hasMultipleCursors_trueForMultiple() {
        let tv = makeGutterTextView(text: "hello world")
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 0)),
            NSValue(range: NSRange(location: 5, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        #expect(tv.hasMultipleCursors)
    }

    @Test func gutterView_selectNextOccurrence_selectsWordWhenNoSelection() {
        let tv = makeGutterTextView(text: "hello world")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.selectNextOccurrence()
        // "hello" should be selected
        let range = tv.selectedRange()
        #expect(range.length > 0)
    }

    @Test func gutterView_selectNextOccurrence_addsSecondCursor() {
        let tv = makeGutterTextView(text: "foo bar foo")
        // Select "foo" at position 0
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        tv.selectNextOccurrence()
        // Should have two selections
        #expect(tv.selectedRanges.count == 2)
        let ranges = tv.selectedRanges.map { $0.rangeValue }
        #expect(ranges.contains { $0.location == 0 && $0.length == 3 })
        #expect(ranges.contains { $0.location == 8 && $0.length == 3 })
    }

    @Test func gutterView_selectNextOccurrence_wrapsAround() {
        let tv = makeGutterTextView(text: "foo bar foo baz foo")
        // Select all occurrences, then next should wrap to first
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        tv.selectNextOccurrence()  // adds (8, 3)
        tv.selectNextOccurrence()  // adds (16, 3)
        tv.selectNextOccurrence()  // wraps → should not add (0,3) again (already selected)
        let count = tv.selectedRanges.count
        #expect(count == 3)
    }

    @Test func gutterView_collapseToSingleCursor() {
        let tv = makeGutterTextView(text: "hello world")
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 0)),
            NSValue(range: NSRange(location: 5, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        #expect(tv.hasMultipleCursors)
        tv.collapseToSingleCursor()
        #expect(!tv.hasMultipleCursors)
    }

    @Test func gutterView_splitIntoLineCursors_noOpForEmptySelection() {
        let tv = makeGutterTextView(text: "hello\nworld")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.splitIntoLineCursors()
        #expect(!tv.hasMultipleCursors)
    }

    @Test func gutterView_splitIntoLineCursors_twoLines() {
        let tv = makeGutterTextView(text: "hello\nworld")
        // Select both lines
        tv.setSelectedRange(NSRange(location: 0, length: 11))
        tv.splitIntoLineCursors()
        #expect(tv.hasMultipleCursors)
        #expect(tv.selectedRanges.count == 2)
    }

    @Test func gutterView_insertText_appliesAtAllCursors() {
        let tv = makeGutterTextView(text: "abcde")
        // Place cursors at positions 1 and 3
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 1, length: 0)),
            NSValue(range: NSRange(location: 3, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        // "aXbcXde" → X inserted at 1 and 4 (3+1 shift from first insertion)
        #expect(tv.string == "aXbcXde")
    }

    @Test func gutterView_deleteBackward_atAllCursors() {
        let tv = makeGutterTextView(text: "abcde")
        // Cursors after 'b' (position 2) and after 'd' (position 4)
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 2, length: 0)),
            NSValue(range: NSRange(location: 4, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        tv.deleteBackward(nil)
        // Deletes 'b' and 'd': "ace"
        #expect(tv.string == "ace")
    }

    @Test func gutterView_deleteForward_atAllCursors() {
        let tv = makeGutterTextView(text: "abcde")
        // Cursors before 'b' (position 1) and before 'd' (position 3)
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 1, length: 0)),
            NSValue(range: NSRange(location: 3, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        tv.deleteForward(nil)
        // Deletes 'b' and 'd': "ace"
        #expect(tv.string == "ace")
    }

    @Test func gutterView_moveLeft_collapsesSelectionsAndMovesCursors() {
        let tv = makeGutterTextView(text: "abcde")
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 2, length: 0)),
            NSValue(range: NSRange(location: 4, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        tv.moveLeft(nil)
        let ranges = tv.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
        #expect(ranges.contains { $0.location == 1 && $0.length == 0 })
        #expect(ranges.contains { $0.location == 3 && $0.length == 0 })
    }

    @Test func gutterView_moveRight_movesCursorsRight() {
        let tv = makeGutterTextView(text: "abcde")
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 1, length: 0)),
            NSValue(range: NSRange(location: 3, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        tv.moveRight(nil)
        let ranges = tv.selectedRanges.map { $0.rangeValue }
        #expect(ranges.count == 2)
        #expect(ranges.contains { $0.location == 2 && $0.length == 0 })
        #expect(ranges.contains { $0.location == 4 && $0.length == 0 })
    }

    @Test func gutterView_moveLeft_atDocumentStart_staysAtZero() {
        let tv = makeGutterTextView(text: "abc")
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 0)),
            NSValue(range: NSRange(location: 2, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        tv.moveLeft(nil)
        let ranges = tv.selectedRanges.map { $0.rangeValue }
        // Cursor at 0 stays at 0; cursor at 2 moves to 1
        #expect(ranges.contains { $0.location == 0 })
        #expect(ranges.contains { $0.location == 1 })
    }

    @Test func gutterView_insertText_mergesAdjacentCursorsAfterMovement() {
        let tv = makeGutterTextView(text: "ab")
        // Two cursors at position 1 (adjacent)
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 1, length: 0)),
            NSValue(range: NSRange(location: 1, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        // NSTextView may deduplicate these; verify it doesn't crash
        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(tv.string.contains("X"))
    }

    @Test func gutterView_collapseToSingleCursor_fromKeyboardAction() {
        // Tests the collapseToSingleCursor() function (triggered by Esc in keyDown)
        let tv = makeGutterTextView(text: "hello world")
        tv.setSelectedRanges([
            NSValue(range: NSRange(location: 0, length: 0)),
            NSValue(range: NSRange(location: 6, length: 0))
        ], affinity: .downstream, stillSelecting: false)
        #expect(tv.hasMultipleCursors)
        tv.collapseToSingleCursor()
        #expect(!tv.hasMultipleCursors)
    }
}
