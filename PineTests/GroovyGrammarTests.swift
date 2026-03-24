//
//  GroovyGrammarTests.swift
//  PineTests
//

import AppKit
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

    // MARK: - Metadata

    @Test func grammarMetadata() {
        #expect(grammar.name == "Groovy")
        #expect(grammar.extensions.contains("groovy"))
        #expect(grammar.extensions.contains("gradle"))
        #expect(grammar.lineComment == "//")
    }

    @Test func jenkinsfileIsRegistered() {
        #expect(grammar.fileNames?.contains("Jenkinsfile") == true)
    }

    @Test func blockCommentMetadata() {
        #expect(grammar.blockComment?.open == "/*")
        #expect(grammar.blockComment?.close == "*/")
    }

    @Test func hasExpectedScopes() {
        let scopes = Set(grammar.rules.map(\.scope))
        #expect(scopes.contains("comment"))
        #expect(scopes.contains("string"))
        #expect(scopes.contains("keyword"))
        #expect(scopes.contains("type"))
        #expect(scopes.contains("number"))
        #expect(scopes.contains("attribute"))
        #expect(scopes.contains("function"))
    }

    // MARK: - Core Groovy Keywords

    @Test func coreKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let core = ["def", "class", "interface", "import", "return",
                     "if", "else", "for", "while", "try", "catch", "finally"]
        for kw in core {
            #expect(allPatterns.contains(kw), "Missing core keyword: \(kw)")
        }
    }

    // MARK: - Jenkins DSL Keywords

    @Test func jenkinsPipelineKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let jenkins = ["pipeline", "agent", "stages", "stage", "steps",
                       "post", "environment", "options", "parameters",
                       "triggers", "tools", "input", "when", "parallel",
                       "script", "node"]
        for kw in jenkins {
            #expect(allPatterns.contains(kw), "Missing Jenkins keyword: \(kw)")
        }
    }

    @Test func jenkinsStepKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let steps = ["sh", "bat", "echo", "checkout", "dir",
                     "timeout", "retry", "sleep", "stash", "unstash",
                     "archiveArtifacts", "junit", "cleanWs",
                     "withCredentials", "withEnv"]
        for step in steps {
            #expect(allPatterns.contains(step), "Missing Jenkins step: \(step)")
        }
    }

    @Test func jenkinsPostConditions() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let conditions = ["always", "success", "failure", "unstable",
                          "aborted", "changed", "fixed", "regression", "cleanup"]
        for cond in conditions {
            #expect(allPatterns.contains(cond), "Missing post condition: \(cond)")
        }
    }

    // MARK: - All Regex Valid

    @Test func allPatternsAreValidRegex() {
        for rule in grammar.rules {
            var opts: NSRegularExpression.Options = []
            if let options = rule.options {
                for opt in options {
                    switch opt {
                    case "anchorsMatchLines": opts.insert(.anchorsMatchLines)
                    default: break
                    }
                }
            }
            let regex = try? NSRegularExpression(pattern: rule.pattern, options: opts)
            #expect(regex != nil, "Invalid regex: \(rule.pattern)")
        }
    }

    // MARK: - Highlighting Integration

    @Test func highlightsPipelineKeyword() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "pipeline {\n  agent any\n}")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "groovy", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func highlightsStringInterpolation() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "\"Hello ${name}\"")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "groovy", font: font)

        let stringColor = try #require(highlighter.theme.color(for: "string"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == stringColor)
    }
}
