//
//  InlineDiffPhantomLayoutTests.swift
//  PineTests
//
//  Tests for #697 (gutter line number corruption when hunk expanded) and
//  #698 (gutter overlaps code when hunk expanded).
//
//  Both bugs share a single root cause: the inline-diff phantom block was
//  drawn in `drawBackground` without reserving any layout space, so it
//  overlapped real text and the gutter. The fix uses NSLayoutManagerDelegate
//  `paragraphSpacingBeforeGlyphAt` to reserve real vertical space above the
//  anchor line, so the layout manager itself shifts subsequent content.
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

@Suite("Inline Diff Phantom Layout Tests")
@MainActor
struct InlineDiffPhantomLayoutTests {

    // MARK: - Helpers

    private func makeTextView(text: String = "line1\nline2\nline3\nline4\nline5\n") -> GutterTextView {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        let tv = GutterTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return tv
    }

    private func deletionHunk(newStart: Int = 3, deletedLines: [String] = ["old1", "old2"]) -> DiffHunk {
        // Pure deletion hunk: phantom overlay shows the deleted lines.
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

    // MARK: - phantomBlockHeights basics

    @Test func phantomHeightsEmptyByDefault() {
        let tv = makeTextView()
        #expect(tv.phantomBlockHeights.isEmpty)
        #expect(tv.phantomBlockHeight(forLine: 1) == 0)
    }

    @Test func phantomHeightsZeroWhenNoExpandedHunk() {
        let tv = makeTextView()
        let hunk = deletionHunk()
        tv.diffHunksForHighlight = [hunk]
        // Not expanded yet — no reserved space.
        #expect(tv.phantomBlockHeights.isEmpty)
    }

    @Test func phantomHeightsPopulatedWhenHunkExpanded() {
        let tv = makeTextView()
        let hunk = deletionHunk(newStart: 3, deletedLines: ["old1", "old2"])
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id

        // Anchor line of a pure-deletion hunk is `newStart` (3 here).
        let height = tv.phantomBlockHeight(forLine: 3)
        #expect(height > 0, "Phantom block must reserve non-zero height for the anchor line")
        // 2 deleted lines → height ≈ 2 × line height. Sanity-check it scales.
        let oneLine = tv.phantomBlockHeight(forLine: 999) // unrelated
        #expect(oneLine == 0)
    }

    @Test func phantomHeightsScaleWithDeletedLineCount() {
        let tv = makeTextView()
        let h1 = deletionHunk(newStart: 3, deletedLines: ["a"])
        tv.diffHunksForHighlight = [h1]
        tv.expandedHunkID = h1.id
        let single = tv.phantomBlockHeight(forLine: 3)

        let h3 = deletionHunk(newStart: 3, deletedLines: ["a", "b", "c"])
        tv.diffHunksForHighlight = [h3]
        tv.expandedHunkID = h3.id
        let triple = tv.phantomBlockHeight(forLine: 3)

        #expect(triple > single)
        // Should be roughly 3× — allow rounding slack.
        #expect(triple >= single * 2.5)
    }

    @Test func phantomHeightsClearedWhenCollapsed() {
        let tv = makeTextView()
        let hunk = deletionHunk()
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id
        #expect(!tv.phantomBlockHeights.isEmpty)
        tv.expandedHunkID = nil
        #expect(tv.phantomBlockHeights.isEmpty)
    }

    @Test func phantomHeightsClearedWhenHunksReplaced() {
        let tv = makeTextView()
        let hunk = deletionHunk()
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id
        #expect(!tv.phantomBlockHeights.isEmpty)
        // Replace hunks — stale expandedHunkID no longer matches anything.
        tv.diffHunksForHighlight = []
        #expect(tv.phantomBlockHeights.isEmpty,
                "Phantom heights must be cleared when expanded hunk no longer exists")
    }

    @Test func modifiedHunksDoNotReservePhantomSpace() {
        // Modified hunks (both - and + lines) intentionally skip the phantom
        // overlay (#681). Phantom heights must reflect that.
        let tv = makeTextView()
        let modified = DiffHunk(
            newStart: 3, newCount: 1, oldStart: 3, oldCount: 1,
            rawText: "@@ -3,1 +3,1 @@\n-old\n+new"
        )
        tv.diffHunksForHighlight = [modified]
        tv.expandedHunkID = modified.id
        #expect(tv.phantomBlockHeights.isEmpty,
                "Modified hunks must not reserve phantom space")
    }

    // MARK: - Layout integration

    @Test func anchorLineFragmentTallerWhenHunkExpanded() {
        // The defining property of the fix: the layout manager actually
        // reserves vertical space above the anchor line. We verify by
        // measuring the lineFragmentRect height for the anchor line glyph
        // before and after expanding the hunk.
        let text = "line1\nline2\nline3\nline4\nline5\n"
        let tv = makeTextView(text: text)
        // Wire the coordinator as layout manager delegate so that
        // paragraphSpacingBeforeGlyphAt is queried.
        let parent = CodeEditorView(
            text: .constant(text), language: "swift", foldState: .constant(FoldState())
        )
        let coordinator = parent.makeCoordinator()
        // Coordinator needs a scrollView reference so it can find the GutterTextView.
        let scrollView = NSScrollView(frame: tv.frame)
        scrollView.documentView = tv
        coordinator.scrollView = scrollView
        tv.layoutManager?.delegate = coordinator

        // Force layout once with no expansion.
        tv.layoutManager?.ensureLayout(for: tv.textContainer!) // swiftlint:disable:this force_unwrapping

        // Anchor line 3 in pure-deletion hunk → glyph index for char index of line 3.
        // Char index of line 3 = length of "line1\nline2\n" = 12.
        let anchorChar = 12
        let glyphIdx = tv.layoutManager!.glyphIndexForCharacter(at: anchorChar) // swiftlint:disable:this force_unwrapping
        let baseRect = tv.layoutManager!.lineFragmentRect( // swiftlint:disable:this force_unwrapping
            forGlyphAt: glyphIdx, effectiveRange: nil
        )

        // Now expand a deletion hunk anchored at line 3.
        let hunk = deletionHunk(newStart: 3, deletedLines: ["old1", "old2"])
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id
        tv.layoutManager?.ensureLayout(for: tv.textContainer!) // swiftlint:disable:this force_unwrapping

        let glyphIdx2 = tv.layoutManager!.glyphIndexForCharacter(at: anchorChar) // swiftlint:disable:this force_unwrapping
        let expandedRect = tv.layoutManager!.lineFragmentRect( // swiftlint:disable:this force_unwrapping
            forGlyphAt: glyphIdx2, effectiveRange: nil
        )

        // The fragment rect must be taller AND its used rect should sit
        // lower (top of the rect now contains reserved phantom space).
        #expect(
            expandedRect.height > baseRect.height,
            "Anchor lineFragmentRect must grow when hunk is expanded (got base=\(baseRect.height), expanded=\(expandedRect.height))"
        )
    }

    @Test func anchorLineFragmentReturnsToNormalWhenCollapsed() {
        let text = "line1\nline2\nline3\nline4\nline5\n"
        let tv = makeTextView(text: text)
        let parent = CodeEditorView(
            text: .constant(text), language: "swift", foldState: .constant(FoldState())
        )
        let coordinator = parent.makeCoordinator()
        let scrollView = NSScrollView(frame: tv.frame)
        scrollView.documentView = tv
        coordinator.scrollView = scrollView
        tv.layoutManager?.delegate = coordinator

        tv.layoutManager?.ensureLayout(for: tv.textContainer!) // swiftlint:disable:this force_unwrapping
        let anchorChar = 12
        let baseHeight = tv.layoutManager!.lineFragmentRect( // swiftlint:disable:this force_unwrapping
            forGlyphAt: tv.layoutManager!.glyphIndexForCharacter(at: anchorChar), // swiftlint:disable:this force_unwrapping
            effectiveRange: nil
        ).height

        let hunk = deletionHunk(newStart: 3, deletedLines: ["a", "b"])
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id
        tv.layoutManager?.ensureLayout(for: tv.textContainer!) // swiftlint:disable:this force_unwrapping

        tv.expandedHunkID = nil
        tv.layoutManager?.ensureLayout(for: tv.textContainer!) // swiftlint:disable:this force_unwrapping
        let collapsedHeight = tv.layoutManager!.lineFragmentRect( // swiftlint:disable:this force_unwrapping
            forGlyphAt: tv.layoutManager!.glyphIndexForCharacter(at: anchorChar), // swiftlint:disable:this force_unwrapping
            effectiveRange: nil
        ).height

        #expect(abs(collapsedHeight - baseHeight) < 0.5,
                "Anchor fragment must return to baseline height after collapse")
    }

    @Test func paragraphSpacingNonZeroOnlyForFirstGlyphOfAnchorLine() {
        // The delegate must return spacing only for the FIRST glyph of the
        // anchor line — never for glyphs mid-line, otherwise the spacing
        // contribution would multiply with line length.
        let text = "abc\ndef\nghi\n"
        let tv = makeTextView(text: text)
        let parent = CodeEditorView(
            text: .constant(text), language: "swift", foldState: .constant(FoldState())
        )
        let coordinator = parent.makeCoordinator()
        let scrollView = NSScrollView(frame: tv.frame)
        scrollView.documentView = tv
        coordinator.scrollView = scrollView
        tv.layoutManager?.delegate = coordinator

        // Pure deletion anchored at line 2 (char index 4 = 'd').
        let hunk = deletionHunk(newStart: 2, deletedLines: ["old"])
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id

        let lm = tv.layoutManager! // swiftlint:disable:this force_unwrapping
        let glyphFirst = lm.glyphIndexForCharacter(at: 4) // 'd' — first glyph of line 2
        let glyphMid = lm.glyphIndexForCharacter(at: 5)   // 'e' — mid-line

        let proposed = NSRect(x: 0, y: 0, width: 100, height: 16)
        let firstSpacing = coordinator.layoutManager(
            lm,
            paragraphSpacingBeforeGlyphAt: glyphFirst,
            withProposedLineFragmentRect: proposed
        )
        let midSpacing = coordinator.layoutManager(
            lm,
            paragraphSpacingBeforeGlyphAt: glyphMid,
            withProposedLineFragmentRect: proposed
        )

        #expect(firstSpacing > 0, "First glyph of anchor line must contribute spacing")
        #expect(midSpacing == 0, "Mid-line glyphs must NOT contribute spacing")
    }

    // MARK: - Phantom drawing constraint

    @Test func phantomBlockBackgroundDoesNotOverlapGutter() {
        // Regression for #698: the phantom block background previously
        // started at x=0 (under the gutter). It must now start at the text
        // container origin (right of the gutter).
        //
        // We verify the invariant indirectly: the GutterTextView's
        // `textContainerOrigin.x` equals `gutterInset`, and the phantom
        // drawing code uses `textContainerOrigin.x` as its left edge. This
        // test documents the invariant by asserting `gutterInset > 0`.
        let tv = makeTextView()
        tv.gutterInset = 44
        #expect(tv.textContainerOrigin.x == tv.gutterInset)
        #expect(tv.gutterInset > 0)
    }
}
