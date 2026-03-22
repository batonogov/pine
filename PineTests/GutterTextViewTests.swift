//
//  GutterTextViewTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for GutterTextView (CodeEditorView.swift) — blame data, auto-indent, comment toggling.
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

    // MARK: - Default state

    @Test func defaultGutterInset() {
        let tv = makeTextView()
        #expect(tv.gutterInset == 44)
    }

    @Test func defaultBottomInset() {
        #expect(GutterTextView.defaultBottomInset == 5)
    }

    @Test func textContainerOriginUsesGutterInset() {
        let tv = makeTextView()
        tv.gutterInset = 60
        #expect(tv.textContainerOrigin.x == 60)
        #expect(tv.textContainerOrigin.y == 8)
    }

    @Test func textContainerOriginDefaultInset() {
        let tv = makeTextView()
        #expect(tv.textContainerOrigin.x == 44)
    }

    // MARK: - Blame data

    @Test func setBlameLines_emptyArray() {
        let tv = makeTextView()
        tv.setBlameLines([])
        // Should not crash, blame lookup remains empty
        #expect(tv.isBlameVisible == false)
    }

    @Test func setBlameLines_populatesLookup() {
        let tv = makeTextView(text: "line1\nline2\nline3")
        let lines = [
            GitBlameLine(hash: "abc123", author: "Alice", authorTime: Date(), summary: "init", finalLine: 1),
            GitBlameLine(hash: "def456", author: "Bob", authorTime: Date(), summary: "update", finalLine: 2),
        ]
        tv.setBlameLines(lines)
        // Calling again with same data should be a no-op (count check)
        tv.setBlameLines(lines)
    }

    @Test func setBlameLines_rebuildOnDifferentCount() {
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
        // Should not crash; lookup updated to 2 entries
    }

    @Test func isBlameVisible_defaultFalse() {
        let tv = makeTextView()
        #expect(tv.isBlameVisible == false)
    }

    @Test func isBlameVisible_canBeSet() {
        let tv = makeTextView()
        tv.isBlameVisible = true
        #expect(tv.isBlameVisible == true)
    }

    // MARK: - Auto-indent

    @Test func insertNewline_preservesLeadingWhitespace() {
        let tv = makeTextView(text: "    hello")
        tv.setSelectedRange(NSRange(location: 9, length: 0)) // end of line
        tv.insertNewline(nil)
        let result = tv.string
        #expect(result.contains("\n    "), "Should preserve 4-space indent")
    }

    @Test func insertNewline_increasesIndentAfterOpenBrace() {
        let tv = makeTextView(text: "func test() {")
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        tv.insertNewline(nil)
        let result = tv.string
        #expect(result.contains("\n    "), "Should add 4-space indent after {")
    }

    @Test func insertNewline_increasesIndentAfterOpenParen() {
        let tv = makeTextView(text: "if (")
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.insertNewline(nil)
        let result = tv.string
        #expect(result.contains("\n    "), "Should add 4-space indent after (")
    }

    @Test func insertNewline_increasesIndentAfterColon() {
        let tv = makeTextView(text: "case .test:")
        tv.setSelectedRange(NSRange(location: 11, length: 0))
        tv.insertNewline(nil)
        let result = tv.string
        #expect(result.contains("\n    "), "Should add 4-space indent after :")
    }

    @Test func insertNewline_braceExpansion() {
        let tv = makeTextView(text: "func test() {}")
        // Place cursor between { and }
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        tv.insertNewline(nil)
        let lines = tv.string.components(separatedBy: "\n")
        #expect(lines.count == 3, "Should expand to 3 lines: opening, indented, closing")
        #expect(lines[1] == "    ", "Middle line should have increased indent")
        #expect(lines[2] == "}", "Closing brace should be on its own line")
    }

    @Test func insertNewline_noExtraIndentForPlainText() {
        let tv = makeTextView(text: "hello world")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        tv.insertNewline(nil)
        let result = tv.string
        #expect(result == "hello\n world")
    }

    // MARK: - File extension for comment toggling

    @Test func fileExtension_defaultNil() {
        let tv = makeTextView()
        #expect(tv.fileExtension == nil)
    }

    @Test func fileExtension_canBeSet() {
        let tv = makeTextView()
        tv.fileExtension = "swift"
        #expect(tv.fileExtension == "swift")
    }

    @Test func exactFileName_defaultNil() {
        let tv = makeTextView()
        #expect(tv.exactFileName == nil)
    }

    @Test func exactFileName_canBeSet() {
        let tv = makeTextView()
        tv.exactFileName = "Dockerfile"
        #expect(tv.exactFileName == "Dockerfile")
    }
}
