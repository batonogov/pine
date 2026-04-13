//
//  SyntaxHighlighterEdgeTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

@Suite(.serialized)
@MainActor
struct SyntaxHighlighterEdgeTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    // MARK: - HighlightGeneration

    @Test func highlightGeneration_initialValueIsZero() {
        let gen = HighlightGeneration()
        #expect(gen.current == 0)
    }

    @Test func highlightGeneration_incrementReturnsNewValue() {
        let gen = HighlightGeneration()
        let val = gen.increment()
        #expect(val == 1)
        #expect(gen.current == 1)
    }

    @Test func highlightGeneration_multipleIncrements() {
        let gen = HighlightGeneration()
        _ = gen.increment()
        _ = gen.increment()
        let val = gen.increment()
        #expect(val == 3)
        #expect(gen.current == 3)
    }

    // MARK: - commentStyle

    @Test func commentStyle_swiftReturnsLineComment() {
        let hl = SyntaxHighlighter.shared
        let style = hl.commentStyle(forExtension: "swift", fileName: nil)
        if case .line(let prefix) = style {
            #expect(prefix == "//")
        } else {
            Issue.record("Expected line comment for swift")
        }
    }

    @Test func commentStyle_unknownExtensionReturnsNil() {
        let hl = SyntaxHighlighter.shared
        let style = hl.commentStyle(forExtension: "xyz_unknown_ext", fileName: nil)
        #expect(style == nil)
    }

    @Test func commentStyle_pythonReturnsHashComment() {
        let hl = SyntaxHighlighter.shared
        let style = hl.commentStyle(forExtension: "py", fileName: nil)
        if case .line(let prefix) = style {
            #expect(prefix == "#")
        } else {
            Issue.record("Expected line comment for python")
        }
    }

    // MARK: - lineComment lookup

    @Test func lineComment_forExtension() {
        let hl = SyntaxHighlighter.shared
        #expect(hl.lineComment(forExtension: "swift") == "//")
        #expect(hl.lineComment(forExtension: "py") == "#")
    }

    @Test func lineComment_forExtension_unknownReturnsNil() {
        let hl = SyntaxHighlighter.shared
        #expect(hl.lineComment(forExtension: "unknownExt123") == nil)
    }

    // MARK: - resolveGrammarByTag

    @Test func resolveGrammarByTag_directExtension() {
        let hl = SyntaxHighlighter.shared
        let result = hl.resolveGrammarByTag("swift")
        #expect(result != nil)
        #expect(result?.0.name.lowercased().contains("swift") == true)
    }

    @Test func resolveGrammarByTag_alias() {
        let hl = SyntaxHighlighter.shared
        // "javascript" is aliased to "js"
        let result = hl.resolveGrammarByTag("javascript")
        #expect(result != nil)
    }

    @Test func resolveGrammarByTag_unknownReturnsNil() {
        let hl = SyntaxHighlighter.shared
        let result = hl.resolveGrammarByTag("brainfuck")
        #expect(result == nil)
    }

    @Test func resolveGrammarByTag_caseInsensitive() {
        let hl = SyntaxHighlighter.shared
        let result = hl.resolveGrammarByTag("Python")
        #expect(result != nil)
    }

    // MARK: - Theme

    @Test func theme_colorForKnownScope() {
        let theme = Theme.default
        #expect(theme.color(for: "keyword") != nil)
        #expect(theme.color(for: "comment") != nil)
        #expect(theme.color(for: "string") != nil)
    }

    @Test func theme_colorForUnknownScopeReturnsNil() {
        let theme = Theme.default
        #expect(theme.color(for: "nonexistent.scope") == nil)
    }

    // MARK: - registerGrammar

    @Test func registerGrammar_makesGrammarAvailable() {
        let hl = SyntaxHighlighter.shared
        let testGrammar = Grammar(
            name: "TestLangEdge",
            extensions: ["testedge"],
            rules: [GrammarRule(pattern: "\\btest\\b", scope: "keyword")]
        )
        hl.registerGrammar(testGrammar)

        let style = hl.commentStyle(forExtension: "testedge", fileName: nil)
        // No comment style defined → nil
        #expect(style == nil)

        // But it should be recognized
        let result = hl.resolveGrammarByTag("testedge")
        #expect(result != nil)
        #expect(result?.0.name == "TestLangEdge")
    }

    @Test func registerGrammar_withFileNames() {
        let hl = SyntaxHighlighter.shared
        let testGrammar = Grammar(
            name: "TestFileNameGrammar",
            extensions: ["tfn"],
            rules: [GrammarRule(pattern: "\\bfoo\\b", scope: "keyword")],
            fileNames: ["TestSpecialFile"]
        )
        hl.registerGrammar(testGrammar)

        let comment = hl.lineComment(forFileName: "TestSpecialFile")
        // No line comment defined → nil, but grammar should be loadable
        #expect(comment == nil)
    }

    // MARK: - invalidateCache

    @Test func invalidateCache_removesEntry() {
        let hl = SyntaxHighlighter.shared
        let storage = NSTextStorage(string: "test content")
        // Highlight to populate cache
        let testGrammar = Grammar(
            name: "CacheLang",
            extensions: ["cachelang"],
            rules: [GrammarRule(pattern: "\\btest\\b", scope: "keyword")]
        )
        hl.registerGrammar(testGrammar)
        hl.highlight(textStorage: storage, language: "cachelang", font: font)

        // Should not crash
        hl.invalidateCache(for: storage)
    }

    // MARK: - commentAndStringRanges

    @Test func commentAndStringRanges_returnsCommentRanges() {
        let hl = SyntaxHighlighter.shared
        let text = "// a comment\nlet x = 1"
        let ranges = hl.commentAndStringRanges(in: text, language: "swift")
        #expect(!ranges.isEmpty)
    }

    @Test func commentAndStringRanges_unknownLanguageReturnsEmpty() {
        let hl = SyntaxHighlighter.shared
        let ranges = hl.commentAndStringRanges(in: "some text", language: "xyz_unknown_edge")
        #expect(ranges.isEmpty)
    }

    // MARK: - HighlightMatch / HighlightMatchResult

    @Test func highlightMatch_struct() {
        let match = HighlightMatch(range: NSRange(location: 0, length: 5), scope: "keyword", priority: 10)
        #expect(match.scope == "keyword")
        #expect(match.priority == 10)
        #expect(match.range.length == 5)
    }

    @Test func highlightMatchResult_struct() {
        let result = HighlightMatchResult(
            matches: [],
            repaintRange: NSRange(location: 0, length: 10),
            multilineFingerprint: [3, 5]
        )
        #expect(result.matches.isEmpty)
        #expect(result.repaintRange.length == 10)
        #expect(result.multilineFingerprint == [3, 5])
    }

    // MARK: - GrammarRule / Grammar structs

    @Test func grammarRule_optionsNilByDefault() {
        let rule = GrammarRule(pattern: "\\bfoo\\b", scope: "keyword")
        #expect(rule.options == nil)
    }

    @Test func grammar_optionalFieldsNilByDefault() {
        let grammar = Grammar(
            name: "Test",
            extensions: ["tst"],
            rules: []
        )
        #expect(grammar.fileNames == nil)
        #expect(grammar.filePatterns == nil)
        #expect(grammar.lineComment == nil)
        #expect(grammar.blockComment == nil)
    }

    @Test func blockCommentDelimiters_fields() {
        let delims = BlockCommentDelimiters(open: "/*", close: "*/")
        #expect(delims.open == "/*")
        #expect(delims.close == "*/")
    }
}
