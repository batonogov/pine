//
//  TrailingNewlineTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("String ensuringTrailingNewline")
@MainActor
struct TrailingNewlineTests {

    @Test("Adds LF when file has no trailing newline")
    func addsLFWhenMissing() {
        #expect("hello".ensuringTrailingNewline() == "hello\n")
    }

    @Test("Does not double newline when one is already present")
    func preservesSingleTrailingLF() {
        #expect("hello\n".ensuringTrailingNewline() == "hello\n")
    }

    @Test("Collapses multiple trailing LFs into one")
    func collapsesMultipleTrailingLFs() {
        #expect("hello\n\n\n".ensuringTrailingNewline() == "hello\n")
    }

    @Test("Collapses multiple trailing CRLFs preserving CRLF style")
    func collapsesMultipleTrailingCRLFs() {
        #expect("a\r\nb\r\n\r\n\r\n".ensuringTrailingNewline() == "a\r\nb\r\n")
    }

    @Test("Preserves CRLF line endings when adding newline")
    func preservesCRLFStyle() {
        #expect("a\r\nb".ensuringTrailingNewline() == "a\r\nb\r\n")
    }

    @Test("Uses LF when file has no line endings")
    func defaultsToLFWhenNoLineEnding() {
        #expect("single line".ensuringTrailingNewline() == "single line\n")
    }

    @Test("Empty string is unchanged")
    func emptyStringUnchanged() {
        #expect("".ensuringTrailingNewline() == "")
    }

    @Test("String of only newlines is unchanged")
    func onlyNewlinesUnchanged() {
        #expect("\n\n\n".ensuringTrailingNewline() == "\n\n\n")
    }

    @Test("Bare CR at end is treated as a trailing newline to collapse")
    func collapsesTrailingCR() {
        // Old classic Mac line endings; treat \r as newline-ish for trimming purposes.
        // Since there's no "\r\n" in the string, LF style is chosen for the appended newline.
        #expect("a\rb\r".ensuringTrailingNewline() == "a\rb\n")
    }

    @Test("Mixed trailing whitespace and newlines — only newlines are collapsed")
    func doesNotTouchNonNewlineWhitespace() {
        // ensuringTrailingNewline is not responsible for stripping spaces — that's
        // trailingWhitespaceStripped's job. A trailing space should be preserved as-is.
        #expect("hello ".ensuringTrailingNewline() == "hello \n")
    }

    @Test("Single LF file is unchanged")
    func singleLFUnchanged() {
        #expect("\n".ensuringTrailingNewline() == "\n")
    }

    @Test("Unicode content is preserved")
    func preservesUnicode() {
        #expect("привет 🌲".ensuringTrailingNewline() == "привет 🌲\n")
    }

    @Test("Large content: only final tail is rewritten")
    func largeContent() {
        let body = String(repeating: "line\n", count: 10_000)
        let input = body + "tail"
        #expect(input.ensuringTrailingNewline() == body + "tail\n")
    }
}
