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

    @Test func recalculateFoldableRanges_findsRanges() async {
        let text = "func test() {\n    print(\"hello\")\n}\n"
        let (coordinator, _, _) = makeCoordinator(text: text, language: "swift")

        coordinator.recalculateFoldableRanges()
        await waitForFoldCalculation(coordinator)
        #expect(!coordinator.foldableRanges.isEmpty)
        #expect(coordinator.lineStartsCache != nil)
    }

    @Test func recalculateFoldableRanges_emptyTextHasNoRanges() async {
        let (coordinator, _, _) = makeCoordinator(text: "")
        coordinator.recalculateFoldableRanges()
        await waitForFoldCalculation(coordinator)
        #expect(coordinator.foldableRanges.isEmpty)
    }

    @Test func handleFoldToggle_togglesFoldState() async {
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
        await waitForFoldCalculation(coordinator)

        guard let range = coordinator.foldableRanges.first else {
            #expect(Bool(false), "Should have at least one foldable range")
            return
        }

        coordinator.handleFoldToggle(range)
        #expect(foldState.isFolded(range))
    }

    @Test("YAML fold renders on the first click with a snapshot binding getter")
    func handleFoldToggle_rendersSnapshotBindingImmediately() throws {
        let text = """
        disabled_rules:
          - trailing_comma
          - todo
        opt_in_rules:
        """
        let initialState = FoldState()
        var persistedState = initialState
        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "yaml",
            fileName: ".swiftlint.yml",
            foldState: .init(
                // PaneLeafView captures an EditorTab value in exactly this
                // shape: the getter remains on the previous render's
                // snapshot even after the setter persists the new state.
                get: { initialState },
                set: { persistedState = $0 }
            )
        )
        let (scrollView, textView) = makeTextStack(text: text)
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.lineStartsCache = LineStartsCache(text: text)
        textView.layoutManager?.delegate = coordinator

        let lineNumberView = LineNumberView(
            textView: textView,
            clipView: scrollView.contentView
        )
        coordinator.lineNumberView = lineNumberView

        let range = try #require(
            YAMLIndentationFoldCalculator.calculate(text: text).first {
                $0.kind == .indentation && $0.startLine == 1
            }
        )
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let hiddenCharacter = (text as NSString).range(
            of: "trailing_comma"
        ).location
        var hiddenGlyph = layoutManager.glyphIndexForCharacter(
            at: hiddenCharacter
        )
        #expect(
            !layoutManager.propertyForGlyph(at: hiddenGlyph).contains(.null)
        )

        coordinator.handleFoldToggle(range)
        layoutManager.ensureLayout(for: textContainer)
        hiddenGlyph = layoutManager.glyphIndexForCharacter(
            at: hiddenCharacter
        )

        #expect(persistedState.isFolded(range))
        #expect(coordinator.renderedFoldState.isFolded(range))
        #expect(lineNumberView.foldState.isFolded(range))
        #expect(
            layoutManager.propertyForGlyph(at: hiddenGlyph).contains(.null),
            "The first click must suppress YAML body glyphs immediately"
        )

        coordinator.handleFoldToggle(range)
        layoutManager.ensureLayout(for: textContainer)
        hiddenGlyph = layoutManager.glyphIndexForCharacter(
            at: hiddenCharacter
        )

        #expect(!persistedState.isFolded(range))
        #expect(!coordinator.renderedFoldState.isFolded(range))
        #expect(!lineNumberView.foldState.isFolded(range))
        #expect(
            !layoutManager.propertyForGlyph(at: hiddenGlyph).contains(.null),
            "The second click must reveal the YAML body, not apply the first click"
        )
    }

    @Test("A later SwiftUI fold-state update resynchronizes AppKit rendering")
    func synchronizeFoldState_appliesExternalState() throws {
        let text = "root:\n  child: value\nsibling: value"
        let (coordinator, scrollView, textView) = makeCoordinator(
            text: text,
            language: "yaml",
            fileName: "test.yaml"
        )
        textView.layoutManager?.delegate = coordinator
        coordinator.lineStartsCache = LineStartsCache(text: text)
        coordinator.lineNumberView = LineNumberView(
            textView: textView,
            clipView: scrollView.contentView
        )
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let range = try #require(
            YAMLIndentationFoldCalculator.calculate(text: text).first
        )
        let hiddenCharacter = (text as NSString).range(
            of: "child"
        ).location
        var hiddenGlyph = layoutManager.glyphIndexForCharacter(
            at: hiddenCharacter
        )
        #expect(
            !layoutManager.propertyForGlyph(at: hiddenGlyph).contains(.null)
        )
        var restoredState = FoldState()
        restoredState.fold(range)

        coordinator.synchronizeFoldState(restoredState)
        layoutManager.ensureLayout(for: textContainer)
        hiddenGlyph = layoutManager.glyphIndexForCharacter(
            at: hiddenCharacter
        )

        #expect(coordinator.renderedFoldState.isFolded(range))
        #expect(coordinator.lineNumberView?.foldState.isFolded(range) == true)
        #expect(
            layoutManager.propertyForGlyph(at: hiddenGlyph).contains(.null)
        )
    }

    @Test("Tab switch adopts its fold state before restoring content and scroll")
    func prepareForViewUpdate_unfoldsBeforeTabLayout() throws {
        let oldLines = (1...240).map { "  - old_rule_\($0)" }
        let oldText = (["disabled_rules:"] + oldLines).joined(separator: "\n")
        let oldRange = FoldableRange(
            startLine: 1,
            endLine: 241,
            startCharIndex: 0,
            endCharIndex: (oldText as NSString).length,
            kind: .indentation
        )
        var oldState = FoldState()
        oldState.fold(oldRange)

        let oldView = CodeEditorView(
            text: .constant(oldText),
            contentVersion: 0,
            language: "yaml",
            fileName: "old.yaml",
            foldState: .constant(oldState)
        )
        let (scrollView, textView) = makeTextStack(text: oldText)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let coordinator = CodeEditorView.Coordinator(parent: oldView)
        coordinator.scrollView = scrollView
        coordinator.lineStartsCache = LineStartsCache(text: oldText)
        coordinator.syncContentVersion()
        textView.layoutManager?.delegate = coordinator

        let newLines = (1...240).map { "new_rule_\($0): enabled" }
        let newText = newLines.joined(separator: "\n")
        let savedOffset: CGFloat = 600
        let newView = CodeEditorView(
            text: .constant(newText),
            contentVersion: 1,
            language: "yaml",
            fileName: "new.yaml",
            foldState: .constant(FoldState()),
            initialScrollOffset: savedOffset
        )

        // This is the production updateNSView order: destination state first,
        // then the content path that synchronously lays out and restores scroll.
        coordinator.prepareForViewUpdate(newView)
        coordinator.updateContentIfNeeded(
            text: newText,
            language: "yaml",
            fileName: "new.yaml",
            font: font13
        )

        #expect(coordinator.parent.fileName == "new.yaml")
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let visibleCharacter = (newText as NSString).range(
            of: "new_rule_200"
        ).location
        let visibleGlyph = layoutManager.glyphIndexForCharacter(
            at: visibleCharacter
        )

        #expect(coordinator.renderedFoldState == FoldState())
        #expect(
            !layoutManager.propertyForGlyph(at: visibleGlyph).contains(.null),
            "The destination document must not inherit hidden lines from the previous tab"
        )
        #expect(
            scrollView.contentView.bounds.origin.y > 0,
            "Scroll restoration must use the destination tab's unfolded layout"
        )
    }

    private func waitForFoldCalculation(
        _ coordinator: CodeEditorView.Coordinator
    ) async {
        for _ in 0..<100 where coordinator.lineStartsCache == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.lineStartsCache != nil)
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
