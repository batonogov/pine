//
//  EditorContainerViewTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for EditorContainerView and EditorScrollView layout behavior.
@Suite("EditorContainerView Layout Tests")
@MainActor
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

    // MARK: - EditorScrollView

    @Test func tileWithNoFindBarKeepsZeroOffset() {
        let sv = EditorScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        sv.tile()
        #expect(sv.findBarOffset == 0)
    }
}
