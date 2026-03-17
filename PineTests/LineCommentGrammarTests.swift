//
//  LineCommentGrammarTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct LineCommentGrammarTests {

    // MARK: - lineComment lookup by extension

    @Test func swiftLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "swift") == "//")
    }

    @Test func pythonLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "py") == "#")
    }

    @Test func jsonHasNoLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "json") == nil)
    }

    @Test func htmlHasNoLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "html") == nil)
    }

    @Test func markdownHasNoLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "md") == nil)
    }

    @Test func goLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "go") == "//")
    }

    @Test func shellLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "sh") == "#")
    }

    @Test func yamlLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "yml") == "#")
    }

    @Test func rustLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "rs") == "//")
    }

    @Test func cssHasNoLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "css") == nil)
    }

    @Test func cLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "c") == "//")
    }

    @Test func cppLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "cpp") == "//")
    }

    @Test func javascriptLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "js") == "//")
    }

    @Test func typescriptLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "ts") == "//")
    }

    @Test func dockerfileLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forFileName: "Dockerfile") == "#")
    }

    // MARK: - Unknown extension

    @Test func unknownExtensionReturnsNil() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "xyz") == nil)
    }
}
