//
//  AgentEventEnvelopeTests.swift
//  PineTests
//
//  Tests for AgentEventEnvelope and its supporting types (epic #933, slice 1 —
//  trusted event provenance): TrustLevel, EventSource, payloads, and
//  forward-compatible Codable behavior.
//

import Foundation
import Testing

@testable import Pine

struct AgentEventEnvelopeTests {

    // MARK: - Helpers

    /// A known-valid UUID fixture. Aborts only on a malformed fixture string
    /// (a programmer error), never on input data, so no force-unwrap is used.
    private func known(_ raw: String) -> UUID {
        guard let id = UUID(uuidString: raw) else {
            fatalError("Invalid fixture UUID string: \(raw)")
        }
        return id
    }

    private func sampleEnvelope(
        trustLevel: TrustLevel = .inferred,
        payload: AgentEventPayload = .none
    ) -> AgentEventEnvelope {
        AgentEventEnvelope(
            projectID: known("00000000-0000-0000-0000-000000000001"),
            sessionID: known("00000000-0000-0000-0000-000000000002"),
            agentTypeRaw: "claudeCode",
            process: AgentProcessIdentity(
                terminalID: known("00000000-0000-0000-0000-000000000003"),
                processGeneration: 4
            ),
            location: AgentEventLocation(worktreePath: "/proj", cwd: "/proj/src"),
            cursorValue: 42,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            source: .explicitAgentEvent,
            trustLevel: trustLevel,
            payload: payload
        )
    }

    private func decode(_ json: [String: Any]) throws -> AgentEventEnvelope {
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        return try JSONDecoder().decode(AgentEventEnvelope.self, from: data)
    }

    // MARK: - TrustLevel

    @Test func trustLevel_hasObservedInferredVerified() {
        #expect(TrustLevel.allCases == [.observed, .inferred, .verified])
    }

    @Test func trustLevel_isVerifiedOnlyForVerified() {
        #expect(TrustLevel.observed.isVerified == false)
        #expect(TrustLevel.inferred.isVerified == false)
        #expect(TrustLevel.verified.isVerified == true)
    }

    @Test func trustLevel_isHeuristicUnlessVerified() {
        #expect(TrustLevel.observed.isHeuristic == true)
        #expect(TrustLevel.inferred.isHeuristic == true)
        #expect(TrustLevel.verified.isHeuristic == false)
    }

    @Test func trustLevel_transitionsFromObservedToVerified() {
        // Levels are ordered weakest-to-strongest; verify the full ordering.
        let ordered: [TrustLevel] = [.observed, .inferred, .verified]
        for i in 0..<(ordered.count - 1) {
            #expect(!ordered[i].isVerified)
        }
        #expect(ordered.last?.isVerified == true)
    }

    @Test func trustLevel_decodesKnownValues() throws {
        for level in TrustLevel.allCases {
            let data = try JSONEncoder().encode(level)
            let decoded = try JSONDecoder().decode(TrustLevel.self, from: data)
            #expect(decoded == level)
        }
    }

    @Test func trustLevel_unknownRawValue_failsClosedToInferred() throws {
        // An unknown trust value from a future Pine must NOT become .verified.
        let data = Data("\"quantum\"".utf8)
        let decoded = try JSONDecoder().decode(TrustLevel.self, from: data)
        #expect(decoded == .inferred)
    }

    // MARK: - EventSource

    @Test func eventSource_roundTripsKnownCases() throws {
        let known: [EventSource] = [
            .terminalProcess, .fileSystemObservation, .gitCorrelation,
            .explicitAgentEvent, .userAction,
        ]
        for source in known {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(EventSource.self, from: data)
            #expect(decoded == source)
        }
    }

    @Test func eventSource_unknownRawValue_isPreservedNotThrown() throws {
        let data = Data("\"futureSource\"".utf8)
        let decoded = try JSONDecoder().decode(EventSource.self, from: data)
        if case .unknown(let raw) = decoded {
            #expect(raw == "futureSource")
        } else {
            Issue.record("expected .unknown, got \(decoded)")
        }
    }

    @Test func eventSource_unknownRoundTripsRawValue() throws {
        let source = EventSource.unknown(raw: "experimental")
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(EventSource.self, from: data)
        #expect(decoded == source)
    }

    @Test func eventSource_stableIdentifier_resolvesKnownOnly() {
        for source: EventSource in [.terminalProcess, .gitCorrelation, .userAction] {
            #expect(EventSource(stableIdentifier: source.stableIdentifier) == source)
        }
        #expect(EventSource(stableIdentifier: "neverHeardOfIt") == nil)
    }

    // MARK: - Payload

    @Test func payload_noneRoundTrips() throws {
        let data = try JSONEncoder().encode(AgentEventPayload.none)
        let decoded = try JSONDecoder().decode(AgentEventPayload.self, from: data)
        #expect(decoded == .none)
    }

    @Test func payload_commandResultRoundTrips() throws {
        let payload = AgentEventPayload.commandResult(
            AgentCommandResult(command: "git commit -m ship", exitStatus: 0)
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AgentEventPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test func payload_fileChangeRoundTrips() throws {
        let payload = AgentEventPayload.fileChange(
            AgentFileChange(
                relativePath: "src/app.swift",
                before: ContentIdentity(content: Data("before".utf8)),
                after: ContentIdentity(content: Data("after".utf8))
            )
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AgentEventPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test func payload_unknownKind_failsClosedToNone() throws {
        // A payload kind from a newer Pine must not throw; it degrades to none
        // while provenance (identity/trust/source) stays intact.
        let json: [String: Any] = [
            "kind": "futurePayloadKind",
            "fileChange": ["relativePath": "x", "after": ["sha256Hex": String(repeating: "0", count: 64), "byteCount": 0]],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AgentEventPayload.self, from: data)
        #expect(decoded == .none)
    }

    // MARK: - Envelope Codable round-trip

    @Test func envelope_roundTripsAllFields() throws {
        let original = sampleEnvelope(
            trustLevel: .verified,
            payload: .fileChange(AgentFileChange(
                relativePath: "a/b.swift",
                before: nil,
                after: ContentIdentity(content: Data("new".utf8))
            ))
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentEventEnvelope.self, from: data)
        #expect(decoded == original)
        #expect(decoded.trustLevel == .verified)
        #expect(decoded.source == .explicitAgentEvent)
        #expect(decoded.cursorValue == 42)
    }

    @Test func envelope_hasAllRequiredProvenanceFields() {
        let envelope = sampleEnvelope()
        // Each field required by epic #933 section 1 is present and populated.
        #expect(envelope.projectID != known("00000000-0000-0000-0000-000000000000"))
        #expect(envelope.sessionID != known("00000000-0000-0000-0000-000000000000"))
        #expect(!envelope.agentTypeRaw.isEmpty)
        #expect(envelope.process.processGeneration == 4)
        #expect(envelope.process.terminalID != UUID())
        #expect(!envelope.location.worktreePath.isEmpty)
        #expect(!envelope.location.cwd.isEmpty)
        #expect(envelope.cursorValue > 0)
    }

    // MARK: - Forward-compatible decoding (fail closed)

    @Test func envelope_unknownTrustLevel_failsClosedToInferred() throws {
        let json: [String: Any] = [
            "id": "00000000-0000-0000-0000-000000000009",
            "projectID": "00000000-0000-0000-0000-000000000001",
            "sessionID": "00000000-0000-0000-0000-000000000002",
            "agentTypeRaw": "claudeCode",
            "trustLevel": "unfathomable",
        ]
        let decoded = try decode(json)
        // Unknown trust never upgrades to .verified.
        #expect(decoded.trustLevel == .inferred)
        #expect(decoded.trustLevel.isVerified == false)
    }

    @Test func envelope_missingOptionalFields_useSafeDefaults() throws {
        // A minimal envelope from an older format must still decode.
        let json: [String: Any] = [
            "id": "00000000-0000-0000-0000-000000000009",
            "projectID": "00000000-0000-0000-0000-000000000001",
            "sessionID": "00000000-0000-0000-0000-000000000002",
        ]
        let decoded = try decode(json)
        #expect(decoded.agentTypeRaw == "generic:Unknown")
        #expect(decoded.cursorValue == 0)
        #expect(decoded.payload == .none)
        #expect(decoded.trustLevel == .inferred)
        #expect(decoded.location.worktreePath == "")
    }

    @Test func envelope_unknownSource_isPreserved() throws {
        let json: [String: Any] = [
            "id": "00000000-0000-0000-0000-000000000009",
            "projectID": "00000000-0000-0000-0000-000000000001",
            "sessionID": "00000000-0000-0000-0000-000000000002",
            "source": "mcpChannel",
        ]
        let decoded = try decode(json)
        if case .unknown(let raw) = decoded.source {
            #expect(raw == "mcpChannel")
        } else {
            Issue.record("expected .unknown source")
        }
    }

    @Test func envelope_verifiedWithoutPayload_isStillVerified() {
        // .verified describes the SOURCE trust, independent of payload. A
        // presence-only verified event is legitimate.
        let envelope = sampleEnvelope(trustLevel: .verified, payload: .none)
        #expect(envelope.trustLevel.isVerified)
        #expect(envelope.payload == .none)
    }
}
