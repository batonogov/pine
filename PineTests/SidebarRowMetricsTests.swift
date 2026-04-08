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
    func listRowInsetsAreZero() {
        let insets = SidebarRowMetrics.listRowInsets
        #expect(insets.top == 0)
        #expect(insets.bottom == 0)
        #expect(insets.leading == 0)
        #expect(insets.trailing == 0)
    }

    @Test
    func defaultMinListRowHeightIsNotInflated() {
        // If this grows past ~16pt (≈ system font cap height) the List will
        // start reserving more vertical space than the row's intrinsic
        // content needs, and top-level rows would once again diverge from
        // their nested siblings (#764). 16pt is the upper bound that still
        // matches a single line of the default sidebar font.
        #expect(SidebarRowMetrics.defaultMinListRowHeight <= 16)
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
    func sidebarFileTreeHasSingleSourceOfVerticalPadding() throws {
        // The #764 invariant — uniform rhythm across nesting levels — only
        // holds if `SidebarFileTree.swift` calls
        // `SidebarRowMetrics.verticalPadding(forFontSize:` from exactly one
        // place. Top-level and nested rows both render through the same
        // `row(isFolder:)` builder, so a single call site there proves there
        // is no ad-hoc padding sneaking in for one render path. If somebody
        // adds a second call (e.g. a "special case" for top-level rows) this
        // test fails fast and forces a review.
        //
        // Locate the source file relative to *this* test file rather than
        // walking the filesystem from cwd, so the test works under both
        // `xcodebuild test` and Xcode's test runner.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // PineTests/
            .deletingLastPathComponent()  // repo root
        let sourceURL = repoRoot
            .appendingPathComponent("Pine")
            .appendingPathComponent("SidebarFileTree.swift")

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            Issue.record("Could not find SidebarFileTree.swift at \(sourceURL.path)")
            return
        }

        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let needle = "SidebarRowMetrics.verticalPadding(forFontSize:"
        var count = 0
        var searchRange = source.startIndex..<source.endIndex
        while let match = source.range(of: needle, range: searchRange) {
            count += 1
            searchRange = match.upperBound..<source.endIndex
        }
        #expect(
            count == 1,
            "Expected exactly one call to SidebarRowMetrics.verticalPadding(forFontSize: in SidebarFileTree.swift, found \(count). Multiple call sites risk diverging behaviour between nesting levels."
        )
    }

    @Test
    func paddingIsDeterministic() {
        // Calling the function twice with the same input must yield the same
        // result — no hidden state, no caching bugs. Use a tolerance compare
        // because `14 * 0.15` is not exactly representable in binary float.
        let expected: CGFloat = 2.1
        let tolerance: CGFloat = 0.0001
        for _ in 0..<100 {
            let actual = SidebarRowMetrics.verticalPadding(forFontSize: 14)
            #expect(abs(actual - expected) < tolerance)
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
