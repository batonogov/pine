//
//  CoordinatorExtendedTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Extended tests for CodeEditorView.Coordinator — font changes, text changes,
/// bracket highlight, fold state, viewport highlighting, selection changes.
@Suite("CodeEditorView.Coordinator Extended Tests")
@MainActor
struct CoordinatorExtendedTests {

    private let font13 = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let font16 = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private let gutterFont11 = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let gutterFont14 = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    /// Builds a minimal text system stack (same as CodeEditorView.makeNSView).
    private func makeTextStack(text: String) -> (NSScrollView, GutterTextView) {
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
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func makeCoordinator(
        text: String = "hello world",
        language: String = "swift",
        fileName: String? = "test.swift"
    ) -> (CodeEditorView.Coordinator, NSScrollView, GutterTextView) {
        let (scrollView, textView) = makeTextStack(text: text)
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
        coordinator.lastFontSize = font13.pointSize
        coordinator.updateContentIfNeeded(
            text: text, language: language, fileName: fileName, font: font13
        )
        return (coordinator, scrollView, textView)
    }

    // MARK: - updateFontIfNeeded

    @Test func updateFontIfNeeded_noChangeWhenSameSize() {
        let (coordinator, _, textView) = makeCoordinator()
        textView.font = font13
        coordinator.updateFontIfNeeded(font: font13, gutterFont: gutterFont11)
        #expect(coordinator.lastFontSize == 13)
    }

    @Test func updateFontIfNeeded_updatesOnSizeChange() {
        let (coordinator, _, textView) = makeCoordinator()
        textView.font = font13
        coordinator.updateFontIfNeeded(font: font16, gutterFont: gutterFont14)
        #expect(coordinator.lastFontSize == 16)
        #expect(textView.font?.pointSize == 16)
    }

    @Test func updateFontIfNeeded_updatesGutterFont() {
        let (coordinator, _, _) = makeCoordinator()
        let lineNumberView = LineNumberView(textView: NSTextView())
        coordinator.lineNumberView = lineNumberView
        coordinator.updateFontIfNeeded(font: font16, gutterFont: gutterFont14)
        #expect(lineNumberView.gutterFont.pointSize == 14)
        #expect(lineNumberView.editorFont.pointSize == 16)
    }

    // MARK: - updateContentIfNeeded — language change

    @Test func updateContentIfNeeded_languageChangeTriggersReHighlight() {
        let text = "func hello()"
        let (coordinator, _, _) = makeCoordinator(text: text, language: "swift")

        // Change language
        let updatedView = CodeEditorView(
            text: .constant(text),
            contentVersion: 1,
            language: "go",
            fileName: "test.go",
            foldState: .constant(FoldState())
        )
        coordinator.parent = updatedView
        coordinator.updateContentIfNeeded(
            text: text, language: "go", fileName: "test.go", font: font13
        )
        #expect(coordinator.lastLanguage == "go")
        #expect(coordinator.lastFileName == "test.go")
    }

    @Test func updateContentIfNeeded_sameContentAndLanguage_noOp() {
        let text = "hello"
        let (coordinator, _, textView) = makeCoordinator(text: text, language: "swift")
        let originalString = textView.string

        coordinator.updateContentIfNeeded(
            text: text, language: "swift", fileName: "test.swift", font: font13
        )
        #expect(textView.string == originalString)
    }

    @Test func updateContentIfNeeded_externalContentChange() {
        let original = "hello"
        let updated = "world"
        let (coordinator, _, textView) = makeCoordinator(text: original)

        let updatedView = CodeEditorView(
            text: .constant(updated),
            contentVersion: 1,
            language: "swift",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )
        coordinator.parent = updatedView
        coordinator.updateContentIfNeeded(
            text: updated, language: "swift", fileName: "test.swift", font: font13
        )
        #expect(textView.string == updated)
    }

    @Test func updateContentIfNeeded_fromTextViewSkipsOverwrite() {
        let text = "edited by user"
        let (coordinator, _, textView) = makeCoordinator(text: "original")

        let updatedView = CodeEditorView(
            text: .constant(text),
            contentVersion: 1,
            language: "swift",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )
        coordinator.parent = updatedView
        coordinator.didChangeFromTextView = true
        textView.string = text

        coordinator.updateContentIfNeeded(
            text: text, language: "swift", fileName: "test.swift", font: font13
        )
        // Flag should be consumed
        #expect(coordinator.didChangeFromTextView == false)
        #expect(textView.string == text)
    }

    // MARK: - textDidChange

    @Test func textDidChange_setsDidChangeFromTextView() {
        let (coordinator, _, textView) = makeCoordinator()
        let notification = Notification(name: NSText.didChangeNotification, object: textView)
        coordinator.textDidChange(notification)
        #expect(coordinator.didChangeFromTextView == true)
    }

    @Test func textDidChange_updatesLineStartsCache() {
        let text = "line1\nline2\nline3"
        let (coordinator, _, textView) = makeCoordinator(text: text)

        // First call to establish cache
        let notification = Notification(name: NSText.didChangeNotification, object: textView)
        coordinator.textDidChange(notification)

        #expect(coordinator.lineStartsCache != nil)
    }

    // MARK: - textViewDidChangeSelection

    @Test func textViewDidChangeSelection_doesNotCrash() {
        let (coordinator, _, textView) = makeCoordinator(text: "hello (world)")
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        let notification = Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        coordinator.textViewDidChangeSelection(notification)
        // Should not crash
    }

    // MARK: - Fold operations

    @Test func recalculateFoldableRanges_findsRanges() {
        let text = "func test() {\n    print(\"hello\")\n}\n"
        let (coordinator, _, _) = makeCoordinator(text: text, language: "swift")

        coordinator.recalculateFoldableRanges()
        #expect(!coordinator.foldableRanges.isEmpty)
        #expect(coordinator.lineStartsCache != nil)
    }

    @Test func recalculateFoldableRanges_emptyTextHasNoRanges() {
        let (coordinator, _, _) = makeCoordinator(text: "")
        coordinator.recalculateFoldableRanges()
        #expect(coordinator.foldableRanges.isEmpty)
    }

    @Test func handleFoldToggle_togglesFoldState() {
        let text = "func test() {\n    print(\"hello\")\n}\n"
        var foldState = FoldState()
        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "swift",
            fileName: "test.swift",
            foldState: .init(
                get: { foldState },
                set: { foldState = $0 }
            )
        )
        let (scrollView, _) = makeTextStack(text: text)
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()
        coordinator.recalculateFoldableRanges()

        guard let range = coordinator.foldableRanges.first else {
            #expect(Bool(false), "Should have at least one foldable range")
            return
        }

        coordinator.handleFoldToggle(range)
        #expect(foldState.isFolded(range))
    }

    // MARK: - Bracket matching with nested brackets

    @Test func selectionChangeWithNestedBrackets() {
        let text = "func test() {\n    if true {\n        print(\"hello\")\n    }\n}\n"
        let (coordinator, _, textView) = makeCoordinator(text: text)

        // Position cursor after inner { — bracket matching should work
        textView.setSelectedRange(NSRange(location: 27, length: 0))
        let notification = Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        coordinator.textViewDidChangeSelection(notification)
    }
}
