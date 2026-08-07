//
//  AgentInboxToolbarButtonSnapshotTests.swift
//  PineTests
//
//  Visual snapshot coverage for the project-window Agent Inbox toolbar
//  button (#1337). Covers the quiet and attention states in both light and
//  dark appearances, plus pixel assertions that the attention dot neither
//  covers the tray glyph nor grows with the count.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("AgentInboxToolbarButton Snapshots")
@MainActor
struct AgentInboxToolbarButtonSnapshotTests {

    // Tight around the 16pt glyph plus the dot's small overhang. Deliberately
    // no padding around the view under test: the dot must stay well inside
    // the toolbar's circular item chrome, so a snapshot taken close to the
    // button's own extent is what catches it drifting outward.
    private static let buttonSize = NSSize(width: 32, height: 32)

    // The SF Symbol glyph and the dot's rounded edge anti-alias slightly
    // differently between macOS 26 (the unit-test runner) and macOS 27 (the
    // Xcode 27 compatibility lane), and both compare against these references.
    // 0.02 is the house default and covers that drift.
    private static let tolerance = 0.02

    private func button(count: Int) -> some View {
        AgentInboxToolbarButton(attentionCount: count) {}
    }

    // MARK: - No attention (no dot)

    @Test("quiet state renders in light appearance")
    func quietLight() throws {
        try assertSnapshot(
            of: button(count: 0),
            size: Self.buttonSize,
            appearance: .light,
            named: "AgentInboxToolbarButton.zero.light",
            tolerance: Self.tolerance
        )
    }

    @Test("quiet state renders in dark appearance")
    func quietDark() throws {
        try assertSnapshot(
            of: button(count: 0),
            size: Self.buttonSize,
            appearance: .dark,
            named: "AgentInboxToolbarButton.zero.dark",
            tolerance: Self.tolerance
        )
    }

    // MARK: - Attention dot

    @Test("attention dot renders in light appearance")
    func dotLight() throws {
        try assertSnapshot(
            of: button(count: 3),
            size: Self.buttonSize,
            appearance: .light,
            named: "AgentInboxToolbarButton.badge.light",
            tolerance: Self.tolerance
        )
    }

    @Test("attention dot renders in dark appearance")
    func dotDark() throws {
        try assertSnapshot(
            of: button(count: 3),
            size: Self.buttonSize,
            appearance: .dark,
            named: "AgentInboxToolbarButton.badge.dark",
            tolerance: Self.tolerance
        )
    }

    // MARK: - Geometry guards

    /// Pins the button to the canvas's leading edge so the glyph lands on the
    /// same pixels in every variant.
    private func pinned(count: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            AgentInboxToolbarButton(attentionCount: count) {}
            Spacer(minLength: 0)
        }
        .frame(
            width: Self.buttonSize.width,
            height: Self.buttonSize.height,
            alignment: .topLeading
        )
    }

    private func maxChannelDelta(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        width: Int,
        height: Int
    ) -> Double? {
        var maxDelta = 0.0
        for x in 0..<width {
            for y in 0..<height {
                guard let a = lhs.colorAt(x: x, y: y),
                      let b = rhs.colorAt(x: x, y: y) else { return nil }
                maxDelta = max(maxDelta, abs(a.redComponent - b.redComponent))
                maxDelta = max(
                    maxDelta,
                    abs(a.greenComponent - b.greenComponent)
                )
                maxDelta = max(maxDelta, abs(a.blueComponent - b.blueComponent))
                maxDelta = max(
                    maxDelta,
                    abs(a.alphaComponent - b.alphaComponent)
                )
            }
        }
        return maxDelta
    }

    /// The regression this file exists for: the first cut positioned a count
    /// capsule with `.offset`, so a wider count grew leftwards and at "99+"
    /// covered the tray glyph almost entirely. The dot may touch only the
    /// glyph's trailing corner, so the glyph's leading columns must be
    /// pixel-identical whether or not it is showing.
    @Test("the dot never covers the glyph's leading region")
    func dotDoesNotOccludeGlyph() throws {
        if SnapshotHarness.isHeadless { return }

        let quiet = try SnapshotHarness.render(
            view: pinned(count: 0),
            size: Self.buttonSize,
            appearance: .light
        )
        let attentive = try SnapshotHarness.render(
            view: pinned(count: 1),
            size: Self.buttonSize,
            appearance: .light
        )

        // The glyph is 16pt wide and the dot's leading edge sits at 10pt;
        // stay a point clear of that boundary to ignore anti-aliasing.
        let safeWidth = 9
        let delta = maxChannelDelta(
            quiet,
            attentive,
            width: safeWidth,
            height: Int(Self.buttonSize.height)
        )
        let maxDelta = try #require(delta, "Missing pixels in the safe region")
        #expect(
            maxDelta < 0.02,
            """
            The attention dot intrudes into the glyph's leading \(safeWidth)pt \
            (max channel delta \(maxDelta)). It must sit at the glyph's \
            corner, not over it.
            """
        )
    }

    /// The dot is numberless on purpose: its size must not track the count,
    /// or it starts reaching past the toolbar's circular item chrome again.
    @Test("the dot is identical for one task and for many")
    func dotDoesNotGrowWithTheCount() throws {
        if SnapshotHarness.isHeadless { return }

        let few = try SnapshotHarness.render(
            view: pinned(count: 1),
            size: Self.buttonSize,
            appearance: .light
        )
        let many = try SnapshotHarness.render(
            view: pinned(count: 150),
            size: Self.buttonSize,
            appearance: .light
        )

        let delta = maxChannelDelta(
            few,
            many,
            width: Int(Self.buttonSize.width),
            height: Int(Self.buttonSize.height)
        )
        let maxDelta = try #require(delta, "Missing pixels")
        #expect(
            maxDelta < 0.02,
            "The dot changed with the count (max channel delta \(maxDelta))."
        )
    }
}
