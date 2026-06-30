//
//  AgentHistoryViewSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for AgentHistoryView (issue #1073) in light and dark
//  appearances. Populates an in-memory AgentHistoryStore with stub entries so
//  no disk or live terminal is needed.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("AgentHistoryView Snapshots")
@MainActor
struct AgentHistoryViewSnapshotTests {

    /// Fits the view's frame (minWidth 460, minHeight 320) with room for two
    /// timeline rows plus the header.
    private static let panelSize = NSSize(width: 480, height: 360)
    /// System colors + Circle anti-aliasing drift ~2–3% between Retina dev
    /// Macs and 1× CI runners (same rationale as AgentStatusBarItem).
    private static let tolerance = 0.03

    /// Fixed timestamps so the rendered "HH:mm – HH:mm" range is stable across
    /// runs and machines.
    private static let startDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let endDate = Date(timeIntervalSince1970: 1_800_036_000)

    private func makePopulatedStore() -> AgentHistoryStore {
        let store = AgentHistoryStore(projectRoot: nil)
        store.append(
            AgentHistoryEntry(
                sessionID: UUID(),
                agentTypeRaw: "claudeCode",
                startedAt: Self.startDate,
                endedAt: Self.endDate,
                affectedFiles: ["src/a.swift", "src/b.swift", "README.md"],
                summary: "3 files, +42/-8 lines",
                reverted: false
            )
        )
        store.append(
            AgentHistoryEntry(
                sessionID: UUID(),
                agentTypeRaw: "codex",
                startedAt: Self.startDate.addingTimeInterval(7_200),
                endedAt: Self.startDate.addingTimeInterval(7_560),
                affectedFiles: ["src/c.swift"],
                summary: "1 file, +12/-0 lines",
                reverted: true
            )
        )
        return store
    }

    @Test("AgentHistoryView renders populated timeline in light appearance")
    func populatedLight() throws {
        let store = makePopulatedStore()
        let view = AgentHistoryView(store: store, isPresented: .constant(true))
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .light,
            named: "AgentHistoryView.populated.light",
            tolerance: Self.tolerance
        )
    }

    @Test("AgentHistoryView renders populated timeline in dark appearance")
    func populatedDark() throws {
        let store = makePopulatedStore()
        let view = AgentHistoryView(store: store, isPresented: .constant(true))
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .dark,
            named: "AgentHistoryView.populated.dark",
            tolerance: Self.tolerance
        )
    }

    @Test("AgentHistoryView renders empty state in light appearance")
    func emptyLight() throws {
        let store = AgentHistoryStore(projectRoot: nil)
        let view = AgentHistoryView(store: store, isPresented: .constant(true))
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .light,
            named: "AgentHistoryView.empty.light",
            tolerance: Self.tolerance
        )
    }

    @Test("AgentHistoryView renders empty state in dark appearance")
    func emptyDark() throws {
        let store = AgentHistoryStore(projectRoot: nil)
        let view = AgentHistoryView(store: store, isPresented: .constant(true))
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .dark,
            named: "AgentHistoryView.empty.dark",
            tolerance: Self.tolerance
        )
    }
}
