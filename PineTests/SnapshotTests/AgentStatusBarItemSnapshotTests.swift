//
//  AgentStatusBarItemSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for AgentStatusBarItem (issue #952) in light and
//  dark appearances. Covers the single-agent (button) and multi-agent (menu)
//  layouts. Because AgentStatusBarItem consumes the value-type
//  AgentStatusSummary, no live terminal is needed.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("AgentStatusBarItem Snapshots")
@MainActor
struct AgentStatusBarItemSnapshotTests {

    /// Sized to match the status-bar height; width leaves room for the label.
    private static let itemSize = NSSize(width: 420, height: 28)
    /// Matches `StatusBarViewSnapshotTests.barTolerance` (0.03): the item uses
    /// the same `.bar`-adjacent system colors and `Circle` anti-aliasing that
    /// drift ~2–3% between Retina dev Macs and 1× CI runners.
    private static let tolerance = 0.03

    private func singleAgentSummary() -> AgentStatusSummary {
        AgentStatusSummary(
            id: UUID(),
            agentType: .claudeCode,
            state: .thinking,
            paneID: PaneID(),
            tabID: UUID()
        )
    }

    private func twoAgentSummaries() -> [AgentStatusSummary] {
        [
            AgentStatusSummary(
                id: UUID(),
                agentType: .claudeCode,
                state: .thinking,
                paneID: PaneID(),
                tabID: UUID()
            ),
            AgentStatusSummary(
                id: UUID(),
                agentType: .codex,
                state: .idle,
                paneID: PaneID(),
                tabID: UUID()
            )
        ]
    }

    // MARK: - Single agent (button)

    @Test("Single agent renders in light appearance")
    func singleAgentLight() throws {
        let view = AgentStatusBarItem(summaries: [singleAgentSummary()]) { _, _ in }
        try assertSnapshot(
            of: view,
            size: Self.itemSize,
            appearance: .light,
            named: "AgentStatusBarItem.singleAgent.light",
            tolerance: Self.tolerance
        )
    }

    @Test("Single agent renders in dark appearance")
    func singleAgentDark() throws {
        let view = AgentStatusBarItem(summaries: [singleAgentSummary()]) { _, _ in }
        try assertSnapshot(
            of: view,
            size: Self.itemSize,
            appearance: .dark,
            named: "AgentStatusBarItem.singleAgent.dark",
            tolerance: Self.tolerance
        )
    }

    // MARK: - Multiple agents (menu)

    @Test("Multiple agents render in light appearance")
    func multipleAgentsLight() throws {
        let view = AgentStatusBarItem(summaries: twoAgentSummaries()) { _, _ in }
        try assertSnapshot(
            of: view,
            size: Self.itemSize,
            appearance: .light,
            named: "AgentStatusBarItem.multipleAgents.light",
            tolerance: Self.tolerance
        )
    }

    @Test("Multiple agents render in dark appearance")
    func multipleAgentsDark() throws {
        let view = AgentStatusBarItem(summaries: twoAgentSummaries()) { _, _ in }
        try assertSnapshot(
            of: view,
            size: Self.itemSize,
            appearance: .dark,
            named: "AgentStatusBarItem.multipleAgents.dark",
            tolerance: Self.tolerance
        )
    }
}
