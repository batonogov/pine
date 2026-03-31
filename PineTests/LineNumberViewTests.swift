//
//  LineNumberViewTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for LineNumberView (LineNumberGutter.swift) — properties and data management.
@Suite("LineNumberView Tests")
@MainActor
struct LineNumberViewTests {

    private func makeView(text: String = "line1\nline2\nline3") -> (LineNumberView, NSTextView) {
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
        let view = LineNumberView(textView: textView)
        return (view, textView)
    }

    // MARK: - Initialization

    @Test func initializationSetsDefaults() {
        let (view, textView) = makeView()
        #expect(view.textView === textView)
        #expect(view.gutterWidth == 40)
        #expect(view.isFlipped == true)
        #expect(view.lineDiffs.isEmpty)
        #expect(view.foldableRanges.isEmpty)
        #expect(view.foldState.foldedRanges.isEmpty)
        #expect(view.accessibilityIdentifier() == AccessibilityID.lineNumberGutter)
    }

    // MARK: - baselineOffset

    @Test func baselineOffsetCalculatedFromFontAscenders() {
        let (view, _) = makeView()
        let editorFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let gutterFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.editorFont = editorFont
        view.gutterFont = gutterFont
        #expect(view.baselineOffset == editorFont.ascender - gutterFont.ascender)
    }

    @Test func baselineOffsetZeroWhenFontsMatch() {
        let (view, _) = makeView()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.editorFont = font
        view.gutterFont = font
        #expect(view.baselineOffset == 0)
    }

    // MARK: - Diff data management

    @Test func lineDiffsRebuildsLookupMap() {
        let (view, _) = makeView()
        view.lineDiffs = [
            GitLineDiff(line: 1, kind: .added),
            GitLineDiff(line: 3, kind: .modified),
            GitLineDiff(line: 5, kind: .deleted),
        ]
        #expect(view.lineDiffs.count == 3)

        // Clear
        view.lineDiffs = []
        #expect(view.lineDiffs.isEmpty)
    }

    // MARK: - Foldable ranges

    @Test func foldableRangesRebuildsStartMap() {
        let (view, _) = makeView()
        view.foldableRanges = [
            FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 50, kind: .braces),
            FoldableRange(startLine: 10, endLine: 15, startCharIndex: 100, endCharIndex: 200, kind: .brackets),
        ]
        #expect(view.foldableRanges.count == 2)
    }

    // MARK: - Fold state

    @Test func foldStateTracksCurrentFolds() {
        let (view, _) = makeView()
        var state = FoldState()
        let range = FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 50, kind: .braces)
        state.fold(range)
        view.foldState = state
        #expect(view.foldState.isFolded(range))
    }

    // MARK: - onFoldToggle

    @Test func onFoldToggleCallbackInvoked() {
        let (view, _) = makeView()
        var toggledRange: FoldableRange?
        view.onFoldToggle = { toggledRange = $0 }

        let range = FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 50, kind: .braces)
        view.onFoldToggle?(range)
        #expect(toggledRange?.startLine == 1)
        #expect(toggledRange?.endLine == 5)
    }
}
