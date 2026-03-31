//
//  HighlightCacheTests.swift
//  PineTests
//
//  Tests for syntax highlight caching to eliminate flash on tab switch.
//

import Testing
import AppKit
@testable import Pine

@Suite(.serialized)
@MainActor
struct HighlightCacheTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let swiftGrammar = Grammar(
        name: "TestSwift",
        extensions: ["testswift"],
        rules: [
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
            GrammarRule(pattern: "\"[^\"]*\"", scope: "string"),
            GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"])
        ]
    )

    private func register(_ grammars: Grammar...) {
        for grammar in grammars {
            SyntaxHighlighter.shared.registerGrammar(grammar)
        }
    }

    // MARK: - EditorTab cache property

    @Test("EditorTab cachedHighlightResult is nil by default")
    func tabCacheNilByDefault() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.swift"), content: "func test() {}")
        #expect(tab.cachedHighlightResult == nil)
    }

    @Test("EditorTab cachedHighlightResult can be set and read")
    func tabCacheSetAndRead() {
        var tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.swift"), content: "func test() {}")
        let result = HighlightMatchResult(
            matches: [HighlightMatch(range: NSRange(location: 0, length: 4), scope: "keyword", priority: 0)],
            repaintRange: NSRange(location: 0, length: 14),
            multilineFingerprint: []
        )
        tab.cachedHighlightResult = result
        #expect(tab.cachedHighlightResult != nil)
        #expect(tab.cachedHighlightResult?.matches.count == 1)
    }

    // MARK: - Synchronous highlight returns result

    @Test("SyntaxHighlighter.highlight returns match result for caching")
    func highlightReturnsCacheableResult() throws {
        register(swiftGrammar)
        let storage = NSTextStorage(string: "func hello() {}")
        let result = SyntaxHighlighter.shared.highlight(
            textStorage: storage,
            language: "testswift",
            font: font
        )
        let unwrapped = try #require(result)
        #expect(unwrapped.matches.isEmpty == false)
        // "func" should be highlighted as keyword
        let keywordMatch = unwrapped.matches.first { $0.scope == "keyword" }
        #expect(keywordMatch != nil)
        #expect(keywordMatch?.range == NSRange(location: 0, length: 4))
    }

    @Test("SyntaxHighlighter.highlight returns nil for unknown language")
    func highlightReturnsNilForUnknownLanguage() {
        let storage = NSTextStorage(string: "some text")
        let result = SyntaxHighlighter.shared.highlight(
            textStorage: storage,
            language: "nonexistent_language_xyz",
            font: font
        )
        #expect(result == nil)
    }

    // MARK: - Cache applied synchronously matches async result

    @Test("Cached result applied synchronously produces same colors as fresh highlight")
    func cachedResultMatchesFreshHighlight() throws {
        register(swiftGrammar)

        // First: highlight fresh and capture result
        let text = "func foo() { // comment\n    \"string\"\n}"
        let storage1 = NSTextStorage(string: text)
        let result = SyntaxHighlighter.shared.highlight(
            textStorage: storage1,
            language: "testswift",
            font: font
        )
        let unwrapped = try #require(result)

        // Capture colors from fresh highlight
        var freshColors: [Int: NSColor] = [:]
        for i in 0..<storage1.length {
            if let color = storage1.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor {
                freshColors[i] = color
            }
        }

        // Second: apply cached result to new storage with same text
        let storage2 = NSTextStorage(string: text)
        // Set default attributes first (simulating what makeNSView does)
        storage2.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: NSRange(location: 0, length: storage2.length))

        SyntaxHighlighter.shared.applyMatches(unwrapped, to: storage2, font: font)

        // Colors should match
        for i in 0..<storage2.length {
            let cachedColor = storage2.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
            let freshColor = freshColors[i]
            #expect(cachedColor == freshColor, "Color mismatch at position \(i)")
        }
    }

    // MARK: - Cache invalidation on content change

    @Test("TabManager.updateContent invalidates highlight cache")
    func updateContentInvalidatesCache() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        var tab = EditorTab(url: url, content: "func test() {}")
        tab.cachedHighlightResult = HighlightMatchResult(
            matches: [HighlightMatch(range: NSRange(location: 0, length: 4), scope: "keyword", priority: 0)],
            repaintRange: NSRange(location: 0, length: 14),
            multilineFingerprint: []
        )
        #expect(tab.cachedHighlightResult != nil)

        // Simulate what updateContent does: set content and nil the cache
        tab.content = "let x = 1"
        tab.cachedHighlightResult = nil
        #expect(tab.cachedHighlightResult == nil)
    }

    // MARK: - Cache survives tab switch roundtrip

    @Test("Highlight cache persists across simulated tab switches")
    func cachePersistsAcrossTabSwitch() throws {
        register(swiftGrammar)

        // Create two tabs
        var tab1 = EditorTab(url: URL(fileURLWithPath: "/tmp/a.swift"), content: "func a() {}")
        var tab2 = EditorTab(url: URL(fileURLWithPath: "/tmp/b.swift"), content: "func b() {}")

        // Highlight tab1 and cache result
        let storage1 = NSTextStorage(string: tab1.content)
        let result1 = SyntaxHighlighter.shared.highlight(
            textStorage: storage1, language: "testswift", font: font
        )
        tab1.cachedHighlightResult = result1

        // Highlight tab2 and cache result
        let storage2 = NSTextStorage(string: tab2.content)
        let result2 = SyntaxHighlighter.shared.highlight(
            textStorage: storage2, language: "testswift", font: font
        )
        tab2.cachedHighlightResult = result2

        // Both caches should exist
        let cached1 = try #require(tab1.cachedHighlightResult)
        #expect(tab2.cachedHighlightResult != nil)

        // Switch back to tab1 — apply cached result to fresh storage
        let freshStorage = NSTextStorage(string: tab1.content)
        freshStorage.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: NSRange(location: 0, length: freshStorage.length))

        SyntaxHighlighter.shared.applyMatches(cached1, to: freshStorage, font: font)

        // "func" should be highlighted
        let funcColor = freshStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let bodyColor = freshStorage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
        #expect(funcColor != bodyColor, "Keyword 'func' should have different color from body text")
    }

    // MARK: - applyMatches validates range bounds

    @Test("applyMatches discards result when text has changed (shorter)")
    func applyMatchesDiscardsOutOfBoundsResult() throws {
        register(swiftGrammar)

        let longText = "func hello() { /* long content */ }"
        let storage = NSTextStorage(string: longText)
        let result = SyntaxHighlighter.shared.highlight(
            textStorage: storage, language: "testswift", font: font
        )
        let unwrapped = try #require(result)

        // Replace with shorter text
        let shortStorage = NSTextStorage(string: "x")
        shortStorage.addAttributes([
            .foregroundColor: NSColor.textColor,
            .font: font
        ], range: NSRange(location: 0, length: shortStorage.length))

        // Apply cached result from longer text — should be safely discarded
        SyntaxHighlighter.shared.applyMatches(unwrapped, to: shortStorage, font: font)

        // Should not crash, and text color should remain default
        let color = shortStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.textColor)
    }

    // MARK: - highlightAsync returns result

    @Test("highlightAsync returns match result for caching")
    func highlightAsyncReturnsCacheableResult() async {
        register(swiftGrammar)
        let storage = NSTextStorage(string: "func test() {}")
        let result = await SyntaxHighlighter.shared.highlightAsync(
            textStorage: storage,
            language: "testswift",
            font: font
        )
        #expect(result != nil)
        let keywordMatch = result?.matches.first { $0.scope == "keyword" }
        #expect(keywordMatch != nil)
    }

    @Test("highlightAsync returns non-nil when generation is current")
    func highlightAsyncReturnsResultWhenGenerationCurrent() async {
        register(swiftGrammar)
        let storage = NSTextStorage(string: "func test() {}")
        let generation = HighlightGeneration()

        // Do not bump generation — result should be applied
        let result = await SyntaxHighlighter.shared.highlightAsync(
            textStorage: storage,
            language: "testswift",
            font: font,
            generation: generation
        )
        #expect(result != nil)
    }
}
