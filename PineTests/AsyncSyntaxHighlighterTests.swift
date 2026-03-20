//
//  AsyncSyntaxHighlighterTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for async syntax highlighting (background computation + main thread application).
/// Serialized: all tests mutate singleton SyntaxHighlighter.shared.
@Suite(.serialized)
struct AsyncSyntaxHighlighterTests {

    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let langA = Grammar(
        name: "LangAsync",
        extensions: ["langasync"],
        rules: [
            GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment"),
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword")
        ]
    )

    private func register(_ grammars: Grammar...) {
        for g in grammars {
            SyntaxHighlighter.shared.registerGrammar(g)
        }
    }

    private func foregroundColor(in storage: NSTextStorage, at position: Int) -> NSColor? {
        guard position < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor
    }

    // MARK: - computeMatches returns correct results

    @Test func computeMatchesReturnsMatchesForKeywords() {
        register(langA)

        let text = "func hello() /* comment */"
        let hl = SyntaxHighlighter.shared
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let result = hl.computeMatches(
            text: text,
            language: "langasync",
            repaintRange: fullRange,
            searchRange: fullRange
        )

        #expect(result != nil, "computeMatches should return a result for known language")
        guard let result else { return }

        // Should find "func" keyword and "/* comment */" comment
        let keywordMatches = result.matches.filter { $0.scope == "keyword" }
        let commentMatches = result.matches.filter { $0.scope == "comment" }
        #expect(keywordMatches.count == 1, "Should find 1 keyword match")
        #expect(commentMatches.count == 1, "Should find 1 comment match")
        #expect(keywordMatches.first?.range == NSRange(location: 0, length: 4))
    }

    @Test func computeMatchesReturnsNilForUnknownLanguage() {
        let result = SyntaxHighlighter.shared.computeMatches(
            text: "some text",
            language: "nonexistent",
            repaintRange: NSRange(location: 0, length: 9),
            searchRange: NSRange(location: 0, length: 9)
        )
        #expect(result == nil)
    }

    // MARK: - applyMatches produces same result as sync highlight

    @Test func applyMatchesProducesSameResultAsSyncHighlight() {
        register(langA)

        let text = "func hello() /* comment */ func world()"
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        let commentColor = hl.theme.color(for: "comment")

        // Sync highlight
        let syncStorage = NSTextStorage(string: text)
        hl.highlight(textStorage: syncStorage, language: "langasync", font: font)

        // Async-style: compute + apply
        let asyncStorage = NSTextStorage(string: text)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard let result = hl.computeMatches(
            text: text,
            language: "langasync",
            repaintRange: fullRange,
            searchRange: fullRange
        ) else {
            Issue.record("computeMatches returned nil")
            return
        }
        hl.applyMatches(result, to: asyncStorage, font: font)

        // Compare colors at key positions
        let funcPos = 0
        let commentPos = (text as NSString).range(of: "/*").location
        let func2Pos = (text as NSString).range(of: "func world").location

        #expect(foregroundColor(in: asyncStorage, at: funcPos) == keywordColor)
        #expect(foregroundColor(in: asyncStorage, at: commentPos) == commentColor)
        #expect(foregroundColor(in: asyncStorage, at: func2Pos) == keywordColor)

        // Verify same as sync
        #expect(foregroundColor(in: asyncStorage, at: funcPos) == foregroundColor(in: syncStorage, at: funcPos))
        #expect(foregroundColor(in: asyncStorage, at: commentPos) == foregroundColor(in: syncStorage, at: commentPos))
        #expect(foregroundColor(in: asyncStorage, at: func2Pos) == foregroundColor(in: syncStorage, at: func2Pos))
    }

    // MARK: - highlightAsync completes and applies results

    @Test func highlightAsyncAppliesResults() async {
        register(langA)

        let text = "func hello() /* comment */"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")
        let commentColor = hl.theme.color(for: "comment")

        await hl.highlightAsync(
            textStorage: storage,
            language: "langasync",
            font: font
        )

        let funcPos = 0
        let commentPos = (text as NSString).range(of: "/*").location

        #expect(foregroundColor(in: storage, at: funcPos) == keywordColor)
        #expect(foregroundColor(in: storage, at: commentPos) == commentColor)
    }

    // MARK: - highlightEditedAsync works correctly

    @Test func highlightEditedAsyncAppliesResults() async {
        register(langA)

        let text = "func hello() /* block\ncomment */ func world()"
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let commentColor = hl.theme.color(for: "comment")

        // Full highlight first to populate cache
        await hl.highlightAsync(textStorage: storage, language: "langasync", font: font)

        // Simulate edit
        let editRange = NSRange(location: 0, length: 4)
        await hl.highlightEditedAsync(
            textStorage: storage,
            editedRange: editRange,
            language: "langasync",
            font: font
        )

        // Comment should still be colored
        let commentPos = (text as NSString).range(of: "/*").location
        #expect(foregroundColor(in: storage, at: commentPos) == commentColor)
    }

    // MARK: - highlightVisibleRangeAsync works correctly

    @Test func highlightVisibleRangeAsyncAppliesResults() async {
        register(langA)

        let lines = (0..<200).map { "func line\($0)()" }
        let text = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: text)
        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        let rangeStart = lineOffset(50, in: text)
        let rangeEnd = lineOffset(60, in: text)
        let visibleRange = NSRange(location: rangeStart, length: rangeEnd - rangeStart)

        await hl.highlightVisibleRangeAsync(
            textStorage: storage,
            visibleCharRange: visibleRange,
            language: "langasync",
            font: font
        )

        // Line 55 should have keyword color
        let line55Offset = lineOffset(55, in: text)
        #expect(foregroundColor(in: storage, at: line55Offset) == keywordColor)
    }

    // MARK: - HighlightGeneration counter

    @Test func generationCounterWorks() {
        let gen = HighlightGeneration()
        #expect(gen.current == 0, "Initial value should be 0")

        gen.increment()
        #expect(gen.current == 1, "After one increment should be 1")

        let captured = gen.current
        gen.increment()
        #expect(gen.current != captured,
                "After increment, current must differ from previously captured value")
        #expect(gen.current == 2)
    }

    // MARK: - highlightAsync respects generation

    @Test func highlightAsyncAppliesWhenGenerationIsCurrent() async {
        register(langA)

        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // Without generation — always applies
        let storage1 = NSTextStorage(string: "func hello()")
        await hl.highlightAsync(
            textStorage: storage1, language: "langasync", font: font
        )
        #expect(foregroundColor(in: storage1, at: 0) == keywordColor,
                "Without generation, highlight must apply")

        // With current (non-bumped) generation — applies
        let gen = HighlightGeneration()
        gen.increment() // 1
        let storage2 = NSTextStorage(string: "func hello()")
        await hl.highlightAsync(
            textStorage: storage2, language: "langasync", font: font, generation: gen
        )
        #expect(foregroundColor(in: storage2, at: 0) == keywordColor,
                "With current generation, highlight must apply")
    }

    @Test func highlightAsyncDiscardsWhenGenerationIsStale() async throws {
        register(langA)

        let hl = SyntaxHighlighter.shared
        let keywordColor = hl.theme.color(for: "keyword")

        // Use large text so background computation takes non-trivial time (~10ms+).
        // Start the highlight in a separate Task, then bump generation while
        // background is running. By the time it resumes, generation will be stale.
        let lines = (0..<20_000).map { "func line\($0)()" }
        let bigText = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: bigText)

        let gen = HighlightGeneration()
        gen.increment() // 1

        let task = Task {
            await hl.highlightAsync(
                textStorage: storage,
                language: "langasync",
                font: font,
                generation: gen
            )
        }

        // Yield to let the task start and begin background computation.
        // Then bump generation to invalidate the result.
        try await Task.sleep(for: .milliseconds(1))
        gen.increment() // 2

        await task.value

        // Result should be discarded — no keyword color at a line in the middle
        let checkPos = lineOffset(10_000, in: bigText)
        #expect(foregroundColor(in: storage, at: checkPos) != keywordColor,
                "Highlight must be discarded when generation is bumped during computation")
    }

    // MARK: - applyMatches validates ranges

    @Test func applyMatchesDiscardsWhenRangesAreStale() {
        register(langA)

        let hl = SyntaxHighlighter.shared

        // Compute matches for a longer text
        let text = "func hello() /* comment */"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard let result = hl.computeMatches(
            text: text, language: "langasync",
            repaintRange: fullRange, searchRange: fullRange
        ) else {
            Issue.record("computeMatches returned nil")
            return
        }

        // Apply to a SHORTER textStorage — repaintRange is out of bounds
        let shortStorage = NSTextStorage(string: "hi")

        // Should not crash — applyMatches must validate ranges
        hl.applyMatches(result, to: shortStorage, font: font)

        // Storage should be unmodified (no attributes applied)
        let color = foregroundColor(in: shortStorage, at: 0)
        let keywordColor = hl.theme.color(for: "keyword")
        #expect(color != keywordColor,
                "applyMatches must skip when repaintRange exceeds textStorage.length")
    }

    // MARK: - multilineFingerprint computed correctly

    @Test func computeMatchesIncludesMultilineFingerprint() {
        register(langA)

        let text = "/* comment */ func hello() /* another */"
        let hl = SyntaxHighlighter.shared
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let result = hl.computeMatches(
            text: text,
            language: "langasync",
            repaintRange: fullRange,
            searchRange: fullRange
        )

        #expect(result != nil)
        guard let result else { return }

        // The `/* ... */` pattern is multiline — should produce fingerprint entries
        #expect(result.multilineFingerprint.count == 2,
                "Two block comments should produce 2 fingerprint entries")
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
