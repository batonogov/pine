//
//  GrammarModelTests.swift
//  PineTests
//

import AppKit
import Testing
import Foundation
@testable import Pine

@MainActor
struct GrammarModelTests {

    // MARK: - Grammar Decoding

    @Test func decodesBasicGrammar() throws {
        let json = """
        {
            "name": "TestLang",
            "extensions": ["tl", "test"],
            "rules": [
                {"pattern": "\\\\bfunc\\\\b", "scope": "keyword"},
                {"pattern": "\\\\/\\\\/.*$", "scope": "comment", "options": ["anchorsMatchLines"]}
            ]
        }
        """
        let data = Data(json.utf8)
        let grammar = try JSONDecoder().decode(Grammar.self, from: data)

        #expect(grammar.name == "TestLang")
        #expect(grammar.extensions == ["tl", "test"])
        #expect(grammar.rules.count == 2)
        #expect(grammar.rules[0].scope == "keyword")
        #expect(grammar.rules[1].scope == "comment")
        #expect(grammar.rules[1].options == ["anchorsMatchLines"])
        #expect(grammar.fileNames == nil)
    }

    @Test func decodesGrammarWithFileNames() throws {
        let json = """
        {
            "name": "Dockerfile",
            "extensions": [],
            "rules": [],
            "fileNames": ["Dockerfile", "Containerfile"]
        }
        """
        let data = Data(json.utf8)
        let grammar = try JSONDecoder().decode(Grammar.self, from: data)

        #expect(grammar.fileNames == ["Dockerfile", "Containerfile"])
    }

    @Test func decodesGrammarWithFilePatterns() throws {
        let json = """
        {
            "name": "Dockerfile",
            "extensions": [],
            "rules": [{"pattern": "FROM", "scope": "keyword"}],
            "fileNames": ["Dockerfile"],
            "filePatterns": ["Dockerfile.*", "*.Dockerfile"]
        }
        """
        let data = Data(json.utf8)
        let grammar = try JSONDecoder().decode(Grammar.self, from: data)

        #expect(grammar.filePatterns == ["Dockerfile.*", "*.Dockerfile"])
    }

    @Test func decodesGrammarWithoutFilePatterns() throws {
        let json = """
        {
            "name": "Go",
            "extensions": ["go"],
            "rules": [{"pattern": "func", "scope": "keyword"}]
        }
        """
        let data = Data(json.utf8)
        let grammar = try JSONDecoder().decode(Grammar.self, from: data)

        #expect(grammar.filePatterns == nil)
    }

    @Test func decodesGrammarRule() throws {
        let json = """
        {"pattern": "test", "scope": "string"}
        """
        let data = Data(json.utf8)
        let rule = try JSONDecoder().decode(GrammarRule.self, from: data)

        #expect(rule.pattern == "test")
        #expect(rule.scope == "string")
        #expect(rule.options == nil)
    }

    @Test func decodesGrammarRuleWithOptions() throws {
        let json = """
        {"pattern": "test", "scope": "comment", "options": ["anchorsMatchLines", "caseInsensitive"]}
        """
        let data = Data(json.utf8)
        let rule = try JSONDecoder().decode(GrammarRule.self, from: data)

        #expect(rule.options?.count == 2)
        #expect(rule.options?.contains("anchorsMatchLines") == true)
        #expect(rule.options?.contains("caseInsensitive") == true)
    }

    // MARK: - Theme

    @Test func themeReturnsColorsForKnownScopes() {
        let theme = Theme.default
        #expect(theme.color(for: "comment") != nil)
        #expect(theme.color(for: "string") != nil)
        #expect(theme.color(for: "keyword") != nil)
        #expect(theme.color(for: "number") != nil)
        #expect(theme.color(for: "type") != nil)
        #expect(theme.color(for: "attribute") != nil)
        #expect(theme.color(for: "function") != nil)
    }

    @Test func themeReturnsNilForUnknownScope() {
        let theme = Theme.default
        #expect(theme.color(for: "nonexistent") == nil)
    }

    // MARK: - File Pattern Matching

    @Test func highlighterResolvesExactFileName() {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestExact",
            extensions: [],
            rules: [GrammarRule(pattern: "test", scope: "keyword")],
            fileNames: ["Vagrantfile"],
            lineComment: "#"
        )
        highlighter.registerGrammar(grammar)
        #expect(highlighter.lineComment(forFileName: "Vagrantfile") == "#")
    }

    @Test func highlighterResolvesFilePattern() {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestPattern",
            extensions: [],
            rules: [GrammarRule(pattern: "test", scope: "keyword")],
            filePatterns: ["TestPattern.*", "*.testpat"],
            lineComment: "//"
        )
        highlighter.registerGrammar(grammar)
        #expect(highlighter.lineComment(forFileName: "TestPattern.prod") == "//")
        #expect(highlighter.lineComment(forFileName: "app.testpat") == "//")
        #expect(highlighter.lineComment(forFileName: "other.txt") == nil)
    }

    @Test func highlighterPrioritizesExtensionOverPattern() {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestPriority",
            extensions: ["tpri"],
            rules: [GrammarRule(pattern: "x", scope: "keyword")],
            filePatterns: ["*.tpri"],
            lineComment: "//"
        )
        highlighter.registerGrammar(grammar)
        #expect(highlighter.lineComment(forExtension: "tpri") == "//")
    }

    @Test func highlighterPrioritizesExactNameOverPattern() {
        let highlighter = SyntaxHighlighter.shared
        let exactGrammar = Grammar(
            name: "TestExactPrio",
            extensions: [],
            rules: [GrammarRule(pattern: "x", scope: "keyword")],
            fileNames: ["SpecialFile"],
            lineComment: "//"
        )
        let patternGrammar = Grammar(
            name: "TestPatternPrio",
            extensions: [],
            rules: [GrammarRule(pattern: "x", scope: "keyword")],
            filePatterns: ["Special*"],
            lineComment: "#"
        )
        highlighter.registerGrammar(exactGrammar)
        highlighter.registerGrammar(patternGrammar)
        // Exact name (//) should win over pattern (#)
        #expect(highlighter.lineComment(forFileName: "SpecialFile") == "//")
    }

    @Test func globMatchWithQuestionMark() {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestQuestion",
            extensions: [],
            rules: [GrammarRule(pattern: "x", scope: "keyword")],
            filePatterns: ["file?.txt"],
            lineComment: "#"
        )
        highlighter.registerGrammar(grammar)
        #expect(highlighter.lineComment(forFileName: "fileA.txt") == "#")
        #expect(highlighter.lineComment(forFileName: "file1.txt") == "#")
        // ? matches exactly one character, not zero
        #expect(highlighter.lineComment(forFileName: "file.txt") == nil)
        // ? matches exactly one character, not two
        #expect(highlighter.lineComment(forFileName: "fileAB.txt") == nil)
    }

    @Test func globMatchDoesNotMatchPartialString() {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestPartial",
            extensions: [],
            rules: [GrammarRule(pattern: "x", scope: "keyword")],
            filePatterns: ["ExactOnlyFile"],
            lineComment: "#"
        )
        highlighter.registerGrammar(grammar)
        // Exact match works
        #expect(highlighter.lineComment(forFileName: "ExactOnlyFile") == "#")
        // Partial match should NOT work (no wildcard in pattern)
        #expect(highlighter.lineComment(forFileName: "ExactOnlyFile.bak") == nil)
        #expect(highlighter.lineComment(forFileName: "myExactOnlyFile") == nil)
    }

    @Test func globMatchWithSpecialRegexCharacters() {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestSpecialChars",
            extensions: [],
            rules: [GrammarRule(pattern: "x", scope: "keyword")],
            filePatterns: [".env.*"],
            lineComment: "#"
        )
        highlighter.registerGrammar(grammar)
        // Dot should be literal, not regex wildcard
        #expect(highlighter.lineComment(forFileName: ".env.local") == "#")
        #expect(highlighter.lineComment(forFileName: ".env.production") == "#")
        // "Xenv" should not match (dot is literal)
        #expect(highlighter.lineComment(forFileName: "XenvYlocal") == nil)
    }

    // MARK: - Bundled Grammar Files

    @Test func bundledGrammarFilesAreValidJSON() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let files = try FileManager.default.contentsOfDirectory(
            at: grammarDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        #expect(!files.isEmpty, "Should find grammar JSON files")

        let decoder = JSONDecoder()
        for file in files {
            let data = try Data(contentsOf: file)
            let grammar = try decoder.decode(Grammar.self, from: data)
            #expect(!grammar.name.isEmpty, "Grammar \(file.lastPathComponent) should have a name")
            #expect(!grammar.rules.isEmpty, "Grammar \(grammar.name) should have rules")
        }
    }

    @Test func allBundledGrammarRulesCompileToValidRegex() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let files = try FileManager.default.contentsOfDirectory(
            at: grammarDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        let decoder = JSONDecoder()
        for file in files {
            let data = try Data(contentsOf: file)
            let grammar = try decoder.decode(Grammar.self, from: data)

            for rule in grammar.rules {
                var opts: NSRegularExpression.Options = []
                if let options = rule.options {
                    for opt in options {
                        switch opt {
                        case "anchorsMatchLines": opts.insert(.anchorsMatchLines)
                        case "caseInsensitive": opts.insert(.caseInsensitive)
                        case "dotMatchesLineSeparators": opts.insert(.dotMatchesLineSeparators)
                        default: break
                        }
                    }
                }
                let regex = try? NSRegularExpression(pattern: rule.pattern, options: opts)
                #expect(
                    regex != nil,
                    "Rule '\(rule.pattern)' in \(grammar.name) should compile to valid regex"
                )
            }
        }
    }

    @Test func allBundledGrammarRulesUseKnownScopes() throws {
        let knownScopes: Set<String> = [
            "comment", "string", "keyword", "number", "type", "attribute", "function",
            // Markdown-specific scopes for visual hierarchy (see Theme.default).
            "markdown.heading.1", "markdown.heading.2", "markdown.heading.3",
            "markdown.heading.4", "markdown.heading.5", "markdown.heading.6",
            "markdown.bold", "markdown.italic", "markdown.code", "markdown.code.fenced",
            // `markdown.code.double` is double-backtick inline code; distinct
            // priority from single-backtick so nested backticks survive.
            "markdown.code.double",
            "markdown.link", "markdown.image", "markdown.list",
            "markdown.quote", "markdown.rule"
        ]

        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let files = try FileManager.default.contentsOfDirectory(
            at: grammarDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        let decoder = JSONDecoder()
        for file in files {
            let data = try Data(contentsOf: file)
            let grammar = try decoder.decode(Grammar.self, from: data)

            for rule in grammar.rules {
                #expect(
                    knownScopes.contains(rule.scope),
                    "Rule scope '\(rule.scope)' in \(grammar.name) should be a known scope"
                )
            }
        }
    }

    // MARK: - Syntax Highlighting Integration

    @Test func highlighterAppliesKeywordColor() throws {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestHighlight",
            extensions: ["thl"],
            rules: [GrammarRule(pattern: "\\bfunc\\b", scope: "keyword")],
            lineComment: "//"
        )
        highlighter.registerGrammar(grammar)

        let textStorage = NSTextStorage(string: "func main()")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "thl", font: font)

        // "func" (range 0..<4) should have keyword color
        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        var range = NSRange()
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: &range) as? NSColor
        #expect(color == keywordColor)
        #expect(range.location == 0)
        #expect(range.length == 4)
    }

    @Test func highlighterResolvesGrammarByFileName() throws {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestFileResolve",
            extensions: [],
            rules: [GrammarRule(pattern: "\\bSERVER\\b", scope: "keyword")],
            fileNames: ["TestFileResolve.conf"]
        )
        highlighter.registerGrammar(grammar)

        let textStorage = NSTextStorage(string: "SERVER 127.0.0.1")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(
            textStorage: textStorage,
            language: "unknown",
            fileName: "TestFileResolve.conf",
            font: font
        )

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func highlighterResolvesGrammarByFilePattern() throws {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestPatternResolve",
            extensions: [],
            rules: [GrammarRule(pattern: "\\bFROM\\b", scope: "keyword")],
            filePatterns: ["TestPatternResolve.*"]
        )
        highlighter.registerGrammar(grammar)

        let textStorage = NSTextStorage(string: "FROM ubuntu:22.04")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(
            textStorage: textStorage,
            language: "unknown",
            fileName: "TestPatternResolve.prod",
            font: font
        )

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func highlighterCommentAndStringRangesWork() {
        let highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "TestCSR",
            extensions: ["tcsr"],
            rules: [
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: "\"[^\"]*\"", scope: "string")
            ]
        )
        highlighter.registerGrammar(grammar)

        let text = "x = \"hello\" // comment"
        let ranges = highlighter.commentAndStringRanges(in: text, language: "tcsr")
        #expect(ranges.count == 2)
    }

    // MARK: - New Grammar Smoke Tests

    @Test func tomlGrammarHighlightsSection() {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "[package]\nname = \"pine\"")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "toml", font: font)

        // "[package]" should be highlighted (keyword scope for section headers)
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color != NSColor.textColor, "TOML section header should be highlighted")
    }

    @Test func javaGrammarHighlightsAnnotation() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "@Override\npublic void run() {}")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "java", font: font)

        let attrColor = try #require(highlighter.theme.color(for: "attribute"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == attrColor)
    }

    @Test func kotlinGrammarHighlightsKeyword() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "fun main() {}")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "kt", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func rubyGrammarHighlightsSymbol() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "x = :hello")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "rb", font: font)

        let stringColor = try #require(highlighter.theme.color(for: "string"))
        // :hello starts at index 4
        let color = textStorage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        #expect(color == stringColor)
    }

    @Test func hclGrammarHighlightsResource() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "resource \"aws_instance\" \"web\" {}")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "tf", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func diffGrammarHighlightsAddedAndRemovedLines() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "+added line\n-removed line")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "diff", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let stringColor = try #require(highlighter.theme.color(for: "string"))
        let addColor = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let rmColor = textStorage.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? NSColor
        #expect(addColor == keywordColor)
        #expect(rmColor == stringColor)
    }

    @Test func xmlGrammarHighlightsTag() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "<root attr=\"val\"/>")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "xml", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func graphqlGrammarHighlightsQuery() throws {
        let highlighter = SyntaxHighlighter.shared
        let textStorage = NSTextStorage(string: "query GetUser { name }")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "graphql", font: font)

        let keywordColor = try #require(highlighter.theme.color(for: "keyword"))
        let color = textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == keywordColor)
    }

    @Test func htmlGrammarHighlightsCSSProperty() throws {
        let highlighter = SyntaxHighlighter.shared
        let text = "<style>\n  display: flex;\n</style>"
        let textStorage = NSTextStorage(string: text)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "html", font: font)

        let attrColor = try #require(highlighter.theme.color(for: "attribute"))
        let displayIndex = (text as NSString).range(of: "display").location
        let color = textStorage.attribute(
            .foregroundColor, at: displayIndex, effectiveRange: nil
        ) as? NSColor
        #expect(color == attrColor, "CSS property 'display' in <style> should be highlighted")
    }

    @Test func htmlGrammarHighlightsCSSHexColor() throws {
        let highlighter = SyntaxHighlighter.shared
        let text = "<style>\n  color: #ff0000;\n</style>"
        let textStorage = NSTextStorage(string: text)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "html", font: font)

        let numberColor = try #require(highlighter.theme.color(for: "number"))
        let hexIndex = (text as NSString).range(of: "#ff0000").location
        let color = textStorage.attribute(
            .foregroundColor, at: hexIndex, effectiveRange: nil
        ) as? NSColor
        #expect(color == numberColor, "CSS hex color should be highlighted")
    }

    // MARK: - Line Comment for New Grammars

    @Test func newGrammarsHaveCorrectLineComment() throws {
        let grammarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        let files = try FileManager.default.contentsOfDirectory(
            at: grammarDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        let decoder = JSONDecoder()
        let expectedComments: [String: String] = [
            "TOML": "#", "Makefile": "#", "INI": "#", "Ruby": "#",
            "Java": "//", "HCL": "#", "Protobuf": "//", "Groovy": "//",
            "Nginx": "#", "Kotlin": "//", "Dart": "//", "GraphQL": "#",
            "Nix": "#", "Prisma": "//", "SSH Config": "#",
            "Swift": "//", "Go": "//", "Python": "#", "Rust": "//",
            "JavaScript": "//", "TypeScript": "//", "C": "//", "C++": "//",
            "Shell": "#", "YAML": "#", "Dockerfile": "#",
            "Helm": "#", "Jinja2": "#"
        ]

        for file in files {
            let data = try Data(contentsOf: file)
            let grammar = try decoder.decode(Grammar.self, from: data)

            if let expected = expectedComments[grammar.name] {
                #expect(
                    grammar.lineComment == expected,
                    "\(grammar.name) lineComment should be '\(expected)', got '\(grammar.lineComment ?? "nil")'"
                )
            }
        }
    }
}
