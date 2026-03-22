//
//  AutoIndentTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for GutterTextView auto-indent logic (insertNewline override).
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
}
