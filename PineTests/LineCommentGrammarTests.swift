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

    // MARK: - blockComment lookup by extension

    @Test func htmlBlockComment() {
        let highlighter = SyntaxHighlighter.shared
        let bc = highlighter.blockComment(forExtension: "html")
        #expect(bc?.open == "<!--")
        #expect(bc?.close == "-->")
    }

    @Test func cssBlockComment() {
        let highlighter = SyntaxHighlighter.shared
        let bc = highlighter.blockComment(forExtension: "css")
        #expect(bc?.open == "/*")
        #expect(bc?.close == "*/")
    }

    @Test func markdownBlockComment() {
        let highlighter = SyntaxHighlighter.shared
        let bc = highlighter.blockComment(forExtension: "md")
        #expect(bc?.open == "<!--")
        #expect(bc?.close == "-->")
    }

    @Test func sqlBlockComment() {
        let highlighter = SyntaxHighlighter.shared
        let bc = highlighter.blockComment(forExtension: "sql")
        #expect(bc?.open == "/*")
        #expect(bc?.close == "*/")
    }

    @Test func sqlLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "sql") == "--")
    }

    @Test func swiftHasNoBlockComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.blockComment(forExtension: "swift") == nil)
    }

    // MARK: - commentStyle: line preferred over block

    @Test func commentStylePrefersLineComment() {
        let highlighter = SyntaxHighlighter.shared
        // SQL has both lineComment and blockComment — line should win
        if case .line(let prefix) = highlighter.commentStyle(forExtension: "sql", fileName: nil) {
            #expect(prefix == "--")
        } else {
            Issue.record("Expected .line for SQL, got block or nil")
        }
    }

    @Test func commentStyleFallsBackToBlock() {
        let highlighter = SyntaxHighlighter.shared
        // HTML has no lineComment — should return block
        if case .block(let open, let close) = highlighter.commentStyle(forExtension: "html", fileName: nil) {
            #expect(open == "<!--")
            #expect(close == "-->")
        } else {
            Issue.record("Expected .block for HTML, got line or nil")
        }
    }

    @Test func commentStyleReturnsNilForJson() {
        let highlighter = SyntaxHighlighter.shared
        // JSON has neither lineComment nor blockComment
        #expect(highlighter.commentStyle(forExtension: "json", fileName: nil) == nil)
    }

    @Test func commentStyleReturnsNilForUnknown() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.commentStyle(forExtension: "xyz", fileName: nil) == nil)
    }
}
