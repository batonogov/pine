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
        #expect(
            store.actions.first?.attribution
                == .session(candidate(sessionID: sessionA, agentType: .claudeCode))
        )
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

    @Test func dedupeDoesNotCollapseDifferentAttributionStrength() {
        let store = AgentActivityStore()
        let base = Date()
        let candidate = candidate(sessionID: sessionA, agentType: .claudeCode)
        store.record(AgentAction(
            attribution: .session(candidate),
            kind: .fileWrite,
            timestamp: base,
            summary: "File changed: a.swift"
        ))
        store.record(AgentAction(
            attribution: .inferred(candidate),
            kind: .fileWrite,
            timestamp: base.addingTimeInterval(0.1),
            summary: "File changed: a.swift"
        ))

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

    @Test func actionsForSessionIncludesAmbiguousCandidateWithoutClaimingOwnership() throws {
        let store = AgentActivityStore()
        let candidates = [
            candidate(sessionID: sessionA, agentType: .claudeCode),
            candidate(sessionID: sessionB, agentType: .codex)
        ]
        store.record(AgentAction(
            attribution: .ambiguous(candidates: candidates),
            kind: .fileWrite,
            summary: "File changed: a.swift"
        ))

        let actionA = try #require(store.actions(forSession: sessionA).first)
        let actionB = try #require(store.actions(forSession: sessionB).first)
        #expect(actionA == actionB)
        #expect(actionA.sessionID == nil)
        #expect(actionA.agentType == nil)
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

    @Test func noteFileSystemChange_ignoredWhenProcessEvidenceIsStale() {
        let store = AgentActivityStore()
        let stale = AgentSession(
            agentType: .claudeCode,
            state: .executing,
            liveness: .stale
        )

        store.noteFileSystemChange(
            at: url("a.swift"),
            activeSessions: [stale]
        )

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
        #expect(
            action.attribution
                == .inferred(candidate(sessionID: sessionA, agentType: .claudeCode))
        )
        #expect(action.kind == .fileWrite)
        #expect(action.fileURL?.lastPathComponent == "a.swift")
        #expect(action.summary == Strings.agentActivityFileChanged("a.swift"))
        #expect(!action.summary.contains("Wrote"))
    }

    @Test func noteFileSystemChange_multipleActivePreservesCandidatesWithoutOwner() throws {
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
        #expect(action.sessionID == nil)
        #expect(action.agentType == nil)
        let expectedCandidates = [
            candidate(sessionID: sessionA, agentType: .claudeCode),
            candidate(sessionID: sessionB, agentType: .codex)
        ].sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
        #expect(
            action.attribution
                == .ambiguous(candidates: expectedCandidates)
        )
        #expect(action.summary == Strings.agentActivityFileChanged("a.swift"))
    }

    @Test func noteFileSystemChange_candidateOrderIsDeterministicAndDedupeSafe() {
        let store = AgentActivityStore()
        let first = AgentSession(id: sessionA, agentType: .claudeCode, state: .executing)
        let second = AgentSession(id: sessionB, agentType: .codex, state: .thinking)

        store.noteFileSystemChange(
            at: url("a.swift"),
            activeSessions: [second, first]
        )
        store.noteFileSystemChange(
            at: url("a.swift"),
            activeSessions: [first, second]
        )

        #expect(store.actions.count == 1)
        #expect(
            store.actions[0].attribution.candidates.map(\.sessionID)
                == [sessionA, sessionB].sorted { $0.uuidString < $1.uuidString }
        )
    }

    @Test func noteFileSystemChange_duplicateSnapshotSessionIsNotAmbiguous() throws {
        let store = AgentActivityStore()
        let session = AgentSession(
            id: sessionA,
            agentType: .claudeCode,
            state: .executing
        )

        store.noteFileSystemChange(
            at: url("a.swift"),
            activeSessions: [session, session]
        )

        let action = try #require(store.actions.first)
        #expect(
            action.attribution
                == .inferred(candidate(sessionID: sessionA, agentType: .claudeCode))
        )
    }

    @Test func noteFileSystemChange_conflictingDuplicateIdentityFailsAmbiguous() throws {
        let store = AgentActivityStore()
        let claude = AgentSession(
            id: sessionA,
            agentType: .claudeCode,
            state: .executing
        )
        let codex = AgentSession(
            id: sessionA,
            agentType: .codex,
            state: .thinking
        )

        store.noteFileSystemChange(
            at: url("a.swift"),
            activeSessions: [codex, claude]
        )

        let action = try #require(store.actions.first)
        #expect(action.sessionID == nil)
        #expect(action.attribution.candidates.count == 2)
    }

    @Test func noteFileSystemChange_doneCandidatesDoNotCreateFalseAmbiguity() throws {
        let store = AgentActivityStore()
        let live = AgentSession(
            id: sessionA,
            agentType: .claudeCode,
            state: .executing
        )
        let done = AgentSession(
            id: sessionB,
            agentType: .codex,
            state: .done
        )

        store.noteFileSystemChange(
            at: url("a.swift"),
            activeSessions: [done, live]
        )

        let action = try #require(store.actions.first)
        #expect(
            action.attribution
                == .inferred(candidate(sessionID: sessionA, agentType: .claudeCode))
        )
    }

    @Test func noteFileSystemChange_appliesDedupe() {
        let store = AgentActivityStore()
        let session = AgentSession(agentType: .claudeCode, state: .executing)
        store.noteFileSystemChange(at: url("a.swift"), activeSessions: [session])
        store.noteFileSystemChange(at: url("a.swift"), activeSessions: [session])
        #expect(store.actions.count == 1)
    }

    // MARK: - Attribution status filter (correlation integration, #1072 SF-1)

    @Test("Attribution covers all changed working-tree states except deleted")
    func isAttributableStatus_coversAllChangedStates() {
        // SF-1 regression guard: agents routinely create new files
        // (.untracked), stage them (.staged), and edit staged files (.mixed).
        // Dropping any of those made the panel miss the most common actions.
        #expect(ProjectManager.isAttributableStatus(.untracked))
        #expect(ProjectManager.isAttributableStatus(.modified))
        #expect(ProjectManager.isAttributableStatus(.staged))
        #expect(ProjectManager.isAttributableStatus(.added))
        #expect(ProjectManager.isAttributableStatus(.conflict))
        #expect(ProjectManager.isAttributableStatus(.mixed))
        // Deleted files no longer exist to open, so they are excluded.
        #expect(!ProjectManager.isAttributableStatus(.deleted))
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

    private func candidate(
        sessionID: UUID,
        agentType: AgentType
    ) -> AgentActionCandidate {
        AgentActionCandidate(sessionID: sessionID, agentType: agentType)
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/project").appendingPathComponent(name)
    }
}
