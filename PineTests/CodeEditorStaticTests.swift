//
//  CodeEditorStaticTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Tests for CodeEditorView static helpers and value types.
struct CodeEditorStaticTests {

    // MARK: - bracketHighlightKey

    @Test func bracketHighlightKey_isUnique() {
        let key = CodeEditorView.bracketHighlightKey
        #expect(key.rawValue == "PineBracketHighlight")
    }

    // MARK: - viewportHighlightThreshold

    @Test func viewportHighlightThreshold_is100K() {
        #expect(CodeEditorView.viewportHighlightThreshold == 100_000)
    }

    // MARK: - GoToRequest

    @Test func goToRequest_uniqueIDs() {
        let r1 = GoToRequest(offset: 0)
        let r2 = GoToRequest(offset: 0)
        #expect(r1.id != r2.id, "Each GoToRequest should have a unique ID")
    }

    @Test func goToRequest_preservesOffset() {
        let r = GoToRequest(offset: 42)
        #expect(r.offset == 42)
    }

    // MARK: - EditorScrollView

    @Test func editorScrollView_initialFindBarOffset() {
        let sv = EditorScrollView()
        #expect(sv.findBarOffset == 0)
    }

    // MARK: - EditorContainerView

    @Test func editorContainerView_isFlipped() {
        let container = EditorContainerView()
        #expect(container.isFlipped == true)
    }

    @Test func editorContainerView_defaultMinimapWidth() {
        let container = EditorContainerView()
        #expect(container.minimapWidth == 0)
    }

    @Test func editorContainerView_minimapWidthCanBeSet() {
        let container = EditorContainerView()
        container.minimapWidth = 120
        #expect(container.minimapWidth == 120)
    }

    // MARK: - Coordinator basics

    @Test func coordinator_initialState() {
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

    @Test func coordinator_syncContentVersion() {
        let editorView = CodeEditorView(
            text: .constant("hello"),
            contentVersion: 42,
            language: "swift",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.syncContentVersion()
        // After sync, updateContentIfNeeded with same version should be no-op
    }

    @Test func coordinator_cancelPendingHighlight() {
        let editorView = CodeEditorView(
            text: .constant(""),
            contentVersion: 0,
            language: "swift",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        // Should not crash when there's nothing to cancel
        coordinator.cancelPendingHighlight()
    }

    @Test func coordinator_performFindAction_withoutScrollView() {
        let editorView = CodeEditorView(
            text: .constant("hello"),
            contentVersion: 0,
            language: "swift",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        // Should not crash when scrollView is nil
        coordinator.performFindAction(.showFindInterface)
        coordinator.performFindAction(.nextMatch)
        coordinator.performFindAction(.previousMatch)
    }

    // MARK: - CodeEditorView initialization

    @Test func codeEditorView_defaultProperties() {
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

    @Test func codeEditorView_customProperties() {
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
