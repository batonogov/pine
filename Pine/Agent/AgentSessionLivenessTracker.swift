//
//  AgentSessionLivenessTracker.swift
//  Pine
//
//  Evaluates the freshness of process evidence for detected agent sessions.
//

import Foundation

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
    func recordObservation(of session: AgentSession, at date: Date) {
        session.recordObservation(at: date)
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
        at now: Date
    ) -> [AgentLivenessCheck] {
        sessions.map { session in
            if session.liveness != .terminated {
                let evidenceAge = now.timeIntervalSince(session.lastObservedAt)
                session.applyLiveness(evidenceAge >= staleAfter ? .stale : .live)
            }
            return AgentLivenessCheck(
                sessionID: session.id,
                liveness: session.liveness,
                lastObservedAt: session.lastObservedAt,
                checkedAt: now
            )
        }
    }
}
