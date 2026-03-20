//
//  EditorBottomInsetTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests that the code editor has sufficient bottom inset so the last line is not clipped.
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
}
