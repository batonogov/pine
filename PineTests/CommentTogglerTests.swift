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
        #expect(result.newText == "//     let x = 1")
    }

    @Test func uncommentsPreservingIndentation() {
        let text = "//     let x = 1"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "    let x = 1")
    }

    @Test func preservesTabIndentation() {
        let text = "\tlet x = 1"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "//")
        #expect(result.newText == "// \tlet x = 1")
    }

    // MARK: - YAML indentation (issue #251)

    @Test func commentYAMLIndentedLines() {
        let text = "    - name: Test\n      become: true"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "#")
        #expect(result.newText == "#     - name: Test\n#       become: true")
    }

    @Test func uncommentYAMLIndentedLines() {
        let text = "#     - name: Test\n#       become: true"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "#")
        #expect(result.newText == "    - name: Test\n      become: true")
    }

    @Test func commentUncommentRoundTripWithIndentation() {
        let text = "    - name: Test\n      become: true"
        let range = NSRange(location: 0, length: text.utf16.count)
        let commented = CommentToggler.toggle(text: text, selectedRange: range, lineComment: "#")
        let uncommented = CommentToggler.toggle(
            text: commented.newText,
            selectedRange: NSRange(location: 0, length: commented.newText.utf16.count),
            lineComment: "#"
        )
        #expect(uncommented.newText == text)
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

    // MARK: - Block comment: round-trip (comment → uncomment = identity)

    @Test func blockCommentRoundTripSingleLine() {
        let text = "color: red;"
        let range = NSRange(location: 0, length: 0)
        let commented = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        let uncommented = CommentToggler.toggleBlock(
            text: commented.newText, selectedRange: NSRange(location: 0, length: 0), open: "/*", close: "*/"
        )
        #expect(uncommented.newText == text)
    }

    @Test func blockCommentRoundTripMultipleLines() {
        let text = "line1\nline2\nline3"
        let range = NSRange(location: 0, length: text.utf16.count)
        let commented = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "<!--", close: "-->")
        let uncommented = CommentToggler.toggleBlock(
            text: commented.newText, selectedRange: NSRange(location: 0, length: commented.newText.utf16.count),
            open: "<!--", close: "-->"
        )
        #expect(uncommented.newText == text)
    }

    @Test func blockCommentRoundTripWithIndentation() {
        let text = "    color: red;"
        let range = NSRange(location: 0, length: 0)
        let commented = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        let uncommented = CommentToggler.toggleBlock(
            text: commented.newText, selectedRange: NSRange(location: 0, length: 0), open: "/*", close: "*/"
        )
        #expect(uncommented.newText == text)
    }

    // MARK: - Block comment: cursor adjustment on uncomment

    @Test func blockUncommentCursorAdjusted() {
        let text = "/* color: red; */"
        let range = NSRange(location: 8, length: 0) // cursor in middle of commented text
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "color: red;")
        // "/* " (3) removed before cursor, so 8 - 3 = 5
        #expect(result.newRange.location == 5)
    }

    @Test func blockUncommentCursorAdjustedNoSpace() {
        let text = "/*color: red;*/"
        let range = NSRange(location: 5, length: 0) // cursor after "/*col"
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "color: red;")
        // "/*" (2) removed before cursor, so 5 - 2 = 3
        #expect(result.newRange.location == 3)
    }

    // MARK: - Block comment: last line without trailing newline

    @Test func blockCommentLastLineNoNewline() {
        let text = "line1\nlast line"
        let range = NSRange(location: 6, length: 0) // cursor on "last line" (no \n at end)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "line1\n/* last line */")
    }

    @Test func blockUncommentLastLineNoNewline() {
        let text = "line1\n/* last line */"
        let range = NSRange(location: 6, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "line1\nlast line")
    }

    // MARK: - Block comment: only open delimiter (no close) — should NOT uncomment

    @Test func blockDoesNotUncommentWithOnlyOpen() {
        let text = "/* hello world"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        // Not detected as commented → wraps it
        #expect(result.newText == "/* /* hello world */")
    }

    @Test func blockDoesNotUncommentWithOnlyClose() {
        let text = "hello world */"
        let range = NSRange(location: 0, length: 0)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "/* hello world */ */")
    }

    // MARK: - Block comment: whitespace-only line with cursor

    @Test func blockCommentWhitespaceOnlyLineNoChange() {
        let text = "   "
        let range = NSRange(location: 1, length: 0) // cursor in whitespace
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        #expect(result.newText == "   ")
        #expect(result.newRange == range)
    }

    // MARK: - Block comment: multi-line selection with mixed indentation

    @Test func blockCommentMultiLineMixedIndentation() {
        let text = "    a: 1;\n        b: 2;\n    c: 3;"
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = CommentToggler.toggleBlock(text: text, selectedRange: range, open: "/*", close: "*/")
        // Leading whitespace from first char of selection (4 spaces)
        #expect(result.newText == "    /* a: 1;\n        b: 2;\n    c: 3; */")
    }
}
