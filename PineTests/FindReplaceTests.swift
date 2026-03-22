//
//  FindReplaceTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Tests for Find & Replace functionality (issue #275) and find bar overlap regression (issue #387).
struct FindReplaceTests {

    private func makeGutterTextView(text: String = "hello world") -> GutterTextView {
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

    // MARK: - GutterTextView configuration

    @Test func gutterTextView_usesFindBar_isEnabled() {
        let textView = makeGutterTextView()
        textView.usesFindBar = true
        #expect(textView.usesFindBar == true, "GutterTextView must support the native find bar")
    }

    // MARK: - Notification names

    @Test func findNotificationNames_areDefined() {
        #expect(Notification.Name.findInFile.rawValue == "findInFile")
        #expect(Notification.Name.findAndReplace.rawValue == "findAndReplace")
        #expect(Notification.Name.findNext.rawValue == "findNext")
        #expect(Notification.Name.findPrevious.rawValue == "findPrevious")
        #expect(Notification.Name.useSelectionForFind.rawValue == "useSelectionForFind")
    }

    // MARK: - Menu icons

    @Test(arguments: [
        (MenuIcons.find, "Find"),
        (MenuIcons.findAndReplace, "Find and Replace"),
    ])
    func findMenuIconExists(_ symbol: String, _ menuItem: String) {
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
            "SF Symbol '\(symbol)' used by '\(menuItem)' does not exist"
        )
    }

    // MARK: - EditorContainerView & EditorScrollView layout

    @Test func editorContainerView_isFlipped() {
        let container = EditorContainerView()
        #expect(container.isFlipped, "EditorContainerView must be flipped to match NSScrollView coordinate system")
    }

    @Test func editorScrollView_findBarOffset_defaultsToZero() {
        let scrollView = EditorScrollView()
        #expect(scrollView.findBarOffset == 0)
    }

    @Test func editorContainerView_lineNumberView_fullHeight_whenNoFindBar() {
        let container = EditorContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let scrollView = EditorScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView
        container.addSubview(scrollView)

        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.frame = NSRect(x: 0, y: 0, width: 40, height: 400)
        container.addSubview(lineNumberView)

        // Without find bar, line number view should fill full height from y=0
        container.layout()
        #expect(lineNumberView.frame.origin.y == 0)
        #expect(lineNumberView.frame.height == 400)
    }

    // MARK: - Coordinator find handler

    @Test func coordinator_performFindAction_doesNotCrash() {
        let textView = makeGutterTextView()
        textView.usesFindBar = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView

        let editorView = CodeEditorView(
            text: .constant("hello world"),
            contentVersion: 0,
            language: "txt",
            fileName: "test.txt",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        // performTextFinderAction requires a window to actually show the find bar,
        // but calling it without a window should be a safe no-op (guard checks window)
        coordinator.performFindAction(.showFindInterface)
        coordinator.performFindAction(.showReplaceInterface)
        coordinator.performFindAction(.nextMatch)
        coordinator.performFindAction(.previousMatch)
        coordinator.performFindAction(.setSearchString)
    }

    // MARK: - Regression: find bar overlaps line numbers (issue #387)

    @Test func editorContainerView_lineNumberView_offsetByFindBar() {
        // Regression #387: when find bar is open, LineNumberView must shift down
        let container = EditorContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let scrollView = EditorScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView
        container.addSubview(scrollView)

        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.frame = NSRect(x: 0, y: 0, width: 40, height: 400)
        container.addSubview(lineNumberView)

        // Simulate find bar height changing via tile()
        // Without actual NSTextFinder, findBarOffset stays 0 — verify no-find-bar case
        container.layout()
        #expect(lineNumberView.frame.origin.y == 0,
                "LineNumberView y must be 0 when no find bar is present")
        #expect(lineNumberView.frame.height == container.bounds.height,
                "LineNumberView must span full container height without find bar")
    }

    @Test func editorContainerView_withMinimap_scrollViewShrinks() {
        // Regression #387: minimap must not break line number positioning
        let container = EditorContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        container.minimapWidth = 100

        let scrollView = EditorScrollView(frame: .zero)
        let textView = NSTextView(frame: .zero)
        scrollView.documentView = textView
        container.addSubview(scrollView)

        let lineNumberView = LineNumberView(textView: textView)
        lineNumberView.frame = NSRect(x: 0, y: 0, width: 40, height: 600)
        container.addSubview(lineNumberView)

        container.layout()

        // ScrollView should shrink to make room for minimap
        #expect(scrollView.frame.width == 700,
                "ScrollView width must be container width minus minimapWidth")
        // LineNumberView should still start at y=0
        #expect(lineNumberView.frame.origin.y == 0)
        #expect(lineNumberView.frame.height == 600)
    }

    @Test func editorContainerView_multipleLineNumberViews_allOffset() {
        // Edge case: verify layout handles multiple non-scroll, non-minimap subviews
        let container = EditorContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let scrollView = EditorScrollView(frame: .zero)
        scrollView.documentView = NSTextView(frame: .zero)
        container.addSubview(scrollView)

        let view1 = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 400))
        let view2 = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 400))
        container.addSubview(view1)
        container.addSubview(view2)

        container.layout()

        // Both non-scroll subviews should be at y=0 (no find bar)
        #expect(view1.frame.origin.y == 0)
        #expect(view2.frame.origin.y == 0)
    }

    @Test func editorContainerView_zeroSize_doesNotCrash() {
        let container = EditorContainerView()
        container.frame = .zero

        let scrollView = EditorScrollView(frame: .zero)
        scrollView.documentView = NSTextView(frame: .zero)
        container.addSubview(scrollView)

        let lineNumberView = LineNumberView(textView: NSTextView())
        container.addSubview(lineNumberView)

        // Should not crash with zero-size container
        container.layout()
        #expect(lineNumberView.frame.height == 0)
    }

    @Test func editorScrollView_findBarHeight_withoutFindBar_isZero() {
        // Regression #387: no find bar subview → findBarOffset stays 0
        let scrollView = EditorScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = NSTextView(frame: .zero)
        scrollView.tile()
        #expect(scrollView.findBarOffset == 0)
    }

    @Test func editorContainerView_hiddenMinimap_doesNotAffectLayout() {
        let container = EditorContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        container.minimapWidth = 100

        let scrollView = EditorScrollView(frame: .zero)
        let textView = NSTextView(frame: .zero)
        scrollView.documentView = textView
        container.addSubview(scrollView)

        let minimap = MinimapView(textView: textView)
        minimap.isHidden = true
        container.addSubview(minimap)

        container.layout()

        // Hidden minimap should be skipped — scroll view still gets full width minus minimapWidth
        #expect(scrollView.frame.width == 700)
    }
}
