//
//  INIGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct INIGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("ini.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    @Test func grammarMetadata() {
        #expect(grammar.name == "INI")
        #expect(grammar.extensions.contains("ini"))
        #expect(grammar.extensions.contains("cfg"))
        #expect(grammar.extensions.contains("conf"))
        #expect(grammar.extensions.contains("properties"))
    }

    @Test func fileNames() {
        #expect(grammar.fileNames?.contains(".editorconfig") == true)
    }

    @Test func hasExpectedScopes() {
        let scopes = Set(grammar.rules.map(\.scope))
        #expect(scopes.contains("comment"))
        #expect(scopes.contains("string"))
        #expect(scopes.contains("keyword"))
        #expect(scopes.contains("attribute"))
        #expect(scopes.contains("number"))
    }

    @Test func sectionHeaders() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("[") }
        #expect(rule != nil)
    }

    @Test func semicolonComments() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains(";") }
        #expect(rule != nil)
    }

    @Test func lineComment() {
        #expect(grammar.lineComment == "#")
    }
}
