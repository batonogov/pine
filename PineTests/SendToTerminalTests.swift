//
//  SendToTerminalTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Tests for the "Send to Terminal" feature (issue #311).
@Suite("Send to Terminal Tests")
@MainActor
struct SendToTerminalTests {

    // MARK: - Helpers

    /// Builds a minimal text system stack for testing.
    private func makeTextView(text: String) -> NSTextView {
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
        return textView
    }

    private func makeCoordinator() -> CodeEditorView.Coordinator {
        let editorView = CodeEditorView(
            text: .constant(""),
            contentVersion: 0,
            language: "swift",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )
        return CodeEditorView.Coordinator(parent: editorView)
    }

    // MARK: - extractTextForTerminal

    @Test func extractsSelectedText() {
        let text = "let x = 42\nlet y = 99\nlet z = 0"
        let textView = makeTextView(text: text)
        // Select "let x = 42" (10 characters)
        textView.setSelectedRange(NSRange(location: 0, length: 10))

        let coordinator = makeCoordinator()
        let result = coordinator.extractTextForTerminal(from: textView)
        #expect(result == "let x = 42")
    }

    @Test func extractsMultiLineSelection() {
        let textView = makeTextView(text: "line1\nline2\nline3")
        textView.setSelectedRange(NSRange(location: 0, length: 11)) // "line1\nline2"

        let coordinator = makeCoordinator()
        let result = coordinator.extractTextForTerminal(from: textView)
        #expect(result == "line1\nline2")
    }

    @Test func extractsCurrentLineWhenNoSelection() {
        let textView = makeTextView(text: "first line\nsecond line\nthird line")
        // Cursor at position 15 — in "second line"
        textView.setSelectedRange(NSRange(location: 15, length: 0))

        let coordinator = makeCoordinator()
        let result = coordinator.extractTextForTerminal(from: textView)
        #expect(result == "second line")
    }

    @Test func extractsFirstLineWhenCursorAtStart() {
        let textView = makeTextView(text: "hello world\nsecond")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let coordinator = makeCoordinator()
        let result = coordinator.extractTextForTerminal(from: textView)
        #expect(result == "hello world")
    }

    @Test func extractsLastLineWithoutTrailingNewline() {
        let textView = makeTextView(text: "first\nlast")
        // Cursor in "last"
        textView.setSelectedRange(NSRange(location: 8, length: 0))

        let coordinator = makeCoordinator()
        let result = coordinator.extractTextForTerminal(from: textView)
        #expect(result == "last")
    }

    @Test func extractsEmptyStringFromEmptyDocument() {
        let textView = makeTextView(text: "")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let coordinator = makeCoordinator()
        let result = coordinator.extractTextForTerminal(from: textView)
        #expect(result == "")
    }

    @Test func extractsPartialSelection() {
        let textView = makeTextView(text: "func hello() { return 42 }")
        // Select "hello"
        textView.setSelectedRange(NSRange(location: 5, length: 5))

        let coordinator = makeCoordinator()
        let result = coordinator.extractTextForTerminal(from: textView)
        #expect(result == "hello")
    }

    @Test func extractsLineRegardlessOfLineEndings() {
        // Test with plain \n line endings
        let textView = makeTextView(text: "line1\nline2\nline3")
        let content = textView.string
        let line2Start = (content as NSString).range(of: "line2").location
        textView.setSelectedRange(NSRange(location: line2Start, length: 0))

        let coordinator = makeCoordinator()
        let result = coordinator.extractTextForTerminal(from: textView)
        #expect(result == "line2")
    }

    // MARK: - TerminalTab.sendText

    @Test func sendTextDoesNotCrashOnStoppedTab() {
        let tab = TerminalTab(name: "test")
        tab.stop()
        // Should not crash — just returns early
        tab.sendText("hello")
        #expect(tab.isTerminated == true)
    }

    @Test func sendTextDoesNotCrashOnUnstartedTab() {
        let tab = TerminalTab(name: "test")
        // Process not started, isProcessRunning is false — should return early
        tab.sendText("hello")
        #expect(tab.isTerminated == false)
    }

    // MARK: - Notification names

    @Test func sendToTerminalNotificationNameExists() {
        let name = Notification.Name.sendToTerminal
        #expect(name.rawValue == "sendToTerminal")
    }

    @Test func sendTextToTerminalNotificationNameExists() {
        let name = Notification.Name.sendTextToTerminal
        #expect(name.rawValue == "sendTextToTerminal")
    }

    // MARK: - Menu strings and icons

    @Test func menuStringExists() {
        // Verify the string key is defined
        let key = Strings.menuSendToTerminal
        #expect(key != nil)
    }

    @Test func menuIconExists() {
        let icon = MenuIcons.sendToTerminal
        #expect(icon == "paperplane")
    }
}
