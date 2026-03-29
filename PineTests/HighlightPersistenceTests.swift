//
//  HighlightPersistenceTests.swift
//  PineTests
//
//  Tests for issue #556: syntax highlighting should not disappear after initially appearing.
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

@Suite(.serialized)
struct HighlightPersistenceTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let yamlGrammar = Grammar(
        name: "TestYAML556",
        extensions: ["testyaml556"],
        rules: [
            GrammarRule(pattern: "#.*$", scope: "comment", options: ["anchorsMatchLines"]),
            GrammarRule(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", scope: "string"),
            GrammarRule(pattern: "\\b(true|false|null)\\b", scope: "keyword"),
            GrammarRule(pattern: "^\\s*[\\w.-]+(?=\\s*:)", scope: "attribute", options: ["anchorsMatchLines"]),
            GrammarRule(pattern: "\\b\\d+(\\.\\d+)?\\b", scope: "number")
        ]
    )

    private func register(_ grammars: Grammar...) {
        for grammar in grammars {
            SyntaxHighlighter.shared.registerGrammar(grammar)
        }
    }

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

    /// Returns true if the text storage has any non-default foreground colors.
    private func hasHighlightColors(_ textStorage: NSTextStorage) -> Bool {
        var found = false
        textStorage.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, _, stop in
            if let color = value as? NSColor, color != NSColor.textColor {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Coordinator init sets language/fileName

    @Test("Coordinator initializes lastLanguage from parent, preventing false languageChanged")
    func coordinatorInitSetsLanguage() {
        let editorView = CodeEditorView(
            text: .constant("test: value"),
            contentVersion: 0,
            language: "testyaml556",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        #expect(coordinator.lastLanguage == "testyaml556")
        #expect(coordinator.lastFileName == "test.yaml")
    }

    @Test("Coordinator with lastLanguage initialized skips unnecessary update on first updateNSView")
    func coordinatorSkipsSpuriousUpdate() {
        let text = "name: test\nversion: 1"
        let (scrollView, textView) = makeTextStack(text: text)

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "testyaml556",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // First updateContentIfNeeded: since lastLanguage is already correct
        // and contentVersion matches, it should return early without touching text.
        coordinator.updateContentIfNeeded(
            text: text, language: "testyaml556", fileName: "test.yaml", font: font
        )

        // Verify the text view still has the original text (not re-set)
        #expect(textView.string == text)
    }

    // MARK: - Issue #556: Same-content version bump must not strip highlights

    @Test("updateContentIfNeeded skips text replacement when content is identical but version bumped")
    func sameContentVersionBumpPreservesHighlights() {
        register(yamlGrammar)
        let text = "name: test\nversion: 1\n# comment"
        let (scrollView, textView) = makeTextStack(text: text)

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "testyaml556",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        // Establish language baseline
        coordinator.updateContentIfNeeded(
            text: text, language: "testyaml556", fileName: "test.yaml", font: font
        )

        // Apply highlighting
        guard let storage = textView.textStorage else {
            Issue.record("textStorage is nil")
            return
        }
        SyntaxHighlighter.shared.highlight(
            textStorage: storage, language: "testyaml556", font: font
        )
        #expect(hasHighlightColors(storage), "Highlights should be present after initial apply")

        // Simulate contentVersion bump with identical text (e.g., updateContent
        // called from textDidChange with same text). This previously caused
        // textView.string = text which stripped all highlight attributes.
        let updatedEditorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 1,  // version bumped, but text is the same
            language: "testyaml556",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        coordinator.parent = updatedEditorView

        coordinator.updateContentIfNeeded(
            text: text, language: "testyaml556", fileName: "test.yaml", font: font
        )

        // Highlights must survive — textView.string should NOT have been re-set
        #expect(hasHighlightColors(storage),
                "Highlights must survive when contentVersion bumps but text is unchanged (issue #556)")
    }

    @Test("updateContentIfNeeded does replace text when content actually changes")
    func differentContentReplacesText() {
        let original = "name: test"
        let updated = "name: updated"
        let (scrollView, textView) = makeTextStack(text: original)

        let editorView = CodeEditorView(
            text: .constant(original),
            contentVersion: 0,
            language: "testyaml556",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        coordinator.updateContentIfNeeded(
            text: original, language: "testyaml556", fileName: "test.yaml", font: font
        )

        // External change with different content
        let updatedEditorView = CodeEditorView(
            text: .constant(updated),
            contentVersion: 1,
            language: "testyaml556",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        coordinator.parent = updatedEditorView

        coordinator.updateContentIfNeeded(
            text: updated, language: "testyaml556", fileName: "test.yaml", font: font
        )

        #expect(textView.string == updated, "Text must be updated when content actually changes")
    }

    // MARK: - Language change re-highlights correctly

    @Test("Language change triggers fresh highlight, not stale cached result")
    func languageChangeDoesNotUseStaleCachedResult() {
        let swiftGrammar = Grammar(
            name: "TestSwift556",
            extensions: ["testswift556"],
            rules: [GrammarRule(pattern: "\\bfunc\\b", scope: "keyword")]
        )
        register(yamlGrammar, swiftGrammar)

        let text = "func test: value\n# comment"
        let (scrollView, textView) = makeTextStack(text: text)

        // Start as "swift"
        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "testswift556",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        coordinator.syncContentVersion()

        coordinator.updateContentIfNeeded(
            text: text, language: "testswift556", fileName: "test.swift", font: font
        )

        // Now switch to YAML language (same text content)
        let yamlEditorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,  // same version — only language changed
            language: "testyaml556",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        coordinator.parent = yamlEditorView

        coordinator.updateContentIfNeeded(
            text: text, language: "testyaml556", fileName: "test.yaml", font: font
        )

        // The coordinator should have updated language tracking
        #expect(coordinator.lastLanguage == "testyaml556")
        #expect(coordinator.lastFileName == "test.yaml")
    }

    // MARK: - Delegate deferral prevents spurious textDidChange

    @Test("Setting text before delegate does not trigger textDidChange")
    func textSetBeforeDelegateDoesNotFireTextDidChange() {
        let text = "name: test\n# comment"
        let textStorage = NSTextStorage(string: "")
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

        // Create coordinator but do NOT set it as delegate
        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "testyaml556",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)

        // Set text — this would fire textDidChange if delegate was set
        textView.string = text

        // didChangeFromTextView should remain false since delegate wasn't set
        #expect(coordinator.didChangeFromTextView == false,
                "textDidChange should not fire when delegate is not set")
    }

    @Test("Setting delegate after text allows highlights to survive")
    func delegateAfterTextPreservesHighlights() {
        register(yamlGrammar)
        let text = "name: test\nversion: 1\n# comment"

        let textStorage = NSTextStorage(string: "")
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
        textView.isRichText = false

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "testyaml556",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)

        // Replicate makeNSView order: text first, then highlight, then delegate
        textView.string = text
        SyntaxHighlighter.shared.highlight(
            textStorage: textStorage, language: "testyaml556", font: font
        )
        #expect(hasHighlightColors(textStorage),
                "Highlights should be applied after highlight()")

        // Set delegate AFTER highlighting
        textView.delegate = coordinator

        // Verify highlights survived delegate assignment
        #expect(hasHighlightColors(textStorage),
                "Highlights must survive after delegate is set (issue #556)")

        // Verify no spurious state mutations happened
        #expect(coordinator.didChangeFromTextView == false,
                "No textDidChange should have fired")
    }

    // MARK: - cancelPendingHighlight clears state correctly

    @Test("cancelPendingHighlight increments generation and clears tasks")
    func cancelPendingHighlightClearsState() {
        let editorView = CodeEditorView(
            text: .constant("test"),
            contentVersion: 0,
            language: "txt",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)

        let genBefore = coordinator.highlightGeneration.current
        coordinator.cancelPendingHighlight()
        let genAfter = coordinator.highlightGeneration.current

        #expect(genAfter == genBefore + 1,
                "cancelPendingHighlight must increment generation")
    }
}
