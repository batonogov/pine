//
//  GrammarModelTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct GrammarModelTests {

    // MARK: - Grammar Decoding

    @Test func decodesBasicGrammar() throws {
        let json = """
        {
            "name": "TestLang",
            "extensions": ["tl", "test"],
            "rules": [
                {"pattern": "\\\\bfunc\\\\b", "scope": "keyword"},
                {"pattern": "\\\\/\\\\/.*$", "scope": "comment", "options": ["anchorsMatchLines"]}
            ]
        }
        """
        let data = Data(json.utf8)
        let grammar = try JSONDecoder().decode(Grammar.self, from: data)

        #expect(grammar.name == "TestLang")
        #expect(grammar.extensions == ["tl", "test"])
        #expect(grammar.rules.count == 2)
        #expect(grammar.rules[0].scope == "keyword")
        #expect(grammar.rules[1].scope == "comment")
        #expect(grammar.rules[1].options == ["anchorsMatchLines"])
        #expect(grammar.fileNames == nil)
    }

    @Test func decodesGrammarWithFileNames() throws {
        let json = """
        {
            "name": "Dockerfile",
            "extensions": [],
            "rules": [],
            "fileNames": ["Dockerfile", "Containerfile"]
        }
        """
        let data = Data(json.utf8)
        let grammar = try JSONDecoder().decode(Grammar.self, from: data)

        #expect(grammar.fileNames == ["Dockerfile", "Containerfile"])
    }

    @Test func decodesGrammarWithFilePatterns() throws {
        let json = """
        {
            "name": "Dockerfile",
            "extensions": [],
            "rules": [{"pattern": "FROM", "scope": "keyword"}],
            "fileNames": ["Dockerfile"],
            "filePatterns": ["Dockerfile.*", "*.Dockerfile"]
        }
        """
        let data = Data(json.utf8)
        let grammar = try JSONDecoder().decode(Grammar.self, from: data)

        #expect(grammar.filePatterns == ["Dockerfile.*", "*.Dockerfile"])
    }

    @Test func decodesGrammarWithoutFilePatterns() throws {
        let json = """
        {
            "name": "Go",
            "extensions": ["go"],
            "rules": [{"pattern": "func", "scope": "keyword"}]
        }
        """
        let data = Data(json.utf8)
        let grammar = try JSONDecoder().decode(Grammar.self, from: data)

        #expect(grammar.filePatterns == nil)
    }

    @Test func decodesGrammarRule() throws {
        let json = """
        {"pattern": "test", "scope": "string"}
        """
        let data = Data(json.utf8)
        let rule = try JSONDecoder().decode(GrammarRule.self, from: data)

        #expect(rule.pattern == "test")
        #expect(rule.scope == "string")
        #expect(rule.options == nil)
    }

    @Test func decodesGrammarRuleWithOptions() throws {
        let json = """
        {"pattern": "test", "scope": "comment", "options": ["anchorsMatchLines", "caseInsensitive"]}
        """
        let data = Data(json.utf8)
        let rule = try JSONDecoder().decode(GrammarRule.self, from: data)

        #expect(rule.options?.count == 2)
        #expect(rule.options?.contains("anchorsMatchLines") == true)
        #expect(rule.options?.contains("caseInsensitive") == true)
    }

    // MARK: - Theme

    @Test func themeReturnsColorsForKnownScopes() {
        let theme = Theme.default
        #expect(theme.color(for: "comment") != nil)
        #expect(theme.color(for: "string") != nil)
        #expect(theme.color(for: "keyword") != nil)
        #expect(theme.color(for: "number") != nil)
        #expect(theme.color(for: "type") != nil)
        #expect(theme.color(for: "attribute") != nil)
        #expect(theme.color(for: "function") != nil)
    }

    @Test func themeReturnsNilForUnknownScope() {
        let theme = Theme.default
        #expect(theme.color(for: "nonexistent") == nil)
    }

    // MARK: - File Pattern Matching

    @Test func highlighterResolvesExactFileName() {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestExact",
            extensions: [],
            rules: [GrammarRule(pattern: "test", scope: "keyword")],
            fileNames: ["Vagrantfile"],
            lineComment: "#"
        )
        highlighter.registerGrammar(grammar)
        // lineComment lookup verifies the grammar was resolved by exact name
        #expect(highlighter.lineComment(forFileName: "Vagrantfile") == "#")
    }

    @Test func highlighterResolvesFilePattern() {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestPattern",
            extensions: [],
            rules: [GrammarRule(pattern: "test", scope: "keyword")],
            filePatterns: ["TestPattern.*", "*.testpat"],
            lineComment: "//"
        )
        highlighter.registerGrammar(grammar)
        // Pattern should match via lineComment(forFileName:) fallback
        #expect(highlighter.lineComment(forFileName: "TestPattern.prod") == "//")
        #expect(highlighter.lineComment(forFileName: "app.testpat") == "//")
        // Non-matching names return nil
        #expect(highlighter.lineComment(forFileName: "other.txt") == nil)
    }

    @Test func highlighterPrioritizesExtensionOverPattern() {
        let highlighter = SyntaxHighlighter.shared
        // Register grammar with both extension and pattern
        let grammar = Grammar(
            name: "TestPriority",
            extensions: ["tpri"],
            rules: [GrammarRule(pattern: "x", scope: "keyword")],
            filePatterns: ["*.tpri"],
            lineComment: "//"
        )
        highlighter.registerGrammar(grammar)
        #expect(highlighter.lineComment(forExtension: "tpri") == "//")
    }

    // MARK: - Bundled Grammar Files

    @Test func bundledGrammarFilesAreValidJSON() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let files = try FileManager.default.contentsOfDirectory(
            at: grammarDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        #expect(!files.isEmpty, "Should find grammar JSON files")

        let decoder = JSONDecoder()
        for file in files {
            let data = try Data(contentsOf: file)
            let grammar = try decoder.decode(Grammar.self, from: data)
            #expect(!grammar.name.isEmpty, "Grammar \(file.lastPathComponent) should have a name")
            #expect(!grammar.rules.isEmpty, "Grammar \(grammar.name) should have rules")
        }
    }
}
