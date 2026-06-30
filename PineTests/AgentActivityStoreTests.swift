//
//  AgentActivityStoreTests.swift
//  PineTests
//
//  Unit tests for AgentActivityStore (issue #1072): record/dedupe/filter,
//  capacity trimming, and the file-system correlation attribution heuristic.
//

import Testing
import Foundation
@testable import Pine

@Suite("AgentActivityStore")
@MainActor
struct AgentActivityStoreTests {

    private let sessionA = UUID()
    private let sessionB = UUID()

    // MARK: - Recording & dedupe

    @Test func recordAppendsAction() {
        let store = AgentActivityStore()
        store.record(makeAction(sessionID: sessionA, summary: "Wrote a.swift"))
        #expect(store.actions.count == 1)
        #expect(store.actions.first?.summary == "Wrote a.swift")
    }

    @Test func dedupeCollapsesIdenticalConsecutiveWithinWindow() {
        let store = AgentActivityStore()
        let base = Date()
        store.record(makeAction(sessionID: sessionA, timestamp: base, summary: "Wrote a.swift"))
        store.record(makeAction(sessionID: sessionA, timestamp: base.addingTimeInterval(0.3), summary: "Wrote a.swift"))
        store.record(makeAction(sessionID: sessionA, timestamp: base.addingTimeInterval(0.6), summary: "Wrote a.swift"))
        #expect(store.actions.count == 1)
    }

    @Test func dedupeDoesNotCollapseDifferentSummary() {
        let store = AgentActivityStore()
        let base = Date()
        store.record(makeAction(sessionID: sessionA, timestamp: base, summary: "Wrote a.swift"))
        store.record(makeAction(sessionID: sessionA, timestamp: base, summary: "Wrote b.swift"))
        #expect(store.actions.count == 2)
    }

    @Test func dedupeDoesNotCollapseDifferentSession() {
        let store = AgentActivityStore()
        let base = Date()
        store.record(makeAction(sessionID: sessionA, timestamp: base, summary: "Wrote a.swift"))
        store.record(makeAction(sessionID: sessionB, timestamp: base, summary: "Wrote a.swift"))
        #expect(store.actions.count == 2)
    }

    @Test func dedupeDoesNotCollapseBeyondWindow() {
        let store = AgentActivityStore()
        let base = Date()
        store.record(makeAction(sessionID: sessionA, timestamp: base, summary: "Wrote a.swift"))
        store.record(makeAction(sessionID: sessionA, timestamp: base.addingTimeInterval(1.5), summary: "Wrote a.swift"))
        #expect(store.actions.count == 2)
    }

    // MARK: - Capacity

    @Test func capsAtMaxActionsDroppingOldest() {
        let store = AgentActivityStore()
        let base = Date()
        for index in 0..<(AgentActivityStore.maxActions + 5) {
            store.record(makeAction(
                sessionID: sessionA,
                timestamp: base.addingTimeInterval(Double(index) * 2.0),
                summary: "Wrote \(index).swift"
            ))
        }
        #expect(store.actions.count == AgentActivityStore.maxActions)
        // Oldest five were dropped; the first retained action is index 5.
        #expect(store.actions.first?.summary == "Wrote 5.swift")
    }

    // MARK: - Queries

    @Test func actionsForSessionFiltersByID() {
        let store = AgentActivityStore()
        let base = Date()
        store.record(makeAction(sessionID: sessionA, kind: .fileWrite, timestamp: base, summary: "a"))
        store.record(makeAction(sessionID: sessionB, kind: .command, timestamp: base, summary: "b"))
        store.record(makeAction(sessionID: sessionA, kind: .fileRead, timestamp: base, summary: "c"))

        #expect(store.actions(forSession: sessionA).count == 2)
        #expect(store.actions(forSession: sessionB).count == 1)
        #expect(store.actions(forSession: UUID()).isEmpty)
    }

    @Test func filteredByKind() {
        let store = AgentActivityStore()
        let base = Date()
        store.record(makeAction(sessionID: sessionA, kind: .fileWrite, timestamp: base, summary: "w"))
        store.record(makeAction(sessionID: sessionA, kind: .fileRead, timestamp: base, summary: "r"))
        store.record(makeAction(sessionID: sessionA, kind: .command, timestamp: base, summary: "c"))

        #expect(store.filtered(kind: .fileWrite).count == 1)
        #expect(store.filtered(kind: .command).count == 1)
        #expect(store.filtered(kind: nil).count == 3)
    }

    @Test func filteredByStatus() {
        let store = AgentActivityStore()
        let base = Date()
        store.record(makeAction(sessionID: sessionA, status: .completed, timestamp: base, summary: "a"))
        store.record(makeAction(sessionID: sessionA, status: .failed, timestamp: base, summary: "b"))
        store.record(makeAction(sessionID: sessionA, status: .completed, timestamp: base, summary: "c"))

        #expect(store.filtered(status: .completed).count == 2)
        #expect(store.filtered(status: .failed).count == 1)
    }

    @Test func clearEmptiesStore() {
        let store = AgentActivityStore()
        store.record(makeAction(sessionID: sessionA, summary: "a"))
        #expect(store.actions.count == 1)
        store.clear()
        #expect(store.actions.isEmpty)
    }

    // MARK: - File-system correlation attribution

    @Test func noteFileSystemChange_ignoredWhenNoActiveSession() {
        let store = AgentActivityStore()
        store.noteFileSystemChange(at: url("a.swift"), activeSessions: [])
        #expect(store.actions.isEmpty)
    }

    @Test func noteFileSystemChange_ignoredWhenOnlyDoneSessions() {
        let store = AgentActivityStore()
        let done = AgentSession(agentType: .claudeCode, state: .done)
        store.noteFileSystemChange(at: url("a.swift"), activeSessions: [done])
        #expect(store.actions.isEmpty)
    }

    @Test func noteFileSystemChange_attributedToSingleActiveSession() throws {
        let store = AgentActivityStore()
        let session = AgentSession(id: sessionA, agentType: .claudeCode, state: .executing)
        store.noteFileSystemChange(at: url("src/a.swift"), activeSessions: [session])

        #expect(store.actions.count == 1)
        let action = try #require(store.actions.first)
        #expect(action.sessionID == sessionA)
        #expect(action.agentType == .claudeCode)
        #expect(action.kind == .fileWrite)
        #expect(action.fileURL?.lastPathComponent == "a.swift")
        #expect(!action.summary.contains("ambiguous"))
    }

    @Test func noteFileSystemChange_multipleActiveAttributesToMostRecentWithMarker() throws {
        let store = AgentActivityStore()
        let older = AgentSession(
            id: sessionA,
            agentType: .claudeCode,
            state: .executing,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = AgentSession(
            id: sessionB,
            agentType: .codex,
            state: .thinking,
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        store.noteFileSystemChange(at: url("a.swift"), activeSessions: [older, newer])

        #expect(store.actions.count == 1)
        let action = try #require(store.actions.first)
        // Most-recently-active (by startedAt) wins.
        #expect(action.sessionID == sessionB)
        // Ambiguous attribution is flagged in the summary.
        #expect(action.summary.contains("ambiguous"))
    }

    @Test func noteFileSystemChange_appliesDedupe() {
        let store = AgentActivityStore()
        let session = AgentSession(agentType: .claudeCode, state: .executing)
        store.noteFileSystemChange(at: url("a.swift"), activeSessions: [session])
        store.noteFileSystemChange(at: url("a.swift"), activeSessions: [session])
        #expect(store.actions.count == 1)
    }

    // MARK: - Helpers

    private func makeAction(
        sessionID: UUID,
        agentType: AgentType = .claudeCode,
        kind: AgentActionKind = .fileWrite,
        status: AgentActionStatus = .completed,
        timestamp: Date = Date(),
        summary: String
    ) -> AgentAction {
        AgentAction(
            sessionID: sessionID,
            agentType: agentType,
            kind: kind,
            status: status,
            timestamp: timestamp,
            summary: summary
        )
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/project").appendingPathComponent(name)
    }
}
