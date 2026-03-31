//
//  CppGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct CppGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("cpp.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    @Test func grammarMetadata() {
        #expect(grammar.name == "C++")
        #expect(grammar.extensions.contains("cpp"))
        #expect(grammar.extensions.contains("cc"))
        #expect(grammar.extensions.contains("cxx"))
        #expect(grammar.extensions.contains("hpp"))
        #expect(grammar.extensions.contains("hxx"))
        #expect(grammar.extensions.contains("hh"))
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

    @Test func cppSpecificKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined()
        #expect(allPatterns.contains("class"))
        #expect(allPatterns.contains("template"))
        #expect(allPatterns.contains("namespace"))
        #expect(allPatterns.contains("virtual"))
        #expect(allPatterns.contains("override"))
        #expect(allPatterns.contains("nullptr"))
    }

    @Test func cppSpecificTypes() {
        let typeRules = grammar.rules.filter { $0.scope == "type" }
        let allPatterns = typeRules.map(\.pattern).joined()
        #expect(allPatterns.contains("string"))
        #expect(allPatterns.contains("vector"))
        #expect(allPatterns.contains("unique_ptr"))
        #expect(allPatterns.contains("shared_ptr"))
    }

    @Test func preprocessorRule() {
        let rule = grammar.rules.first { $0.scope == "attribute" && $0.pattern.contains("#") }
        #expect(rule != nil)
    }

    @Test func rawStringRule() {
        let rule = grammar.rules.first { $0.scope == "string" && $0.pattern.contains("R\"") }
        #expect(rule != nil)
    }

    @Test func lineCommentRule() throws {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("//") }
        #expect(rule != nil)
        #expect(rule?.options?.contains("anchorsMatchLines") == true)
    }

    @Test func numberRules() {
        let numberRules = grammar.rules.filter { $0.scope == "number" }
        #expect(numberRules.count >= 2)
    }
}
