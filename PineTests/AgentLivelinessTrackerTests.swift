//
//  AgentLivelinessTrackerTests.swift
//  PineTests
//
//  Tests for AgentLivelinessTracker and AgentLiveliness (vision #933 §4,
//  Multi-agent UX: staleness tracking).
//

import Testing
import Foundation
@testable import Pine

@Suite("AgentLivelinessTracker")
@MainActor
struct AgentLivelinessTrackerTests {

    // MARK: - AgentLiveliness computed properties

    @Test func liveliness_displayNames() {
        #expect(AgentLiveliness.live.displayName == "Live")
        #expect(AgentLiveliness.stale.displayName == "Stale")
        #expect(AgentLiveliness.terminated.displayName == "Terminated")
    }

    @Test func liveliness_glyphNames() {
        #expect(AgentLiveliness.live.glyphName == nil)
        #expect(AgentLiveliness.stale.glyphName == "clock")
        #expect(AgentLiveliness.terminated.glyphName == "xmark")
    }

    @Test func liveliness_isStale() {
        #expect(AgentLiveliness.live.isStale == false)
        #expect(AgentLiveliness.stale.isStale == true)
        #expect(AgentLiveliness.terminated.isStale == true)
    }

    // MARK: - checkStaleness

    @Test func freshIdleSession_isLive() {
        let tracker = AgentLivelinessTracker()
        let session = AgentSession(
            agentType: .claudeCode,
            state: .idle,
            startedAt: Date()
        )

        let checks = tracker.checkStaleness(activeSessions: [session])

        #expect(checks.count == 1)
        #expect(checks[0].liveliness == .live)
        #expect(tracker.liveliness(for: session.id) == .live)
    }

    @Test func oldIdleSession_isStale() {
        let tracker = AgentLivelinessTracker(timeoutInterval: 300)
        let sixMinutesAgo = Date().addingTimeInterval(-360)
        let session = AgentSession(
            agentType: .claudeCode,
            state: .idle,
            startedAt: sixMinutesAgo
        )

        let checks = tracker.checkStaleness(activeSessions: [session])

        #expect(checks.count == 1)
        #expect(checks[0].liveliness == .stale)
        #expect(tracker.liveliness(for: session.id) == .stale)
    }

    @Test func thinkingSession_neverStaleRegardlessOfAge() {
        let tracker = AgentLivelinessTracker(timeoutInterval: 300)
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let session = AgentSession(
            agentType: .codex,
            state: .thinking,
            startedAt: oneHourAgo
        )

        let checks = tracker.checkStaleness(activeSessions: [session])

        #expect(checks[0].liveliness == .live)
    }

    @Test func executingSession_neverStaleRegardlessOfAge() {
        let tracker = AgentLivelinessTracker(timeoutInterval: 300)
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let session = AgentSession(
            agentType: .aider,
            state: .executing,
            startedAt: oneHourAgo
        )

        let checks = tracker.checkStaleness(activeSessions: [session])

        #expect(checks[0].liveliness == .live)
    }

    // MARK: - update / liveliness round-trip

    @Test func update_setsLiveliness_forSession() {
        let tracker = AgentLivelinessTracker()
        let id = UUID()

        tracker.update(sessionID: id, liveliness: .stale)
        #expect(tracker.liveliness(for: id) == .stale)

        tracker.update(sessionID: id, liveliness: .live)
        #expect(tracker.liveliness(for: id) == .live)
    }

    @Test func liveliness_defaultsToLiveForUnknownSession() {
        let tracker = AgentLivelinessTracker()
        #expect(tracker.liveliness(for: UUID()) == .live)
    }

    // MARK: - Terminated is sticky

    @Test func terminatedSession_staysTerminated() {
        let tracker = AgentLivelinessTracker()
        let sixMinutesAgo = Date().addingTimeInterval(-360)
        let session = AgentSession(
            agentType: .claudeCode,
            state: .idle,
            startedAt: sixMinutesAgo
        )

        tracker.update(sessionID: session.id, liveliness: .terminated)

        let checks = tracker.checkStaleness(activeSessions: [session])

        #expect(checks[0].liveliness == .terminated)
        #expect(tracker.liveliness(for: session.id) == .terminated)
    }

    // MARK: - Multiple sessions

    @Test func mixedSessions_eachAssessedIndependently() {
        let tracker = AgentLivelinessTracker(timeoutInterval: 300)
        let now = Date()
        let fresh = AgentSession(
            agentType: .claudeCode,
            state: .idle,
            startedAt: now
        )
        let old = AgentSession(
            agentType: .codex,
            state: .idle,
            startedAt: now.addingTimeInterval(-360)
        )
        let active = AgentSession(
            agentType: .aider,
            state: .executing,
            startedAt: now.addingTimeInterval(-3600)
        )

        let checks = tracker.checkStaleness(
            activeSessions: [fresh, old, active]
        )

        #expect(checks.count == 3)
        #expect(checks[0].liveliness == .live)
        #expect(checks[1].liveliness == .stale)
        #expect(checks[2].liveliness == .live)
    }

    // MARK: - remove / clear

    @Test func remove_dropsSessionFromTracking() {
        let tracker = AgentLivelinessTracker()
        let id = UUID()

        tracker.update(sessionID: id, liveliness: .stale)
        #expect(tracker.liveliness(for: id) == .stale)

        tracker.remove(sessionID: id)
        #expect(tracker.liveliness(for: id) == .live)
    }

    @Test func clear_resetsAllSessions() {
        let tracker = AgentLivelinessTracker()
        let a = UUID()
        let b = UUID()

        tracker.update(sessionID: a, liveliness: .stale)
        tracker.update(sessionID: b, liveliness: .terminated)
        tracker.clear()

        #expect(tracker.liveliness(for: a) == .live)
        #expect(tracker.liveliness(for: b) == .live)
    }
}
