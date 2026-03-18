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

    // MARK: - Misc

    @Test func commentWithSlashOnNonCodeText() {
        let text = "color: red;"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// color: red;")
    }

    // MARK: - Unicode / emoji

    @Test func commentLineWithEmoji() {
        // 🎉 is 2 UTF-16 code units — verify NSRange offsets are correct
        let text = "let x = \"🎉\""
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// let x = \"🎉\"")
    }

    @Test func uncommentLineWithEmoji() {
        let text = "// let x = \"🎉\""
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "let x = \"🎉\"")
    }

    @Test func commentMultipleLinesWithEmoji() {
        let text = "let a = \"🎉\"\nlet b = \"🚀\""
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// let a = \"🎉\"\n// let b = \"🚀\"")
    }

    @Test func cursorAfterEmojiAdjustsCorrectly() {
        let text = "let x = \"🎉\""
        // Cursor after the emoji: "🎉" ends at UTF-16 offset 12 (l-e-t- -x- -=- -"-🎉(2)-")
        let cursorPos = (text as NSString).length // end of string
        let range = NSRange(location: cursorPos, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// let x = \"🎉\"")
        // Cursor should shift by 3 ("// ")
        #expect(result.newRange.location == cursorPos + 3)
    }

    // MARK: - Block comment: single line

    @Test func blockCommentSingleLine() {
        let text = "color: red;"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "/* color: red; */")
    }

    @Test func blockUncommentSingleLine() {
        let text = "/* color: red; */"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "color: red;")
    }

    @Test func blockCommentSingleLineHTML() {
        let text = "<div>hello</div>"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "<!--", close: "-->")
        #expect(result.newText == "<!-- <div>hello</div> -->")
    }

    @Test func blockUncommentSingleLineHTML() {
        let text = "<!-- <div>hello</div> -->"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "<!--", close: "-->")
        #expect(result.newText == "<div>hello</div>")
    }

    // MARK: - Block comment: without space

    @Test func blockUncommentWithoutSpace() {
        let text = "/*color: red;*/"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "color: red;")
    }

    // MARK: - Block comment: multiple lines

    @Test func blockCommentMultipleLines() {
        let text = "color: red;\nfont-size: 12px;"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "/* color: red;\nfont-size: 12px; */")
    }

    @Test func blockUncommentMultipleLines() {
        let text = "/* color: red;\nfont-size: 12px; */"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "color: red;\nfont-size: 12px;")
    }

    // MARK: - Block comment: preserves indentation

    @Test func blockCommentPreservesIndentation() {
        let text = "    color: red;"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "    /* color: red; */")
    }

    @Test func blockUncommentPreservesIndentation() {
        let text = "    /* color: red; */"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "    color: red;")
    }

    // MARK: - Block comment: empty lines

    @Test func blockCommentAllEmptyLinesNoChange() {
        let text = "\n\n"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "\n\n")
    }

    // MARK: - Block comment: range adjustment

    @Test func blockCommentAdjustsRange() {
        let text = "color: red;"
        let range = NSRange(location: 0, length: 11)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        // "/* " (3) + "color: red;" (11) + " */" (3) = 17
        #expect(result.newRange.length == 17)
    }

    @Test func blockUncommentAdjustsRange() {
        let text = "/* color: red; */"
        let range = NSRange(location: 0, length: 17)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newRange.length == 11) // "color: red;"
    }

    @Test func blockCommentCursorAdjusted() {
        let text = "color: red;"
        let range = NSRange(location: 5, length: 0) // cursor in middle
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        // "/* " added before content, cursor shifts by 3
        #expect(result.newRange.location == 8)
    }

    // MARK: - Block comment: cursor on middle line

    @Test func blockCommentCursorOnMiddleLine() {
        let text = "a: 1;\nb: 2;\nc: 3;"
        let range = NSRange(location: 6, length: 0) // cursor on line "b: 2;"
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "a: 1;\n/* b: 2; */\nc: 3;")
    }

    // MARK: - Block comment: unicode

    @Test func blockCommentWithEmoji() {
        let text = "let x = \"🎉\""
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "/* let x = \"🎉\" */")
    }

    @Test func blockUncommentWithEmoji() {
        let text = "/* let x = \"🎉\" */"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "let x = \"🎉\"")
    }

    // MARK: - Block comment: partial selection within a line

    @Test func blockCommentPartialSelection() {
        let text = "a: 1; b: 2; c: 3;"
        // Select just "b: 2;"
        let range = NSRange(location: 6, length: 5) // "b: 2;"
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "a: 1; /* b: 2; */ c: 3;")
    }

    @Test func blockUncommentPartialSelection() {
        let text = "a: 1; /* b: 2; */ c: 3;"
        // Select "/* b: 2; */"
        let range = NSRange(location: 6, length: 11) // "/* b: 2; */"
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "a: 1; b: 2; c: 3;")
    }
}
