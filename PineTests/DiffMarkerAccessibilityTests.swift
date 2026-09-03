//
//  DiffMarkerAccessibilityTests.swift
//  PineTests
//
//  Differentiate Without Color support for the git diff markers drawn by the
//  editor gutter and the minimap (#1540).
//

import AppKit
import Testing

@testable import Pine

@Suite("Git Diff Marker Accessibility Cues")
@MainActor
struct DiffMarkerAccessibilityTests {

    // MARK: - Cue resolution

    @Test("Cue follows the Differentiate Without Color preference")
    func cueResolution() {
        #expect(GitDiffMarkerCue.resolve(differentiateWithoutColor: false) == .colorOnly)
        #expect(GitDiffMarkerCue.resolve(differentiateWithoutColor: true) == .shape)
    }

    // MARK: - Shape differentiation (acceptance criterion: added vs modified
    // must differ in shape or pattern, not only in hue)

    @Test("Without the preference the markers keep the historic color-only geometry")
    func colorOnlyShapes() {
        let cue = GitDiffMarkerCue.colorOnly
        #expect(cue.shape(for: .added) == .bar)
        #expect(cue.shape(for: .modified) == .bar)
        #expect(cue.shape(for: .deleted) == .triangle)
    }

    @Test("With the preference added and modified differ in shape")
    func shapeCueDifferentiatesAddedFromModified() {
        let cue = GitDiffMarkerCue.shape
        #expect(cue.shape(for: .added) == .bar)
        #expect(cue.shape(for: .modified) == .outlinedBar)
        #expect(
            cue.shape(for: .added) != cue.shape(for: .modified),
            "Added and modified must not rely on hue alone"
        )
        #expect(cue.shape(for: .deleted) == .triangle)
        #expect(
            Set([cue.shape(for: .added), cue.shape(for: .modified), cue.shape(for: .deleted)]).count == 3,
            "Every kind must have its own shape"
        )
    }

    // MARK: - Accessibility value

    @Test("Accessibility value is empty without markers")
    func accessibilityValueWithoutMarkers() {
        #expect(GitDiffMarkerCue.accessibilityValue(hasMarkers: false, cue: .shape).isEmpty)
        #expect(GitDiffMarkerCue.accessibilityValue(hasMarkers: false, cue: .colorOnly).isEmpty)
    }

    @Test("Accessibility value names the active cue")
    func accessibilityValueNamesCue() {
        let shapeValue = GitDiffMarkerCue.accessibilityValue(hasMarkers: true, cue: .shape)
        let colorValue = GitDiffMarkerCue.accessibilityValue(hasMarkers: true, cue: .colorOnly)
        #expect(!shapeValue.isEmpty)
        #expect(!colorValue.isEmpty)
        #expect(shapeValue != colorValue)
    }

    // MARK: - LineNumberView wiring

    @Test("Gutter exposes the marker cue mode once diffs arrive")
    func gutterAccessibilityValueFollowsDiffs() {
        let (view, _) = makeGutterView()
        view.lineDiffs = []
        #expect((view.accessibilityValue() as? String ?? "").isEmpty)

        view.lineDiffs = [
            GitLineDiff(line: 1, kind: .added),
            GitLineDiff(line: 2, kind: .modified),
        ]
        let expected = GitDiffMarkerCue.accessibilityValue(
            hasMarkers: true,
            cue: GitDiffMarkerCue.resolve(
                differentiateWithoutColor: NSWorkspace.shared
                    .accessibilityDisplayShouldDifferentiateWithoutColor
            )
        )
        #expect((view.accessibilityValue() as? String ?? "") == expected)

        view.lineDiffs = []
        #expect((view.accessibilityValue() as? String ?? "").isEmpty)
    }

    @Test("Gutter repaints and refreshes its AX value when display options change")
    func gutterRepaintsOnDisplayOptionsChange() {
        let (view, _) = makeGutterView()
        view.lineDiffs = [GitLineDiff(line: 1, kind: .added)]
        #expect(view.accessibilityOptionsChangeCount == 0)

        // The notification must arrive through the workspace's own center
        // (#1540 review): registering on NotificationCenter.default never
        // delivers it, and the live preference read would silently stay
        // stale. `needsDisplay` is not observable on a windowless test view,
        // so the delivery proof goes through the debug counter — the same
        // pattern as `boundsChangeCount`.
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        #expect(view.accessibilityOptionsChangeCount == 1, "The gutter observer must fire")
        #expect(
            !(view.accessibilityValue() as? String ?? "").isEmpty,
            "The AX value must stay in sync with the current cue"
        )
    }

    // MARK: - MinimapView wiring

    @Test("Minimap exposes the marker cue mode once diffs arrive")
    func minimapAccessibilityValueFollowsDiffs() {
        let (_, textView) = makeGutterView()
        let minimap = MinimapView(textView: textView)
        minimap.lineDiffs = []
        #expect((minimap.accessibilityValue() as? String ?? "").isEmpty)

        minimap.lineDiffs = [GitLineDiff(line: 1, kind: .modified)]
        let expected = GitDiffMarkerCue.accessibilityValue(
            hasMarkers: true,
            cue: GitDiffMarkerCue.resolve(
                differentiateWithoutColor: NSWorkspace.shared
                    .accessibilityDisplayShouldDifferentiateWithoutColor
            )
        )
        #expect((minimap.accessibilityValue() as? String ?? "") == expected)
    }

    @Test("Minimap repaints and refreshes its AX value when display options change")
    func minimapRepaintsOnDisplayOptionsChange() {
        let (_, textView) = makeGutterView()
        let minimap = MinimapView(textView: textView)
        minimap.lineDiffs = [GitLineDiff(line: 1, kind: .modified)]
        #expect(minimap.accessibilityOptionsChangeCount == 0)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        #expect(minimap.accessibilityOptionsChangeCount == 1, "The minimap observer must fire")
        #expect(
            !(minimap.accessibilityValue() as? String ?? "").isEmpty,
            "The AX value must stay in sync with the current cue"
        )
    }

    // MARK: - Helpers

    private func makeGutterView(
        text: String = "line1\nline2\nline3"
    ) -> (LineNumberView, NSTextView) {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView
        return (LineNumberView(textView: textView), textView)
    }
}
