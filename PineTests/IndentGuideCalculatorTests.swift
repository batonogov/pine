//
//  IndentGuideCalculatorTests.swift
//  PineTests
//
//  Created by Claude on 21.03.2026.
//

import Testing
@testable import Pine

@Suite("IndentGuideCalculator Tests")
struct IndentGuideCalculatorTests {

    // MARK: - indentLevel(of:style:) — spaces

    @Test("Empty line returns 0 (spaces)")
    func emptyLineSpaces() {
        #expect(IndentGuideCalculator.indentLevel(of: "", style: .spaces(4)) == 0)
    }

    @Test("Whitespace-only line returns 0 (spaces)")
    func whitespaceOnlySpaces() {
        #expect(IndentGuideCalculator.indentLevel(of: "    ", style: .spaces(4)) == 0)
        #expect(IndentGuideCalculator.indentLevel(of: "   \n", style: .spaces(4)) == 0)
    }

    @Test("No indentation returns 0 (spaces)")
    func noIndentSpaces() {
        #expect(IndentGuideCalculator.indentLevel(of: "hello", style: .spaces(4)) == 0)
        #expect(IndentGuideCalculator.indentLevel(of: "func foo() {", style: .spaces(4)) == 0)
    }

    @Test("One indent level (4 spaces)")
    func oneIndentLevel4() {
        #expect(IndentGuideCalculator.indentLevel(of: "    hello", style: .spaces(4)) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: "    return x\n", style: .spaces(4)) == 1)
    }

    @Test("Two indent levels (4 spaces)")
    func twoIndentLevels4() {
        #expect(IndentGuideCalculator.indentLevel(of: "        nested", style: .spaces(4)) == 2)
    }

    @Test("Three indent levels (4 spaces)")
    func threeIndentLevels4() {
        #expect(IndentGuideCalculator.indentLevel(of: "            deep", style: .spaces(4)) == 3)
    }

    @Test("Partial indent is truncated (3 spaces with width 4 → 0)")
    func partialIndentTruncated4() {
        #expect(IndentGuideCalculator.indentLevel(of: "   x", style: .spaces(4)) == 0)
    }

    @Test("Five spaces with width 4 → 1 (integer division)")
    func fiveSpacesWidth4() {
        #expect(IndentGuideCalculator.indentLevel(of: "     x", style: .spaces(4)) == 1)
    }

    @Test("Indent level with width 2")
    func indentWidth2() {
        #expect(IndentGuideCalculator.indentLevel(of: "  x", style: .spaces(2)) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: "    x", style: .spaces(2)) == 2)
        #expect(IndentGuideCalculator.indentLevel(of: "      x", style: .spaces(2)) == 3)
    }

    @Test("Indent level with width 1 (every space is one level)")
    func indentWidth1() {
        #expect(IndentGuideCalculator.indentLevel(of: " x", style: .spaces(1)) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: "  x", style: .spaces(1)) == 2)
        #expect(IndentGuideCalculator.indentLevel(of: "   x", style: .spaces(1)) == 3)
    }

    @Test("Indent level with width 8")
    func indentWidth8() {
        #expect(IndentGuideCalculator.indentLevel(of: "        x", style: .spaces(8)) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: "    x", style: .spaces(8)) == 0)
    }

    // MARK: - indentLevel(of:style:) — tabs

    @Test("Empty line returns 0 (tabs)")
    func emptyLineTabs() {
        #expect(IndentGuideCalculator.indentLevel(of: "", style: .tabs) == 0)
    }

    @Test("Whitespace-only line returns 0 (tabs)")
    func whitespaceOnlyTabs() {
        #expect(IndentGuideCalculator.indentLevel(of: "\t\t", style: .tabs) == 0)
        #expect(IndentGuideCalculator.indentLevel(of: "\t\n", style: .tabs) == 0)
    }

    @Test("No indentation returns 0 (tabs)")
    func noIndentTabs() {
        #expect(IndentGuideCalculator.indentLevel(of: "hello", style: .tabs) == 0)
    }

    @Test("One tab → level 1")
    func oneTab() {
        #expect(IndentGuideCalculator.indentLevel(of: "\thello", style: .tabs) == 1)
    }

    @Test("Two tabs → level 2")
    func twoTabs() {
        #expect(IndentGuideCalculator.indentLevel(of: "\t\thello", style: .tabs) == 2)
    }

    @Test("Three tabs → level 3")
    func threeTabs() {
        #expect(IndentGuideCalculator.indentLevel(of: "\t\t\thello", style: .tabs) == 3)
    }

    @Test("Tab then space does not count extra tab level")
    func tabThenSpace() {
        #expect(IndentGuideCalculator.indentLevel(of: "\t hello", style: .tabs) == 1)
    }

    @Test("Space then tab: space breaks tab counting → 0 tabs")
    func spaceThenTab() {
        #expect(IndentGuideCalculator.indentLevel(of: " \thello", style: .tabs) == 0)
    }

    // MARK: - guideXOffset(level:style:charWidth:)

    @Test("Level 1, spaces(4), charWidth 8 → 32")
    func guideXOffsetSpaces4Level1() {
        let result = IndentGuideCalculator.guideXOffset(level: 1, style: .spaces(4), charWidth: 8)
        #expect(result == 32)
    }

    @Test("Level 2, spaces(4), charWidth 8 → 64")
    func guideXOffsetSpaces4Level2() {
        let result = IndentGuideCalculator.guideXOffset(level: 2, style: .spaces(4), charWidth: 8)
        #expect(result == 64)
    }

    @Test("Level 1, spaces(2), charWidth 8 → 16")
    func guideXOffsetSpaces2Level1() {
        let result = IndentGuideCalculator.guideXOffset(level: 1, style: .spaces(2), charWidth: 8)
        #expect(result == 16)
    }

    @Test("Level 1, tabs, charWidth 8 → 32 (4 visual columns × 8)")
    func guideXOffsetTabsLevel1() {
        let result = IndentGuideCalculator.guideXOffset(
            level: 1, style: .tabs, charWidth: 8
        )
        #expect(result == CGFloat(IndentGuideCalculator.tabVisualWidth) * 8)
    }

    @Test("Level 3, tabs, charWidth 6")
    func guideXOffsetTabsLevel3() {
        let result = IndentGuideCalculator.guideXOffset(level: 3, style: .tabs, charWidth: 6)
        #expect(result == CGFloat(3 * IndentGuideCalculator.tabVisualWidth) * 6)
    }

    @Test("Level 0 returns 0 offset")
    func guideXOffsetLevel0() {
        #expect(IndentGuideCalculator.guideXOffset(level: 0, style: .spaces(4), charWidth: 8) == 0)
    }

    @Test("guideXOffset scales linearly with level")
    func guideXOffsetLinear() {
        let charWidth: CGFloat = 10
        let base = IndentGuideCalculator.guideXOffset(level: 1, style: .spaces(4), charWidth: charWidth)
        #expect(IndentGuideCalculator.guideXOffset(level: 2, style: .spaces(4), charWidth: charWidth) == base * 2)
        #expect(IndentGuideCalculator.guideXOffset(level: 3, style: .spaces(4), charWidth: charWidth) == base * 3)
    }
}
