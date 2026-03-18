//
//  TOMLGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct TOMLGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("toml.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    @Test func grammarMetadata() {
        #expect(grammar.name == "TOML")
        #expect(grammar.extensions.contains("toml"))
    }

    @Test func fileNames() {
        #expect(grammar.fileNames?.contains("Cargo.toml") == true)
        #expect(grammar.fileNames?.contains("Pipfile") == true)
        #expect(grammar.fileNames?.contains("pyproject.toml") == true)
    }

    @Test func filePatterns() {
        #expect(grammar.filePatterns?.contains("*.toml") == true)
    }

    @Test func hasExpectedScopes() {
        let scopes = Set(grammar.rules.map(\.scope))
        #expect(scopes.contains("comment"))
        #expect(scopes.contains("string"))
        #expect(scopes.contains("keyword"))
        #expect(scopes.contains("attribute"))
        #expect(scopes.contains("number"))
    }

    @Test func tableHeaders() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("[") }
        #expect(rule != nil)
    }

    @Test func booleanKeywords() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("true") }
        #expect(rule != nil)
    }

    @Test func multilineStrings() {
        let rules = grammar.rules.filter { $0.scope == "string" }
        #expect(rules.count >= 3)
    }

    @Test func lineComment() {
        #expect(grammar.lineComment == "#")
    }
}
