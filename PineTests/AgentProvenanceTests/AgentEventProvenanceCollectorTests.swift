//
//  AgentEventProvenanceCollectorTests.swift
//  PineTests
//
//  Tests for the AgentEventProvenanceCollector seam and its no-op default
//  (epic #933, slice 1 — trusted event provenance).
//

import Foundation
import Testing

@testable import Pine

nonisolated struct AgentEventProvenanceCollectorTests {

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

    @Test func actorCollector_canCaptureAcrossIsolationDomains() async {
        // An actor is the natural serialization boundary for a provenance
        // stream. Recording from a detached task proves the protocol and its
        // Sendable envelope are not accidentally MainActor-isolated.
        let collector = CapturingCollector()
        let first = makeEnvelope()
        let second = makeEnvelope()
        await Task.detached {
            await collector.record(first)
            await collector.record(second)
        }.value

        let recorded = await collector.snapshot()
        #expect(recorded.count == 2)
        #expect(recorded[0] == first)
        #expect(recorded[1] == second)
    }
}

/// An actor-backed collector proving the seam supports serialized persistence
/// without unchecked Sendable conformance.
actor CapturingCollector: AgentEventProvenanceCollector {
    private var recorded: [AgentEventEnvelope] = []

    func record(_ envelope: AgentEventEnvelope) async {
        recorded.append(envelope)
    }

    func snapshot() -> [AgentEventEnvelope] {
        recorded
    }
}
