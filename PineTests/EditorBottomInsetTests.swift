//
//  EditorBottomInsetTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests that the code editor has sufficient bottom inset so the last line is not clipped.
struct EditorBottomInsetTests {

    @Test func gutterTextView_hasBottomTextContainerInset() {
        let textStorage = NSTextStorage(string: "line1\nline2\nline3")
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

        // textContainerInset.height adds padding to both top and bottom of the text container.
        // We expect a non-zero height inset to prevent the last line from being clipped.
        #expect(textView.textContainerInset.height > 0,
                "GutterTextView should have a bottom text container inset to prevent last line clipping")
    }

    @Test func gutterTextView_textContainerOrigin_includesTopPadding() {
        let textStorage = NSTextStorage(string: "test")
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

        // textContainerOrigin should still include the gutter x-offset and top padding
        #expect(textView.textContainerOrigin.x > 0, "Should have gutter x-offset")
        #expect(textView.textContainerOrigin.y > 0, "Should have top padding")
    }
}
