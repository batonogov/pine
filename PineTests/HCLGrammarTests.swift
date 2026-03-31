//
//  HCLGrammarTests.swift
//  PineTests
//

import AppKit
import Testing
import Foundation
@testable import Pine

@MainActor
struct HCLGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("hcl.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    // MARK: - Metadata

    @Test func grammarMetadata() {
        #expect(grammar.name == "HCL")
        #expect(grammar.extensions.contains("hcl"))
        #expect(grammar.lineComment == "#")
    }

    @Test func blockCommentMetadata() {
        #expect(grammar.blockComment?.open == "/*")
        #expect(grammar.blockComment?.close == "*/")
    }

    @Test func doesNotClaimTerraformExtensions() {
        #expect(!grammar.extensions.contains("tf"))
        #expect(!grammar.extensions.contains("tfvars"))
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

    // MARK: - Core HCL Keywords

    @Test func coreHCLKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let core = ["resource", "data", "variable", "output", "locals",
                     "module", "provider", "if", "for", "in",
                     "true", "false", "null"]
        for kw in core {
            #expect(allPatterns.contains(kw), "Missing core keyword: \(kw)")
        }
    }

    // MARK: - Vault Keywords

    @Test func vaultKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let vault = ["listener", "storage", "seal", "telemetry",
                     "api_addr", "cluster_addr", "ui", "disable_mlock",
                     "default_lease_ttl", "max_lease_ttl"]
        for kw in vault {
            #expect(allPatterns.contains(kw), "Missing Vault keyword: \(kw)")
        }
    }

    // MARK: - Consul Keywords

    @Test func consulKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let consul = ["service", "check", "node", "connect",
                      "datacenter", "encrypt", "retry_join",
                      "acl", "autopilot", "ports"]
        for kw in consul {
            #expect(allPatterns.contains(kw), "Missing Consul keyword: \(kw)")
        }
    }

    // MARK: - Nomad Keywords

    @Test func nomadKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let nomad = ["job", "group", "task", "artifact", "constraint",
                     "affinity", "volume", "vault", "template",
                     "resources", "network", "scaling", "periodic"]
        for kw in nomad {
            #expect(allPatterns.contains(kw), "Missing Nomad keyword: \(kw)")
        }
    }

    // MARK: - Packer Keywords

    @Test func packerKeywords() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let packer = ["build", "source", "post-processor", "packer"]
        for kw in packer {
            #expect(allPatterns.contains(kw), "Missing Packer keyword: \(kw)")
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

    @Test func highlightsVaultListener() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "listener \"tcp\" {\n  address = \"0.0.0.0:8200\"\n}")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "hcl", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func highlightsInterpolation() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "name = \"${var.name}\"")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "hcl", font: font)

        let stringColor = try #require(highlighter.theme.color(for: "string"))
        let text = "name = \"${var.name}\"" as NSString
        let strIndex = text.range(of: "\"${").location
        let color = textStorage.attribute(.foregroundColor, at: strIndex, effectiveRange: nil) as? NSColor
        #expect(color == stringColor)
    }
}
