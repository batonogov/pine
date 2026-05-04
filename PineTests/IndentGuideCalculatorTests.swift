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
        #expect(guides[0].xPosition == 28.5) // floor(1 * 28.0) + 0.5
    }

    @Test func guides_tabBased_level3() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 3, charWidth: 7.0, tabStopWidth: 28.0,
            usesTabs: true, indentWidth: 4
        )
        #expect(guides.count == 3)
        #expect(guides[0].xPosition == 28.5)  // floor(28) + 0.5
        #expect(guides[1].xPosition == 56.5)  // floor(56) + 0.5
        #expect(guides[2].xPosition == 84.5)  // floor(84) + 0.5
    }

    @Test func guides_tabBased_usesTabStopWidth_notCharWidth() {
        // Key bug fix from #587/#601: tab-indented guides must use the actual
        // tab stop width from NSParagraphStyle, NOT `charWidth * indentWidth`.
        // Pick values where the two formulas diverge to prove that
        // `usesTabs: true` ignores `charWidth` and `indentWidth` entirely
        // and only consults `tabStopWidth`.
        //
        //   tabStopWidth = 35.0
        //   charWidth * indentWidth = 7.0 * 4 = 28.0  ← wrong (regression value)
        //   tabStopWidth-based:     1×35.0 = 35.0,  2×35.0 = 70.0  ← correct
        let charWidth: CGFloat = 7.0
        let indentWidth = 4
        let tabStopWidth: CGFloat = 35.0
        let wrongValueLevel1 = charWidth * CGFloat(indentWidth)             // 28
        let wrongValueLevel2 = charWidth * CGFloat(indentWidth) * 2          // 56

        let guides = IndentGuideCalculator.guides(
            forLevel: 2, charWidth: charWidth, tabStopWidth: tabStopWidth,
            usesTabs: true, indentWidth: indentWidth
        )

        // Correct: tab-stop-based, pixel-snapped
        #expect(guides[0].xPosition == floor(tabStopWidth) + 0.5)            // 35.5
        #expect(guides[1].xPosition == floor(tabStopWidth * 2) + 0.5)        // 70.5

        // Regression guard: must NOT fall back to charWidth * indentWidth
        #expect(guides[0].xPosition != floor(wrongValueLevel1) + 0.5)        // != 28.5
        #expect(guides[1].xPosition != floor(wrongValueLevel2) + 0.5)        // != 56.5
    }

    @Test func guides_tabBased_customTabStop() {
        // Tab stop at 32pt (not the standard 28pt)
        let guides = IndentGuideCalculator.guides(
            forLevel: 2, charWidth: 7.0, tabStopWidth: 32.0,
            usesTabs: true, indentWidth: 4
        )
        #expect(guides[0].xPosition == 32.5) // floor(32) + 0.5
        #expect(guides[1].xPosition == 64.5) // floor(64) + 0.5
    }

    // MARK: - guides: Space-based

    @Test func guides_spaceBased_level1_indent4() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 1, charWidth: 7.0, tabStopWidth: 28.0,
            usesTabs: false, indentWidth: 4
        )
        #expect(guides.count == 1)
        #expect(guides[0].xPosition == 28.5) // floor(1 * 4 * 7.0) + 0.5
    }

    @Test func guides_spaceBased_level2_indent2() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 2, charWidth: 7.0, tabStopWidth: 28.0,
            usesTabs: false, indentWidth: 2
        )
        #expect(guides.count == 2)
        #expect(guides[0].xPosition == 14.5) // floor(1 * 2 * 7.0) + 0.5
        #expect(guides[1].xPosition == 28.5) // floor(2 * 2 * 7.0) + 0.5
    }

    @Test func guides_spaceBased_differentCharWidth() {
        // Larger font → wider charWidth
        let guides = IndentGuideCalculator.guides(
            forLevel: 1, charWidth: 9.5, tabStopWidth: 38.0,
            usesTabs: false, indentWidth: 4
        )
        #expect(guides[0].xPosition == 38.5) // floor(1 * 4 * 9.5) + 0.5
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
        // With charWidth=7 and tabStopWidth=35:
        // Tab-based level 1: floor(35) + 0.5 = 35.5
        // Space-based level 1 with indent 4: floor(28) + 0.5 = 28.5
        let tabGuides = IndentGuideCalculator.guides(
            forLevel: 1, charWidth: 7.0, tabStopWidth: 35.0,
            usesTabs: true, indentWidth: 4
        )
        let spaceGuides = IndentGuideCalculator.guides(
            forLevel: 1, charWidth: 7.0, tabStopWidth: 35.0,
            usesTabs: false, indentWidth: 4
        )
        #expect(tabGuides[0].xPosition == 35.5) // floor(tabStopWidth) + 0.5
        #expect(spaceGuides[0].xPosition == 28.5) // floor(indentWidth * charWidth) + 0.5
        #expect(tabGuides[0].xPosition != spaceGuides[0].xPosition)
    }

    // MARK: - Pixel-alignment: same indent level → same x across calls

    @Test func guides_sameLevelProducesSameX_spaceBased() {
        // Simulates calling guides() for multiple lines at the same indent level.
        // Before the fix, fractional charWidth could produce different x values
        // per call. Now pixel-snapping ensures exact equality.
        let charWidth: CGFloat = 7.21875 // Typical fractional advance width
        let results = (0..<100).map { _ in
            IndentGuideCalculator.guides(
                forLevel: 3,
                charWidth: charWidth,
                tabStopWidth: 28.0,
                usesTabs: false,
                indentWidth: 2
            )
        }
        // All 100 calls must produce identical x for each level
        for i in 1..<results.count {
            for lvl in 0..<3 {
                #expect(
                    results[0][lvl].xPosition == results[i][lvl].xPosition,
                    "Level \(lvl + 1) x must be identical across calls"
                )
            }
        }
    }

    @Test func guides_sameLevelProducesSameX_tabBased() {
        let results = (0..<100).map { _ in
            IndentGuideCalculator.guides(
                forLevel: 3,
                charWidth: 7.21875,
                tabStopWidth: 28.875,
                usesTabs: true,
                indentWidth: 4
            )
        }
        for i in 1..<results.count {
            for lvl in 0..<3 {
                #expect(
                    results[0][lvl].xPosition == results[i][lvl].xPosition,
                    "Level \(lvl + 1) x must be identical across calls"
                )
            }
        }
    }

    // MARK: - Pixel-alignment: x ends in .5

    @Test func guides_xPositionsArePixelSnapped() {
        // With fractional charWidth, raw x has a fractional part.
        // After snapping, x must be floor(raw) + 0.5.
        let charWidth: CGFloat = 7.21875
        let guides = IndentGuideCalculator.guides(
            forLevel: 4,
            charWidth: charWidth,
            tabStopWidth: 28.0,
            usesTabs: false,
            indentWidth: 2
        )
        for guide in guides {
            let fractionalPart = guide.xPosition - floor(guide.xPosition)
            #expect(
                fractionalPart == 0.5,
                "Guide level \(guide.level) x=\(guide.xPosition) must end in .5 for pixel-snap"
            )
        }
    }

    @Test func guides_tabBased_xPositionsArePixelSnapped() {
        let guides = IndentGuideCalculator.guides(
            forLevel: 4,
            charWidth: 7.0,
            tabStopWidth: 28.875,
            usesTabs: true,
            indentWidth: 4
        )
        for guide in guides {
            let fractionalPart = guide.xPosition - floor(guide.xPosition)
            #expect(
                fractionalPart == 0.5,
                "Guide level \(guide.level) x=\(guide.xPosition) must end in .5 for pixel-snap"
            )
        }
    }

    // MARK: - Fractional charWidth correctness

    @Test func guides_fractionalCharWidth_snapsCorrectly() {
        // charWidth = 7.21875: raw x for level 1 indent 2 = 2 * 7.21875 = 14.4375
        // Snapped: floor(14.4375) + 0.5 = 14.5
        let guides = IndentGuideCalculator.guides(
            forLevel: 1,
            charWidth: 7.21875,
            tabStopWidth: 28.0,
            usesTabs: false,
            indentWidth: 2
        )
        #expect(guides[0].xPosition == 14.5) // floor(14.4375) + 0.5
    }

    @Test func guides_fractionalCharWidth_level3() {
        // charWidth = 7.21875, indentWidth = 2:
        //   level 1: floor(2 * 7.21875) + 0.5 = floor(14.4375) + 0.5 = 14.5
        //   level 2: floor(4 * 7.21875) + 0.5 = floor(28.875) + 0.5  = 28.5
        //   level 3: floor(6 * 7.21875) + 0.5 = floor(43.3125) + 0.5 = 43.5
        let guides = IndentGuideCalculator.guides(
            forLevel: 3,
            charWidth: 7.21875,
            tabStopWidth: 28.0,
            usesTabs: false,
            indentWidth: 2
        )
        #expect(guides[0].xPosition == 14.5)
        #expect(guides[1].xPosition == 28.5)
        #expect(guides[2].xPosition == 43.5)
    }

    @Test func snappedXPosition_fractionalOrigin_snapsAfterAddingOrigin_spaceBased() throws {
        // Regression guard for blank-line fallback drawing: the editor gutter
        // width can be fractional, so adding origin.x after snapping the
        // container-relative guide puts empty-line guides on a different pixel
        // column from the glyph-based path used by non-blank lines.
        let charWidth: CGFloat = 7.21875
        let originX: CGFloat = 52.44
        let rawX = CGFloat(2) * charWidth

        let snapped = try #require(IndentGuideCalculator.snappedXPosition(
            forLevel: 1,
            charWidth: charWidth,
            tabStopWidth: 28.0,
            usesTabs: false,
            indentWidth: 2,
            originX: originX
        ))

        #expect(snapped == floor(rawX + originX) + 0.5)

        let oldFallbackX = IndentGuideCalculator.guides(
            forLevel: 1,
            charWidth: charWidth,
            tabStopWidth: 28.0,
            usesTabs: false,
            indentWidth: 2
        )[0].xPosition + originX
        #expect(snapped != oldFallbackX)
    }

    @Test func snappedXPosition_fractionalOrigin_snapsAfterAddingOrigin_tabBased() throws {
        let tabStopWidth: CGFloat = 28.875
        let originX: CGFloat = 52.44

        let snapped = try #require(IndentGuideCalculator.snappedXPosition(
            forLevel: 1,
            charWidth: 7.0,
            tabStopWidth: tabStopWidth,
            usesTabs: true,
            indentWidth: 4,
            originX: originX
        ))

        #expect(snapped == floor(tabStopWidth + originX) + 0.5)

        let oldFallbackX = IndentGuideCalculator.guides(
            forLevel: 1,
            charWidth: 7.0,
            tabStopWidth: tabStopWidth,
            usesTabs: true,
            indentWidth: 4
        )[0].xPosition + originX
        #expect(snapped != oldFallbackX)
    }

    @Test func guides_fractionalTabStop_snapsCorrectly() {
        // tabStopWidth = 28.875:
        //   level 1: floor(28.875) + 0.5 = 28.5
        //   level 2: floor(57.75)  + 0.5 = 57.5
        let guides = IndentGuideCalculator.guides(
            forLevel: 2,
            charWidth: 7.0,
            tabStopWidth: 28.875,
            usesTabs: true,
            indentWidth: 4
        )
        #expect(guides[0].xPosition == 28.5)
        #expect(guides[1].xPosition == 57.5)
    }

    // MARK: - YAML scenario (issue #876)

    @Test func yamlFile_spaceIndented_guidesAligned() {
        // YAML with 2-space indentation — the scenario from issue #876
        let lines = [
            "root:",                            // level 0
            "  child1:",                        // level 1
            "    grandchild1: value",           // level 2
            "    grandchild2: value",           // level 2
            "  child2:",                        // level 1
            "    grandchild3: value"            // level 2
        ]

        let charWidth: CGFloat = 7.21875 // Typical fractional monospace advance

        // All level-2 lines must produce identical guide positions
        let level2Lines = [2, 3, 5]
        var level2Guides: [[IndentGuide]] = []
        for idx in level2Lines {
            let level = IndentGuideCalculator.indentLevel(of: lines[idx], indentWidth: 2)
            #expect(level == 2)
            let guides = IndentGuideCalculator.guides(
                forLevel: level,
                charWidth: charWidth,
                tabStopWidth: 28.0,
                usesTabs: false,
                indentWidth: 2
            )
            level2Guides.append(guides)
        }

        // Guide at level 1 must be identical across all level-2 lines
        for i in 1..<level2Guides.count {
            #expect(level2Guides[0][0].xPosition == level2Guides[i][0].xPosition)
        }
        // Guide at level 2 must be identical across all level-2 lines
        for i in 1..<level2Guides.count {
            #expect(level2Guides[0][1].xPosition == level2Guides[i][1].xPosition)
        }
    }

    // MARK: - indentLevel: Unicode & special content

    @Test func indentLevel_unicodeContent() {
        // Indent level only depends on leading whitespace, not content
        let level = IndentGuideCalculator.indentLevel(of: "        \u{1F600} emoji", indentWidth: 4)
        #expect(level == 2)
    }

    @Test func indentLevel_newlineOnly() {
        let level = IndentGuideCalculator.indentLevel(of: "\n", indentWidth: 4)
        #expect(level == 0)
    }

    @Test func indentLevel_singleSpace_indentWidth1() {
        let level = IndentGuideCalculator.indentLevel(of: " x", indentWidth: 1)
        #expect(level == 1)
    }

    @Test func indentLevel_negativeIndentWidth_returnsZero() {
        let level = IndentGuideCalculator.indentLevel(of: "    code", indentWidth: -2)
        #expect(level == 0)
    }

    @Test func indentLevel_spaceThenTab() {
        // Spaces before tab: spaces=1, then tab counted
        // "  \t" → spaces=2, tabs=1 → tabs + spaces/indentWidth = 1 + 2/4 = 1
        let level = IndentGuideCalculator.indentLevel(of: "  \tcode", indentWidth: 4)
        #expect(level == 1)
    }

    @Test func indentLevel_exactSpaces_multipleIndentWidths() {
        // 12 spaces with indentWidth 3 → 4 levels
        let level = IndentGuideCalculator.indentLevel(of: "            code", indentWidth: 3)
        #expect(level == 4)
    }

    // MARK: - inheritedIndentLevel: Additional edge cases

    @Test func inheritedIndent_singleLineDocument() {
        let lines = ["code"]
        // Can't inherit — lineIndex 0 is not blank anyway, but test boundary
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 0, in: [""], indentWidth: 4
        )
        #expect(level == 0)
        // Verify non-blank single line
        let nonBlank = IndentGuideCalculator.indentLevel(of: lines[0], indentWidth: 4)
        #expect(nonBlank == 0)
    }

    @Test func inheritedIndent_blankAfterDeepNesting() {
        let lines = [
            "                deep",  // 16 spaces → level 4
            "",
            "    shallow"            // 4 spaces → level 1
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level == 1) // min(4, 1) = 1
    }

    @Test func inheritedIndent_consecutiveBlankLines_differentPositions() {
        let lines = [
            "        deep",  // level 2
            "",              // index 1
            "",              // index 2
            "",              // index 3
            "    shallow"    // level 1
        ]
        // First blank
        let level1 = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level1 == 1) // min(2, 1) = 1

        // Middle blank
        let level2 = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 2, in: lines, indentWidth: 4
        )
        #expect(level2 == 1) // min(2, 1) = 1

        // Last blank
        let level3 = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 3, in: lines, indentWidth: 4
        )
        #expect(level3 == 1) // min(2, 1) = 1
    }

    @Test func inheritedIndent_blankLineBetweenTabAndSpace() {
        // Mixed: above uses tabs, below uses spaces
        let lines = [
            "\t\tcode",     // 2 tabs → level 2
            "",
            "        code"  // 8 spaces → level 2
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 1, in: lines, indentWidth: 4
        )
        #expect(level == 2) // min(2, 2) = 2
    }

    @Test func inheritedIndent_firstLineIsBlank_noLineAbove() {
        let lines = [
            "",
            "",
            "        code"  // level 2
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 0, in: lines, indentWidth: 4
        )
        #expect(level == 0) // above = 0 (nothing above), below = 2 → min(0,2) = 0
    }

    @Test func inheritedIndent_lastLineIsBlank_noLineBelow() {
        let lines = [
            "        code",  // level 2
            "",
            ""
        ]
        let level = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 2, in: lines, indentWidth: 4
        )
        #expect(level == 0) // above = 2, below = 0 (nothing below) → min(2,0) = 0
    }

    // MARK: - Real-world: Swift nested closures

    @Test func swiftFile_nestedClosures() {
        let lines = [
            "func test() {",             // level 0
            "    let x = items.map {",   // level 1
            "        $0 + 1",            // level 2
            "    }",                      // level 1
            "}"                          // level 0
        ]
        #expect(IndentGuideCalculator.indentLevel(of: lines[0], indentWidth: 4) == 0)
        #expect(IndentGuideCalculator.indentLevel(of: lines[1], indentWidth: 4) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[2], indentWidth: 4) == 2)
        #expect(IndentGuideCalculator.indentLevel(of: lines[3], indentWidth: 4) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[4], indentWidth: 4) == 0)
    }

    // MARK: - Real-world: HTML with 2-space indent

    @Test func htmlFile_twoSpaceIndent() {
        let lines = [
            "<div>",                      // level 0
            "  <ul>",                     // level 1
            "    <li>item</li>",          // level 2
            "  </ul>",                    // level 1
            "</div>"                      // level 0
        ]
        #expect(IndentGuideCalculator.indentLevel(of: lines[0], indentWidth: 2) == 0)
        #expect(IndentGuideCalculator.indentLevel(of: lines[1], indentWidth: 2) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[2], indentWidth: 2) == 2)
        #expect(IndentGuideCalculator.indentLevel(of: lines[3], indentWidth: 2) == 1)
        #expect(IndentGuideCalculator.indentLevel(of: lines[4], indentWidth: 2) == 0)
    }

    // MARK: - Blank-line fallback (renderer regression guard, issue #876 review)

    /// Reproduction for the regression flagged in PR #878 review:
    /// the renderer used to query the layout manager for the glyph at
    /// `lineStart + level * indentWidth`, but for blank lines that index
    /// is past `NSMaxRange(lineRange)`, so guides for inherited blank
    /// lines were silently dropped. The renderer now falls back to
    /// `IndentGuideCalculator.guides(...)` for blank lines, and the
    /// inherited level must still be > 0 inside a nested block.
    @Test func inheritedIndent_blankInsideNestedBlock_producesNonZeroLevel() {
        let lines = [
            "outer:",                       // level 0
            "  inner:",                     // level 1
            "    deepest:",                 // level 2
            "      value: 1",               // level 3
            "",                              // blank inside the deepest block
            "      value: 2",               // level 3
            "  other: 3"                    // level 1
        ]
        let blank = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 4, in: lines, indentWidth: 2
        )
        // Above level = 3, below level = 3 → inherited = 3
        #expect(blank == 3, "Blank lines inside nested blocks must inherit a non-zero level")

        // And the calculator must produce 3 guide positions for that level.
        let blankGuides = IndentGuideCalculator.guides(
            forLevel: blank,
            charWidth: 7.0,
            tabStopWidth: 28.0,
            usesTabs: false,
            indentWidth: 2
        )
        #expect(blankGuides.count == 3)
    }

    /// The fallback path the renderer uses for blank lines must produce
    /// the *same* x-coordinates as the calculator path used for the
    /// surrounding non-blank lines (assuming uniform indentation). This
    /// is what makes the guides look like continuous vertical lines
    /// flowing through empty rows.
    @Test func inheritedIndent_blankFallback_xMatchesNonBlankNeighbours() {
        let lines = [
            "  child1:",                    // level 1
            "    grandchild: value",        // level 2
            "",                              // blank inheriting level 2
            "    grandchild: value"         // level 2
        ]
        let charWidth: CGFloat = 7.21875 // realistic fractional advance
        let tabStopWidth: CGFloat = 28.0

        let nonBlankLevel = IndentGuideCalculator.indentLevel(
            of: lines[1], indentWidth: 2
        )
        let blankLevel = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 2, in: lines, indentWidth: 2
        )
        #expect(blankLevel == nonBlankLevel) // both = 2

        let nonBlankGuides = IndentGuideCalculator.guides(
            forLevel: nonBlankLevel,
            charWidth: charWidth,
            tabStopWidth: tabStopWidth,
            usesTabs: false,
            indentWidth: 2
        )
        let blankGuides = IndentGuideCalculator.guides(
            forLevel: blankLevel,
            charWidth: charWidth,
            tabStopWidth: tabStopWidth,
            usesTabs: false,
            indentWidth: 2
        )
        for lvl in 0..<nonBlankGuides.count {
            #expect(
                nonBlankGuides[lvl].xPosition == blankGuides[lvl].xPosition,
                "Blank-line fallback x must match non-blank neighbour x at level \(lvl + 1)"
            )
        }
    }

    /// Tab-indented blank lines must also produce non-zero inherited levels
    /// and guide x-positions (Makefile/Go/etc.).
    @Test func inheritedIndent_blankInsideTabBlock_producesNonZeroLevel() {
        let lines = [
            "func body() {",                // level 0
            "\tif cond {",                  // level 1
            "\t\tdo()",                     // level 2
            "",                              // blank inside the inner block
            "\t\tmore()"                    // level 2
        ]
        let blank = IndentGuideCalculator.inheritedIndentLevel(
            forBlankLineAt: 3, in: lines, indentWidth: 4
        )
        #expect(blank == 2, "Blank lines inside tab-indented blocks must inherit a non-zero level")

        let blankGuides = IndentGuideCalculator.guides(
            forLevel: blank,
            charWidth: 7.0,
            tabStopWidth: 28.0,
            usesTabs: true,
            indentWidth: 4
        )
        #expect(blankGuides.count == 2)
        // Both x positions are pixel-snapped tab-stop multiples.
        #expect(blankGuides[0].xPosition == 28.5)
        #expect(blankGuides[1].xPosition == 56.5)
    }

    /// Guard against a different regression: when a non-blank line is
    /// shorter than the inherited indent column (e.g. a single comment
    /// character on a deeply-indented line), the renderer must still draw
    /// guides via the fallback path. The calculator continues to produce
    /// positions independent of the actual line length.
    @Test func guides_shortLineFallback_returnsPositionsForFullLevel() {
        // 5 levels worth of x-positions even though the "line" has no
        // glyph past the first column.
        let guides = IndentGuideCalculator.guides(
            forLevel: 5,
            charWidth: 7.0,
            tabStopWidth: 28.0,
            usesTabs: false,
            indentWidth: 4
        )
        #expect(guides.count == 5)
        for (i, g) in guides.enumerated() {
            #expect(g.level == i + 1)
            // All snapped, all monotonically increasing.
            #expect(g.xPosition.truncatingRemainder(dividingBy: 1) == 0.5)
        }
        for i in 1..<guides.count {
            #expect(guides[i].xPosition > guides[i - 1].xPosition)
        }
    }
}
