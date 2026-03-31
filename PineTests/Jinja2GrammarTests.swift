//
//  Jinja2GrammarTests.swift
//  PineTests
//

import AppKit
import Testing
import Foundation
@testable import Pine

@MainActor
struct Jinja2GrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("jinja2.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    // MARK: - Metadata

    @Test func grammarMetadata() {
        #expect(grammar.name == "Jinja2")
        #expect(grammar.extensions.contains("j2"))
        #expect(grammar.extensions.contains("jinja2"))
        #expect(grammar.extensions.contains("jinja"))
        #expect(grammar.lineComment == "#")
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

    // MARK: - Comments

    @Test func jinjaBlockComment() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("{#") }
        #expect(rule != nil)
    }

    @Test func hashComment() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("#") && !$0.pattern.contains("{#") }
        #expect(rule != nil)
        #expect(rule?.options?.contains("anchorsMatchLines") == true)
    }

    // MARK: - Template Delimiters

    @Test func templateDelimiters() {
        let rule = grammar.rules.first { $0.scope == "keyword" && $0.pattern.contains("%") }
        #expect(rule != nil)
    }

    // MARK: - Jinja2 Keywords

    @Test func jinjaControlKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let expected = ["block", "endblock", "extends", "macro", "endmacro",
                        "if", "elif", "else", "endif", "for", "endfor",
                        "include", "import", "set", "endset", "with", "endwith",
                        "filter", "endfilter", "raw", "endraw"]
        for kw in expected {
            #expect(allPatterns.contains(kw), "Missing keyword: \(kw)")
        }
    }

    @Test func jinjaOperators() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let operators = ["not", "and", "or", "is", "in"]
        for op in operators {
            #expect(allPatterns.contains(op), "Missing operator: \(op)")
        }
    }

    // MARK: - Jinja2 Filters

    @Test func jinjaFilters() {
        let functionRules = grammar.rules.filter { $0.scope == "function" }
        let allPatterns = functionRules.map(\.pattern).joined(separator: " ")

        let filters = ["default", "join", "lower", "upper", "trim",
                       "replace", "sort", "length", "first", "last",
                       "map", "select", "reject", "tojson"]
        for fn in filters {
            #expect(allPatterns.contains(fn), "Missing filter: \(fn)")
        }
    }

    // MARK: - Ansible Variables

    @Test func ansibleVariables() {
        let typeRules = grammar.rules.filter { $0.scope == "type" }
        let allPatterns = typeRules.map(\.pattern).joined(separator: " ")

        let vars = ["ansible_", "inventory_hostname", "group_names", "hostvars"]
        for v in vars {
            #expect(allPatterns.contains(v), "Missing Ansible variable: \(v)")
        }
    }

    // MARK: - Ansible Keywords

    @Test func ansiblePlaybookKeywords() {
        let attrRules = grammar.rules.filter { $0.scope == "attribute" }
        let allPatterns = attrRules.map(\.pattern).joined(separator: " ")

        let keywords = ["when", "register", "become", "notify", "handlers",
                        "tasks", "vars", "roles", "gather_facts", "hosts",
                        "tags", "delegate_to"]
        for kw in keywords {
            #expect(allPatterns.contains(kw), "Missing Ansible keyword: \(kw)")
        }
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

    @Test func highlightsJinjaDelimiters() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "{% if enabled %}")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "j2", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func highlightsJinjaComment() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "{# this is a comment #}")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "j2", font: font)

        let commentColor = try #require(highlighter.theme.color(for: "comment"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == commentColor)
    }

    @Test func highlightsNumber() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "port: 8080")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "j2", font: font)

        let numberColor = try #require(highlighter.theme.color(for: "number"))
        let text = "port: 8080" as NSString
        let numIndex = text.range(of: "8080").location
        let color = textStorage.attribute(.foregroundColor, at: numIndex, effectiveRange: nil) as? NSColor
        #expect(color == numberColor)
    }
}
