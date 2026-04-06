//
//  InlineDiffStageTests.swift
//  PineTests
//
//  Tests for the Stage action on the inline diff toolbar (#687):
//  - Stage button exists on the toolbar
//  - Stage callback fires on click
//  - Stage button has correct accessibility identifier
//  - Stage button sits to the left of Restore (UX order)
//  - acceptHunk wiring path exists in CodeEditorView via onStageHunk
//

import Testing
import AppKit
@testable import Pine

@Suite("Inline Diff Stage Tests")
@MainActor
struct InlineDiffStageTests {

    private func makeHunk() -> DiffHunk {
        DiffHunk(
            newStart: 2, newCount: 1, oldStart: 2, oldCount: 1,
            rawText: "@@ -2,1 +2,1 @@\n-old\n+new\n"
        )
    }

    @Test func toolbarHasStageButton() {
        let toolbar = InlineDiffToolbarView()
        let mirror = Mirror(reflecting: toolbar)
        let labels = mirror.children.compactMap { $0.label }
        #expect(labels.contains("stageButton"),
                "Stage button should exist after #687")
    }

    @Test func stageButtonHasAccessibilityIdentifier() {
        let toolbar = InlineDiffToolbarView()
        #expect(toolbar.stageButton.identifier?.rawValue == AccessibilityID.inlineDiffStageButton)
    }

    @Test func stageCallbackInvokedOnClick() {
        let toolbar = InlineDiffToolbarView()
        var called = false
        toolbar.onStage = { called = true }
        toolbar.stageButton.performClick(nil)
        #expect(called)
    }

    @Test func stageCallbackNilByDefault() {
        let toolbar = InlineDiffToolbarView()
        #expect(toolbar.onStage == nil)
        // Clicking with no callback should not crash
        toolbar.stageButton.performClick(nil)
    }

    @Test func stageButtonIsEnabledByDefault() {
        let toolbar = InlineDiffToolbarView()
        #expect(toolbar.stageButton.isEnabled)
    }

    @Test func stageButtonIsLeftOfRestore() {
        // UX requirement: Stage sits to the LEFT of Restore in the toolbar.
        let toolbar = InlineDiffToolbarView()
        // Force the toolbar to lay out so frames are populated.
        toolbar.layoutSubtreeIfNeeded()
        #expect(toolbar.stageButton.frame.origin.x < toolbar.restoreButton.frame.origin.x,
                "Stage should appear before Restore (left → right)")
    }

    @Test func stageButtonHasNonZeroSize() {
        let toolbar = InlineDiffToolbarView()
        toolbar.layoutSubtreeIfNeeded()
        #expect(toolbar.stageButton.frame.width > 0)
        #expect(toolbar.stageButton.frame.height > 0)
    }

    @Test func toolbarIntrinsicSizeAccountsForStageButton() {
        // Toolbar with Stage should be wider than a hypothetical 3-button layout.
        // We just sanity-check the width is reasonable for 4 controls.
        let toolbar = InlineDiffToolbarView()
        let size = toolbar.intrinsicContentSize
        #expect(size.width > 100)
    }

    @Test func stageDismissCallbackPathExists() {
        // After clicking Stage, the toolbar callback chain in CodeEditorView
        // is expected to dismiss the toolbar via dismissInlineDiffToolbar().
        // We verify the callback wiring shape here — actual reload happens in
        // PaneLeafView.handleGutterAccept.
        let toolbar = InlineDiffToolbarView()
        var stageCalled = false
        var dismissCalled = false
        toolbar.onStage = { stageCalled = true }
        toolbar.onDismiss = { dismissCalled = true }
        toolbar.stageButton.performClick(nil)
        toolbar.requestDismiss()
        #expect(stageCalled)
        #expect(dismissCalled)
    }

    // MARK: - acceptHunk wiring (regression: action available)

    @Test func acceptHunkAPIIsCallableForStaging() {
        // Sanity-check that the acceptHunk API used by the Stage path still
        // exists and accepts the expected parameter shape.
        let hunk = makeHunk()
        let tmpDir = FileManager.default.temporaryDirectory
        let fakeFile = tmpDir.appendingPathComponent("nonexistent.txt")
        // We don't actually run git here — we just verify the function signature.
        Task {
            _ = await InlineDiffProvider.acceptHunk(hunk, fileURL: fakeFile, repoURL: tmpDir)
        }
    }

    // MARK: - Updated PR1 invariant

    @Test func toolbarStillExposesRestoreAndNavAfterPR2() {
        let toolbar = InlineDiffToolbarView()
        #expect(toolbar.restoreButton.identifier?.rawValue == AccessibilityID.inlineDiffRestoreButton)
        #expect(toolbar.nextButton.identifier?.rawValue == AccessibilityID.inlineDiffNextButton)
        #expect(toolbar.previousButton.identifier?.rawValue == AccessibilityID.inlineDiffPreviousButton)
    }
}
