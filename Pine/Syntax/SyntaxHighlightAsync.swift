//
//  SyntaxHighlightAsync.swift
//  Pine
//
//  Extracted from SyntaxHighlighter.swift — async highlight orchestration.
//

import AppKit

/// Thread-safe cache for multiline match fingerprints keyed by NSTextStorage identity.
nonisolated final class MultilineMatchCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [ObjectIdentifier: [Int]] = [:]

    func fingerprint(for key: ObjectIdentifier) -> [Int]? {
        lock.withLock { cache[key] }
    }

    func update(key: ObjectIdentifier, fingerprint: [Int]) {
        lock.withLock { cache[key] = fingerprint }
    }

    func setIfNil(key: ObjectIdentifier, fingerprint: [Int]) {
        lock.withLock {
            if cache[key] == nil {
                cache[key] = fingerprint
            }
        }
    }

    func remove(key: ObjectIdentifier) {
        lock.withLock { cache.removeValue(forKey: key) }
    }

    func removeAll() {
        lock.withLock { cache.removeAll() }
    }
}

/// Async syntax highlight operations with generation token validation.
/// Offloads regex computation to a background OperationQueue and applies
/// results on the main thread.
nonisolated final class SyntaxHighlightAsync: @unchecked Sendable {
    /// Maximum number of concurrent highlight operations.
    static let maxConcurrentHighlights = 4

    /// Concurrent queue for regex computation across multiple tabs.
    private let highlightQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.pine.syntax-highlight"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = SyntaxHighlightAsync.maxConcurrentHighlights
        return queue
    }()

    private let engine: SyntaxHighlightEngine
    private let registry: GrammarRegistry
    private let cache: CompiledGrammarCache
    private let nestedHighlighter: NestedHighlighter
    private let multilineCache: MultilineMatchCache

    /// `@unchecked Sendable` container for non-Sendable captures needed to
    /// hop `applyMatches`/`resetAttributes` to the main thread.
    ///
    /// `NSTextStorage` and `NSFont` are AppKit types without `Sendable`
    /// conformance. Safety invariants:
    /// - `textStorage` is exclusively mutated on the main thread.
    /// - `NSFont` is immutable.
    /// - `SyntaxHighlightEngine` is already `@unchecked Sendable`.
    /// - The box is stack-local and never escapes beyond a single synchronous
    ///   main-thread call.
    private struct MainHopBox: @unchecked Sendable {
        let textStorage: NSTextStorage
        let font: NSFont
        let engine: SyntaxHighlightEngine
    }

    init(
        engine: SyntaxHighlightEngine,
        registry: GrammarRegistry,
        cache: CompiledGrammarCache,
        nestedHighlighter: NestedHighlighter,
        multilineCache: MultilineMatchCache
    ) {
        self.engine = engine
        self.registry = registry
        self.cache = cache
        self.nestedHighlighter = nestedHighlighter
        self.multilineCache = multilineCache
    }

    // MARK: - Async Full Highlight

    /// Async full highlight: computes on background queue, applies on main thread.
    /// Returns the applied match result (for caching on tab switch), or nil if generation was stale.
    @discardableResult
    func highlightAsync(
        textStorage: NSTextStorage,
        language: String,
        fileName: String? = nil,
        font: NSFont,
        generation: HighlightGeneration? = nil
    ) async -> HighlightMatchResult? {
        let text = String(textStorage.string)
        let textLength = (text as NSString).length
        guard textLength > 0 else { return nil }

        let fullRange = NSRange(location: 0, length: textLength)
        let gen = generation?.current ?? 0

        let result: HighlightMatchResult? = await withCheckedContinuation { continuation in
            highlightQueue.addOperation {
                let r = self.computeMatches(
                    text: text,
                    language: language,
                    fileName: fileName,
                    repaintRange: fullRange,
                    searchRange: fullRange
                )
                continuation.resume(returning: r)
            }
        }

        if let generation, generation.current != gen { return nil }

        if let result {
            self.applyMatchesOnMain(result, to: textStorage, font: font)
            multilineCache.update(key: ObjectIdentifier(textStorage), fingerprint: result.multilineFingerprint)
            return result
        } else {
            self.resetAttributesOnMain(textStorage: textStorage, range: fullRange, font: font)
            return nil
        }
    }

    // MARK: - Async Incremental Highlight

    /// Async incremental highlight after an edit.
    func highlightEditedAsync(
        textStorage: NSTextStorage,
        editedRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont,
        generation: HighlightGeneration? = nil
    ) async {
        let text = String(textStorage.string)
        let textLength = (text as NSString).length
        guard textLength > 0 else { return }

        let fullRange = NSRange(location: 0, length: textLength)
        let key = ObjectIdentifier(textStorage)
        let cachedFingerprint = multilineCache.fingerprint(for: key)
        let gen = generation?.current ?? 0

        let bgResult: (HighlightMatchResult?, Bool) = await withCheckedContinuation { continuation in
            highlightQueue.addOperation {
                let rules = self.resolveRules(language: language, fileName: fileName)
                let currentFingerprint = GrammarCompiler.collectMultilineFingerprint(
                    rules: rules, source: text, searchRange: fullRange
                )

                let needsFullRepaint = (cachedFingerprint != currentFingerprint)

                let repaintRange: NSRange
                let searchRange: NSRange
                if needsFullRepaint {
                    repaintRange = fullRange
                    searchRange = fullRange
                } else {
                    let expanded = self.engine.expandToContext(
                        editedRange, in: text as NSString, totalLength: textLength
                    )
                    repaintRange = expanded
                    searchRange = expanded
                }

                let result = self.computeMatches(
                    text: text,
                    language: language,
                    fileName: fileName,
                    repaintRange: repaintRange,
                    searchRange: searchRange
                )

                continuation.resume(returning: (result, needsFullRepaint))
            }
        }

        if let generation, generation.current != gen { return }

        let (result, _) = bgResult
        if let result {
            self.applyMatchesOnMain(result, to: textStorage, font: font)
            multilineCache.update(key: key, fingerprint: result.multilineFingerprint)
        } else {
            self.resetAttributesOnMain(textStorage: textStorage, range: fullRange, font: font)
        }
    }

    // MARK: - Async Viewport Highlight

    /// Async viewport-based highlight.
    func highlightVisibleRangeAsync(
        textStorage: NSTextStorage,
        visibleCharRange: NSRange,
        language: String,
        fileName: String? = nil,
        font: NSFont,
        generation: HighlightGeneration? = nil
    ) async {
        let text = String(textStorage.string)
        let textLength = (text as NSString).length
        guard textLength > 0 else { return }

        let key = ObjectIdentifier(textStorage)
        let gen = generation?.current ?? 0

        let result: HighlightMatchResult? = await withCheckedContinuation { continuation in
            highlightQueue.addOperation {
                let source = text as NSString
                let expanded = self.engine.expandToContext(
                    visibleCharRange, in: source,
                    totalLength: textLength, lines: self.engine.viewportContextLines
                )

                let r = self.computeMatches(
                    text: text,
                    language: language,
                    fileName: fileName,
                    repaintRange: expanded,
                    searchRange: expanded
                )
                continuation.resume(returning: r)
            }
        }

        if let generation, generation.current != gen { return }

        if let result {
            self.applyMatchesOnMain(result, to: textStorage, font: font)
            multilineCache.setIfNil(key: key, fingerprint: result.multilineFingerprint)
        } else {
            self.resetAttributesOnMain(textStorage: textStorage, range: visibleCharRange, font: font)
        }
    }

    // MARK: - Private

    private func computeMatches(
        text: String,
        language: String,
        fileName: String?,
        repaintRange: NSRange,
        searchRange: NSRange
    ) -> HighlightMatchResult? {
        guard let grammar = registry.resolveGrammar(language: language, fileName: fileName),
              let rules = cache.rules(for: grammar.name) else {
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

    private func resolveRules(language: String, fileName: String?) -> [CompiledRule] {
        guard let grammar = registry.resolveGrammar(language: language, fileName: fileName),
              let rules = cache.rules(for: grammar.name) else {
            return []
        }
        return rules
    }

    /// Hops to the main thread (synchronously) to call `applyMatches`.
    ///
    /// Used by the async entry points. `NSTextStorage` and `NSFont` are not
    /// `Sendable`, so we avoid `MainActor.run { }` (which requires Sendable
    /// captures under strict concurrency) and instead route through
    /// `DispatchQueue.main.sync` — classic Apple pattern for bridging
    /// background GCD work to the main-thread UI.
    ///
    /// Safe to call from any non-main thread; falls through directly when
    /// already on main to avoid a redundant hop.
    private func applyMatchesOnMain(
        _ result: HighlightMatchResult,
        to textStorage: NSTextStorage,
        font: NSFont
    ) {
        let box = MainHopBox(textStorage: textStorage, font: font, engine: engine)
        if Thread.isMainThread {
            box.engine.applyMatches(result, to: box.textStorage, font: box.font)
        } else {
            DispatchQueue.main.sync {
                box.engine.applyMatches(result, to: box.textStorage, font: box.font)
            }
        }
    }

    /// Hops to the main thread (synchronously) to call `resetAttributes`.
    /// See `applyMatchesOnMain` for rationale.
    private func resetAttributesOnMain(
        textStorage: NSTextStorage,
        range: NSRange,
        font: NSFont
    ) {
        let box = MainHopBox(textStorage: textStorage, font: font, engine: engine)
        if Thread.isMainThread {
            box.engine.resetAttributes(textStorage: box.textStorage, range: range, font: box.font)
        } else {
            DispatchQueue.main.sync {
                box.engine.resetAttributes(
                    textStorage: box.textStorage, range: range, font: box.font
                )
            }
        }
    }
}
