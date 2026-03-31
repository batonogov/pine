//
//  HelmGrammarTests.swift
//  PineTests
//

import AppKit
import Testing
import Foundation
@testable import Pine

@MainActor
struct HelmGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("helm.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    // MARK: - Metadata

    @Test func grammarMetadata() {
        #expect(grammar.name == "Helm")
        #expect(grammar.extensions.contains("tpl"))
        #expect(grammar.lineComment == "#")
    }

    @Test func blockCommentMetadata() {
        #expect(grammar.blockComment?.open == "{{/*")
        #expect(grammar.blockComment?.close == "*/}}")
    }

    @Test func hasFilePatterns() {
        #expect(grammar.filePatterns != nil)
        #expect(grammar.filePatterns?.isEmpty == false)
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

    // MARK: - Template Delimiters

    @Test func templateDelimitersAreKeywords() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("\\{\\{") }
        #expect(rule != nil)
    }

    // MARK: - Go Template Keywords

    @Test func goTemplateKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let expected = ["if", "else", "end", "range", "with", "define",
                        "template", "block", "include", "required", "default"]
        for kw in expected {
            #expect(allPatterns.contains(kw), "Missing keyword: \(kw)")
        }
    }

    // MARK: - Helm Objects

    @Test func helmBuiltinObjects() {
        let typeRules = grammar.rules.filter { $0.scope == "type" }
        let allPatterns = typeRules.map(\.pattern).joined(separator: " ")

        let objects = ["Values", "Chart", "Release", "Files", "Capabilities", "Template"]
        for obj in objects {
            #expect(allPatterns.contains(obj), "Missing Helm object: \(obj)")
        }
    }

    // MARK: - Sprig Functions

    @Test func sprigFunctions() {
        let functionRules = grammar.rules.filter { $0.scope == "function" }
        let allPatterns = functionRules.map(\.pattern).joined(separator: " ")

        let funcs = ["toYaml", "toJson", "nindent", "indent", "trim",
                     "lower", "upper", "quote", "b64enc", "b64dec",
                     "sha256sum", "lookup", "list", "dict", "merge"]
        for fn in funcs {
            #expect(allPatterns.contains(fn), "Missing Sprig function: \(fn)")
        }
    }

    // MARK: - Variables

    @Test func variablesAreAttributes() {
        let rule = grammar.rules.first { $0.scope == "attribute" && $0.pattern.contains("\\$") }
        #expect(rule != nil)
    }

    // MARK: - Comments

    @Test func helmBlockComment() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("/\\*") }
        #expect(rule != nil)
    }

    @Test func hashComment() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("#") }
        #expect(rule != nil)
        #expect(rule?.options?.contains("anchorsMatchLines") == true)
    }

    // MARK: - Strings

    @Test func doubleQuotedStrings() {
        let rule = grammar.rules.first { $0.scope == "string" && $0.pattern.contains("\"") }
        #expect(rule != nil)
    }

    @Test func singleQuotedStrings() {
        let rule = grammar.rules.first { $0.scope == "string" && $0.pattern.contains("'") }
        #expect(rule != nil)
    }

    @Test func backtickStrings() {
        let rule = grammar.rules.first { $0.scope == "string" && $0.pattern.contains("`") }
        #expect(rule != nil)
    }

    // MARK: - All Regex Patterns Valid

    @Test func allPatternsAreValidRegex() {
        for rule in grammar.rules {
            var opts: NSRegularExpression.Options = []
            if let options = rule.options {
                for opt in options {
                    switch opt {
                    case "anchorsMatchLines": opts.insert(.anchorsMatchLines)
                    case "caseInsensitive": opts.insert(.caseInsensitive)
                    default: break
                    }
                }
            }
            let regex = try? NSRegularExpression(pattern: rule.pattern, options: opts)
            #expect(regex != nil, "Invalid regex: \(rule.pattern)")
        }
    }

    // MARK: - Highlighting Integration

    @Test func highlightsTemplateDelimiters() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "{{ .Values.name }}")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "tpl", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func highlightsYamlKeys() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "replicaCount: 3")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "tpl", font: font)

        let attrColor = try #require(highlighter.theme.color(for: "attribute"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == attrColor)
    }
}
