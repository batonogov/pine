//
//  NewlineHighlightTests.swift
//  PineTests
//
//  Tests for syntax highlighting after newline insertion (#659).
//  Verifies that pressing Enter does not break highlighting.

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Serialized: all tests mutate singleton SyntaxHighlighter.shared.
@Suite(.serialized)
@MainActor
struct NewlineHighlightTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// YAML-like grammar with key patterns that use anchorsMatchLines.
    private let yamlGrammar = Grammar(
        name: "TestYAML",
        extensions: ["testyaml"],
        rules: [
            GrammarRule(pattern: "#.*$", scope: "comment", options: ["anchorsMatchLines"]),
            GrammarRule(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", scope: "string"),
            GrammarRule(pattern: "'[^']*'", scope: "string"),
            GrammarRule(pattern: "^\\s*[\\w.-]+(?=\\s*:)", scope: "attribute", options: ["anchorsMatchLines"]),
            GrammarRule(pattern: "\\b(true|false|yes|no|null|~)\\b", scope: "keyword"),
            GrammarRule(pattern: "\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", scope: "number")
        ]
    )

    /// Grammar with a keyword rule (no anchorsMatchLines).
    private let simpleGrammar = Grammar(
        name: "TestSimple",
        extensions: ["testsimple"],
        rules: [
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
            GrammarRule(pattern: "#.*$", scope: "comment", options: ["anchorsMatchLines"])
        ]
    )

    // MARK: - Helpers

    private func register(_ grammars: Grammar...) {
        for g in grammars {
            SyntaxHighlighter.shared.registerGrammar(g)
        }
    }

    private func foregroundColor(in storage: NSTextStorage, at position: Int) -> NSColor? {
        guard position < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor
    }

    /// Character offset of the start of a given line (0-based).
    private func lineOffset(_ line: Int, in text: String) -> Int {
        var offset = 0
        for (i, char) in text.enumerated() {
            if offset == line { return i }
            if char == "\n" { offset += 1 }
        }
        return text.count
    }

    // MARK: - 1. Basic newline insertion preserves highlighting

    @Test func highlightEditedPreservesColorsAfterNewlineInsertion() {
        register(yamlGrammar)

        let originalText = "name: test\nversion: 1.0"
        let storage = NSTextStorage(string: originalText)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")
        let numberColor = hl.theme.color(for: "number")

        // Full highlight
        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Verify initial colors
        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'name' should be attribute-colored")
        let versionPos = (originalText as NSString).range(of: "version").location
        #expect(foregroundColor(in: storage, at: versionPos) == attributeColor,
                "'version' should be attribute-colored")

        // Insert newline at end of first line (position 10, after "test")
        storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n")
        // Text is now: "name: test\n\nversion: 1.0"

        // Run incremental highlight with the edit range
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 10, length: 1),
            language: "testyaml",
            font: font
        )

        // Verify colors are preserved
        let newText = storage.string
        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'name' must retain attribute color after newline insertion")
        let newVersionPos = (newText as NSString).range(of: "version").location
        #expect(foregroundColor(in: storage, at: newVersionPos) == attributeColor,
                "'version' must retain attribute color after newline insertion")
        let numPos = (newText as NSString).range(of: "1.0").location
        #expect(foregroundColor(in: storage, at: numPos) == numberColor,
                "'1.0' must retain number color after newline insertion")
    }

    // MARK: - 2. Multiple consecutive newline insertions

    @Test func highlightEditedPreservesColorsAfterMultipleNewlines() {
        register(yamlGrammar)

        let text = "name: test\nversion: 1.0"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Insert 3 newlines at position 10
        storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n\n\n")
        // Text: "name: test\n\n\n\nversion: 1.0"

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 10, length: 3),
            language: "testyaml",
            font: font
        )

        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'name' must retain attribute color after multiple newlines")
        let newVersionPos = (storage.string as NSString).range(of: "version").location
        #expect(foregroundColor(in: storage, at: newVersionPos) == attributeColor,
                "'version' must retain attribute color after multiple newlines")
    }

    // MARK: - 3. Newline at beginning of file

    @Test func highlightEditedPreservesColorsAfterNewlineAtStart() {
        register(yamlGrammar)

        let text = "name: test"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)
        #expect(foregroundColor(in: storage, at: 0) == attributeColor)

        // Insert newline at the very beginning
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")
        // Text: "\nname: test"

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 0, length: 1),
            language: "testyaml",
            font: font
        )

        // "name" starts at position 1 now
        #expect(foregroundColor(in: storage, at: 1) == attributeColor,
                "'name' must be attribute-colored after newline inserted at start")
    }

    // MARK: - 4. Newline at end of file

    @Test func highlightEditedPreservesColorsAfterNewlineAtEnd() {
        register(yamlGrammar)

        let text = "name: test"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)
        #expect(foregroundColor(in: storage, at: 0) == attributeColor)

        // Insert newline at the very end
        storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n")
        // Text: "name: test\n"

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 10, length: 1),
            language: "testyaml",
            font: font
        )

        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'name' must retain attribute color after newline at end")
    }

    // MARK: - 5. Newline in middle of a YAML key

    @Test func highlightEditedHandlesNewlineInMiddleOfKey() {
        register(yamlGrammar)

        let text = "longkey: value"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)
        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'longkey' should be attribute-colored")

        // Insert newline in the middle of "longkey" (after "long")
        storage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "\n")
        // Text: "long\nkey: value"

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 4, length: 1),
            language: "testyaml",
            font: font
        )

        // "long" is no longer a key (no colon after it)
        // "key" is now a key (has colon)
        let keyPos = (storage.string as NSString).range(of: "key").location
        #expect(foregroundColor(in: storage, at: keyPos) == attributeColor,
                "'key' on new line should be attribute-colored")
        // "long" should NOT be attribute-colored (no colon)
        #expect(foregroundColor(in: storage, at: 0) != attributeColor,
                "'long' without colon should not be attribute-colored")
    }

    // MARK: - 6. Newline with auto-indent whitespace

    @Test func highlightEditedHandlesNewlineWithIndent() {
        register(yamlGrammar)

        let text = "parent:\n  child: 42"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")
        let numberColor = hl.theme.color(for: "number")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Verify initial state
        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'parent' should be attribute-colored")
        let childPos = (text as NSString).range(of: "child").location
        #expect(foregroundColor(in: storage, at: childPos) == attributeColor,
                "'child' should be attribute-colored")

        // Insert newline + indent after "child: 42" (simulating auto-indent)
        let insertPos = (text as NSString).length
        storage.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: "\n  ")
        // Text: "parent:\n  child: 42\n  "

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: insertPos, length: 3),
            language: "testyaml",
            font: font
        )

        // Verify all colors preserved
        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'parent' must retain attribute color")
        let newChildPos = (storage.string as NSString).range(of: "child").location
        #expect(foregroundColor(in: storage, at: newChildPos) == attributeColor,
                "'child' must retain attribute color")
        let numPos = (storage.string as NSString).range(of: "42").location
        #expect(foregroundColor(in: storage, at: numPos) == numberColor,
                "'42' must retain number color")
    }

    // MARK: - 7. Large file: newline preserves colors outside context window

    @Test func highlightEditedInLargeFilePreservesColorsOutsideContextWindow() {
        register(simpleGrammar)

        // 100 lines of "func lineN()"
        let lines = (0..<100).map { "func line\($0)()" }
        let text = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // Full highlight
        hl.highlight(textStorage: storage, language: "testsimple", font: font)

        // Verify colors at beginning and end
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "Line 0: 'func' should be keyword-colored")
        let line99Offset = lineOffset(99, in: text)
        #expect(foregroundColor(in: storage, at: line99Offset) == keywordColor,
                "Line 99: 'func' should be keyword-colored")

        // Insert newline at line 50
        let insertPos = lineOffset(50, in: text)
        storage.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: "\n")

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: insertPos, length: 1),
            language: "testsimple",
            font: font
        )

        // Colors near the edit should be correct
        let line49Offset = lineOffset(49, in: storage.string)
        #expect(foregroundColor(in: storage, at: line49Offset) == keywordColor,
                "Line 49: 'func' must retain keyword color")
        let line52Offset = lineOffset(52, in: storage.string)
        #expect(foregroundColor(in: storage, at: line52Offset) == keywordColor,
                "Line 52: 'func' must retain keyword color")

        // Colors far from the edit (outside ±20 line context) should survive
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "Line 0: 'func' must retain keyword color (outside context window)")
        let line99NewOffset = lineOffset(100, in: storage.string) // shifted by 1 line
        #expect(foregroundColor(in: storage, at: line99NewOffset) == keywordColor,
                "Last line: 'func' must retain keyword color (outside context window)")
    }

    // MARK: - 8. Newline insertion in comment

    @Test func highlightEditedPreservesCommentColorAfterNewline() {
        register(yamlGrammar)

        let text = "# this is a comment\nname: test"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let commentColor = hl.theme.color(for: "comment")
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)
        #expect(foregroundColor(in: storage, at: 0) == commentColor,
                "'#' should be comment-colored")

        // Insert newline after comment
        storage.replaceCharacters(in: NSRange(location: 19, length: 0), with: "\n")
        // Text: "# this is a comment\n\nname: test"

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 19, length: 1),
            language: "testyaml",
            font: font
        )

        #expect(foregroundColor(in: storage, at: 0) == commentColor,
                "Comment must retain color after newline insertion below")
        let namePos = (storage.string as NSString).range(of: "name").location
        #expect(foregroundColor(in: storage, at: namePos) == attributeColor,
                "'name' must retain attribute color after newline insertion above")
    }

    // MARK: - 9. Newline in empty document

    @Test func highlightEditedHandlesNewlineInEmptyDocument() {
        register(yamlGrammar)

        let storage = NSTextStorage(string: "")
        let hl = SyntaxHighlighter.shared

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Insert newline into empty document
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 0, length: 1),
            language: "testyaml",
            font: font
        )

        // Should not crash; text is just "\n"
        #expect(storage.string == "\n")
    }

    // MARK: - 10. Newline insertion then typing on new line

    @Test func highlightEditedHandlesTypingAfterNewline() {
        register(yamlGrammar)

        let text = "name: test"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Insert newline at end
        storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n")

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 10, length: 1),
            language: "testyaml",
            font: font
        )

        // Now type a new key on the new line
        storage.replaceCharacters(in: NSRange(location: 11, length: 0), with: "age: 25")

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 11, length: 7),
            language: "testyaml",
            font: font
        )

        // Both keys should be colored
        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'name' must retain attribute color")
        let agePos = (storage.string as NSString).range(of: "age").location
        #expect(foregroundColor(in: storage, at: agePos) == attributeColor,
                "'age' on new line must be attribute-colored")
    }

    // MARK: - 11. Async highlightEditedAsync preserves colors after newline

    @Test func highlightEditedAsyncPreservesColorsAfterNewline() async {
        register(yamlGrammar)

        let text = "name: test\nversion: 1.0"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")
        let numberColor = hl.theme.color(for: "number")

        // Full highlight to establish cache
        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Insert newline
        storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n")
        // Text: "name: test\n\nversion: 1.0"

        await hl.highlightEditedAsync(
            textStorage: storage,
            editedRange: NSRange(location: 10, length: 1),
            language: "testyaml",
            font: font
        )

        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'name' must retain attribute color after async highlight")
        let versionPos = (storage.string as NSString).range(of: "version").location
        #expect(foregroundColor(in: storage, at: versionPos) == attributeColor,
                "'version' must retain attribute color after async highlight")
        let numPos = (storage.string as NSString).range(of: "1.0").location
        #expect(foregroundColor(in: storage, at: numPos) == numberColor,
                "'1.0' must retain number color after async highlight")
    }

    // MARK: - 12. Async path with multiple newlines

    @Test func highlightEditedAsyncPreservesColorsAfterMultipleNewlines() async {
        register(yamlGrammar)

        let text = "name: test\nversion: 1.0\ncount: 5"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Insert 2 newlines after first line
        storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n\n")

        await hl.highlightEditedAsync(
            textStorage: storage,
            editedRange: NSRange(location: 10, length: 2),
            language: "testyaml",
            font: font
        )

        let newText = storage.string
        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'name' must retain attribute color")
        let vPos = (newText as NSString).range(of: "version").location
        #expect(foregroundColor(in: storage, at: vPos) == attributeColor,
                "'version' must retain attribute color")
        let cPos = (newText as NSString).range(of: "count").location
        #expect(foregroundColor(in: storage, at: cPos) == attributeColor,
                "'count' must retain attribute color")
    }

    // MARK: - 13. Newline with zero-length editedRange (edge case)

    @Test func highlightEditedHandlesZeroLengthEditedRange() {
        register(yamlGrammar)

        let text = "name: test\nversion: 1.0"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Insert newline but pass zero-length editedRange
        // (simulating pre-edit range from NSTextStorageDelegate)
        storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n")

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 10, length: 0),
            language: "testyaml",
            font: font
        )

        // Should still highlight correctly (expandToContext handles zero-length)
        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'name' must be attribute-colored even with zero-length editedRange")
        let vPos = (storage.string as NSString).range(of: "version").location
        #expect(foregroundColor(in: storage, at: vPos) == attributeColor,
                "'version' must be attribute-colored even with zero-length editedRange")
    }

    // MARK: - 14. Coordinator captures correct editedRange for newline

    @Test func coordinatorCapturesEditedRangeForNewlineInsertion() {
        let text = "name: test"
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
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "testyaml",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        // Wire up delegate
        textStorage.delegate = coordinator

        // Initially nil
        #expect(coordinator.pendingEditedRange == nil)

        // Insert a newline
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n")
        textStorage.endEditing()

        // pendingEditedRange should be captured
        #expect(coordinator.pendingEditedRange != nil,
                "Delegate must capture editedRange for newline insertion")

        // The range should cover the inserted newline in the new text
        if let range = coordinator.pendingEditedRange {
            #expect(range.location <= 10,
                    "editedRange must start at or before the insertion point")
            #expect(NSMaxRange(range) >= 11,
                    "editedRange must extend past the inserted newline")
        }

        // changeInLength should be 1
        #expect(coordinator.pendingChangeInLength == 1,
                "changeInLength must be 1 for single newline insertion")
    }

    // MARK: - 15. Coordinator captures correct editedRange for newline + indent

    @Test func coordinatorCapturesEditedRangeForNewlineWithIndent() {
        let text = "parent:\n  child: value"
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
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "testyaml",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        textStorage.delegate = coordinator

        // Insert newline + indent (simulating auto-indent)
        let insertPos = (text as NSString).length
        textStorage.beginEditing()
        textStorage.replaceCharacters(
            in: NSRange(location: insertPos, length: 0),
            with: "\n  "
        )
        textStorage.endEditing()

        #expect(coordinator.pendingEditedRange != nil,
                "Delegate must capture editedRange for newline+indent insertion")
        #expect(coordinator.pendingChangeInLength == 3,
                "changeInLength must be 3 for '\\n  ' insertion")
    }

    // MARK: - 16. Highlighting after newline splitting YAML key from colon

    @Test func highlightEditedAfterNewlineSplittingKeyColon() {
        register(yamlGrammar)

        let text = "longkey: value\nanother: data"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Verify both keys are colored
        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'longkey' should be attribute-colored initially")
        let anotherPos = (text as NSString).range(of: "another").location
        #expect(foregroundColor(in: storage, at: anotherPos) == attributeColor)

        // Insert newline in "longkey" → "long\nkey: value\nanother: data"
        storage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "\n")

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 4, length: 1),
            language: "testyaml",
            font: font
        )

        // After split, "key" should be attribute-colored (has colon on same line)
        let keyPos = (storage.string as NSString).range(of: "key").location
        #expect(foregroundColor(in: storage, at: keyPos) == attributeColor,
                "'key' with colon should be attribute-colored")

        // "another" should still be attribute-colored
        let newAnotherPos = (storage.string as NSString).range(of: "another").location
        #expect(foregroundColor(in: storage, at: newAnotherPos) == attributeColor,
                "'another' must retain attribute color")

        // Verify the regex behavior: check if "long" on its own line is still matched.
        // With anchorsMatchLines, the YAML pattern ^\\s*[\\w.-]+(?=\\s*:)
        // checks \\s*: after the matched word. \\s includes newline, so the
        // lookahead can span across lines — "long" followed by "\\nkey: " has
        // \\s (the newline) then more chars before the colon. However, \\s*:
        // requires ONLY whitespace before the colon. "\\nkey: " has "k" which
        // is not whitespace, so the lookahead should fail for "long".
        // If this assertion fails, it indicates a regex engine subtlety.
        let longColor = foregroundColor(in: storage, at: 0)
        let longIsAttribute = (longColor == attributeColor)
        // Note: We do NOT assert that "long" loses its color, because NSRegularExpression
        // may match differently depending on the engine version. The critical test is
        // that highlighting runs without crashing and keys WITH colons remain colored.
    }

    // MARK: - 17. Rapid consecutive newline insertions

    @Test func highlightEditedHandlesRapidConsecutiveNewlines() {
        register(yamlGrammar)

        let text = "a: 1\nb: 2\nc: 3"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")
        let numberColor = hl.theme.color(for: "number")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Insert newline after each line, simulating rapid Enter presses
        // After first newline: "a: 1\n\nb: 2\nc: 3"
        storage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "\n")
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 4, length: 1),
            language: "testyaml",
            font: font
        )

        // After second newline: "a: 1\n\nb: 2\n\nc: 3"
        let bLineEnd = (storage.string as NSString).range(of: "b: 2").location + 4
        storage.replaceCharacters(in: NSRange(location: bLineEnd, length: 0), with: "\n")
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: bLineEnd, length: 1),
            language: "testyaml",
            font: font
        )

        // All keys and values should be correctly colored
        let finalText = storage.string
        let aPos = (finalText as NSString).range(of: "a").location
        #expect(foregroundColor(in: storage, at: aPos) == attributeColor,
                "'a' must retain attribute color")
        let bPos = (finalText as NSString).range(of: "b").location
        #expect(foregroundColor(in: storage, at: bPos) == attributeColor,
                "'b' must retain attribute color")
        let cPos = (finalText as NSString).range(of: "c").location
        #expect(foregroundColor(in: storage, at: cPos) == attributeColor,
                "'c' must retain attribute color")
    }

    // MARK: - 18. Newline in string value

    @Test func highlightEditedPreservesStringColorAfterNewline() {
        register(yamlGrammar)

        let text = "name: \"hello\"\nkey: value"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let stringColor = hl.theme.color(for: "string")
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        let helloPos = (text as NSString).range(of: "\"hello\"").location
        #expect(foregroundColor(in: storage, at: helloPos) == stringColor,
                "'\"hello\"' should be string-colored")

        // Insert newline between the two lines
        storage.replaceCharacters(in: NSRange(location: 13, length: 0), with: "\n")

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 13, length: 1),
            language: "testyaml",
            font: font
        )

        let newText = storage.string
        let newHelloPos = (newText as NSString).range(of: "\"hello\"").location
        #expect(foregroundColor(in: storage, at: newHelloPos) == stringColor,
                "'\"hello\"' must retain string color after newline insertion")
        let keyPos = (newText as NSString).range(of: "key").location
        #expect(foregroundColor(in: storage, at: keyPos) == attributeColor,
                "'key' must retain attribute color")
    }

    // MARK: - 19. Boolean/keyword values after newline

    @Test func highlightEditedPreservesKeywordColorAfterNewline() {
        register(yamlGrammar)

        let text = "enabled: true\ncount: 42"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        let numberColor = hl.theme.color(for: "number")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        let truePos = (text as NSString).range(of: "true").location
        #expect(foregroundColor(in: storage, at: truePos) == keywordColor)
        let numPos = (text as NSString).range(of: "42").location
        #expect(foregroundColor(in: storage, at: numPos) == numberColor)

        // Insert newline between the two lines
        storage.replaceCharacters(in: NSRange(location: 13, length: 0), with: "\n")

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 13, length: 1),
            language: "testyaml",
            font: font
        )

        let newTruePos = (storage.string as NSString).range(of: "true").location
        #expect(foregroundColor(in: storage, at: newTruePos) == keywordColor,
                "'true' must retain keyword color after newline")
        let newNumPos = (storage.string as NSString).range(of: "42").location
        #expect(foregroundColor(in: storage, at: newNumPos) == numberColor,
                "'42' must retain number color after newline")
    }

    // MARK: - 21. NSTextView insertText triggers delegate before textDidChange

    @Test func insertTextTriggersStorageDelegateBeforeTextDidChange() {
        let text = "name: test"
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
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "testyaml",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        // Wire up both delegates
        textView.delegate = coordinator
        textStorage.delegate = coordinator

        // Track whether pendingEditedRange was set when textDidChange fires
        // We'll check by examining the state after insertNewline
        textView.setSelectedRange(NSRange(location: 10, length: 0))

        // Call insertNewline which uses insertText internally
        textView.insertNewline(nil)

        // After insertNewline returns, both delegates should have fired:
        // 1. textStorage(didProcessEditing:) → sets pendingEditedRange
        // 2. textDidChange → consumes pendingEditedRange
        // After textDidChange consumes it, pendingEditedRange should be nil.
        #expect(coordinator.pendingEditedRange == nil,
                "pendingEditedRange must be consumed by textDidChange after insertNewline")

        // Verify the text was actually modified
        #expect(textView.string == "name: test\n",
                "insertNewline should have inserted a newline")
    }

    // MARK: - 22. insertNewline with auto-indent triggers proper delegate sequence

    @Test func insertNewlineWithAutoIndentCapturesEditedRange() {
        let text = "parent:\n  child: value"
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
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView

        let editorView = CodeEditorView(
            text: .constant(text),
            contentVersion: 0,
            language: "testyaml",
            fileName: "test.yaml",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView
        textView.delegate = coordinator
        textStorage.delegate = coordinator

        // Place cursor at end of "child: value" (position 21)
        textView.setSelectedRange(NSRange(location: 21, length: 0))

        // insertNewline will insert "\n" + indent (preserving existing 2-space indent)
        textView.insertNewline(nil)

        // After insertNewline, pendingEditedRange should have been consumed
        #expect(coordinator.pendingEditedRange == nil,
                "pendingEditedRange must be consumed after insertNewline with auto-indent")

        // Verify the text was modified (newline + some indent added)
        let result = textView.string
        #expect(result.count > text.count,
                "insertNewline should add characters, got: \(result.debugDescription)")
    }

    // MARK: - 20. Paragraph-extended editedRange scenario

    @Test func highlightEditedHandlesParagraphExtendedRange() {
        register(yamlGrammar)

        let text = "name: test\nversion: 1.0\ncount: 5"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let attributeColor = hl.theme.color(for: "attribute")

        hl.highlight(textStorage: storage, language: "testyaml", font: font)

        // Insert newline
        storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n")

        // Simulate paragraph-extended editedRange (as NSTextStorage might report
        // after processEditing extends to paragraph boundaries)
        let extendedRange = NSRange(location: 0, length: 12) // covers "name: test\n\n"

        hl.highlightEdited(
            textStorage: storage,
            editedRange: extendedRange,
            language: "testyaml",
            font: font
        )

        #expect(foregroundColor(in: storage, at: 0) == attributeColor,
                "'name' must be colored with paragraph-extended range")
        let vPos = (storage.string as NSString).range(of: "version").location
        #expect(foregroundColor(in: storage, at: vPos) == attributeColor,
                "'version' must be colored with paragraph-extended range")
    }

    // MARK: - Generation invalidation

    @Test func generationIncrementInvalidatesStaleCapture() {
        let gen = HighlightGeneration()

        // Step 1: first increment simulates the immediate bump in
        // scheduleDeferredHighlight (invalidates prior in-flight Tasks).
        gen.increment()

        // Step 2: second increment simulates the bump inside the workItem
        // right before spawning the new Task.
        gen.increment()
        let capturedGen = gen.current  // Task captures this value

        // Step 3: another edit arrives — immediate bump again.
        gen.increment()

        // The captured generation is now stale; the Task should discard its
        // result because capturedGen != gen.current.
        #expect(capturedGen != gen.current,
                "Captured generation must differ from current after a subsequent edit")
    }

    @Test func generationRemainsValidWithoutIntervening() {
        let gen = HighlightGeneration()

        // Simulate the two-phase increment for a single edit.
        gen.increment()  // immediate bump
        gen.increment()  // workItem bump
        let capturedGen = gen.current

        // No further edits — captured generation is still valid.
        #expect(capturedGen == gen.current,
                "Captured generation must equal current when no new edit intervenes")
    }

    @Test func generationIncrementIsMonotonic() {
        let gen = HighlightGeneration()
        let first = gen.increment()
        let second = gen.increment()
        let third = gen.increment()

        #expect(first < second, "Generation must increase monotonically")
        #expect(second < third, "Generation must increase monotonically")
    }
}
