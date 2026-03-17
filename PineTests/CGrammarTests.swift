//
//  CGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct CGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("c.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    @Test func grammarMetadata() {
        #expect(grammar.name == "C")
        #expect(grammar.extensions.contains("c"))
        #expect(grammar.extensions.contains("h"))
    }

    @Test func hasExpectedScopes() {
        let scopes = Set(grammar.rules.map(\.scope))
        #expect(scopes.contains("comment"))
        #expect(scopes.contains("string"))
        #expect(scopes.contains("keyword"))
        #expect(scopes.contains("type"))
        #expect(scopes.contains("number"))
        #expect(scopes.contains("function"))
        #expect(scopes.contains("attribute"))
    }

    @Test func lineCommentRule() throws {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("//") }
        #expect(rule != nil)
        #expect(rule?.options?.contains("anchorsMatchLines") == true)
    }

    @Test func blockCommentRule() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("*") }
        #expect(rule != nil)
    }

    @Test func stringRule() {
        let rule = grammar.rules.first { $0.scope == "string" && $0.pattern.contains("\"") }
        #expect(rule != nil)
    }

    @Test func preprocessorRule() {
        let rule = grammar.rules.first { $0.scope == "attribute" && $0.pattern.contains("#") }
        #expect(rule != nil)
    }

    @Test func keywordsIncludeReturn() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("return") }
        #expect(rule != nil)
    }

    @Test func typesIncludeInt() {
        let rule = grammar.rules.first { $0.scope == "type" && $0.pattern.contains("int") }
        #expect(rule != nil)
    }

    @Test func numberRules() {
        let numberRules = grammar.rules.filter { $0.scope == "number" }
        #expect(numberRules.count >= 2)
    }
}
