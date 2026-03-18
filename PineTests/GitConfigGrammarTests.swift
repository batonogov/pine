//
//  GitConfigGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct GitConfigGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("gitconfig.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    @Test func grammarMetadata() {
        #expect(grammar.name == "Git Config")
        #expect(grammar.extensions.contains("gitignore"))
        #expect(grammar.extensions.contains("gitattributes"))
        #expect(grammar.extensions.contains("gitmodules"))
        #expect(grammar.extensions.contains("gitconfig"))
    }

    @Test func fileNames() {
        #expect(grammar.fileNames?.contains(".gitignore") == true)
        #expect(grammar.fileNames?.contains(".gitattributes") == true)
        #expect(grammar.fileNames?.contains(".gitmodules") == true)
        #expect(grammar.fileNames?.contains(".gitconfig") == true)
    }

    @Test func filePatterns() {
        #expect(grammar.filePatterns?.contains(".gitignore_global") == true)
    }

    @Test func hasExpectedScopes() {
        let scopes = Set(grammar.rules.map(\.scope))
        #expect(scopes.contains("comment"))
        #expect(scopes.contains("string"))
        #expect(scopes.contains("keyword"))
        #expect(scopes.contains("attribute"))
    }

    @Test func sectionHeaders() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("[") }
        #expect(rule != nil)
    }

    @Test func negationPatterns() {
        let rule = grammar.rules.first { $0.scope == "type" && $0.pattern.contains("!") }
        #expect(rule != nil)
    }

    @Test func lineComment() {
        #expect(grammar.lineComment == "#")
    }
}
