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
//    asserts the rendered glyph fits inside the slot.
//  * Source-parser regression guards on `Pine/FileNodeRow.swift` that fail
//    fast if anyone removes the per-icon `.frame(width:)` from either the
//    normal branch OR the `inlineEditor` rename branch (so the row does
//    not visually jump on entering/leaving rename — see #736).
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
    /// `iconSlotWidth`.
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

    @Test("FileNodeRow icon uses fixed-width frame in BOTH the normal and rename branches")
    func fileNodeRowUsesFixedWidthFrameInBothBranches() throws {
        let src = try fileNodeRowSource()
        // Both call sites must reference the metric so entering rename
        // does not visually jump (#736 + #763).
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

    @Test("FileNodeRow does NOT reintroduce a custom LabelStyle HStack wrapper")
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
        #expect(
            !src.contains("Color.clear.frame"),
            """
            FileNodeRow must not re-introduce the `HStack { Color.clear.frame … ; row }` \
            wrapper pattern from the reverted PR #770. Apply metrics INSIDE \
            the Label's icon closure so Label stays the row's root view.
            """
        )
    }
}
