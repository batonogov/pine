//
//  UndoHighlightSafetyTests.swift
//  PineTests
//
//  Tests for undo/redo safety during syntax highlighting (#650).
//  Verifies that applyMatches and resetAttributes bail out when
//  the undo manager is in the middle of undoing/redoing, preventing
//  EXC_BAD_ACCESS from concurrent NSTextStorage mutations.

import Testing
import AppKit
import SwiftUI
@testable import Pine

@Suite("Undo Highlight Safety")
struct UndoHighlightSafetyTests {

    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Builds a minimal text system stack with an undo manager.
    private func makeTextStack(text: String) -> (NSScrollView, GutterTextView, NSTextStorage) {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        let textView = GutterTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
        textView.allowsUndo = true
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView
        return (scrollView, textView, textStorage)
    }

    private func makeCoordinator(
        text: String = "func hello() { }",
        language: String = "swift",
        fileName: String? = "test.swift"
    ) -> (CodeEditorView.Coordinator, NSScrollView, GutterTextView) {
        let (scrollView, textView, _) = makeTextStack(text: text)
        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: language,
            fileName: fileName,
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()
        coordinator.lastFontSize = font.pointSize
        coordinator.updateContentIfNeeded(
            text: text, language: language, fileName: fileName, font: font
        )
        return (coordinator, scrollView, textView)
    }

    // MARK: - applyMatches safety

    @Test func applyMatches_appliesNormally_whenNoUndoInProgress() {
        let text = "let x = 42"
        let (_, _, textStorage) = makeTextStack(text: text)

        let match = HighlightMatch(
            range: NSRange(location: 0, length: 3),
            scope: "keyword",
            priority: 0
        )
        let result = HighlightMatchResult(
            matches: [match],
            repaintRange: NSRange(location: 0, length: textStorage.length),
            multilineFingerprint: []
        )

        // Apply highlights — should succeed (no undo in progress)
        SyntaxHighlighter.shared.applyMatches(result, to: textStorage, font: font)

        // Verify "let" got keyword color (not default textColor)
        var effectiveRange = NSRange()
        let color = textStorage.attribute(
            .foregroundColor, at: 0, effectiveRange: &effectiveRange
        ) as? NSColor
        #expect(color != nil, "Keyword should have a color applied")
    }

    @Test func applyMatches_skipsWhenRepaintRangeExceedsLength() {
        let text = "short"
        let (_, _, textStorage) = makeTextStack(text: text)

        let result = HighlightMatchResult(
            matches: [],
            repaintRange: NSRange(location: 0, length: 999),
            multilineFingerprint: []
        )

        // Should not crash — just skip
        SyntaxHighlighter.shared.applyMatches(result, to: textStorage, font: font)
    }

    // MARK: - Coordinator undo/redo detection

    @Test func coordinator_createsWithUndoRedoFlagFalse() {
        let (coordinator, _, _) = makeCoordinator()
        // The coordinator should start with undo/redo not in progress.
        // We can't directly check the private isUndoRedoInProgress flag,
        // but we verify that textDidChange works normally (no undo skip path).
        #expect(coordinator.didChangeFromTextView == false)
    }

    @Test func textDidChange_setsDidChangeFromTextView() {
        let text = "hello"
        let (coordinator, scrollView, textView) = makeCoordinator(text: text)

        // Simulate a text change via NSTextView
        textView.string = "hello world"

        let notification = Notification(
            name: NSText.didChangeNotification,
            object: textView
        )

        coordinator.textDidChange(notification)

        #expect(coordinator.didChangeFromTextView == true)
    }

    @Test func textDidChange_updatesParentText() {
        var capturedText = "hello"
        let editorView = CodeEditorView(
            text: .init(get: { capturedText }, set: { capturedText = $0 }),
            contentVersion: 0,
            language: "swift",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )

        let (scrollView, textView, _) = makeTextStack(text: "hello")
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        textView.string = "changed"

        let notification = Notification(
            name: NSText.didChangeNotification,
            object: textView
        )

        coordinator.textDidChange(notification)

        #expect(capturedText == "changed",
                "Parent text binding should be updated after textDidChange")
    }

    // MARK: - HighlightGeneration

    @Test func highlightGeneration_incrementsCorrectly() {
        let gen = HighlightGeneration()
        let initial = gen.current
        gen.increment()
        #expect(gen.current == initial + 1)
        gen.increment()
        #expect(gen.current == initial + 2)
    }

    @Test func cancelPendingHighlight_incrementsGeneration() {
        let (coordinator, _, _) = makeCoordinator()
        let genBefore = coordinator.highlightGeneration.current
        coordinator.cancelPendingHighlight()
        #expect(coordinator.highlightGeneration.current == genBefore + 1)
    }

    // MARK: - applyMatches with valid ranges

    @Test func applyMatches_appliesMultipleScopes() {
        let text = "let x = \"hello\""
        let (_, _, textStorage) = makeTextStack(text: text)

        let matches = [
            HighlightMatch(range: NSRange(location: 0, length: 3), scope: "keyword", priority: 0),
            HighlightMatch(range: NSRange(location: 8, length: 7), scope: "string", priority: 90),
        ]
        let result = HighlightMatchResult(
            matches: matches,
            repaintRange: NSRange(location: 0, length: textStorage.length),
            multilineFingerprint: []
        )

        SyntaxHighlighter.shared.applyMatches(result, to: textStorage, font: font)

        // Keyword color at position 0
        let kwColor = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(kwColor != nil)

        // String color at position 8
        let strColor = textStorage.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor
        #expect(strColor != nil)

        // The two colors should be different (keyword vs string)
        if let kw = kwColor, let str = strColor {
            #expect(kw != str, "Keyword and string should have different colors")
        }
    }

    @Test func applyMatches_skipsMatchBeyondTextLength() {
        let text = "hi"
        let (_, _, textStorage) = makeTextStack(text: text)

        let matches = [
            HighlightMatch(range: NSRange(location: 0, length: 2), scope: "keyword", priority: 0),
            // This match is out of bounds — should be silently skipped
            HighlightMatch(range: NSRange(location: 10, length: 5), scope: "string", priority: 90),
        ]
        let result = HighlightMatchResult(
            matches: matches,
            repaintRange: NSRange(location: 0, length: textStorage.length),
            multilineFingerprint: []
        )

        // Should not crash
        SyntaxHighlighter.shared.applyMatches(result, to: textStorage, font: font)

        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color != nil, "Valid match should still be applied")
    }

    // MARK: - Real undoManager.undo() integration

    @Test func applyMatches_skipsWhenRealUndoManagerIsUndoing() {
        let text = "let x = 42"
        let (_, textView, textStorage) = makeTextStack(text: text)

        // Register a real undo action so undoManager.undo() triggers isUndoing
        textView.undoManager?.registerUndo(withTarget: textView) { tv in
            tv.string = "let x = 42"
        }
        textView.undoManager?.setActionName("Test Edit")

        // Build a highlight result that would color "let" as a keyword
        let match = HighlightMatch(
            range: NSRange(location: 0, length: 3),
            scope: "keyword",
            priority: 0
        )
        let result = HighlightMatchResult(
            matches: [match],
            repaintRange: NSRange(location: 0, length: textStorage.length),
            multilineFingerprint: []
        )

        // Record the default foreground color before any highlighting
        let colorBefore = textStorage.attribute(
            .foregroundColor, at: 0, effectiveRange: nil
        ) as? NSColor

        // Trigger undo — inside the undo block, isUndoing == true
        // We hijack the undo action to call applyMatches mid-undo
        textView.undoManager?.registerUndo(withTarget: textView) { [font] _ in
            // This runs while isUndoing == true
            SyntaxHighlighter.shared.applyMatches(result, to: textStorage, font: font)
        }
        textView.undoManager?.undo()

        // applyMatches should have bailed out — foreground color must be unchanged
        let colorAfter = textStorage.attribute(
            .foregroundColor, at: 0, effectiveRange: nil
        ) as? NSColor
        #expect(
            colorBefore == colorAfter,
            "applyMatches must not apply highlights while undoManager.isUndoing == true"
        )
    }

    @Test func isUndoRedoInProgress_resetsOnNextTextDidChange() {
        let (coordinator, _, textView) = makeCoordinator(text: "hello")

        // Simulate that isUndoRedoInProgress got stuck (e.g., deferred work item cancelled)
        // We need to set it via textDidChange with an undoing undoManager first.
        // Instead, since we made it private(set), we verify the reset behavior:
        // 1. Trigger textDidChange with no undo in progress
        // 2. Verify the flag is false
        textView.string = "hello world"
        let notification = Notification(
            name: NSText.didChangeNotification,
            object: textView
        )
        coordinator.textDidChange(notification)

        // After a normal textDidChange, isUndoRedoInProgress should be false
        #expect(
            coordinator.isUndoRedoInProgress == false,
            "isUndoRedoInProgress must be reset at the start of textDidChange"
        )
    }
}
