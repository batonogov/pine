//
//  AgentHistoryChangeSetTests.swift
//  PineTests
//
//  Persistence and privacy tests for the verified undo contract (#1183).
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent History Verified Change Set")
struct AgentHistoryChangeSetTests {

    @Test("A verified change set round-trips through the project log")
    func roundTrip() throws {
        let entry = AgentHistoryChangeSetFixtures.entry()

        let data = try AgentHistoryStore.makeEncoder().encode(entry)
        let decoded = try AgentHistoryStore.makeDecoder().decode(
            AgentHistoryEntry.self,
            from: data
        )

        #expect(decoded == entry)
        #expect(decoded.verifiedChangeSet == entry.verifiedChangeSet)
    }

    @Test("The project log stores no patch bytes or machine-specific paths")
    func projectLogContainsOnlyOpaquePayloadReference() throws {
        let entry = AgentHistoryChangeSetFixtures.entry()
        let data = try AgentHistoryStore.makeEncoder().encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("private source that must not enter git"))
        #expect(!json.contains("/Users/example/private-project"))
        #expect(!json.contains("unifiedDiff"))
        #expect(!json.contains("patchContents"))
        #expect(json.contains(entry.verifiedChangeSet?.inversePayload.blobID.uuidString ?? "missing"))
        #expect(json.contains("\"storage\" : \"applicationSupport\""))
    }

    @Test("Unknown operation and storage values decode without becoming trusted")
    func unknownValuesDecodeFailClosed() throws {
        let operation = try JSONDecoder().decode(
            AgentHistoryFileOperation.self,
            from: Data("\"futureOperation\"".utf8)
        )
        let storage = try JSONDecoder().decode(
            AgentHistoryPrivateStorage.self,
            from: Data("\"projectRelativeFile\"".utf8)
        )

        #expect(operation == .unsupported("futureOperation"))
        #expect(storage == .unsupported("projectRelativeFile"))
    }

    @Test("Unsupported enum cases cannot encode aliases of trusted values")
    func unsupportedAliasesCannotRoundTripAsTrusted() {
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode(
                AgentHistoryFileOperation.unsupported("modify")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode(
                AgentHistoryRecordedFileKind.unsupported("regularFile")
            )
        }
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode(
                AgentHistoryPrivateStorage.unsupported("applicationSupport")
            )
        }
    }

    @Test("A malformed optional change set does not make the history log unreadable")
    func malformedOptionalContractFailsClosed() throws {
        let data = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000301",
          "sessionID": "00000000-0000-0000-0000-000000000302",
          "agentTypeRaw": "codex",
          "startedAt": 1000,
          "affectedFiles": ["tracked.txt"],
          "attribution": "verified",
          "verifiedChangeSet": "malformed",
          "summary": "1 file"
        }
        """.utf8)

        let entry = try JSONDecoder().decode(AgentHistoryEntry.self, from: data)

        #expect(entry.verifiedChangeSet == nil)
        #expect(entry.undoAvailability == .unavailable(.missingVerifiedReversibleChangeSet))
    }
}

enum AgentHistoryChangeSetFixtures {
    static let digestA = String(repeating: "a", count: 64)
    static let digestB = String(repeating: "b", count: 64)
    static let digestC = String(repeating: "c", count: 64)
    static let digestD = String(repeating: "d", count: 64)
    static let digestE = String(repeating: "e", count: 64)
    static let headOID = String(repeating: "1", count: 40)

    static func fileState(
        digest: String = digestA,
        byteCount: UInt64 = 12,
        permissions: UInt16 = 0o644,
        kind: AgentHistoryRecordedFileKind = .regularFile
    ) -> AgentHistoryRecordedFileState {
        AgentHistoryRecordedFileState(
            kind: kind,
            contentSHA256: digest,
            byteCount: byteCount,
            permissions: permissions
        )
    }

    static func modifyChange(path: String = "Sources/App.swift") -> AgentHistoryRecordedFileChange {
        AgentHistoryRecordedFileChange(
            relativePath: path,
            operation: .modify,
            before: fileState(digest: digestA),
            after: fileState(digest: digestB, byteCount: 20)
        )
    }

    static func changeSet(
        id: UUID = UUID(),
        historyEntryID: UUID = UUID(),
        sessionID: UUID,
        schemaVersion: Int = VerifiedAgentChangeSet.currentSchemaVersion,
        provenance: AgentHistoryWriterProvenance? = nil,
        workspace: AgentHistoryWorkspaceIdentity? = nil,
        changes: [AgentHistoryRecordedFileChange]? = nil,
        authority: AgentHistoryPrivateAuthorityReference? = nil,
        authorityRecordID: UUID = UUID(),
        inversePayload: AgentHistoryInversePayloadReference? = nil,
        payloadBlobID: UUID = UUID()
    ) -> VerifiedAgentChangeSet {
        VerifiedAgentChangeSet(
            id: id,
            historyEntryID: historyEntryID,
            schemaVersion: schemaVersion,
            capturedAt: Date(timeIntervalSince1970: 1_000),
            provenance: provenance ?? AgentHistoryWriterProvenance(
                sessionID: sessionID,
                writerInstanceID: UUID(),
                processIdentifier: 42,
                processGeneration: 3,
                firstEventSequence: 10,
                lastEventSequence: 12
            ),
            workspace: workspace ?? AgentHistoryWorkspaceIdentity(
                privateWorkspaceID: UUID(),
                headOID: headOID,
                indexSHA256: digestD
            ),
            changes: changes ?? [modifyChange()],
            authority: authority ?? AgentHistoryPrivateAuthorityReference(
                storage: .applicationSupport,
                recordID: authorityRecordID,
                manifestFormatVersion:
                    AgentHistoryPrivateAuthorityReference.currentManifestFormatVersion,
                canonicalContractSHA256: digestC
            ),
            inversePayload: inversePayload ?? AgentHistoryInversePayloadReference(
                storage: .applicationSupport,
                blobID: payloadBlobID,
                formatVersion: AgentHistoryInversePayloadReference.currentFormatVersion,
                byteCount: 256,
                sha256: digestE
            )
        )
    }

    static func entry(
        id: UUID = UUID(),
        attribution: AgentHistoryAttribution = .verified,
        sessionID: UUID = UUID(),
        changes: [AgentHistoryRecordedFileChange]? = nil,
        changeSetID: UUID = UUID(),
        authorityRecordID: UUID = UUID(),
        payloadBlobID: UUID = UUID(),
        changeSetTransform: ((VerifiedAgentChangeSet) -> VerifiedAgentChangeSet)? = nil
    ) -> AgentHistoryEntry {
        let entryID = id
        let resolvedChanges = changes ?? [modifyChange()]
        let originalChangeSet = changeSet(
            id: changeSetID,
            historyEntryID: entryID,
            sessionID: sessionID,
            changes: resolvedChanges,
            authorityRecordID: authorityRecordID,
            payloadBlobID: payloadBlobID
        )
        let resolvedChangeSet = changeSetTransform?(originalChangeSet) ?? originalChangeSet
        return AgentHistoryEntry(
            id: entryID,
            sessionID: sessionID,
            agentTypeRaw: "codex",
            startedAt: Date(timeIntervalSince1970: 900),
            endedAt: Date(timeIntervalSince1970: 1_100),
            affectedFiles: resolvedChanges.map(\.relativePath),
            attribution: attribution,
            verifiedChangeSet: resolvedChangeSet,
            summary: "\(resolvedChanges.count) files"
        )
    }
}
