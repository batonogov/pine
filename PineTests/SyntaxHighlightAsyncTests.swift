//
//  SyntaxHighlightAsyncTests.swift
//  PineTests
//
//  Tests for SyntaxHighlightAsync — async highlight orchestration.
//

import Testing
import AppKit
@testable import Pine

@Suite("SyntaxHighlightAsync Tests", .serialized)
@MainActor
struct SyntaxHighlightAsyncTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let testGrammar = Grammar(
        name: "AsyncTest",
        extensions: ["asynctest"],
        rules: [
            GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment"),
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
            GrammarRule(pattern: "\"[^\"]*\"", scope: "string")
        ]
    )

    /// Container for SyntaxHighlightAsync and its dependencies.
    private final class TestComponents: @unchecked Sendable {
        let engine: SyntaxHighlightEngine
        let registry: GrammarRegistry
        let cache: CompiledGrammarCache
        let nestedHighlighter: NestedHighlighter
        let multilineCache: MultilineMatchCache
        let asyncHighlighter: SyntaxHighlightAsync

        init() {
            let engine = SyntaxHighlightEngine()
            self.engine = engine
            let registry = GrammarRegistry()
            self.registry = registry
            let cache = CompiledGrammarCache()
            self.cache = cache
            let nestedHighlighter = NestedHighlighter(engine: engine, registry: registry, cache: cache)
            self.nestedHighlighter = nestedHighlighter
            let multilineCache = MultilineMatchCache()
            self.multilineCache = multilineCache
            asyncHighlighter = SyntaxHighlightAsync(
                engine: engine,
                registry: registry,
                cache: cache,
                nestedHighlighter: nestedHighlighter,
                multilineCache: multilineCache
            )
        }
    }

    private func makeComponents() -> TestComponents {
        TestComponents()
    }

    private func registerGrammar(
        _ grammar: Grammar,
        registry: GrammarRegistry,
        cache: CompiledGrammarCache
    ) {
        registry.registerGrammar(grammar)
        let rules = GrammarCompiler.compileRules(for: grammar)
        cache.setRules(rules, for: grammar.name)
    }

    private func foregroundColor(in storage: NSTextStorage, at position: Int) -> NSColor? {
        guard position < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor
    }

    // MARK: - highlightAsync

    @Test func highlightAsync_appliesKeywordColor() async {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let text = "func hello()"
        let storage = NSTextStorage(string: text)
        let keywordColor = components.engine.theme.color(for: "keyword")

        let result = await components.asyncHighlighter.highlightAsync(
            textStorage: storage,
            language: "asynctest",
            font: font
        )

        #expect(result != nil, "Should return a result for known language")
        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "Keyword should be colored after async highlight")
    }

    @Test func highlightAsync_returnsNilForUnknownLanguage() async {
        let components = makeComponents()

        let text = "some text"
        let storage = NSTextStorage(string: text)

        let result = await components.asyncHighlighter.highlightAsync(
            textStorage: storage,
            language: "nonexistent",
            font: font
        )

        #expect(result == nil, "Should return nil for unknown language")
    }

    @Test func highlightAsync_returnsNilForEmptyText() async {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let storage = NSTextStorage(string: "")

        let result = await components.asyncHighlighter.highlightAsync(
            textStorage: storage,
            language: "asynctest",
            font: font
        )

        #expect(result == nil, "Should return nil for empty text")
    }

    @Test func highlightAsync_updatesMultilineCache() async {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let text = "/* block\ncomment */ func hello()"
        let storage = NSTextStorage(string: text)
        let key = ObjectIdentifier(storage)

        await components.asyncHighlighter.highlightAsync(
            textStorage: storage,
            language: "asynctest",
            font: font
        )

        let fingerprint = components.multilineCache.fingerprint(for: key)
        #expect(fingerprint != nil, "Multiline cache should be populated after async highlight")
        #expect(fingerprint?.count == 1, "One multiline comment should produce one fingerprint entry")
    }

    @Test func highlightAsync_discardsWhenGenerationIsStale() async throws {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let lines = (0..<5_000).map { "func line\($0)()" }
        let bigText = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: bigText)
        let keywordColor = components.engine.theme.color(for: "keyword")

        let gen = HighlightGeneration()
        gen.increment()

        let task = Task {
            await components.asyncHighlighter.highlightAsync(
                textStorage: storage,
                language: "asynctest",
                font: font,
                generation: gen
            )
        }

        try await Task.sleep(for: .milliseconds(1))
        gen.increment() // stale

        let result = await task.value
        #expect(result == nil, "Should return nil when generation is stale")

        let deep = storage.length - 10
        #expect(foregroundColor(in: storage, at: deep) != keywordColor,
                "Colors should not be applied when generation is stale")
    }

    // MARK: - highlightEditedAsync

    @Test func highlightEditedAsync_appliesAfterEdit() async {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let text = "func hello() /* comment */"
        let storage = NSTextStorage(string: text)
        let keywordColor = components.engine.theme.color(for: "keyword")

        // Full highlight first
        await components.asyncHighlighter.highlightAsync(
            textStorage: storage,
            language: "asynctest",
            font: font
        )

        // Edit
        let editRange = NSRange(location: 0, length: 4)
        await components.asyncHighlighter.highlightEditedAsync(
            textStorage: storage,
            editedRange: editRange,
            language: "asynctest",
            font: font
        )

        #expect(foregroundColor(in: storage, at: 0) == keywordColor,
                "Keyword should be colored after edited async highlight")
    }

    @Test func highlightEditedAsync_doesFullRepaintWhenMultilineChanges() async {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let text = "/* block\ncomment */ func hello()"
        let storage = NSTextStorage(string: text)
        let commentColor = components.engine.theme.color(for: "comment")

        // Initial highlight to populate multiline cache
        await components.asyncHighlighter.highlightAsync(
            textStorage: storage,
            language: "asynctest",
            font: font
        )

        // Now modify the text (simulate multiline change)
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: "/* new\nblock */ "
        )

        let editRange = NSRange(location: 0, length: 4)
        await components.asyncHighlighter.highlightEditedAsync(
            textStorage: storage,
            editedRange: editRange,
            language: "asynctest",
            font: font
        )

        let commentPos = (storage.string as NSString).range(of: "/* new").location
        #expect(foregroundColor(in: storage, at: commentPos) == commentColor,
                "Comment should be colored after multiline structure change")
    }

    // MARK: - highlightVisibleRangeAsync

    @Test func highlightVisibleRangeAsync_appliesToVisibleRange() async {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let lines = (0..<200).map { "func line\($0)()" }
        let text = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: text)
        let keywordColor = components.engine.theme.color(for: "keyword")

        let rangeStart = lineOffset(50, in: text)
        let rangeEnd = lineOffset(60, in: text)
        let visibleRange = NSRange(location: rangeStart, length: rangeEnd - rangeStart)

        await components.asyncHighlighter.highlightVisibleRangeAsync(
            textStorage: storage,
            visibleCharRange: visibleRange,
            language: "asynctest",
            font: font
        )

        let line55Offset = lineOffset(55, in: text)
        #expect(foregroundColor(in: storage, at: line55Offset) == keywordColor,
                "Visible range should be highlighted")
    }

    @Test func highlightVisibleRangeAsync_populatesMultilineCacheIfEmpty() async {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let text = "/* block\ncomment */ func hello()"
        let storage = NSTextStorage(string: text)
        let key = ObjectIdentifier(storage)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        await components.asyncHighlighter.highlightVisibleRangeAsync(
            textStorage: storage,
            visibleCharRange: fullRange,
            language: "asynctest",
            font: font
        )

        let fingerprint = components.multilineCache.fingerprint(for: key)
        #expect(fingerprint != nil, "Multiline cache should be set on first viewport highlight")
    }

    @Test func highlightVisibleRangeAsync_doesNotOverwriteExistingMultilineCache() async {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let text = "/* block\ncomment */ func hello()"
        let storage = NSTextStorage(string: text)
        let key = ObjectIdentifier(storage)

        // Pre-populate cache with a different fingerprint
        components.multilineCache.update(key: key, fingerprint: [999])
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        await components.asyncHighlighter.highlightVisibleRangeAsync(
            textStorage: storage,
            visibleCharRange: fullRange,
            language: "asynctest",
            font: font
        )

        let fingerprint = components.multilineCache.fingerprint(for: key)
        #expect(fingerprint == [999],
                "setIfNil should not overwrite existing fingerprint")
    }

    // MARK: - Generation token integration

    @Test func highlightEditedAsync_discardsWhenGenerationIsStale() async throws {
        let components = makeComponents()
        registerGrammar(testGrammar, registry: components.registry, cache: components.cache)

        let lines = (0..<5_000).map { "func line\($0)()" }
        let bigText = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: bigText)

        // Initial highlight
        await components.asyncHighlighter.highlightAsync(
            textStorage: storage,
            language: "asynctest",
            font: font
        )

        let gen = HighlightGeneration()
        gen.increment()

        let task = Task {
            await components.asyncHighlighter.highlightEditedAsync(
                textStorage: storage,
                editedRange: NSRange(location: 0, length: 4),
                language: "asynctest",
                font: font,
                generation: gen
            )
        }

        try await Task.sleep(for: .milliseconds(1))
        gen.increment()

        await task.value
        // Should not crash — stale result discarded
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
