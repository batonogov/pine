//
//  MultiCursorTests.swift
//  PineTests
//
//  Tests for MultiCursorState — multiple cursor tracking and operations.
//

import Testing
@testable import Pine
import AppKit

@Suite("MultiCursorState")
struct MultiCursorTests {

    // MARK: - CursorSelection

    @Test("CursorSelection sorts by location")
    func cursorSorting() {
        let a = CursorSelection(range: NSRange(location: 10, length: 0))
        let b = CursorSelection(range: NSRange(location: 5, length: 0))
        let c = CursorSelection(range: NSRange(location: 20, length: 3))
        var cursors = [a, b, c]
        cursors.sort()
        #expect(cursors[0].location == 5)
        #expect(cursors[1].location == 10)
        #expect(cursors[2].location == 20)
    }

    @Test("CursorSelection equality")
    func cursorEquality() {
        let a = CursorSelection(range: NSRange(location: 5, length: 3))
        let b = CursorSelection(range: NSRange(location: 5, length: 3))
        let c = CursorSelection(range: NSRange(location: 5, length: 0))
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Basic state

    @Test("Initial state has single cursor")
    func initialState() {
        let state = MultiCursorState()
        #expect(state.cursors.count == 1)
        #expect(!state.isMultiCursor)
        #expect(state.primary.location == 0)
    }

    @Test("setSingle replaces all cursors")
    func setSingle() {
        var state = MultiCursorState()
        state.addCursor(at: NSRange(location: 10, length: 0))
        state.addCursor(at: NSRange(location: 20, length: 0))
        #expect(state.cursors.count == 3)

        state.setSingle(NSRange(location: 50, length: 5))
        #expect(state.cursors.count == 1)
        #expect(state.primary.location == 50)
        #expect(state.primary.length == 5)
    }

    // MARK: - Adding cursors

    @Test("addCursor adds new cursor")
    func addCursor() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 5, length: 0))
        let added = state.addCursor(at: NSRange(location: 15, length: 0))
        #expect(added)
        #expect(state.isMultiCursor)
        #expect(state.cursors.count == 2)
    }

    @Test("addCursor does not add duplicate")
    func addCursorDuplicate() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 5, length: 0))
        let added = state.addCursor(at: NSRange(location: 5, length: 0))
        #expect(!added)
        #expect(state.cursors.count == 1)
    }

    @Test("addCursor keeps sorted order")
    func addCursorSorted() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 20, length: 0))
        state.addCursor(at: NSRange(location: 5, length: 0))
        state.addCursor(at: NSRange(location: 50, length: 0))
        #expect(state.cursors[0].location == 5)
        #expect(state.cursors[1].location == 20)
        #expect(state.cursors[2].location == 50)
    }

    @Test("Overlapping cursors merge")
    func mergeOverlapping() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 5, length: 10)) // 5..15
        state.addCursor(at: NSRange(location: 10, length: 10)) // 10..20
        #expect(state.cursors.count == 1)
        #expect(state.cursors[0].location == 5)
        #expect(state.cursors[0].length == 15) // 5..20
    }

    @Test("Adjacent cursors merge")
    func mergeAdjacent() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 5, length: 5)) // 5..10
        state.addCursor(at: NSRange(location: 10, length: 5)) // 10..15
        #expect(state.cursors.count == 1)
        #expect(state.cursors[0].location == 5)
        #expect(state.cursors[0].length == 10) // 5..15
    }

    // MARK: - Collapse

    @Test("collapseToSingle keeps first cursor")
    func collapseToSingle() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 5, length: 0))
        state.addCursor(at: NSRange(location: 15, length: 0))
        state.addCursor(at: NSRange(location: 25, length: 0))
        state.collapseToSingle()
        #expect(state.cursors.count == 1)
        #expect(state.primary.location == 5)
    }

    @Test("collapseToSingle no-op for single cursor")
    func collapseToSingleNoop() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 10, length: 0))
        state.collapseToSingle()
        #expect(state.cursors.count == 1)
    }

    // MARK: - Find next occurrence

    @Test("findNextOccurrence finds match after cursor")
    func findNextOccurrenceBasic() {
        let text = "hello world hello world" as NSString
        let result = MultiCursorState.findNextOccurrence(
            of: "hello",
            in: text,
            searchFrom: 5,
            existingRanges: [NSRange(location: 0, length: 5)]
        )
        #expect(result != nil)
        #expect(result?.location == 12)
        #expect(result?.length == 5)
    }

    @Test("findNextOccurrence wraps around")
    func findNextOccurrenceWrap() {
        let text = "hello world" as NSString
        let result = MultiCursorState.findNextOccurrence(
            of: "hello",
            in: text,
            searchFrom: 10,
            existingRanges: []
        )
        #expect(result != nil)
        #expect(result?.location == 0)
    }

    @Test("findNextOccurrence returns nil when all occurrences selected")
    func findNextOccurrenceAllSelected() {
        let text = "ab ab" as NSString
        let result = MultiCursorState.findNextOccurrence(
            of: "ab",
            in: text,
            searchFrom: 5,
            existingRanges: [
                NSRange(location: 0, length: 2),
                NSRange(location: 3, length: 2)
            ]
        )
        #expect(result == nil)
    }

    @Test("findNextOccurrence returns nil for empty word")
    func findNextOccurrenceEmptyWord() {
        let text = "hello" as NSString
        let result = MultiCursorState.findNextOccurrence(
            of: "",
            in: text,
            searchFrom: 0,
            existingRanges: []
        )
        #expect(result == nil)
    }

    @Test("findNextOccurrence returns nil when word not found")
    func findNextOccurrenceNotFound() {
        let text = "hello world" as NSString
        let result = MultiCursorState.findNextOccurrence(
            of: "xyz",
            in: text,
            searchFrom: 0,
            existingRanges: []
        )
        #expect(result == nil)
    }

    @Test("findNextOccurrence skips already-selected match and finds next")
    func findNextOccurrenceSkipsSelected() {
        let text = "aa aa aa" as NSString
        let result = MultiCursorState.findNextOccurrence(
            of: "aa",
            in: text,
            searchFrom: 3,
            existingRanges: [
                NSRange(location: 0, length: 2),
                NSRange(location: 3, length: 2)
            ]
        )
        #expect(result != nil)
        #expect(result?.location == 6)
    }

    // MARK: - Word at cursor

    @Test("wordAtCursor selects word under cursor")
    func wordAtCursorBasic() {
        let text = "hello world" as NSString
        let result = MultiCursorState.wordAtCursor(in: text, cursorLocation: 3)
        #expect(result != nil)
        #expect(result?.location == 0)
        #expect(result?.length == 5) // "hello"
    }

    @Test("wordAtCursor returns nil on whitespace")
    func wordAtCursorWhitespace() {
        let text = "hello world" as NSString
        let result = MultiCursorState.wordAtCursor(in: text, cursorLocation: 5)
        #expect(result == nil)
    }

    @Test("wordAtCursor selects word with underscores")
    func wordAtCursorUnderscore() throws {
        let text = "my_var = 42" as NSString
        let result = MultiCursorState.wordAtCursor(in: text, cursorLocation: 3)
        let range = try #require(result)
        #expect(text.substring(with: range) == "my_var")
    }

    @Test("wordAtCursor at beginning of text")
    func wordAtCursorBeginning() {
        let text = "hello" as NSString
        let result = MultiCursorState.wordAtCursor(in: text, cursorLocation: 0)
        #expect(result != nil)
        #expect(result?.location == 0)
        #expect(result?.length == 5)
    }

    @Test("wordAtCursor at end of text")
    func wordAtCursorEnd() {
        let text = "hello" as NSString
        let result = MultiCursorState.wordAtCursor(in: text, cursorLocation: 4)
        #expect(result != nil)
        #expect(result?.location == 0)
        #expect(result?.length == 5)
    }

    @Test("wordAtCursor empty text")
    func wordAtCursorEmptyText() {
        let text = "" as NSString
        let result = MultiCursorState.wordAtCursor(in: text, cursorLocation: 0)
        #expect(result == nil)
    }

    @Test("wordAtCursor beyond text length")
    func wordAtCursorBeyondLength() {
        let text = "hi" as NSString
        let result = MultiCursorState.wordAtCursor(in: text, cursorLocation: 100)
        #expect(result == nil)
    }

    // MARK: - Multiple Cmd+D chain

    @Test("Multiple Cmd+D chains through occurrences")
    func multipleSelectNextOccurrence() throws {
        var state = MultiCursorState()
        let text = "foo bar foo baz foo" as NSString

        // First "selection" of foo at position 0
        state.setSingle(NSRange(location: 0, length: 3))

        // Second Cmd+D — find next foo
        let second = MultiCursorState.findNextOccurrence(
            of: "foo", in: text, searchFrom: 3,
            existingRanges: state.cursors.map(\.range)
        )
        let secondRange = try #require(second)
        #expect(secondRange.location == 8)
        state.addCursor(at: secondRange)

        // Third Cmd+D
        let third = MultiCursorState.findNextOccurrence(
            of: "foo", in: text, searchFrom: 11,
            existingRanges: state.cursors.map(\.range)
        )
        let thirdRange = try #require(third)
        #expect(thirdRange.location == 16)
        state.addCursor(at: thirdRange)

        #expect(state.cursors.count == 3)

        // Fourth Cmd+D — wraps, all already selected
        let fourth = MultiCursorState.findNextOccurrence(
            of: "foo", in: text, searchFrom: 19,
            existingRanges: state.cursors.map(\.range)
        )
        #expect(fourth == nil)
    }

    // MARK: - Edge cases

    @Test("Cursor at beginning of file (BOF)")
    func cursorAtBOF() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 0, length: 0))
        state.addCursor(at: NSRange(location: 5, length: 0))
        #expect(state.cursors.count == 2)
        #expect(state.cursors[0].location == 0)
    }

    @Test("Cursor at end of file (EOF)")
    func cursorAtEOF() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 100, length: 0))
        state.addCursor(at: NSRange(location: 0, length: 0))
        #expect(state.cursors.count == 2)
        #expect(state.cursors[1].location == 100)
    }

    @Test("Many cursors (performance sanity)")
    func manyCursors() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 0, length: 0))
        for i in 1..<100 {
            state.addCursor(at: NSRange(location: i * 10, length: 0))
        }
        #expect(state.cursors.count == 100)
        #expect(state.isMultiCursor)
    }

    @Test("adjustAfterEdit shifts cursors correctly")
    func adjustAfterEdit() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 5, length: 0))
        state.addCursor(at: NSRange(location: 15, length: 0))
        state.addCursor(at: NSRange(location: 25, length: 0))

        // Insert 3 chars at position 10
        state.adjustAfterEdit(at: 10, oldLength: 0, newLength: 3)
        #expect(state.cursors[0].location == 5) // Before edit — unchanged
        #expect(state.cursors[1].location == 18) // 15 + 3
        #expect(state.cursors[2].location == 28) // 25 + 3
    }

    @Test("adjustAfterEdit with deletion shifts cursors back")
    func adjustAfterEditDeletion() {
        var state = MultiCursorState()
        state.setSingle(NSRange(location: 5, length: 0))
        state.addCursor(at: NSRange(location: 15, length: 0))

        // Delete 3 chars at position 10
        state.adjustAfterEdit(at: 10, oldLength: 3, newLength: 0)
        #expect(state.cursors[0].location == 5) // Before edit — unchanged
        #expect(state.cursors[1].location == 12) // 15 - 3
    }
}
