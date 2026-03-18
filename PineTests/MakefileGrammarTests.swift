//
//  MakefileGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct MakefileGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("makefile.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    @Test func grammarMetadata() {
        #expect(grammar.name == "Makefile")
        #expect(grammar.extensions.contains("mk"))
        #expect(grammar.extensions.contains("mak"))
    }

    @Test func fileNames() {
        #expect(grammar.fileNames?.contains("Makefile") == true)
        #expect(grammar.fileNames?.contains("makefile") == true)
        #expect(grammar.fileNames?.contains("GNUmakefile") == true)
        #expect(grammar.fileNames?.contains("BSDmakefile") == true)
    }

    @Test func filePatterns() {
        #expect(grammar.filePatterns?.contains("Makefile.*") == true)
        #expect(grammar.filePatterns?.contains("*.mk") == true)
    }

    @Test func hasExpectedScopes() {
        let scopes = Set(grammar.rules.map(\.scope))
        #expect(scopes.contains("comment"))
        #expect(scopes.contains("string"))
        #expect(scopes.contains("keyword"))
        #expect(scopes.contains("attribute"))
        #expect(scopes.contains("function"))
        #expect(scopes.contains("number"))
    }

    @Test func directivesAreKeywords() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("ifeq") }
        #expect(rule != nil)
    }

    @Test func targetRule() {
        let rule = grammar.rules.first { $0.scope == "function" && $0.pattern.contains(":") }
        #expect(rule != nil)
    }

    @Test func variableAssignment() {
        let rule = grammar.rules.first { $0.scope == "attribute" && $0.pattern.contains("=") }
        #expect(rule != nil)
    }

    @Test func automaticVariables() {
        let rule = grammar.rules.first { $0.scope == "attribute" && $0.pattern.contains("$") }
        #expect(rule != nil)
    }

    @Test func lineComment() {
        #expect(grammar.lineComment == "#")
    }

    @Test func globMatchesFilePatterns() {
        #expect(SyntaxHighlighter.fileNameMatchesGlob("Makefile.am", pattern: "Makefile.*"))
        #expect(SyntaxHighlighter.fileNameMatchesGlob("rules.mk", pattern: "*.mk"))
        #expect(!SyntaxHighlighter.fileNameMatchesGlob("Makefile", pattern: "Makefile.*"))
    }
}
