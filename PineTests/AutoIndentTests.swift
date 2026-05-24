//
//  AutoIndentTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for GutterTextView auto-indent logic (insertNewline override).
@MainActor
struct AutoIndentTests {

    private func makeGutterTextView(text: String) -> GutterTextView {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        return GutterTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
    }

    /// Simulates pressing Enter at the given cursor position.
    private func insertNewline(in view: GutterTextView, at position: Int) {
        view.setSelectedRange(NSRange(location: position, length: 0))
        view.insertNewline(nil)
    }

    // MARK: - Basic indent preservation

    @Test func insertNewline_preservesLeadingSpaces() {
        let view = makeGutterTextView(text: "    hello")
        insertNewline(in: view, at: 9) // end of "    hello"

        #expect(view.string == "    hello\n    ")
    }

    @Test func insertNewline_preservesLeadingTabs() {
        let view = makeGutterTextView(text: "\t\thello")
        insertNewline(in: view, at: 7) // end of "\t\thello"

        #expect(view.string == "\t\thello\n\t\t")
    }

    @Test func insertNewline_preservesMixedTabsAndSpaces() {
        let view = makeGutterTextView(text: "\t  hello")
        insertNewline(in: view, at: 8) // end of "\t  hello"

        #expect(view.string == "\t  hello\n\t  ")
    }

    @Test func insertNewline_noIndent_whenLineHasNoLeading() {
        let view = makeGutterTextView(text: "hello")
        insertNewline(in: view, at: 5)

        #expect(view.string == "hello\n")
    }

    // MARK: - Indent increase after openers

    @Test func insertNewline_afterOpenBrace_increasesIndent() {
        let view = makeGutterTextView(text: "func foo() {")
        insertNewline(in: view, at: 12) // after "{"

        #expect(view.string == "func foo() {\n    ")
    }

    @Test func insertNewline_afterOpenParen_increasesIndent() {
        let view = makeGutterTextView(text: "call(")
        insertNewline(in: view, at: 5) // after "("

        #expect(view.string == "call(\n    ")
    }

    @Test func insertNewline_afterColon_increasesIndent() {
        let view = makeGutterTextView(text: "case .foo:")
        insertNewline(in: view, at: 10) // after ":"

        #expect(view.string == "case .foo:\n    ")
    }

    @Test func insertNewline_afterOpener_withExistingIndent() {
        let view = makeGutterTextView(text: "    if true {")
        insertNewline(in: view, at: 13) // after "{"

        #expect(view.string == "    if true {\n        ")
    }

    // MARK: - Bracket pair expansion (cursor between { and })

    @Test func insertNewline_betweenBraces_expandsToThreeLines() {
        let view = makeGutterTextView(text: "{}")
        insertNewline(in: view, at: 1) // between { and }

        #expect(view.string == "{\n    \n}")
    }

    @Test func insertNewline_betweenParens_expandsToThreeLines() {
        let view = makeGutterTextView(text: "()")
        insertNewline(in: view, at: 1) // between ( and )

        #expect(view.string == "(\n    \n)")
    }

    @Test func insertNewline_betweenBraces_withIndent() {
        let view = makeGutterTextView(text: "    {}")
        insertNewline(in: view, at: 5) // between { and }

        #expect(view.string == "    {\n        \n    }")
    }

    @Test func insertNewline_betweenBraces_cursorOnMiddleLine() {
        let view = makeGutterTextView(text: "{}")
        insertNewline(in: view, at: 1) // between { and }

        // Cursor should be on the middle (indented) line
        let cursor = view.selectedRange().location
        let expectedPos = 1 + 1 + 4 // after "{" + "\n" + "    "
        #expect(cursor == expectedPos)
    }

    // MARK: - Empty and whitespace-only lines

    @Test func insertNewline_emptyLine() {
        let view = makeGutterTextView(text: "line1\n\nline3")
        insertNewline(in: view, at: 6) // on the empty line

        #expect(view.string == "line1\n\n\nline3")
    }

    @Test func insertNewline_whitespaceOnlyLine() {
        let view = makeGutterTextView(text: "    ")
        insertNewline(in: view, at: 4) // end of whitespace-only line

        #expect(view.string == "    \n    ")
    }

    // MARK: - Cursor mid-line

    @Test func insertNewline_midLine_preservesIndent() {
        let view = makeGutterTextView(text: "    hello world")
        insertNewline(in: view, at: 9) // after "    hello"

        // 5 spaces before "world": 4 from indent + 1 original space before "world"
        #expect(view.string == "    hello\n     world")
    }

    // MARK: - No indent increase for non-openers

    @Test func insertNewline_afterCloseBrace_noExtraIndent() {
        let view = makeGutterTextView(text: "    }")
        insertNewline(in: view, at: 5) // after "}"

        #expect(view.string == "    }\n    ")
    }

    @Test func insertNewline_afterRegularChar_noExtraIndent() {
        let view = makeGutterTextView(text: "    return x")
        insertNewline(in: view, at: 12) // after "x"

        #expect(view.string == "    return x\n    ")
    }

    // MARK: - Bug #862: Cursor position after Enter in Swift files

    @Test func insertNewline_betweenBracesWithSpaces_cursorPositionCorrect() {
        // "{ }" with space between braces — cursor after "{"
        let view = makeGutterTextView(text: "{ }")
        insertNewline(in: view, at: 1) // between { and space

        // Should expand braces, cursor on middle indented line
        let cursor = view.selectedRange().location
        // Expected text: "{\n    \n }"
        // Cursor should be at position 1 + 1 + 4 = 6 (after \n + 4 spaces)
        let expectedCursor = 6
        #expect(cursor == expectedCursor, "Cursor should be on middle line at \(expectedCursor), got \(cursor)")
        #expect(view.string == "{\n    \n }", "Text should expand braces correctly")
    }

    @Test func insertNewline_braceExpansionWithIndent_cursorNotOnClosingBrace() {
        let view = makeGutterTextView(text: "    if true {}")
        insertNewline(in: view, at: 13) // between { and }

        let cursor = view.selectedRange().location
        let text = view.string
        // Expected text: "    if true {\n        \n    }"
        // Expected cursor: 13 + 1 + 8 = 22 (after \n + 8 spaces on middle line)
        let nsText = text as NSString
        let closingBracePos = Int(nsText.range(of: "}", options: .backwards).location)
        #expect(cursor != closingBracePos, "Cursor should NOT be on closing brace")
        #expect(cursor == 22, "Cursor should be at position 22 (middle line), got \(cursor)")
    }

    @Test func insertNewline_betweenBraces_multilineCode_cursorOnNewLine() {
        // Cursor at end of line inside a function body
        let view = makeGutterTextView(text: "    let x = 1\n    }")
        insertNewline(in: view, at: 13) // after "1" on first line

        // Should just insert newline with preserved indent (4 spaces)
        let cursor = view.selectedRange().location
        let expectedCursor = 13 + 1 + 4 // after \n + 4 spaces
        #expect(cursor == expectedCursor, "Cursor should be at \(expectedCursor), got \(cursor)")
        #expect(view.string == "    let x = 1\n    \n    }")
    }

    @Test func insertNewline_betweenBracesInFunc_cursorNotOnClosingBrace() {
        // "func foo() {\n}" — cursor after { on same line
        let view = makeGutterTextView(text: "func foo() {\n}")
        insertNewline(in: view, at: 12) // after "{", before "\n"

        // Should insert "\n    " — increase indent after {
        let cursor = view.selectedRange().location
        // Expected text: "func foo() {\n    \n}"
        // Expected cursor: 12 + 1 + 4 = 17
        #expect(cursor == 17, "Cursor should be at 17 (new indented line), got \(cursor)")
        #expect(view.string == "func foo() {\n    \n}")
    }

    @Test func insertNewline_nestedBraces_expansionCursorCorrect() {
        let view = makeGutterTextView(text: "    if true {\n        {}\n    }")
        // "    if true {\n" = 14 chars, "        {" = 9 chars → { at position 22
        // between { and } is position 23
        insertNewline(in: view, at: 23) // between { and } in inner "{}"

        // Bracket expansion for inner {}
        // leadingWhitespace = "        " (8 spaces from "        {}")
        // indent = "        " + "    " = "            " (12 spaces)
        // closingIndent = "        " (8 spaces)
        let text = view.string
        let cursor = view.selectedRange().location
        // Expected: "    if true {\n        {\n            \n        }\n    }"
        let expectedCursor = 23 + 1 + 12 // 36
        #expect(cursor == expectedCursor, "Cursor should be at \(expectedCursor), got \(cursor)")
    }

    @Test func insertNewline_afterColonInSwitch_cursorNotOnClosingBrace() {
        // Bug scenario: ":" is in indentOpeners, "}" after on same line triggers bracket expansion
        let view = makeGutterTextView(text: "    case .foo:}")
        insertNewline(in: view, at: 14) // after ":"

        // This triggers bracket expansion: lastNonSpace = ":", firstNonSpaceAfter = "}"
        let cursor = view.selectedRange().location
        // Expected text: "    case .foo:\n        \n    }"
        // indent = "    " + "    " = "        " (8 spaces)
        // closingIndent = "    " (4 spaces)
        // newCursorPos = 14 + 1 + 8 = 23
        #expect(cursor == 23, "Cursor should be at 23, got \(cursor)")
    }

    @Test func insertNewline_emptyBracesAtEndOfFile_cursorCorrect() {
        // No trailing newline — cursor between { and }
        let view = makeGutterTextView(text: "class Foo {}")
        insertNewline(in: view, at: 11) // between { and }

        let cursor = view.selectedRange().location
        // Expected: "class Foo {\n    \n}"
        // leadingWhitespace = ""
        // indent = "    "
        // closingIndent = ""
        // newCursorPos = 11 + 1 + 4 = 16
        #expect(cursor == 16, "Cursor should be at 16, got \(cursor)")
        #expect(view.string == "class Foo {\n    \n}")
    }

    @Test func insertNewline_withTabIndent_bracketExpansion_cursorCorrect() {
        // Tab-based indent with bracket expansion
        let view = makeGutterTextView(text: "\t{}")
        insertNewline(in: view, at: 2) // between { and }

        let cursor = view.selectedRange().location
        // leadingWhitespace = "\t"
        // indent = "\t" + "    " = "\t    " (5 chars, 5 UTF-16)
        // closingIndent = "\t"
        // newCursorPos = 2 + 1 + 5 = 8
        #expect(cursor == 8, "Cursor should be at 8, got \(cursor)")
        #expect(view.string == "\t{\n\t    \n\t}")
    }

    @Test func insertNewline_betweenColonAndCloseParen_expansionCursorCorrect() {
        // ":" + ")" — both opener and closer, should trigger bracket expansion
        let view = makeGutterTextView(text: "case .foo:)")
        insertNewline(in: view, at: 10) // after ":"

        let cursor = view.selectedRange().location
        // This IS bracket expansion: lastNonSpace = ":", firstNonSpaceAfter = ")"
        // indent = "" + "    " = "    "
        // closingIndent = ""
        // newCursorPos = 10 + 1 + 4 = 15
        #expect(cursor == 15, "Cursor should be at 15, got \(cursor)")
    }

    @Test func insertNewline_insideFunctionBody_preservesIndent() {
        // Realistic Swift scenario: cursor at end of line inside function
        let view = makeGutterTextView(text: "    var x = 42")
        insertNewline(in: view, at: 14) // after "2"

        let cursor = view.selectedRange().location
        #expect(cursor == 14 + 1 + 4, "Cursor should be at 19, got \(cursor)")
        #expect(view.string == "    var x = 42\n    ")
    }

    @Test func insertNewline_betweenParensWithContent_noExpansion() {
        // "func()" — cursor after "c", before "c" — not between opener and closer
        let view = makeGutterTextView(text: "func()")
        insertNewline(in: view, at: 4) // after "c", before "("

        // "c" is not an opener, so no indent increase
        let cursor = view.selectedRange().location
        #expect(cursor == 5, "Cursor should be at 5, got \(cursor)")
        #expect(view.string == "func\n()")
    }

    @Test func insertNewline_afterReturnInFunc_noExtraIndent() {
        let view = makeGutterTextView(text: "    return x")
        insertNewline(in: view, at: 12)

        let cursor = view.selectedRange().location
        #expect(cursor == 12 + 1 + 4, "Cursor should preserve 4-space indent")
        #expect(view.string == "    return x\n    ")
    }

    @Test func insertNewline_betweenBracesWithTrailingContent_cursorCorrect() {
        // "{}" with content after — cursor between { and }
        let view = makeGutterTextView(text: "{} // comment")
        insertNewline(in: view, at: 1) // between { and }

        // lastNonSpace = "{", firstNonSpaceAfter = "}" — bracket expansion triggers!
        // Even though there's content after }, the closer is the first non-space after cursor
        // indent = "" + "    " = "    ", closingIndent = ""
        // Text becomes: "{\n    \n} // comment"
        let cursor = view.selectedRange().location
        #expect(cursor == 1 + 1 + 4, "Cursor should be at 6, got \(cursor)")
        #expect(view.string == "{\n    \n} // comment")
    }

    @Test func insertNewline_nestedBracketsInOneLine_correctExpansion() {
        // "(){}" — cursor between ( and )
        let view = makeGutterTextView(text: "(){}")
        insertNewline(in: view, at: 1) // between ( and )

        // lastNonSpace = "(", firstNonSpaceAfter = ")"
        // Bracket expansion for (): inserts "\n{indent}\n{closingIndent}"
        // indent = "" + "    " = "    ", closingIndent = ""
        // Text becomes: "(\n    \n){}"
        let cursor = view.selectedRange().location
        #expect(cursor == 1 + 1 + 4, "Cursor should be at 6, got \(cursor)")
        #expect(view.string == "(\n    \n){}")
    }

    @Test func insertNewline_braceExpansion_undoManagerAvailable() {
        // Verify that undo manager is available and functional after bracket expansion
        let view = makeGutterTextView(text: "{}")
        insertNewline(in: view, at: 1)

        // The expansion should modify text — verify text changed
        #expect(view.string == "{\n    \n}", "Text should be expanded to three lines")

        // Undo should restore original text and cursor position
        view.undoManager?.undo()
        #expect(view.string == "{}", "Undo should restore original text")
        #expect(view.selectedRange().location == 1, "Undo should restore cursor position")
    }
}
