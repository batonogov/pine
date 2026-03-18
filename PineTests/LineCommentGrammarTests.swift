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

    // MARK: - commentStyle

    @Test func sqlLineComment() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.lineComment(forExtension: "sql") == "--")
    }

    @Test func commentStylePrefersLineComment() {
        let highlighter = SyntaxHighlighter.shared
        // SQL has both lineComment and blockComment — line should win
        if case .line(let prefix) = highlighter.commentStyle(forExtension: "sql", fileName: nil) {
            #expect(prefix == "--")
        } else {
            Issue.record("Expected .line for SQL, got block or nil")
        }
    }

    @Test func commentStyleHTMLBlock() {
        let highlighter = SyntaxHighlighter.shared
        if case .block(let open, let close) = highlighter.commentStyle(forExtension: "html", fileName: nil) {
            #expect(open == "<!--")
            #expect(close == "-->")
        } else {
            Issue.record("Expected .block for HTML, got line or nil")
        }
    }

    @Test func commentStyleCSSBlock() {
        let highlighter = SyntaxHighlighter.shared
        if case .block(let open, let close) = highlighter.commentStyle(forExtension: "css", fileName: nil) {
            #expect(open == "/*")
            #expect(close == "*/")
        } else {
            Issue.record("Expected .block for CSS, got line or nil")
        }
    }

    @Test func commentStyleMarkdownBlock() {
        let highlighter = SyntaxHighlighter.shared
        if case .block(let open, let close) = highlighter.commentStyle(forExtension: "md", fileName: nil) {
            #expect(open == "<!--")
            #expect(close == "-->")
        } else {
            Issue.record("Expected .block for Markdown, got line or nil")
        }
    }

    @Test func commentStyleSwiftLine() {
        let highlighter = SyntaxHighlighter.shared
        if case .line(let prefix) = highlighter.commentStyle(forExtension: "swift", fileName: nil) {
            #expect(prefix == "//")
        } else {
            Issue.record("Expected .line for Swift, got block or nil")
        }
    }

    @Test func commentStyleReturnsNilForJson() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.commentStyle(forExtension: "json", fileName: nil) == nil)
    }

    @Test func commentStyleReturnsNilForUnknown() {
        let highlighter = SyntaxHighlighter.shared
        #expect(highlighter.commentStyle(forExtension: "xyz", fileName: nil) == nil)
    }
}
