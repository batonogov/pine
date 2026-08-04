import Foundation
import Testing
@testable import Pine

@Suite("Fuzz Agent Boundary Tests", .timeLimit(.minutes(2)))
struct FuzzAgentBoundaryTests {
    @Test func fuzzEventEnvelopeDecoder() {
        var rng = SplitMix64(seed: 62)
        let decoder = JSONDecoder()

        for _ in 0..<100 {
            let length = FuzzGen.randomLength(max: 8_192, rng: &rng)
            let input = FuzzGen.randomBytes(count: length, rng: &rng)
            _ = try? decoder.decode(
                AgentEventEnvelope.self,
                from: Data(input.utf8)
            )
        }
    }

    @Test func fuzzIdentifiersPathsAndOpaqueCursors() {
        var rng = SplitMix64(seed: 63)

        for _ in 0..<100 {
            let length = FuzzGen.randomLength(max: 512, rng: &rng)
            let value = FuzzGen.randomUnicode(count: length, rng: &rng)
            _ = try? AgentID(validating: value)
            _ = try? AdapterID(validating: value)
            _ = try? ExecutableAlias(validating: value)
            _ = try? VendorReference(role: .event, value: value)
            _ = try? AdapterResumePosition(value)
            _ = try? CandidateFileChange(
                operation: .modify,
                relativePath: value
            )
        }
    }

    @Test func fuzzUnknownTrustAndSourceNeverUpgrade() throws {
        var rng = SplitMix64(seed: 64)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for index in 0..<100 {
            let envelope = AgentEventEnvelope(
                projectID: UUID(),
                sessionID: UUID(),
                agentTypeRaw: "codex",
                process: AgentProcessIdentity(
                    terminalID: UUID(),
                    processGeneration: UInt64(index + 1)
                ),
                location: AgentEventLocation(
                    worktreePath: "/tmp/project",
                    cwd: "/tmp/project"
                ),
                cursorValue: UInt64(index + 1),
                timestamp: Date(timeIntervalSince1970: 1_000),
                source: .terminalProcess,
                trustLevel: .observed
            )
            let data = try encoder.encode(envelope)
            var object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            object["source"] = FuzzGen.randomPrintable(
                count: 24,
                rng: &rng
            )
            object["trustLevel"] = "future-super-trust"
            let hostile = try JSONSerialization.data(withJSONObject: object)
            let decoded = try decoder.decode(
                AgentEventEnvelope.self,
                from: hostile
            )

            #expect(decoded.trustLevel != .verified)
            #expect(!decoded.source.canEstablishVerifiedTrust)
        }
    }

    @Test func opaqueDiagnosticsRemainRedactedUnderRandomInputs() throws {
        var rng = SplitMix64(seed: 65)

        for _ in 0..<100 {
            var randomValue = FuzzGen.randomPrintable(
                count: FuzzGen.randomLength(min: 1, max: 128, rng: &rng),
                rng: &rng
            )
            randomValue.removeAll { $0.isNewline }
            let value = "opaque-(randomValue)-value"
            let reference = try VendorReference(role: .event, value: value)
            let cursor = try AdapterResumePosition(value)

            #expect(reference.description == "<redacted:event>")
            #expect(reference.debugDescription == "<redacted:event>")
            #expect(cursor.description == "<redacted:resume-position>")
            #expect(cursor.debugDescription == "<redacted:resume-position>")
        }
    }
}
