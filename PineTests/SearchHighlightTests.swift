//
//  SearchHighlightTests.swift
//  PineTests
//
//  Created by Claude on 27.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("Search Highlight Offset Tests")
@MainActor
struct SearchHighlightTests {

    // MARK: - Helpers

    private func createTestFile(content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineSearchHighlightTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("test.txt")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func cleanup(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Validates that matchRangeStart/matchRangeLength correctly index into lineContent.
    private func validateHighlight(_ match: SearchMatch, expectedSubstring: String) {
        let utf16 = match.lineContent.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: match.matchRangeStart)
        let end = utf16.index(start, offsetBy: match.matchRangeLength)
        let highlighted = String(match.lineContent[start..<end])
        #expect(highlighted == expectedSubstring,
                "Expected '\(expectedSubstring)' but got '\(highlighted)' at offset \(match.matchRangeStart) in '\(match.lineContent)'")
    }

    // MARK: - Leading whitespace trimming

    @Test("Match offset adjusts for trimmed leading whitespace")
    func matchOffsetAdjustsForTrimmedLeadingWhitespace() throws {
        let file = try createTestFile(content: "    hello world")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "hello", isCaseSensitive: true)

        #expect(matches.count == 1)
        #expect(matches[0].lineContent == "hello world")
        validateHighlight(matches[0], expectedSubstring: "hello")
    }

    @Test("Match offset adjusts for tab-indented lines")
    func matchOffsetAdjustsForTabIndentation() throws {
        let file = try createTestFile(content: "\t\thello world")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "hello", isCaseSensitive: true)

        #expect(matches.count == 1)
        validateHighlight(matches[0], expectedSubstring: "hello")
    }

    @Test("Match offset correct when no leading whitespace")
    func matchOffsetCorrectNoLeadingWhitespace() throws {
        let file = try createTestFile(content: "hello world")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "world", isCaseSensitive: true)

        #expect(matches.count == 1)
        validateHighlight(matches[0], expectedSubstring: "world")
    }

    // MARK: - Multiple matches on same line

    @Test("Multiple matches on same line have correct offsets")
    func multipleMatchesSameLineCorrectOffsets() throws {
        let file = try createTestFile(content: "foo bar foo baz foo")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "foo", isCaseSensitive: true)

        #expect(matches.count == 3)
        for match in matches {
            validateHighlight(match, expectedSubstring: "foo")
        }

        // Verify distinct offsets
        #expect(matches[0].matchRangeStart == 0)
        #expect(matches[1].matchRangeStart == 8)
        #expect(matches[2].matchRangeStart == 16)
    }

    @Test("Multiple matches on indented line have correct offsets")
    func multipleMatchesIndentedLine() throws {
        let file = try createTestFile(content: "    foo bar foo baz foo")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "foo", isCaseSensitive: true)

        #expect(matches.count == 3)
        // After trimming, lineContent is "foo bar foo baz foo"
        #expect(matches[0].matchRangeStart == 0)
        #expect(matches[1].matchRangeStart == 8)
        #expect(matches[2].matchRangeStart == 16)

        for match in matches {
            validateHighlight(match, expectedSubstring: "foo")
        }
    }

    // MARK: - Second match highlighting (core bug scenario)

    @Test("Second occurrence on a line is highlighted, not the first")
    func secondOccurrenceHighlighted() throws {
        let file = try createTestFile(content: "abc abc")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "abc", isCaseSensitive: true)

        #expect(matches.count == 2)
        // Second match should point to offset 4, not 0
        #expect(matches[1].matchRangeStart == 4)
        validateHighlight(matches[1], expectedSubstring: "abc")
    }

    // MARK: - Unicode: Cyrillic

    @Test("Match offset correct for Cyrillic text with leading spaces")
    func cyrillicWithLeadingSpaces() throws {
        let file = try createTestFile(content: "    Привет мир")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "мир", isCaseSensitive: true)

        #expect(matches.count == 1)
        validateHighlight(matches[0], expectedSubstring: "мир")
    }

    @Test("Multiple Cyrillic matches on same line")
    func multipleCyrillicMatches() throws {
        let file = try createTestFile(content: "кот и кот и кот")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "кот", isCaseSensitive: true)

        #expect(matches.count == 3)
        for match in matches {
            validateHighlight(match, expectedSubstring: "кот")
        }
    }

    // MARK: - Unicode: Emoji (UTF-16 surrogates)

    @Test("Match offset correct for emoji in text")
    func emojiInText() throws {
        let file = try createTestFile(content: "before 🌲 after 🌲 end")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "🌲", isCaseSensitive: true)

        #expect(matches.count == 2)
        for match in matches {
            validateHighlight(match, expectedSubstring: "🌲")
        }
    }

    @Test("Match after emoji has correct offset (emoji is 2 UTF-16 units)")
    func matchAfterEmoji() throws {
        let file = try createTestFile(content: "🎉hello")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "hello", isCaseSensitive: true)

        #expect(matches.count == 1)
        // 🎉 is 2 UTF-16 code units, so "hello" starts at offset 2
        #expect(matches[0].matchRangeStart == 2)
        validateHighlight(matches[0], expectedSubstring: "hello")
    }

    @Test("Match between emojis")
    func matchBetweenEmojis() throws {
        let file = try createTestFile(content: "🔥target🔥")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "target", isCaseSensitive: true)

        #expect(matches.count == 1)
        validateHighlight(matches[0], expectedSubstring: "target")
    }

    @Test("Match offset with compound emoji (family emoji)")
    func compoundEmoji() throws {
        // 👨‍👩‍👧‍👦 is a ZWJ sequence: multiple code points joined
        let file = try createTestFile(content: "👨‍👩‍👧‍👦 find me")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "find", isCaseSensitive: true)

        #expect(matches.count == 1)
        validateHighlight(matches[0], expectedSubstring: "find")
    }

    // MARK: - Unicode: CJK

    @Test("CJK characters with leading whitespace")
    func cjkWithLeadingWhitespace() throws {
        let file = try createTestFile(content: "  你好世界你好")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "你好", isCaseSensitive: true)

        #expect(matches.count == 2)
        for match in matches {
            validateHighlight(match, expectedSubstring: "你好")
        }
        // After trimming: "你好世界你好"
        // First at 0, second at 4 (each CJK char is 1 UTF-16 unit)
        #expect(matches[0].matchRangeStart == 0)
        #expect(matches[1].matchRangeStart == 4)
    }

    // MARK: - Case-insensitive search

    @Test("Case-insensitive match offset is correct")
    func caseInsensitiveOffset() throws {
        let file = try createTestFile(content: "Hello HELLO hello")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "hello", isCaseSensitive: false)

        #expect(matches.count == 3)
        // Validate each match highlights the actual text at that position
        let utf16 = matches[0].lineContent.utf16
        let s0 = utf16.index(utf16.startIndex, offsetBy: matches[0].matchRangeStart)
        let e0 = utf16.index(s0, offsetBy: matches[0].matchRangeLength)
        #expect(String(matches[0].lineContent[s0..<e0]) == "Hello")

        let s1 = utf16.index(utf16.startIndex, offsetBy: matches[1].matchRangeStart)
        let e1 = utf16.index(s1, offsetBy: matches[1].matchRangeLength)
        #expect(String(matches[1].lineContent[s1..<e1]) == "HELLO")

        let s2 = utf16.index(utf16.startIndex, offsetBy: matches[2].matchRangeStart)
        let e2 = utf16.index(s2, offsetBy: matches[2].matchRangeLength)
        #expect(String(matches[2].lineContent[s2..<e2]) == "hello")
    }

    // MARK: - Edge cases

    @Test("Empty line produces no matches")
    func emptyLine() throws {
        let file = try createTestFile(content: "\n\n\n")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "x", isCaseSensitive: true)
        #expect(matches.isEmpty)
    }

    @Test("Line that is entirely whitespace produces no matches for non-whitespace query")
    func whitespaceOnlyLine() throws {
        let file = try createTestFile(content: "     ")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "x", isCaseSensitive: true)
        #expect(matches.isEmpty)
    }

    @Test("Match at start of line with no whitespace")
    func matchAtStartNoWhitespace() throws {
        let file = try createTestFile(content: "target rest of line")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "target", isCaseSensitive: true)

        #expect(matches.count == 1)
        #expect(matches[0].matchRangeStart == 0)
        validateHighlight(matches[0], expectedSubstring: "target")
    }

    @Test("Match at end of line")
    func matchAtEndOfLine() throws {
        let file = try createTestFile(content: "start middle target")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "target", isCaseSensitive: true)

        #expect(matches.count == 1)
        validateHighlight(matches[0], expectedSubstring: "target")
    }

    @Test("Entire line is the match")
    func entireLineIsMatch() throws {
        let file = try createTestFile(content: "  exactmatch  ")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "exactmatch", isCaseSensitive: true)

        #expect(matches.count == 1)
        #expect(matches[0].matchRangeStart == 0)
        #expect(matches[0].lineContent == "exactmatch")
        validateHighlight(matches[0], expectedSubstring: "exactmatch")
    }

    @Test("Mixed whitespace (spaces and tabs) trimmed correctly")
    func mixedWhitespaceTrimming() throws {
        let file = try createTestFile(content: " \t \thello")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "hello", isCaseSensitive: true)

        #expect(matches.count == 1)
        #expect(matches[0].matchRangeStart == 0)
        #expect(matches[0].lineContent == "hello")
        validateHighlight(matches[0], expectedSubstring: "hello")
    }

    // MARK: - UTF-16 surrogate pairs

    @Test("Match offset correct with flag emoji (4 UTF-16 units)")
    func flagEmoji() throws {
        // Flag emojis are two regional indicator symbols, each 2 UTF-16 units = 4 total
        let file = try createTestFile(content: "🇺🇸 flag test")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "flag", isCaseSensitive: true)

        #expect(matches.count == 1)
        validateHighlight(matches[0], expectedSubstring: "flag")
    }

    @Test("Search for emoji that uses surrogate pairs")
    func searchForSurrogatePairEmoji() throws {
        let file = try createTestFile(content: "a 🌲 b 🌲 c")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "🌲", isCaseSensitive: true)

        #expect(matches.count == 2)
        for match in matches {
            validateHighlight(match, expectedSubstring: "🌲")
        }
    }

    // MARK: - Regression: line content prefix limit does not break offsets

    @Test("Match near prefix limit boundary still validates")
    func matchNearPrefixLimit() throws {
        // 190 chars + "FIND" + remaining = match is within 200-char prefix
        let prefix = String(repeating: "x", count: 190)
        let file = try createTestFile(content: prefix + "FIND rest")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "FIND", isCaseSensitive: true)

        #expect(matches.count == 1)
        // Match at offset 190 is within 200-char display prefix
        validateHighlight(matches[0], expectedSubstring: "FIND")
    }

    @Test("Match beyond prefix limit has offset outside display content")
    func matchBeyondPrefixLimit() throws {
        // Match starts at offset 210 — beyond 200-char prefix
        let prefix = String(repeating: "x", count: 210)
        let file = try createTestFile(content: prefix + "FIND rest")
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "FIND", isCaseSensitive: true)

        #expect(matches.count == 1)
        // matchRangeStart is 210, but lineContent is only 200 chars
        // The UI should gracefully handle this (fallback to plain text)
        #expect(matches[0].matchRangeStart == 210)
        #expect(matches[0].lineContent.count == 200)
    }

    // MARK: - Multiline file, multiple lines with multiple matches

    @Test("Multiple lines with multiple matches all have correct offsets")
    func multipleLineMultipleMatches() throws {
        let content = """
        first foo and foo
            second foo bar foo
        foo
        """
        let file = try createTestFile(content: content)
        defer { cleanup(file) }

        let matches = ProjectSearchProvider.searchFile(at: file, query: "foo", isCaseSensitive: true)

        // Line 1: "first foo and foo" (no leading whitespace) -> 2 matches
        // Line 2: "    second foo bar foo" -> trimmed to "second foo bar foo" -> 2 matches
        // Line 3: "foo" -> 1 match
        #expect(matches.count == 5)

        for match in matches {
            validateHighlight(match, expectedSubstring: "foo")
        }
    }
}
