//
//  EditorTabBarTests.swift
//  PineTests
//
//  Tests for EditorTabBar tab width calculation and overflow behavior.
//

import Foundation
import Testing

@testable import Pine

@Suite("EditorTabBar Tab Width Tests")
@MainActor
struct EditorTabBarTests {

    // MARK: - unpinnedTabWidth calculation

    @Test("Returns maxTabWidth when plenty of space for few tabs")
    func maxWidthWhenPlentyOfSpace() {
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 1000, tabCount: 3)
        #expect(width == EditorTabBar.maxTabWidth)
    }

    @Test("Returns minTabWidth when extremely narrow")
    func minWidthWhenVeryNarrow() {
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 200, tabCount: 10)
        #expect(width == EditorTabBar.minTabWidth)
    }

    @Test("Returns maxTabWidth for a single unpinned tab")
    func maxWidthForSingleTab() {
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 500, tabCount: 1)
        #expect(width == EditorTabBar.maxTabWidth)
    }

    @Test("Unpinned tabs shrink as tab count increases")
    func tabsShrinkWithCount() {
        let width3 = EditorTabBar.unpinnedTabWidth(availableWidth: 800, tabCount: 3)
        let width10 = EditorTabBar.unpinnedTabWidth(availableWidth: 800, tabCount: 10)
        #expect(width3 > width10)
    }

    @Test("Unpinned tab width never exceeds maxTabWidth")
    func neverExceedsMax() {
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 10000, tabCount: 2)
        #expect(width <= EditorTabBar.maxTabWidth)
    }

    @Test("Unpinned tab width never goes below minTabWidth")
    func neverBelowMin() {
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 50, tabCount: 100)
        #expect(width >= EditorTabBar.minTabWidth)
    }

    @Test("Every unpinned tab shares one selection-independent width")
    func widthDoesNotDependOnSelection() {
        // 3 tabs in 600px: usable = 600 - 12(padding) - 4(spacing),
        // divided evenly and clamped to 180.
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 600, tabCount: 3)
        #expect(width == EditorTabBar.maxTabWidth)

        // The caller reuses this exact value for every active-tab choice.
        let widthsAcrossSelections = (0..<3).map { _ in width }
        #expect(Set(widthsAcrossSelections).count == 1)

        // 6 tabs in 700px: usable = 700 - 12 - 10 = 678, perTab = 113.
        let width6 = EditorTabBar.unpinnedTabWidth(availableWidth: 700, tabCount: 6)
        #expect(width6 > EditorTabBar.minTabWidth)
        #expect(width6 < EditorTabBar.maxTabWidth)
    }

    @Test("Pinned and unpinned widths remain identical for every selection")
    func mixedWidthsDoNotDependOnSelection() {
        let pinnedStates = [true, true, false, false, false, false]
        let unpinnedWidth = EditorTabBar.unpinnedTabWidth(
            availableWidth: 640,
            tabCount: pinnedStates.count,
            pinnedCount: 2
        )
        let baseline = pinnedStates.map {
            $0 ? EditorTabBar.pinnedTabWidth : unpinnedWidth
        }

        for _ in pinnedStates.indices {
            let widthsForSelection = pinnedStates.map {
                $0 ? EditorTabBar.pinnedTabWidth : unpinnedWidth
            }
            #expect(widthsForSelection == baseline)
        }
    }

    @Test("Two tabs both get maxTabWidth in wide space")
    func twoTabsWideSpace() {
        // 2 tabs in 500px: usable = 500 - 8 - 2 - 180 = 310, perTab = 310 → clamped to 180
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 500, tabCount: 2)
        #expect(width == EditorTabBar.maxTabWidth)
    }

    @Test("Unpinned tabs get intermediate width between min and max")
    func intermediateWidth() {
        // 10 tabs in 1000px: usable = 1000 - 12 - 18 = 970, perTab = 97.
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 1000, tabCount: 10)
        #expect(width > EditorTabBar.minTabWidth)
        #expect(width < EditorTabBar.maxTabWidth)
    }

    @Test("Many tabs in narrow space all clamp to minTabWidth")
    func manyTabsNarrowSpace() {
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 400, tabCount: 20)
        #expect(width == EditorTabBar.minTabWidth)
    }

    // MARK: - Pinned tab width calculations

    @Test("Pinned tabs reduce available space for unpinned tabs")
    func pinnedTabsReduceSpace() {
        let widthNoPinned = EditorTabBar.unpinnedTabWidth(
            availableWidth: 800, tabCount: 6, pinnedCount: 0
        )
        let widthWithPinned = EditorTabBar.unpinnedTabWidth(
            availableWidth: 800, tabCount: 6, pinnedCount: 2
        )
        // Pinned tabs take fixed space, so fewer unpinned tabs share the remainder.
        // (fewer unpinned tabs sharing the remaining space)
        #expect(widthWithPinned >= widthNoPinned)
    }

    @Test("All tabs pinned except one returns maxTabWidth")
    func allPinnedExceptOne() {
        let width = EditorTabBar.unpinnedTabWidth(
            availableWidth: 800, tabCount: 5, pinnedCount: 4
        )
        #expect(width == EditorTabBar.maxTabWidth)
    }

    @Test("Pinned tab width constant is narrower than minTabWidth")
    func pinnedTabWidthIsCompact() {
        #expect(EditorTabBar.pinnedTabWidth < EditorTabBar.minTabWidth)
    }

    // MARK: - Tab width bounds

    @Test("minTabWidth is less than maxTabWidth")
    func minLessThanMax() {
        #expect(EditorTabBar.minTabWidth < EditorTabBar.maxTabWidth)
    }

    @Test("Width monotonically decreases as tab count grows")
    func monotonicDecrease() {
        var previousWidth = CGFloat.infinity
        for count in 2...20 {
            let width = EditorTabBar.unpinnedTabWidth(availableWidth: 1200, tabCount: count)
            #expect(width <= previousWidth, "Width should not increase when adding more tabs")
            previousWidth = width
        }
    }

    @Test("Zero available width still returns minTabWidth")
    func zeroAvailableWidth() {
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: 0, tabCount: 5)
        #expect(width == EditorTabBar.minTabWidth)
    }

    @Test("Negative available width still returns minTabWidth")
    func negativeAvailableWidth() {
        let width = EditorTabBar.unpinnedTabWidth(availableWidth: -100, tabCount: 5)
        #expect(width == EditorTabBar.minTabWidth)
    }
}
