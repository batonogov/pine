//
//  SyntaxHighlighter.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//
//  Facade — delegates to GrammarRegistry, CompiledGrammarCache, SyntaxHighlightEngine,
//  NestedHighlighter, SyntaxHighlightAsync, and MultilineMatchCache.
//  Public API is unchanged; all call sites compile without edits.
//

import AppKit

nonisolated final class SyntaxHighlighter: @unchecked Sendable {
    /// Singleton — one instance per application (grammars loaded once).
    static let shared = SyntaxHighlighter()

    // MARK: - Sub-components

    private let registry = GrammarRegistry()
    private let compiledCache = CompiledGrammarCache()
    private(set) var engine: SyntaxHighlightEngine
    private let nestedHighlighter: NestedHighlighter
    private let asyncHighlighter: SyntaxHighlightAsync
    private let multilineCache = MultilineMatchCache()

    /// Current theme (public for call sites that read theme colors).
    var theme: Theme { engine.theme }

    /// Maximum number of concurrent highlight operations.
    static let maxConcurrentHighlights = SyntaxHighlightAsync.maxConcurrentHighlights

    private init() {
        let engine = SyntaxHighlightEngine()
        self.engine = engine
        let nestedHighlighter = NestedHighlighter(
            engine: engine, registry: registry, cache: compiledCache
        )
        self.nestedHighlighter = nestedHighlighter
        asyncHighlighter = SyntaxHighlightAsync(
            engine: engine,
            registry: registry,
            cache: compiledCache,
            nestedHighlighter: nestedHighlighter,
            multilineCache: multilineCache
        )
        let grammars = registry.loadGrammarsFromBundle()
        compileGrammars(grammars)
    }

    // MARK: - Grammar Registration

    /// Registers a grammar directly (for tests via @testable import).
    func registerGrammar(_ grammar: Grammar) {
        registry.registerGrammar(grammar)
        let rules = GrammarCompiler.compileRules(for: grammar)
        compiledCache.setRules(rules, for: grammar.name)
    }

    #if DEBUG
    /// Removes a previously registered grammar (for test cleanup).
    func unregisterGrammar(_ grammar: Grammar) {
        registry.unregisterGrammar(grammar)
        compiledCache.removeRules(for: grammar.name)
    }

    /// Clears the multiline match cache (for test teardown).
    func clearMultilineCache() {
        multilineCache.removeAll()
    }
    #endif

    // MARK: - Line Comment Lookup

    func lineComment(forExtension ext: String) -> String? {
        registry.lineComment(forExtension: ext)
    }

    func lineComment(forFileName name: String) -> String? {
        registry.lineComment(forFileName: name)
    }

    // MARK: - Comment Style Lookup

    // Backward-compatible alias — call sites use SyntaxHighlighter.CommentStyle
    typealias CommentStyle = GrammarRegistry.CommentStyle

    func commentStyle(forExtension ext: String?, fileName: String?) -> CommentStyle? {
        registry.commentStyle(forExtension: ext, fileName: fileName)
    }

    // MARK: - Sync Highlight (full)

    @discardableResult
    func highlight(
        textStorage: NSTextStorage,
        language: String,
        fileName: String? = nil,
        font: NSFont
    ) -> HighlightMatchResult? {
        guard let grammar = registry.resolveGrammar(language: language, fileName: fileName),
              let rules = compiledCache.rules(for: grammar.name) else {
            engine.resetAttributes(textStorage: textStorage,
                            range: NSRange(location: 0, length: textStorage.length),
                            font: font)
            return nil
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let result = engine.computeMatches(
            text: textStorage.string,
            rules: rules,
            grammarName: grammar.name,
            repaintRange: fullRange,
            searchRange: fullRange,
            nestedHighlighter: nestedHighlighter
        )
        engine.applyMatches(result, to: textStorage, font: font)
        multilineCache.update(key: ObjectIdentifier(textStorage), fingerprint: result.multilineFingerprint)
        return result
    }

    // MARK: - Sync Highlight (viewport)

    func highlightVisibleRange(
        textStorage: NSTextStorage,
        visibleCharRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont
    ) {
        let totalLength = textStorage.length
        guard totalLength > 0 else { return }

        guard let grammar = registry.resolveGrammar(language: language, fileName: fileName),
              let rules = compiledCache.rules(for: grammar.name) else {
            engine.resetAttributes(textStorage: textStorage,
                            range: visibleCharRange,
                            font: font)
            return
        }

        let source = textStorage.string as NSString
        let expanded = engine.expandToContext(
            visibleCharRange, in: source, totalLength: totalLength, lines: engine.viewportContextLines
        )

        let result = engine.computeMatches(
            text: textStorage.string,
            rules: rules,
            grammarName: grammar.name,
            repaintRange: expanded,
            searchRange: expanded,
            fullFingerprintRange: NSRange(location: 0, length: totalLength),
            nestedHighlighter: nestedHighlighter
        )

        engine.applyMatches(result, to: textStorage, font: font)

        let key = ObjectIdentifier(textStorage)
        multilineCache.setIfNil(key: key, fingerprint: result.multilineFingerprint)
    }

    // MARK: - Sync Highlight (incremental)

    func highlightEdited(
        textStorage: NSTextStorage,
        editedRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont
    ) {
        let totalLength = textStorage.length
        guard totalLength > 0 else { return }

        guard let grammar = registry.resolveGrammar(language: language, fileName: fileName),
              let rules = compiledCache.rules(for: grammar.name) else {
            engine.resetAttributes(textStorage: textStorage,
                            range: NSRange(location: 0, length: totalLength),
                            font: font)
            return
        }

        let source = textStorage.string
        let fullRange = NSRange(location: 0, length: totalLength)

        let currentFingerprint = GrammarCompiler.collectMultilineFingerprint(
            rules: rules, source: source, searchRange: fullRange
        )

        let key = ObjectIdentifier(textStorage)
        let cachedFingerprint = multilineCache.fingerprint(for: key)

        if cachedFingerprint != currentFingerprint {
            let result = engine.computeMatches(
                text: source,
                rules: rules,
                grammarName: grammar.name,
                repaintRange: fullRange,
                searchRange: fullRange,
                nestedHighlighter: nestedHighlighter
            )
            engine.applyMatches(result, to: textStorage, font: font)
            multilineCache.update(key: key, fingerprint: result.multilineFingerprint)
            return
        }

        let repaintRange = engine.expandToContext(editedRange, in: source as NSString, totalLength: totalLength)
        let result = engine.computeMatches(
            text: source,
            rules: rules,
            grammarName: grammar.name,
            repaintRange: repaintRange,
            searchRange: repaintRange,
            nestedHighlighter: nestedHighlighter
        )
        engine.applyMatches(result, to: textStorage, font: font)
    }

    // MARK: - Cache Invalidation

    func invalidateCache(for textStorage: NSTextStorage) {
        multilineCache.remove(key: ObjectIdentifier(textStorage))
    }

    // MARK: - Comment & String Ranges

    func commentAndStringRanges(
        in text: String,
        language: String,
        fileName: String? = nil
    ) -> [NSRange] {
        guard let grammar = registry.resolveGrammar(language: language, fileName: fileName),
              let rules = compiledCache.rules(for: grammar.name) else {
            return []
        }
        return engine.commentAndStringRanges(in: text, rules: rules)
    }

    // MARK: - Grammar Tag Resolution

    func resolveGrammarByTag(_ tag: String) -> (Grammar, [CompiledRule])? {
        guard let grammar = registry.resolveGrammarByTag(tag),
              let rules = compiledCache.rules(for: grammar.name) else {
            return nil
        }
        return (grammar, rules)
    }

    // MARK: - Pure Computation (thread-safe)

    func computeMatches(
        text: String,
        language: String,
        fileName: String? = nil,
        repaintRange: NSRange,
        searchRange: NSRange
    ) -> HighlightMatchResult? {
        guard let grammar = registry.resolveGrammar(language: language, fileName: fileName),
              let rules = compiledCache.rules(for: grammar.name) else {
            return nil
        }
        return engine.computeMatches(
            text: text,
            rules: rules,
            grammarName: grammar.name,
            repaintRange: repaintRange,
            searchRange: searchRange,
            nestedHighlighter: nestedHighlighter
        )
    }

    // MARK: - Apply Matches (main thread only)

    func applyMatches(
        _ result: HighlightMatchResult,
        to textStorage: NSTextStorage,
        font: NSFont
    ) {
        engine.applyMatches(result, to: textStorage, font: font)
    }

    // MARK: - Async Entry Points

    @discardableResult
    func highlightAsync(
        textStorage: NSTextStorage,
        language: String,
        fileName: String? = nil,
        font: NSFont,
        generation: HighlightGeneration? = nil
    ) async -> HighlightMatchResult? {
        await asyncHighlighter.highlightAsync(
            textStorage: textStorage,
            language: language,
            fileName: fileName,
            font: font,
            generation: generation
        )
    }

    func highlightEditedAsync(
        textStorage: NSTextStorage,
        editedRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont,
        generation: HighlightGeneration? = nil
    ) async {
        await asyncHighlighter.highlightEditedAsync(
            textStorage: textStorage,
            editedRange: editedRange,
            language: language,
            fileName: fileName,
            font: font,
            generation: generation
        )
    }

    func highlightVisibleRangeAsync(
        textStorage: NSTextStorage,
        visibleCharRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont,
        generation: HighlightGeneration? = nil
    ) async {
        await asyncHighlighter.highlightVisibleRangeAsync(
            textStorage: textStorage,
            visibleCharRange: visibleCharRange,
            language: language,
            fileName: fileName,
            font: font,
            generation: generation
        )
    }

    // MARK: - Private

    /// Compiles rules for pre-loaded grammars without re-reading files from disk.
    private func compileGrammars(_ grammars: [Grammar]) {
        for grammar in grammars {
            let rules = GrammarCompiler.compileRules(for: grammar)
            compiledCache.setRules(rules, for: grammar.name)
        }
    }
}
