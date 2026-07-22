//
//  EditorCanvasBackgroundTests.swift
//  PineTests
//
//  Verifies that custom editor chrome stays visually continuous with the
//  NSTextView document canvas on every system appearance.
//

import AppKit
import Testing

@testable import Pine

@Suite("Editor Canvas Background Tests")
@MainActor
struct EditorCanvasBackgroundTests {
    @Test("Gutter and minimap follow the editor background")
    func chromeFollowsEditorBackground() {
        let editor = NSTextView()
        let customBackground = NSColor(
            srgbRed: 0.21,
            green: 0.32,
            blue: 0.43,
            alpha: 1
        )
        editor.backgroundColor = customBackground

        let gutter = LineNumberView(textView: editor)
        let minimap = MinimapView(textView: editor)

        #expect(gutter.canvasBackgroundColor == customBackground)
        #expect(minimap.canvasBackgroundColor == customBackground)
    }

    @Test("Detached editor chrome falls back to the semantic text background")
    func detachedChromeUsesSemanticFallback() {
        let editor = NSTextView()
        let gutter = LineNumberView(textView: editor)
        let minimap = MinimapView(textView: editor)

        gutter.textView = nil
        minimap.textView = nil

        #expect(gutter.canvasBackgroundColor == NSColor.textBackgroundColor)
        #expect(minimap.canvasBackgroundColor == NSColor.textBackgroundColor)
    }
}
