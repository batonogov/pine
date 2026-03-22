//
//  LineNumberViewTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for LineNumberView (LineNumberGutter.swift) — data management, properties, mouse handling.
struct LineNumberViewTests {

    private func makeTextView(text: String = "line1\nline2\nline3") -> NSTextView {
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
        return textView
    }

    private func makeView(text: String = "line1\nline2\nline3") -> (LineNumberView, NSTextView) {
        let textView = makeTextView(text: text)
        let view = LineNumberView(textView: textView)
        return (view, textView)
    }

    // MARK: - Initialization

    @Test func initialization_setsTextView() {
        let (view, textView) = makeView()
        #expect(view.textView === textView)
    }

    @Test func initialization_defaultGutterWidth() {
        let (view, _) = makeView()
        #expect(view.gutterWidth == 40)
    }

    @Test func initialization_isFlipped() {
        let (view, _) = makeView()
        #expect(view.isFlipped == true)
    }

    @Test func initialization_emptyDiffs() {
        let (view, _) = makeView()
        #expect(view.lineDiffs.isEmpty)
    }

    @Test func initialization_emptyFoldableRanges() {
        let (view, _) = makeView()
        #expect(view.foldableRanges.isEmpty)
    }

    @Test func initialization_emptyFoldState() {
        let (view, _) = makeView()
        #expect(view.foldState.foldedRanges.isEmpty)
    }

    // MARK: - baselineOffset

    @Test func baselineOffset_calculatedFromFonts() {
        let (view, _) = makeView()
        let editorFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let gutterFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.editorFont = editorFont
        view.gutterFont = gutterFont
        let expected = editorFont.ascender - gutterFont.ascender
        #expect(view.baselineOffset == expected)
    }

    @Test func baselineOffset_zeroWhenFontsMatch() {
        let (view, _) = makeView()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.editorFont = font
        view.gutterFont = font
        #expect(view.baselineOffset == 0)
    }

    // MARK: - lineDiffs property

    @Test func lineDiffs_setsAndRebuildsMap() {
        let (view, _) = makeView()
        view.lineDiffs = [
            GitLineDiff(line: 1, kind: .added),
            GitLineDiff(line: 3, kind: .modified),
            GitLineDiff(line: 5, kind: .deleted),
        ]
        #expect(view.lineDiffs.count == 3)
    }

    @Test func lineDiffs_duplicateLineLastWins() {
        let (view, _) = makeView()
        view.lineDiffs = [
            GitLineDiff(line: 1, kind: .added),
            GitLineDiff(line: 1, kind: .modified),
        ]
        #expect(view.lineDiffs.count == 2)
    }

    @Test func lineDiffs_emptyArray() {
        let (view, _) = makeView()
        view.lineDiffs = [GitLineDiff(line: 1, kind: .added)]
        view.lineDiffs = []
        #expect(view.lineDiffs.isEmpty)
    }

    // MARK: - foldableRanges property

    @Test func foldableRanges_setsAndRebuildsMap() {
        let (view, _) = makeView()
        view.foldableRanges = [
            FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 50, kind: .braces),
            FoldableRange(startLine: 10, endLine: 15, startCharIndex: 100, endCharIndex: 200, kind: .brackets),
        ]
        #expect(view.foldableRanges.count == 2)
    }

    @Test func foldableRanges_emptyArray() {
        let (view, _) = makeView()
        view.foldableRanges = [FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 50, kind: .braces)]
        view.foldableRanges = []
        #expect(view.foldableRanges.isEmpty)
    }

    // MARK: - foldState property

    @Test func foldState_canBeSet() {
        let (view, _) = makeView()
        var state = FoldState()
        let range = FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 50, kind: .braces)
        state.fold(range)
        view.foldState = state
        #expect(view.foldState.isFolded(range))
    }

    // MARK: - onFoldToggle callback

    @Test func onFoldToggle_callbackInvoked() {
        let (view, _) = makeView()
        var toggledRange: FoldableRange?
        view.onFoldToggle = { range in
            toggledRange = range
        }
        let range = FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 50, kind: .braces)
        view.onFoldToggle?(range)
        #expect(toggledRange?.startLine == 1)
        #expect(toggledRange?.endLine == 5)
    }

    // MARK: - lineStartsCache

    @Test func lineStartsCache_defaultNil() {
        let (view, _) = makeView()
        #expect(view.lineStartsCache == nil)
    }

    @Test func lineStartsCache_canBeSet() {
        let (view, _) = makeView()
        let cache = LineStartsCache(text: "a\nb\nc")
        view.lineStartsCache = cache
        #expect(view.lineStartsCache != nil)
    }

    // MARK: - gutterWidth

    @Test func gutterWidth_canBeChanged() {
        let (view, _) = makeView()
        view.gutterWidth = 60
        #expect(view.gutterWidth == 60)
    }

    // MARK: - Accessibility

    @Test func accessibilityIdentifier_set() {
        let (view, _) = makeView()
        #expect(view.accessibilityIdentifier() == AccessibilityID.lineNumberGutter)
    }
}
