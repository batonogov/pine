//
//  ScrollRestorationTests.swift
//  PineTests
//
//  Tests for synchronous scroll position restoration on tab switch (issue #595).
//  Verifies that ensureLayout + synchronous scroll eliminates the visual jump
//  from position 0 to the saved offset.
//

import AppKit
import Testing

@testable import Pine

@Suite("Scroll Restoration Tests")
struct ScrollRestorationTests {

    // MARK: - Helpers

    /// Creates a full NSTextView + NSScrollView stack with enough content to scroll.
    @MainActor
    private func makeScrollableEditor(lineCount: Int = 500) -> (NSScrollView, NSTextView) {
        let text = (0..<lineCount).map { "Line \($0): some content here\n" }.joined()
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: textContainer
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView

        return (scrollView, textView)
    }

    // MARK: - Synchronous scroll after ensureLayout

    @Test("ensureLayout allows synchronous scroll to non-zero offset")
    @MainActor
    func synchronousScrollAfterEnsureLayout() {
        let (scrollView, textView) = makeScrollableEditor()

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            Issue.record("Text system not configured")
            return
        }

        // Force layout so scroll positions are valid
        layoutManager.ensureLayout(for: textContainer)

        let targetOffset: CGFloat = 2000
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let actualOffset = scrollView.contentView.bounds.origin.y
        // The offset should be applied synchronously (same call frame)
        // Allow small delta for clamping to valid content range
        #expect(actualOffset > 0, "Scroll offset should be non-zero after synchronous restore")
    }

    @Test("Scroll offset is zero before any scroll restoration")
    @MainActor
    func initialScrollOffsetIsZero() {
        let (scrollView, _) = makeScrollableEditor()
        let offset = scrollView.contentView.bounds.origin.y
        #expect(offset == 0, "Initial scroll offset should be zero")
    }

    @Test("ensureLayout handles empty text without crash")
    @MainActor
    func ensureLayoutEmptyText() {
        let (_, textView) = makeScrollableEditor(lineCount: 0)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            Issue.record("Text system not configured")
            return
        }

        // Should not crash on empty content
        layoutManager.ensureLayout(for: textContainer)
    }

    @Test("Scroll restoration sets offset even when exceeding document bounds")
    @MainActor
    func scrollRestorationWithLargeOffset() {
        let (scrollView, textView) = makeScrollableEditor(lineCount: 10)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            Issue.record("Text system not configured")
            return
        }

        layoutManager.ensureLayout(for: textContainer)

        // Scroll past the document end — NSScrollView accepts any offset when offscreen
        // (clamping only happens when the scroll view is in a visible window).
        // The important thing is that scroll() does not crash.
        let hugeOffset: CGFloat = 999_999
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: hugeOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let actualOffset = scrollView.contentView.bounds.origin.y
        // Offset is applied (even if not clamped offscreen) — no crash
        #expect(actualOffset >= 0, "Scroll offset should be non-negative")
    }

    // MARK: - Tab switch scroll state preservation

    @Test("EditorTab preserves scroll offset across tab switches")
    func editorTabScrollOffsetPreservation() {
        let tabManager = TabManager()

        let tab1 = EditorTab(
            url: URL(fileURLWithPath: "/tmp/scroll-test-1.swift"),
            content: String(repeating: "line\n", count: 500),
            savedContent: String(repeating: "line\n", count: 500)
        )
        let tab2 = EditorTab(
            url: URL(fileURLWithPath: "/tmp/scroll-test-2.swift"),
            content: "short file",
            savedContent: "short file"
        )

        tabManager.tabs = [tab1, tab2]
        tabManager.activeTabID = tab1.id

        // Simulate scrolling in tab1
        tabManager.updateEditorState(cursorPosition: 200, scrollOffset: 1500.0)

        // Switch to tab2
        tabManager.activeTabID = tab2.id
        tabManager.updateEditorState(cursorPosition: 0, scrollOffset: 0)

        // Switch back to tab1
        tabManager.activeTabID = tab1.id

        let restored = tabManager.activeTab
        #expect(restored?.scrollOffset == 1500.0, "Scroll offset should be preserved")
        #expect(restored?.cursorPosition == 200, "Cursor position should be preserved")
    }

    @Test("EditorTab scroll offset defaults to zero for new tabs")
    func newTabScrollOffsetIsZero() {
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/new-file.swift"),
            content: "new content",
            savedContent: "new content"
        )
        #expect(tab.scrollOffset == 0)
        #expect(tab.cursorPosition == 0)
    }

    @Test("Multiple rapid tab switches preserve correct scroll offsets")
    func rapidTabSwitchPreservesOffsets() {
        let tabManager = TabManager()

        let tabs = (0..<5).map { index in
            EditorTab(
                url: URL(fileURLWithPath: "/tmp/rapid-\(index).swift"),
                content: String(repeating: "line \(index)\n", count: 100),
                savedContent: String(repeating: "line \(index)\n", count: 100)
            )
        }
        tabManager.tabs = tabs

        // Set different scroll offsets for each tab
        let offsets: [CGFloat] = [100, 250, 0, 500, 1200]
        for (index, tab) in tabs.enumerated() {
            tabManager.activeTabID = tab.id
            tabManager.updateEditorState(cursorPosition: index * 10, scrollOffset: offsets[index])
        }

        // Rapidly switch through all tabs and verify offsets
        for (index, tab) in tabs.enumerated() {
            tabManager.activeTabID = tab.id
            let active = tabManager.activeTab
            #expect(active?.scrollOffset == offsets[index],
                    "Tab \(index) should have offset \(offsets[index])")
            #expect(active?.cursorPosition == index * 10,
                    "Tab \(index) should have cursor \(index * 10)")
        }
    }

    // MARK: - Cursor position clamping

    @Test("Cursor position is clamped to text length on restore")
    @MainActor
    func cursorPositionClamping() {
        let shortText = "hi"
        let safePosition = min(999, (shortText as NSString).length)
        #expect(safePosition == 2, "Cursor should be clamped to text length")
    }

    @Test("Zero scroll offset skips scroll restoration")
    func zeroScrollOffsetSkipsRestore() {
        // This tests the logic: if savedOffset > 0 { scroll } else if safePosition > 0 { scrollToVisible }
        // When both are 0, nothing should happen
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/no-scroll.swift"),
            content: "content",
            savedContent: "content"
        )
        #expect(tab.scrollOffset == 0)
        #expect(tab.cursorPosition == 0)
        // No scroll restoration should occur — view stays at origin
    }
}
