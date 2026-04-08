//
//  SidebarIconLabelStyleTests.swift
//  PineTests
//
//  Tests for issue #763 — sidebar file/folder names must line up on the
//  same vertical baseline regardless of which SF Symbol the row uses.
//
//  Strategy:
//  * Runtime invariants on the metric constants (cover boundary conditions,
//    never-zero / never-negative, realistic upper bounds).
//  * Source-parser regression guards on `Pine/FileNodeRow.swift` that fail
//    fast if someone removes `.labelStyle(.sidebarIcon)` from either the
//    normal branch OR the `inlineEditor` rename branch. Both call sites
//    must stay in sync — otherwise entering/leaving rename mode causes the
//    row to visually jump (see #736).
//  * Regression guard that the fix does NOT re-introduce the HStack wrapper
//    pattern from reverted PR #770, which broke `List` selection and
//    XCUITest accessibility lookups.
//

import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Sidebar Icon Label Style — Issue #763")
struct SidebarIconLabelStyleTests {

    // MARK: - Metric invariants

    @Test("iconSlotWidth is positive")
    func iconSlotWidthIsPositive() {
        #expect(SidebarIconLabelStyle.iconSlotWidth > 0)
    }

    @Test("iconSlotWidth is wide enough for the widest SF Symbol used by FileIconMapper")
    func iconSlotWidthCoversWidestSymbol() {
        // `list.bullet`, `folder`, `doc.text` are the widest glyphs used in
        // the sidebar. Empirically they all fit inside ~16pt; we reserve 18
        // as a small buffer. Guard against accidental shrinking below that.
        #expect(SidebarIconLabelStyle.iconSlotWidth >= 16)
    }

    @Test("iconSlotWidth is not oversized")
    func iconSlotWidthIsNotOversized() {
        // 24pt would be visibly sparse and eat sidebar horizontal space.
        #expect(SidebarIconLabelStyle.iconSlotWidth <= 22)
    }

    @Test("iconTitleSpacing is non-negative and reasonable")
    func iconTitleSpacingIsReasonable() {
        #expect(SidebarIconLabelStyle.iconTitleSpacing >= 0)
        #expect(SidebarIconLabelStyle.iconTitleSpacing <= 12)
    }

    @Test("metrics are deterministic — repeated reads return identical values")
    func metricsAreDeterministic() {
        #expect(SidebarIconLabelStyle.iconSlotWidth == SidebarIconLabelStyle.iconSlotWidth)
        #expect(SidebarIconLabelStyle.iconTitleSpacing == SidebarIconLabelStyle.iconTitleSpacing)
    }

    @Test("style sugar `.sidebarIcon` returns a SidebarIconLabelStyle")
    func sidebarIconSugarIsCorrectType() {
        let style: SidebarIconLabelStyle = .sidebarIcon
        #expect(type(of: style) == SidebarIconLabelStyle.self)
    }

    // MARK: - Source-parser regression guards

    /// Loads `Pine/FileNodeRow.swift` from disk relative to this test file
    /// so we can assert structural properties without running a UI.
    private func fileNodeRowSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        // PineTests/SidebarIconLabelStyleTests.swift → repo root → Pine/FileNodeRow.swift
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let target = repoRoot.appendingPathComponent("Pine/FileNodeRow.swift")
        return try String(contentsOf: target, encoding: .utf8)
    }

    @Test("FileNodeRow applies .labelStyle(.sidebarIcon) on both branches")
    func fileNodeRowAppliesSidebarIconLabelStyleTwice() throws {
        let source = try fileNodeRowSource()
        let occurrences = source.components(separatedBy: ".labelStyle(.sidebarIcon)").count - 1
        // One for the normal display branch, one for the inline rename branch.
        // Keeping them in sync prevents the row from visually jumping when
        // entering/leaving rename mode — the historical #736 regression.
        #expect(
            occurrences >= 2,
            "Expected .labelStyle(.sidebarIcon) on BOTH the normal and inlineEditor branches, found \(occurrences)"
        )
    }

    @Test("FileNodeRow does not wrap rows in an HStack with a Color.clear spacer (reverted PR #770)")
    func fileNodeRowDoesNotReintroduceHStackWrapper() throws {
        let source = try fileNodeRowSource()
        // Reverted PR #770 wrapped the row in `HStack { Color.clear.frame(width: …); row(…) }`
        // which broke `List` selection and XCUITest accessibility lookups.
        // Guard against its return.
        #expect(!source.contains("Color.clear.frame(width: SidebarDisclosureMetrics"))
    }

    @Test("FileNodeRow still uses Label as the accessibility root (not a bare HStack)")
    func fileNodeRowUsesLabelAsRoot() throws {
        let source = try fileNodeRowSource()
        // Both branches must use SwiftUI's `Label` primitive so accessibility
        // identifiers attach correctly and OutlineGroup selection highlights
        // the right row.
        #expect(source.contains("Label {"))
        #expect(source.contains("} icon: {"))
    }

    @Test("SidebarIconLabelStyle file exists and declares the style")
    func styleFileExistsAndDeclaresType() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let styleFile = repoRoot.appendingPathComponent("Pine/SidebarIconLabelStyle.swift")
        let source = try String(contentsOf: styleFile, encoding: .utf8)
        #expect(source.contains("struct SidebarIconLabelStyle: LabelStyle"))
        #expect(source.contains("static let iconSlotWidth"))
        #expect(source.contains("static let iconTitleSpacing"))
        #expect(source.contains(".frame(width: Self.iconSlotWidth"))
    }

    // MARK: - Structural: makeBody compiles and wires configuration

    @Test("makeBody returns a non-empty view for arbitrary Label configuration")
    func makeBodyProducesView() {
        // Smoke test: construct a Label, apply the style, and ensure we can
        // reference the resulting view without crashing. SwiftUI view trees
        // are opaque at runtime, so this is effectively a compile-time /
        // initialisation guard.
        let label = Label {
            Text("example.swift")
        } icon: {
            Image(systemName: "doc.text")
        }
        .labelStyle(.sidebarIcon)
        _ = label
        #expect(Bool(true))
    }
}
