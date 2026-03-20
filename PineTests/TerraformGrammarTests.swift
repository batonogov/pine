//
//  TerraformGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct TerraformGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("terraform.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    // MARK: - Metadata

    @Test func grammarMetadata() {
        #expect(grammar.name == "Terraform")
        #expect(grammar.extensions.contains("tf"))
        #expect(grammar.extensions.contains("tfvars"))
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

    // MARK: - Comments

    @Test func hashComment() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("#") }
        #expect(rule != nil)
        #expect(rule?.options?.contains("anchorsMatchLines") == true)
    }

    @Test func slashSlashComment() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("//") }
        #expect(rule != nil)
        #expect(rule?.options?.contains("anchorsMatchLines") == true)
    }

    @Test func blockComment() {
        let rule = grammar.rules.first { $0.scope == "comment" && $0.pattern.contains("*") }
        #expect(rule != nil)
    }

    // MARK: - Strings

    @Test func heredocString() {
        let rule = grammar.rules.first { $0.scope == "string" && $0.pattern.contains("<<") }
        #expect(rule != nil)
    }

    @Test func doubleQuotedString() {
        let rule = grammar.rules.first { $0.scope == "string" && $0.pattern.contains("\"") }
        #expect(rule != nil)
    }

    // MARK: - Interpolation

    @Test func interpolationExpression() {
        let rule = grammar.rules.first { $0.scope == "attribute" && $0.pattern.contains("$") }
        #expect(rule != nil)
    }

    // MARK: - Block types

    @Test func blockTypeKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let blockTypes = ["resource", "data", "module", "provider", "terraform",
                          "variable", "output", "locals", "moved", "import", "check"]
        for blockType in blockTypes {
            #expect(allPatterns.contains(blockType), "Missing block type: \(blockType)")
        }
    }

    // MARK: - Meta-arguments

    @Test func metaArguments() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let metaArgs = ["for_each", "depends_on", "lifecycle",
                        "provisioner", "connection"]
        for arg in metaArgs {
            #expect(allPatterns.contains(arg), "Missing meta-argument: \(arg)")
        }
    }

    // MARK: - Lifecycle arguments

    @Test func lifecycleArguments() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let lifecycleArgs = ["create_before_destroy", "prevent_destroy",
                             "ignore_changes", "replace_triggered_by"]
        for arg in lifecycleArgs {
            #expect(allPatterns.contains(arg), "Missing lifecycle argument: \(arg)")
        }
    }

    // MARK: - Special references

    @Test func specialReferences() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        #expect(allPatterns.contains("self"))
        #expect(allPatterns.contains("each"))
        #expect(allPatterns.contains("count\\.index"))
        #expect(allPatterns.contains("path\\.module"))
        #expect(allPatterns.contains("path\\.root"))
        #expect(allPatterns.contains("path\\.cwd"))
        #expect(allPatterns.contains("terraform\\.workspace"))
    }

    // MARK: - Built-in functions

    @Test func builtInFunctions() {
        let functionRules = grammar.rules.filter { $0.scope == "function" }
        let allPatterns = functionRules.map(\.pattern).joined(separator: " ")

        let builtins = ["file", "templatefile", "lookup", "merge", "concat",
                        "toset", "try", "can", "coalesce", "flatten",
                        "tolist", "tomap", "tonumber", "tostring",
                        "format", "join", "split", "replace", "length",
                        "element", "keys", "values"]
        for fn in builtins {
            #expect(allPatterns.contains(fn), "Missing built-in function: \(fn)")
        }
    }

    // MARK: - Types

    @Test func typeKeywords() {
        let typeRules = grammar.rules.filter { $0.scope == "type" }
        let allPatterns = typeRules.map(\.pattern).joined(separator: " ")

        let types = ["string", "number", "bool", "list", "map", "set", "object", "tuple", "any", "optional"]
        for type in types {
            #expect(allPatterns.contains(type), "Missing type: \(type)")
        }
    }

    // MARK: - Numbers

    @Test func numberRules() {
        let numberRules = grammar.rules.filter { $0.scope == "number" }
        #expect(numberRules.count >= 2)
    }

    @Test func hexNumberRule() {
        let rule = grammar.rules.first { $0.scope == "number" && $0.pattern.contains("0x") }
        #expect(rule != nil)
    }

    // MARK: - General function call pattern

    @Test func generalFunctionCallPattern() {
        let rule = grammar.rules.first { $0.scope == "function" && $0.pattern.contains("\\(") }
        #expect(rule != nil)
    }
}
