//
//  TrailingWhitespaceTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("String trailing whitespace stripping")
@MainActor
struct TrailingWhitespaceTests {

    @Test("Strips trailing spaces from lines")
    func stripsTrailingSpaces() {
        let input = "hello   \nworld  \n"
        #expect(input.trailingWhitespaceStripped() == "hello\nworld\n")
    }

    @Test("Strips trailing tabs from lines")
    func stripsTrailingTabs() {
        let input = "hello\t\t\nworld\t\n"
        #expect(input.trailingWhitespaceStripped() == "hello\nworld\n")
    }

    @Test("Strips mixed trailing whitespace")
    func stripsMixedWhitespace() {
        let input = "hello \t \nworld\t  \n"
        #expect(input.trailingWhitespaceStripped() == "hello\nworld\n")
    }

    @Test("Preserves empty lines")
    func preservesEmptyLines() {
        let input = "hello  \n\nworld\n\n"
        #expect(input.trailingWhitespaceStripped() == "hello\n\nworld\n\n")
    }

    @Test("Preserves leading whitespace")
    func preservesLeadingWhitespace() {
        let input = "    hello  \n\tworld\t\n"
        #expect(input.trailingWhitespaceStripped() == "    hello\n\tworld\n")
    }

    @Test("Handles CRLF line endings")
    func handlesCRLF() {
        let input = "hello   \r\nworld\t\r\n"
        #expect(input.trailingWhitespaceStripped() == "hello\r\nworld\r\n")
    }

    @Test("No-op for clean string")
    func noOpForCleanString() {
        let input = "hello\nworld\n"
        #expect(input.trailingWhitespaceStripped() == "hello\nworld\n")
    }

    @Test("Empty string returns empty")
    func emptyString() {
        #expect("".trailingWhitespaceStripped() == "")
    }

    @Test("Single line with trailing whitespace")
    func singleLine() {
        #expect("hello   ".trailingWhitespaceStripped() == "hello")
    }

    @Test("Only whitespace lines become empty")
    func onlyWhitespace() {
        let input = "   \n\t\t\n  \t  \n"
        #expect(input.trailingWhitespaceStripped() == "\n\n\n")
    }

    @Test("Handles mixed LF and CRLF in same string")
    func handlesMixedLineEndings() {
        let input = "hello   \nworld\t\r\nfoo  \n"
        #expect(input.trailingWhitespaceStripped() == "hello\nworld\r\nfoo\n")
    }

    @Test("String with no trailing newline")
    func noTrailingNewline() {
        #expect("hello   \nworld  ".trailingWhitespaceStripped() == "hello\nworld")
    }

    @Test("String of only newlines unchanged")
    func onlyNewlines() {
        #expect("\n\n\n".trailingWhitespaceStripped() == "\n\n\n")
    }

    @Test("Preserves internal whitespace")
    func preservesInternalWhitespace() {
        let input = "foo  bar  \nbaz\tqux\t\n"
        #expect(input.trailingWhitespaceStripped() == "foo  bar\nbaz\tqux\n")
    }
}
