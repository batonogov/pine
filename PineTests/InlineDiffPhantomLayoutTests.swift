//
//  InlineDiffPhantomLayoutTests.swift
//  PineTests
//
//  Tests for layout-aware phantom block reservation (#697, #698).
//
//  When an inline diff hunk is expanded, the phantom block of deleted lines
//  must reserve real layout space so that:
//  - Subsequent code lines shift down (no overlap)
//  - LineNumberView draws line numbers in the correct slots
//  - The gutter does not overlap the code area
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

@Suite("Inline Diff Phantom Layout Tests")
@MainActor
struct InlineDiffPhantomLayoutTests {

    // MARK: - Helpers

    private func deletionHunk(
        newStart: Int = 3,
        deletedLines: [String] = ["old1", "old2", "old3"]
    ) -> DiffHunk {
        let raw = "@@ -\(newStart),\(deletedLines.count) +\(newStart),0 @@\n"
            + deletedLines.map { "-\($0)" }.joined(separator: "\n")
        return DiffHunk(
            newStart: newStart,
            newCount: 0,
            oldStart: newStart,
            oldCount: deletedLines.count,
            rawText: raw
        )
    }

    private func modifiedHunk(newStart: Int = 3) -> DiffHunk {
        // Modified hunks are excluded from phantom rendering (#681).
        DiffHunk(
            newStart: newStart, newCount: 1,
            oldStart: newStart, oldCount: 1,
            rawText: "@@ -\(newStart),1 +\(newStart),1 @@\n-old\n+new\n"
        )
    }

    // MARK: - phantomLineCount

    @Test func phantomLineCountReturnsZeroWhenNoExpandedHunk() {
        let hunk = deletionHunk(newStart: 5, deletedLines: ["a", "b"])
        let count = InlineDiffProvider.phantomLineCount(
            forLine: 5,
            in: [hunk],
            expandedHunkID: nil
        )
        #expect(count == 0)
    }

    @Test func phantomLineCountReturnsZeroForUnexpandedHunk() {
        let hunk = deletionHunk(newStart: 5, deletedLines: ["a", "b"])
        let other = UUID()
        let count = InlineDiffProvider.phantomLineCount(
            forLine: 5,
            in: [hunk],
            expandedHunkID: other
        )
        #expect(count == 0)
    }

    @Test func phantomLineCountReturnsDeletedLinesAtAnchor() {
        let hunk = deletionHunk(newStart: 5, deletedLines: ["a", "b", "c"])
        let count = InlineDiffProvider.phantomLineCount(
            forLine: 5,
            in: [hunk],
            expandedHunkID: hunk.id
        )
        #expect(count == 3)
    }

    @Test func phantomLineCountReturnsZeroForNonAnchorLine() {
        let hunk = deletionHunk(newStart: 5, deletedLines: ["a", "b"])
        #expect(InlineDiffProvider.phantomLineCount(
            forLine: 4, in: [hunk], expandedHunkID: hunk.id
        ) == 0)
        #expect(InlineDiffProvider.phantomLineCount(
            forLine: 6, in: [hunk], expandedHunkID: hunk.id
        ) == 0)
    }

    @Test func phantomLineCountIgnoresModifiedHunks() {
        // Modified hunks (delete+add) do not render phantom overlay (#681).
        let hunk = modifiedHunk(newStart: 5)
        let count = InlineDiffProvider.phantomLineCount(
            forLine: 5,
            in: [hunk],
            expandedHunkID: hunk.id
        )
        #expect(count == 0)
    }

    @Test func phantomLineCountSelectsOnlyExpandedHunkAmongMany() {
        let h1 = deletionHunk(newStart: 5, deletedLines: ["a"])
        let h2 = deletionHunk(newStart: 10, deletedLines: ["b", "c"])
        // Expand h2 — h1's anchor must return 0
        #expect(InlineDiffProvider.phantomLineCount(
            forLine: 5, in: [h1, h2], expandedHunkID: h2.id
        ) == 0)
        #expect(InlineDiffProvider.phantomLineCount(
            forLine: 10, in: [h1, h2], expandedHunkID: h2.id
        ) == 2)
    }

    @Test func phantomLineCountWithEmptyHunksIsZero() {
        #expect(InlineDiffProvider.phantomLineCount(
            forLine: 1, in: [], expandedHunkID: UUID()
        ) == 0)
    }

    // MARK: - phantomAnchorLine

    @Test func phantomAnchorLineForExpandedHunk() {
        let hunk = deletionHunk(newStart: 7, deletedLines: ["a", "b"])
        let anchor = InlineDiffProvider.phantomAnchorLine(
            in: [hunk],
            expandedHunkID: hunk.id
        )
        #expect(anchor == 7)
    }

    @Test func phantomAnchorLineNilWhenNoExpansion() {
        let hunk = deletionHunk(newStart: 7)
        #expect(InlineDiffProvider.phantomAnchorLine(
            in: [hunk], expandedHunkID: nil
        ) == nil)
    }

    @Test func phantomAnchorLineNilForModifiedHunk() {
        let hunk = modifiedHunk(newStart: 7)
        #expect(InlineDiffProvider.phantomAnchorLine(
            in: [hunk], expandedHunkID: hunk.id
        ) == nil)
    }

    // MARK: - Integration tests against the real layout manager
    //
    // These tests assemble the same Storage → LayoutManager → Container →
    // GutterTextView stack used by CodeEditorView.makeNSView, attach the
    // Coordinator as the layout manager delegate, then call ensureLayout
    // and inspect lineFragmentRect / lineFragmentUsedRect for the anchor
    // line. This verifies the *behavior* (real fragment height, real glyph
    // row offset) — not just the pure helpers.

    /// Builds a minimal CodeEditorView + Coordinator wired to a real
    /// GutterTextView text stack. Returns the pieces a test needs.
    private func makeIntegrationStack(
        text: String,
        diffHunks: [DiffHunk]
    ) -> (
        coordinator: CodeEditorView.Coordinator,
        gutterView: GutterTextView,
        layoutManager: NSLayoutManager
    ) {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 5
        layoutManager.addTextContainer(textContainer)

        let gutterView = GutterTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 800),
            textContainer: textContainer
        )
        gutterView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        gutterView.diffHunksForHighlight = diffHunks

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        scrollView.documentView = gutterView

        let editorView = CodeEditorView(
            text: .constant(text),
            language: "swift",
            fileName: "test.swift",
            diffHunks: diffHunks,
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.lineStartsCache = LineStartsCache(text: text)
        layoutManager.delegate = coordinator
        // Seed cached state (mirrors makeNSView).
        coordinator.cachedPhantomHunks = diffHunks
        coordinator.cachedExpandedHunkID = nil

        return (coordinator, gutterView, layoutManager)
    }

    /// Returns the height of the line fragment for the given 1-based line.
    private func lineFragmentHeight(
        forLine line: Int,
        layoutManager: NSLayoutManager,
        textStorage: NSTextStorage
    ) -> (rectHeight: CGFloat, usedHeight: CGFloat, usedY: CGFloat) {
        // Force layout for the entire document.
        layoutManager.ensureLayout(for: layoutManager.textContainers[0])

        let nsString = textStorage.string as NSString
        // Find character index of the start of the requested line.
        var currentLine = 1
        var charIndex = 0
        let length = nsString.length
        while currentLine < line && charIndex < length {
            let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            charIndex = NSMaxRange(lineRange)
            currentLine += 1
        }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
        var effectiveRange = NSRange(location: 0, length: 0)
        let rect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &effectiveRange
        )
        let used = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil
        )
        return (rect.size.height, used.size.height, used.origin.y - rect.origin.y)
    }

    @Test func anchorLineFragmentTallerWhenHunkExpanded() {
        // Document with 6 lines; the deletion hunk's anchor is line 3 with
        // 2 phantom lines.
        let text = "line1\nline2\nline3\nline4\nline5\nline6\n"
        let hunk = deletionHunk(newStart: 3, deletedLines: ["old_a", "old_b"])
        let stack = makeIntegrationStack(text: text, diffHunks: [hunk])

        guard let textStorage = stack.layoutManager.textStorage else {
            Issue.record("layoutManager has no textStorage")
            return
        }

        // Baseline (collapsed): anchor line fragment should be a normal
        // single-line height, glyph row aligned with the fragment top.
        let baseline = lineFragmentHeight(
            forLine: 3,
            layoutManager: stack.layoutManager,
            textStorage: textStorage
        )
        #expect(baseline.rectHeight > 0)
        #expect(baseline.usedY == 0)

        // Expand the hunk. The didSet on GutterTextView should fire and the
        // Coordinator should re-cache + invalidate, so the next ensureLayout
        // returns an inflated fragment.
        stack.gutterView.expandedHunkID = hunk.id

        let expanded = lineFragmentHeight(
            forLine: 3,
            layoutManager: stack.layoutManager,
            textStorage: textStorage
        )

        // Inflated fragment height = baseline * (1 + phantomCount) where
        // phantomCount == 2.
        let expectedHeight = baseline.rectHeight * 3
        #expect(abs(expanded.rectHeight - expectedHeight) < 0.5,
                "expected anchor fragment to be ~\(expectedHeight), got \(expanded.rectHeight)")
        // Glyph row should be pushed to the bottom by phantomCount * baseHeight.
        let expectedShift = baseline.rectHeight * 2
        #expect(abs(expanded.usedY - expectedShift) < 0.5,
                "expected glyph row Y shift ~\(expectedShift), got \(expanded.usedY)")
    }

    @Test func anchorLineFragmentReturnsToNormalWhenCollapsed() {
        let text = "alpha\nbeta\ngamma\ndelta\nepsilon\n"
        let hunk = deletionHunk(newStart: 4, deletedLines: ["old1", "old2", "old3"])
        let stack = makeIntegrationStack(text: text, diffHunks: [hunk])
        guard let textStorage = stack.layoutManager.textStorage else {
            Issue.record("layoutManager has no textStorage")
            return
        }

        // Capture baseline FIRST.
        let baseline = lineFragmentHeight(
            forLine: 4,
            layoutManager: stack.layoutManager,
            textStorage: textStorage
        )

        // Expand → verify it inflated.
        stack.gutterView.expandedHunkID = hunk.id
        let expanded = lineFragmentHeight(
            forLine: 4,
            layoutManager: stack.layoutManager,
            textStorage: textStorage
        )
        #expect(expanded.rectHeight > baseline.rectHeight + 0.5)

        // Collapse → verify the anchor fragment returned to normal.
        stack.gutterView.expandedHunkID = nil
        let collapsed = lineFragmentHeight(
            forLine: 4,
            layoutManager: stack.layoutManager,
            textStorage: textStorage
        )
        #expect(abs(collapsed.rectHeight - baseline.rectHeight) < 0.5,
                "expected fragment to return to baseline \(baseline.rectHeight), got \(collapsed.rectHeight)")
        #expect(collapsed.usedY == 0,
                "expected glyph row Y to return to 0, got \(collapsed.usedY)")
    }
}
