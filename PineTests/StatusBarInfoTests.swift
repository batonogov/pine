//
//  StatusBarInfoTests.swift
//  PineTests
//
//  Created by Claude on 21.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("StatusBarInfo Tests")
struct StatusBarInfoTests {

    // MARK: - CursorLocation from position

    @Test("Line and column for empty string")
    func cursorLocationEmptyString() {
        let loc = CursorLocation(position: 0, in: "")
        #expect(loc.line == 1)
        #expect(loc.column == 1)
    }

    @Test("Line and column at start of string")
    func cursorLocationStart() {
        let loc = CursorLocation(position: 0, in: "hello\nworld")
        #expect(loc.line == 1)
        #expect(loc.column == 1)
    }

    @Test("Line and column mid-first line")
    func cursorLocationMidFirstLine() {
        let loc = CursorLocation(position: 3, in: "hello\nworld")
        #expect(loc.line == 1)
        #expect(loc.column == 4)
    }

    @Test("Line and column at newline boundary")
    func cursorLocationAtNewline() {
        let loc = CursorLocation(position: 5, in: "hello\nworld")
        #expect(loc.line == 1)
        #expect(loc.column == 6)
    }

    @Test("Line and column at start of second line")
    func cursorLocationSecondLine() {
        let loc = CursorLocation(position: 6, in: "hello\nworld")
        #expect(loc.line == 2)
        #expect(loc.column == 1)
    }

    @Test("Line and column at end of content")
    func cursorLocationEnd() {
        let loc = CursorLocation(position: 11, in: "hello\nworld")
        #expect(loc.line == 2)
        #expect(loc.column == 6)
    }

    @Test("Line and column with multiple lines")
    func cursorLocationMultipleLines() {
        let content = "line1\nline2\nline3"
        // Position 12 = start of "line3"
        let loc = CursorLocation(position: 12, in: content)
        #expect(loc.line == 3)
        #expect(loc.column == 1)
    }

    @Test("Line and column with CRLF line endings")
    func cursorLocationCRLF() {
        let content = "hello\r\nworld"
        // Position 7 = start of "world"
        let loc = CursorLocation(position: 7, in: content)
        #expect(loc.line == 2)
        #expect(loc.column == 1)
    }

    @Test("Position beyond content length clamps to end")
    func cursorLocationBeyondEnd() {
        let loc = CursorLocation(position: 100, in: "hello")
        #expect(loc.line == 1)
        #expect(loc.column == 6)
    }

    // MARK: - Line ending detection

    @Test("Detect LF line endings")
    func detectLF() {
        let ending = LineEnding.detect(in: "hello\nworld\n")
        #expect(ending == .lf)
    }

    @Test("Detect CRLF line endings")
    func detectCRLF() {
        let ending = LineEnding.detect(in: "hello\r\nworld\r\n")
        #expect(ending == .crlf)
    }

    @Test("Detect mixed defaults to LF")
    func detectMixed() {
        let ending = LineEnding.detect(in: "hello\nworld\r\n")
        #expect(ending == .lf)
    }

    @Test("Empty content defaults to LF")
    func detectEmptyContent() {
        let ending = LineEnding.detect(in: "")
        #expect(ending == .lf)
    }

    @Test("No line endings defaults to LF")
    func detectNoLineEndings() {
        let ending = LineEnding.detect(in: "hello world")
        #expect(ending == .lf)
    }

    @Test("LineEnding display names")
    func lineEndingDisplayName() {
        #expect(LineEnding.lf.displayName == "LF")
        #expect(LineEnding.crlf.displayName == "CRLF")
    }

    // MARK: - Indentation detection

    @Test("Detect spaces indentation")
    func detectSpaces() {
        let content = "func foo() {\n    let x = 1\n    let y = 2\n}"
        let indent = IndentationStyle.detect(in: content)
        #expect(indent == .spaces(4))
    }

    @Test("Detect tab indentation")
    func detectTabs() {
        let content = "func foo() {\n\tlet x = 1\n\tlet y = 2\n}"
        let indent = IndentationStyle.detect(in: content)
        #expect(indent == .tabs)
    }

    @Test("Detect 2-space indentation")
    func detectTwoSpaces() {
        let content = "func foo() {\n  let x = 1\n  let y = 2\n}"
        let indent = IndentationStyle.detect(in: content)
        #expect(indent == .spaces(2))
    }

    @Test("Empty content defaults to spaces 4")
    func detectIndentationEmpty() {
        let indent = IndentationStyle.detect(in: "")
        #expect(indent == .spaces(4))
    }

    @Test("No indentation defaults to spaces 4")
    func detectNoIndentation() {
        let indent = IndentationStyle.detect(in: "hello\nworld")
        #expect(indent == .spaces(4))
    }

    @Test("IndentationStyle display names")
    func indentationDisplayName() {
        #expect(IndentationStyle.spaces(4).displayName == "Spaces: 4")
        #expect(IndentationStyle.spaces(2).displayName == "Spaces: 2")
        #expect(IndentationStyle.tabs.displayName == "Tabs")
    }

    // MARK: - File size formatting

    @Test("Format bytes")
    func formatBytes() {
        #expect(FileSizeFormatter.format(500) == "500 B")
    }

    @Test("Format kilobytes")
    func formatKB() {
        #expect(FileSizeFormatter.format(1_536) == "1.5 KB")
    }

    @Test("Format megabytes")
    func formatMB() {
        #expect(FileSizeFormatter.format(2_621_440) == "2.5 MB")
    }

    @Test("Format zero bytes")
    func formatZero() {
        #expect(FileSizeFormatter.format(0) == "0 B")
    }

    @Test("Format exactly 1 KB")
    func formatExactKB() {
        #expect(FileSizeFormatter.format(1_024) == "1.0 KB")
    }
}
