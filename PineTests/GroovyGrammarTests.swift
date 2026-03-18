//
//  GroovyGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct GroovyGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("groovy.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    @Test func grammarMetadata() {
        #expect(grammar.name == "Groovy")
        #expect(grammar.extensions.contains("groovy"))
        #expect(grammar.extensions.contains("gradle"))
    }

    @Test func fileNames() {
        #expect(grammar.fileNames?.contains("Jenkinsfile") == true)
    }

    @Test func filePatterns() {
        #expect(grammar.filePatterns?.contains("Jenkinsfile.*") == true)
        #expect(grammar.filePatterns?.contains("*.Jenkinsfile") == true)
    }

    @Test func hasExpectedScopes() {
        let scopes = Set(grammar.rules.map(\.scope))
        #expect(scopes.contains("comment"))
        #expect(scopes.contains("string"))
        #expect(scopes.contains("keyword"))
        #expect(scopes.contains("attribute"))
        #expect(scopes.contains("type"))
        #expect(scopes.contains("function"))
        #expect(scopes.contains("number"))
    }

    @Test func jenkinsKeywords() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("pipeline") }
        #expect(rule != nil)
    }

    @Test func blockCommentRule() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("*") }
        #expect(rule != nil)
    }

    @Test func lineComment() {
        #expect(grammar.lineComment == "//")
    }

    @Test func globMatchesJenkinsfile() {
        #expect(SyntaxHighlighter.fileNameMatchesGlob("Jenkinsfile.prod", pattern: "Jenkinsfile.*"))
        #expect(SyntaxHighlighter.fileNameMatchesGlob("ci.Jenkinsfile", pattern: "*.Jenkinsfile"))
    }
}
