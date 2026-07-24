//
//  AgentEventProvenanceCollectorTests.swift
//  PineTests
//
//  Tests for the AgentEventProvenanceCollector seam and its no-op default
//  (epic #933, slice 1 — trusted event provenance).
//

import Foundation
import os
import Testing

@testable import Pine

struct AgentEventProvenanceCollectorTests {

    private func makeEnvelope() -> AgentEventEnvelope {
        AgentEventEnvelope(
            projectID: UUID(),
            sessionID: UUID(),
            agentTypeRaw: "claudeCode",
            process: AgentProcessIdentity(terminalID: UUID(), processGeneration: 1),
            location: AgentEventLocation(worktreePath: "/proj", cwd: "/proj"),
            cursorValue: 1,
            source: .explicitAgentEvent,
            trustLevel: .verified,
            payload: .none
        )
    }

    @Test func nullCollector_isSendableAndAdoptsProtocol() {
        // Compile-time conformance is asserted by the type annotation; this
        // confirms the null collector can be used wherever the protocol is
        // expected without optionality.
        let collector: AgentEventProvenanceCollector = NullAgentEventProvenanceCollector()
        #expect(type(of: collector) == NullAgentEventProvenanceCollector.self)
    }

    @Test func nullCollector_recordsWithoutThrowing() async {
        let collector = NullAgentEventProvenanceCollector()
        // Recording many envelopes must be a harmless no-op.
        for _ in 0..<100 {
            await collector.record(makeEnvelope())
        }
        #expect(true)
    }

    @Test func customCollector_canCaptureRecordedEnvelopes() async {
        // A test collector proving the seam is adoptable and observable.
        let collector = CapturingCollector()
        let first = makeEnvelope()
        let second = makeEnvelope()
        await collector.record(first)
        await collector.record(second)
        #expect(collector.recorded.count == 2)
        #expect(collector.recorded[0] == first)
        #expect(collector.recorded[1] == second)
    }
}

/// A thread-safe collector used to verify the seam captures envelopes.
///
/// Mirrors the production `NullAgentEventProvenanceCollector`: a `Sendable`
/// final class guarded by an unfair lock. An `actor` cannot conform to a
/// plain `Sendable` protocol under strict concurrency, so the test uses the
/// same lock-based shape production adopters will.
final class CapturingCollector: AgentEventProvenanceCollector, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [AgentEventEnvelope]())

    func record(_ envelope: AgentEventEnvelope) async {
        lock.withLock { state in state.append(envelope) }
    }

    /// The envelopes recorded so far, in insertion order.
    var recorded: [AgentEventEnvelope] { lock.withLock { $0 } }
}
