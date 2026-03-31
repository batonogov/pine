//
//  InlineDiffHunkViewerTests.swift
//  PineTests
//
//  Tests for inline diff hunk viewer (#689):
//  - Hunk navigation (next/previous) from expanded state
//  - Dismiss on click outside hunk area
//  - Restore (revert) action from toolbar
//  - Toolbar button actions mapping
//

import Testing
import AppKit
@testable import Pine

@Suite("Inline Diff Hunk Viewer Tests")
struct InlineDiffHunkViewerTests {

    // MARK: - Helpers

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

    // MARK: - Hunk Navigation

    @Test func navigateToNextHunkFromExpanded() {
        let hunk1 = makeHunk(newStart: 2, newCount: 2)
        let hunk2 = makeHunk(newStart: 8, newCount: 3)
        let hunk3 = makeHunk(newStart: 15, newCount: 1)
        let hunks = [hunk1, hunk2, hunk3]

        // Currently expanded hunk1, navigate next should return hunk2
        let next = InlineDiffProvider.nextHunk(after: hunk1, in: hunks)
        #expect(next?.id == hunk2.id)
    }

    @Test func navigateToNextHunkWrapsAround() {
        let hunk1 = makeHunk(newStart: 2, newCount: 2)
        let hunk2 = makeHunk(newStart: 8, newCount: 3)
        let hunks = [hunk1, hunk2]

        // Currently at last hunk, should wrap to first
        let next = InlineDiffProvider.nextHunk(after: hunk2, in: hunks)
        #expect(next?.id == hunk1.id)
    }

    @Test func navigateToPreviousHunkFromExpanded() {
        let hunk1 = makeHunk(newStart: 2, newCount: 2)
        let hunk2 = makeHunk(newStart: 8, newCount: 3)
        let hunk3 = makeHunk(newStart: 15, newCount: 1)
        let hunks = [hunk1, hunk2, hunk3]

        // Currently expanded hunk2, navigate previous should return hunk1
        let prev = InlineDiffProvider.previousHunk(before: hunk2, in: hunks)
        #expect(prev?.id == hunk1.id)
    }

    @Test func navigateToPreviousHunkWrapsAround() {
        let hunk1 = makeHunk(newStart: 2, newCount: 2)
        let hunk2 = makeHunk(newStart: 8, newCount: 3)
        let hunks = [hunk1, hunk2]

        // Currently at first hunk, should wrap to last
        let prev = InlineDiffProvider.previousHunk(before: hunk1, in: hunks)
        #expect(prev?.id == hunk2.id)
    }

    @Test func navigateNextWithSingleHunkReturnsSelf() {
        let hunk = makeHunk(newStart: 2, newCount: 2)
        let next = InlineDiffProvider.nextHunk(after: hunk, in: [hunk])
        #expect(next?.id == hunk.id)
    }

    @Test func navigatePreviousWithSingleHunkReturnsSelf() {
        let hunk = makeHunk(newStart: 2, newCount: 2)
        let prev = InlineDiffProvider.previousHunk(before: hunk, in: [hunk])
        #expect(prev?.id == hunk.id)
    }

    @Test func navigateNextWithEmptyHunksReturnsNil() {
        let hunk = makeHunk(newStart: 2, newCount: 2)
        let next = InlineDiffProvider.nextHunk(after: hunk, in: [])
        #expect(next == nil)
    }

    @Test func navigatePreviousWithEmptyHunksReturnsNil() {
        let hunk = makeHunk(newStart: 2, newCount: 2)
        let prev = InlineDiffProvider.previousHunk(before: hunk, in: [])
        #expect(prev == nil)
    }

    @Test func navigateNextWithStaleHunkReturnsFirst() {
        let hunk1 = makeHunk(newStart: 2, newCount: 2)
        let hunk2 = makeHunk(newStart: 8, newCount: 3)
        let staleHunk = makeHunk(newStart: 100, newCount: 1)

        // Stale hunk not found in list — should return first hunk
        let next = InlineDiffProvider.nextHunk(after: staleHunk, in: [hunk1, hunk2])
        #expect(next?.id == hunk1.id)
    }

    @Test func navigatePreviousWithStaleHunkReturnsLast() {
        let hunk1 = makeHunk(newStart: 2, newCount: 2)
        let hunk2 = makeHunk(newStart: 8, newCount: 3)
        let staleHunk = makeHunk(newStart: 100, newCount: 1)

        // Stale hunk not found in list — should return last hunk
        let prev = InlineDiffProvider.previousHunk(before: staleHunk, in: [hunk1, hunk2])
        #expect(prev?.id == hunk2.id)
    }

    // MARK: - Click Outside Dismisses Hunk

    @Test func clickOutsideHunkDismissesExpanded() {
        let tv = makeTextView()
        let hunk = makeHunk(newStart: 2, newCount: 2)
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id
        #expect(tv.expandedHunkID != nil)

        // Line 5 is outside hunk range (2-3)
        let shouldDismiss = tv.shouldDismissHunkOnClick(atLine: 5)
        #expect(shouldDismiss == true)
    }

    @Test func clickInsideHunkDoesNotDismiss() {
        let tv = makeTextView()
        let hunk = makeHunk(newStart: 2, newCount: 2)
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id

        // Line 2 is inside hunk range (2-3)
        let shouldDismiss = tv.shouldDismissHunkOnClick(atLine: 2)
        #expect(shouldDismiss == false)
    }

    @Test func clickInsideHunkLastLineDoesNotDismiss() {
        let tv = makeTextView()
        let hunk = makeHunk(newStart: 2, newCount: 3)
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id

        // Line 4 is inside hunk range (2-4)
        let shouldDismiss = tv.shouldDismissHunkOnClick(atLine: 4)
        #expect(shouldDismiss == false)
    }

    @Test func clickWithNoExpandedHunkDoesNotDismiss() {
        let tv = makeTextView()
        tv.expandedHunkID = nil

        let shouldDismiss = tv.shouldDismissHunkOnClick(atLine: 3)
        #expect(shouldDismiss == false)
    }

    @Test func clickOnPureDeletionHunkDoesNotDismiss() {
        let tv = makeTextView()
        let hunk = DiffHunk(
            newStart: 3, newCount: 0, oldStart: 3, oldCount: 2,
            rawText: "@@ -3,2 +3,0 @@\n-deleted1\n-deleted2"
        )
        tv.diffHunksForHighlight = [hunk]
        tv.expandedHunkID = hunk.id

        // Line 3 is the anchor for a pure deletion hunk
        let shouldDismiss = tv.shouldDismissHunkOnClick(atLine: 3)
        #expect(shouldDismiss == false)
    }

    // MARK: - Hunk Position Info

    @Test func hunkPositionInfoCorrect() {
        let hunk1 = makeHunk(newStart: 2)
        let hunk2 = makeHunk(newStart: 8)
        let hunk3 = makeHunk(newStart: 15)
        let hunks = [hunk1, hunk2, hunk3]

        let info = InlineDiffProvider.hunkPositionInfo(for: hunk2, in: hunks)
        #expect(info?.index == 2)
        #expect(info?.total == 3)
    }

    @Test func hunkPositionInfoFirstHunk() {
        let hunk1 = makeHunk(newStart: 2)
        let hunk2 = makeHunk(newStart: 8)
        let hunks = [hunk1, hunk2]

        let info = InlineDiffProvider.hunkPositionInfo(for: hunk1, in: hunks)
        #expect(info?.index == 1)
        #expect(info?.total == 2)
    }

    @Test func hunkPositionInfoSingleHunk() {
        let hunk = makeHunk(newStart: 5)
        let info = InlineDiffProvider.hunkPositionInfo(for: hunk, in: [hunk])
        #expect(info?.index == 1)
        #expect(info?.total == 1)
    }

    @Test func hunkPositionInfoStaleHunkReturnsNil() {
        let hunk1 = makeHunk(newStart: 2)
        let staleHunk = makeHunk(newStart: 100)
        let info = InlineDiffProvider.hunkPositionInfo(for: staleHunk, in: [hunk1])
        #expect(info == nil)
    }

    // MARK: - Toolbar Action Enum

    @Test func hunkToolbarActionValues() {
        let actions: [HunkToolbarAction] = [.previousHunk, .nextHunk, .restore, .dismiss]
        #expect(actions.count == 4)
    }

    @Test func hunkToolbarActionAccessibilityIDs() {
        #expect(HunkToolbarAction.previousHunk.accessibilityID == AccessibilityID.hunkToolbarPrevious)
        #expect(HunkToolbarAction.nextHunk.accessibilityID == AccessibilityID.hunkToolbarNext)
        #expect(HunkToolbarAction.restore.accessibilityID == AccessibilityID.hunkToolbarRestore)
        #expect(HunkToolbarAction.dismiss.accessibilityID == AccessibilityID.hunkToolbarDismiss)
    }

    // MARK: - Hunk Summary Text

    @Test func hunkSummaryForAddition() {
        let hunk = DiffHunk(
            newStart: 5, newCount: 3, oldStart: 5, oldCount: 0,
            rawText: "@@ -5,0 +5,3 @@\n+line1\n+line2\n+line3"
        )
        let summary = InlineDiffProvider.hunkSummary(hunk)
        #expect(summary.contains("+3"))
        #expect(!summary.contains("-"))
    }

    @Test func hunkSummaryForDeletion() {
        let hunk = DiffHunk(
            newStart: 5, newCount: 0, oldStart: 5, oldCount: 2,
            rawText: "@@ -5,2 +5,0 @@\n-line1\n-line2"
        )
        let summary = InlineDiffProvider.hunkSummary(hunk)
        #expect(summary.contains("-2"))
    }

    @Test func hunkSummaryForModification() {
        let hunk = DiffHunk(
            newStart: 5, newCount: 3, oldStart: 5, oldCount: 2,
            rawText: "@@ -5,2 +5,3 @@\n-old1\n-old2\n+new1\n+new2\n+new3"
        )
        let summary = InlineDiffProvider.hunkSummary(hunk)
        #expect(summary.contains("+3"))
        #expect(summary.contains("-2"))
    }

    // MARK: - Expanded hunk line range helper

    @Test func expandedHunkLineRangeForNormalHunk() {
        let hunk = makeHunk(newStart: 5, newCount: 3)
        let range = InlineDiffProvider.expandedLineRange(for: hunk)
        #expect(range == 5...7)
    }

    @Test func expandedHunkLineRangeForPureDeletion() {
        let hunk = DiffHunk(
            newStart: 5, newCount: 0, oldStart: 5, oldCount: 3,
            rawText: "@@ -5,3 +5,0 @@\n-a\n-b\n-c"
        )
        let range = InlineDiffProvider.expandedLineRange(for: hunk)
        #expect(range == 5...5)
    }

    @Test func expandedHunkLineRangeForSingleLine() {
        let hunk = makeHunk(newStart: 10, newCount: 1)
        let range = InlineDiffProvider.expandedLineRange(for: hunk)
        #expect(range == 10...10)
    }

    // MARK: - onHunkDismissed callback

    @Test func onHunkDismissedCalledWhenExpandedHunkSetToNil() {
        let tv = makeTextView()
        var dismissed = false
        tv.onHunkDismissed = { dismissed = true }

        tv.expandedHunkID = UUID()
        #expect(!dismissed)

        tv.expandedHunkID = nil
        #expect(dismissed)
    }

    @Test func onHunkDismissedNotCalledWhenSettingNewHunkID() {
        let tv = makeTextView()
        var dismissCount = 0
        tv.onHunkDismissed = { dismissCount += 1 }

        tv.expandedHunkID = UUID()
        tv.expandedHunkID = UUID() // switching to different hunk
        #expect(dismissCount == 0)
    }

    @Test func onHunkDismissedCalledFromDismissExpandedHunk() {
        let tv = makeTextView()
        var dismissed = false
        tv.onHunkDismissed = { dismissed = true }

        tv.expandedHunkID = UUID()
        tv.dismissExpandedHunk()
        #expect(dismissed)
    }

    // MARK: - HunkToolbarView basic creation

    @Test func hunkToolbarViewCreation() {
        let toolbar = HunkToolbarView()
        #expect(toolbar.accessibilityIdentifier() == AccessibilityID.hunkToolbar)
    }

    @Test func hunkToolbarViewShadowNotClipped() {
        let toolbar = HunkToolbarView()
        // masksToBounds must be false so shadow is visible
        #expect(toolbar.layer?.masksToBounds != true)
        #expect(toolbar.layer?.shadowOpacity == 1)
        #expect(toolbar.layer?.shadowRadius == 3)
    }

    @Test func hunkToolbarViewHasAppearanceColors() {
        let toolbar = HunkToolbarView()
        // Background and border should be set after init
        #expect(toolbar.layer?.backgroundColor != nil)
        #expect(toolbar.layer?.borderColor != nil)
        #expect(toolbar.layer?.borderWidth == 0.5)
    }

    @Test func hunkToolbarSeparatorsUpdateWithAppearance() {
        let toolbar = HunkToolbarView()
        // Separator views should be created and have background color
        #expect(toolbar.separatorViews.count == 2)
        for sep in toolbar.separatorViews {
            #expect(sep.layer?.backgroundColor != nil)
        }
        // Trigger appearance update — separator colors should still be set
        toolbar.viewDidChangeEffectiveAppearance()
        for sep in toolbar.separatorViews {
            #expect(sep.layer?.backgroundColor != nil)
        }
    }

    @Test func hunkToolbarViewSummaryText() {
        let toolbar = HunkToolbarView()
        toolbar.summaryText = "2/5 +3 -1"
        // Verify it doesn't crash and the frame is non-zero after layout
        let size = toolbar.idealSize()
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test func hunkToolbarViewActionCallback() {
        let toolbar = HunkToolbarView()
        var receivedAction: HunkToolbarAction?
        toolbar.onAction = { action in
            receivedAction = action
        }
        // Simulate action via callback
        toolbar.onAction?(.restore)
        #expect(receivedAction == .restore)
    }

    // MARK: - Hunk summary edge cases

    @Test func hunkSummaryForContextOnlyHunk() {
        // A hunk that has no added or deleted lines (shouldn't happen in practice, but test it)
        let hunk = DiffHunk(
            newStart: 1, newCount: 3, oldStart: 1, oldCount: 3,
            rawText: "@@ -1,3 +1,3 @@\n context1\n context2\n context3"
        )
        let summary = InlineDiffProvider.hunkSummary(hunk)
        #expect(summary.isEmpty)
    }

    // MARK: - Navigation with many hunks

    @Test func navigateNextThroughAllHunks() {
        let hunks = (0..<5).map { makeHunk(newStart: $0 * 10 + 1) }

        var current = hunks[0]
        for i in 1..<5 {
            guard let next = InlineDiffProvider.nextHunk(after: current, in: hunks) else {
                Issue.record("nextHunk returned nil at index \(i)")
                return
            }
            #expect(next.id == hunks[i].id)
            current = next
        }
        // Wrap around
        let wrapped = InlineDiffProvider.nextHunk(after: current, in: hunks)
        #expect(wrapped?.id == hunks[0].id)
    }

    @Test func navigatePreviousThroughAllHunks() {
        let hunks = (0..<5).map { makeHunk(newStart: $0 * 10 + 1) }

        var current = hunks[4]
        for i in stride(from: 3, through: 0, by: -1) {
            guard let prev = InlineDiffProvider.previousHunk(before: current, in: hunks) else {
                Issue.record("previousHunk returned nil at index \(i)")
                return
            }
            #expect(prev.id == hunks[i].id)
            current = prev
        }
        // Wrap around
        let wrapped = InlineDiffProvider.previousHunk(before: current, in: hunks)
        #expect(wrapped?.id == hunks[4].id)
    }

    // MARK: - Click outside with multiple hunks

    @Test func clickOutsideMultipleHunksDismisses() {
        let tv = makeTextView(text: String(repeating: "line\n", count: 30))
        let hunk1 = makeHunk(newStart: 2, newCount: 3)
        let hunk2 = makeHunk(newStart: 10, newCount: 2)
        tv.diffHunksForHighlight = [hunk1, hunk2]
        tv.expandedHunkID = hunk1.id

        // Line 7 is between hunk1 (2-4) and hunk2 (10-11)
        #expect(tv.shouldDismissHunkOnClick(atLine: 7) == true)
        // Line 10 is inside hunk2 but hunk1 is expanded, so should dismiss
        #expect(tv.shouldDismissHunkOnClick(atLine: 10) == true)
        // Line 3 is inside hunk1 (expanded), should not dismiss
        #expect(tv.shouldDismissHunkOnClick(atLine: 3) == false)
    }
}
