//
//  AgentActivityViewSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for AgentActivityView (issue #1072) in light and
//  dark appearances. Consumes value-type AgentActivityRow projections, so no
//  live terminal or store is needed.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("AgentActivityView Snapshots")
@MainActor
struct AgentActivityViewSnapshotTests {

    /// Matches the view's intrinsic frame (see AgentActivityView.body).
    private static let panelSize = NSSize(width: 420, height: 480)
    /// System colors + Circle anti-aliasing drift ~2–3% between Retina dev
    /// Macs and 1× CI runners (same rationale as AgentStatusBarItem).
    private static let tolerance = 0.03

    /// Fixed far-past timestamp so the relative-time label ("decades ago") is
    /// stable across runs and machines — a near-now timestamp would drift the
    /// rendered text between snapshot capture and comparison.
    private static let stableTimestamp = Date(timeIntervalSinceReferenceDate: 0)
    private static let sessionA = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )
    private static let sessionB = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)
    )

    private func populatedRows() -> [AgentActivityRow] {
        [
            AgentAction(
                attribution: .inferred(
                    AgentActionCandidate(
                        sessionID: Self.sessionA,
                        agentType: .claudeCode
                    )
                ),
                kind: .fileWrite,
                status: .completed,
                timestamp: Self.stableTimestamp,
                fileURL: URL(fileURLWithPath: "/p/src/a.swift"),
                summary: Strings.agentActivityFileChanged("a.swift")
            ),
            AgentAction(
                attribution: .ambiguous(candidates: [
                    AgentActionCandidate(
                        sessionID: Self.sessionA,
                        agentType: .claudeCode
                    ),
                    AgentActionCandidate(
                        sessionID: Self.sessionB,
                        agentType: .codex
                    )
                ]),
                kind: .fileWrite,
                status: .completed,
                timestamp: Self.stableTimestamp,
                fileURL: URL(fileURLWithPath: "/p/src/shared.swift"),
                summary: Strings.agentActivityFileChanged("shared.swift")
            ),
            AgentAction(
                sessionID: Self.sessionB,
                agentType: .codex,
                kind: .command,
                status: .completed,
                timestamp: Self.stableTimestamp,
                summary: "ran npm test"
            ),
            AgentAction(
                sessionID: Self.sessionA,
                agentType: .claudeCode,
                kind: .toolCall,
                status: .failed,
                timestamp: Self.stableTimestamp,
                summary: "apply_patch failed"
            )
        ].map(AgentActivityRow.init)
    }

    @Test("AgentActivityView renders populated panel in light appearance")
    func populatedLight() throws {
        let view = AgentActivityView(rows: populatedRows(), onSelectFile: { _ in }, onClose: {})
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .light,
            named: "AgentActivityView.populated.light",
            tolerance: Self.tolerance
        )
    }

    @Test("AgentActivityView renders populated panel in dark appearance")
    func populatedDark() throws {
        let view = AgentActivityView(rows: populatedRows(), onSelectFile: { _ in }, onClose: {})
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .dark,
            named: "AgentActivityView.populated.dark",
            tolerance: Self.tolerance
        )
    }

    @Test("AgentActivityView renders empty state in light appearance")
    func emptyLight() throws {
        let view = AgentActivityView(rows: [], onSelectFile: { _ in }, onClose: {})
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .light,
            named: "AgentActivityView.empty.light",
            tolerance: Self.tolerance
        )
    }

    @Test("AgentActivityView renders empty state in dark appearance")
    func emptyDark() throws {
        let view = AgentActivityView(rows: [], onSelectFile: { _ in }, onClose: {})
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .dark,
            named: "AgentActivityView.empty.dark",
            tolerance: Self.tolerance
        )
    }
}
