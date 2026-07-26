//
//  AgentLivenessTrackerTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@Suite("AgentSessionLivenessTracker")
@MainActor
struct AgentLivenessTrackerTests {
    private let baseline = Date(timeIntervalSince1970: 1_000_000)

    @Test func localizedPresentationMetadataCoversEveryState() {
        #expect(!AgentLiveness.live.displayName.isEmpty)
        #expect(!AgentLiveness.stale.displayName.isEmpty)
        #expect(!AgentLiveness.terminated.displayName.isEmpty)
        #expect(AgentLiveness.live.glyphName == nil)
        #expect(AgentLiveness.stale.glyphName == "clock")
        #expect(AgentLiveness.terminated.glyphName == "xmark")
        #expect(!AgentLiveness.live.isStale)
        #expect(AgentLiveness.stale.isStale)
        #expect(AgentLiveness.terminated.isStale)
    }

    @Test func freshEvidenceRemainsLiveBeforeTimeout() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(lastObservedAt: baseline)

        let checks = tracker.checkStaleness(
            of: [session],
            at: baseline.addingTimeInterval(299)
        )

        #expect(checks == [
            AgentLivenessCheck(
                sessionID: session.id,
                liveness: .live,
                lastObservedAt: baseline,
                checkedAt: baseline.addingTimeInterval(299)
            )
        ])
        #expect(session.liveness == .live)
    }

    @Test func evidenceBecomesStaleAtTimeoutBoundary() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(lastObservedAt: baseline)

        tracker.checkStaleness(
            of: [session],
            at: baseline.addingTimeInterval(300)
        )

        #expect(session.liveness == .stale)
        #expect(session.lastObservedAt == baseline)
    }

    @Test func oldExecutingSessionBecomesStaleWithoutFreshEvidence() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(
            state: .executing,
            lastObservedAt: baseline
        )

        tracker.checkStaleness(
            of: [session],
            at: baseline.addingTimeInterval(301)
        )

        #expect(session.liveness == .stale)
    }

    @Test func successfulObservationRevivesStaleEvidence() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(
            liveness: .stale,
            lastObservedAt: baseline
        )
        let observedAt = baseline.addingTimeInterval(400)

        tracker.recordObservation(of: session, at: observedAt)

        #expect(session.liveness == .live)
        #expect(session.lastObservedAt == observedAt)
    }

    @Test func terminatedSessionIsStickyAcrossFailedChecks() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(lastObservedAt: baseline)
        tracker.recordTermination(of: session)

        tracker.checkStaleness(
            of: [session],
            at: baseline.addingTimeInterval(1_000)
        )

        #expect(session.liveness == .terminated)
        #expect(session.lastObservedAt == baseline)
    }

    @Test func successfulObservationCanRepresentPidReuseWithNewSession() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let oldSession = makeSession(lastObservedAt: baseline)
        tracker.recordTermination(of: oldSession)
        let newSession = makeSession(
            id: UUID(),
            lastObservedAt: baseline.addingTimeInterval(1)
        )

        tracker.recordObservation(
            of: newSession,
            at: baseline.addingTimeInterval(2)
        )

        #expect(oldSession.liveness == .terminated)
        #expect(newSession.liveness == .live)
    }

    @Test func multipleSessionsAreAssessedIndependentlyAndInOrder() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let stale = makeSession(lastObservedAt: baseline)
        let fresh = makeSession(
            id: UUID(),
            lastObservedAt: baseline.addingTimeInterval(250)
        )
        let terminated = makeSession(
            id: UUID(),
            liveness: .terminated,
            lastObservedAt: baseline
        )

        let checks = tracker.checkStaleness(
            of: [stale, fresh, terminated],
            at: baseline.addingTimeInterval(500)
        )

        #expect(checks.map(\.sessionID) == [stale.id, fresh.id, terminated.id])
        #expect(checks.map(\.liveness) == [.stale, .live, .terminated])
    }

    @Test func futureObservationDoesNotBecomeStaleAfterClockMovesBackward() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(
            lastObservedAt: baseline.addingTimeInterval(60)
        )

        tracker.checkStaleness(of: [session], at: baseline)

        #expect(session.liveness == .live)
    }

    private func makeSession(
        id: UUID = UUID(),
        state: AgentState = .idle,
        liveness: AgentLiveness = .live,
        lastObservedAt: Date
    ) -> AgentSession {
        AgentSession(
            id: id,
            agentType: .claudeCode,
            state: state,
            startedAt: baseline.addingTimeInterval(-1_000),
            liveness: liveness,
            lastObservedAt: lastObservedAt
        )
    }
}
