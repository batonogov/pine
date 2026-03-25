//
//  IndentGuideRendererTests.swift
//  PineTests
//
//  Created by Claude on 25.03.2026.
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

    // MARK: - Guide x-positions

    @Test("Guide x-positions for 0 levels")
    func xPositionsZeroLevels() {
        let positions = IndentGuideRenderer.guideXPositions(
            maxLevel: 0, indentUnitWidth: 4, charWidth: 8.0, textOriginX: 44.0
        )
        #expect(positions.isEmpty)
    }

    @Test("Guide x-positions for 1 level")
    func xPositionsOneLevel() {
        let positions = IndentGuideRenderer.guideXPositions(
            maxLevel: 1, indentUnitWidth: 4, charWidth: 8.0, textOriginX: 44.0
        )
        #expect(positions.count == 1)
        // 44 + 1*4*8 = 44 + 32 = 76
        #expect(positions[0] == 76.0)
    }

    @Test("Guide x-positions for 3 levels")
    func xPositionsThreeLevels() {
        let positions = IndentGuideRenderer.guideXPositions(
            maxLevel: 3, indentUnitWidth: 4, charWidth: 8.0, textOriginX: 44.0
        )
        #expect(positions.count == 3)
        #expect(positions[0] == 76.0)   // 44 + 1*4*8
        #expect(positions[1] == 108.0)  // 44 + 2*4*8
        #expect(positions[2] == 140.0)  // 44 + 3*4*8
    }

    @Test("Guide x-positions with 2-space indent")
    func xPositionsTwoSpaceIndent() {
        let positions = IndentGuideRenderer.guideXPositions(
            maxLevel: 2, indentUnitWidth: 2, charWidth: 7.5, textOriginX: 40.0
        )
        #expect(positions.count == 2)
        // 40 + 1*2*7.5 = 55
        #expect(positions[0] == 55.0)
        // 40 + 2*2*7.5 = 70
        #expect(positions[1] == 70.0)
    }

    @Test("Guide x-positions with zero indent unit width returns empty")
    func xPositionsZeroIndentUnit() {
        let positions = IndentGuideRenderer.guideXPositions(
            maxLevel: 3, indentUnitWidth: 0, charWidth: 8.0, textOriginX: 44.0
        )
        #expect(positions.isEmpty)
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

    @Test("Effective tab width for tabs is 4")
    func effectiveTabWidthTabs() {
        #expect(IndentGuideRenderer.effectiveTabWidth(from: .tabs) == 4)
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
}
