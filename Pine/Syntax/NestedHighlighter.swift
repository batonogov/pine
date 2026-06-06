//
//  NestedHighlighter.swift
//  Pine
//
//  Extracted from SyntaxHighlighter.swift — nested fenced code block highlighting.
//

import AppKit

/// Handles nested highlighting for fenced code blocks in Markdown.
/// For each fenced block with a recognized language tag, runs the inner
/// grammar on the block content and returns additional matches.
nonisolated final class NestedHighlighter: @unchecked Sendable {
    private let registry: GrammarRegistry
    private let cache: CompiledGrammarCache

    /// Resolves a scope to its highlight info (priority + color).
    /// Returns nil if the scope has no theme color and should be skipped.
    private let scopeResolver: @Sendable (String) -> (priority: Int, color: NSColor)?

    /// Regex to match fenced code blocks with an optional language tag.
    /// Group 1 captures the language tag (e.g. "swift", "python").
    private static let fencedBlockRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "```(\\w+)?[^\\n]*\\n([\\s\\S]*?)```")
    }()

    /// Designated initializer — takes a scope resolver closure to decouple
    /// from SyntaxHighlightEngine.
    init(
        registry: GrammarRegistry,
        cache: CompiledGrammarCache,
        scopeResolver: @Sendable @escaping (String) -> (priority: Int, color: NSColor)?
    ) {
        self.registry = registry
        self.cache = cache
        self.scopeResolver = scopeResolver
    }

    /// Convenience initializer that derives the scope resolver from an engine instance.
    /// Provided for backward compatibility with existing call sites and tests.
    convenience init(
        engine: SyntaxHighlightEngine,
        registry: GrammarRegistry,
        cache: CompiledGrammarCache
    ) {
        self.init(
            registry: registry,
            cache: cache,
            scopeResolver: { scope in engine.shouldHighlight(scope: scope) }
        )
    }

    /// Computes nested highlight matches for fenced code blocks in markdown.
    func computeNestedFencedMatches(
        text: String,
        repaintRange: NSRange
    ) -> [HighlightMatch] {
        guard let regex = Self.fencedBlockRegex else { return [] }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        var nestedMatches: [HighlightMatch] = []

        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match else { return }

            let tagRange = match.range(at: 1)
            guard tagRange.location != NSNotFound, tagRange.length > 0 else { return }
            let tag = source.substring(with: tagRange)

            // Resolve grammar and compiled rules
            guard let grammar = registry.resolveGrammarByTag(tag),
                  let innerRules = cache.rules(for: grammar.name) else { return }

            let contentRange = match.range(at: 2)
            guard contentRange.location != NSNotFound, contentRange.length > 0 else { return }

            let clipped = NSIntersectionRange(contentRange, repaintRange)
            guard clipped.length > 0 else { return }

            let content = source.substring(with: contentRange)

            for rule in innerRules {
                guard let highlight = scopeResolver(rule.scope) else { continue }
                let priority = highlight.priority

                let contentNS = content as NSString
                let innerRange = NSRange(location: 0, length: contentNS.length)

                rule.regex.enumerateMatches(in: content, range: innerRange) { innerMatch, _, _ in
                    guard let innerMatchRange = innerMatch?.range else { return }

                    let absoluteRange = NSRange(
                        location: innerMatchRange.location + contentRange.location,
                        length: innerMatchRange.length
                    )

                    let absoluteClipped = NSIntersectionRange(absoluteRange, repaintRange)
                    guard absoluteClipped.length > 0 else { return }

                    nestedMatches.append(HighlightMatch(
                        range: absoluteClipped,
                        scope: rule.scope,
                        priority: max(priority, 96)
                    ))
                }
            }
        }

        return nestedMatches
    }
}
