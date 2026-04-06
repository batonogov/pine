//
//  InlineDiffToolbarTests.swift
//  PineTests
//
//  Tests for the floating inline diff toolbar (#689):
//  - Hunk navigation without wrap-around (within file boundaries)
//  - Restore callback wiring
//  - Dismiss on edit / outside click
//  - Edge cases for navigation (single hunk, multi hunk, boundaries)
//

import Testing
import AppKit
@testable import Pine

@Suite("Inline Diff Toolbar Tests")
@MainActor
struct InlineDiffToolbarTests {

    // MARK: - Helpers

    private func makeHunk(
        newStart: Int,
        newCount: Int = 1,
        oldStart: Int = 1,
        oldCount: Int = 1,
        rawText: String = "@@ -1,1 +1,1 @@\n-old\n+new\n"
    ) -> DiffHunk {
        DiffHunk(
            newStart: newStart,
            newCount: newCount,
            oldStart: oldStart,
            oldCount: oldCount,
            rawText: rawText
        )
    }

    // MARK: - Navigation: nextHunk (no wrap)

    @Test func nextHunkReturnsNilWhenNoHunks() {
        let result = InlineDiffNavigator.nextHunk(after: nil, in: [])
        #expect(result == nil)
    }

    @Test func nextHunkFromNilReturnsFirst() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        let result = InlineDiffNavigator.nextHunk(after: nil, in: [h1, h2])
        #expect(result?.id == h1.id)
    }

    @Test func nextHunkReturnsFollowingHunk() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        let h3 = makeHunk(newStart: 10)
        let result = InlineDiffNavigator.nextHunk(after: h2.id, in: [h1, h2, h3])
        #expect(result?.id == h3.id)
    }

    @Test func nextHunkOnLastReturnsNilNoWrap() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        let result = InlineDiffNavigator.nextHunk(after: h2.id, in: [h1, h2])
        #expect(result == nil, "No wrap-around: next on last hunk returns nil")
    }

    @Test func nextHunkWithUnknownIDReturnsFirst() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        let result = InlineDiffNavigator.nextHunk(after: UUID(), in: [h1, h2])
        #expect(result?.id == h1.id)
    }

    // MARK: - Navigation: previousHunk (no wrap)

    @Test func previousHunkReturnsNilWhenNoHunks() {
        let result = InlineDiffNavigator.previousHunk(before: nil, in: [])
        #expect(result == nil)
    }

    @Test func previousHunkFromNilReturnsLast() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        let result = InlineDiffNavigator.previousHunk(before: nil, in: [h1, h2])
        #expect(result?.id == h2.id)
    }

    @Test func previousHunkReturnsPrecedingHunk() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        let h3 = makeHunk(newStart: 10)
        let result = InlineDiffNavigator.previousHunk(before: h3.id, in: [h1, h2, h3])
        #expect(result?.id == h2.id)
    }

    @Test func previousHunkOnFirstReturnsNilNoWrap() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        let result = InlineDiffNavigator.previousHunk(before: h1.id, in: [h1, h2])
        #expect(result == nil, "No wrap-around: previous on first hunk returns nil")
    }

    @Test func previousHunkWithSingleHunkReturnsNil() {
        let h1 = makeHunk(newStart: 2)
        let result = InlineDiffNavigator.previousHunk(before: h1.id, in: [h1])
        #expect(result == nil)
    }

    @Test func nextHunkWithSingleHunkReturnsNil() {
        let h1 = makeHunk(newStart: 2)
        let result = InlineDiffNavigator.nextHunk(after: h1.id, in: [h1])
        #expect(result == nil)
    }

    // MARK: - Boundary checks (canGoNext / canGoPrevious)

    @Test func canGoNextFalseAtLastHunk() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        #expect(!InlineDiffNavigator.canGoNext(from: h2.id, in: [h1, h2]))
    }

    @Test func canGoNextTrueWhenMoreHunksFollow() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        #expect(InlineDiffNavigator.canGoNext(from: h1.id, in: [h1, h2]))
    }

    @Test func canGoPreviousFalseAtFirstHunk() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        #expect(!InlineDiffNavigator.canGoPrevious(from: h1.id, in: [h1, h2]))
    }

    @Test func canGoPreviousTrueWhenEarlierHunksExist() {
        let h1 = makeHunk(newStart: 2)
        let h2 = makeHunk(newStart: 5)
        #expect(InlineDiffNavigator.canGoPrevious(from: h2.id, in: [h1, h2]))
    }

    @Test func canGoNextFalseWithSingleHunk() {
        let h1 = makeHunk(newStart: 2)
        #expect(!InlineDiffNavigator.canGoNext(from: h1.id, in: [h1]))
    }

    @Test func canGoPreviousFalseWithSingleHunk() {
        let h1 = makeHunk(newStart: 2)
        #expect(!InlineDiffNavigator.canGoPrevious(from: h1.id, in: [h1]))
    }

    @Test func canGoNextFalseWithEmptyHunks() {
        #expect(!InlineDiffNavigator.canGoNext(from: nil, in: []))
    }

    @Test func canGoPreviousFalseWithEmptyHunks() {
        #expect(!InlineDiffNavigator.canGoPrevious(from: nil, in: []))
    }

    // MARK: - InlineDiffToolbarView (PR1: Restore + nav, no Stage)

    @Test func toolbarHasRestoreAndNavButtons() {
        let toolbar = InlineDiffToolbarView()
        #expect(toolbar.restoreButton.identifier?.rawValue == AccessibilityID.inlineDiffRestoreButton)
        #expect(toolbar.nextButton.identifier?.rawValue == AccessibilityID.inlineDiffNextButton)
        #expect(toolbar.previousButton.identifier?.rawValue == AccessibilityID.inlineDiffPreviousButton)
    }

@Test func restoreCallbackIsInvokedOnButtonClick() {
        let toolbar = InlineDiffToolbarView()
        var called = false
        toolbar.onRestore = { called = true }
        toolbar.restoreButton.performClick(nil)
        #expect(called)
    }

    @Test func nextCallbackIsInvokedOnButtonClick() {
        let toolbar = InlineDiffToolbarView()
        var called = false
        toolbar.onNext = { called = true }
        toolbar.nextButton.performClick(nil)
        #expect(called)
    }

    @Test func previousCallbackIsInvokedOnButtonClick() {
        let toolbar = InlineDiffToolbarView()
        var called = false
        toolbar.onPrevious = { called = true }
        toolbar.previousButton.performClick(nil)
        #expect(called)
    }

    @Test func dismissCallbackInvoked() {
        let toolbar = InlineDiffToolbarView()
        var called = false
        toolbar.onDismiss = { called = true }
        toolbar.requestDismiss()
        #expect(called)
    }

    // MARK: - Button enabled state mirrors navigation availability

    @Test func updateNavigationStateDisablesButtonsAtBoundaries() {
        let toolbar = InlineDiffToolbarView()
        toolbar.updateNavigationState(canGoNext: false, canGoPrevious: false)
        #expect(!toolbar.nextButton.isEnabled)
        #expect(!toolbar.previousButton.isEnabled)
    }

    @Test func updateNavigationStateEnablesButtons() {
        let toolbar = InlineDiffToolbarView()
        toolbar.updateNavigationState(canGoNext: true, canGoPrevious: true)
        #expect(toolbar.nextButton.isEnabled)
        #expect(toolbar.previousButton.isEnabled)
    }

    @Test func updateNavigationStateMixed() {
        let toolbar = InlineDiffToolbarView()
        toolbar.updateNavigationState(canGoNext: true, canGoPrevious: false)
        #expect(toolbar.nextButton.isEnabled)
        #expect(!toolbar.previousButton.isEnabled)
    }

    // MARK: - Toolbar sizing

    @Test func toolbarHasNonZeroIntrinsicSize() {
        let toolbar = InlineDiffToolbarView()
        let size = toolbar.intrinsicContentSize
        #expect(size.width > 0)
        #expect(size.height > 0)
    }
}
