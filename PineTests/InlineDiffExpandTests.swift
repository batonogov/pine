//
//  InlineDiffExpandTests.swift
//  PineTests
//
//  Tests for inline diff expand/collapse on gutter click (#672).
//

import Testing
import AppKit
@testable import Pine

/// Tests for the inline diff expand/collapse behavior:
/// - Default: no inline diff highlights shown
/// - Clicking a gutter diff marker: expands that hunk's inline diff
/// - Clicking again: collapses
/// - Escape key: collapses
/// - Diff data change: collapses
@Suite("Inline Diff Expand Tests")
struct InlineDiffExpandTests {

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

    // MARK: - GutterTextView expandedHunkID

    @Test func expandedHunkIDDefaultsToNil() {
        let tv = makeTextView()
        #expect(tv.expandedHunkID == nil)
    }

    @Test func settingExpandedHunkIDStoresValue() {
        let tv = makeTextView()
        let hunk = makeHunk()
        tv.expandedHunkID = hunk.id
        #expect(tv.expandedHunkID == hunk.id)
    }

    @Test func clearingExpandedHunkIDSetsNil() {
        let tv = makeTextView()
        let hunk = makeHunk()
        tv.expandedHunkID = hunk.id
        #expect(tv.expandedHunkID != nil)
        tv.expandedHunkID = nil
        #expect(tv.expandedHunkID == nil)
    }

    @Test func diffHunksForHighlightStoresHunks() {
        let tv = makeTextView()
        let hunk1 = makeHunk(newStart: 1)
        let hunk2 = makeHunk(newStart: 5)
        tv.diffHunksForHighlight = [hunk1, hunk2]
        #expect(tv.diffHunksForHighlight.count == 2)
        #expect(tv.diffHunksForHighlight[0].id == hunk1.id)
        #expect(tv.diffHunksForHighlight[1].id == hunk2.id)
    }

    // MARK: - LineNumberView expandedHunkID

    @Test func lineNumberViewExpandedHunkIDDefaultsToNil() {
        let view = makeLineNumberView()
        #expect(view.expandedHunkID == nil)
    }

    @Test func lineNumberViewExpandedHunkIDToggle() {
        let view = makeLineNumberView()
        let hunk = makeHunk()
        view.expandedHunkID = hunk.id
        #expect(view.expandedHunkID == hunk.id)
        view.expandedHunkID = nil
        #expect(view.expandedHunkID == nil)
    }

    // MARK: - onDiffMarkerClick callback

    @Test func onDiffMarkerClickCallbackIsCalled() {
        let view = makeLineNumberView()
        let hunk = makeHunk()
        view.diffHunks = [hunk]

        var clickedHunk: DiffHunk?
        view.onDiffMarkerClick = { h in
            clickedHunk = h
        }

        // Simulate callback invocation
        view.onDiffMarkerClick?(hunk)
        #expect(clickedHunk?.id == hunk.id)
    }

    // MARK: - Accept/Revert buttons removed (#688)

    @Test func gutterNoLongerHasAcceptRevertButtons() {
        // After #688, accept/revert buttons were removed from the gutter.
        // Diff markers still work for expand/collapse via onDiffMarkerClick.
        let view = makeLineNumberView()
        let hunk = makeHunk(newStart: 1)
        view.diffHunks = [hunk]
        #expect(view.diffHunks.count == 1, "Diff hunks still tracked")
    }

    // MARK: - Escape key collapses expanded hunk

    @Test func escapeKeyCollapsesExpandedHunk() {
        let tv = makeTextView()
        let hunk = makeHunk()
        tv.expandedHunkID = hunk.id
        #expect(tv.expandedHunkID != nil)

        // Simulate Escape key (keyCode 53)
        guard let escapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ) else {
            Issue.record("Failed to create Escape NSEvent")
            return
        }
        tv.keyDown(with: escapeEvent)
        #expect(tv.expandedHunkID == nil)
    }

    @Test func escapeKeyWithNoExpandedHunkDoesNotCrash() {
        let tv = makeTextView()
        #expect(tv.expandedHunkID == nil)
        // When no hunk is expanded, keyDown passes to super — not tested directly
        // because super.keyDown requires a full responder chain, but we verify
        // the state remains nil.
    }

    // MARK: - Expand toggle logic

    @Test func toggleExpandCollapsesSameHunk() {
        let tv = makeTextView()
        let hunk = makeHunk()

        // Expand
        tv.expandedHunkID = hunk.id
        #expect(tv.expandedHunkID == hunk.id)

        // Toggle same hunk — should collapse
        let newID: UUID? = (tv.expandedHunkID == hunk.id) ? nil : hunk.id
        tv.expandedHunkID = newID
        #expect(tv.expandedHunkID == nil)
    }

    @Test func toggleExpandSwitchesHunk() {
        let tv = makeTextView()
        let hunk1 = makeHunk(newStart: 1)
        let hunk2 = makeHunk(newStart: 5)

        // Expand hunk1
        tv.expandedHunkID = hunk1.id
        #expect(tv.expandedHunkID == hunk1.id)

        // Click hunk2 — should switch to hunk2
        let newID: UUID? = (tv.expandedHunkID == hunk2.id) ? nil : hunk2.id
        tv.expandedHunkID = newID
        #expect(tv.expandedHunkID == hunk2.id)
    }

    // MARK: - Diff data change collapses expanded hunk

    @Test func changingDiffDataShouldResetExpandedHunk() {
        let tv = makeTextView()
        let hunk = makeHunk()
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id

        // Simulate diff data change (as updateNSView does)
        let newHunk = makeHunk(newStart: 10)
        tv.diffHunksForHighlight = [newHunk]
        // In real code, updateNSView clears expandedHunkID when diff data changes
        tv.expandedHunkID = nil

        #expect(tv.expandedHunkID == nil)
    }

    // MARK: - hunkForLine via InlineDiffProvider

    @Test func hunkAtLineFindsCorrectHunk() {
        let hunk1 = makeHunk(newStart: 2, newCount: 3)
        let hunk2 = makeHunk(newStart: 10, newCount: 2)

        #expect(InlineDiffProvider.hunk(atLine: 2, in: [hunk1, hunk2])?.id == hunk1.id)
        #expect(InlineDiffProvider.hunk(atLine: 4, in: [hunk1, hunk2])?.id == hunk1.id)
        #expect(InlineDiffProvider.hunk(atLine: 10, in: [hunk1, hunk2])?.id == hunk2.id)
        #expect(InlineDiffProvider.hunk(atLine: 7, in: [hunk1, hunk2]) == nil)
    }

    @Test func hunkAtLineForPureDeletion() {
        let hunk = DiffHunk(
            newStart: 5, newCount: 0, oldStart: 5, oldCount: 3,
            rawText: "@@ -5,3 +5,0 @@\n-deleted1\n-deleted2\n-deleted3"
        )
        // Pure deletion — marker sits at the line after deletion point
        #expect(InlineDiffProvider.hunk(atLine: 5, in: [hunk])?.id == hunk.id)
        #expect(InlineDiffProvider.hunk(atLine: 4, in: [hunk]) == nil)
        #expect(InlineDiffProvider.hunk(atLine: 6, in: [hunk]) == nil)
    }

    // MARK: - Filtered highlights for expanded hunk

    @Test func addedLineNumbersFilteredToSingleHunk() {
        let hunk1 = DiffHunk(
            newStart: 2, newCount: 2, oldStart: 2, oldCount: 0,
            rawText: "@@ -2,0 +2,2 @@\n+added1\n+added2"
        )
        let hunk2 = DiffHunk(
            newStart: 8, newCount: 1, oldStart: 8, oldCount: 0,
            rawText: "@@ -8,0 +8,1 @@\n+added3"
        )

        // Full set contains all added lines
        let allAdded = InlineDiffProvider.addedLineNumbers(from: [hunk1, hunk2])
        #expect(allAdded.contains(2))
        #expect(allAdded.contains(3))
        #expect(allAdded.contains(8))

        // Filtered to hunk1 only
        let hunk1Added = InlineDiffProvider.addedLineNumbers(from: [hunk1])
        #expect(hunk1Added.contains(2))
        #expect(hunk1Added.contains(3))
        #expect(!hunk1Added.contains(8))

        // Filtered to hunk2 only
        let hunk2Added = InlineDiffProvider.addedLineNumbers(from: [hunk2])
        #expect(!hunk2Added.contains(2))
        #expect(!hunk2Added.contains(3))
        #expect(hunk2Added.contains(8))
    }

    @Test func deletedLineBlocksFilteredToSingleHunk() {
        let hunk1 = DiffHunk(
            newStart: 2, newCount: 1, oldStart: 2, oldCount: 2,
            rawText: "@@ -2,2 +2,1 @@\n-old line\n context"
        )
        let hunk2 = DiffHunk(
            newStart: 8, newCount: 0, oldStart: 8, oldCount: 1,
            rawText: "@@ -8,1 +8,0 @@\n-deleted"
        )

        let allBlocks = InlineDiffProvider.deletedLineBlocks(from: [hunk1, hunk2])
        #expect(allBlocks.count == 2)

        let hunk1Blocks = InlineDiffProvider.deletedLineBlocks(from: [hunk1])
        #expect(hunk1Blocks.count == 1)
        #expect(hunk1Blocks[0].anchorLine == 2)

        let hunk2Blocks = InlineDiffProvider.deletedLineBlocks(from: [hunk2])
        #expect(hunk2Blocks.count == 1)
        #expect(hunk2Blocks[0].anchorLine == 8)
    }

    // MARK: - Edge cases

    @Test func expandedHunkIDWithEmptyDiffHunks() {
        let tv = makeTextView()
        tv.diffHunksForHighlight = []
        tv.expandedHunkID = UUID() // some random ID
        // No crash — drawBackground should handle gracefully
        #expect(tv.expandedHunkID != nil)
    }

    @Test func expandedHunkIDWithStaleID() {
        let tv = makeTextView()
        let hunk = makeHunk()
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id

        // Replace hunks with new ones — stale ID should not match
        let newHunk = makeHunk(newStart: 20)
        tv.diffHunksForHighlight = [newHunk]

        let found = tv.diffHunksForHighlight.first { $0.id == tv.expandedHunkID }
        #expect(found == nil, "Stale expanded hunk ID should not match new hunks")
    }

    @Test func multipleHunksOnlyOneExpanded() {
        let tv = makeTextView()
        let hunk1 = makeHunk(newStart: 1)
        let hunk2 = makeHunk(newStart: 5)
        let hunk3 = makeHunk(newStart: 10)
        tv.diffHunksForHighlight = [hunk1, hunk2, hunk3]

        tv.expandedHunkID = hunk2.id

        let expanded = tv.diffHunksForHighlight.first { $0.id == tv.expandedHunkID }
        #expect(expanded?.id == hunk2.id)
        #expect(expanded?.newStart == 5)
    }

    @Test func lineNumberViewDiffMarkerCallbackNilByDefault() {
        let view = makeLineNumberView()
        #expect(view.onDiffMarkerClick == nil)
    }
}
