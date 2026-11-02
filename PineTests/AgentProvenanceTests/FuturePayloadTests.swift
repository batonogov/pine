import CryptoKit
import Foundation
import Testing

@testable import Pine

struct FuturePayloadTests {
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func event(projectID: UUID, path: String) -> AgentEventEnvelope {
        AgentEventEnvelope(
            projectID: projectID, sessionID: UUID(), agentTypeRaw: "claudeCode",
            process: AgentProcessIdentity(terminalID: UUID(), processGeneration: 1),
            location: AgentEventLocation(worktreePath: path, cwd: path),
            cursorValue: 1, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            source: .explicitAgentEvent, trustLevel: .verified
        )
    }

    private func replacingPayload(_ data: Data, with payload: String) throws -> Data {
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"payload\":{\"kind\":\"none\"}"))
        return Data(text.replacingOccurrences(
            of: "\"payload\":{\"kind\":\"none\"}", with: "\"payload\":\(payload)"
        ).utf8)
    }

    private func frame(_ payload: Data) -> Data {
        var data = SecureAgentEventJournal.frameMagic
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        data.append(contentsOf: SHA256.hash(data: payload))
        return data
    }

    @Test(arguments: ["true", "9007199254740993", "18446744073709551615", "-9223372036854775808",
                      "0.12345678901234567890123456789012345678", "1.000000000000000000000000000000000001",
                      "1e+20", "1e-07", "1.0", "{\"a\u{301}\":1,\"ss\":2}"])
    func compactedFuturePayloadSurvivesOpenAndFurtherCompaction(value: String) async throws {
        try await checkCompactedFuturePayload(value: value, expectation: .healthy)
    }

    @Test(arguments: ["1e999", "1e-999", "1e128", "1e-129",
                      "1.000000000000000000000000000000000000001",
                      #"{"é":1,"e\u0301":2}"#, #"{"same":1,"same":2}"#])
    func unsupportedFutureJournalIsRefusedWithoutMutation(value: String) async throws {
        try await checkCompactedFuturePayload(value: value, expectation: .unsupported)
    }

    @Test(arguments: ["1e", "01", "truefalse", #"{"x":1,}"#,
                      #"{"number":1e999,}"#, #"{"same":1,"same":truefalse}"#])
    func malformedJSONRemainsRecoverableCorruption(value: String) async throws {
        try await checkCompactedFuturePayload(value: value, expectation: .corrupt)
    }

    private enum ReadExpectation { case healthy, unsupported, corrupt }

    private func checkCompactedFuturePayload(value: String, expectation: ReadExpectation) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pine-1682-\(UUID())")
        let worktree = root.appendingPathComponent("worktree")
        let storage = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try AgentEventStoreScope(projectID: UUID(), worktreeURL: worktree)
        let limits = try AgentEventStoreLimits(maxRecords: 2)
        let prefix = event(projectID: scope.projectID, path: scope.worktreePath)
        let original = event(projectID: scope.projectID, path: scope.worktreePath)
        let seed = try SecureAgentEventJournal.open(scope: scope, storageRoot: storage, limits: limits)
        let payload = "{\"kind\":\"future\",\"value\":\(value)}"
        let envelopeJSON = try replacingPayload(encoder().encode(original), with: payload)
        let digest = SHA256.hash(data: envelopeJSON).map { String(format: "%02x", $0) }.joined()
        let checkpoint = AgentEventJournalCheckpoint(
            projectID: scope.projectID, worktreePath: scope.worktreePath, lastSequence: 2,
            streamWatermarks: [AgentEventStreamIdentity(envelope: prefix): 1,
                               AgentEventStreamIdentity(envelope: original): 1],
            recentIdentities: [AgentEventRecentIdentity(id: original.id, digest: digest, sequence: 2)]
        )
        // Future-writer fixture: compute the digest from the actual future JSON,
        // not an envelope already decoded (and possibly degraded) by this build.
        let checkpointJSON = try encoder().encode(checkpoint)
        let checkpointText = try #require(String(data: checkpointJSON, encoding: .utf8))
        let envelopeText = try #require(String(data: envelopeJSON, encoding: .utf8))
        var journal = frame(Data(("{\"checkpoint\":" + checkpointText
            + ",\"kind\":\"checkpoint\",\"version\":1}").utf8))
        let prefixData = try encoder().encode(StoredAgentEvent(sequence: 1, envelope: prefix))
        let prefixText = try #require(String(data: prefixData, encoding: .utf8))
        journal.append(frame(Data(("{\"event\":" + prefixText + ",\"kind\":\"event\",\"version\":1}").utf8)))
        journal.append(frame(Data(("{\"event\":{\"envelope\":" + envelopeText
            + ",\"sequence\":2},\"kind\":\"event\",\"version\":1}").utf8)))
        try journal.write(to: seed.journal.journalURL)
        if case .unsupported = expectation {
            for _ in 0..<2 {
                #expect(throws: AgentEventStoreError.unsafeStorage(.unsupportedPayload)) {
                    try AgentEventProvenanceStore(scope: scope, storageRoot: storage, limits: limits)
                }
                #expect(try Data(contentsOf: seed.journal.journalURL) == journal)
                let files = try FileManager.default.contentsOfDirectory(atPath: seed.journal.scopeDirectoryURL.path)
                #expect(files == [SecureAgentEventJournal.journalFileName])
            }
            return
        }
        let store = try AgentEventProvenanceStore(scope: scope, storageRoot: storage, limits: limits)
        let snapshot = await store.snapshot()
        if case .corrupt = expectation {
            guard case .recovered(let report) = snapshot.integrity else {
                Issue.record("Malformed JSON must remain recoverable corruption")
                return
            }
            #expect(report.kind == .invalidCheckpoint)
            #expect(try Data(contentsOf: seed.journal.journalURL) != journal)
            return
        }
        #expect(snapshot.integrity == .healthy)
        #expect(snapshot.records.count == 2)
        #expect(try Data(contentsOf: seed.journal.journalURL) == journal)
        if let retained = snapshot.records.last {
            #expect(try SecureAgentEventJournal.digest(of: retained.envelope) == digest)
            #expect(await store.append(retained.envelope) == .duplicate(existingSequence: 2))
        }
        let next = event(projectID: scope.projectID, path: scope.worktreePath)
        #expect(await store.append(next) == .appended(sequence: 3))
        let restarted = try AgentEventProvenanceStore(scope: scope, storageRoot: storage, limits: limits)
        let compacted = await restarted.snapshot()
        #expect(compacted.integrity == .healthy)
        #expect(compacted.lastSequence == 3)
        #expect(compacted.records.map(\.sequence) == [2, 3])
        let future = try #require(compacted.records.first)
        #expect(!future.envelope.payload.isKnown)
        #expect(try SecureAgentEventJournal.digest(of: future.envelope) == digest)
        #expect(await restarted.append(future.envelope) == .duplicate(existingSequence: 2))
    }

    @Test(arguments: [
        ["9007199254740992", "9007199254740993"],
        ["18446744073709551614", "18446744073709551615"],
        ["1.000000000000000000000000000000000001", "1.000000000000000000000000000000000002"],
        ["0.12345678901234567890123456789012345677", "0.12345678901234567890123456789012345678"]
    ])
    func distinctFutureNumbersDoNotCollapse(values: [String]) async throws {
        let original = event(projectID: UUID(), path: "/tmp")
        let encoded = try encoder().encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try AgentEventJSON.decode(AgentEventEnvelope.self, from: replacingPayload(
            encoded, with: "{\"kind\":\"future\",\"value\":\(values[0])}"
        ), using: decoder)
        let second = try AgentEventJSON.decode(AgentEventEnvelope.self, from: replacingPayload(
            encoded, with: "{\"kind\":\"future\",\"value\":\(values[1])}"
        ), using: decoder)
        #expect(try SecureAgentEventJournal.digest(of: first) != SecureAgentEventJournal.digest(of: second))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pine-1682-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try AgentEventStoreScope(projectID: original.projectID, worktreeURL: URL(fileURLWithPath: "/tmp"))
        let store = try AgentEventProvenanceStore(scope: scope, storageRoot: root)
        #expect(await store.append(first) == .appended(sequence: 1))
        #expect(await store.append(first) == .duplicate(existingSequence: 1))
        #expect(await store.append(second) == .rejected(.identityCollision))
    }

    @Test func booleanRemainsBooleanRatherThanNumberOrNone() throws {
        let json = Data(#"{"kind":"future","value":[true,false,1,0,null,{"nested":"ok"}]}"#.utf8)
        let payload = try AgentEventJSON.decode(AgentEventPayload.self, from: json)
        #expect(payload != .none)
        #expect(try encoder().encode(payload) == json)
    }

    @Test(arguments: ["1e999", "1e-999", "1e128", "1e-129",
                      "1.000000000000000000000000000000000000001",
                      "12345678901234567890123456789012345678901234567890"])
    func unsupportedNumbersAreRejected(value: String) throws {
        let json = Data("{\"kind\":\"future\",\"value\":\(value)}".utf8)
        #expect(throws: (any Error).self) { try AgentEventJSON.decode(AgentEventPayload.self, from: json) }
        let original = event(projectID: UUID(), path: "/tmp")
        let payloadText = try #require(String(data: json, encoding: .utf8))
        let data = try replacingPayload(encoder().encode(original), with: payloadText)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(throws: (any Error).self) {
            try AgentEventJSON.decode(AgentEventEnvelope.self, from: data, using: decoder)
        }
    }

    @Test func genericDecoderCannotSilentlyRoundNumbers() {
        for value in ["1", "1.000000000000000000000000000000000000001",
                      "1.000000000000000000000000000000000000002"] {
            let data = Data("{\"kind\":\"future\",\"nested\":[{\"number\":\(value)}]}".utf8)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentEventPayload.self, from: data) }
        }
    }

    @Test func exactNumbersRetainWriterSpellingAndCanonicalKeyOrder() throws {
        let first = Data(#"{"value":{"n":1.25e-2,"escaped":"1.5\\\"-99","bool":true},"kind":"future"}"#.utf8)
        let second = Data(#"{"kind":"future","value":{"bool":true,"escaped":"1.5\\\"-99","n":0.0125}}"#.utf8)
        let left = try AgentEventJSON.decode(AgentEventPayload.self, from: first)
        let right = try AgentEventJSON.decode(AgentEventPayload.self, from: second)
        guard case .unknown(let leftJSON) = left, case .unknown(let rightJSON) = right else {
            Issue.record("Expected untyped payloads")
            return
        }
        let canonicalLeft = try leftJSON.canonicalData()
        let canonicalRight = try rightJSON.canonicalData()
        #expect(canonicalLeft != canonicalRight)
        #expect(try #require(String(data: canonicalLeft, encoding: .utf8)).contains("1.25e-2"))
        #expect(try #require(String(data: canonicalRight, encoding: .utf8)).contains("0.0125"))
    }

    @Test(arguments: [
        #"{"kind":"future","é":1,"e\u0301":2}"#,
        #"{"kind":"future","x":1,"x":2}"#,
        #"{"kind":"future","nested":{"é":"a","e\u0301":"b"}}"#
    ])
    func ambiguousObjectKeysAreRejected(json: String) {
        #expect(throws: (any Error).self) {
            try AgentEventJSON.decode(AgentEventPayload.self, from: Data(json.utf8))
        }
    }

    @Test func canonicalKeysMatchExistingWriter() throws {
        let object = AgentEventJSON.object([
            "z": .string("/quoted\\\""), "é": .bool(true), "e": .null,
            "x2": .signed(2), "x10": .unsigned(10), "Z": .decimal(Decimal(string: "1.25") ?? 0),
            "a\u{301}": .null, "ss": .null, "e\u{300}": .null, "😀": .null, "𐀀": .null
        ])
        #expect(try object.canonicalData() == encoder().encode(object))
    }

    @Test func unknownCannotAliasKnownPayloadOnEncode() {
        let payload = AgentEventPayload.unknown(.object(["kind": .string("none")]))
        #expect(throws: (any Error).self) { try encoder().encode(payload) }
    }
}
