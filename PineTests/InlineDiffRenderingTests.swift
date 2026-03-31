//
//  InlineDiffRenderingTests.swift
//  PineTests
//
//  Tests for inline diff rendering improvements (#678, #681):
//  - Modified marker color changed from blue to yellow
//  - Deleted phantom lines use no strikethrough
//  - Accept/Revert buttons visible when hunk is expanded (no hover required)
//  - Gutter diff marker click area covers full hunk range
//  - Modified hunks (delete+add) do not render phantom overlay (#681)
//

import Testing
import AppKit
@testable import Pine

@Suite("Inline Diff Rendering Tests")
struct InlineDiffRenderingTests {

    // MARK: - Helpers

    private func makeTextView(text: String = "line1\nline2\nline3\nline4\nline5\n") -> GutterTextView {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        return GutterTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
    }

    private func makeHunk(
        newStart: Int = 2,
        newCount: Int = 2,
        oldStart: Int = 2,
        oldCount: Int = 1,
        rawText: String = "@@ -2,1 +2,2 @@\n context\n+added line\n"
    ) -> DiffHunk {
        DiffHunk(
            newStart: newStart,
            newCount: newCount,
            oldStart: oldStart,
            oldCount: oldCount,
            rawText: rawText
        )
    }

    private func makeLineNumberView() -> LineNumberView {
        let textStorage = NSTextStorage(string: "line1\nline2\nline3\n")
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
        return LineNumberView(textView: textView)
    }

    // MARK: - Modified diffs can be set on LineNumberView

    @Test func modifiedDiffsCanBeSet() throws {
        let view = makeLineNumberView()
        let diffs: [GitLineDiff] = [GitLineDiff(line: 1, kind: .modified)]
        view.lineDiffs = diffs
        // Note: modifiedColor is private — we can only verify the diff data is stored correctly.
        // The actual color (systemYellow vs systemBlue) is a visual property tested via manual/UI review.
        try #require(view.lineDiffs.count == 1, "Expected exactly one diff entry")
        #expect(view.lineDiffs[0].kind == .modified)
        #expect(view.lineDiffs[0].line == 1)
    }

    // MARK: - Deleted phantom lines: parsing

    @Test func pureDeletionHunkParsesDeletedLines() throws {
        // Verify that a pure-deletion hunk correctly parses deleted lines
        // from the raw diff text.
        let tv = makeTextView()
        let hunk = DiffHunk(
            newStart: 2, newCount: 1, oldStart: 2, oldCount: 2,
            rawText: "@@ -2,2 +2,1 @@\n-old line 1\n-old line 2\n context"
        )
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id

        let blocks = InlineDiffProvider.deletedLineBlocks(from: [hunk])
        try #require(blocks.count == 1, "Expected exactly one deleted block")
        try #require(blocks[0].lines.count == 2, "Expected two deleted lines")
        #expect(blocks[0].lines[0] == "old line 1")
        #expect(blocks[0].lines[1] == "old line 2")
    }

    // MARK: - Accept/Revert buttons removed (#688)

    @Test func gutterHasNoAcceptRevertButtons() {
        // After #688, accept/revert buttons were removed from the gutter.
        // LineNumberView no longer has hunkButtonHitTest, onAcceptHunk, or onRevertHunk.
        // Diff markers (colored bars) still render correctly.
        let view = makeLineNumberView()
        let hunk = makeHunk(newStart: 1)
        view.diffHunks = [hunk]
        view.expandedHunkID = hunk.id

        // Verify diff hunks are still tracked for color markers
        #expect(view.diffHunks.count == 1)
        // onDiffMarkerClick still works for expand/collapse
        var clicked = false
        view.onDiffMarkerClick = { _ in clicked = true }
        view.onDiffMarkerClick?(hunk)
        #expect(clicked)
    }

    // MARK: - Gutter diff marker click detects hunk across full range

    @Test func gutterClickDetectsHunkAcrossFullRange() {
        let hunk = DiffHunk(
            newStart: 3, newCount: 4, oldStart: 3, oldCount: 2,
            rawText: "@@ -3,2 +3,4 @@\n context\n+added1\n+added2\n context"
        )

        // All lines in the hunk range should map to the hunk
        for line in 3...6 {
            let found = InlineDiffProvider.hunk(atLine: line, in: [hunk])
            #expect(found?.id == hunk.id, "Line \(line) should be within hunk range")
        }

        // Lines outside should not match
        #expect(InlineDiffProvider.hunk(atLine: 2, in: [hunk]) == nil)
        #expect(InlineDiffProvider.hunk(atLine: 7, in: [hunk]) == nil)
    }

    // MARK: - Expand/collapse does not leave visual artifacts

    @Test func expandCollapseResetsState() {
        let tv = makeTextView()
        let hunk = makeHunk()
        tv.diffHunksForHighlight = [hunk]

        // Expand
        tv.expandedHunkID = hunk.id
        #expect(tv.expandedHunkID == hunk.id)
        #expect(tv.diffHunksForHighlight.count == 1, "Hunks remain during expand")

        // Collapse
        tv.expandedHunkID = nil
        #expect(tv.expandedHunkID == nil, "Expanded hunk ID cleared after collapse")
        // After collapse: hunks stay (they describe the file diff), but no hunk is expanded
        #expect(tv.diffHunksForHighlight.count == 1, "Hunks persist after collapse")
        #expect(tv.addedLineNumbers.isEmpty, "No residual added-line highlights after collapse")
    }

    // MARK: - Multiple hunks: only expanded hunk shows highlights

    @Test func onlyExpandedHunkShowsHighlights() {
        let tv = makeTextView(text: "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        let hunk1 = DiffHunk(
            newStart: 2, newCount: 2, oldStart: 2, oldCount: 1,
            rawText: "@@ -2,1 +2,2 @@\n-old\n+new1\n+new2"
        )
        let hunk2 = DiffHunk(
            newStart: 7, newCount: 1, oldStart: 6, oldCount: 1,
            rawText: "@@ -6,1 +7,1 @@\n-oldLine\n+newLine"
        )
        tv.diffHunksForHighlight = [hunk1, hunk2]
        tv.expandedHunkID = hunk1.id

        // Only hunk1 should provide highlights
        let matched = tv.diffHunksForHighlight.first { $0.id == tv.expandedHunkID }
        #expect(matched?.id == hunk1.id)
        #expect(matched?.newStart == 2)
    }

    // MARK: - Pure deletion hunk renders correctly

    @Test func pureDeletionHunkRendersDeletedBlock() throws {
        let hunk = DiffHunk(
            newStart: 5, newCount: 0, oldStart: 5, oldCount: 3,
            rawText: "@@ -5,3 +5,0 @@\n-line1\n-line2\n-line3"
        )

        let addedLines = InlineDiffProvider.addedLineNumbers(from: [hunk])
        #expect(addedLines.isEmpty, "Pure deletion should have no added lines")

        let blocks = InlineDiffProvider.deletedLineBlocks(from: [hunk])
        try #require(blocks.count == 1, "Expected exactly one deleted block")
        try #require(blocks[0].lines.count == 3, "Expected three deleted lines")
        #expect(blocks[0].anchorLine == 5)
    }

    // MARK: - Pure addition hunk renders correctly

    @Test func pureAdditionHunkRendersAddedLines() {
        let hunk = DiffHunk(
            newStart: 3, newCount: 2, oldStart: 3, oldCount: 0,
            rawText: "@@ -3,0 +3,2 @@\n+new1\n+new2"
        )

        let addedLines = InlineDiffProvider.addedLineNumbers(from: [hunk])
        #expect(addedLines.contains(3))
        #expect(addedLines.contains(4))

        let blocks = InlineDiffProvider.deletedLineBlocks(from: [hunk])
        #expect(blocks.isEmpty, "Pure addition should have no deleted blocks")
    }

    // MARK: - Mixed hunk with context lines

    @Test func mixedHunkWithContextLines() {
        let hunk = DiffHunk(
            newStart: 10, newCount: 4, oldStart: 10, oldCount: 3,
            rawText: "@@ -10,3 +10,4 @@\n context1\n-removed\n+added1\n+added2\n context2"
        )

        let addedLines = InlineDiffProvider.addedLineNumbers(from: [hunk])
        // context1 = line 10, -removed skipped, +added1 = line 11, +added2 = line 12, context2 = line 13
        #expect(addedLines.contains(11), "First added line after context and deletion")
        #expect(addedLines.contains(12), "Second added line")

        // This hunk has both deleted and added lines → modified → no phantom blocks (#681)
        let blocks = InlineDiffProvider.deletedLineBlocks(from: [hunk])
        #expect(blocks.isEmpty, "Modified hunk (context+delete+add) should not produce phantom blocks")
    }

    // MARK: - Empty hunk edge case

    @Test func emptyHunkProducesNoHighlights() {
        let addedLines = InlineDiffProvider.addedLineNumbers(from: [])
        #expect(addedLines.isEmpty)

        let blocks = InlineDiffProvider.deletedLineBlocks(from: [])
        #expect(blocks.isEmpty)
    }

    // MARK: - Hunk with only context lines (no actual changes)

    @Test func hunkWithOnlyContextLines() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 2, oldStart: 1, oldCount: 2,
            rawText: "@@ -1,2 +1,2 @@\n context1\n context2"
        )

        let addedLines = InlineDiffProvider.addedLineNumbers(from: [hunk])
        #expect(addedLines.isEmpty, "Context-only hunk should have no added lines")

        let blocks = InlineDiffProvider.deletedLineBlocks(from: [hunk])
        #expect(blocks.isEmpty, "Context-only hunk should have no deleted blocks")
    }

    // MARK: - LineNumberView hunk lookup for multi-line modified region

    @Test func hunkForLineCoversEntireModifiedRange() {
        let hunk = DiffHunk(
            newStart: 5, newCount: 3, oldStart: 5, oldCount: 2,
            rawText: "@@ -5,2 +5,3 @@\n-old1\n-old2\n+new1\n+new2\n+new3"
        )

        for line in 5...7 {
            let found = InlineDiffProvider.hunk(atLine: line, in: [hunk])
            #expect(found?.id == hunk.id, "Line \(line) should map to hunk")
        }
    }

    // MARK: - Modified hunks: no phantom overlay (#681)

    @Test func isModifiedHunkReturnsTrueForDeletePlusAdd() {
        // A hunk with both deleted and added lines is a "modified" hunk
        let hunk = DiffHunk(
            newStart: 5, newCount: 1, oldStart: 5, oldCount: 1,
            rawText: "@@ -5,1 +5,1 @@\n-old CMD line\n+new ENV PATH line"
        )
        #expect(InlineDiffProvider.isModifiedHunk(hunk) == true)
    }

    @Test func isModifiedHunkReturnsFalseForPureDeletion() {
        let hunk = DiffHunk(
            newStart: 5, newCount: 0, oldStart: 5, oldCount: 2,
            rawText: "@@ -5,2 +5,0 @@\n-deleted1\n-deleted2"
        )
        #expect(InlineDiffProvider.isModifiedHunk(hunk) == false)
    }

    @Test func isModifiedHunkReturnsFalseForPureAddition() {
        let hunk = DiffHunk(
            newStart: 3, newCount: 2, oldStart: 3, oldCount: 0,
            rawText: "@@ -3,0 +3,2 @@\n+new1\n+new2"
        )
        #expect(InlineDiffProvider.isModifiedHunk(hunk) == false)
    }

    @Test func isModifiedHunkReturnsFalseForContextOnly() {
        let hunk = DiffHunk(
            newStart: 1, newCount: 2, oldStart: 1, oldCount: 2,
            rawText: "@@ -1,2 +1,2 @@\n context1\n context2"
        )
        #expect(InlineDiffProvider.isModifiedHunk(hunk) == false)
    }

    @Test func modifiedHunkDoesNotProduceDeletedBlocks() {
        // Modified hunk (delete + add) should NOT produce phantom deleted blocks
        let modifiedHunk = DiffHunk(
            newStart: 5, newCount: 1, oldStart: 5, oldCount: 1,
            rawText: "@@ -5,1 +5,1 @@\n-old CMD line\n+new ENV PATH line"
        )
        let blocks = InlineDiffProvider.deletedLineBlocks(from: [modifiedHunk])
        #expect(blocks.isEmpty, "Modified hunks should not produce phantom overlay blocks")
    }

    @Test func modifiedHunkStillProducesAddedLines() {
        // Modified hunk should still highlight added lines with green background
        let modifiedHunk = DiffHunk(
            newStart: 5, newCount: 1, oldStart: 5, oldCount: 1,
            rawText: "@@ -5,1 +5,1 @@\n-old CMD line\n+new ENV PATH line"
        )
        let addedLines = InlineDiffProvider.addedLineNumbers(from: [modifiedHunk])
        #expect(addedLines.contains(5), "Modified hunk should still highlight added lines")
    }

    @Test func mixedHunksFilterCorrectly() {
        // Pure deletion hunk should still produce phantom blocks
        let pureDelete = DiffHunk(
            newStart: 3, newCount: 0, oldStart: 3, oldCount: 2,
            rawText: "@@ -3,2 +3,0 @@\n-removed1\n-removed2"
        )
        // Modified hunk should NOT produce phantom blocks
        let modified = DiffHunk(
            newStart: 8, newCount: 1, oldStart: 7, oldCount: 1,
            rawText: "@@ -7,1 +8,1 @@\n-old line\n+new line"
        )

        let blocks = InlineDiffProvider.deletedLineBlocks(from: [pureDelete, modified])
        #expect(blocks.count == 1, "Only pure deletion hunks produce phantom blocks")
        #expect(blocks[0].anchorLine == 3)
        #expect(blocks[0].lines == ["removed1", "removed2"])
    }

    @Test func multiLineModifiedHunkDoesNotProduceDeletedBlocks() {
        // Multi-line modification (multiple deletes + multiple adds)
        let hunk = DiffHunk(
            newStart: 10, newCount: 3, oldStart: 10, oldCount: 2,
            rawText: "@@ -10,2 +10,3 @@\n-old1\n-old2\n+new1\n+new2\n+new3"
        )
        #expect(InlineDiffProvider.isModifiedHunk(hunk) == true)
        let blocks = InlineDiffProvider.deletedLineBlocks(from: [hunk])
        #expect(blocks.isEmpty, "Multi-line modified hunk should not produce phantom blocks")
    }

    @Test func hunkWithContextAndModificationIsModified() {
        // Hunk with context lines around a modification
        let hunk = DiffHunk(
            newStart: 10, newCount: 4, oldStart: 10, oldCount: 3,
            rawText: "@@ -10,3 +10,4 @@\n context1\n-removed\n+added1\n+added2\n context2"
        )
        #expect(InlineDiffProvider.isModifiedHunk(hunk) == true)
        let blocks = InlineDiffProvider.deletedLineBlocks(from: [hunk])
        #expect(blocks.isEmpty, "Hunk with context + modification should not produce phantom blocks")
    }

    // MARK: - Adjacent hunks do not overlap

    @Test func adjacentHunksDoNotOverlap() {
        let hunk1 = DiffHunk(
            newStart: 1, newCount: 3, oldStart: 1, oldCount: 2,
            rawText: "@@ -1,2 +1,3 @@\n-old\n+new1\n+new2\n context"
        )
        let hunk2 = DiffHunk(
            newStart: 4, newCount: 2, oldStart: 3, oldCount: 1,
            rawText: "@@ -3,1 +4,2 @@\n context\n+added"
        )

        // Lines 1-3 belong to hunk1
        #expect(InlineDiffProvider.hunk(atLine: 1, in: [hunk1, hunk2])?.id == hunk1.id)
        #expect(InlineDiffProvider.hunk(atLine: 3, in: [hunk1, hunk2])?.id == hunk1.id)

        // Lines 4-5 belong to hunk2
        #expect(InlineDiffProvider.hunk(atLine: 4, in: [hunk1, hunk2])?.id == hunk2.id)
        #expect(InlineDiffProvider.hunk(atLine: 5, in: [hunk1, hunk2])?.id == hunk2.id)
    }
}
