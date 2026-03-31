//
//  EditorContainerViewTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for EditorContainerView and EditorScrollView layout behavior.
@Suite("EditorContainerView Layout Tests")
struct EditorContainerViewTests {

    // MARK: - Layout with minimap

    @Test func layoutPositionsMinimapOnRight() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        container.minimapWidth = 120

        let scrollView = EditorScrollView(frame: .zero)
        container.addSubview(scrollView)

        let minimap = MinimapView(textView: NSTextView())
        minimap.isHidden = false
        container.addSubview(minimap)

        container.layout()

        #expect(scrollView.frame.width == 880)
        #expect(scrollView.frame.height == 600)
        #expect(minimap.frame.origin.x == 880)
        #expect(minimap.frame.width == 120)
        #expect(minimap.frame.height == 600)
    }

    @Test func layoutWithZeroMinimapFillsFullWidth() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        container.minimapWidth = 0

        let scrollView = EditorScrollView(frame: .zero)
        container.addSubview(scrollView)

        container.layout()

        #expect(scrollView.frame.width == 1000)
    }

    // MARK: - Layout with line number view

    @Test func layoutPositionsLineNumberView() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        container.minimapWidth = 0

        let scrollView = EditorScrollView(frame: .zero)
        container.addSubview(scrollView)

        let textView = NSTextView(frame: .zero)
        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.frame = NSRect(x: 0, y: 0, width: 40, height: 600)
        container.addSubview(lineNumberView)

        container.layout()

        #expect(lineNumberView.frame.width == 40)
        #expect(lineNumberView.frame.height == 600)
    }

    // MARK: - HunkToolbarView is not repositioned by layout (#698)

    @Test func layoutDoesNotOverrideHunkToolbarFrame() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        container.minimapWidth = 0

        let scrollView = EditorScrollView(frame: .zero)
        container.addSubview(scrollView)

        let textView = NSTextView(frame: .zero)
        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.frame = NSRect(x: 0, y: 0, width: 40, height: 600)
        container.addSubview(lineNumberView)

        // Add a HunkToolbarView with a specific frame (as showHunkToolbar would)
        let toolbar = HunkToolbarView()
        let toolbarFrame = NSRect(x: 800, y: 50, width: 180, height: 24)
        toolbar.frame = toolbarFrame
        container.addSubview(toolbar)

        container.layout()

        // Toolbar frame must be preserved — layout should not reposition it
        #expect(toolbar.frame.origin.x == 800)
        #expect(toolbar.frame.origin.y == 50)
        #expect(toolbar.frame.size.width == 180)
        #expect(toolbar.frame.size.height == 24)

        // LineNumberView should still be positioned correctly
        #expect(lineNumberView.frame.origin.x == 0)
        #expect(lineNumberView.frame.width == 40)
    }

    // MARK: - EditorScrollView

    @Test func tileWithNoFindBarKeepsZeroOffset() {
        let sv = EditorScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        sv.tile()
        #expect(sv.findBarOffset == 0)
    }
}
