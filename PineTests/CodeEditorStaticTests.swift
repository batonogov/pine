//
//  CodeEditorStaticTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Tests for CodeEditorView static helpers, value types, and Coordinator basics.
@Suite("CodeEditorView Static Tests")
struct CodeEditorStaticTests {

    // MARK: - GoToRequest

    @Test func goToRequestHasUniqueIDs() {
        let r1 = GoToRequest(offset: 0)
        let r2 = GoToRequest(offset: 0)
        #expect(r1.id != r2.id)
        #expect(r1.offset == 0)
    }

    // MARK: - EditorContainerView

    @Test func editorContainerViewIsFlipped() {
        let container = EditorContainerView()
        #expect(container.isFlipped == true)
    }

    // MARK: - Coordinator initial state

    @Test func coordinatorInitialState() {
        let editorView = CodeEditorView(
            text: .constant("hello"),
            contentVersion: 0,
            language: "swift",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        #expect(coordinator.didChangeFromTextView == false)
        #expect(coordinator.lastGoToID == nil)
        #expect(coordinator.lastLanguage == "")
        #expect(coordinator.lastFileName == nil)
        #expect(coordinator.lastFontSize == 0)
        #expect(coordinator.foldableRanges.isEmpty)
        #expect(coordinator.lineStartsCache == nil)
        #expect(coordinator.highlightedCharRange == nil)
    }

    // MARK: - Coordinator edge cases without scroll view

    @Test func coordinatorEdgeCasesWithoutScrollView() {
        let editorView = CodeEditorView(
            text: .constant("hello"),
            contentVersion: 0,
            language: "swift",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)

        // All should be no-ops when scrollView is nil
        coordinator.cancelPendingHighlight()
        coordinator.performFindAction(.showFindInterface)
        coordinator.performFindAction(.nextMatch)
        coordinator.handleToggleComment()
        coordinator.handleFoldCode(Notification(name: .foldCode, userInfo: ["action": "foldAll"]))
    }

    // MARK: - CodeEditorView properties

    @Test func codeEditorViewDefaultProperties() {
        let view = CodeEditorView(
            text: .constant("test"),
            language: "swift",
            foldState: .constant(FoldState())
        )
        #expect(view.lineDiffs.isEmpty)
        #expect(view.isBlameVisible == false)
        #expect(view.blameLines.isEmpty)
        #expect(view.isMinimapVisible == true)
        #expect(view.syntaxHighlightingDisabled == false)
        #expect(view.initialCursorPosition == 0)
        #expect(view.initialScrollOffset == 0)
        #expect(view.goToOffset == nil)
    }

    @Test func codeEditorViewCustomProperties() {
        let diffs = [GitLineDiff(line: 1, kind: .added)]
        let view = CodeEditorView(
            text: .constant("test"),
            contentVersion: 5,
            language: "go",
            fileName: "main.go",
            lineDiffs: diffs,
            isBlameVisible: true,
            foldState: .constant(FoldState()),
            isMinimapVisible: false,
            syntaxHighlightingDisabled: true,
            initialCursorPosition: 100,
            initialScrollOffset: 200
        )
        #expect(view.contentVersion == 5)
        #expect(view.language == "go")
        #expect(view.fileName == "main.go")
        #expect(view.lineDiffs.count == 1)
        #expect(view.isBlameVisible == true)
        #expect(view.isMinimapVisible == false)
        #expect(view.syntaxHighlightingDisabled == true)
        #expect(view.initialCursorPosition == 100)
        #expect(view.initialScrollOffset == 200)
    }
}
