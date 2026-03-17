//
//  MinimapViewTests.swift
//  PineTests
//
//  Created by Claude on 17.03.2026.
//

import AppKit
import Testing

@testable import Pine

@Suite("MinimapView Tests")
struct MinimapViewTests {

    // MARK: - UserDefaults persistence

    @Test("Minimap visibility defaults to true")
    func defaultVisibility() {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else { return }
        let visible = MinimapSettings.isVisible(in: defaults)
        #expect(visible == true)
    }

    @Test("Minimap visibility persists to UserDefaults")
    func persistVisibility() {
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else { return }
        MinimapSettings.setVisible(false, in: defaults)
        #expect(MinimapSettings.isVisible(in: defaults) == false)

        MinimapSettings.setVisible(true, in: defaults)
        #expect(MinimapSettings.isVisible(in: defaults) == true)
    }

    // MARK: - MinimapView basics

    @Test("MinimapView initializes with textView reference")
    func initWithTextView() {
        let textView = NSTextView()
        textView.string = "Hello\nWorld"
        let minimap = MinimapView(textView: textView)

        #expect(minimap.textView === textView)
        #expect(minimap.isFlipped == true)
    }

    @Test("MinimapView has correct default width")
    func defaultWidth() {
        #expect(MinimapView.defaultWidth == 80)
    }

    @Test("MinimapView scale factor is small enough for overview")
    func scaleFactor() {
        let scale = MinimapView.scaleFactor
        #expect(scale > 0)
        #expect(scale < 1)
    }

    // MARK: - Viewport indicator calculation

    @Test("Viewport rect maps visible region to minimap coordinates")
    func viewportRectCalculation() {
        let textStorage = NSTextStorage(string: String(repeating: "Line\n", count: 100))
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), textContainer: textContainer)
        textView.string = String(repeating: "Line\n", count: 100)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scrollView.documentView = textView

        let minimap = MinimapView(textView: textView)
        minimap.frame = NSRect(x: 0, y: 0, width: 80, height: 400)

        // Viewport rect should be non-nil and have positive dimensions
        let rect = minimap.computeViewportRect()
        #expect(rect != nil)
        if let rect {
            #expect(rect.width > 0)
            #expect(rect.height > 0)
            #expect(rect.origin.x >= 0)
            #expect(rect.origin.y >= 0)
        }
    }

    // MARK: - Scroll-to-position

    @Test("clickToScroll clamps to valid document range")
    func clickToScrollClamping() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        textView.string = "Short"

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scrollView.documentView = textView

        let minimap = MinimapView(textView: textView)
        minimap.frame = NSRect(x: 0, y: 0, width: 80, height: 400)

        // Clicking at y = -100 should not crash
        minimap.scrollToPosition(minimapY: -100)

        // Clicking at y = 10000 should not crash
        minimap.scrollToPosition(minimapY: 10000)
    }
}
