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
}
