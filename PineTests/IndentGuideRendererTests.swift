//
//  IndentGuideRendererTests.swift
//  PineTests
//
//  Created by Fedor Batonogov on 25.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("IndentGuideRenderer Tests")
struct IndentGuideRendererTests {

    // MARK: - Indent level detection

    @Test("Indent level for empty string")
    func indentLevelEmpty() {
        #expect(IndentGuideRenderer.indentLevel(of: "", tabWidth: 4) == 0)
    }

    @Test("Indent level for no indentation")
    func indentLevelNone() {
        #expect(IndentGuideRenderer.indentLevel(of: "hello", tabWidth: 4) == 0)
    }

    @Test("Indent level for 4 spaces")
    func indentLevel4Spaces() {
        #expect(IndentGuideRenderer.indentLevel(of: "    hello", tabWidth: 4) == 4)
    }

    @Test("Indent level for 8 spaces")
    func indentLevel8Spaces() {
        #expect(IndentGuideRenderer.indentLevel(of: "        hello", tabWidth: 4) == 8)
    }

    @Test("Indent level for single tab with tabWidth 4")
    func indentLevelSingleTab() {
        #expect(IndentGuideRenderer.indentLevel(of: "\thello", tabWidth: 4) == 4)
    }

    @Test("Indent level for two tabs with tabWidth 4")
    func indentLevelTwoTabs() {
        #expect(IndentGuideRenderer.indentLevel(of: "\t\thello", tabWidth: 4) == 8)
    }

    @Test("Indent level for mixed spaces and tabs")
    func indentLevelMixed() {
        // 2 spaces + 1 tab(4) = 6 columns
        #expect(IndentGuideRenderer.indentLevel(of: "  \thello", tabWidth: 4) == 6)
    }

    @Test("Indent level for tab with tabWidth 2")
    func indentLevelTabWidth2() {
        #expect(IndentGuideRenderer.indentLevel(of: "\thello", tabWidth: 2) == 2)
    }

    @Test("Indent level for whitespace-only string")
    func indentLevelWhitespaceOnly() {
        #expect(IndentGuideRenderer.indentLevel(of: "    ", tabWidth: 4) == 4)
    }

    @Test("Indent level for 2 spaces")
    func indentLevel2Spaces() {
        #expect(IndentGuideRenderer.indentLevel(of: "  hello", tabWidth: 4) == 2)
    }

    // MARK: - Guide levels calculation

    @Test("Guide levels for 0 columns")
    func guideLevelsZero() {
        #expect(IndentGuideRenderer.guideLevels(columns: 0, indentUnitWidth: 4) == 0)
    }

    @Test("Guide levels for 4 columns with unit 4")
    func guideLevelsOne() {
        #expect(IndentGuideRenderer.guideLevels(columns: 4, indentUnitWidth: 4) == 1)
    }

    @Test("Guide levels for 8 columns with unit 4")
    func guideLevelsTwo() {
        #expect(IndentGuideRenderer.guideLevels(columns: 8, indentUnitWidth: 4) == 2)
    }

    @Test("Guide levels for 6 columns with unit 4 (partial)")
    func guideLevelsPartial() {
        // 6 / 4 = 1 (integer division)
        #expect(IndentGuideRenderer.guideLevels(columns: 6, indentUnitWidth: 4) == 1)
    }

    @Test("Guide levels for 2 columns with unit 2")
    func guideLevelsUnit2() {
        #expect(IndentGuideRenderer.guideLevels(columns: 2, indentUnitWidth: 2) == 1)
    }

    @Test("Guide levels for 8 columns with unit 2")
    func guideLevelsUnit2Multiple() {
        #expect(IndentGuideRenderer.guideLevels(columns: 8, indentUnitWidth: 2) == 4)
    }

    @Test("Guide levels with zero indent unit width")
    func guideLevelsZeroUnit() {
        #expect(IndentGuideRenderer.guideLevels(columns: 8, indentUnitWidth: 0) == 0)
    }

    // MARK: - Indent unit width from style

    @Test("Indent unit width for spaces style")
    func indentUnitWidthSpaces() {
        #expect(IndentGuideRenderer.indentUnitWidth(from: .spaces(4)) == 4)
        #expect(IndentGuideRenderer.indentUnitWidth(from: .spaces(2)) == 2)
    }

    @Test("Indent unit width for tabs style")
    func indentUnitWidthTabs() {
        #expect(IndentGuideRenderer.indentUnitWidth(from: .tabs) == 1)
    }

    // MARK: - Effective tab width

    @Test("Effective tab width for spaces matches indent width")
    func effectiveTabWidthSpaces() {
        #expect(IndentGuideRenderer.effectiveTabWidth(from: .spaces(4)) == 4)
        #expect(IndentGuideRenderer.effectiveTabWidth(from: .spaces(2)) == 2)
    }

    @Test("Effective tab width for tabs defaults to 4")
    func effectiveTabWidthTabsDefault() {
        #expect(IndentGuideRenderer.effectiveTabWidth(from: .tabs) == 4)
    }

    @Test("Effective tab width for tabs with custom render width")
    func effectiveTabWidthTabsCustom() {
        #expect(IndentGuideRenderer.effectiveTabWidth(from: .tabs, renderTabWidth: 8) == 8)
        #expect(IndentGuideRenderer.effectiveTabWidth(from: .tabs, renderTabWidth: 2) == 2)
    }

    // MARK: - Blank line continuation (effectiveLevels)

    @Test("Effective levels for non-blank line returns actual levels")
    func effectiveLevelsNonBlank() {
        let lines = ["func foo() {", "    let x = 1", "}"]
        let levels = IndentGuideRenderer.effectiveLevels(
            forLineAt: 1, lines: lines, tabWidth: 4, indentUnitWidth: 4
        )
        #expect(levels == 1) // 4 columns / 4 unit = 1 level
    }

    @Test("Effective levels for blank line between indented lines")
    func effectiveLevelsBlankBetween() {
        let lines = ["    line1", "", "    line3"]
        let levels = IndentGuideRenderer.effectiveLevels(
            forLineAt: 1, lines: lines, tabWidth: 4, indentUnitWidth: 4
        )
        #expect(levels == 1) // min(1, 1) = 1
    }

    @Test("Effective levels for blank line with different surrounding indents")
    func effectiveLevelsBlankDifferent() {
        let lines = ["        deep", "", "    shallow"]
        let levels = IndentGuideRenderer.effectiveLevels(
            forLineAt: 1, lines: lines, tabWidth: 4, indentUnitWidth: 4
        )
        #expect(levels == 1) // min(2, 1) = 1
    }

    @Test("Effective levels for blank line at start of file")
    func effectiveLevelsBlankAtStart() {
        let lines = ["", "    code"]
        let levels = IndentGuideRenderer.effectiveLevels(
            forLineAt: 0, lines: lines, tabWidth: 4, indentUnitWidth: 4
        )
        #expect(levels == 0) // min(0, 1) = 0, no previous line
    }

    @Test("Effective levels for blank line at end of file")
    func effectiveLevelsBlankAtEnd() {
        let lines = ["    code", ""]
        let levels = IndentGuideRenderer.effectiveLevels(
            forLineAt: 1, lines: lines, tabWidth: 4, indentUnitWidth: 4
        )
        #expect(levels == 0) // min(1, 0) = 0, no next non-blank line
    }

    @Test("Effective levels for multiple consecutive blank lines")
    func effectiveLevelsMultipleBlanks() {
        let lines = ["        deep", "", "", "", "        deep"]
        // All blank lines should get min(2, 2) = 2
        for i in 1...3 {
            let levels = IndentGuideRenderer.effectiveLevels(
                forLineAt: i, lines: lines, tabWidth: 4, indentUnitWidth: 4
            )
            #expect(levels == 2)
        }
    }

    @Test("Effective levels for blank line between unindented lines")
    func effectiveLevelsBlankNoIndent() {
        let lines = ["top", "", "bottom"]
        let levels = IndentGuideRenderer.effectiveLevels(
            forLineAt: 1, lines: lines, tabWidth: 4, indentUnitWidth: 4
        )
        #expect(levels == 0)
    }

    @Test("Effective levels with zero indent unit width returns 0")
    func effectiveLevelsZeroUnit() {
        let lines = ["    code"]
        let levels = IndentGuideRenderer.effectiveLevels(
            forLineAt: 0, lines: lines, tabWidth: 4, indentUnitWidth: 0
        )
        #expect(levels == 0)
    }

    @Test("Effective levels with out-of-bounds index returns 0")
    func effectiveLevelsOutOfBounds() {
        let lines = ["code"]
        #expect(IndentGuideRenderer.effectiveLevels(
            forLineAt: -1, lines: lines, tabWidth: 4, indentUnitWidth: 4
        ) == 0)
        #expect(IndentGuideRenderer.effectiveLevels(
            forLineAt: 5, lines: lines, tabWidth: 4, indentUnitWidth: 4
        ) == 0)
    }

    // MARK: - Edge cases

    @Test("Indent level with only newline character")
    func indentLevelNewline() {
        #expect(IndentGuideRenderer.indentLevel(of: "\n", tabWidth: 4) == 0)
    }

    @Test("Indent level with spaces then newline")
    func indentLevelSpacesNewline() {
        #expect(IndentGuideRenderer.indentLevel(of: "    \n", tabWidth: 4) == 4)
    }

    @Test("Guide levels for very deep nesting")
    func guideLevelsDeepNesting() {
        // 40 columns with indent unit 4 = 10 levels
        let columns = IndentGuideRenderer.indentLevel(
            of: "                                        code", tabWidth: 4
        )
        #expect(columns == 40)
        #expect(IndentGuideRenderer.guideLevels(columns: columns, indentUnitWidth: 4) == 10)
    }

    @Test("Indent level stops at first non-whitespace")
    func indentLevelStopsAtContent() {
        #expect(IndentGuideRenderer.indentLevel(of: "  hello  world", tabWidth: 4) == 2)
    }

    @Test("Effective levels for whitespace-only line treated as blank")
    func effectiveLevelsWhitespaceOnly() {
        let lines = ["    code", "   ", "    code"]
        let levels = IndentGuideRenderer.effectiveLevels(
            forLineAt: 1, lines: lines, tabWidth: 4, indentUnitWidth: 4
        )
        #expect(levels == 1) // whitespace-only treated as blank, min(1,1) = 1
    }

    @Test("Guide segment struct stores correct values")
    func guideSegmentValues() {
        let segment = IndentGuideRenderer.GuideSegment(x: 10.0, y: 20.0, height: 15.0)
        #expect(segment.x == 10.0)
        #expect(segment.y == 20.0)
        #expect(segment.height == 15.0)
    }

    // MARK: - Guide X position (guideXOffset)

    @Test("guideXOffset for spaces uses charWidth * level * indentUnit")
    func guideXOffsetSpaces() {
        let charWidth: CGFloat = 7.8
        // .spaces(4): level 1 -> 1 * 4 * 7.8 = 31.2
        let x1 = IndentGuideRenderer.guideXOffset(
            level: 1, style: .spaces(4), charWidth: charWidth, tabStopWidth: 28
        )
        #expect(x1 == 31.2)

        // .spaces(4): level 2 -> 2 * 4 * 7.8 = 62.4
        let x2 = IndentGuideRenderer.guideXOffset(
            level: 2, style: .spaces(4), charWidth: charWidth, tabStopWidth: 28
        )
        #expect(x2 == 62.4)
    }

    @Test("guideXOffset for spaces with indent unit 2")
    func guideXOffsetSpacesUnit2() {
        let charWidth: CGFloat = 8.0
        // .spaces(2): level 1 -> 1 * 2 * 8.0 = 16.0
        let offset = IndentGuideRenderer.guideXOffset(
            level: 1, style: .spaces(2), charWidth: charWidth, tabStopWidth: 28
        )
        #expect(offset == 16.0)
    }

    @Test("guideXOffset for tabs uses tabStopWidth, not charWidth")
    func guideXOffsetTabs() {
        let charWidth: CGFloat = 7.8
        let tabStopWidth: CGFloat = 28.0

        // .tabs: level 1 -> 1 * 28.0 = 28.0 (not 1 * 1 * 7.8)
        let x1 = IndentGuideRenderer.guideXOffset(
            level: 1, style: .tabs, charWidth: charWidth, tabStopWidth: tabStopWidth
        )
        #expect(x1 == 28.0)

        // .tabs: level 2 -> 2 * 28.0 = 56.0
        let x2 = IndentGuideRenderer.guideXOffset(
            level: 2, style: .tabs, charWidth: charWidth, tabStopWidth: tabStopWidth
        )
        #expect(x2 == 56.0)

        // .tabs: level 3 -> 3 * 28.0 = 84.0
        let x3 = IndentGuideRenderer.guideXOffset(
            level: 3, style: .tabs, charWidth: charWidth, tabStopWidth: tabStopWidth
        )
        #expect(x3 == 84.0)
    }

    @Test("guideXOffset for tabs with custom tab stop width")
    func guideXOffsetTabsCustomWidth() {
        let offset = IndentGuideRenderer.guideXOffset(
            level: 2, style: .tabs, charWidth: 7.8, tabStopWidth: 32.0
        )
        #expect(offset == 64.0)
    }

    @Test("guideXOffset tabs vs spaces produce different results for typical settings")
    func guideXOffsetTabsVsSpaces() {
        let charWidth: CGFloat = 7.8
        let tabStopWidth: CGFloat = 28.0

        let tabX = IndentGuideRenderer.guideXOffset(
            level: 1, style: .tabs, charWidth: charWidth, tabStopWidth: tabStopWidth
        )
        let spaceX = IndentGuideRenderer.guideXOffset(
            level: 1, style: .spaces(4), charWidth: charWidth, tabStopWidth: tabStopWidth
        )
        // Tab guide at 28pt, space guide at 31.2pt
        #expect(tabX != spaceX)
        #expect(tabX == 28.0)
        #expect(spaceX == 31.2)
    }

    @Test("guideXOffset for Go-style tab indentation matches real tab stops")
    func guideXOffsetGoStyle() {
        // Go uses real tabs. NSTextView default tab interval = 28pt.
        // Old buggy code would compute: level * 1 * 7.8 = 7.8pt (wrong)
        // Fixed code computes: level * 28.0 = 28.0pt (correct)
        let charWidth: CGFloat = 7.8
        let tabStopWidth: CGFloat = 28.0

        let guides = (1...3).map { level in
            IndentGuideRenderer.guideXOffset(
                level: level, style: .tabs, charWidth: charWidth, tabStopWidth: tabStopWidth
            )
        }
        #expect(guides == [28.0, 56.0, 84.0])
    }

    @Test("guideXOffset evenly spaced for both styles")
    func guideXOffsetEvenlySpaced() {
        let charWidth: CGFloat = 8.0
        let tabStopWidth: CGFloat = 32.0

        // Tab file: guides at 32, 64, 96
        let tabGuides = (1...3).map {
            IndentGuideRenderer.guideXOffset(
                level: $0, style: .tabs, charWidth: charWidth, tabStopWidth: tabStopWidth
            )
        }
        #expect(tabGuides == [32.0, 64.0, 96.0])

        // Space file (4-space indent, 8pt char): guides also at 32, 64, 96
        let spaceGuides = (1...3).map {
            IndentGuideRenderer.guideXOffset(
                level: $0, style: .spaces(4), charWidth: charWidth, tabStopWidth: tabStopWidth
            )
        }
        #expect(spaceGuides == [32.0, 64.0, 96.0])
    }
}
