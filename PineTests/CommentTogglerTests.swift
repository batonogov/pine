//
//  CommentTogglerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct CommentTogglerTests {

    // MARK: - Comment single line

    @Test func commentsSingleLine() {
        let text = "let x = 1"
        let range = NSRange(location: 0, length: 0) // cursor on line
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// let x = 1")
    }

    @Test func uncommentsSingleLine() {
        let text = "// let x = 1"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "let x = 1")
    }

    @Test func uncommentsWithoutSpace() {
        let text = "//let x = 1"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "let x = 1")
    }

    // MARK: - Multiple lines

    @Test func commentsMultipleLines() {
        let text = "let x = 1\nlet y = 2\nlet z = 3"
        // Select lines 1 and 2
        let range = NSRange(location: 0, length: 19) // "let x = 1\nlet y = 2"
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// let x = 1\n// let y = 2\nlet z = 3")
    }

    @Test func uncommentsMultipleLines() {
        let text = "// let x = 1\n// let y = 2\nlet z = 3"
        let range = NSRange(location: 0, length: 25) // "// let x = 1\n// let y = 2"
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "let x = 1\nlet y = 2\nlet z = 3")
    }

    // MARK: - Mixed state (some commented, some not) → comment all

    @Test func mixedStateCommentsAll() {
        let text = "// let x = 1\nlet y = 2"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// // let x = 1\n// let y = 2")
    }

    // MARK: - Empty lines are not commented

    @Test func emptyLinesAreSkipped() {
        let text = "let x = 1\n\nlet y = 2"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// let x = 1\n\n// let y = 2")
    }

    @Test func uncommentWithEmptyLines() {
        let text = "// let x = 1\n\n// let y = 2"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "let x = 1\n\nlet y = 2")
    }

    // MARK: - Different comment symbols

    @Test func commentWithHash() {
        let text = "x = 1"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "#")
        #expect(result.newText == "# x = 1")
    }

    @Test func uncommentWithHash() {
        let text = "# x = 1"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "#")
        #expect(result.newText == "x = 1")
    }

    // MARK: - Preserves indentation

    @Test func preservesIndentation() {
        let text = "    let x = 1"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "    // let x = 1")
    }

    @Test func uncommentsPreservingIndentation() {
        let text = "    // let x = 1"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "    let x = 1")
    }

    @Test func preservesTabIndentation() {
        let text = "\tlet x = 1"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "\t// let x = 1")
    }

    // MARK: - Range adjustment

    @Test func adjustsRangeAfterCommenting() {
        let text = "let x = 1"
        let range = NSRange(location: 0, length: 9) // full line selected
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        // "// " added = 3 chars, new length should cover "// let x = 1"
        #expect(result.newRange.length == 12)
    }

    @Test func adjustsRangeAfterUncommenting() {
        let text = "// let x = 1"
        let range = NSRange(location: 0, length: 12)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newRange.length == 9) // "let x = 1"
    }

    @Test func cursorRangeAdjustedAfterComment() {
        let text = "let x = 1"
        let range = NSRange(location: 4, length: 0) // cursor in middle
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        // "// " added before cursor, so location shifts by 3
        #expect(result.newRange.location == 7)
        #expect(result.newRange.length == 0)
    }

    // MARK: - Cursor on middle line

    @Test func commentsCursorLine() {
        let text = "line1\nline2\nline3"
        // Cursor on line2 (location 6 = start of "line2")
        let range = NSRange(location: 6, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "line1\n// line2\nline3")
    }

    // MARK: - All empty lines selected

    @Test func allEmptyLinesNoChange() {
        let text = "\n\n"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "\n\n")
    }

    // MARK: - CSS comment style

    @Test func commentWithCSSStyle() {
        let text = "color: red;"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// color: red;")
    }
}
