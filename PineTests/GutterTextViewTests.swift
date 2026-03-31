//
//  GutterTextViewTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for GutterTextView (CodeEditorView.swift) — blame data, auto-indent.
@Suite("GutterTextView Tests")
@MainActor
struct GutterTextViewTests {

    private func makeTextView(text: String = "") -> GutterTextView {
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

    // MARK: - textContainerOrigin

    @Test func textContainerOriginUsesGutterInset() {
        let tv = makeTextView()
        #expect(tv.textContainerOrigin.x == 44) // default gutterInset
        #expect(tv.textContainerOrigin.y == 8)

        tv.gutterInset = 60
        #expect(tv.textContainerOrigin.x == 60)
    }

    // MARK: - Blame data

    @Test func setBlameLinesPopulatesLookup() {
        let tv = makeTextView(text: "line1\nline2\nline3")
        let lines = [
            GitBlameLine(hash: "abc123", author: "Alice", authorTime: Date(), summary: "init", finalLine: 1),
            GitBlameLine(hash: "def456", author: "Bob", authorTime: Date(), summary: "update", finalLine: 2),
        ]
        tv.setBlameLines(lines)
        // Calling again with same count should skip rebuild (optimization check)
        tv.setBlameLines(lines)
    }

    @Test func setBlameLinesRebuildsOnCountChange() {
        let tv = makeTextView(text: "line1\nline2\nline3")
        let lines1 = [
            GitBlameLine(hash: "abc123", author: "Alice", authorTime: Date(), summary: "init", finalLine: 1),
        ]
        let lines2 = [
            GitBlameLine(hash: "abc123", author: "Alice", authorTime: Date(), summary: "init", finalLine: 1),
            GitBlameLine(hash: "def456", author: "Bob", authorTime: Date(), summary: "update", finalLine: 2),
        ]
        tv.setBlameLines(lines1)
        tv.setBlameLines(lines2)
    }

    // MARK: - Auto-indent

    @Test func insertNewlinePreservesLeadingWhitespace() {
        let tv = makeTextView(text: "    hello")
        tv.setSelectedRange(NSRange(location: 9, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string.contains("\n    "), "Should preserve 4-space indent")
    }

    @Test func insertNewlineIncreasesIndentAfterOpenBrace() {
        let tv = makeTextView(text: "func test() {")
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string.contains("\n    "), "Should add 4-space indent after {")
    }

    @Test func insertNewlineIncreasesIndentAfterOpenParen() {
        let tv = makeTextView(text: "if (")
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string.contains("\n    "), "Should add 4-space indent after (")
    }

    @Test func insertNewlineIncreasesIndentAfterColon() {
        let tv = makeTextView(text: "case .test:")
        tv.setSelectedRange(NSRange(location: 11, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string.contains("\n    "), "Should add 4-space indent after :")
    }

    @Test func insertNewlineBraceExpansion() {
        let tv = makeTextView(text: "func test() {}")
        // Place cursor between { and }
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        tv.insertNewline(nil)
        let lines = tv.string.components(separatedBy: "\n")
        #expect(lines.count == 3, "Should expand to 3 lines")
        #expect(lines[1] == "    ", "Middle line should have increased indent")
        #expect(lines[2] == "}", "Closing brace should be on its own line")
    }

    @Test func insertNewlineMidLinePreservesIndent() {
        let tv = makeTextView(text: "    let x = 1 + 2")
        // Cursor in middle of the line (after "1 ")
        tv.setSelectedRange(NSRange(location: 14, length: 0))
        tv.insertNewline(nil)
        let lines = tv.string.components(separatedBy: "\n")
        #expect(lines.count == 2)
        // New line should have same indent as original line
        #expect(lines[1].hasPrefix("    "), "Should preserve indent when splitting mid-line")
    }

    @Test func insertNewlineWithExistingIndentAndBrace() {
        let tv = makeTextView(text: "    if true {}")
        // Cursor between { and }
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        tv.insertNewline(nil)
        let lines = tv.string.components(separatedBy: "\n")
        #expect(lines.count == 3, "Should expand braces")
        #expect(lines[1] == "        ", "Should add indent on top of existing 4-space")
        #expect(lines[2] == "    }", "Closing brace should keep original indent")
    }
}
