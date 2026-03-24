//
//  BracketMatcherTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct BracketMatcherTests {

    // MARK: - Basic matching

    @Test func matchesParentheses() {
        let text = "(hello)"
        // Cursor after '(' at position 1
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result?.opener == 0)
        #expect(result?.closer == 6)

        // Cursor before ')' at position 6
        let result2 = BracketMatcher.findMatch(in: text, cursorPosition: 6)
        #expect(result2?.opener == 0)
        #expect(result2?.closer == 6)
    }

    @Test func matchesCurlyBraces() {
        let text = "{hello}"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result?.opener == 0)
        #expect(result?.closer == 6)
    }

    @Test func matchesSquareBrackets() {
        let text = "[hello]"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result?.opener == 0)
        #expect(result?.closer == 6)
    }

    // MARK: - Cursor adjacent to bracket

    @Test func cursorBeforeOpenBracket() {
        let text = "(hello)"
        // Cursor at position 0, character after cursor is '('
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 0)
        #expect(result?.opener == 0)
        #expect(result?.closer == 6)
    }

    @Test func cursorAfterCloseBracket() {
        let text = "(hello)"
        // Cursor at position 7 (after ')'), character before cursor is ')'
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 7)
        #expect(result?.opener == 0)
        #expect(result?.closer == 6)
    }

    // MARK: - Nested brackets

    @Test func matchesNestedBrackets() {
        let text = "{foo(bar)}"
        // Cursor after outer '{'
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result?.opener == 0)
        #expect(result?.closer == 9)

        // Cursor after inner '('
        let result2 = BracketMatcher.findMatch(in: text, cursorPosition: 5)
        #expect(result2?.opener == 4)
        #expect(result2?.closer == 8)
    }

    @Test func matchesDeeplyNested() {
        let text = "({[x]})"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result?.opener == 0)
        #expect(result?.closer == 6)

        let result2 = BracketMatcher.findMatch(in: text, cursorPosition: 2)
        #expect(result2?.opener == 1)
        #expect(result2?.closer == 5)

        let result3 = BracketMatcher.findMatch(in: text, cursorPosition: 3)
        #expect(result3?.opener == 2)
        #expect(result3?.closer == 4)
    }

    // MARK: - No match

    @Test func noMatchWhenCursorNotAdjacentToBracket() {
        let text = "hello world"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 5)
        #expect(result == nil)
    }

    @Test func noMatchForUnmatchedOpen() {
        let text = "(hello"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result == nil)
    }

    @Test func noMatchForUnmatchedClose() {
        let text = "hello)"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 5)
        #expect(result == nil)
    }

    @Test func noMatchForMismatchedTypes() {
        let text = "(hello]"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result == nil)
    }

    // MARK: - Edge cases

    @Test func emptyString() {
        let result = BracketMatcher.findMatch(in: "", cursorPosition: 0)
        #expect(result == nil)
    }

    @Test func cursorAtStartOfFile() {
        let text = "hello()"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 0)
        #expect(result == nil)
    }

    @Test func cursorAtEndOfFile() {
        let text = "()hello"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 7)
        #expect(result == nil)
    }

    @Test func adjacentBrackets() {
        let text = "()"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result?.opener == 0)
        #expect(result?.closer == 1)
    }

    // MARK: - Skip ranges (strings/comments)

    @Test func skipsBracketsInsideSkipRanges() {
        let text = "( \"(\" )"
        // The '(' at index 3 is inside a string (skip range 2...4)
        let skipRanges = [NSRange(location: 2, length: 3)] // covers "(", the inner paren
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1, skipRanges: skipRanges)
        #expect(result?.opener == 0)
        #expect(result?.closer == 6)
    }

    @Test func noMatchWhenCursorBracketIsInsideSkipRange() {
        let text = "\"(\""
        let skipRanges = [NSRange(location: 0, length: 3)]
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 2)
        #expect(result == nil)
    }

    // MARK: - Multiline

    @Test func matchesAcrossLines() {
        let text = "func foo() {\n    return 42\n}"
        // Cursor after '{' at position 12
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 12)
        #expect(result?.opener == 11)
        #expect(result?.closer == 27)
    }

    // MARK: - Priority: character before cursor takes priority

    @Test func characterBeforeCursorTakesPriority() {
        // ")(" — cursor at position 1: char before is ')', char after is '('
        // Should match the ')' (before cursor)
        let text = "()("
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1)
        #expect(result?.opener == 0)
        #expect(result?.closer == 1)
    }

    // MARK: - findHighlight consistency

    @Test func findHighlightReturnsOrphanWhenAdjacentBracketHasNoMatch() {
        // Text: ")()" — cursor at position 1
        // bracketAdjacentToCursor picks ')' at position 0 (before cursor) — orphan
        // findMatch must NOT fall through to '(' at position 1 which has a match
        let text = ")()"
        let result = BracketMatcher.findHighlight(in: text, cursorPosition: 1)
        #expect(result == .unmatched(position: 0))
    }

    @Test func findHighlightReturnsMatchWhenAdjacentBracketHasMatch() {
        let text = "()"
        let result = BracketMatcher.findHighlight(in: text, cursorPosition: 1)
        #expect(result == .matched(BracketMatch(opener: 0, closer: 1)))
    }

    @Test func findHighlightReturnsNilWhenNoBracketAdjacent() {
        let text = "hello"
        let result = BracketMatcher.findHighlight(in: text, cursorPosition: 2)
        #expect(result == nil)
    }

    @Test func findHighlightOrphanOpenBracketBeforeMatchedClose() {
        // Text: "(])" — cursor at position 2
        // bracketAdjacentToCursor picks ']' at position 1 (before cursor) — orphan (no matching '[')
        // '(' at position 0 is not adjacent, ')' at position 2 has match with '(' — but should not be used
        let text = "(])"
        let result = BracketMatcher.findHighlight(in: text, cursorPosition: 2)
        #expect(result == .unmatched(position: 1))
    }

    // MARK: - findMatchForBracket

    @Test func findMatchForBracketAtSpecificPosition() {
        let text = "(hello)"
        let result = BracketMatcher.findMatchForBracket(in: text, at: 0)
        #expect(result?.opener == 0)
        #expect(result?.closer == 6)

        let result2 = BracketMatcher.findMatchForBracket(in: text, at: 6)
        #expect(result2?.opener == 0)
        #expect(result2?.closer == 6)
    }

    @Test func findMatchForBracketReturnsNilForOrphan() {
        let text = "(hello"
        let result = BracketMatcher.findMatchForBracket(in: text, at: 0)
        #expect(result == nil)
    }

    @Test func findMatchForBracketReturnsNilForNonBracket() {
        let text = "hello"
        let result = BracketMatcher.findMatchForBracket(in: text, at: 2)
        #expect(result == nil)
    }

    @Test func findMatchForBracketRespectsSkipRanges() {
        let text = "(\"(\")"
        let skipRanges = [NSRange(location: 1, length: 3)]
        let result = BracketMatcher.findMatchForBracket(in: text, at: 0, skipRanges: skipRanges)
        #expect(result?.opener == 0)
        #expect(result?.closer == 4)
    }

    @Test func findMatchForBracketOutOfBoundsReturnsNil() {
        let text = "()"
        #expect(BracketMatcher.findMatchForBracket(in: text, at: -1) == nil)
        #expect(BracketMatcher.findMatchForBracket(in: text, at: 5) == nil)
    }
}
