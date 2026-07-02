//
//  LSPHoverTests.swift
//  PineTests
//
//  Unit tests for LSPHover — parses the polymorphic `contents` field of a
//  textDocument/hover response (MarkupContent, MarkedString, array of
//  MarkedStrings) into a normalised LSPMarkupContent.
//

import Foundation
import Testing

@testable import Pine

@Suite("LSPHover Tests")
struct LSPHoverTests {

    // MARK: - MarkupContent normalization

    @Test("Parse MarkupContent markdown")
    func parseMarkupContentMarkdown() {
        let json: [String: Any] = [
            "contents": [
                "kind": "markdown",
                "value": "## Heading\nSome text"
            ]
        ]
        let hover = LSPHover(result: json)
        #expect(hover != nil)
        #expect(hover?.markup.value == "## Heading\nSome text")
        #expect(hover?.markup.isMarkdown == true)
    }

    @Test("Parse MarkupContent plaintext")
    func parseMarkupContentPlaintext() {
        let json: [String: Any] = [
            "contents": [
                "kind": "plaintext",
                "value": "Just plain text"
            ]
        ]
        let hover = LSPHover(result: json)
        #expect(hover?.markup.value == "Just plain text")
        #expect(hover?.markup.isMarkdown == false)
    }

    @Test("MarkupContent without kind defaults to plaintext")
    func markupContentNoKind() {
        let json: [String: Any] = [
            "contents": ["value": "no kind field"]
        ]
        let hover = LSPHover(result: json)
        #expect(hover?.markup.value == "no kind field")
        #expect(hover?.markup.isMarkdown == false)
    }

    // MARK: - Plain MarkedString (bare string)

    @Test("Parse plain MarkedString (bare string)")
    func parseBareString() {
        let json: [String: Any] = [
            "contents": "This is a hover string"
        ]
        let hover = LSPHover(result: json)
        #expect(hover != nil)
        #expect(hover?.markup.value == "This is a hover string")
        #expect(hover?.markup.isMarkdown == false)
    }

    // MARK: - Code MarkedString ({language, value})

    @Test("Parse code MarkedString")
    func parseCodeMarkedString() {
        let json: [String: Any] = [
            "contents": [
                "language": "swift",
                "value": "func hello() {}"
            ]
        ]
        let hover = LSPHover(result: json)
        #expect(hover != nil)
        #expect(hover?.markup.value == "func hello() {}")
        #expect(hover?.markup.isMarkdown == false)
    }

    @Test("Code MarkedString without language")
    func parseCodeMarkedStringNoLanguage() {
        let json: [String: Any] = [
            "contents": ["value": "code block"]
        ]
        let hover = LSPHover(result: json)
        #expect(hover?.markup.value == "code block")
        #expect(hover?.markup.isMarkdown == false)
    }

    // MARK: - Array of MarkedStrings

    @Test("Parse array of bare strings")
    func parseArrayOfStrings() {
        let json: [String: Any] = [
            "contents": ["First part", "Second part"]
        ]
        let hover = LSPHover(result: json)
        #expect(hover != nil)
        #expect(hover?.markup.value == "First part\n\nSecond part")
    }

    @Test("Parse array of code MarkedStrings")
    func parseArrayOfCodeMarkedStrings() {
        let json: [String: Any] = [
            "contents": [
                ["language": "swift", "value": "let x = 1"],
                ["language": "python", "value": "x = 1"]
            ]
        ]
        let hover = LSPHover(result: json)
        #expect(hover != nil)
        #expect(hover?.markup.isMarkdown == true)
        #expect(hover?.markup.value.contains("```swift") == true)
        #expect(hover?.markup.value.contains("let x = 1") == true)
        #expect(hover?.markup.value.contains("```python") == true)
        #expect(hover?.markup.value.contains("x = 1") == true)
    }

    @Test("Parse mixed array of strings and code MarkedStrings")
    func parseMixedArray() {
        let json: [String: Any] = [
            "contents": [
                "Description text",
                ["language": "swift", "value": "code()"]
            ]
        ]
        let hover = LSPHover(result: json)
        #expect(hover != nil)
        #expect(hover?.markup.isMarkdown == true)
        #expect(hover?.markup.value.contains("Description text") == true)
        #expect(hover?.markup.value.contains("```swift") == true)
    }

    @Test("Array elements joined with double newline")
    func arrayJoinedWithDoubleNewline() {
        let json: [String: Any] = [
            "contents": ["A", "B", "C"]
        ]
        let hover = LSPHover(result: json)
        #expect(hover?.markup.value == "A\n\nB\n\nC")
    }

    // MARK: - Null / empty contents

    @Test("Null result returns nil")
    func nullResult() {
        let hover = LSPHover(result: nil)
        #expect(hover == nil)
    }

    @Test("Non-dictionary result returns nil")
    func nonDictionaryResult() {
        let hover = LSPHover(result: "just a string")
        #expect(hover == nil)
    }

    @Test("Empty contents returns nil")
    func emptyContents() {
        let json: [String: Any] = ["contents": ""]
        let hover = LSPHover(result: json)
        #expect(hover == nil)
    }

    @Test("Empty array contents returns nil")
    func emptyArrayContents() {
        let json: [String: Any] = ["contents": []]
        let hover = LSPHover(result: json)
        #expect(hover == nil)
    }

    @Test("Missing contents key returns nil")
    func missingContents() {
        let json: [String: Any] = ["range": [:]]
        let hover = LSPHover(result: json)
        #expect(hover == nil)
    }

    @Test("Array of empty strings returns nil")
    func arrayOfEmptyStrings() {
        let json: [String: Any] = ["contents": ["", ""]]
        let hover = LSPHover(result: json)
        #expect(hover == nil)
    }

    // MARK: - Range parsing

    @Test("Optional range parsed when present")
    func rangeParsed() {
        let json: [String: Any] = [
            "contents": "text",
            "range": [
                "start": ["line": 2, "character": 3],
                "end": ["line": 2, "character": 8]
            ]
        ]
        let hover = LSPHover(result: json)
        #expect(hover?.range != nil)
        #expect(hover?.range?.start.line == 2)
        #expect(hover?.range?.start.character == 3)
        #expect(hover?.range?.end.character == 8)
    }

    @Test("Range is nil when absent")
    func rangeAbsent() {
        let json: [String: Any] = ["contents": "text"]
        let hover = LSPHover(result: json)
        #expect(hover?.range == nil)
    }
}
