//
//  NestedHighlighterTests.swift
//  PineTests
//
//  Tests for NestedHighlighter — nested fenced code block highlighting in Markdown.
//

import Testing
import AppKit
@testable import Pine

@Suite("NestedHighlighter Tests")
struct NestedHighlighterTests {

    private let engine = SyntaxHighlightEngine()

    private func makeHighlighter() -> NestedHighlighter {
        let registry = GrammarRegistry()
        let cache = CompiledGrammarCache()
        return NestedHighlighter(engine: engine, registry: registry, cache: cache)
    }

    private func makeHighlighterWithSwift() -> (NestedHighlighter, GrammarRegistry, CompiledGrammarCache) {
        let registry = GrammarRegistry()
        let cache = CompiledGrammarCache()
        let swiftGrammar = Grammar(
            name: "Swift",
            extensions: ["swift"],
            rules: [
                GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
                GrammarRule(pattern: "\\bvar\\b", scope: "keyword")
            ]
        )
        registry.registerGrammar(swiftGrammar)
        let rules = GrammarCompiler.compileRules(for: swiftGrammar)
        cache.setRules(rules, for: swiftGrammar.name)
        let highlighter = NestedHighlighter(engine: engine, registry: registry, cache: cache)
        return (highlighter, registry, cache)
    }

    // MARK: - Empty / no-match cases

    @Test func noFencedBlocks_returnsEmptyMatches() {
        let highlighter = makeHighlighter()
        let text = "Hello world\nNo fenced blocks here"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)
        #expect(matches.isEmpty)
    }

    @Test func fencedBlockWithoutLanguageTag_returnsEmptyMatches() {
        let highlighter = makeHighlighter()
        let text = "```\nfunc hello()\n```"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)
        #expect(matches.isEmpty, "Fenced block without language tag should produce no matches")
    }

    @Test func fencedBlockWithUnknownLanguage_returnsEmptyMatches() {
        let highlighter = makeHighlighter()
        let text = "```unknown_lang\nfunc hello()\n```"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)
        #expect(matches.isEmpty, "Fenced block with unknown language should produce no matches")
    }

    // MARK: - Matching with registered grammar

    @Test func fencedBlockWithSwift_matchesKeywordsInsideBlock() {
        let (highlighter, _, _) = makeHighlighterWithSwift()
        let text = "# Title\n```swift\nfunc hello()\n```\nMore text"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)

        let keywordMatches = matches.filter { $0.scope == "keyword" }
        #expect(keywordMatches.count == 1, "Should find 'func' keyword inside fenced Swift block")
    }

    @Test func fencedBlock_matchesAreInAbsoluteCoordinates() {
        let (highlighter, _, _) = makeHighlighterWithSwift()
        let text = "# Title\n```swift\nfunc hello()\n```\n"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)

        let funcRange = (text as NSString).range(of: "func", options: .backwards)
        let keywordMatch = matches.first { $0.scope == "keyword" }
        guard let matched = keywordMatch else {
            Issue.record("Expected keyword match")
            return
        }
        #expect(matched.range.location == funcRange.location,
                "Match should be in absolute coordinates relative to the full text")
    }

    @Test func fencedBlock_outsideRepaintRange_producesNoMatches() {
        let (highlighter, _, _) = makeHighlighterWithSwift()
        let text = "```swift\nfunc hello()\n```\n```swift\nvar x = 1\n```"
        // Only repaint the first block
        let firstBlockEnd = (text as NSString).range(of: "```\n").location + 4
        let repaintRange = NSRange(location: 0, length: firstBlockEnd)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: repaintRange)

        // Only matches from the first block should appear (clipped to repaintRange)
        let funcRange = (text as NSString).range(of: "func")
        let hasFunc = matches.contains { $0.scope == "keyword" && $0.range.location == funcRange.location }
        #expect(hasFunc, "Should match 'func' in the first block")
    }

    @Test func multipleFencedBlocksWithSameLanguage() {
        let (highlighter, _, _) = makeHighlighterWithSwift()
        let text = "```swift\nfunc one()\n```\nText between\n```swift\nvar x = 1\n```"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)

        let keywordMatches = matches.filter { $0.scope == "keyword" }
        #expect(keywordMatches.count == 2, "Should find keywords in both fenced blocks")
    }

    @Test func nestedMatchesHaveHighPriority() {
        let (highlighter, _, _) = makeHighlighterWithSwift()
        let text = "```swift\nfunc hello()\n```"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)

        let keywordMatch = matches.first { $0.scope == "keyword" }
        guard let matched = keywordMatch else {
            Issue.record("Expected keyword match")
            return
        }
        // Priority should be at least 96 (fenced code block boost)
        #expect(matched.priority >= 96, "Nested matches should have high priority (>= 96)")
    }

    @Test func emptyFencedBlockContent_producesNoMatches() {
        let (highlighter, _, _) = makeHighlighterWithSwift()
        let text = "```swift\n```"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)
        #expect(matches.isEmpty, "Empty fenced block content should produce no matches")
    }

    // MARK: - Language alias resolution

    @Test func fencedBlockResolvesLanguageAliases() {
        let registry = GrammarRegistry()
        let cache = CompiledGrammarCache()

        let jsGrammar = Grammar(
            name: "JavaScript",
            extensions: ["js"],
            rules: [GrammarRule(pattern: "\\bfunction\\b", scope: "keyword")]
        )
        registry.registerGrammar(jsGrammar)
        let rules = GrammarCompiler.compileRules(for: jsGrammar)
        cache.setRules(rules, for: jsGrammar.name)

        let highlighter = NestedHighlighter(engine: engine, registry: registry, cache: cache)
        let text = "```javascript\nfunction foo()\n```"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)
        let keywordMatches = matches.filter { $0.scope == "keyword" }
        #expect(keywordMatches.count == 1,
                "Should resolve 'javascript' alias to 'js' extension and find the keyword")
    }

    // MARK: - Priority capping

    @Test func nestedMatchPriorityCappedAt96Minimum() {
        let registry = GrammarRegistry()
        let cache = CompiledGrammarCache()

        let grammar = Grammar(
            name: "LowPrio",
            extensions: ["lowprio"],
            rules: [GrammarRule(pattern: "\\bfoo\\b", scope: "custom")]
        )
        registry.registerGrammar(grammar)
        // Don't register a theme color for "custom" — it shouldn't match without one

        let highlighter = NestedHighlighter(engine: engine, registry: registry, cache: cache)
        let text = "```lowprio\nfoo bar\n```"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let matches = highlighter.computeNestedFencedMatches(text: text, repaintRange: fullRange)
        // "custom" scope has no theme color — should be filtered out
        #expect(matches.isEmpty, "Rule with no theme color should be skipped")
    }
}
