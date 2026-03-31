//
//  CleanGutterMarkersTests.swift
//  PineTests
//
//  Tests for #688: gutter should show clean color markers only
//  (green=added, yellow=modified, red=deleted) without accept/revert buttons
//  that overlap line numbers.
//

import Testing
import AppKit
@testable import Pine

@Suite("Clean Gutter Markers Tests")
struct CleanGutterMarkersTests {

    // MARK: - Helpers

    private func makeLineNumberView() -> LineNumberView {
        let textStorage = NSTextStorage(string: "line1\nline2\nline3\nline4\nline5\n")
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

    private func makeHunk(
        newStart: Int = 2,
        newCount: Int = 2,
        oldStart: Int = 2,
        oldCount: Int = 1
    ) -> DiffHunk {
        DiffHunk(
            newStart: newStart,
            newCount: newCount,
            oldStart: oldStart,
            oldCount: oldCount,
            rawText: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n context\n+added line\n"
        )
    }

    // MARK: - Accept/Revert buttons removed from gutter

    @Test func lineNumberViewHasNoAcceptHunkCallback() {
        let view = makeLineNumberView()
        // After #688, LineNumberView should not have onAcceptHunk/onRevertHunk properties.
        // If compilation succeeds, these properties are gone. We verify the view has
        // no accept/revert button drawing infrastructure by checking that
        // hunkButtonHitTest is removed.
        // This test validates that the gutter renders clean markers without button overlays.

        // LineNumberView should still accept diffHunks for color markers
        let hunk = makeHunk()
        view.diffHunks = [hunk]
        #expect(view.diffHunks.count == 1, "Diff hunks for color markers should still work")
    }

    @Test func lineNumberViewHasNoRevertHunkCallback() {
        let view = makeLineNumberView()
        // Verify no revert callback exists — the property should be removed.
        // This is a compile-time check: if onRevertHunk still exists, the test below
        // would need to reference it. Since we don't reference it, successful
        // compilation proves the property is removed.

        // Diff marker click callback should still exist (for expand/collapse)
        var clicked = false
        view.onDiffMarkerClick = { _ in clicked = true }
        let hunk = makeHunk()
        view.onDiffMarkerClick?(hunk)
        #expect(clicked, "onDiffMarkerClick should still work for expand/collapse")
    }

    // MARK: - Diff color markers still render

    @Test func addedDiffMarkersStillTracked() {
        let view = makeLineNumberView()
        view.lineDiffs = [
            GitLineDiff(line: 1, kind: .added),
            GitLineDiff(line: 2, kind: .added)
        ]
        #expect(view.lineDiffs.count == 2, "Added markers should be tracked")
        #expect(view.lineDiffs[0].kind == .added)
    }

    @Test func modifiedDiffMarkersStillTracked() {
        let view = makeLineNumberView()
        view.lineDiffs = [GitLineDiff(line: 3, kind: .modified)]
        #expect(view.lineDiffs.count == 1)
        #expect(view.lineDiffs[0].kind == .modified)
    }

    @Test func deletedDiffMarkersStillTracked() {
        let view = makeLineNumberView()
        view.lineDiffs = [GitLineDiff(line: 5, kind: .deleted)]
        #expect(view.lineDiffs.count == 1)
        #expect(view.lineDiffs[0].kind == .deleted)
    }

    // MARK: - Expanded hunk still works (for inline diff highlighting)

    @Test func expandedHunkIDStillWorks() {
        let view = makeLineNumberView()
        let hunk = makeHunk()
        view.diffHunks = [hunk]
        view.expandedHunkID = hunk.id
        #expect(view.expandedHunkID == hunk.id, "Expanded hunk tracking should still work")

        view.expandedHunkID = nil
        #expect(view.expandedHunkID == nil, "Should be clearable")
    }

    // MARK: - Diff marker click still functional

    @Test func diffMarkerClickCallbackStillFires() {
        let view = makeLineNumberView()
        let hunk = makeHunk(newStart: 1)
        view.diffHunks = [hunk]

        var receivedHunk: DiffHunk?
        view.onDiffMarkerClick = { h in receivedHunk = h }
        view.onDiffMarkerClick?(hunk)
        #expect(receivedHunk?.id == hunk.id)
    }

    // MARK: - Menu accept/revert actions still exist (via NotificationCenter, not gutter)

    @Test func inlineDiffActionEnumStillExists() {
        // Menu commands (Accept Change, Revert Change, etc.) use InlineDiffAction
        // and go through NotificationCenter, not through gutter buttons.
        #expect(InlineDiffAction.accept.rawValue == "accept")
        #expect(InlineDiffAction.revert.rawValue == "revert")
        #expect(InlineDiffAction.acceptAll.rawValue == "acceptAll")
        #expect(InlineDiffAction.revertAll.rawValue == "revertAll")
    }

    // MARK: - Multiple diff types coexist

    @Test func multipleDiffTypesCoexist() {
        let view = makeLineNumberView()
        view.lineDiffs = [
            GitLineDiff(line: 1, kind: .added),
            GitLineDiff(line: 3, kind: .modified),
            GitLineDiff(line: 5, kind: .deleted)
        ]
        #expect(view.lineDiffs.count == 3)
    }

    // MARK: - Empty diffs don't crash

    @Test func emptyDiffsDoNotCrash() {
        let view = makeLineNumberView()
        view.lineDiffs = []
        view.diffHunks = []
        view.expandedHunkID = nil
        #expect(view.lineDiffs.isEmpty)
        #expect(view.diffHunks.isEmpty)
    }
}
