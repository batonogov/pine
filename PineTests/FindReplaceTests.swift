//
//  FindReplaceTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Tests for Find & Replace functionality (issue #275).
struct FindReplaceTests {

    private func makeGutterTextView(text: String = "hello world") -> GutterTextView {
        let textStorage = NSTextStorage(string: text)
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
        return textView
    }

    // MARK: - GutterTextView configuration

    @Test func gutterTextView_usesFindBar_isEnabled() {
        let textView = makeGutterTextView()
        textView.usesFindBar = true
        #expect(textView.usesFindBar == true, "GutterTextView must support the native find bar")
    }

    // MARK: - Notification names

    @Test func findNotificationNames_areDefined() {
        #expect(Notification.Name.findInFile.rawValue == "findInFile")
        #expect(Notification.Name.findAndReplace.rawValue == "findAndReplace")
        #expect(Notification.Name.findNext.rawValue == "findNext")
        #expect(Notification.Name.findPrevious.rawValue == "findPrevious")
        #expect(Notification.Name.useSelectionForFind.rawValue == "useSelectionForFind")
    }

    // MARK: - Menu icons

    @Test(arguments: [
        (MenuIcons.find, "Find"),
        (MenuIcons.findAndReplace, "Find and Replace"),
    ])
    func findMenuIconExists(_ symbol: String, _ menuItem: String) {
        #expect(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
            "SF Symbol '\(symbol)' used by '\(menuItem)' does not exist"
        )
    }

    // MARK: - Coordinator find handler

    @Test func coordinator_performFindAction_doesNotCrash() {
        let textView = makeGutterTextView()
        textView.usesFindBar = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView

        let editorView = CodeEditorView(
            text: .constant("hello world"),
            contentVersion: 0,
            language: "txt",
            fileName: "test.txt",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        // performTextFinderAction requires a window to actually show the find bar,
        // but calling it without a window should be a safe no-op (guard checks window)
        coordinator.performFindAction(.showFindInterface)
        coordinator.performFindAction(.showReplaceInterface)
        coordinator.performFindAction(.nextMatch)
        coordinator.performFindAction(.previousMatch)
        coordinator.performFindAction(.setSearchString)
    }
}
