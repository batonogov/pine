//
//  GoToLineTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

struct GoToLineTests {

    // MARK: - Parser: valid inputs

    @Test func parse_lineOnly() {
        let result = GoToLineParser.parse("42")
        #expect(result?.line == 42)
        #expect(result?.column == nil)
    }

    @Test func parse_lineAndColumn() {
        let result = GoToLineParser.parse("42:10")
        #expect(result?.line == 42)
        #expect(result?.column == 10)
    }

    @Test func parse_trims_whitespace() {
        let result = GoToLineParser.parse("  42  ")
        #expect(result?.line == 42)
        #expect(result?.column == nil)
    }

    @Test func parse_lineOne() {
        let result = GoToLineParser.parse("1")
        #expect(result?.line == 1)
    }

    @Test func parse_lineAndColumnOne() {
        let result = GoToLineParser.parse("1:1")
        #expect(result?.line == 1)
        #expect(result?.column == 1)
    }

    // MARK: - Parser: invalid inputs

    @Test func parse_emptyString_returnsNil() {
        #expect(GoToLineParser.parse("") == nil)
    }

    @Test func parse_whitespaceOnly_returnsNil() {
        #expect(GoToLineParser.parse("   ") == nil)
    }

    @Test func parse_nonNumeric_returnsNil() {
        #expect(GoToLineParser.parse("abc") == nil)
    }

    @Test func parse_zero_returnsNil() {
        #expect(GoToLineParser.parse("0") == nil)
    }

    @Test func parse_negative_returnsNil() {
        #expect(GoToLineParser.parse("-5") == nil)
    }

    @Test func parse_zeroColumn_returnsNil() {
        #expect(GoToLineParser.parse("10:0") == nil)
    }

    @Test func parse_negativeColumn_returnsNil() {
        #expect(GoToLineParser.parse("10:-3") == nil)
    }

    @Test func parse_tooManyParts_returnsNil() {
        #expect(GoToLineParser.parse("1:2:3") == nil)
    }

    @Test func parse_nonNumericColumn_returnsNil() {
        #expect(GoToLineParser.parse("10:abc") == nil)
    }

    @Test func parse_trailingColon_returnsNil() {
        #expect(GoToLineParser.parse("10:") == nil)
    }

    @Test func parse_leadingColon_returnsNil() {
        #expect(GoToLineParser.parse(":10") == nil)
    }

    @Test func parse_float_returnsNil() {
        #expect(GoToLineParser.parse("10.5") == nil)
    }

    // MARK: - Notification name

    @Test func goToLineNotificationName_isDefined() {
        #expect(Notification.Name.goToLine.rawValue == "goToLine")
    }

    // MARK: - Menu icon

    @Test func goToLineMenuIcon_existsAsSFSymbol() {
        #expect(
            NSImage(systemSymbolName: MenuIcons.goToLine, accessibilityDescription: nil) != nil,
            "SF Symbol '\(MenuIcons.goToLine)' for Go to Line does not exist"
        )
    }

    // MARK: - totalLineCount consistency

    @Test func totalLineCount_matchesCursorOffsetLineEnumeration() {
        // Ensure the line counting algorithm matches cursorOffset's line enumeration
        let content = "first\nsecond\nthird"
        let ns = content as NSString
        var count = 1
        var pos = 0
        while pos < ns.length {
            pos = NSMaxRange(ns.lineRange(for: NSRange(location: pos, length: 0)))
            count += 1
        }
        let totalLines = max(1, count - 1)
        #expect(totalLines == 3)

        // Line 3 should be navigable
        let offset = ContentView.cursorOffset(forLine: 3, in: content)
        #expect(offset == 13)
    }

    @Test func totalLineCount_trailingNewline() {
        let content = "first\nsecond\n"
        let ns = content as NSString
        var count = 1
        var pos = 0
        while pos < ns.length {
            pos = NSMaxRange(ns.lineRange(for: NSRange(location: pos, length: 0)))
            count += 1
        }
        let totalLines = max(1, count - 1)
        // "first\nsecond\n" has 2 lines of content, trailing newline doesn't add a navigable line
        #expect(totalLines == 2)
    }

    // MARK: - cursorOffset with column

    @Test func cursorOffset_lineOnly() {
        let content = "first\nsecond\nthird"
        let offset = ContentView.cursorOffset(forLine: 2, in: content)
        #expect(offset == 6) // "second" starts at index 6
    }

    @Test func cursorOffset_withColumn() {
        let content = "first\nsecond\nthird"
        let offset = ContentView.cursorOffset(forLine: 2, column: 4, in: content)
        #expect(offset == 9) // index 6 + 3 (column 4 is 0-based offset 3)
    }

    @Test func cursorOffset_withColumn_one() {
        let content = "first\nsecond\nthird"
        let offset = ContentView.cursorOffset(forLine: 2, column: 1, in: content)
        #expect(offset == 6) // column 1 = start of line
    }

    @Test func cursorOffset_withColumn_clampedToLineEnd() {
        let content = "first\nsecond\nthird"
        // "second" is 6 chars, column 100 should clamp
        let offset = ContentView.cursorOffset(forLine: 2, column: 100, in: content)
        #expect(offset == 12) // end of "second" (index 6 + 6)
    }

    @Test func cursorOffset_lastLine() {
        let content = "first\nsecond\nthird"
        let offset = ContentView.cursorOffset(forLine: 3, in: content)
        #expect(offset == 13) // "third" starts at index 13
    }

    @Test func cursorOffset_beyondLastLine_clampsToEnd() {
        let content = "first\nsecond\nthird"
        let offset = ContentView.cursorOffset(forLine: 10, in: content)
        #expect(offset == (content as NSString).length)
    }
}
