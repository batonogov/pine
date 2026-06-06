//
//  CompiledGrammarTests.swift
//  PineTests
//
//  Tests for CompiledGrammarCache and GrammarCompiler.
//

import Testing
import Foundation
@testable import Pine

@Suite("CompiledGrammarCache Tests")
struct CompiledGrammarCacheTests {

    @Test func cacheReturnsNilForUnknownGrammar() {
        let cache = CompiledGrammarCache()
        #expect(cache.rules(for: "UnknownGrammar") == nil)
    }

    @Test func cacheStoresAndRetrievesRules() {
        let cache = CompiledGrammarCache()
        let grammar = Grammar(
            name: "CacheTest",
            extensions: ["ctest"],
            rules: [GrammarRule(pattern: "\\bfunc\\b", scope: "keyword")]
        )
        let rules = GrammarCompiler.compileRules(for: grammar)

        cache.setRules(rules, for: "CacheTest")
        let retrieved = cache.rules(for: "CacheTest")

        #expect(retrieved != nil)
        #expect(retrieved?.count == 1)
        #expect(retrieved?.first?.scope == "keyword")
    }

    @Test func cacheRemovesRules() {
        let cache = CompiledGrammarCache()
        let grammar = Grammar(
            name: "RemoveTest",
            extensions: ["rtest"],
            rules: [GrammarRule(pattern: "\\bfunc\\b", scope: "keyword")]
        )
        let rules = GrammarCompiler.compileRules(for: grammar)

        cache.setRules(rules, for: "RemoveTest")
        #expect(cache.rules(for: "RemoveTest") != nil)

        cache.removeRules(for: "RemoveTest")
        #expect(cache.rules(for: "RemoveTest") == nil)
    }
}

@Suite("GrammarCompiler Tests")
struct GrammarCompilerTests {

    @Test func compileRules_producesCorrectRules() {
        let grammar = Grammar(
            name: "CompileTest",
            extensions: ["ctest"],
            rules: [
                GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: "\"[^\"]*\"", scope: "string")
            ]
        )

        let rules = GrammarCompiler.compileRules(for: grammar)

        #expect(rules.count == 3)
        #expect(rules[0].scope == "keyword")
        #expect(rules[0].isMultiline == false)
        #expect(rules[1].scope == "comment")
        #expect(rules[2].scope == "string")
    }

    @Test func compileRules_multilinePatternDetected() {
        let grammar = Grammar(
            name: "MultilineTest",
            extensions: ["mtest"],
            rules: [
                GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment"),
                GrammarRule(pattern: "\"[\\S\\s]*?\"", scope: "string"),
                GrammarRule(pattern: "normal", scope: "keyword", options: ["dotMatchesLineSeparators"])
            ]
        )

        let rules = GrammarCompiler.compileRules(for: grammar)

        // [\\s\\S] pattern → isMultiline
        #expect(rules[0].isMultiline == true)
        // [\\S\\s] pattern → isMultiline
        #expect(rules[1].isMultiline == true)
        // dotMatchesLineSeparators option → isMultiline
        #expect(rules[2].isMultiline == true)
    }

    @Test func compileRules_invalidRegexSkipped() {
        let grammar = Grammar(
            name: "InvalidRegex",
            extensions: ["iregex"],
            rules: [
                GrammarRule(pattern: "[", scope: "error"),
                GrammarRule(pattern: "\\bvalid\\b", scope: "keyword")
            ]
        )

        let rules = GrammarCompiler.compileRules(for: grammar)

        // Invalid regex should be skipped, only valid one kept
        #expect(rules.count == 1)
        #expect(rules[0].scope == "keyword")
    }

    @Test func compileRules_emptyGrammar() {
        let grammar = Grammar(
            name: "Empty",
            extensions: ["empty"],
            rules: []
        )

        let rules = GrammarCompiler.compileRules(for: grammar)
        #expect(rules.isEmpty)
    }

    @Test func compileRules_caseInsensitiveOption() {
        let grammar = Grammar(
            name: "CaseInsensitive",
            extensions: ["ci"],
            rules: [
                GrammarRule(pattern: "\\bFUNC\\b", scope: "keyword", options: ["caseInsensitive"])
            ]
        )

        let rules = GrammarCompiler.compileRules(for: grammar)
        #expect(rules.count == 1)

        // Verify caseInsensitive works
        let text = "func hello"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let match = rules[0].regex.firstMatch(in: text, range: range)
        #expect(match != nil, "Case insensitive regex should match 'func' against pattern 'FUNC'")
    }

    @Test func collectMultilineFingerprint_returnsLengths() {
        let grammar = Grammar(
            name: "Fingerprint",
            extensions: ["fp"],
            rules: [
                GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment"),
                GrammarRule(pattern: "\\bfunc\\b", scope: "keyword")
            ]
        )

        let rules = GrammarCompiler.compileRules(for: grammar)
        let text = "/* block */ func /* another */"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let fingerprint = GrammarCompiler.collectMultilineFingerprint(
            rules: rules, source: text, searchRange: fullRange
        )

        // Two block comments → 2 fingerprint entries
        #expect(fingerprint.count == 2)
        // Lengths should be the lengths of "/* block */" and "/* another */"
        #expect(fingerprint.contains(11)) // "/* block */"
        #expect(fingerprint.contains(13)) // "/* another */"
    }

    @Test func collectMultilineFingerprint_emptyText() {
        let grammar = Grammar(
            name: "FingerprintEmpty",
            extensions: ["fpe"],
            rules: [
                GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment")
            ]
        )

        let rules = GrammarCompiler.compileRules(for: grammar)
        let fingerprint = GrammarCompiler.collectMultilineFingerprint(
            rules: rules, source: "", searchRange: NSRange(location: 0, length: 0)
        )

        #expect(fingerprint.isEmpty)
    }
}
