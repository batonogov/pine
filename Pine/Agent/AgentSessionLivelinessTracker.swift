//
//  AgentSessionLivelinessTracker.swift
//  Pine
//
//  Tracks the liveliness of agent sessions — whether each session's backing
//  terminal process is still alive, has gone stale (idle past a threshold),
//  or has been explicitly terminated (vision #933, Phase 4 — Multi-agent UX:
//  "make ambiguity and stale sessions visible").
//
//  The tracker is `@MainActor @Observable` so SwiftUI views can observe
//  liveliness changes directly. `AgentLivelinessCheck` is a `nonisolated`
//  Sendable value type so checks can be passed across actor boundaries
//  (e.g. from a background staleness sweep) without concurrency violations.
//

import Foundation

/// Immutable snapshot of one session's liveliness at a point in time.
/// `nonisolated` + `Sendable` so it can cross actor boundaries freely.
nonisolated struct AgentLivelinessCheck: Sendable, Equatable {
    /// The session whose liveliness was assessed.
    let sessionID: UUID
    /// The assessed liveliness at `checkedAt`.
    let liveliness: AgentLiveliness
    /// When the assessment was made.
    let checkedAt: Date
}

/// `@MainActor @Observable` store tracking per-session `AgentLiveliness`.
///
/// Follows the same pattern as `AgentActivityStore`: a single observable
/// source of truth for the UI, with a value-type projection
/// (`AgentLivelinessCheck`) for cross-actor and snapshot-test use.
@MainActor
@Observable
final class AgentLivelinessTracker {
    /// Sessions older than this (seconds) whose `state` is `.idle` are
    /// considered stale. 5 minutes — long enough to avoid false positives
    /// during brief thinking pauses, short enough to surface dead sessions
    /// before the user is misled.
    var timeoutInterval: TimeInterval = 300

    /// Per-session liveliness, keyed by session ID. A session not present in
    /// this dictionary defaults to `.live` (see `liveliness(for:)`).
    private(set) var livelinessBySession: [UUID: AgentLiveliness] = [:]

    init(timeoutInterval: TimeInterval = 300) {
        self.timeoutInterval = timeoutInterval
    }

    // MARK: - Mutations

    /// Records the liveliness for a session. Overwrites any prior value.
    func update(sessionID: UUID, liveliness: AgentLiveliness) {
        livelinessBySession[sessionID] = liveliness
    }

    /// Removes a session from tracking (e.g. after the user dismisses it).
    func remove(sessionID: UUID) {
        livelinessBySession.removeValue(forKey: sessionID)
    }

    /// Clears all tracked liveliness.
    func clear() {
        livelinessBySession.removeAll()
    }

    // MARK: - Queries

    /// Returns the tracked liveliness for `sessionID`, or `.live` if the
    /// session has no recorded liveliness (the safe default — a session we
    /// have not assessed is assumed alive).
    func liveliness(for sessionID: UUID) -> AgentLiveliness {
        livelinessBySession[sessionID] ?? .live
    }

    // MARK: - Staleness sweep

    /// Assesses each session in `activeSessions` and records its liveliness.
    ///
    /// A session is marked `.stale` when:
    /// - its `startedAt` is older than `timeoutInterval` ago, **and**
    /// - its `state` is `.idle` (active sessions — thinking/executing — are
    ///   never stale regardless of age).
    ///
    /// A session already marked `.terminated` stays `.terminated` —
    /// termination is a terminal state that staleness cannot override.
    ///
    /// Returns the checks for every session assessed, in the order given.
    @discardableResult
    func checkStaleness(
        activeSessions: [AgentSession]
    ) -> [AgentLivelinessCheck] {
        let now = Date()
        var checks: [AgentLivelinessCheck] = []
        checks.reserveCapacity(activeSessions.count)

        for session in activeSessions {
            let assessed = assess(session: session, now: now)
            livelinessBySession[session.id] = assessed
            checks.append(
                AgentLivelinessCheck(
                    sessionID: session.id,
                    liveliness: assessed,
                    checkedAt: now
                )
            )
        }

        return checks
    }

    // MARK: - Internals

    /// Determines the liveliness for one session at a reference time.
    /// Pure function of the session's current state — does not mutate the
    /// tracker. Extracted so the staleness rule is directly unit-testable.
    private func assess(
        session: AgentSession,
        now: Date
    ) -> AgentLiveliness {
        // Termination is sticky: once terminated, always terminated.
        if livelinessBySession[session.id] == .terminated {
            return .terminated
        }

        // Active sessions are never stale regardless of age.
        if session.state.isActive {
            return .live
        }

        // An idle session older than the threshold is stale.
        let age = now.timeIntervalSince(session.startedAt)
        if session.state == .idle, age > timeoutInterval {
            return .stale
        }

        return .live
    }
}
