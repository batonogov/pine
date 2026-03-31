//
//  IndentGuideCalculatorTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

/// Tests for IndentGuideCalculator — pure indent level and guide position logic.
@MainActor
struct IndentGuideCalculatorTests {

    // MARK: - indentLevel: Tab-only indentation

    @Test func indentLevel_singleTab() {
        let level = IndentGuideCalculator.indentLevel(of: "\tfoo", indentWidth: 4)
        #expect(level == 1)
    }

    @Test func indentLevel_twoTabs() {
        let level = IndentGuideCalculator.indentLevel(of: "\t\tbar", indentWidth: 4)
        #expect(level == 2)
    }

    @Test func indentLevel_fiveTabs() {
        let level = IndentGuideCalculator.indentLevel(of: "\t\t\t\t\tbaz", indentWidth: 4)
        #expect(level == 5)
    }

    @Test func indentLevel_tabOnlyLine() {
        // Line with only a tab and no content
        let level = IndentGuideCalculator.indentLevel(of: "\t", indentWidth: 4)
        #expect(level == 1)
    }

    @Test func indentLevel_multipleTabs_noContent() {
        let level = IndentGuideCalculator.indentLevel(of: "\t\t\t", indentWidth: 4)
        #expect(level == 3)
    }

    // MARK: - indentLevel: Space-only indentation

    @Test func indentLevel_fourSpaces() {
        let level = IndentGuideCalculator.indentLevel(of: "    code", indentWidth: 4)
        #expect(level == 1)
    }

    @Test func indentLevel_eightSpaces() {
        let level = IndentGuideCalculator.indentLevel(of: "        code", indentWidth: 4)
        #expect(level == 2)
    }

    @Test func indentLevel_twoSpaces_indentWidth2() {
        let level = IndentGuideCalculator.indentLevel(of: "  code", indentWidth: 2)
        #expect(level == 1)
    }

    @Test func indentLevel_sixSpaces_indentWidth2() {
        let level = IndentGuideCalculator.indentLevel(of: "      code", indentWidth: 2)
        #expect(level == 3)
    }

    @Test func indentLevel_threeSpaces_indentWidth4_roundsDown() {
        // 3 spaces with indentWidth 4 → 0 full levels
        let level = IndentGuideCalculator.indentLevel(of: "   code", indentWidth: 4)
        #expect(level == 0)
    }

    @Test func indentLevel_fiveSpaces_indentWidth4_roundsDown() {
        // 5 spaces with indentWidth 4 → 1 full level (4 spaces = 1, 1 space remainder)
        let level = IndentGuideCalculator.indentLevel(of: "     code", indentWidth: 4)
        #expect(level == 1)
    }

    // MARK: - indentLevel: Mixed tabs + spaces

    @Test func indentLevel_tabPlusSpaces() {
        // 1 tab + 4 spaces = 1 (tab) + 1 (4 spaces / 4) = 2
        let level = IndentGuideCalculator.indentLevel(of: "\t    code", indentWidth: 4)
        #expect(level == 2)
    }

    @Test func indentLevel_tabPlusTwoSpaces_indentWidth4() {
        // 1 tab + 2 spaces = 1 + 0 = 1 (2 spaces < 4)
        let level = IndentGuideCalculator.indentLevel(of: "\t  code", indentWidth: 4)
        #expect(level == 1)
    }

    @Test func indentLevel_twoTabsPlusTwoSpaces_indentWidth2() {
        // 2 tabs + 2 spaces = 2 + 1 = 3
        let level = IndentGuideCalculator.indentLevel(of: "\t\t  code", indentWidth: 2)
        #expect(level == 3)
    }

    // MARK: - indentLevel: No indentation

    @Test func indentLevel_noIndent() {
        let level = IndentGuideCalculator.indentLevel(of: "code", indentWidth: 4)
        #expect(level == 0)
    }

    @Test func indentLevel_emptyString() {
        let level = IndentGuideCalculator.indentLevel(of: "", indentWidth: 4)
        #expect(level == 0)
    }

    // MARK: - indentLevel: Edge cases

    @Test func indentLevel_indentWidthZero_returnsZero() {
        // Prevents division by zero
        let level = IndentGuideCalculator.indentLevel(of: "    code", indentWidth: 0)
        #expect(level == 0)
    }

    @Test func indentLevel_whitespaceOnlyLine() {
        // All spaces, no actual content
        let level = IndentGuideCalculator.indentLevel(of: "        ", indentWidth: 4)
        #expect(level == 2)
    }

    @Test func indentLevel_tabsOnlyLine() {
        let level = IndentGuideCalculator.indentLevel(of: "\t\t\t\t", indentWidth: 4)
        #expect(level == 4)
    }

    @Test func indentLevel_indentWidth8() {
        let level = IndentGuideCalculator.indentLevel(of: "        code", indentWidth: 8)
        #expect(level == 1)
    }

    @Test func indentLevel_deepNesting_spaces() {
        let line = String(repeating: "    ", count: 10) + "deeply_nested()"
        let level = IndentGuideCalculator.indentLevel(of: line, indentWidth: 4)
        #expect(level == 10)
    }

    @Test func indentLevel_deepNesting_tabs() {
        let line = String(repeating: "\t", count: 10) + "deeply_nested()"
        let level = IndentGuideCalculator.indentLevel(of: line, indentWidth: 4)
        #expect(level == 10)
    }

    // MARK: - guides: Tab-based

    @Test func guides_tabBased_level1() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 1, charWidth: 7.0, tabStopWidth: 28.0,
            usesTabs: true, indentWidth: 4
        )
        #expect(guides.count == 1)
        #expect(guides[0].level == 1)
        #expect(guides[0].xPosition == 28.0) // 1 * tabStopWidth
    }

    @Test func guides_tabBased_level3() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 3, charWidth: 7.0, tabStopWidth: 28.0,
            usesTabs: true, indentWidth: 4
        )
        #expect(guides.count == 3)
        #expect(guides[0].xPosition == 28.0)
        #expect(guides[1].xPosition == 56.0)
        #expect(guides[2].xPosition == 84.0)
    }

    @Test func guides_tabBased_usesTabStopWidth_notCharWidth() {
        // Key bug fix: tab guides must use tabStopWidth, not charWidth * indentWidth
        let charWidth: CGFloat = 7.0
        let tabStopWidth: CGFloat = 28.0
        let guides = IndentGuideCalculator.guides(
            forLevel: 2, charWidth: charWidth, tabStopWidth: tabStopWidth,
            usesTabs: true, indentWidth: 4
        )
        // Must be 28 and 56, NOT 28 (7*4) and 56 (7*4*2) — same in this case, but
        // the key point is that tabStopWidth is independent of charWidth * indentWidth
        #expect(guides[0].xPosition == tabStopWidth)
        #expect(guides[1].xPosition == tabStopWidth * 2)
    }

    @Test func guides_tabBased_customTabStop() {
        // Tab stop at 32pt (not the standard 28pt)
        let guides = IndentGuideCalculator.guides(
            forLevel: 2, charWidth: 7.0, tabStopWidth: 32.0,
            usesTabs: true, indentWidth: 4
        )
        #expect(guides[0].xPosition == 32.0)
        #expect(guides[1].xPosition == 64.0)
    }

    // MARK: - guides: Space-based

    @Test func guides_spaceBased_level1_indent4() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 1, charWidth: 7.0, tabStopWidth: 28.0,
            usesTabs: false, indentWidth: 4
        )
        #expect(guides.count == 1)
        #expect(guides[0].xPosition == 28.0) // 1 * 4 * 7.0
    }

    @Test func guides_spaceBased_level2_indent2() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 2, charWidth: 7.0, tabStopWidth: 28.0,
            usesTabs: false, indentWidth: 2
        )
        #expect(guides.count == 2)
        #expect(guides[0].xPosition == 14.0) // 1 * 2 * 7.0
        #expect(guides[1].xPosition == 28.0) // 2 * 2 * 7.0
    }

    @Test func guides_spaceBased_differentCharWidth() {
        // Larger font → wider charWidth
        let guides = IndentGuideCalculator.guides(
            forLevel: 1, charWidth: 9.5, tabStopWidth: 38.0,
            usesTabs: false, indentWidth: 4
        )
        #expect(guides[0].xPosition == 38.0) // 1 * 4 * 9.5
    }

    // MARK: - guides: Edge cases

    @Test func guides_levelZero_returnsEmpty() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 0, charWidth: 7.0, tabStopWidth: 28.0,
            usesTabs: true, indentWidth: 4
        )
        #expect(guides.isEmpty)
    }

    @Test func guides_charWidthZero_returnsEmpty() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 2, charWidth: 0.0, tabStopWidth: 28.0,
            usesTabs: false, indentWidth: 4
        )
        #expect(guides.isEmpty)
    }

    @Test func guides_negativeLevelReturnsEmpty() {
        let guides = IndentGuideCalculator.guides(
            forLevel: -1, charWidth: 7.0, tabStopWidth: 28.0,
            usesTabs: true, indentWidth: 4
        )
        #expect(guides.isEmpty)
    }

    // MARK: - inheritedIndentLevel: Blank line inheritance

    @Test func inheritedIndent_blankBetweenIndentedLines() {
        let lines = [
            "    func foo() {",
            "",
            "    }"
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level == 1) // min(1, 1) = 1
    }

    @Test func inheritedIndent_blankBetweenDifferentLevels() {
        let lines = [
            "        deep",
            "",
            "    shallow"
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level == 1) // min(2, 1) = 1
    }

    @Test func inheritedIndent_blankAtStart() {
        let lines = [
            "",
            "    code"
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 0, in: lines, indentWidth: 4
        )
        #expect(level == 0) // above = 0 (no lines above), below = 1 → min(0,1) = 0
    }

    @Test func inheritedIndent_blankAtEnd() {
        let lines = [
            "    code",
            ""
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level == 0) // above = 1, below = 0 (no lines below) → min(1,0) = 0
    }

    @Test func inheritedIndent_multipleBlankLines() {
        let lines = [
            "        deep",
            "",
            "",
            "",
            "        deep"
        ]
        // Middle blank line
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 2, in: lines, indentWidth: 4
        )
        #expect(level == 2) // min(2, 2) = 2
    }

    @Test func inheritedIndent_blankSurroundedByNoIndent() {
        let lines = [
            "top",
            "",
            "bottom"
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level == 0) // min(0, 0) = 0
    }

    @Test func inheritedIndent_tabIndentedContext() {
        let lines = [
            "\t\tfunc body() {",
            "",
            "\t\t}"
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level == 2) // min(2, 2) = 2
    }

    @Test func inheritedIndent_whitespaceOnlyLineTreatedAsBlank() {
        // A line with only spaces is treated as blank by trimmingCharacters
        let lines = [
            "        deep",
            "   ",  // whitespace-only, treated as blank
            "        deep"
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level == 2)
    }

    @Test func inheritedIndent_indentWidthZero_returnsZero() {
        let lines = ["    code", "", "    code"]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 0
        )
        #expect(level == 0)
    }

    @Test func inheritedIndent_allBlankLines() {
        let lines = ["", "", ""]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level == 0)
    }

    // MARK: - IndentGuide struct

    @Test func indentGuide_equatable() {
        let a = IndentGuide(level: 1, xPosition: 28.0)
        let b = IndentGuide(level: 1, xPosition: 28.0)
        let c = IndentGuide(level: 2, xPosition: 56.0)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Real-world scenarios

    @Test func goFile_tabIndented() {
        // Typical Go file with tab indentation
        let lines = [
            "package main",           // level 0
            "",                        // inherited: 0
            "func main() {",          // level 0
            "\tfmt.Println(\"hello\")", // level 1
            "\tif true {",            // level 1
            "\t\tfmt.Println(\"deep\")", // level 2
            "\t}",                    // level 1
            "}"                       // level 0
        ]
        #expect(IndentGuideCalculator.indentLevel(of: lines[0], indentWidth: 4) == 0)
        #expect(IndentGuideCalculator.indentLevel(of: lines[3], indentWidth: 4) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[4], indentWidth: 4) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[5], indentWidth: 4) == 2)
        #expect(IndentGuideCalculator.indentLevel(of: lines[6], indentWidth: 4) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[7], indentWidth: 4) == 0)
    }

    @Test func makefile_tabIndented() {
        // Makefile: recipes are indented with a single tab
        let lines = [
            "all: build",           // level 0
            "\tgcc -o main main.c", // level 1
            "",                      // inherited: min(1, 1) = 1
            "clean:",               // level 0
            "\trm -f main"          // level 1
        ]
        #expect(IndentGuideCalculator.indentLevel(of: lines[0], indentWidth: 4) == 0)
        #expect(IndentGuideCalculator.indentLevel(of: lines[1], indentWidth: 4) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[3], indentWidth: 4) == 0)
        #expect(IndentGuideCalculator.indentLevel(of: lines[4], indentWidth: 4) == 1)

        let inherited = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 2, in: lines, indentWidth: 4
        )
        #expect(inherited == 0) // min(1, 0) = 0 because "clean:" has 0 indent
    }

    @Test func pythonFile_spaceIndented() {
        let lines = [
            "def foo():",                     // level 0
            "    if True:",                   // level 1
            "        print(\"nested\")",      // level 2
            "    else:",                      // level 1
            "        print(\"other\")"        // level 2
        ]
        #expect(IndentGuideCalculator.indentLevel(of: lines[0], indentWidth: 4) == 0)
        #expect(IndentGuideCalculator.indentLevel(of: lines[1], indentWidth: 4) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[2], indentWidth: 4) == 2)
        #expect(IndentGuideCalculator.indentLevel(of: lines[3], indentWidth: 4) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[4], indentWidth: 4) == 2)
    }

    @Test func guides_tabVsSpace_positionsAreDifferent() {
        // With charWidth=7 and tabStopWidth=28:
        // Tab-based level 1: x = 28 (tabStopWidth)
        // Space-based level 1 with indent 4: x = 28 (4 * 7)
        // Same in this case, but with different tabStopWidth they differ:
        let tabGuides = IndentGuideCalculator.guides(
            forLevel: 1, charWidth: 7.0, tabStopWidth: 35.0,
            usesTabs: true, indentWidth: 4
        )
        let spaceGuides = IndentGuideCalculator.guides(
            forLevel: 1, charWidth: 7.0, tabStopWidth: 35.0,
            usesTabs: false, indentWidth: 4
        )
        #expect(tabGuides[0].xPosition == 35.0) // tabStopWidth
        #expect(spaceGuides[0].xPosition == 28.0) // indentWidth * charWidth
        #expect(tabGuides[0].xPosition != spaceGuides[0].xPosition)
    }
}
