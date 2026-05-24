//
//  HighlightFlickerTests.swift
//  PineTests
//
//  Tests for syntax highlighting flicker fix (#863).
//  Verifies that pressing Enter does not cause visible attribute reset.
//

import Testing
import SwiftUI
import AppKit
@testable import Pine

/// Serialized: all tests mutate singleton SyntaxHighlighter.shared.
@Suite(.serialized)
@MainActor
struct HighlightFlickerTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let swiftGrammar = Grammar(
        name: "FlickerSwift",
        extensions: ["flickerswift"],
        rules: [
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
            GrammarRule(pattern: "\\bvar\\b", scope: "keyword"),
            GrammarRule(pattern: "\\blet\\b", scope: "keyword"),
            GrammarRule(pattern: "\"[^\"]*\"", scope: "string"),
            GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
            GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment")
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

    /// Checks whether all positions in the given range have a non-default text color.
    private func allPositionsHaveNonDefaultColor(
        in storage: NSTextStorage,
        range: NSRange,
        defaultColor: NSColor
    ) -> Bool {
        guard storage.length > 0 else { return true }
        let checkEnd = min(NSMaxRange(range), storage.length)
        for i in range.location..<checkEnd {
            if let color = foregroundColor(in: storage, at: i), color != defaultColor {
                continue
            }
            // Whitespace positions may not be colored — skip them
            let source = storage.string as NSString
            if i < source.length {
                let ch = source.character(at: i)
                let space = UInt16((" " as Character).asciiValue ?? 0)
                let newline = UInt16(("\n" as Character).asciiValue ?? 0)
                let tab = UInt16(("\t" as Character).asciiValue ?? 0)
                if ch == space || ch == newline || ch == tab {
                    continue
                }
            }
            return false
        }
        return true
    }

    // MARK: - 1. Sync highlightEdited preserves colors outside edited range

    @Test("highlightEdited does not reset colors outside the context window")
    func highlightEditedPreservesColorsOutsideContextWindow() {
        register(swiftGrammar)

        // Build text with highlighted keywords spread far apart
        let lines = (0..<100).map { "func line\($0)()" }
        let text = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // Full highlight
        hl.highlight(textStorage: storage, language: "flickerswift", font: font)

        // Verify "func" at line 0 is colored
        #expect(foregroundColor(in: storage, at: 0) == keywordColor)

        // Insert newline at line 50
        let insertPos = lineOffset(50, in: text)
        storage.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: "\n")

        // Sync incremental highlight — should only repaint ±20 lines around edit
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: insertPos, length: 1),
            language: "flickerswift",
            font: font
        )

        // Colors far from the edit should be preserved (line 0 and line 99)
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "Line 0 must retain keyword color after incremental highlight")
        // After inserting newline at line 50, original line 99 is now line 100 (0-based).
        let lastLinePos = lineOffset(100, in: storage.string)
        let safePos = min(lastLinePos, (storage.string as NSString).length - 1)
        #expect(safePos >= 0, "Must have a valid position for last line")
        #expect(foregroundColor(in: storage, at: safePos) == keywordColor,
                "Last line must retain keyword color after incremental highlight")
    }

    // MARK: - 2. Sync highlightEdited does not cause global attribute reset

    @Test("highlightEdited with newline does not reset attributes globally")
    func highlightEditedNoGlobalReset() {
        register(swiftGrammar)

        let text = "func hello() {\n    let x = \"world\"\n}"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        let stringColor = hl.theme.color(for: "string")

        // Full highlight
        hl.highlight(textStorage: storage, language: "flickerswift", font: font)

        // Verify initial colors
        #expect(foregroundColor(in: storage, at: 0) == keywordColor)
        let letPos = (text as NSString).range(of: "let").location
        #expect(foregroundColor(in: storage, at: letPos) == keywordColor)
        let stringPos = (text as NSString).range(of: "\"world\"").location
        #expect(foregroundColor(in: storage, at: stringPos) == stringColor)

        // Insert newline at end of first line (after "{")
        let bracePos = (text as NSString).range(of: "{").location
        storage.replaceCharacters(in: NSRange(location: bracePos + 1, length: 0), with: "\n")

        // Record attribute at position 0 BEFORE incremental highlight
        let colorBeforeEdit = foregroundColor(in: storage, at: 0)
        #expect(colorBeforeEdit == keywordColor,
                "Keyword at position 0 should still be colored before incremental highlight")

        // Sync incremental highlight
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: bracePos + 1, length: 1),
            language: "flickerswift",
            font: font
        )

        // Position 0 should still be colored (never went blank)
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "Keyword at position 0 must retain color after incremental highlight")
        let newLetPos = (storage.string as NSString).range(of: "let").location
        #expect(foregroundColor(in: storage, at: newLetPos) == keywordColor,
                "'let' must retain keyword color after incremental highlight")
        let newStringPos = (storage.string as NSString).range(of: "\"world\"").location
        #expect(foregroundColor(in: storage, at: newStringPos) == stringColor,
                "String must retain color after incremental highlight")
    }

    // MARK: - 3. Multiline comment insertion does not cause full repaint flicker

    @Test("Inserting newline inside block comment updates fingerprint without global reset")
    func newlineInBlockCommentIncrementalHighlight() {
        register(swiftGrammar)

        let text = "func test() {\n    /* block comment */\n}"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        let commentColor = hl.theme.color(for: "comment")

        // Full highlight
        hl.highlight(textStorage: storage, language: "flickerswift", font: font)

        // Verify "func" is colored
        #expect(foregroundColor(in: storage, at: 0) == keywordColor)
        // Verify comment is colored
        let commentPos = (text as NSString).range(of: "/*").location
        #expect(foregroundColor(in: storage, at: commentPos) == commentColor)

        // Insert newline inside block comment (after "block")
        let blockPos = (text as NSString).range(of: "block ").location + 5
        storage.replaceCharacters(in: NSRange(location: blockPos, length: 0), with: "\n")

        // This WILL trigger full repaint because multiline fingerprint changes
        // (block comment length increases by 1). But the highlight should still be correct.
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: blockPos, length: 1),
            language: "flickerswift",
            font: font
        )

        // "func" must still be colored even after full repaint
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "'func' must be colored after full repaint from block comment change")
        // Comment must still be colored
        let newCommentPos = (storage.string as NSString).range(of: "/*").location
        #expect(foregroundColor(in: storage, at: newCommentPos) == commentColor,
                "Block comment must be colored after full repaint")
    }

    // MARK: - 4. applyMatches does not reset attributes beyond repaintRange

    @Test("applyMatches only resets attributes within repaintRange")
    func applyMatchesRespectsRepaintRange() {
        register(swiftGrammar)

        let text = "func hello() {\n    let x = 1\n    var y = 2\n}"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // Full highlight
        hl.highlight(textStorage: storage, language: "flickerswift", font: font)

        // Verify keywords at start
        #expect(foregroundColor(in: storage, at: 0) == keywordColor)

        // Now compute matches for a SUBSET of the text (lines 2-3 only)
        let letPos = (text as NSString).range(of: "let").location
        _ = (text as NSString).range(of: "var").location
        let line2Start = letPos
        let line3End = (text as NSString).range(of: "2\n").location + 2
        let subrange = NSRange(location: line2Start, length: line3End - line2Start)

        guard let result = hl.computeMatches(
            text: text,
            language: "flickerswift",
            repaintRange: subrange,
            searchRange: subrange
        ) else {
            Issue.record("computeMatches returned nil")
            return
        }

        // Apply to the subset — this should NOT reset attributes outside subrange
        hl.applyMatches(result, to: storage, font: font)

        // "func" at position 0 must still be colored (outside repaintRange)
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "'func' must retain color — it's outside repaintRange")
    }

    // MARK: - 5. Rapid consecutive edits maintain highlighting

    @Test("Rapid consecutive edits maintain highlighting consistency")
    func rapidConsecutiveEditsMaintainHighlighting() {
        register(swiftGrammar)

        let text = "func test() {\n    let x = 1\n}"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // Full highlight
        hl.highlight(textStorage: storage, language: "flickerswift", font: font)
        #expect(foregroundColor(in: storage, at: 0) == keywordColor)

        // Simulate rapid typing: insert "var" character by character
        let insertPos = (text as NSString).range(of: "}").location
        storage.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: "v")
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: insertPos, length: 1),
            language: "flickerswift",
            font: font
        )
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "'func' must retain color after first char insertion")

        storage.replaceCharacters(in: NSRange(location: insertPos + 1, length: 0), with: "a")
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: insertPos, length: 2),
            language: "flickerswift",
            font: font
        )
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "'func' must retain color after second char insertion")

        storage.replaceCharacters(in: NSRange(location: insertPos + 2, length: 0), with: "r")
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: insertPos, length: 3),
            language: "flickerswift",
            font: font
        )
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "'func' must retain color after third char insertion")

        // "var" should now be recognized as keyword
        let varPos = (storage.string as NSString).range(of: "var").location
        #expect(foregroundColor(in: storage, at: varPos) == keywordColor,
                "'var' should be keyword-colored after typing it")
    }

    // MARK: - 6. highlightEdited does not destroy colors on lines far from edit

    @Test("highlightEdited preserves colors on first and last lines for 50-line file")
    func highlightEditedPreservesFirstAndLastLines() {
        register(swiftGrammar)

        // 50 lines: each starts with "func"
        let lines = (0..<50).map { "func method\($0)()" }
        let text = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // Full highlight
        hl.highlight(textStorage: storage, language: "flickerswift", font: font)

        // Verify all lines are highlighted
        for i in 0..<50 {
            let pos = lineOffset(i, in: text)
            #expect(foregroundColor(in: storage, at: pos) == keywordColor,
                    "Line \(i) should be keyword-colored before edit")
        }

        // Insert newline at line 25 (right in the middle)
        let editPos = lineOffset(25, in: text)
        storage.replaceCharacters(in: NSRange(location: editPos, length: 0), with: "\n")

        // Incremental highlight with context ±20 lines
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: editPos, length: 1),
            language: "flickerswift",
            font: font
        )

        // Line 0 and line 49 (now line 50) should still be colored
        // These are outside the ±20 line context window from the edit at line 25
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "Line 0 (outside context) must retain color")
        // After inserting newline at line 25, original line 49 is now line 50 (0-based).
        let lastLinePos = lineOffset(50, in: storage.string)
        let safePos = min(lastLinePos, (storage.string as NSString).length - 1)
        #expect(safePos >= 0, "Must have a valid position for last line")
        #expect(foregroundColor(in: storage, at: safePos) == keywordColor,
                "Last line (outside context) must retain color")
    }

    // MARK: - 7. Coordinator uses sync highlight for edits on small files

    @Test("Coordinator applies sync highlight immediately on text change")
    func coordinatorAppliesSyncHighlightOnEdit() {
        register(swiftGrammar)

        let text = "func test()"
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
            language: "flickerswift",
            fileName: "test.swift",
            foldState: .constant(FoldState())
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        // Wire up delegates
        textView.delegate = coordinator
        textStorage.delegate = coordinator

        // Initial highlight — apply sync highlight to establish baseline
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        hl.highlight(textStorage: textStorage, language: "flickerswift", font: font)
        #expect(foregroundColor(in: textStorage, at: 0) == keywordColor)

        // Simulate insertNewline: insert "\n" at end
        textView.setSelectedRange(NSRange(location: text.count, length: 0))
        textView.insertNewline(nil)

        // After insertNewline, textDidChange fires synchronously
        // and scheduleDeferredHighlight is called with debounce.
        // But the key fix: we want the highlight to be applied
        // BEFORE the display cycle, not after a 100ms debounce.
        // The fix is: for edits, apply sync incremental highlight immediately.

        // Verify the text was modified
        let newText = textView.string
        #expect(newText.hasPrefix("func test()\n"),
                "insertNewline should insert a newline")

        // After the fix, "func" should still be colored immediately
        // (because sync incremental highlight runs in textDidChange)
        #expect(foregroundColor(in: textStorage, at: 0) == keywordColor,
                "'func' must retain keyword color immediately after insertNewline")
    }

    // MARK: - 8. Full highlight after multiline fingerprint change still preserves colors

    @Test("Full repaint triggered by fingerprint change preserves all token colors")
    func fullRepaintPreservesColors() {
        register(swiftGrammar)

        let text = "func a() {}\nfunc b() {}\n/* block\ncomment */\nfunc c() {}"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        let commentColor = hl.theme.color(for: "comment")

        hl.highlight(textStorage: storage, language: "flickerswift", font: font)

        // Verify initial state
        #expect(foregroundColor(in: storage, at: 0) == keywordColor)
        let funcBPos = (text as NSString).range(of: "func b").location
        #expect(foregroundColor(in: storage, at: funcBPos) == keywordColor)
        let funcCPos = (text as NSString).range(of: "func c").location
        #expect(foregroundColor(in: storage, at: funcCPos) == keywordColor)
        let commentStartPos = (text as NSString).range(of: "/*").location
        #expect(foregroundColor(in: storage, at: commentStartPos) == commentColor)

        // Insert newline inside block comment — triggers fingerprint change → full repaint
        let commentBodyPos = (text as NSString).range(of: "block").location + 2
        storage.replaceCharacters(in: NSRange(location: commentBodyPos, length: 0), with: "\n")

        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: commentBodyPos, length: 1),
            language: "flickerswift",
            font: font
        )

        // All keywords must still be colored after full repaint
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "func a must retain color after full repaint")
        let newFuncBPos = (storage.string as NSString).range(of: "func b").location
        #expect(foregroundColor(in: storage, at: newFuncBPos) == keywordColor,
                "func b must retain color after full repaint")
        let newFuncCPos = (storage.string as NSString).range(of: "func c").location
        #expect(foregroundColor(in: storage, at: newFuncCPos) == keywordColor,
                "func c must retain color after full repaint")
        let newCommentPos = (storage.string as NSString).range(of: "/*").location
        #expect(foregroundColor(in: storage, at: newCommentPos) == commentColor,
                "block comment must retain color after full repaint")
    }

    // MARK: - 9. Async highlightEditedAsync respects edited range boundaries

    @Test("Async highlightEditedAsync preserves colors outside context window")
    func asyncHighlightEditedPreservesColorsOutsideContext() async {
        register(swiftGrammar)

        let lines = (0..<100).map { "func line\($0)()" }
        let text = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // Full highlight to establish cache
        hl.highlight(textStorage: storage, language: "flickerswift", font: font)

        // Insert newline at line 50
        let insertPos = lineOffset(50, in: text)
        storage.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: "\n")

        await hl.highlightEditedAsync(
            textStorage: storage,
            editedRange: NSRange(location: insertPos, length: 1),
            language: "flickerswift",
            font: font
        )

        // Colors far from the edit should be preserved
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "Line 0 must retain color after async incremental highlight")
        let lastLinePos = lineOffset(100, in: storage.string)
        let safePos = min(lastLinePos, (storage.string as NSString).length - 1)
        #expect(safePos >= 0, "Must have a valid position for last line")
        #expect(foregroundColor(in: storage, at: safePos) == keywordColor,
                "Last line must retain color after async incremental highlight")
    }

    // MARK: - Helpers

    private func lineOffset(_ line: Int, in text: String) -> Int {
        var offset = 0
        for (i, char) in text.enumerated() {
            if offset == line { return i }
            if char == "\n" { offset += 1 }
        }
        return text.count
    }
}
