//
//  LineNumberBaselineTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests that line number baseline aligns with editor text baseline.
struct LineNumberBaselineTests {

    private func makeView() -> LineNumberView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        return LineNumberView(textView: textView)
    }

    /// When editor font is larger than gutter font, baselineOffset should compensate.
    @Test func baselineOffsetCompensatesForSmallerGutterFont() {
        let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let view = makeView()
        view.gutterFont = gutterFont
        view.editorFont = editorFont

        let expectedOffset = editorFont.ascender - gutterFont.ascender
        #expect(expectedOffset > 0, "Editor font ascender should be larger")
        #expect(view.baselineOffset == expectedOffset)
    }

    /// When editor and gutter fonts have the same size, baselineOffset should be 0.
    @Test func baselineOffsetZeroWhenFontsMatch() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        let view = makeView()
        view.gutterFont = font
        view.editorFont = font

        #expect(view.baselineOffset == 0)
    }

    /// baselineOffset updates when fonts change and reflects ascender difference.
    @Test func baselineOffsetUpdatesWithFonts() {
        let view = makeView()

        let editor1 = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let gutter1 = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.editorFont = editor1
        view.gutterFont = gutter1
        let offset1 = view.baselineOffset

        // Change to different size — offset should match new ascender difference
        let editor2 = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let gutter2 = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.editorFont = editor2
        view.gutterFont = gutter2
        let offset2 = view.baselineOffset

        let expected2 = editor2.ascender - gutter2.ascender
        #expect(offset2 == expected2)
        #expect(offset1 != offset2, "Offset should change when fonts change")
    }
}
