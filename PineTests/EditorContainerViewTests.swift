//
//  EditorContainerViewTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for EditorContainerView and EditorScrollView layout behavior.
struct EditorContainerViewTests {

    // MARK: - EditorContainerView

    @Test func containerView_layoutWithMinimap() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        container.minimapWidth = 120

        let scrollView = EditorScrollView(frame: .zero)
        container.addSubview(scrollView)

        let minimap = MinimapView(textView: NSTextView())
        minimap.isHidden = false
        container.addSubview(minimap)

        container.layout()

        // ScrollView should fill width minus minimap
        #expect(scrollView.frame.width == 880)
        #expect(scrollView.frame.height == 600)

        // Minimap should be on the right
        #expect(minimap.frame.origin.x == 880)
        #expect(minimap.frame.width == 120)
        #expect(minimap.frame.height == 600)
    }

    @Test func containerView_layoutWithHiddenMinimap() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        container.minimapWidth = 120

        let scrollView = EditorScrollView(frame: .zero)
        container.addSubview(scrollView)

        let minimap = MinimapView(textView: NSTextView())
        minimap.isHidden = true
        container.addSubview(minimap)

        container.layout()

        // ScrollView should fill full width minus minimap allocation
        #expect(scrollView.frame.width == 880)
    }

    @Test func containerView_layoutWithZeroMinimapWidth() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        container.minimapWidth = 0

        let scrollView = EditorScrollView(frame: .zero)
        container.addSubview(scrollView)

        container.layout()

        // ScrollView should fill entire width
        #expect(scrollView.frame.width == 1000)
    }

    @Test func containerView_layoutWithLineNumberView() {
        let container = EditorContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        container.minimapWidth = 0

        let scrollView = EditorScrollView(frame: .zero)
        container.addSubview(scrollView)

        let textView = NSTextView(frame: .zero)
        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.frame = NSRect(x: 0, y: 0, width: 40, height: 600)
        container.addSubview(lineNumberView)

        container.layout()

        // LineNumberView should maintain its width
        #expect(lineNumberView.frame.width == 40)
        // Height should match container
        #expect(lineNumberView.frame.height == 600)
    }

    // MARK: - EditorScrollView

    @Test func editorScrollView_initialFindBarOffset() {
        let sv = EditorScrollView()
        #expect(sv.findBarOffset == 0)
    }

    @Test func editorScrollView_tileWithNoFindBar() {
        let sv = EditorScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        sv.tile()
        #expect(sv.findBarOffset == 0)
    }

    // MARK: - GoToRequest

    @Test func goToRequest_equalityByID() {
        let r1 = GoToRequest(offset: 10)
        let r2 = GoToRequest(offset: 10)
        #expect(r1.id != r2.id, "Different instances should have different IDs")
    }

    @Test func goToRequest_storesOffset() {
        let r = GoToRequest(offset: 12345)
        #expect(r.offset == 12345)
    }
}
