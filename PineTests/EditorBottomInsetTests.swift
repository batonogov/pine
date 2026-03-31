//
//  EditorBottomInsetTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests that the code editor has sufficient bottom inset so the last line is not clipped (issue #258).
@MainActor
struct EditorBottomInsetTests {

    private func makeGutterTextView(text: String = "line1\nline2\nline3") -> GutterTextView {
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

    @Test func gutterTextView_hasBottomTextContainerInset() {
        let textView = makeGutterTextView()

        #expect(textView.textContainerInset.height == GutterTextView.defaultBottomInset,
                "textContainerInset.height should equal defaultBottomInset")
        #expect(textView.textContainerInset.width == 0,
                "textContainerInset.width should be 0 (gutter offset is handled by textContainerOrigin)")
    }

    @Test func gutterTextView_textContainerOrigin_includesTopPadding() {
        let textView = makeGutterTextView(text: "test")

        #expect(textView.textContainerOrigin.x > 0, "Should have gutter x-offset")
        #expect(textView.textContainerOrigin.y > 0, "Should have top padding")
    }

    @Test func gutterTextView_defaultBottomInset_isReasonable() {
        // Inset should be large enough to provide breathing room but not excessive
        #expect(GutterTextView.defaultBottomInset >= 2)
        #expect(GutterTextView.defaultBottomInset <= 40)
    }

    // MARK: - Regression: last line clipping (issue #258)
    // textContainerInset.height is set once in GutterTextView.init and must not
    // be overridden by content changes. These tests guard against future code that
    // might inadvertently adjust the inset based on text content.

    /// Empty file should still have bottom inset.
    @Test func gutterTextView_emptyFile_hasBottomInset() {
        let textView = makeGutterTextView(text: "")
        #expect(textView.textContainerInset.height == GutterTextView.defaultBottomInset,
                "Empty file must still have bottom padding")
    }

    /// Single-line file without trailing newline.
    @Test func gutterTextView_singleLineNoNewline_hasBottomInset() {
        let textView = makeGutterTextView(text: "hello")
        #expect(textView.textContainerInset.height == GutterTextView.defaultBottomInset)
        #expect(textView.textContainerOrigin.y > 0, "Single line still needs top padding")
    }

    /// File with trailing newline — bottom inset must not change.
    @Test func gutterTextView_trailingNewline_hasBottomInset() {
        let textView = makeGutterTextView(text: "line1\nline2\n")
        #expect(textView.textContainerInset.height == GutterTextView.defaultBottomInset,
                "Trailing newline must not affect bottom inset")
    }

    /// File without trailing newline — same bottom inset.
    @Test func gutterTextView_noTrailingNewline_hasBottomInset() {
        let textView = makeGutterTextView(text: "line1\nline2")
        #expect(textView.textContainerInset.height == GutterTextView.defaultBottomInset)
    }

    /// Very long single line — bottom inset unaffected by line width.
    @Test func gutterTextView_veryLongLine_hasBottomInset() {
        let longLine = String(repeating: "a", count: 10_000)
        let textView = makeGutterTextView(text: longLine)
        #expect(textView.textContainerInset.height == GutterTextView.defaultBottomInset)
    }

    /// Many lines — bottom inset stays the same regardless of line count.
    @Test func gutterTextView_manyLines_hasBottomInset() {
        let text = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeGutterTextView(text: text)
        #expect(textView.textContainerInset.height == GutterTextView.defaultBottomInset)
    }

    /// textContainerOrigin.x accounts for gutter inset.
    @Test func gutterTextView_gutterInset_affectsOrigin() {
        let textView = makeGutterTextView(text: "test")
        textView.gutterInset = 80
        #expect(textView.textContainerOrigin.x == 80,
                "textContainerOrigin.x must match gutterInset")
    }

    /// Changing gutterInset does not affect bottom inset.
    @Test func gutterTextView_gutterInsetChange_preservesBottomInset() {
        let textView = makeGutterTextView(text: "test")
        textView.gutterInset = 120
        #expect(textView.textContainerInset.height == GutterTextView.defaultBottomInset,
                "Changing gutterInset must not affect bottom padding")
    }
}
