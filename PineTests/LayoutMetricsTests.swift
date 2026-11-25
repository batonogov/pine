//
//  LayoutMetricsTests.swift
//  PineTests
//
//  Tests for centralized layout spacing constants.
//

import Foundation
import Testing

@testable import Pine

@Suite("LayoutMetrics Constants")
@MainActor
struct LayoutMetricsTests {

    // MARK: - Font sizes

    @Test("Caption font size is 10")
    func captionFontSize() {
        #expect(LayoutMetrics.captionFontSize == 10)
    }

    @Test("Body small font size is 11")
    func bodySmallFontSize() {
        #expect(LayoutMetrics.bodySmallFontSize == 11)
    }

    @Test("Icon small font size is 9")
    func iconSmallFontSize() {
        #expect(LayoutMetrics.iconSmallFontSize == 9)
    }

    // MARK: - Spacing

    @Test("Status bar horizontal padding is consistent")
    func statusBarPadding() {
        #expect(LayoutMetrics.statusBarHorizontalPadding == 10)
    }

    @Test("Status bar height is 22")
    func statusBarHeight() {
        #expect(LayoutMetrics.statusBarHeight == 22)
    }

    @Test("Status bar item spacing is 6")
    func statusBarItemSpacing() {
        #expect(LayoutMetrics.statusBarItemSpacing == 6)
    }

    @Test("Tab bar height is 30")
    func tabBarHeight() {
        #expect(LayoutMetrics.tabBarHeight == 30)
    }

    // MARK: - All values are positive

    @Test("All spacing values are positive")
    func allValuesPositive() {
        #expect(LayoutMetrics.captionFontSize > 0)
        #expect(LayoutMetrics.bodySmallFontSize > 0)
        #expect(LayoutMetrics.iconSmallFontSize > 0)
        #expect(LayoutMetrics.statusBarHorizontalPadding > 0)
        #expect(LayoutMetrics.statusBarHeight > 0)
        #expect(LayoutMetrics.statusBarItemSpacing > 0)
        #expect(LayoutMetrics.tabBarHeight > 0)
    }

    // MARK: - Font size ordering

    @Test("Font sizes are ordered: icon small < caption < body small")
    func fontSizeOrdering() {
        #expect(LayoutMetrics.iconSmallFontSize < LayoutMetrics.captionFontSize)
        #expect(LayoutMetrics.captionFontSize < LayoutMetrics.bodySmallFontSize)
    }
}
