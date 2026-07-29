//
//  AgentKeyboardSelectionTests.swift
//  PineTests
//
//  Unit coverage for Agent Attention keyboard selection (#1245).
//

import Foundation
import Testing

@testable import Pine

@MainActor
struct AgentKeyboardSelectionTests {
    @Test("Stable identity survives insertion and rank reordering")
    func stableIdentitySurvivesReorder() {
        let first = UUID()
        let selected = UUID()
        let inserted = UUID()

        #expect(
            AgentKeyboardSelection.normalizeID(
                selected,
                ids: [inserted, selected, first]
            ) == selected
        )
        #expect(
            AgentKeyboardSelection.moveID(
                from: selected,
                by: 1,
                ids: [inserted, selected, first]
            ) == first
        )
    }

    @Test("Removed identity fails safely to the first current row")
    func removedIdentitySelectsCurrentFirstRow() {
        let removed = UUID()
        let first = UUID()
        let second = UUID()

        #expect(
            AgentKeyboardSelection.normalizeID(
                removed,
                ids: [first, second]
            ) == first
        )
        #expect(
            AgentKeyboardSelection.normalizeID(
                removed,
                ids: []
            ) == nil
        )
    }

    @Test("Normalize handles empty, missing, valid, and stale selections")
    func normalizeSelection() {
        #expect(AgentKeyboardSelection.normalize(nil, count: 0) == nil)
        #expect(AgentKeyboardSelection.normalize(0, count: -1) == nil)
        #expect(AgentKeyboardSelection.normalize(nil, count: 3) == 0)
        #expect(AgentKeyboardSelection.normalize(1, count: 3) == 1)
        #expect(AgentKeyboardSelection.normalize(-10, count: 3) == 0)
        #expect(AgentKeyboardSelection.normalize(10, count: 3) == 2)
    }

    @Test("Arrow movement starts at the first row and clamps at both edges")
    func arrowMovementClamps() {
        #expect(AgentKeyboardSelection.move(from: nil, by: 1, count: 3) == 1)
        #expect(AgentKeyboardSelection.move(from: nil, by: -1, count: 3) == 0)
        #expect(AgentKeyboardSelection.move(from: 0, by: -1, count: 3) == 0)
        #expect(AgentKeyboardSelection.move(from: 1, by: -1, count: 3) == 0)
        #expect(AgentKeyboardSelection.move(from: 1, by: 1, count: 3) == 2)
        #expect(AgentKeyboardSelection.move(from: 2, by: 1, count: 3) == 2)
        #expect(AgentKeyboardSelection.move(from: 1, by: 0, count: 3) == 1)
    }

    @Test("Arrow movement safely handles stale indices and integer overflow")
    func arrowMovementHandlesInvalidAndExtremeValues() {
        #expect(AgentKeyboardSelection.move(from: -5, by: 1, count: 3) == 1)
        #expect(AgentKeyboardSelection.move(from: 99, by: -1, count: 3) == 1)
        #expect(
            AgentKeyboardSelection.move(
                from: 1,
                by: Int.max,
                count: 3
            ) == 2
        )
        #expect(
            AgentKeyboardSelection.move(
                from: 1,
                by: Int.min,
                count: 3
            ) == 0
        )
        #expect(AgentKeyboardSelection.move(from: 0, by: 1, count: 0) == nil)
        #expect(AgentKeyboardSelection.move(from: 0, by: 1, count: -2) == nil)
    }

    @Test("Return resolves a valid row and rejects every empty-list shape")
    func returnResolution() {
        #expect(AgentKeyboardSelection.resolveReturn(current: nil, count: 0) == nil)
        #expect(AgentKeyboardSelection.resolveReturn(current: 0, count: -1) == nil)
        #expect(AgentKeyboardSelection.resolveReturn(current: nil, count: 3) == 0)
        #expect(AgentKeyboardSelection.resolveReturn(current: 2, count: 3) == 2)
        #expect(AgentKeyboardSelection.resolveReturn(current: -1, count: 3) == 0)
        #expect(AgentKeyboardSelection.resolveReturn(current: 3, count: 3) == 0)
        #expect(AgentKeyboardSelection.resolveReturn(current: 99, count: 3) == 0)
    }

    @Test("Selected-row announcement identifies the same terminal request")
    func accessibilityAnnouncementMatchesSummary() {
        let summary = AgentStatusSummary(
            id: UUID(),
            agentType: .codex,
            state: .waitingInput,
            liveness: .stale,
            paneID: PaneID(),
            tabID: UUID()
        )

        #expect(
            AgentAttentionOverlay.accessibilityAnnouncement(for: summary)
                == summary.detailText
        )
        #expect(
            AgentAttentionOverlay.accessibilityAnnouncement(for: summary)
                .contains("Codex")
        )
        #expect(
            AgentAttentionOverlay.accessibilityAnnouncement(for: summary)
                .contains(AgentLiveness.stale.displayName)
        )
    }

}
