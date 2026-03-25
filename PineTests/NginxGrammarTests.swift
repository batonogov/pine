//
//  NginxGrammarTests.swift
//  PineTests
//

import AppKit
import Testing
import Foundation
@testable import Pine

struct NginxGrammarTests {

    let grammar: Grammar

    init() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let url = grammarDir.appendingPathComponent("nginx.json")
        let data = try Data(contentsOf: url)
        grammar = try JSONDecoder().decode(Grammar.self, from: data)
    }

    // MARK: - Metadata

    @Test func grammarMetadata() {
        #expect(grammar.name == "Nginx")
        #expect(grammar.lineComment == "#")
    }

    @Test func fileNamesIncludeNginxConf() {
        #expect(grammar.fileNames?.contains("nginx.conf") == true)
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
        #expect(scopes.contains("attribute"))
        #expect(scopes.contains("number"))
        #expect(scopes.contains("type"))
    }

    // MARK: - Core Directives

    @Test func coreDirectives() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let core = ["server", "location", "upstream", "http", "events",
                     "stream", "listen", "server_name", "root", "index",
                     "include", "worker_processes", "worker_connections"]
        for kw in core {
            #expect(allPatterns.contains(kw), "Missing core directive: \(kw)")
        }
    }

    // MARK: - Proxy Directives

    @Test func proxyDirectives() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let proxy = ["proxy_pass", "proxy_set_header", "proxy_redirect",
                     "proxy_connect_timeout", "proxy_read_timeout",
                     "proxy_buffering", "proxy_cache", "proxy_cache_valid",
                     "proxy_http_version"]
        for kw in proxy {
            #expect(allPatterns.contains(kw), "Missing proxy directive: \(kw)")
        }
    }

    // MARK: - SSL Directives

    @Test func sslDirectives() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let ssl = ["ssl", "ssl_certificate", "ssl_certificate_key",
                   "ssl_protocols", "ssl_ciphers", "ssl_session_cache",
                   "ssl_prefer_server_ciphers", "ssl_stapling"]
        for kw in ssl {
            #expect(allPatterns.contains(kw), "Missing SSL directive: \(kw)")
        }
    }

    // MARK: - Gzip Directives

    @Test func gzipDirectives() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let gzip = ["gzip", "gzip_types", "gzip_vary", "gzip_min_length",
                     "gzip_comp_level"]
        for kw in gzip {
            #expect(allPatterns.contains(kw), "Missing gzip directive: \(kw)")
        }
    }

    // MARK: - Client/Timeout Directives

    @Test func clientDirectives() {
        let keywordRules = grammar.rules.filter { $0.scope == "keyword" }
        let allPatterns = keywordRules.map(\.pattern).joined(separator: " ")

        let client = ["client_max_body_size", "client_body_timeout",
                      "send_timeout", "keepalive_timeout"]
        for kw in client {
            #expect(allPatterns.contains(kw), "Missing client directive: \(kw)")
        }
    }

    // MARK: - Variables

    @Test func variablesAreAttributes() {
        let rule = grammar.rules.first { $0.scope == "attribute" && $0.pattern.contains("\\$") }
        #expect(rule != nil)
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

    @Test func highlightsServerDirective() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "server {\n  listen 80;\n}")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "nginx", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func highlightsVariable() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "set $backend \"http://127.0.0.1\";")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "nginx", font: font)

        let attrColor = try #require(highlighter.theme.color(for: "attribute"))
        let text = "set $backend \"http://127.0.0.1\";" as NSString
        let varIndex = text.range(of: "$backend").location
        let color = textStorage.attribute(.foregroundColor, at: varIndex, effectiveRange: nil) as? NSColor
        #expect(color == attrColor)
    }

    @Test func highlightsNumber() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "listen 443;")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "nginx", font: font)

        let numberColor = try #require(highlighter.theme.color(for: "number"))
        let text = "listen 443;" as NSString
        let numIndex = text.range(of: "443").location
        let color = textStorage.attribute(.foregroundColor, at: numIndex, effectiveRange: nil) as? NSColor
        #expect(color == numberColor)
    }
}
