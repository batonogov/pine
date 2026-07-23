//
//  AgentHistoryUndoPreflightTests.swift
//  PineTests
//
//  Pure fail-closed validation tests for durable Agent History undo (#1183).
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent History Undo Preflight")
struct AgentHistoryUndoPreflightTests {

    @Test("A complete contract advances only to private-authority validation")
    func completeContractIsStructurallyReady() {
        let entry = AgentHistoryChangeSetFixtures.entry()

        #expect(
            AgentHistoryUndoPreflight.evaluate(entry)
                == .readyForPrivateAuthorityValidation
        )
        #expect(entry.undoAvailability == .unavailable(.checkedUndoEngineUnavailable))
    }

    @Test("Heuristic and ambiguous attribution cannot borrow a change set")
    func unverifiedAttributionIsBlocked() {
        for attribution in [AgentHistoryAttribution.heuristic, .ambiguous] {
            let entry = AgentHistoryChangeSetFixtures.entry(attribution: attribution)
            #expect(
                AgentHistoryUndoPreflight.evaluate(entry)
                    == .blocked(.attributionNotVerified(attribution))
            )
        }
    }

    @Test("Verified attribution without a change set remains read-only")
    func missingChangeSetIsBlocked() {
        let entry = makeEntry(changeSet: nil)

        #expect(AgentHistoryUndoPreflight.evaluate(entry) == .blocked(.missingChangeSet))
        #expect(entry.undoAvailability == .unavailable(.missingVerifiedReversibleChangeSet))
    }

    @Test("Unknown schema versions fail closed")
    func futureSchemaIsBlocked() {
        let sessionID = UUID()
        let changeSet = AgentHistoryChangeSetFixtures.changeSet(
            sessionID: sessionID,
            schemaVersion: 99
        )
        let entry = makeEntry(sessionID: sessionID, changeSet: changeSet)

        #expect(
            AgentHistoryUndoPreflight.evaluate(entry)
                == .blocked(.unsupportedSchemaVersion(99))
        )
    }

    @Test("The change-set identifier must be nonzero")
    func invalidChangeSetIdentityIsBlocked() {
        let sessionID = UUID()
        let original = AgentHistoryChangeSetFixtures.changeSet(sessionID: sessionID)
        let changeSet = VerifiedAgentChangeSet(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            historyEntryID: original.historyEntryID,
            schemaVersion: original.schemaVersion,
            capturedAt: original.capturedAt,
            provenance: original.provenance,
            workspace: original.workspace,
            changes: original.changes,
            authority: original.authority,
            inversePayload: original.inversePayload
        )
        let entry = makeEntry(sessionID: sessionID, changeSet: changeSet)

        #expect(
            AgentHistoryUndoPreflight.evaluate(entry)
                == .blocked(.invalidChangeSetIdentity)
        )
    }

    @Test("The private authority must bind the exact stored entry")
    func entryIdentityMismatchIsBlocked() {
        let sessionID = UUID()
        let changeSet = AgentHistoryChangeSetFixtures.changeSet(sessionID: sessionID)
        let entry = makeEntry(
            entryID: UUID(),
            sessionID: sessionID,
            changeSet: changeSet
        )

        #expect(
            AgentHistoryUndoPreflight.evaluate(entry)
                == .blocked(.entryIdentityMismatch)
        )
    }

    @Test("The change set must belong to the stored session")
    func sessionMismatchIsBlocked() {
        let entry = makeEntry(
            sessionID: UUID(),
            changeSet: AgentHistoryChangeSetFixtures.changeSet(sessionID: UUID())
        )

        #expect(AgentHistoryUndoPreflight.evaluate(entry) == .blocked(.sessionMismatch))
    }

    @Test("Writer process generation and event cursor must be valid")
    func invalidProvenanceIsBlocked() {
        let sessionID = UUID()
        let changeSet = AgentHistoryChangeSetFixtures.changeSet(
            sessionID: sessionID,
            provenance: AgentHistoryWriterProvenance(
                sessionID: sessionID,
                writerInstanceID: UUID(),
                processIdentifier: 0,
                processGeneration: 0,
                firstEventSequence: 4,
                lastEventSequence: 3
            )
        )
        let entry = makeEntry(sessionID: sessionID, changeSet: changeSet)

        #expect(AgentHistoryUndoPreflight.evaluate(entry) == .blocked(.invalidProvenance))
    }

    @Test("Workspace identity requires an opaque private ID and Git state")
    func invalidWorkspaceIsBlocked() {
        let sessionID = UUID()
        let changeSet = AgentHistoryChangeSetFixtures.changeSet(
            sessionID: sessionID,
            workspace: AgentHistoryWorkspaceIdentity(
                privateWorkspaceID: UUID(
                    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                ),
                headOID: "not-an-object-id",
                indexSHA256: AgentHistoryChangeSetFixtures.digestD
            )
        )
        let entry = makeEntry(sessionID: sessionID, changeSet: changeSet)

        #expect(
            AgentHistoryUndoPreflight.evaluate(entry)
                == .blocked(.invalidWorkspaceIdentity)
        )
    }

    @Test("Project-log data cannot replace the owner-private authority record")
    func invalidPrivateAuthorityIsBlocked() {
        let sessionID = UUID()
        let changeSet = AgentHistoryChangeSetFixtures.changeSet(
            sessionID: sessionID,
            authority: AgentHistoryPrivateAuthorityReference(
                storage: .unsupported("projectLog"),
                recordID: UUID(),
                manifestFormatVersion: 99,
                canonicalContractSHA256: "BAD"
            )
        )
        let entry = makeEntry(sessionID: sessionID, changeSet: changeSet)

        #expect(
            AgentHistoryUndoPreflight.evaluate(entry)
                == .blocked(.invalidPrivateAuthority)
        )
    }

    @Test("Inverse payload must be owner-private, integrity-bound, and non-empty")
    func invalidInversePayloadIsBlocked() {
        let sessionID = UUID()
        let changeSet = AgentHistoryChangeSetFixtures.changeSet(
            sessionID: sessionID,
            inversePayload: AgentHistoryInversePayloadReference(
                storage: .unsupported("projectFile"),
                blobID: UUID(),
                formatVersion: 2,
                byteCount: 0,
                sha256: "BAD"
            )
        )
        let entry = makeEntry(sessionID: sessionID, changeSet: changeSet)

        #expect(
            AgentHistoryUndoPreflight.evaluate(entry)
                == .blocked(.invalidInversePayload)
        )
    }

    @Test("Empty and affected-file-mismatched change sets fail closed")
    func emptyOrMismatchedChangesAreBlocked() {
        let sessionID = UUID()
        let empty = AgentHistoryChangeSetFixtures.changeSet(
            sessionID: sessionID,
            changes: []
        )
        #expect(
            AgentHistoryUndoPreflight.evaluate(
                makeEntry(sessionID: sessionID, affectedFiles: [], changeSet: empty)
            ) == .blocked(.emptyChangeSet)
        )

        let nonempty = AgentHistoryChangeSetFixtures.changeSet(sessionID: sessionID)
        #expect(
            AgentHistoryUndoPreflight.evaluate(
                makeEntry(
                    sessionID: sessionID,
                    affectedFiles: ["different.swift"],
                    changeSet: nonempty
                )
            ) == .blocked(.affectedFilesMismatch)
        )
    }

    @Test("Traversal, absolute, noncanonical, and ambiguous paths fail closed")
    func unsafePathsAreBlocked() {
        let invalidPaths = [
            "../escape.swift",
            "/absolute.swift",
            "Sources/./App.swift",
            "Sources//App.swift",
            "Cafe\u{301}.swift",
            "bad\u{0000}name.swift",
            ".git/config",
            "nested/.GIT/index",
            ".pine/agent-log.json",
            "nested/.PINE/AGENT-LOG.JSON",
        ]

        for path in invalidPaths {
            let change = AgentHistoryChangeSetFixtures.modifyChange(path: path)
            let entry = entryWithChanges([change])
            #expect(
                AgentHistoryUndoPreflight.evaluate(entry)
                    == .blocked(.invalidRelativePath(path))
            )
        }

        let aliases = [
            AgentHistoryChangeSetFixtures.modifyChange(path: "Sources/App.swift"),
            AgentHistoryChangeSetFixtures.modifyChange(path: "sources/app.swift"),
        ]
        let aliasedEntry = entryWithChanges(aliases)
        #expect(
            AgentHistoryUndoPreflight.evaluate(aliasedEntry)
                == .blocked(.duplicatePath("sources/app.swift"))
        )
    }

    @Test("Rename, symlink, and unknown operations have explicit refusal")
    func unsupportedOperationsAreBlocked() {
        let operations: [AgentHistoryFileOperation] = [
            .rename,
            .symlink,
            .unsupported("futureOperation"),
        ]

        for operation in operations {
            let change = AgentHistoryRecordedFileChange(
                relativePath: "Sources/App.swift",
                operation: operation,
                before: AgentHistoryChangeSetFixtures.fileState(),
                after: AgentHistoryChangeSetFixtures.fileState(
                    digest: AgentHistoryChangeSetFixtures.digestB
                )
            )
            let entry = entryWithChanges([change])
            #expect(
                AgentHistoryUndoPreflight.evaluate(entry)
                    == .blocked(.unsupportedOperation(operation.persistedValue))
            )
        }
    }

    @Test("Modify, create, and delete require exact before/after shapes")
    func operationStateShapesAreValidated() {
        let invalidChanges = [
            AgentHistoryRecordedFileChange(
                relativePath: "modify.swift",
                operation: .modify,
                before: AgentHistoryChangeSetFixtures.fileState(),
                after: AgentHistoryChangeSetFixtures.fileState()
            ),
            AgentHistoryRecordedFileChange(
                relativePath: "create.swift",
                operation: .create,
                before: AgentHistoryChangeSetFixtures.fileState(),
                after: AgentHistoryChangeSetFixtures.fileState()
            ),
            AgentHistoryRecordedFileChange(
                relativePath: "delete.swift",
                operation: .delete,
                before: AgentHistoryChangeSetFixtures.fileState(),
                after: AgentHistoryChangeSetFixtures.fileState()
            ),
        ]

        for change in invalidChanges {
            let entry = entryWithChanges([change])
            #expect(
                AgentHistoryUndoPreflight.evaluate(entry)
                    == .blocked(.invalidFileState(change.relativePath))
            )
        }
    }

    @Test("Non-regular file states and noncanonical digests are refused")
    func invalidFileIdentityIsBlocked() {
        let invalidStates = [
            AgentHistoryChangeSetFixtures.fileState(
                kind: .symbolicLink
            ),
            AgentHistoryChangeSetFixtures.fileState(
                digest: String(repeating: "A", count: 64)
            ),
        ]

        for state in invalidStates {
            let change = AgentHistoryRecordedFileChange(
                relativePath: "Sources/App.swift",
                operation: .create,
                before: nil,
                after: state
            )
            let entry = entryWithChanges([change])
            #expect(
                AgentHistoryUndoPreflight.evaluate(entry)
                    == .blocked(.invalidFileState(change.relativePath))
            )
        }
    }

    @Test("Valid create and delete contracts reach private-authority validation")
    func supportedOperationShapesAreReady() {
        let changes = [
            AgentHistoryRecordedFileChange(
                relativePath: "created.swift",
                operation: .create,
                before: nil,
                after: AgentHistoryChangeSetFixtures.fileState()
            ),
            AgentHistoryRecordedFileChange(
                relativePath: "deleted.swift",
                operation: .delete,
                before: AgentHistoryChangeSetFixtures.fileState(),
                after: nil
            ),
        ]

        #expect(
            AgentHistoryUndoPreflight.evaluate(entryWithChanges(changes))
                == .readyForPrivateAuthorityValidation
        )
    }

    private func entryWithChanges(
        _ changes: [AgentHistoryRecordedFileChange]
    ) -> AgentHistoryEntry {
        let sessionID = UUID()
        return makeEntry(
            sessionID: sessionID,
            affectedFiles: changes.map(\.relativePath),
            changeSet: AgentHistoryChangeSetFixtures.changeSet(
                sessionID: sessionID,
                changes: changes
            )
        )
    }

    private func makeEntry(
        entryID: UUID? = nil,
        sessionID: UUID = UUID(),
        affectedFiles: [String] = ["Sources/App.swift"],
        changeSet: VerifiedAgentChangeSet?
    ) -> AgentHistoryEntry {
        AgentHistoryEntry(
            id: entryID ?? changeSet?.historyEntryID ?? UUID(),
            sessionID: sessionID,
            agentTypeRaw: "codex",
            startedAt: Date(timeIntervalSince1970: 900),
            affectedFiles: affectedFiles,
            attribution: .verified,
            verifiedChangeSet: changeSet,
            summary: "\(affectedFiles.count) files"
        )
    }
}
