//
//  BracketHighlightTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct BracketHighlightTests {

    // MARK: - bracketAdjacentToCursor

    @Test func findsOpenBracketBeforeCursor() {
        // "({" — cursor at 1, char before cursor is '('
        let result = BracketMatcher.bracketAdjacentToCursor(in: "(hello)", cursorPosition: 1)
        #expect(result == 0)
    }

    @Test func findsCloseBracketBeforeCursor() {
        let result = BracketMatcher.bracketAdjacentToCursor(in: "(hello)", cursorPosition: 7)
        #expect(result == 6)
    }

    @Test func findsOpenBracketAfterCursor() {
        // cursor at 0, char after is '('
        let result = BracketMatcher.bracketAdjacentToCursor(in: "(hello)", cursorPosition: 0)
        #expect(result == 0)
    }

    @Test func findsCloseBracketAfterCursor() {
        let result = BracketMatcher.bracketAdjacentToCursor(in: "(hello)", cursorPosition: 6)
        #expect(result == 6)
    }

    @Test func noBracketAdjacentToCursor() {
        let result = BracketMatcher.bracketAdjacentToCursor(in: "hello world", cursorPosition: 5)
        #expect(result == nil)
    }

    @Test func noBracketInEmptyString() {
        let result = BracketMatcher.bracketAdjacentToCursor(in: "", cursorPosition: 0)
        #expect(result == nil)
    }

    @Test func skipRangesRespected() {
        // '(' at index 1 is inside skip range
        let result = BracketMatcher.bracketAdjacentToCursor(
            in: "\"(\"",
            cursorPosition: 2,
            skipRanges: [NSRange(location: 0, length: 3)]
        )
        #expect(result == nil)
    }

    @Test func prefersCharBeforeCursor() {
        // ")(", cursor at 1: char before is ')', char after is '('
        let result = BracketMatcher.bracketAdjacentToCursor(in: ")(", cursorPosition: 1)
        #expect(result == 0) // ')' before cursor
    }

    @Test func cursorAtBOFWithBracket() {
        let result = BracketMatcher.bracketAdjacentToCursor(in: "[abc]", cursorPosition: 0)
        #expect(result == 0)
    }

    @Test func cursorAtEOFWithBracket() {
        let result = BracketMatcher.bracketAdjacentToCursor(in: "[abc]", cursorPosition: 5)
        #expect(result == 4)
    }

    @Test func allBracketTypes() {
        for bracket in ["()", "[]", "{}"] {
            let result = BracketMatcher.bracketAdjacentToCursor(in: bracket, cursorPosition: 1)
            #expect(result != nil, "Should find bracket in \(bracket)")
        }
    }

    // MARK: - findHighlight

    @Test func matchedHighlight() {
        let result = BracketMatcher.findHighlight(in: "(hello)", cursorPosition: 1)
        guard case let .matched(match) = result else {
            Issue.record("Expected .matched, got \(String(describing: result))")
            return
        }
        #expect(match.opener == 0)
        #expect(match.closer == 6)
    }

    @Test func unmatchedOpenBracket() {
        let result = BracketMatcher.findHighlight(in: "(hello", cursorPosition: 1)
        guard case let .unmatched(position) = result else {
            Issue.record("Expected .unmatched, got \(String(describing: result))")
            return
        }
        #expect(position == 0)
    }

    @Test func unmatchedCloseBracket() {
        let result = BracketMatcher.findHighlight(in: "hello)", cursorPosition: 6)
        guard case let .unmatched(position) = result else {
            Issue.record("Expected .unmatched, got \(String(describing: result))")
            return
        }
        #expect(position == 5)
    }

    @Test func noHighlightWhenNoBracket() {
        let result = BracketMatcher.findHighlight(in: "hello", cursorPosition: 3)
        #expect(result == nil)
    }

    @Test func unmatchedMismatchedTypes() {
        // "(hello]" — cursor after '(', no matching ')'
        let result = BracketMatcher.findHighlight(in: "(hello]", cursorPosition: 1)
        guard case let .unmatched(position) = result else {
            Issue.record("Expected .unmatched, got \(String(describing: result))")
            return
        }
        #expect(position == 0)
    }

    @Test func cursorBetweenTwoBracketsMatchesFirst() {
        // "}{" — cursor at 1, char before is '}' (unmatched)
        let result = BracketMatcher.findHighlight(in: "}{", cursorPosition: 1)
        guard case let .unmatched(position) = result else {
            Issue.record("Expected .unmatched, got \(String(describing: result))")
            return
        }
        #expect(position == 0)
    }

    @Test func matchedWithSkipRanges() {
        let text = "( \"(\" )"
        let skipRanges = [NSRange(location: 2, length: 3)]
        let result = BracketMatcher.findHighlight(in: text, cursorPosition: 1, skipRanges: skipRanges)
        guard case let .matched(match) = result else {
            Issue.record("Expected .matched, got \(String(describing: result))")
            return
        }
        #expect(match.opener == 0)
        #expect(match.closer == 6)
    }

    @Test func nestedBracketsMatchInnermost() {
        let text = "{foo(bar)}"
        let result = BracketMatcher.findHighlight(in: text, cursorPosition: 5)
        guard case let .matched(match) = result else {
            Issue.record("Expected .matched, got \(String(describing: result))")
            return
        }
        #expect(match.opener == 4)
        #expect(match.closer == 8)
    }

    @Test func highlightAtBOF() {
        let result = BracketMatcher.findHighlight(in: "(hello)", cursorPosition: 0)
        guard case let .matched(match) = result else {
            Issue.record("Expected .matched, got \(String(describing: result))")
            return
        }
        #expect(match.opener == 0)
        #expect(match.closer == 6)
    }

    @Test func highlightAtEOF() {
        let result = BracketMatcher.findHighlight(in: "(hello)", cursorPosition: 7)
        guard case let .matched(match) = result else {
            Issue.record("Expected .matched, got \(String(describing: result))")
            return
        }
        #expect(match.opener == 0)
        #expect(match.closer == 6)
    }

    @Test func emptyFileNoHighlight() {
        let result = BracketMatcher.findHighlight(in: "", cursorPosition: 0)
        #expect(result == nil)
    }

    @Test func fileWithOnlyBrackets() {
        let result = BracketMatcher.findHighlight(in: "()[]{}", cursorPosition: 1)
        guard case let .matched(match) = result else {
            Issue.record("Expected .matched, got \(String(describing: result))")
            return
        }
        #expect(match.opener == 0)
        #expect(match.closer == 1)
    }
}
