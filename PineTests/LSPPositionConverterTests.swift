//
//  LSPPositionConverterTests.swift
//  PineTests
//
//  Unit tests for LSPPositionConverter — pure logic that maps a UTF-16 offset
//  to an LSP Position (0-based line + character), handling multi-byte chars
//  and CRLF line endings.
//

import Foundation
import Testing

@testable import Pine

@Suite("LSPPositionConverter Tests")
struct LSPPositionConverterTests {

    // MARK: - Empty string

    @Test("Offset 0 in empty string")
    func emptyStringOffsetZero() {
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 0, in: "")
        #expect(pos.line == 0)
        #expect(pos.character == 0)
    }

    // MARK: - Single line

    @Test("Single line, offset at start")
    func singleLineStart() {
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 0, in: "hello world")
        #expect(pos.line == 0)
        #expect(pos.character == 0)
    }

    @Test("Single line, offset at end")
    func singleLineEnd() {
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 5, in: "hello")
        #expect(pos.line == 0)
        #expect(pos.character == 5)
    }

    @Test("Single line, offset in middle")
    func singleLineMiddle() {
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 3, in: "hello")
        #expect(pos.line == 0)
        #expect(pos.character == 3)
    }

    // MARK: - Multi-line (LF)

    @Test("Multi-line, offset on second line")
    func multiLineSecondLine() {
        let text = "line1\nline2"
        // offset 8 → 'n' in "line2" (0-based: l=0,i=1,n=2,e=3,2=4 within line 1)
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 8, in: text)
        #expect(pos.line == 1)
        #expect(pos.character == 2)
    }

    @Test("Multi-line, offset at newline character")
    func multiLineAtNewline() {
        let text = "ab\ncd"
        // offset 2 = '\n'
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 2, in: text)
        #expect(pos.line == 0)
        #expect(pos.character == 2)
    }

    @Test("Multi-line, offset right after newline")
    func multiLineAfterNewline() {
        let text = "ab\ncd"
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 3, in: text)
        #expect(pos.line == 1)
        #expect(pos.character == 0)
    }

    @Test("Three lines, offset on third line")
    func threeLines() {
        let text = "a\nb\nc"
        // offset 4 is immediately before 'c' on line 2.
        let start = LSPPositionConverter.lspPosition(utf16Offset: 4, in: text)
        #expect(start.line == 2)
        #expect(start.character == 0)

        // offset 5 is immediately after 'c', at the end of the document.
        let end = LSPPositionConverter.lspPosition(utf16Offset: 5, in: text)
        #expect(end.line == 2)
        #expect(end.character == 1)
    }

    // MARK: - Multi-byte characters (emoji)

    @Test("Emoji counts as 2 UTF-16 code units")
    func emojiCharacters() {
        let text = "😀abc"
        // NSString length = 5 (2 for emoji surrogate pair + 3 ASCII)
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 3, in: text)
        #expect(pos.line == 0)
        #expect(pos.character == 3)  // 2 (emoji) + 1 (a) = 3
    }

    @Test("Emoji with newline")
    func emojiWithNewline() {
        let text = "😀\nabc"
        // NSString length = 6 (2 emoji + 1 \n + 3 abc)
        // offset 3 = right after \n → start of line 1
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 3, in: text)
        #expect(pos.line == 1)
        #expect(pos.character == 0)
    }

    // MARK: - Multi-byte characters (CJK)

    @Test("CJK characters (1 UTF-16 code unit each)")
    func cjkCharacters() {
        let text = "你好世界"
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 2, in: text)
        #expect(pos.line == 0)
        #expect(pos.character == 2)
    }

    @Test("Mixed ASCII and CJK")
    func mixedAsciiCJK() {
        let text = "abc你好"
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 4, in: text)
        #expect(pos.line == 0)
        #expect(pos.character == 4)  // 3 ASCII + 1 CJK
    }

    // MARK: - CRLF line endings

    @Test("CRLF: CR counted as character on the line")
    func crlfCrCounted() {
        let text = "ab\r\ncd"
        // NSString: a=0, b=1, \r=2, \n=3, c=4, d=5
        // offset 4 = 'c' → line 1, char 0
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 4, in: text)
        #expect(pos.line == 1)
        #expect(pos.character == 0)
    }

    @Test("CRLF: offset at carriage return")
    func crlfAtCR() {
        let text = "ab\r\ncd"
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 2, in: text)
        #expect(pos.line == 0)
        #expect(pos.character == 2)  // a + b
    }

    @Test("CRLF: offset at newline")
    func crlfAtNewline() {
        let text = "ab\r\ncd"
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 3, in: text)
        #expect(pos.line == 0)
        #expect(pos.character == 3)  // \r counted as 1 char
    }

    @Test("CRLF: offset after newline on second line")
    func crlfAfterNewline() {
        let text = "ab\r\ncd"
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 5, in: text)
        #expect(pos.line == 1)
        #expect(pos.character == 1)  // c=0, d=1
    }

    // MARK: - Clamping

    @Test("Offset beyond string length clamps to end")
    func offsetBeyondLength() {
        let pos = LSPPositionConverter.lspPosition(utf16Offset: 100, in: "abc")
        #expect(pos.line == 0)
        #expect(pos.character == 3)
    }

    @Test("Negative offset clamps to 0")
    func negativeOffset() {
        let pos = LSPPositionConverter.lspPosition(utf16Offset: -5, in: "abc")
        #expect(pos.line == 0)
        #expect(pos.character == 0)
    }

    // MARK: - Reverse conversion (line + character → offset)

    @Test("Reverse: line 0 char 0 → offset 0")
    func reverseStart() {
        let offset = LSPPositionConverter.utf16Offset(line: 0, character: 0, in: "abc")
        #expect(offset == 0)
    }

    @Test("Reverse: line 0 char 2 → offset 2")
    func reverseMidSingleLine() {
        let offset = LSPPositionConverter.utf16Offset(line: 0, character: 2, in: "abc")
        #expect(offset == 2)
    }

    @Test("Reverse: line 1 char 0 → offset 3")
    func reverseLine1Char0() {
        let offset = LSPPositionConverter.utf16Offset(line: 1, character: 0, in: "ab\ncd")
        #expect(offset == 3)
    }

    @Test("Reverse: line 1 char 1 → offset 4")
    func reverseLine1Char1() {
        let offset = LSPPositionConverter.utf16Offset(line: 1, character: 1, in: "ab\ncd")
        #expect(offset == 4)
    }

    // MARK: - Round-trip

    @Test("Round-trip: offset → position → offset")
    func roundTrip() {
        let text = "func hello() {\n    print(\"hi\")\n}"
        for offset in 0...text.utf16.count {
            let pos = LSPPositionConverter.lspPosition(utf16Offset: offset, in: text)
            let back = LSPPositionConverter.utf16Offset(line: pos.line, character: pos.character, in: text)
            #expect(back == offset)
        }
    }
}
