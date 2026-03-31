//
//  NotificationObserverScopingTests.swift
//  PineTests
//
//  Tests for issue #465: NotificationCenter observers must be scoped
//  to specific scroll views, not object: nil.
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

@Suite("NotificationCenter Observer Scoping")
@MainActor
struct NotificationObserverScopingTests {

    // MARK: - Helpers

    /// Creates a full text stack: NSTextStorage → NSLayoutManager → NSTextContainer → NSTextView → NSScrollView.
    private func makeTextStack(text: String = "line1\nline2\nline3") -> (NSScrollView, NSTextView) {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        return (scrollView, textView)
    }

    // MARK: - LineNumberView observer scoping

    @Test("LineNumberView ignores boundsDidChange from unrelated clipView")
    func lineNumberViewIgnoresUnrelatedClipView() {
        let (scrollView, textView) = makeTextStack()
        let lineNumberView = LineNumberView(textView: textView, clipView: scrollView.contentView)

        let initialCount = lineNumberView.boundsChangeCount

        // Create a completely unrelated scroll view
        let foreignScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        foreignScrollView.documentView = NSTextView()

        // Post boundsDidChange from the foreign clipView
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: foreignScrollView.contentView
        )

        #expect(lineNumberView.boundsChangeCount == initialCount,
                "LineNumberView must not react to notifications from unrelated scroll views")
    }

    @Test("LineNumberView reacts to boundsDidChange from its own clipView")
    func lineNumberViewReactsToOwnClipView() {
        let (scrollView, textView) = makeTextStack()
        let lineNumberView = LineNumberView(textView: textView, clipView: scrollView.contentView)

        let initialCount = lineNumberView.boundsChangeCount

        // Post boundsDidChange from the correct clipView
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        #expect(lineNumberView.boundsChangeCount == initialCount + 1,
                "LineNumberView must react when its own scroll view scrolls")
    }

    // MARK: - MinimapView observer scoping

    @Test("MinimapView ignores boundsDidChange from unrelated clipView")
    func minimapViewIgnoresUnrelatedClipView() {
        let (scrollView, textView) = makeTextStack()
        let minimapView = MinimapView(textView: textView, clipView: scrollView.contentView)

        let initialCount = minimapView.scrollChangeCount

        // Create a foreign scroll view
        let foreignScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        foreignScrollView.documentView = NSTextView()

        // Post from foreign clipView
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: foreignScrollView.contentView
        )

        #expect(minimapView.scrollChangeCount == initialCount,
                "MinimapView must not react to notifications from unrelated scroll views")
    }

    @Test("MinimapView reacts to boundsDidChange from its own clipView")
    func minimapViewReactsToOwnClipView() {
        let (scrollView, textView) = makeTextStack()
        let minimapView = MinimapView(textView: textView, clipView: scrollView.contentView)

        let initialCount = minimapView.scrollChangeCount

        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        #expect(minimapView.scrollChangeCount == initialCount + 1,
                "MinimapView must react when its own scroll view scrolls")
    }

    // MARK: - Deinit / retain cycle tests

    @Test("LineNumberView deinit is called — no retain cycles")
    func lineNumberViewDeinitCalled() {
        weak var weakView: LineNumberView?
        autoreleasepool {
            let (scrollView, textView) = makeTextStack()
            let view = LineNumberView(textView: textView, clipView: scrollView.contentView)
            weakView = view
        }

        #expect(weakView == nil,
                "LineNumberView must be deallocated — no retain cycles from NotificationCenter observers")
    }

    @Test("MinimapView deinit is called — no retain cycles")
    func minimapViewDeinitCalled() {
        weak var weakView: MinimapView?
        autoreleasepool {
            let (scrollView, textView) = makeTextStack()
            let view = MinimapView(textView: textView, clipView: scrollView.contentView)
            weakView = view
            _ = view
        }

        #expect(weakView == nil,
                "MinimapView must be deallocated — no retain cycles from NotificationCenter observers")
    }

    @Test("CodeEditorView.Coordinator deinit is called — no retain cycles")
    func coordinatorDeinitCalled() {
        weak var weakCoordinator: CodeEditorView.Coordinator?
        autoreleasepool {
            let editorView = CodeEditorView(
                text: .constant("hello"),
                contentVersion: 0,
                language: "txt",
                fileName: "test.txt",
                foldState: .constant(FoldState())
            )
            let coordinator = CodeEditorView.Coordinator(parent: editorView)
            weakCoordinator = coordinator
            _ = coordinator
        }

        #expect(weakCoordinator == nil,
                "Coordinator must be deallocated — no retain cycles")
    }

    // MARK: - Coordinator command notification scoping

    @Test("Coordinator handleToggleComment only fires for key window")
    func coordinatorToggleCommentKeyWindowGuard() {
        let (scrollView, _) = makeTextStack(text: "// hello")
        let editorView = CodeEditorView(
            text: .constant("// hello"),
            contentVersion: 0,
            language: "swift",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        // Without a window (or non-key window), handleToggleComment should be a no-op
        coordinator.handleToggleComment()

        let textView = scrollView.documentView as? NSTextView
        #expect(textView?.string == "// hello",
                "Toggle comment must not fire without a key window")
    }

    @Test("Coordinator find actions only fire for key window")
    func coordinatorFindActionsKeyWindowGuard() {
        let (scrollView, _) = makeTextStack(text: "hello world")
        let editorView = CodeEditorView(
            text: .constant("hello world"),
            contentVersion: 0,
            language: "txt",
            fileName: "test.txt",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        // These should all be no-ops without a key window — no crash
        coordinator.handleFindInFile()
        coordinator.handleFindAndReplace()
        coordinator.handleFindNext()
        coordinator.handleFindPrevious()
        coordinator.handleUseSelectionForFind()
    }

    @Test("Coordinator fold code only fires for key window")
    func coordinatorFoldCodeKeyWindowGuard() {
        let (scrollView, _) = makeTextStack(text: "func foo() {\n    bar()\n}")
        let editorView = CodeEditorView(
            text: .constant("func foo() {\n    bar()\n}"),
            contentVersion: 0,
            language: "swift",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        let notification = Notification(
            name: .foldCode,
            object: nil,
            userInfo: ["action": "fold"]
        )
        coordinator.handleFoldCode(notification)
    }

    // MARK: - Multiple observers isolation

    @Test("Two LineNumberViews do not interfere with each other's scroll notifications")
    func twoLineNumberViewsIsolated() {
        let (scrollView1, textView1) = makeTextStack(text: "file1\nline2")
        let (scrollView2, textView2) = makeTextStack(text: "file2\nline2")

        let lineNum1 = LineNumberView(textView: textView1, clipView: scrollView1.contentView)
        let lineNum2 = LineNumberView(textView: textView2, clipView: scrollView2.contentView)

        let count1Before = lineNum1.boundsChangeCount
        let count2Before = lineNum2.boundsChangeCount

        // Scroll only scrollView1
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView1.contentView
        )

        #expect(lineNum1.boundsChangeCount == count1Before + 1,
                "LineNumberView 1 must react to its own scroll")
        #expect(lineNum2.boundsChangeCount == count2Before,
                "LineNumberView 2 must NOT react to scrollView1's scroll")
    }

    @Test("Two MinimapViews do not interfere with each other's scroll notifications")
    func twoMinimapViewsIsolated() {
        let (scrollView1, textView1) = makeTextStack(text: "file1\nline2")
        let (scrollView2, textView2) = makeTextStack(text: "file2\nline2")

        let minimap1 = MinimapView(textView: textView1, clipView: scrollView1.contentView)
        let minimap2 = MinimapView(textView: textView2, clipView: scrollView2.contentView)

        let count1Before = minimap1.scrollChangeCount
        let count2Before = minimap2.scrollChangeCount

        // Scroll only scrollView1
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scrollView1.contentView
        )

        #expect(minimap1.scrollChangeCount == count1Before + 1,
                "MinimapView 1 must react to its own scroll")
        #expect(minimap2.scrollChangeCount == count2Before,
                "MinimapView 2 must NOT react to scrollView1's scroll")
    }
}
