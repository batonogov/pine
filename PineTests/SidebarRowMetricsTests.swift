//
//  SidebarRowMetricsTests.swift
//  PineTests
//
//  Tests for sidebar vertical rhythm constants (#764).
//
//  The goal of #764 is a uniform vertical rhythm across *all* nesting levels
//  in the sidebar file tree. These tests lock in the invariants that make
//  that possible:
//
//  1. List-level spacing/insets are zeroed out so SwiftUI doesn't add its
//     own `.sidebar` style gap between top-level rows.
//  2. `verticalPadding(forFontSize:)` is a pure function of font size —
//     so the same font size always produces the same padding, regardless of
//     whether the row is a top-level `List` child or a deeply nested
//     `DisclosureGroup` descendant.
//

import Foundation
import SwiftUI
import Testing
@testable import Pine

@MainActor
struct SidebarRowMetricsTests {

    // MARK: - List-level geometry must be zeroed

    @Test
    func listRowSpacingIsZero() {
        // Non-zero list row spacing is what produced the bug — top-level rows
        // would get an extra gap that nested rows (inside our custom
        // DisclosureGroup VStack(spacing: 0)) wouldn't. Lock it to 0.
        #expect(SidebarRowMetrics.listRowSpacing == 0)
    }

    @Test
    func listRowInsetsAreZero() {
        let insets = SidebarRowMetrics.listRowInsets
        #expect(insets.top == 0)
        #expect(insets.bottom == 0)
        #expect(insets.leading == 0)
        #expect(insets.trailing == 0)
    }

    @Test
    func defaultMinListRowHeightIsNotInflated() {
        // If this grows, intrinsic row height will stop driving the rhythm
        // and top-level rows could again diverge from nested ones.
        #expect(SidebarRowMetrics.defaultMinListRowHeight <= 2)
        #expect(SidebarRowMetrics.defaultMinListRowHeight > 0)
    }

    // MARK: - verticalPadding is a pure function

    @Test
    func verticalPaddingFollowsFormulaAboveThreshold() {
        // Above the floor, padding == fontSize * 0.15.
        #expect(SidebarRowMetrics.verticalPadding(forFontSize: 20) == 3.0)
        #expect(SidebarRowMetrics.verticalPadding(forFontSize: 40) == 6.0)
        #expect(SidebarRowMetrics.verticalPadding(forFontSize: 100) == 15.0)
    }

    @Test
    func verticalPaddingClampsAtFloor() {
        // Below the floor (fontSize * 0.15 < 2), padding is clamped to 2.
        #expect(SidebarRowMetrics.verticalPadding(forFontSize: 13) == 2.0)
        #expect(SidebarRowMetrics.verticalPadding(forFontSize: 10) == 2.0)
        #expect(SidebarRowMetrics.verticalPadding(forFontSize: 1) == 2.0)
        #expect(SidebarRowMetrics.verticalPadding(forFontSize: 0) == 2.0)
    }

    @Test
    func verticalPaddingAtExactThreshold() {
        // fontSize * 0.15 == 2 exactly when fontSize == 13.333…
        // At 13.3333 the formula yields ~1.9999 → floor 2.0
        // At 13.3334 the formula yields ~2.00001 → ~2.00001
        let justBelow = SidebarRowMetrics.verticalPadding(forFontSize: 13.3)
        #expect(justBelow == 2.0)
        let atThreshold = SidebarRowMetrics.verticalPadding(forFontSize: 13.3334)
        #expect(atThreshold >= 2.0)
    }

    @Test
    func verticalPaddingIsNeverNegative() {
        // Defensive: even pathological inputs must not produce negative padding.
        #expect(SidebarRowMetrics.verticalPadding(forFontSize: -5) >= 2.0)
        #expect(SidebarRowMetrics.verticalPadding(forFontSize: -100) >= 2.0)
    }

    // MARK: - Uniform rhythm across nesting levels

    @Test
    func paddingIsIdenticalAcrossNestingLevels() {
        // This is the core invariant of #764: at any given font size, every
        // row — top-level or nested — computes the exact same vertical
        // padding. Simulate "top-level" and "nested depth N" by just calling
        // the pure function with the same font size; since the view code on
        // both paths now routes through `SidebarRowMetrics.verticalPadding`,
        // identical inputs prove identical outputs.
        let fontSizes: [CGFloat] = [11, 12, 13, 14, 16, 18, 20, 24, 32]
        for fontSize in fontSizes {
            let topLevel = SidebarRowMetrics.verticalPadding(forFontSize: fontSize)
            let nestedDepth1 = SidebarRowMetrics.verticalPadding(forFontSize: fontSize)
            let nestedDepth5 = SidebarRowMetrics.verticalPadding(forFontSize: fontSize)
            let nestedDepth20 = SidebarRowMetrics.verticalPadding(forFontSize: fontSize)
            #expect(topLevel == nestedDepth1)
            #expect(topLevel == nestedDepth5)
            #expect(topLevel == nestedDepth20)
        }
    }

    @Test
    func paddingIsDeterministic() {
        // Calling the function twice with the same input must yield the same
        // result — no hidden state, no caching bugs.
        for _ in 0..<100 {
            #expect(SidebarRowMetrics.verticalPadding(forFontSize: 14) == 2.1)
        }
    }

    @Test
    func paddingIsMonotonicInFontSize() {
        // Sanity: a larger font never produces *less* padding than a smaller one.
        var previous = SidebarRowMetrics.verticalPadding(forFontSize: 1)
        for fontSize in stride(from: CGFloat(1), through: 100, by: 0.5) {
            let current = SidebarRowMetrics.verticalPadding(forFontSize: fontSize)
            #expect(current >= previous)
            previous = current
        }
    }
}
