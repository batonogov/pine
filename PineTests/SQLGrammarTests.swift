//
//  SQLGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct SQLGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("sql.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    @Test func grammarMetadata() {
        #expect(grammar.name == "SQL")
        #expect(grammar.extensions.contains("sql"))
    }

    @Test func hasExpectedScopes() {
        let scopes = Set(grammar.rules.map(\.scope))
        #expect(scopes.contains("comment"))
        #expect(scopes.contains("string"))
        #expect(scopes.contains("keyword"))
        #expect(scopes.contains("type"))
        #expect(scopes.contains("number"))
        #expect(scopes.contains("function"))
    }

    @Test func singleLineCommentRule() throws {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("--") }
        #expect(rule != nil)
        #expect(rule?.options?.contains("anchorsMatchLines") == true)
    }

    @Test func blockCommentRule() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("*") }
        #expect(rule != nil)
    }

    @Test func stringRule() {
        let rule = grammar.rules.first { $0.scope == "string" && $0.pattern.contains("'") }
        #expect(rule != nil)
    }

    @Test func keywordsIncludeSelect() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("SELECT") }
        #expect(rule != nil)
    }

    @Test func keywordsIncludeCRUD() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("INSERT") }
        #expect(rule != nil)
    }

    @Test func keywordsIncludeDDL() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("CREATE") }
        #expect(rule != nil)
    }

    @Test func typesIncludeInt() {
        let rule = grammar.rules.first { $0.scope == "type" && $0.pattern.contains("INT") }
        #expect(rule != nil)
    }

    @Test func typesIncludeVarchar() {
        let rule = grammar.rules.first { $0.scope == "type" && $0.pattern.contains("VARCHAR") }
        #expect(rule != nil)
    }

    @Test func numberRule() {
        let numberRules = grammar.rules.filter { $0.scope == "number" }
        #expect(numberRules.count >= 1)
    }

    @Test func functionRule() {
        let rule = grammar.rules.first { $0.scope == "function" && $0.pattern.contains("COUNT") }
        #expect(rule != nil)
    }
}
