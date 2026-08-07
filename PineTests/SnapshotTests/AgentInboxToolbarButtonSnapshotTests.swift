//
//  AgentInboxToolbarButtonSnapshotTests.swift
//  PineTests
//
//  Visual snapshot coverage for the project-window Agent Inbox toolbar
//  button (#1337). Covers the zero-attention and N-attention badge states
//  in both light and dark appearances.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("AgentInboxToolbarButton Snapshots")
@MainActor
struct AgentInboxToolbarButtonSnapshotTests {

    /// The button is a single toolbar glyph; render it with enough padding
    /// that the red attention capsule (offset onto the icon's corner) is not
    /// clipped at the bitmap edge.
    private static let buttonSize = NSSize(width: 56, height: 40)

    // The badge capsule uses solid `.red` and the glyph uses a system tint,
    // both of which are stable across machines; default tolerance is enough.
    private static let tolerance = 0.01

    private func button(count: Int) -> some View {
        AgentInboxToolbarButton(attentionCount: count) {}
            .padding(8)
    }

    // MARK: - Zero attention (no badge)

    @Test("zero attention renders in light appearance")
    func zeroLight() throws {
        try assertSnapshot(
            of: button(count: 0),
            size: Self.buttonSize,
            appearance: .light,
            named: "AgentInboxToolbarButton.zero.light",
            tolerance: Self.tolerance
        )
    }

    @Test("zero attention renders in dark appearance")
    func zeroDark() throws {
        try assertSnapshot(
            of: button(count: 0),
            size: Self.buttonSize,
            appearance: .dark,
            named: "AgentInboxToolbarButton.zero.dark",
            tolerance: Self.tolerance
        )
    }

    // MARK: - With attention badge

    @Test("badge with count renders in light appearance")
    func badgeLight() throws {
        try assertSnapshot(
            of: button(count: 3),
            size: Self.buttonSize,
            appearance: .light,
            named: "AgentInboxToolbarButton.badge.light",
            tolerance: Self.tolerance
        )
    }

    @Test("badge with count renders in dark appearance")
    func badgeDark() throws {
        try assertSnapshot(
            of: button(count: 3),
            size: Self.buttonSize,
            appearance: .dark,
            named: "AgentInboxToolbarButton.badge.dark",
            tolerance: Self.tolerance
        )
    }

    // MARK: - Overflow cap (99+)

    @Test("overflow caps display at 99+ in light appearance")
    func overflowLight() throws {
        try assertSnapshot(
            of: button(count: 150),
            size: Self.buttonSize,
            appearance: .light,
            named: "AgentInboxToolbarButton.overflow.light",
            tolerance: Self.tolerance
        )
    }

    @Test("overflow caps display at 99+ in dark appearance")
    func overflowDark() throws {
        try assertSnapshot(
            of: button(count: 150),
            size: Self.buttonSize,
            appearance: .dark,
            named: "AgentInboxToolbarButton.overflow.dark",
            tolerance: Self.tolerance
        )
    }
}
