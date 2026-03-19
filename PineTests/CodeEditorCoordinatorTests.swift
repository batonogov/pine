//
//  CodeEditorCoordinatorTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Tests for CodeEditorView.Coordinator behavior.
struct CodeEditorCoordinatorTests {

    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Builds a minimal text system stack (same as CodeEditorView.makeNSView).
    private func makeTextStack(text: String) -> (NSScrollView, NSTextView) {
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
        return (scrollView, textView)
    }

    // MARK: - Issue #250: cursor jumps to end after delete + type

    @Test func updateContentIfNeeded_skipsTextOverwrite_whenChangeFromTextView() {
        let original = "version: 18.8.0-ce.0\nline2\nline3"
        let edited   = "version: 18.8.-ce.0\nline2\nline3"

        let (scrollView, textView) = makeTextStack(text: original)

        // Simulate initial state: coordinator has seen version 0
        let editorView = CodeEditorView(
            text: .constant(original),
            contentVersion: 0,
            language: "yaml",
            fileName: "test.yaml"
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // First call — establish language baseline
        coordinator.updateContentIfNeeded(
            text: original, language: "yaml", fileName: "test.yaml", font: font
        )

        // Simulate user deleting a character: textView now has edited text,
        // cursor is at position 15 (after "18.8.")
        textView.string = edited
        let cursorAfterDelete = 14  // position after "18.8."
        textView.setSelectedRange(NSRange(location: cursorAfterDelete, length: 0))

        // Simulate what textDidChange does: set the flag and bump version via parent
        let updatedEditorView = CodeEditorView(
            text: .constant(edited),
            contentVersion: 1,
            language: "yaml",
            fileName: "test.yaml"
        )
        coordinator.parent = updatedEditorView
        coordinator.didChangeFromTextView = true

        // Now updateContentIfNeeded runs (as it would from updateNSView).
        // It should NOT overwrite textView.string and should NOT move the cursor.
        coordinator.updateContentIfNeeded(
            text: edited, language: "yaml", fileName: "test.yaml", font: font
        )

        // Cursor must remain where the user left it
        #expect(textView.selectedRange().location == cursorAfterDelete,
                "Cursor must stay at \(cursorAfterDelete), not jump to \(textView.selectedRange().location)")
        #expect(textView.string == edited, "Text must not be overwritten")
    }

    @Test func updateContentIfNeeded_doesOverwriteText_whenChangeFromExternal() {
        let original = "hello world"
        let updated = "hello swift"

        let (scrollView, textView) = makeTextStack(text: original)

        let editorView = CodeEditorView(
            text: .constant(original),
            contentVersion: 0,
            language: "txt",
            fileName: "test.txt"
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // First call
        coordinator.updateContentIfNeeded(
            text: original, language: "txt", fileName: "test.txt", font: font
        )

        // External content change (e.g., file reloaded from disk) — version bumps
        let updatedEditorView = CodeEditorView(
            text: .constant(updated),
            contentVersion: 1,
            language: "txt",
            fileName: "test.txt"
        )
        coordinator.parent = updatedEditorView
        // didChangeFromTextView is NOT set — this is an external change

        coordinator.updateContentIfNeeded(
            text: updated, language: "txt", fileName: "test.txt", font: font
        )

        #expect(textView.string == updated, "Text must be updated for external changes")
    }

    @Test func updateContentIfNeeded_reHighlights_whenLanguageChanges_evenFromTextView() {
        let text = "func hello()"

        let (scrollView, textView) = makeTextStack(text: text)

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "swift",
            fileName: "test.swift"
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // Establish baseline
        coordinator.updateContentIfNeeded(
            text: text, language: "swift", fileName: "test.swift", font: font
        )

        // Language change + fromTextView flag — language change must still trigger re-highlight
        let updatedEditorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 1,
            language: "go",
            fileName: "test.go"
        )
        coordinator.parent = updatedEditorView
        coordinator.didChangeFromTextView = true

        coordinator.updateContentIfNeeded(
            text: text, language: "go", fileName: "test.go", font: font
        )

        // The flag should be consumed
        #expect(coordinator.didChangeFromTextView == false,
                "didChangeFromTextView must be reset after updateContentIfNeeded")
    }
}
