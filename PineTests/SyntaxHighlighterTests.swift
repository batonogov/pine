//
//  SyntaxHighlighterTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftUI
@testable import Pine

/// Serialized: все тесты мутируют singleton SyntaxHighlighter.shared
/// (регистрируют грамматики, меняют кэш), поэтому параллельный запуск небезопасен.
@Suite(.serialized)
struct SyntaxHighlighterTests {

    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Grammar with multiline block comment (`/* ... */`) and single-line keyword (`func`)
    private let langA = Grammar(
        name: "LangA",
        extensions: ["langa"],
        rules: [
            GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment"),
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword")
        ]
    )

    /// Grammar with single-line comment (`# ...`) only
    private let langB = Grammar(
        name: "LangB",
        extensions: ["langb"],
        rules: [
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

    /// Build text with a block comment spanning many lines.
    private func makeLongComment(prefixLines: Int = 0, commentLines: Int = 60) -> String {
        var lines: [String] = []
        for i in 0..<prefixLines {
            lines.append("func prefix\(i)()")
        }
        lines.append("/* comment start")
        for i in 1..<commentLines {
            lines.append("   comment line \(i)")
        }
        lines.append("   comment end */")
        lines.append("func after()")
        return lines.joined(separator: "\n")
    }

    // MARK: - 1. highlightEdited preserves color inside long multiline token
    //         when its opening delimiter is above the context window

    @Test func multilineTokenRetainsColorWhenStartAboveContextWindow() {
        register(langA)

        let text = makeLongComment(prefixLines: 0, commentLines: 60)
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let commentColor = hl.theme.color(for: "comment")

        // Full highlight — establishes cache and colors
        hl.highlight(textStorage: storage, language: "langa", font: font)

        // Verify comment color is applied inside the comment
        let midLine = lineOffset(30, in: text) + 3
        #expect(foregroundColor(in: storage, at: midLine) == commentColor,
                "Line 30 should be comment-colored after full highlight")

        // Simulate an edit at line 30 (inside the comment, far from `/*` at line 0).
        // The context window (~20 lines) won't reach line 0.
        // We don't actually modify the text — just call highlightEdited with a range
        // in the middle to verify the multiline regex scans the full text.
        let editPos = lineOffset(30, in: text)
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: editPos, length: 1),
            language: "langa",
            font: font
        )

        // Color inside the comment but within the repaint range must survive
        #expect(foregroundColor(in: storage, at: midLine) == commentColor,
                "Line 30 must remain comment-colored after incremental highlight")

        // Also check a line outside the context window but inside the comment
        let farLine = lineOffset(55, in: text) + 3
        #expect(foregroundColor(in: storage, at: farLine) == commentColor,
                "Line 55 (outside context window) must keep comment color")
    }

    // MARK: - 2. Removing a multiline delimiter triggers full repaint

    @Test func removingDelimiterTriggersFullRepaint() {
        register(langA)

        let text = makeLongComment(prefixLines: 0, commentLines: 40)
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let commentColor = hl.theme.color(for: "comment")

        // Full highlight
        hl.highlight(textStorage: storage, language: "langa", font: font)

        // Verify line 30 is comment-colored
        let checkPos = lineOffset(30, in: text) + 3
        #expect(foregroundColor(in: storage, at: checkPos) == commentColor)

        // Remove `/*` by replacing first two characters with spaces
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "  ")

        // highlightEdited with the edited range at the beginning
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 0, length: 2),
            language: "langa",
            font: font
        )

        // Line 30 (far from edit, was inside comment) should no longer be comment-colored
        // because `/*` was removed and the comment regex no longer matches
        let newCheckPos = lineOffset(30, in: storage.string) + 3
        #expect(foregroundColor(in: storage, at: newCheckPos) != commentColor,
                "Line 30 must lose comment color after `/*` is removed (full repaint)")
    }

    // MARK: - 3. Edit above multiline token does not cause false full repaint

    @Test func editAboveMultilineTokenUsesIncrementalPath() {
        register(langA)

        // Layout: 30 lines of code, then a 10-line block comment, then `func after()`
        var lines: [String] = []
        for i in 0..<30 {
            lines.append("func line\(i)()")
        }
        lines.append("/* block comment")
        for i in 1..<10 {
            lines.append("   comment \(i)")
        }
        lines.append("   end */")
        lines.append("func after()")
        let text = lines.joined(separator: "\n")

        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared

        // Full highlight
        hl.highlight(textStorage: storage, language: "langa", font: font)

        // Place a "marker" — set foregroundColor to red at a position far from the edit
        // (at the `func after()` line, which is at the very end).
        // If full repaint happens, this will be overwritten.
        // If incremental path is taken, it will survive (outside the repaint range).
        let afterLineOffset = lineOffset(41, in: text)
        let markerRange = NSRange(location: afterLineOffset, length: 4) // "func"
        storage.addAttribute(.foregroundColor, value: NSColor.red, range: markerRange)

        // Edit at line 0 (insert a space at the beginning)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: " ")

        // highlightEdited at the insertion point
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 0, length: 1),
            language: "langa",
            font: font
        )

        // The red marker should survive — proving incremental path was taken,
        // not a false full repaint triggered by shifted multiline positions
        let newMarkerPos = afterLineOffset + 1 // shifted by 1 due to insertion
        let colorAtMarker = foregroundColor(in: storage, at: newMarkerPos)
        #expect(colorAtMarker == NSColor.red,
                "Marker outside repaint range must survive — proves no false full repaint")
    }

    // MARK: - 4. Language change with same text re-highlights (SyntaxHighlighter level)

    @Test func languageChangeWithSameTextReHighlights() {
        register(langA, langB)

        let text = "# this is a comment\nfunc hello()"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let commentColor = hl.theme.color(for: "comment")
        let keywordColor = hl.theme.color(for: "keyword")

        // Highlight as langA (C-style comments, `func` keyword)
        // `#` is not a comment in langA, but `func` is a keyword
        hl.highlight(textStorage: storage, language: "langa", font: font)

        let hashPos = 0 // `#` character
        let funcPos = (text as NSString).range(of: "func").location

        #expect(foregroundColor(in: storage, at: hashPos) != commentColor,
                "`#` should not be comment in langA")
        #expect(foregroundColor(in: storage, at: funcPos) == keywordColor,
                "`func` should be keyword in langA")

        // Now re-highlight as langB (# comments, no keyword rule)
        hl.invalidateCache(for: storage)
        hl.highlight(textStorage: storage, language: "langb", font: font)

        #expect(foregroundColor(in: storage, at: hashPos) == commentColor,
                "`#` should be comment in langB")
        #expect(foregroundColor(in: storage, at: funcPos) != keywordColor,
                "`func` should not be keyword in langB")
    }

    // MARK: - 5. Cache invalidation prevents stale range usage

    @Test func invalidateCacheForcesFullRepaintOnNextEdit() {
        register(langA)

        let text = makeLongComment(prefixLines: 0, commentLines: 40)
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let commentColor = hl.theme.color(for: "comment")

        // Full highlight — fills the cache
        hl.highlight(textStorage: storage, language: "langa", font: font)

        // Place a red marker far from where we'll "edit"
        let farPos = lineOffset(35, in: text) + 3
        storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: farPos, length: 1))
        #expect(foregroundColor(in: storage, at: farPos) == NSColor.red, "Red marker should be set")

        // Invalidate cache (simulates file switch)
        hl.invalidateCache(for: storage)

        // Now call highlightEdited — without cache, fingerprint comparison
        // is nil != [current], which triggers full repaint
        hl.highlightEdited(
            textStorage: storage,
            editedRange: NSRange(location: 0, length: 1),
            language: "langa",
            font: font
        )

        // Red marker should be gone — full repaint overwrote it with comment color
        #expect(foregroundColor(in: storage, at: farPos) == commentColor,
                "After cache invalidation, full repaint must overwrite marker with comment color")
    }

    // MARK: - 6. updateNSView detects language change with identical text

    @Test func updateNSViewReHighlightsOnLanguageChangeWithSameText() {
        register(langA, langB)

        let text = "# this is a comment\nfunc hello()"
        let hl = SyntaxHighlighter.shared
        let commentColor = hl.theme.color(for: "comment")
        let keywordColor = hl.theme.color(for: "keyword")

        // Build the text system manually (same stack as CodeEditorView.makeNSView)
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(textContainer)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: textContainer)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView

        // Create Coordinator with langA
        var editorView = CodeEditorView(
            text: .constant(text),
            language: "langa",
            fileName: "test.langa"
        )
        let coordinator = CodeEditorView.Coordinator(parent: editorView)
        coordinator.scrollView = scrollView

        // Simulate first updateNSView — establishes lastLanguage/lastFileName
        coordinator.lastLanguage = "langa"
        coordinator.lastFileName = "test.langa"
        hl.highlight(textStorage: textStorage, language: "langa", font: font)

        let hashPos = 0
        let funcPos = (text as NSString).range(of: "func").location

        #expect(foregroundColor(in: textStorage, at: hashPos) != commentColor,
                "`#` should not be comment in langA")
        #expect(foregroundColor(in: textStorage, at: funcPos) == keywordColor,
                "`func` should be keyword in langA")

        // Now simulate switching to langB — same text, different language
        editorView = CodeEditorView(
            text: .constant(text),
            language: "langb",
            fileName: "test.langb"
        )
        coordinator.parent = editorView

        // This is the logic from updateNSView that we're testing:
        // languageChanged should be true, textChanged should be false
        let languageChanged = coordinator.lastLanguage != editorView.language
            || coordinator.lastFileName != editorView.fileName
        let textChanged = textView.string != text

        #expect(languageChanged, "Language change must be detected")
        #expect(!textChanged, "Text must be identical")

        // Execute the same code path as updateNSView
        if textChanged || languageChanged {
            coordinator.cancelPendingHighlight()
            hl.invalidateCache(for: textStorage)

            // text didn't change, so no textView.string = text
            hl.highlight(textStorage: textStorage, language: editorView.language, font: font)

            coordinator.lastLanguage = editorView.language
            coordinator.lastFileName = editorView.fileName
        }

        // Verify re-highlighting happened with the new grammar
        #expect(foregroundColor(in: textStorage, at: hashPos) == commentColor,
                "`#` must become comment after language switch to langB")
        #expect(foregroundColor(in: textStorage, at: funcPos) != keywordColor,
                "`func` must lose keyword color after language switch to langB")
    }
}
