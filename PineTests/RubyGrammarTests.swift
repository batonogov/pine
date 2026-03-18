//
//  RubyGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct RubyGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("ruby.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    @Test func grammarMetadata() {
        #expect(grammar.name == "Ruby")
        #expect(grammar.extensions.contains("rb"))
        #expect(grammar.extensions.contains("gemspec"))
        #expect(grammar.extensions.contains("rake"))
    }

    @Test func fileNames() {
        #expect(grammar.fileNames?.contains("Gemfile") == true)
        #expect(grammar.fileNames?.contains("Rakefile") == true)
        #expect(grammar.fileNames?.contains("Guardfile") == true)
        #expect(grammar.fileNames?.contains("Vagrantfile") == true)
        #expect(grammar.fileNames?.contains("Podfile") == true)
        #expect(grammar.fileNames?.contains("Fastfile") == true)
    }

    @Test func noRedundantFilePatterns() {
        // *.gemspec and *.rake are covered by extensions, no filePatterns needed
        #expect(grammar.filePatterns == nil)
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

    @Test func keywordsIncludeDefAndClass() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("def") }
        #expect(rule != nil)
        let classRule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("class") }
        #expect(classRule != nil)
    }

    @Test func symbolsAreAttributes() {
        let rule = grammar.rules.first { $0.scope == "attribute" && $0.pattern.contains(":") }
        #expect(rule != nil)
    }

    @Test func instanceVariablesAreAttributes() {
        let rule = grammar.rules.first { $0.scope == "attribute" && $0.pattern.contains("@") }
        #expect(rule != nil)
    }

    @Test func lineComment() {
        #expect(grammar.lineComment == "#")
    }

    @Test func globMatchesGemspec() {
        #expect(SyntaxHighlighter.fileNameMatchesGlob("my_gem.gemspec", pattern: "*.gemspec"))
        #expect(SyntaxHighlighter.fileNameMatchesGlob("tasks.rake", pattern: "*.rake"))
    }
}
