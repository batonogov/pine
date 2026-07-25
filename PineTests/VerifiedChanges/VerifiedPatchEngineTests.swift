//
//  VerifiedPatchEngineTests.swift
//  PineTests
//
//  Security, preparation, budget, and multi-agent coverage for #933.
//

import Foundation
import Testing

@testable import Pine

@Suite("Verified Patch Ingress")
struct VerifiedPatchIngressTests {
    @Test("Full provenance and durable journal scope are mandatory")
    func provenanceAndJournalBinding() throws {
        let before = file("before\n")
        let after = file("after\n")
        let valid = record(
            envelopeID: id(1),
            cursor: 1,
            journalSequence: 10,
            changes: [change("file.txt", before, after)]
        )

        _ = try receipt([valid])

        let inferred = record(
            envelopeID: id(2),
            cursor: 1,
            journalSequence: 11,
            source: .gitCorrelation,
            changes: [change("file.txt", before, after)]
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try receipt([inferred])
        }

        let forgedJournal = VerifiedPatchUntrustedEventRecord(
            envelope: valid.envelope,
            durableIdentity: durableIdentity(
                envelope: valid.envelope,
                journalSequence: 10,
                eventCursor: 2
            ),
            mediatedWriterReceipt: valid.mediatedWriterReceipt,
            transitions: valid.transitions
        )
        #expect(
            throws: VerifiedPatchValidationError
                .invalidDurableEvent(valid.envelope.id)
        ) {
            try receipt([forgedJournal])
        }
    }

    @Test("Authenticated external-write evidence is audit-only")
    func externalWriteCannotAuthorizePatch() {
        let external = record(
            envelopeID: id(20),
            cursor: 1,
            journalSequence: 1,
            mediatedByPine: false,
            changes: [change(
                "file.txt",
                file("before"),
                file("after")
            )]
        )

        #expect(throws: VerifiedPatchValidationError
            .missingMediatedWriterReceipt(external.envelope.id)) {
            try receipt([external])
        }
    }

    @Test("Several batches retain irrelevant durable cursor records")
    func severalBatchesAndIrrelevantEvents() throws {
        let first = record(
            envelopeID: id(1),
            cursor: 40,
            journalSequence: 100,
            changes: [change(
                "first.txt",
                file("one\n"),
                file("agent-one\n")
            )]
        )
        let irrelevant = record(
            envelopeID: id(2),
            cursor: 41,
            journalSequence: 103,
            changes: []
        )
        let second = record(
            envelopeID: id(3),
            cursor: 42,
            journalSequence: 109,
            changes: [change(
                "second.txt",
                file("two\n"),
                file("agent-two\n")
            )]
        )

        let accepted = try receipt([second, first, irrelevant])

        #expect(accepted.events.map(\.envelope.cursorValue) == [40, 41, 42])
        #expect(accepted.events[1].transitions.isEmpty)
        #expect(
            accepted.durableEventIdentities.map(\.journalSequence)
                == [100, 103, 109]
        )
    }

    @Test("Cursor gaps and journal rollback fail closed")
    func cursorAndJournalOrder() {
        let state = file("state")
        let first = record(
            envelopeID: id(1),
            cursor: 1,
            journalSequence: 10,
            changes: [change("one.txt", nil, state)]
        )
        let gap = record(
            envelopeID: id(2),
            cursor: 3,
            journalSequence: 11,
            changes: []
        )
        #expect(throws: VerifiedPatchValidationError.cursorGap(
            expected: 2,
            actual: 3
        )) {
            try receipt([first, gap])
        }

        let rollback = record(
            envelopeID: id(3),
            cursor: 2,
            journalSequence: 9,
            changes: []
        )
        #expect(throws: VerifiedPatchValidationError.journalOrderMismatch(
            previous: 10,
            actual: 9
        )) {
            try receipt([first, rollback])
        }
    }

    @Test("File-change payload must bind exactly one transition")
    func payloadBinding() {
        let before = file("before")
        let after = file("after")
        let mismatchedPayload = AgentEventPayload.fileChange(
            AgentFileChange(
                relativePath: "other.txt",
                before: before.identity,
                after: after.identity
            )
        )
        let value = record(
            envelopeID: id(1),
            cursor: 1,
            journalSequence: 1,
            payload: mismatchedPayload,
            changes: [change("file.txt", before, after)]
        )

        #expect(
            throws: VerifiedPatchValidationError
                .invalidEnvelope(value.envelope.id)
        ) {
            try receipt([value])
        }
    }

    @Test("Protected, noncanonical, and alias paths are rejected")
    func pathPolicy() throws {
        let state = file("state")
        for path in [".git/config", ".pine/authority", "../escape"] {
            let value = record(
                envelopeID: id(path.count),
                cursor: 1,
                journalSequence: 1,
                changes: [change(path, nil, state)]
            )
            #expect(throws: VerifiedPatchValidationError.self) {
                try receipt([value])
            }
        }

        let decomposed = "Cafe\u{301}.txt"
        let value = record(
            envelopeID: id(30),
            cursor: 1,
            journalSequence: 1,
            changes: [change(decomposed, nil, state)]
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try receipt([value])
        }

        let records = [
            record(
                envelopeID: id(40),
                cursor: 1,
                journalSequence: 1,
                changes: [change("File.swift", nil, state)]
            ),
            record(
                envelopeID: id(41),
                cursor: 2,
                journalSequence: 2,
                changes: [change("file.swift", nil, state)]
            )
        ]
        let accepted = try receipt(records)
        #expect(throws: VerifiedPatchValidationError.self) {
            try makePatch(
                patchID: id(42),
                receipt: accepted,
                sources: [
                    source(
                        records[0],
                        ordinal: 0,
                        before: nil,
                        after: state
                    ),
                    source(
                        records[1],
                        ordinal: 0,
                        before: nil,
                        after: state
                    )
                ]
            )
        }
    }

    @Test("Event and transition aggregate limits accept limit and reject +1")
    func ingressLimits() throws {
        let events = (0..<VerifiedPatchLimits.maximumEventCount).map {
            record(
                envelopeID: id($0 + 1),
                cursor: UInt64($0 + 1),
                journalSequence: UInt64($0 + 1),
                changes: []
            )
        }
        _ = try receipt(events)
        let extra = record(
            envelopeID: id(events.count + 1),
            cursor: UInt64(events.count + 1),
            journalSequence: UInt64(events.count + 1),
            changes: []
        )
        #expect(throws: VerifiedPatchValidationError.tooManyEvents) {
            try receipt(events + [extra])
        }

        let state = file("x")
        let changes = (0..<VerifiedPatchLimits.maximumTransitionCount).map {
            change("files/\($0).txt", nil, state)
        }
        let atLimit = record(
            envelopeID: id(2_000),
            cursor: 1,
            journalSequence: 1,
            changes: changes
        )
        _ = try receipt([atLimit])
        let overLimit = record(
            envelopeID: id(2_001),
            cursor: 1,
            journalSequence: 1,
            changes: changes + [change("extra.txt", nil, state)]
        )
        #expect(throws: VerifiedPatchValidationError.tooManyTransitions) {
            try receipt([overLimit])
        }
    }
}

@Suite("Verified Patch Preparation")
struct VerifiedPatchPreparationTests {
    @Test("Prepared inverse exposes resolved ranges and exact coordinator seam")
    func preparedPreviewAndCoordinatorExpectations() throws {
        let before = file(
            "p0\np1\np2\np3\nold\nbottom0\nbottom1\n",
            mode: 0o600
        )
        let after = file(
            "p0\np1\np2\np3\nagent\nbottom0\nbottom1\n",
            mode: 0o600
        )
        let patch = try singlePatch(before: before, after: after)
        let current = file("human\n" + text(after), mode: 0o600)

        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": current]
        )

        let preview = try #require(prepared.previews.first)
        let hunk = try #require(preview.hunks.first)
        #expect(hunk.capturedAfterStartLine == 4)
        #expect(hunk.resolvedCurrentStartLine == 5)
        #expect(preview.expectedCurrent == current.stateIdentity)
        #expect(
            prepared.coordinatorExpectations.durableEvents
                == patch.receipt.durableEventIdentities
        )
        #expect(
            prepared.coordinatorExpectations.capturedHeadOID
                == String(repeating: "a", count: 40)
        )
        #expect(
            prepared.coordinatorExpectations.capturedIndexSHA256
                == String(repeating: "b", count: 64)
        )

        let result = VerifiedPatchEngine.applyPrepared(
            prepared,
            currentSnapshot: snapshot(["file.txt": current])
        )
        let applied = try #require(appliedSnapshot(result))
        #expect(text(try #require(applied.files["file.txt"]))
            == "human\np0\np1\np2\np3\nold\nbottom0\nbottom1\n")
    }

    @Test("A proven non-overlapping human edit is preserved")
    func preservesNonOverlap() throws {
        let before = file(
            "human-old\nstable-a\nstable-b\nold\nstable-c\nstable-d\n"
        )
        let after = file(
            "human-old\nstable-a\nstable-b\nagent\nstable-c\nstable-d\n"
        )
        let current = file(
            "human-new\nstable-a\nstable-b\nagent\nstable-c\nstable-d\n"
        )
        let patch = try singlePatch(before: before, after: after)

        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": current]
        )
        let result = VerifiedPatchEngine.applyPrepared(
            prepared,
            currentSnapshot: snapshot(["file.txt": current])
        )

        let applied = try #require(appliedSnapshot(result))
        #expect(
            text(try #require(applied.files["file.txt"]))
                == "human-new\nstable-a\nstable-b\nold\nstable-c\nstable-d\n"
        )
    }

    @Test("Overlap and moved-region duplicates both conflict")
    func overlapAndMovedDuplicateConflict() throws {
        let before = file("a\nb\nold\nc\nd\n")
        let after = file("a\nb\nagent\nc\nd\n")
        let patch = try singlePatch(before: before, after: after)

        let overlap = VerifiedPatchEngine.prepareCheckedInverse(
            patch,
            currentSnapshot: snapshot([
                "file.txt": file("a\nb\nhuman\nc\nd\n")
            ])
        )
        #expect(preparationConflicts(overlap)?.first?.reason
            == .humanEditOverlapsAgentRegion(hunkIndex: 0))

        let moved = VerifiedPatchEngine.prepareCheckedInverse(
            patch,
            currentSnapshot: snapshot([
                "file.txt": file(
                    "human-replaced-original\n"
                        + "a\nb\nagent\nc\nd\n"
                )
            ])
        )
        #expect(preparationConflicts(moved)?.first?.reason
            == .humanEditOverlapsAgentRegion(hunkIndex: 0))
    }

    @Test("CRLF and missing final newline survive resolved application")
    func crlfAndNoFinalNewline() throws {
        let before = file(
            "human-old\r\nstable-a\r\nstable-b\r\nold\r\nlast"
        )
        let after = file(
            "human-old\r\nstable-a\r\nstable-b\r\nagent\r\nlast"
        )
        let current = file(
            "human-new\r\nstable-a\r\nstable-b\r\nagent\r\nlast"
        )
        let patch = try singlePatch(before: before, after: after)
        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": current]
        )
        let result = VerifiedPatchEngine.applyPrepared(
            prepared,
            currentSnapshot: snapshot(["file.txt": current])
        )

        let applied = try #require(appliedSnapshot(result))
        let restored = try #require(applied.files["file.txt"])
        #expect(text(restored)
            == "human-new\r\nstable-a\r\nstable-b\r\nold\r\nlast")
    }

    @Test("Fresh snapshot is rechecked after preparation")
    func stalePreparedPlanConflicts() throws {
        let patch = try singlePatch(
            before: file("before"),
            after: file("after")
        )
        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": file("after")]
        )

        let result = VerifiedPatchEngine.applyPrepared(
            prepared,
            currentSnapshot: snapshot(["file.txt": file("human")])
        )

        #expect(conflicts(result)?.first?.reason
            == .snapshotChangedAfterPreparation)
    }

    @Test("Authority seam revalidates writer proof and journal audit")
    func combinedAuthorityEvidenceSeam() async throws {
        let patch = try singlePatch(
            before: file("before"),
            after: file("after")
        )
        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": file("after")]
        )
        let revalidator = AuthorityEvidenceRecorder()

        try await VerifiedPatchEngine.revalidateAuthorityEvidence(
            prepared,
            using: revalidator
        )

        let counts = await revalidator.counts()
        #expect(counts.writer == 1)
        #expect(counts.audit == 1)
    }

    @Test("Same-path chains collapse while retaining every durable reference")
    func transitionChainsCollapse() throws {
        let middle = file("middle")
        let final = file("final")
        let create = record(
            envelopeID: id(1),
            cursor: 1,
            journalSequence: 10,
            changes: [change("file.txt", nil, middle)]
        )
        let modify = record(
            envelopeID: id(2),
            cursor: 2,
            journalSequence: 12,
            changes: [change("file.txt", middle, final)]
        )
        let accepted = try receipt([create, modify])
        let patch = try makePatch(
            patchID: id(3),
            receipt: accepted,
            sources: [
                source(create, ordinal: 0, before: nil, after: middle),
                source(modify, ordinal: 0, before: middle, after: final)
            ]
        )

        #expect(patch.operations.count == 1)
        #expect(patch.operations[0].kind == .create)
        #expect(patch.operations[0].id.transitionIDs == [
            transitionID(create, 0),
            transitionID(modify, 0)
        ])
        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": final]
        )
        let applied = try #require(appliedSnapshot(
            VerifiedPatchEngine.applyPrepared(
                prepared,
                currentSnapshot: snapshot(["file.txt": final])
            )
        ))
        #expect(applied.files["file.txt"] == nil)

        let original = file("original")
        let changed = file("changed")
        let first = record(
            envelopeID: id(4),
            cursor: 1,
            journalSequence: 20,
            changes: [change("gone.txt", original, changed)]
        )
        let deletion = record(
            envelopeID: id(5),
            cursor: 2,
            journalSequence: 21,
            changes: [change("gone.txt", changed, nil)]
        )
        let deletionPatch = try makePatch(
            patchID: id(6),
            receipt: try receipt([first, deletion]),
            sources: [
                source(
                    first,
                    ordinal: 0,
                    before: original,
                    after: changed
                ),
                source(
                    deletion,
                    ordinal: 0,
                    before: changed,
                    after: nil
                )
            ]
        )
        #expect(deletionPatch.operations[0].kind == .delete)
        let restore = try requirePrepared(deletionPatch, files: [:])
        let restored = try #require(appliedSnapshot(
            VerifiedPatchEngine.applyPrepared(
                restore,
                currentSnapshot: snapshot([:])
            )
        ))
        #expect(restored.files["gone.txt"] == original)
    }

    @Test("Mode is restored and symlink or mode divergence conflicts")
    func modeAndFileKind() throws {
        let before = file("before\n", mode: 0o600)
        let after = file("after\n", mode: 0o755)
        let patch = try singlePatch(before: before, after: after)

        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": after]
        )
        let applied = try #require(appliedSnapshot(
            VerifiedPatchEngine.applyPrepared(
                prepared,
                currentSnapshot: snapshot(["file.txt": after])
            )
        ))
        #expect(applied.files["file.txt"]?.posixMode == 0o600)

        let wrongMode = VerifiedPatchEngine.prepareCheckedInverse(
            patch,
            currentSnapshot: snapshot([
                "file.txt": file("after\n", mode: 0o700)
            ])
        )
        #expect(preparationConflicts(wrongMode)?.first?.reason
            == .exactStateDiverged)

        let symlink = VerifiedPatchEngine.prepareCheckedInverse(
            patch,
            currentSnapshot: snapshot([
                "file.txt": file(
                    "after\n",
                    mode: 0o755,
                    kind: .symbolicLink
                )
            ])
        )
        #expect(preparationConflicts(symlink)?.first?.reason
            == .unsupportedCurrentFileKind)
    }

    @Test("Rename is previewable but cannot become a prepared authority plan")
    func renameBlocked() throws {
        let before = file("old")
        let after = file("new")
        let rename = record(
            envelopeID: id(1),
            cursor: 1,
            journalSequence: 1,
            changes: [change(
                "old.txt",
                before,
                after,
                destination: "new.txt"
            )]
        )
        let patch = try makePatch(
            patchID: id(2),
            receipt: try receipt([rename]),
            sources: [source(
                rename,
                ordinal: 0,
                before: before,
                after: after
            )]
        )

        #expect(VerifiedPatchEngine.previewInverse(patch).first?.kind
            == .simulateRenamedFile)
        let preparation = VerifiedPatchEngine.prepareCheckedInverse(
            patch,
            currentSnapshot: snapshot(["new.txt": after])
        )
        guard case .failure(.unsupportedOperation(let operationID, .rename))
                = preparation else {
            Issue.record("Rename must fail before preparing authority")
            return
        }
        #expect(operationID == patch.operations[0].id)
    }

    @Test("Synthesized patch and prepared values are revalidated")
    func synthesizedValuesCannotBypassChecks() throws {
        let patch = try singlePatch(
            before: file("before"),
            after: file("after")
        )
        let accepted = patch.receipt.events[0]
        let forgedEvent = VerifiedPatchAcceptedEvent(
            envelope: accepted.envelope,
            durableIdentity: VerifiedPatchDurableEventIdentity(
                projectID: accepted.durableIdentity.projectID,
                canonicalWorktreePath: accepted.durableIdentity
                    .canonicalWorktreePath,
                sessionID: accepted.durableIdentity.sessionID,
                terminalID: accepted.durableIdentity.terminalID,
                processGeneration: accepted.durableIdentity
                    .processGeneration,
                eventCursor: accepted.durableIdentity.eventCursor,
                envelopeID: id(9_999),
                journalSequence: accepted.durableIdentity.journalSequence
            ),
            mediatedWriterReceipt: accepted.mediatedWriterReceipt,
            transitions: accepted.transitions
        )
        let forgedReceipt = VerifiedPatchIngressReceipt(
            receiptID: patch.receipt.receiptID,
            workspace: patch.receipt.workspace,
            projectID: patch.receipt.projectID,
            sessionID: patch.receipt.sessionID,
            process: patch.receipt.process,
            events: [forgedEvent]
        )
        let forgedPatch = VerifiedPatchSet(
            id: patch.id,
            receipt: forgedReceipt,
            operations: patch.operations
        )

        guard case .failure(.invalidPatch) =
                VerifiedPatchEngine.prepareCheckedInverse(
                    forgedPatch,
                    currentSnapshot: snapshot(["file.txt": file("after")])
                ) else {
            Issue.record("Forged durable receipt must be rejected")
            return
        }

        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": file("after")]
        )
        let forgedExpectations = VerifiedPatchCoordinatorExpectations(
            privateWorkspaceID: prepared.coordinatorExpectations
                .privateWorkspaceID,
            canonicalRootPath: prepared.coordinatorExpectations
                .canonicalRootPath,
            rootDevice: prepared.coordinatorExpectations.rootDevice,
            rootInode: prepared.coordinatorExpectations.rootInode,
            capturedHeadOID: prepared.coordinatorExpectations
                .capturedHeadOID,
            capturedIndexSHA256: prepared.coordinatorExpectations
                .capturedIndexSHA256,
            durableEvents: [],
            mediatedWriterReceipts: prepared.coordinatorExpectations
                .mediatedWriterReceipts
        )
        let forgedPrepared = PreparedInverse(
            patch: prepared.patch,
            coordinatorExpectations: forgedExpectations,
            operations: prepared.operations
        )
        #expect(conflicts(VerifiedPatchEngine.applyPrepared(
            forgedPrepared,
            currentSnapshot: snapshot(["file.txt": file("after")])
        ))?.first?.reason == .invalidCurrentSnapshot)

        let originalOperation = prepared.operations[0]
        let forgedOperation = VerifiedPreparedInverseOperation(
            operationID: originalOperation.operationID,
            kind: originalOperation.kind,
            mode: originalOperation.mode,
            expectations: originalOperation.expectations,
            results: [VerifiedPreparedPathResult(
                path: "other.txt",
                state: file("forged")
            )],
            resolvedTextHunks: originalOperation.resolvedTextHunks,
            preview: originalOperation.preview
        )
        let forgedResult = PreparedInverse(
            patch: prepared.patch,
            coordinatorExpectations: prepared.coordinatorExpectations,
            operations: [forgedOperation]
        )
        #expect(conflicts(VerifiedPatchEngine.applyPrepared(
            forgedResult,
            currentSnapshot: snapshot(["file.txt": file("after")])
        ))?.first?.reason == .invalidCurrentSnapshot)
    }
}

@Suite("Verified Patch Budgets")
struct VerifiedPatchBudgetTests {
    @Test("Per-file byte limit accepts limit and rejects +1")
    func fileByteLimit() throws {
        let maximum = Data(
            repeating: 0,
            count: VerifiedPatchLimits.maximumFileByteCount
        )
        _ = try singlePatch(before: nil, after: file(maximum))

        let oversized = Data(
            repeating: 0,
            count: VerifiedPatchLimits.maximumFileByteCount + 1
        )
        #expect(throws: VerifiedPatchValidationError.contentTooLarge) {
            try singlePatch(before: nil, after: file(oversized))
        }
    }

    @Test("Operation limit accepts limit and rejects +1")
    func operationLimit() throws {
        let state = file("x")
        let records = (0..<VerifiedPatchLimits.maximumOperationCount).map {
            record(
                envelopeID: id($0 + 1),
                cursor: UInt64($0 + 1),
                journalSequence: UInt64($0 + 1),
                changes: [change("files/\($0).txt", nil, state)]
            )
        }
        let accepted = try receipt(records)
        _ = try makePatch(
            patchID: id(5_000),
            receipt: accepted,
            sources: records.map {
                source($0, ordinal: 0, before: nil, after: state)
            }
        )

        let extra = record(
            envelopeID: id(records.count + 1),
            cursor: UInt64(records.count + 1),
            journalSequence: UInt64(records.count + 1),
            changes: [change("extra.txt", nil, state)]
        )
        let over = records + [extra]
        #expect(throws: VerifiedPatchValidationError.tooManyOperations) {
            try makePatch(
                patchID: id(5_001),
                receipt: try receipt(over),
                sources: over.map {
                    source($0, ordinal: 0, before: nil, after: state)
                }
            )
        }
    }

    @Test("Snapshot file-count limit accepts limit and rejects +1")
    func snapshotFileLimit() throws {
        let after = file("after")
        let patch = try singlePatch(before: file("before"), after: after)
        var files = ["file.txt": after]
        for index in 1..<VerifiedPatchLimits.maximumSnapshotFileCount {
            files["snapshot/\(index).txt"] = file(Data())
        }
        _ = try requirePrepared(patch, files: files)

        files["snapshot/overflow.txt"] = file(Data())
        guard case .failure(.invalidPatch(.invalidSnapshot)) =
                VerifiedPatchEngine.prepareCheckedInverse(
                    patch,
                    currentSnapshot: snapshot(files)
                ) else {
            Issue.record("Snapshot file-count +1 must fail closed")
            return
        }
    }

    @Test("LCS cell budget accepts boundary and rejects +1")
    func lcsCellLimit() {
        let atLimit = alternatingLines(count: 1_413)
        #expect(VerifiedTextPatch.estimatedLCSCellCount(
            before: atLimit,
            after: atLimit
        ) == 1_999_396)

        let overLimit = alternatingLines(count: 1_414)
        #expect(VerifiedTextPatch.estimatedLCSCellCount(
            before: overLimit,
            after: overLimit
        ) == nil)
    }

    @Test("Repeated alternating input remains bounded and conservative")
    func adversarialRepeatedInput() throws {
        let before = file(
            alternatingLines(count: 600, replacement: "old\n")
        )
        let after = file(
            alternatingLines(count: 600, replacement: "agent\n")
        )
        let patch = try singlePatch(before: before, after: after)
        let current = file(
            "human\n" + text(after) + text(after)
        )

        let outcome = VerifiedPatchEngine.prepareCheckedInverse(
            patch,
            currentSnapshot: snapshot(["file.txt": current])
        )
        #expect(preparationConflicts(outcome) != nil)
    }
}

@Suite("Verified Patch Version Chains")
struct VerifiedPatchVersionChainTests {
    @Test("Divergent bases conflict and exact chains are ordered")
    func divergenceAndExactChain() throws {
        let base = file("base")
        let middle = file("middle")
        let first = try singlePatch(
            patchID: id(1),
            envelopeID: id(11),
            cursor: 1,
            journalSequence: 10,
            before: base,
            after: middle,
            sessionID: id(101),
            terminalID: id(201)
        )
        let divergent = try singlePatch(
            patchID: id(2),
            envelopeID: id(12),
            cursor: 1,
            journalSequence: 20,
            before: base,
            after: file("other"),
            sessionID: id(102),
            terminalID: id(202)
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([first, divergent])
        )?.contains { $0.reason == .ambiguousVersionChain } == true)

        let second = try singlePatch(
            patchID: id(3),
            envelopeID: id(13),
            cursor: 1,
            journalSequence: 30,
            before: middle,
            after: file("final"),
            sessionID: id(103),
            terminalID: id(203)
        )
        guard case .valid(let report) =
                VerifiedPatchVersionChainDetector.analyze([second, first])
        else {
            Issue.record("Exact cross-agent version chain should be valid")
            return
        }
        #expect(report.orderedPatchIDsByPath.values.first == [id(1), id(3)])
    }

    @Test("Duplicate patch IDs and journal sequence collisions fail closed")
    func duplicateAndJournalCollision() throws {
        let first = try singlePatch(
            patchID: id(1),
            envelopeID: id(11),
            cursor: 1,
            journalSequence: 10,
            path: "one.txt",
            before: file("a"),
            after: file("b")
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([first, first])
        )?.contains { $0.reason == .duplicatePatchID(id(1)) } == true)

        let second = try singlePatch(
            patchID: id(2),
            envelopeID: id(12),
            cursor: 1,
            journalSequence: 10,
            path: "two.txt",
            before: file("c"),
            after: file("d"),
            sessionID: id(102),
            terminalID: id(202)
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([first, second])
        )?.contains { $0.reason == .journalSequenceCollision(10) } == true)
    }

    @Test("Root path aliases cannot split a shared private workspace")
    func rootAliasesShareScope() throws {
        let first = try singlePatch(
            patchID: id(1),
            envelopeID: id(11),
            path: "File.swift",
            before: file("base"),
            after: file("one"),
            rootPath: "/tmp/project"
        )
        let second = try singlePatch(
            patchID: id(2),
            envelopeID: id(12),
            path: "file.swift",
            before: file("base"),
            after: file("two"),
            sessionID: id(102),
            terminalID: id(202),
            rootPath: "/private/tmp/project"
        )

        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([first, second])
        )?.contains { $0.reason == .ambiguousVersionChain } == true)
    }

    @Test("Version patch-count limit accepts limit and rejects +1")
    func patchCountLimit() throws {
        let patches = try (0..<VerifiedPatchLimits.maximumVersionPatchCount)
            .map { index in
                try singlePatch(
                    patchID: id(index + 1),
                    envelopeID: id(index + 1_000),
                    cursor: 1,
                    journalSequence: UInt64(index + 1),
                    path: "file-\(index).txt",
                    before: file("before-\(index)"),
                    after: file("after-\(index)"),
                    sessionID: id(index + 2_000),
                    terminalID: id(index + 3_000)
                )
            }
        guard case .valid =
                VerifiedPatchVersionChainDetector.analyze(patches) else {
            Issue.record("Patch-count limit should remain valid")
            return
        }
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze(
                patches + [try singlePatch(
                    patchID: id(9_000),
                    envelopeID: id(9_001),
                    path: "overflow.txt",
                    before: file("before"),
                    after: file("after"),
                    sessionID: id(9_002),
                    terminalID: id(9_003)
                )]
            )
        )?.first?.reason == .resourceLimitExceeded)
    }
}

private func singlePatch(
    patchID: UUID = id(100),
    envelopeID: UUID = id(101),
    cursor: UInt64 = 1,
    journalSequence: UInt64 = 1,
    path: String = "file.txt",
    before: VerifiedPatchFileState?,
    after: VerifiedPatchFileState?,
    sessionID: UUID = id(200),
    terminalID: UUID = id(300),
    rootPath: String = "/private/tmp/project"
) throws -> VerifiedPatchSet {
    let value = record(
        envelopeID: envelopeID,
        cursor: cursor,
        journalSequence: journalSequence,
        sessionID: sessionID,
        terminalID: terminalID,
        rootPath: rootPath,
        changes: [change(path, before, after)]
    )
    return try makePatch(
        patchID: patchID,
        receipt: try receipt(
            [value],
            workspace: workspace(rootPath: rootPath)
        ),
        sources: [source(
            value,
            ordinal: 0,
            before: before,
            after: after
        )]
    )
}

private func makePatch(
    patchID: UUID,
    receipt: VerifiedPatchIngressReceipt,
    sources: [VerifiedPatchSourceOperation]
) throws -> VerifiedPatchSet {
    try VerifiedPatchEngine.makePatch(
        id: patchID,
        receipt: receipt,
        operations: sources
    )
}

private func receipt(
    _ records: [VerifiedPatchUntrustedEventRecord],
    workspace: VerifiedPatchWorkspaceIdentity = workspace()
) throws -> VerifiedPatchIngressReceipt {
    try VerifiedPatchIngressCoordinator.accept(
        receiptID: id(8_000),
        workspace: workspace,
        records: records
    )
}

private func record(
    envelopeID: UUID,
    cursor: UInt64,
    journalSequence: UInt64,
    sessionID: UUID = id(200),
    terminalID: UUID = id(300),
    projectID: UUID = id(400),
    rootPath: String = "/private/tmp/project",
    source eventSource: EventSource = .explicitAgentEvent,
    payload: AgentEventPayload? = nil,
    mediatedByPine: Bool = true,
    changes: [VerifiedPatchContentTransition]
) -> VerifiedPatchUntrustedEventRecord {
    let selectedPayload: AgentEventPayload
    if let payload {
        selectedPayload = payload
    } else if changes.count == 1,
              changes[0].destinationPath == nil,
              let after = changes[0].after {
        selectedPayload = .fileChange(AgentFileChange(
            relativePath: changes[0].sourcePath,
            before: changes[0].before?.contentIdentity,
            after: after.contentIdentity
        ))
    } else {
        selectedPayload = .none
    }
    let envelope = AgentEventEnvelope(
        id: envelopeID,
        projectID: projectID,
        sessionID: sessionID,
        agentTypeRaw: "generic:test",
        process: AgentProcessIdentity(
            terminalID: terminalID,
            processGeneration: 1
        ),
        location: AgentEventLocation(
            worktreePath: rootPath,
            cwd: rootPath
        ),
        cursorValue: cursor,
        timestamp: Date(timeIntervalSince1970: 1_000 + Double(cursor)),
        source: eventSource,
        trustLevel: .verified,
        payload: selectedPayload
    )
    let auditIdentity = durableIdentity(
        envelope: envelope,
        journalSequence: journalSequence
    )
    let writerReceipt: PineMediatedWriterReceipt?
    if mediatedByPine, !changes.isEmpty {
        writerReceipt = PineMediatedWriterReceipt(
            receiptID: UUID(),
            userApprovalID: UUID(),
            descriptorTransactionID: UUID(),
            descriptorCASSequence: journalSequence,
            workspace: workspace(rootPath: rootPath),
            auditEvent: auditIdentity,
            transitions: changes
        )
    } else {
        writerReceipt = nil
    }
    return VerifiedPatchUntrustedEventRecord(
        envelope: envelope,
        durableIdentity: auditIdentity,
        mediatedWriterReceipt: writerReceipt,
        transitions: changes
    )
}

private func durableIdentity(
    envelope: AgentEventEnvelope,
    journalSequence: UInt64,
    eventCursor: UInt64? = nil
) -> VerifiedPatchDurableEventIdentity {
    VerifiedPatchDurableEventIdentity(
        projectID: envelope.projectID,
        canonicalWorktreePath: envelope.location.worktreePath,
        sessionID: envelope.sessionID,
        terminalID: envelope.process.terminalID,
        processGeneration: envelope.process.processGeneration,
        eventCursor: eventCursor ?? envelope.cursorValue,
        envelopeID: envelope.id,
        journalSequence: journalSequence
    )
}

private func change(
    _ path: String,
    _ before: VerifiedPatchFileState?,
    _ after: VerifiedPatchFileState?,
    destination: String? = nil
) -> VerifiedPatchContentTransition {
    VerifiedPatchContentTransition(
        sourcePath: path,
        destinationPath: destination,
        before: before?.stateIdentity,
        after: after?.stateIdentity
    )
}

private func source(
    _ record: VerifiedPatchUntrustedEventRecord,
    ordinal: Int,
    before: VerifiedPatchFileState?,
    after: VerifiedPatchFileState?
) -> VerifiedPatchSourceOperation {
    let transition = record.transitions[ordinal]
    return VerifiedPatchSourceOperation(
        transitionID: transitionID(record, ordinal),
        sourcePath: transition.sourcePath,
        destinationPath: transition.destinationPath,
        before: before,
        after: after
    )
}

private func transitionID(
    _ record: VerifiedPatchUntrustedEventRecord,
    _ ordinal: Int
) -> VerifiedPatchTransitionID {
    VerifiedPatchTransitionID(
        envelopeID: record.envelope.id,
        ordinal: ordinal
    )
}

private func requirePrepared(
    _ patch: VerifiedPatchSet,
    files: [String: VerifiedPatchFileState]
) throws -> PreparedInverse {
    switch VerifiedPatchEngine.prepareCheckedInverse(
        patch,
        currentSnapshot: snapshot(files)
    ) {
    case .success(let prepared):
        return prepared
    case .failure(let failure):
        throw FixtureError.preparation(failure)
    }
}

private func snapshot(
    _ files: [String: VerifiedPatchFileState]
) -> VerifiedPatchWorkspaceSnapshot {
    VerifiedPatchWorkspaceSnapshot(files: files)
}

private func workspace(
    rootPath: String = "/private/tmp/project",
    privateID: UUID = id(700),
    rootDevice: UInt64 = 11,
    rootInode: UInt64 = 22
) -> VerifiedPatchWorkspaceIdentity {
    VerifiedPatchWorkspaceIdentity(
        privateWorkspaceID: privateID,
        canonicalRootPath: rootPath,
        rootDevice: rootDevice,
        rootInode: rootInode,
        capturedHeadOID: String(repeating: "a", count: 40),
        capturedIndexSHA256: String(repeating: "b", count: 64)
    )
}

private func appliedSnapshot(
    _ result: VerifiedCheckedInverseResult
) -> VerifiedPatchWorkspaceSnapshot? {
    guard case .applied(let snapshot, _) = result else { return nil }
    return snapshot
}

private func conflicts(
    _ result: VerifiedCheckedInverseResult
) -> [VerifiedPatchConflict]? {
    guard case .conflicted(let conflicts) = result else { return nil }
    return conflicts
}

private func preparationConflicts(
    _ result: Result<PreparedInverse, VerifiedPatchPreparationFailure>
) -> [VerifiedPatchConflict]? {
    guard case .failure(.conflicts(let conflicts)) = result else {
        return nil
    }
    return conflicts
}

private func versionConflicts(
    _ result: VerifiedPatchVersionChainResult
) -> [VerifiedPatchVersionConflict]? {
    guard case .conflicted(let conflicts) = result else { return nil }
    return conflicts
}

private func alternatingLines(
    count: Int,
    replacement: String? = nil
) -> Data {
    let value = (0..<count).map { index in
        if index.isMultiple(of: 2) {
            return replacement ?? "a\n"
        }
        return "b\n"
    }.joined()
    return Data(value.utf8)
}

private func text(_ state: VerifiedPatchFileState) -> String {
    guard let value = String(data: state.content, encoding: .utf8) else {
        preconditionFailure("Fixture content must be UTF-8")
    }
    return value
}

private func file(
    _ value: String,
    mode: UInt16 = 0o644,
    kind: VerifiedPatchFileKind = .regularFile
) -> VerifiedPatchFileState {
    file(Data(value.utf8), mode: mode, kind: kind)
}

private func file(
    _ value: Data,
    mode: UInt16 = 0o644,
    kind: VerifiedPatchFileKind = .regularFile
) -> VerifiedPatchFileState {
    VerifiedPatchFileState(
        content: value,
        kind: kind,
        posixMode: mode
    )
}

private func id(_ value: Int) -> UUID {
    UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ))
}

private enum FixtureError: Error {
    case preparation(VerifiedPatchPreparationFailure)
}

private actor AuthorityEvidenceRecorder:
    PatchAuthorityEvidenceRevalidator {
    private var writerReceiptCount = 0
    private var auditEventCount = 0

    func revalidateMediatedWriterReceipts(
        _ receipts: [PineMediatedWriterReceipt]
    ) {
        writerReceiptCount += receipts.count
    }

    func revalidateDurableEvents(
        _ identities: [VerifiedPatchDurableEventIdentity]
    ) {
        auditEventCount += identities.count
    }

    func counts() -> (writer: Int, audit: Int) {
        (writerReceiptCount, auditEventCount)
    }
}
