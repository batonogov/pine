//
//  AgentSessionLivenessTracker.swift
//  Pine
//
//  Evaluates the freshness of process evidence for detected agent sessions.
//

import Foundation

/// Ordered process-evidence timestamp.
///
/// `wallTime` is presentation metadata only. Freshness uses `uptime`, while
/// `generation` + `sequence` provide a total order across coordinator
/// stop/restart cycles and individual polls. This prevents wall-clock changes
/// and delayed results from moving a session backwards through its lifecycle.
nonisolated struct AgentObservationStamp: Sendable, Equatable, Comparable {
    let wallTime: Date
    let uptime: TimeInterval
    let generation: UInt64
    let sequence: UInt64

    init(
        wallTime: Date,
        uptime: TimeInterval,
        generation: UInt64 = 0,
        sequence: UInt64
    ) {
        precondition(
            uptime.isFinite && uptime >= 0,
            "Agent observation uptime must be finite and non-negative"
        )
        self.wallTime = wallTime
        self.uptime = uptime
        self.generation = generation
        self.sequence = sequence
    }

    static func == (lhs: AgentObservationStamp, rhs: AgentObservationStamp) -> Bool {
        lhs.generation == rhs.generation && lhs.sequence == rhs.sequence
    }

    static func < (lhs: AgentObservationStamp, rhs: AgentObservationStamp) -> Bool {
        if lhs.generation != rhs.generation {
            return lhs.generation < rhs.generation
        }
        return lhs.sequence < rhs.sequence
    }
}

/// Immutable projection of one liveness assessment.
nonisolated struct AgentLivenessCheck: Sendable, Equatable {
    let sessionID: UUID
    let liveness: AgentLiveness
    let lastObservedAt: Date
    let checkedAt: Date
}

/// Main-actor policy object for session liveness.
///
/// `AgentSession.liveness` is the sole observable source of truth. The tracker
/// intentionally owns no parallel dictionary: it applies observations and
/// assessments directly to the session so model and UI cannot diverge.
@MainActor
final class AgentSessionLivenessTracker {
    /// Maximum age of the last successful process observation before its
    /// evidence becomes stale.
    let staleAfter: TimeInterval

    init(staleAfter: TimeInterval = 300) {
        precondition(
            staleAfter.isFinite && staleAfter >= 0,
            "Agent liveness timeout must be finite and non-negative"
        )
        self.staleAfter = staleAfter
    }

    /// Records that a successful full process snapshot contained `session`.
    ///
    /// Returns `false` for out-of-order evidence and for a terminated session;
    /// neither may be revived in place.
    @discardableResult
    func recordObservation(
        of session: AgentSession,
        observation: AgentObservationStamp
    ) -> Bool {
        session.recordObservation(observation)
    }

    /// Records authoritative absence from a successful full process snapshot.
    func recordTermination(of session: AgentSession) {
        session.applyLiveness(.terminated)
    }

    /// Reassesses sessions after a process snapshot could not be obtained.
    ///
    /// Logical activity never bypasses this check: an `.executing` session
    /// with no fresh process evidence is just as uncertain as an idle one.
    @discardableResult
    func checkStaleness(
        of sessions: [AgentSession],
        observation: AgentObservationStamp
    ) -> [AgentLivenessCheck] {
        sessions.map { session in
            if session.liveness == .live,
               observation > session.lastObservationStamp {
                let evidenceAge = max(
                    0,
                    observation.uptime - session.lastObservationStamp.uptime
                )
                if evidenceAge >= staleAfter {
                    session.applyLiveness(.stale)
                }
            }
            return AgentLivenessCheck(
                sessionID: session.id,
                liveness: session.liveness,
                lastObservedAt: session.lastObservedAt,
                checkedAt: observation.wallTime
            )
        }
    }
}
