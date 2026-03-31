//
//  CodeEditorCoordinatorTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Tests for CodeEditorView.Coordinator behavior.
@MainActor
struct CodeEditorCoordinatorTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

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
            fileName: "test.yaml",
            foldState: .constant(FoldState())
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
            fileName: "test.yaml",
            foldState: .constant(FoldState())
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
            fileName: "test.txt",
            foldState: .constant(FoldState())
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
            fileName: "test.txt",
            foldState: .constant(FoldState())
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
            fileName: "test.swift",
            foldState: .constant(FoldState())
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
            fileName: "test.go",
            foldState: .constant(FoldState())
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

    // MARK: - Issue #441: cursor restoration on tab switch (no .id(tab.id))

    @Test func updateContentIfNeeded_restoresCursorPosition_onTabSwitch() {
        let fileA = "line1\nline2\nline3\nline4"
        let fileB = "func hello() {\n    return\n}"

        let (scrollView, textView) = makeTextStack(text: fileA)

        // Start with file A
        let editorView = CodeEditorView(
            text: .constant(fileA),
            contentVersion: 0,
            language: "txt",
            fileName: "a.txt",
            foldState: .constant(FoldState()),
            initialCursorPosition: 0
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        coordinator.updateContentIfNeeded(
            text: fileA, language: "txt", fileName: "a.txt", font: font
        )

        // Switch to file B with cursor at position 15 (end of first line)
        let editorViewB = CodeEditorView(
            text: .constant(fileB),
            contentVersion: 1,
            language: "swift",
            fileName: "b.swift",
            foldState: .constant(FoldState()),
            initialCursorPosition: 15
        )
        coordinator.parent = editorViewB

        coordinator.updateContentIfNeeded(
            text: fileB, language: "swift", fileName: "b.swift", font: font
        )

        #expect(textView.string == fileB, "Text must be updated to file B content")
        #expect(textView.selectedRange().location == 15,
                "Cursor must be restored to saved position 15, got \(textView.selectedRange().location)")
    }

    @Test func updateContentIfNeeded_clampsCursorPosition_whenBeyondTextLength() {
        let shortText = "hi"

        let (scrollView, textView) = makeTextStack(text: "original content")

        let editorView = CodeEditorView(
            text: .constant("original content"),
            contentVersion: 0,
            language: "txt",
            fileName: "a.txt",
            foldState: .constant(FoldState()),
            initialCursorPosition: 0
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        coordinator.updateContentIfNeeded(
            text: "original content", language: "txt", fileName: "a.txt", font: font
        )

        // Switch to a short file but with a cursor position beyond its length
        let editorViewB = CodeEditorView(
            text: .constant(shortText),
            contentVersion: 1,
            language: "txt",
            fileName: "b.txt",
            foldState: .constant(FoldState()),
            initialCursorPosition: 999
        )
        coordinator.parent = editorViewB

        coordinator.updateContentIfNeeded(
            text: shortText, language: "txt", fileName: "b.txt", font: font
        )

        #expect(textView.string == shortText, "Text must be updated")
        let cursorPos = textView.selectedRange().location
        #expect(cursorPos <= (shortText as NSString).length,
                "Cursor must be clamped to text length, got \(cursorPos)")
    }

    @Test func updateContentIfNeeded_switchBackPreservesCursor() {
        let fileA = "line1\nline2\nline3\nline4"
        let fileB = "func hello() {\n    return\n}"

        let (scrollView, textView) = makeTextStack(text: fileA)

        // Start with file A, cursor at position 10
        let editorA = CodeEditorView(
            text: .constant(fileA),
            contentVersion: 0,
            language: "txt",
            fileName: "a.txt",
            foldState: .constant(FoldState()),
            initialCursorPosition: 10
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorA)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        coordinator.updateContentIfNeeded(
            text: fileA, language: "txt", fileName: "a.txt", font: font
        )

        // Switch to file B
        let editorB = CodeEditorView(
            text: .constant(fileB),
            contentVersion: 1,
            language: "swift",
            fileName: "b.swift",
            foldState: .constant(FoldState()),
            initialCursorPosition: 5
        )
        coordinator.parent = editorB
        coordinator.updateContentIfNeeded(
            text: fileB, language: "swift", fileName: "b.swift", font: font
        )
        #expect(textView.string == fileB)
        #expect(textView.selectedRange().location == 5)

        // Switch back to file A — cursor should restore to position 10
        let editorA2 = CodeEditorView(
            text: .constant(fileA),
            contentVersion: 2,
            language: "txt",
            fileName: "a.txt",
            foldState: .constant(FoldState()),
            initialCursorPosition: 10
        )
        coordinator.parent = editorA2
        coordinator.updateContentIfNeeded(
            text: fileA, language: "txt", fileName: "a.txt", font: font
        )
        #expect(textView.string == fileA)
        #expect(textView.selectedRange().location == 10)
    }

    @Test func updateContentIfNeeded_emptyFileHandledCorrectly() {
        let (scrollView, textView) = makeTextStack(text: "some content")

        let editorView = CodeEditorView(
            text: .constant("some content"),
            contentVersion: 0,
            language: "txt",
            fileName: "a.txt",
            foldState: .constant(FoldState()),
            initialCursorPosition: 0
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        coordinator.updateContentIfNeeded(
            text: "some content", language: "txt", fileName: "a.txt", font: font
        )

        // Switch to empty file
        let editorB = CodeEditorView(
            text: .constant(""),
            contentVersion: 1,
            language: "txt",
            fileName: "empty.txt",
            foldState: .constant(FoldState()),
            initialCursorPosition: 0
        )
        coordinator.parent = editorB
        coordinator.updateContentIfNeeded(
            text: "", language: "txt", fileName: "empty.txt", font: font
        )

        #expect(textView.string == "")
        #expect(textView.selectedRange().location == 0)
    }

    // MARK: - Issue #649: pendingEditedRange captured via NSTextStorageDelegate

    @Test func pendingEditedRange_capturedByTextStorageDelegate() {
        let text = "key: value"
        let (scrollView, _) = makeTextStack(text: text)
        guard let textView = scrollView.documentView as? NSTextView else {
            Issue.record("Failed to get NSTextView from scroll view")
            return
        }

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "yaml",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        // Wire up NSTextStorageDelegate
        textView.textStorage?.delegate = coordinator

        // Initially nil
        #expect(coordinator.pendingEditedRange == nil)

        // Simulate typing: insert a character
        textView.textStorage?.beginEditing()
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 10, length: 0), with: "s"
        )
        textView.textStorage?.endEditing()

        // pendingEditedRange should have been captured by the delegate
        #expect(coordinator.pendingEditedRange != nil,
                "NSTextStorageDelegate must capture editedRange before it resets")
        #expect(coordinator.pendingEditedRange?.location == 10,
                "Captured range must start at the insertion point")
    }

    @Test func pendingEditedRange_consumedByTextDidChange() {
        let text = "name: test"
        let (scrollView, _) = makeTextStack(text: text)
        guard let textView = scrollView.documentView as? NSTextView else {
            Issue.record("Failed to get NSTextView from scroll view")
            return
        }

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "yaml",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // Set up delegates
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator

        // Pre-set a pending range (simulating what the delegate would capture)
        coordinator.pendingEditedRange = NSRange(location: 5, length: 1)

        // Fire textDidChange — it should consume pendingEditedRange
        NotificationCenter.default.post(
            name: NSText.didChangeNotification, object: textView
        )

        #expect(coordinator.pendingEditedRange == nil,
                "textDidChange must consume pendingEditedRange")
    }

    @Test func pendingEditedRange_clearedOnProgrammaticTextChange() {
        let text = "hello"
        let (scrollView, _) = makeTextStack(text: text)
        guard let textView = scrollView.documentView as? NSTextView else {
            Issue.record("Failed to get NSTextView from scroll view")
            return
        }

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "txt",
            fileName: "test.txt",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator

        // Set a pending range and mark as programmatic change
        coordinator.pendingEditedRange = NSRange(location: 0, length: 5)

        // Simulate programmatic text replacement (as in updateContentIfNeeded)
        let updatedEditor = CodeEditorView(
            text: .constant("world"),
            contentVersion: 1,
            language: "txt",
            fileName: "test.txt",
            foldState: .constant(FoldState())
        )
        coordinator.parent = updatedEditor

        coordinator.updateContentIfNeeded(
            text: "world", language: "txt", fileName: "test.txt", font: font
        )

        // After programmatic text change, pendingEditedRange should be cleared
        // (the textDidChange handler clears it when isProgrammaticTextChange is true)
        #expect(coordinator.pendingEditedRange == nil,
                "pendingEditedRange must be cleared after programmatic text change")
    }

    @Test func pendingEditedRange_notSetForAttributeOnlyEdits() {
        let text = "key: value"
        let (scrollView, _) = makeTextStack(text: text)
        guard let textView = scrollView.documentView as? NSTextView else {
            Issue.record("Failed to get NSTextView from scroll view")
            return
        }

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "yaml",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        textView.textStorage?.delegate = coordinator

        // Attribute-only edit (like syntax highlighting applying colors)
        textView.textStorage?.beginEditing()
        textView.textStorage?.addAttribute(
            .foregroundColor,
            value: NSColor.red,
            range: NSRange(location: 0, length: 3)
        )
        textView.textStorage?.endEditing()

        // pendingEditedRange should NOT be set for attribute-only edits
        #expect(coordinator.pendingEditedRange == nil,
                "Attribute-only edits must not set pendingEditedRange")
    }
}
