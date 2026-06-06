//
//  GrammarRegistryTests.swift
//  PineTests
//
//  Tests for GrammarRegistry — grammar loading, indexing, and lookup.
//

import Testing
import AppKit
@testable import Pine

@Suite("GrammarRegistry Tests", .serialized)
struct GrammarRegistryTests {

    private let registry = GrammarRegistry()

    private let swiftGrammar = Grammar(
        name: "RegistryTestSwift",
        extensions: ["regswift"],
        rules: [GrammarRule(pattern: "\\bfunc\\b", scope: "keyword")],
        lineComment: "//",
        blockComment: BlockCommentDelimiters(open: "/*", close: "*/")
    )

    private let dockerGrammar = Grammar(
        name: "RegistryTestDockerfile",
        extensions: ["dockerreg"],
        rules: [GrammarRule(pattern: "\\bFROM\\b", scope: "keyword")],
        fileNames: ["RegistryTestDockerfile"],
        lineComment: "#"
    )

    private let globGrammar = Grammar(
        name: "RegistryTestGlob",
        extensions: ["globreg"],
        rules: [GrammarRule(pattern: "\\btest\\b", scope: "keyword")],
        filePatterns: ["Jenkinsfile.*"]
    )

    // MARK: - Register + Resolve by Extension

    @Test func registerGrammar_resolvesByExtension() {
        registry.registerGrammar(swiftGrammar)

        let resolved = registry.resolveGrammar(language: "regswift", fileName: nil)
        #expect(resolved != nil)
        #expect(resolved?.name == "RegistryTestSwift")
    }

    @Test func registerGrammar_resolvesByExtensionCaseInsensitive() {
        registry.registerGrammar(swiftGrammar)

        let resolved = registry.resolveGrammar(language: "REGSWIFT", fileName: nil)
        #expect(resolved != nil)
    }

    @Test func registerGrammar_unknownExtensionReturnsNil() {
        let resolved = registry.resolveGrammar(language: "nonexistent_lang_xyz", fileName: nil)
        #expect(resolved == nil)
    }

    // MARK: - Resolve by File Name

    @Test func registerGrammar_resolvesByFileName() {
        registry.registerGrammar(dockerGrammar)

        let resolved = registry.resolveGrammar(language: "nonexistent", fileName: "RegistryTestDockerfile")
        #expect(resolved != nil)
        #expect(resolved?.name == "RegistryTestDockerfile")
    }

    @Test func fileNamePriorityOverExtension() {
        registry.registerGrammar(swiftGrammar)
        registry.registerGrammar(dockerGrammar)

        // dockerGrammar has "RegistryTestDockerfile" as fileName
        // swiftGrammar has "regswift" as extension
        // Requesting fileName="RegistryTestDockerfile" should prefer dockerGrammar
        let resolved = registry.resolveGrammar(language: "regswift", fileName: "RegistryTestDockerfile")
        #expect(resolved?.name == "RegistryTestDockerfile")
    }

    // MARK: - Resolve by Glob Pattern

    @Test func registerGrammar_resolvesByGlobPattern() {
        registry.registerGrammar(globGrammar)

        let resolved = registry.resolveGrammar(language: "nonexistent", fileName: "Jenkinsfile.dev")
        #expect(resolved != nil)
        #expect(resolved?.name == "RegistryTestGlob")
    }

    @Test func globPatternDoesNotMatchExact() {
        registry.registerGrammar(globGrammar)

        let resolved = registry.resolveGrammar(language: "nonexistent", fileName: "Jenkinsfile")
        #expect(resolved == nil)
    }

    // MARK: - Line Comment

    @Test func lineComment_forExtension() {
        registry.registerGrammar(swiftGrammar)
        #expect(registry.lineComment(forExtension: "regswift") == "//")
    }

    @Test func lineComment_forUnknownExtensionReturnsNil() {
        #expect(registry.lineComment(forExtension: "unknownExt") == nil)
    }

    @Test func lineComment_forFileName() {
        registry.registerGrammar(dockerGrammar)
        #expect(registry.lineComment(forFileName: "RegistryTestDockerfile") == "#")
    }

    // MARK: - Comment Style

    @Test func commentStyle_lineCommentPreferred() {
        registry.registerGrammar(swiftGrammar)

        let style = registry.commentStyle(forExtension: "regswift", fileName: nil)
        if case .line(let prefix) = style {
            #expect(prefix == "//")
        } else {
            Issue.record("Expected line comment for regswift")
        }
    }

    @Test func commentStyle_blockCommentFallback() {
        let grammar = Grammar(
            name: "BlockOnly",
            extensions: ["blockonly"],
            rules: [],
            blockComment: BlockCommentDelimiters(open: "<!--", close: "-->")
        )
        registry.registerGrammar(grammar)

        let style = registry.commentStyle(forExtension: "blockonly", fileName: nil)
        if case .block(let open, let close) = style {
            #expect(open == "<!--")
            #expect(close == "-->")
        } else {
            Issue.record("Expected block comment for blockonly")
        }
    }

    @Test func commentStyle_unknownReturnsNil() {
        let style = registry.commentStyle(forExtension: "xyz_unknown", fileName: nil)
        #expect(style == nil)
    }

    // MARK: - Unregister

    @Test func unregisterGrammar_removesFromLookup() {
        registry.registerGrammar(swiftGrammar)
        #expect(registry.resolveGrammar(language: "regswift", fileName: nil) != nil)

        registry.unregisterGrammar(swiftGrammar)
        #expect(registry.resolveGrammar(language: "regswift", fileName: nil) == nil)
    }

    // MARK: - resolveGrammarByTag

    @Test func resolveGrammarByTag_directExtension() {
        registry.registerGrammar(swiftGrammar)
        let result = registry.resolveGrammarByTag("regswift")
        #expect(result != nil)
        #expect(result?.name == "RegistryTestSwift")
    }

    @Test func resolveGrammarByTag_caseInsensitive() {
        registry.registerGrammar(swiftGrammar)
        let result = registry.resolveGrammarByTag("REGSWIFT")
        #expect(result != nil)
    }

    @Test func resolveGrammarByTag_unknownReturnsNil() {
        let result = registry.resolveGrammarByTag("nonexistent_language_xyz")
        #expect(result == nil)
    }

    // MARK: - Multiple Extensions

    @Test func registerGrammar_multipleExtensions() {
        let multiGrammar = Grammar(
            name: "MultiExt",
            extensions: ["ext1", "ext2", "ext3"],
            rules: [GrammarRule(pattern: "\\bfoo\\b", scope: "keyword")]
        )
        registry.registerGrammar(multiGrammar)

        #expect(registry.resolveGrammar(language: "ext1", fileName: nil)?.name == "MultiExt")
        #expect(registry.resolveGrammar(language: "ext2", fileName: nil)?.name == "MultiExt")
        #expect(registry.resolveGrammar(language: "ext3", fileName: nil)?.name == "MultiExt")
    }
}
