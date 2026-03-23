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
struct EditorTabBarTests {

    // MARK: - inactiveTabWidth calculation

    @Test("Returns maxTabWidth when plenty of space for few tabs")
    func maxWidthWhenPlentyOfSpace() {
        let width = EditorTabBar.inactiveTabWidth(availableWidth: 1000, tabCount: 3)
        #expect(width == EditorTabBar.maxTabWidth)
    }

    @Test("Returns minTabWidth when extremely narrow")
    func minWidthWhenVeryNarrow() {
        let width = EditorTabBar.inactiveTabWidth(availableWidth: 200, tabCount: 10)
        #expect(width == EditorTabBar.minTabWidth)
    }

    @Test("Returns maxTabWidth for single tab (no inactive tabs)")
    func maxWidthForSingleTab() {
        let width = EditorTabBar.inactiveTabWidth(availableWidth: 500, tabCount: 1)
        #expect(width == EditorTabBar.maxTabWidth)
    }

    @Test("Inactive tabs shrink as tab count increases")
    func tabsShrinkWithCount() {
        let width3 = EditorTabBar.inactiveTabWidth(availableWidth: 800, tabCount: 3)
        let width10 = EditorTabBar.inactiveTabWidth(availableWidth: 800, tabCount: 10)
        #expect(width3 > width10)
    }

    @Test("Inactive tab width never exceeds maxTabWidth")
    func neverExceedsMax() {
        let width = EditorTabBar.inactiveTabWidth(availableWidth: 10000, tabCount: 2)
        #expect(width <= EditorTabBar.maxTabWidth)
    }

    @Test("Inactive tab width never goes below minTabWidth")
    func neverBelowMin() {
        let width = EditorTabBar.inactiveTabWidth(availableWidth: 50, tabCount: 100)
        #expect(width >= EditorTabBar.minTabWidth)
    }

    @Test("Active tab space is reserved from available width")
    func activeTabSpaceReserved() {
        // 3 tabs in 600px: usable = 600 - 8(padding) - 4(spacing) - 180(active) = 408, perTab = 204 → clamped to 180
        let width = EditorTabBar.inactiveTabWidth(availableWidth: 600, tabCount: 3)
        #expect(width == EditorTabBar.maxTabWidth)

        // 6 tabs in 600px: usable = 600 - 8 - 10 - 180 = 402, perTab = 80.4
        let width6 = EditorTabBar.inactiveTabWidth(availableWidth: 600, tabCount: 6)
        #expect(width6 > EditorTabBar.minTabWidth)
        #expect(width6 < EditorTabBar.maxTabWidth)
    }

    @Test("Two tabs both get maxTabWidth in wide space")
    func twoTabsWideSpace() {
        // 2 tabs in 500px: usable = 500 - 8 - 2 - 180 = 310, perTab = 310 → clamped to 180
        let width = EditorTabBar.inactiveTabWidth(availableWidth: 500, tabCount: 2)
        #expect(width == EditorTabBar.maxTabWidth)
    }

    @Test("Inactive tabs get intermediate width between min and max")
    func intermediateWidth() {
        // 10 tabs in 900px: usable = 900 - 8 - 18 - 180 = 694, perTab = 77.1 → clamped to 80
        let width = EditorTabBar.inactiveTabWidth(availableWidth: 1000, tabCount: 10)
        #expect(width >= EditorTabBar.minTabWidth)
    }

    @Test("Many tabs in narrow space all clamp to minTabWidth")
    func manyTabsNarrowSpace() {
        let width = EditorTabBar.inactiveTabWidth(availableWidth: 400, tabCount: 20)
        #expect(width == EditorTabBar.minTabWidth)
    }
}
