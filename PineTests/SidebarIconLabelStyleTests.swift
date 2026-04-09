//
//  SidebarIconLabelStyleTests.swift
//  PineTests
//
//  Tests for issue #763 — sidebar file/folder names must line up on the
//  same vertical baseline regardless of which SF Symbol the row uses.
//
//  Strategy:
//
//  * Metric invariants on `SidebarIconMetrics.iconSlotWidth`.
//  * Real geometry test that renders an `Image(systemName:)` via SwiftUI's
//    `ImageRenderer` for every wide SF Symbol used by `FileIconMapper` and
//    asserts the rendered glyph fits inside the slot. This is honest, unlike
//    the previous `NSImage(systemSymbolName:).size` measurement which
//    returned container bounds (with internal padding) rather than the
//    width SwiftUI actually lays out.
//  * Source-parser regression guards on `Pine/FileNodeRow.swift` that fail
//    fast if anyone removes the per-icon `.frame(width:)` from either the
//    normal branch OR the `inlineEditor` rename branch (so the row does
//    not visually jump on entering/leaving rename — see #736).
//  * Regression guard that the fix does NOT re-introduce the
//    `.labelStyle(.sidebarIcon)` HStack-wrapper pattern from reverted
//    PRs #766/#770/#775v1, which inflated vertical rhythm and broke
//    top-level visual alignment.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Sidebar Icon Alignment — Issue #763")
@MainActor
struct SidebarIconMetricsTests {

    // MARK: - Metric invariants

    @Test("iconSlotWidth is positive")
    func iconSlotWidthIsPositive() {
        #expect(SidebarIconMetrics.iconSlotWidth > 0)
    }

    @Test("iconSlotWidth is in the realistic SF Symbol body range (16...24)")
    func iconSlotWidthIsRealistic() {
        // The widest symbol used by FileIconMapper
        // (`chevron.left.forwardslash.chevron.right`) rasterises to 21pt
        // via ImageRenderer at body font. Anything below 16 would clip
        // common symbols; anything above 24 would over-indent rows.
        #expect(SidebarIconMetrics.iconSlotWidth >= 16)
        #expect(SidebarIconMetrics.iconSlotWidth <= 24)
    }

    // MARK: - Real geometry via ImageRenderer

    /// SF Symbols used by `FileIconMapper.iconForFile/iconForFolder` that
    /// historically caused row drift in #763. Renders each via SwiftUI's
    /// `ImageRenderer` and asserts the actual rasterised image fits inside
    /// `iconSlotWidth`. Unlike `NSImage(systemSymbolName:).size`, this
    /// measures what SwiftUI actually draws.
    @Test("All sidebar SF Symbols rasterise to widths that fit inside iconSlotWidth")
    func sfSymbolsFitInsideSlot() throws {
        let symbols = [
            // Folders
            "folder", "folder.fill", "folder.badge.gearshape",
            // Files
            "doc", "doc.text", "doc.plaintext",
            "shield", "lock", "book.closed",
            "list.bullet", "list.bullet.rectangle",
            "chevron.left.forwardslash.chevron.right",
            "point.3.connected.trianglepath.dotted",
            "gear", "hammer", "wrench.and.screwdriver",
            "terminal", "swift", "globe", "photo",
            "music.note", "film", "archivebox"
        ]

        let slot = SidebarIconMetrics.iconSlotWidth

        for symbol in symbols {
            // Skip symbols that are unavailable on the current SDK so the
            // test stays portable across macOS versions.
            guard NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else {
                continue
            }

            let view = Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.primary)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2.0
            guard let cgImage = renderer.cgImage else {
                Issue.record("ImageRenderer returned nil for symbol \(symbol)")
                continue
            }
            // cgImage.width is in pixels at scale=2, so divide.
            let pointWidth = CGFloat(cgImage.width) / 2.0
            #expect(
                pointWidth <= slot + 0.5,
                "SF Symbol '\(symbol)' rendered at \(pointWidth)pt, exceeds slot \(slot)pt"
            )
        }
    }

    // MARK: - Source-parser regression guards

    private func fileNodeRowSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PineTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Pine/FileNodeRow.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("FileNodeRow icon uses fixed-width frame in the normal branch")
    func normalBranchUsesFixedWidthFrame() throws {
        let src = try fileNodeRowSource()
        // Both call sites must reference the metric — search for the
        // canonical token. Fail-fast if removed.
        let occurrences = src.components(separatedBy: "SidebarIconMetrics.iconSlotWidth").count - 1
        #expect(
            occurrences >= 2,
            """
            Expected SidebarIconMetrics.iconSlotWidth to be used in BOTH the \
            normal and inlineEditor branches of FileNodeRow (so entering \
            rename does not visually jump — see #736). \
            Found \(occurrences) usage(s).
            """
        )
    }

    @Test("FileNodeRow does NOT use the reverted .sidebarIcon LabelStyle wrapper")
    func doesNotReintroduceLabelStyleWrapper() throws {
        let src = try fileNodeRowSource()
        // PRs #766, #770, #775v1 wrapped the Label in a custom LabelStyle
        // or HStack. All were reverted because they inflated vertical
        // rhythm and broke alignment. Guard against re-introduction.
        #expect(
            !src.contains(".labelStyle(.sidebarIcon)"),
            """
            FileNodeRow must not use .labelStyle(.sidebarIcon) — that pattern \
            was reverted in #772/#773 because it inflated vertical rhythm \
            and broke top-level alignment. Apply .frame(width:) directly on \
            the Image inside the icon closure instead.
            """
        )
    }

    // MARK: - File-leaf leading inset (alignment with folder icons)

    @Test("fileLeafLeadingInset is strictly positive")
    func fileLeafLeadingInsetIsPositive() {
        #expect(SidebarIconMetrics.fileLeafLeadingInset > 0)
    }

    @Test("fileLeafLeadingInset matches chevron width + HStack spacing")
    func fileLeafLeadingInsetMatchesChevronGeometry() {
        // SidebarDisclosureGroupStyle prepends:
        //   Image("chevron.right").frame(width: 10)
        //   HStack(spacing: 2) { chevron ; label }
        // So a folder label starts 10 + 2 = 12pt to the right of the row.
        // File-leaf rows must compensate by exactly that much so their icon
        // lines up with the folder icon on the same x-coordinate.
        #expect(SidebarIconMetrics.fileLeafLeadingInset == 22)
    }

    @Test("fileLeafLeadingInset stays in a sane 8...24 range")
    func fileLeafLeadingInsetIsRealistic() {
        #expect(SidebarIconMetrics.fileLeafLeadingInset >= 8)
        #expect(SidebarIconMetrics.fileLeafLeadingInset <= 24)
    }

    @Test("fileLeafLeadingInset is deterministic across reads")
    func fileLeafLeadingInsetIsDeterministic() {
        let first = SidebarIconMetrics.fileLeafLeadingInset
        let second = SidebarIconMetrics.fileLeafLeadingInset
        let third = SidebarIconMetrics.fileLeafLeadingInset
        #expect(first == second)
        #expect(second == third)
    }

    @Test("FileNodeRow applies the leaf inset in BOTH the normal and rename branches")
    func fileNodeRowAppliesLeafInsetToBothBranches() throws {
        let src = try fileNodeRowSource()
        let occurrences = src.components(
            separatedBy: "SidebarIconMetrics.fileLeafLeadingInset"
        ).count - 1
        #expect(
            occurrences >= 2,
            """
            Expected SidebarIconMetrics.fileLeafLeadingInset to be used in \
            BOTH the normal Label branch and the inlineEditor rename branch \
            of FileNodeRow so entering rename does not visually jump \
            (#736 + #763). Found \(occurrences) usage(s).
            """
        )
    }

    @Test("FileNodeRow exposes an isLeaf parameter (not a hard-coded constant)")
    func fileNodeRowExposesIsLeafParameter() throws {
        let src = try fileNodeRowSource()
        #expect(
            src.contains("var isLeaf: Bool"),
            """
            FileNodeRow must expose `isLeaf: Bool` so SidebarFileTree can \
            pass false for folder rows (which already have a chevron in \
            front of them) and true for file-leaf rows (which need the \
            compensating leading inset). A hard-coded inset would push \
            folder labels too far right.
            """
        )
    }

    @Test("FileNodeRow guards the inset behind isLeaf (folder rows get zero inset)")
    func fileNodeRowGuardsInsetWithIsLeaf() throws {
        let src = try fileNodeRowSource()
        // The inset must be conditional on isLeaf so folder rows (which
        // already have a chevron prefix from SidebarDisclosureGroupStyle)
        // do not receive a second compensating inset and drift right.
        #expect(
            src.contains("isLeaf ? SidebarIconMetrics.fileLeafLeadingInset"),
            """
            The leading inset must be guarded by `isLeaf ? … : 0` so folder \
            rows (which already carry a chevron prefix) receive zero inset \
            and keep their existing x-coordinate. Unconditionally padding \
            would push folders past their chevron and break top-level \
            alignment.
            """
        )
    }

    @Test("FileNodeRow does not wrap the row in an HStack spacer")
    func fileNodeRowDoesNotWrapInHStack() throws {
        let src = try fileNodeRowSource()
        // PR #770 wrapped the row in `HStack { Color.clear.frame(width:) ; row }`
        // which moved Label out of the row root and broke XCUITest
        // outline.cells lookups + SwiftUI selection highlight. The fix
        // must live inside the Label's icon closure, not as an outer
        // HStack wrapper.
        #expect(
            !src.contains("Color.clear.frame"),
            """
            FileNodeRow must not re-introduce the `HStack { Color.clear.frame … ; row }` \
            wrapper pattern from the reverted PR #770. Apply the leading \
            inset as `.padding(.leading, …)` on the Image INSIDE the \
            Label's icon closure so Label stays the row's root view.
            """
        )
    }

    @Test("SidebarFileTree passes isLeaf based on folder flag")
    func sidebarFileTreePassesIsLeafFlag() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/SidebarFileTree.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(
            src.contains("FileNodeRow(node: node, isLeaf: !isFolder)"),
            """
            SidebarFileTree.row(isFolder:) must forward the inverse of its \
            `isFolder` argument to FileNodeRow.isLeaf so file rows get the \
            compensating leading inset and folder rows do not.
            """
        )
    }
}
