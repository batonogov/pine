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
            observation: stamp(wallOffset: 299, uptime: 399, sequence: 2)
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
            observation: stamp(wallOffset: 300, uptime: 400, sequence: 2)
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
            observation: stamp(wallOffset: 301, uptime: 401, sequence: 2)
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

        tracker.recordObservation(
            of: session,
            observation: stamp(
                wallOffset: 400,
                uptime: 500,
                sequence: 2
            )
        )

        #expect(session.liveness == .live)
        #expect(session.lastObservedAt == observedAt)
    }

    @Test func terminatedSessionIsStickyAcrossFailedChecks() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(lastObservedAt: baseline)
        tracker.recordTermination(of: session)

        tracker.checkStaleness(
            of: [session],
            observation: stamp(wallOffset: 1_000, uptime: 1_100, sequence: 2)
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
            observation: stamp(wallOffset: 2, uptime: 102, sequence: 2)
        )

        #expect(oldSession.liveness == .terminated)
        #expect(newSession.liveness == .live)
    }

    @Test func multipleSessionsAreAssessedIndependentlyAndInOrder() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let stale = makeSession(lastObservedAt: baseline)
        let fresh = makeSession(
            id: UUID(),
            lastObservedAt: baseline.addingTimeInterval(250),
            uptime: 350
        )
        let terminated = makeSession(
            id: UUID(),
            liveness: .terminated,
            lastObservedAt: baseline
        )

        let checks = tracker.checkStaleness(
            of: [stale, fresh, terminated],
            observation: stamp(wallOffset: 500, uptime: 600, sequence: 2)
        )

        #expect(checks.map(\.sessionID) == [stale.id, fresh.id, terminated.id])
        #expect(checks.map(\.liveness) == [.stale, .live, .terminated])
    }

    @Test func wallClockRollbackDoesNotHideMonotonicStaleness() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(
            lastObservedAt: baseline.addingTimeInterval(60)
        )

        tracker.checkStaleness(
            of: [session],
            observation: stamp(
                wallOffset: 0,
                uptime: 400,
                sequence: 2
            )
        )

        #expect(session.liveness == .stale)
        #expect(session.lastObservedAt == baseline.addingTimeInterval(60))
    }

    @Test func failedClockRollbackNeverRevivesStaleSession() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(
            liveness: .stale,
            lastObservedAt: baseline
        )

        tracker.checkStaleness(
            of: [session],
            observation: stamp(
                wallOffset: -500,
                uptime: 500,
                sequence: 2
            )
        )

        #expect(session.liveness == .stale)
        #expect(session.lastObservedAt == baseline)
    }

    @Test func outOfOrderSuccessfulEvidenceCannotReviveStaleSession() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(
            liveness: .stale,
            lastObservedAt: baseline,
            uptime: 500,
            generation: 2,
            sequence: 5
        )

        let accepted = tracker.recordObservation(
            of: session,
            observation: stamp(
                wallOffset: 1_000,
                uptime: 700,
                generation: 2,
                sequence: 4
            )
        )

        #expect(!accepted)
        #expect(session.liveness == .stale)
        #expect(session.lastObservedAt == baseline)
    }

    @Test func outOfOrderFailedCheckCannotStaleNewerEvidence() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(
            lastObservedAt: baseline,
            uptime: 500,
            generation: 2,
            sequence: 5
        )

        tracker.checkStaleness(
            of: [session],
            observation: stamp(
                wallOffset: 1_000,
                uptime: 1_500,
                generation: 2,
                sequence: 4
            )
        )

        #expect(session.liveness == .live)
    }

    @Test func newerSuccessfulEvidenceCannotReviveTerminatedSession() {
        let tracker = AgentSessionLivenessTracker(staleAfter: 300)
        let session = makeSession(lastObservedAt: baseline)
        tracker.recordTermination(of: session)

        let accepted = tracker.recordObservation(
            of: session,
            observation: stamp(wallOffset: 1, uptime: 101, sequence: 2)
        )

        #expect(!accepted)
        #expect(session.liveness == .terminated)
    }

    private func makeSession(
        id: UUID = UUID(),
        state: AgentState = .idle,
        liveness: AgentLiveness = .live,
        lastObservedAt: Date,
        uptime: TimeInterval = 100,
        generation: UInt64 = 1,
        sequence: UInt64 = 1
    ) -> AgentSession {
        AgentSession(
            id: id,
            agentType: .claudeCode,
            state: state,
            startedAt: baseline.addingTimeInterval(-1_000),
            liveness: liveness,
            lastObservedAt: lastObservedAt,
            lastObservedUptime: uptime,
            observationGeneration: generation,
            observationSequence: sequence
        )
    }

    private func stamp(
        wallOffset: TimeInterval,
        uptime: TimeInterval,
        generation: UInt64 = 1,
        sequence: UInt64
    ) -> AgentObservationStamp {
        AgentObservationStamp(
            wallTime: baseline.addingTimeInterval(wallOffset),
            uptime: uptime,
            generation: generation,
            sequence: sequence
        )
    }
}
