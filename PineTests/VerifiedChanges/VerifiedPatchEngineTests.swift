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

    @Test("Synthesized empty receipt accessors fail safely")
    func emptyReceiptAccessors() {
        let empty = VerifiedPatchIngressReceipt(
            receiptID: id(1),
            workspace: workspace(),
            projectID: id(2),
            sessionID: id(3),
            process: AgentProcessIdentity(
                terminalID: id(4),
                processGeneration: 1
            ),
            events: []
        )

        #expect(empty.firstCursorValue == 0)
        #expect(empty.lastCursorValue == 0)
        #expect(empty.firstJournalSequence == 0)
        #expect(empty.lastJournalSequence == 0)
        #expect(empty.durableEventExpectations.isEmpty)
        #expect(throws: VerifiedPatchValidationError.invalidReceipt) {
            try VerifiedPatchIngressCoordinator.revalidate(empty)
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
                == patch.receipt.durableEventExpectations
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

    @Test("Deleting the first of two equal after-blocks is ambiguous")
    func duplicateAfterBlockDeletionConflicts() throws {
        let before = file(
            "p0\np1\nold\ns0\ns1\n"
                + "p0\np1\nagent\ns0\ns1\n"
        )
        let after = file(
            "p0\np1\nagent\ns0\ns1\n"
                + "p0\np1\nagent\ns0\ns1\n"
        )
        let patch = try singlePatch(before: before, after: after)
        let outcome = VerifiedPatchEngine.prepareCheckedInverse(
            patch,
            currentSnapshot: snapshot([
                "file.txt": file("p0\np1\nagent\ns0\ns1\n")
            ])
        )

        #expect(preparationConflicts(outcome)?.first?.reason
            == .ambiguousCurrentMapping(hunkIndex: 0))
    }

    @Test("Moved or reordered duplicate after-blocks conflict")
    func duplicateAfterBlockMovementConflicts() throws {
        let block = "p0\np1\nagent\ns0\ns1\n"
        let before = file(
            "p0\np1\nold\ns0\ns1\n"
                + "unique-u\n"
                + block
                + "unique-v\n"
        )
        let after = file(
            block
                + "unique-u\n"
                + block
                + "unique-v\n"
        )
        let patch = try singlePatch(before: before, after: after)
        let currentValues = [
            "unique-u\n" + block + "unique-v\n" + block,
            block + "unique-v\n" + block + "unique-u\n"
        ]

        for current in currentValues {
            let outcome = VerifiedPatchEngine.prepareCheckedInverse(
                patch,
                currentSnapshot: snapshot([
                    "file.txt": file(current)
                ])
            )
            #expect(preparationConflicts(outcome)?.first?.reason
                == .ambiguousCurrentMapping(hunkIndex: 0))
        }
    }

    @Test("Duplicate blocks remain safe with one unique optimal mapping")
    func duplicateAfterBlocksWithUniqueMapping() throws {
        let block = "p0\np1\nagent\ns0\ns1\n"
        let before = file(
            "p0\np1\nold\ns0\ns1\n"
                + "unique\n"
                + block
        )
        let after = file(block + "unique\n" + block)
        let current = file("human\n" + text(after))
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

        #expect(text(try #require(applied.files["file.txt"]))
            == "human\n" + text(before))
    }

    @Test("A human edit inside the guarded region conflicts")
    func overlappingHumanEditConflicts() throws {
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
        let auditExpectations = await revalidator.auditExpectations()
        let journalExpectation = try #require(auditExpectations.first)
        #expect(journalExpectation.envelope == patch.receipt.events[0].envelope)
        #expect(
            journalExpectation.durableIdentity
                == patch.receipt.events[0].durableIdentity
        )
        #expect(journalExpectation.envelope.agentTypeRaw == "generic:test")
        #expect(
            journalExpectation.envelope.location.cwd
                == "/private/tmp/project"
        )
        #expect(journalExpectation.envelope.source == .explicitAgentEvent)
        #expect(journalExpectation.envelope.trustLevel == .verified)
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

        #expect(try VerifiedPatchEngine.previewInverse(patch).first?.kind
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

    @Test("Content-preserving rename is valid but no-op modify is rejected")
    func contentPreservingRenameAndNoOpModify() throws {
        let state = file("same")
        let noOp = record(
            envelopeID: id(10),
            cursor: 1,
            journalSequence: 1,
            changes: [change("same.txt", state, state)]
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try makePatch(
                patchID: id(11),
                receipt: try receipt([noOp]),
                sources: [source(
                    noOp,
                    ordinal: 0,
                    before: state,
                    after: state
                )]
            )
        }

        let rename = record(
            envelopeID: id(12),
            cursor: 1,
            journalSequence: 2,
            changes: [change(
                "old.txt",
                state,
                state,
                destination: "new.txt"
            )]
        )
        let patch = try makePatch(
            patchID: id(13),
            receipt: try receipt([rename]),
            sources: [source(
                rename,
                ordinal: 0,
                before: state,
                after: state
            )]
        )
        let preview = try #require(
            try VerifiedPatchEngine.previewInverse(patch).first
        )
        #expect(patch.operations[0].kind == .rename)
        #expect(preview.kind == .simulateRenamedFile)
        #expect(preview.sourcePath == "old.txt")
        #expect(preview.destinationPath == "new.txt")
        #expect(preview.expectedCurrent == state.stateIdentity)
        #expect(preview.result == state.stateIdentity)
    }

    @Test("Rename cannot smuggle a same-source transition chain")
    func renameChainParity() throws {
        let before = file("before")
        let middle = file("middle")
        let after = file("after")
        let rename = record(
            envelopeID: id(30),
            cursor: 1,
            journalSequence: 30,
            changes: [change(
                "old.txt",
                before,
                middle,
                destination: "new.txt"
            )]
        )
        let followup = record(
            envelopeID: id(31),
            cursor: 2,
            journalSequence: 31,
            changes: [change("old.txt", middle, after)]
        )
        let accepted = try receipt([rename, followup])
        let sources = [
            source(rename, ordinal: 0, before: before, after: middle),
            source(followup, ordinal: 0, before: middle, after: after)
        ]
        #expect(throws: VerifiedPatchValidationError.self) {
            try makePatch(
                patchID: id(32),
                receipt: accepted,
                sources: sources
            )
        }

        let forged = VerifiedPatchSet(
            id: id(33),
            receipt: accepted,
            operations: [VerifiedPatchOperation(
                id: VerifiedPatchOperationID(
                    patchID: id(33),
                    transitionIDs: [
                        transitionID(rename, 0),
                        transitionID(followup, 0)
                    ]
                ),
                kind: .rename,
                sourcePath: "old.txt",
                destinationPath: "new.txt",
                before: before,
                after: after,
                strategy: .exactState
            )]
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.revalidate(forged)
        }
    }

    @Test("Nominal preview revalidates canonical strategy and arithmetic")
    func previewRejectsForgedStrategyAndRanges() throws {
        let patch = try singlePatch(
            before: file("a\nold\n"),
            after: file("a\nagent\n")
        )
        let original = patch.operations[0]
        guard case .text(let hunks, let cells) = original.strategy,
              let firstHunk = hunks.first else {
            Issue.record("Fixture must produce a canonical text patch")
            return
        }

        let downgraded = VerifiedPatchSet(
            id: patch.id,
            receipt: patch.receipt,
            operations: [VerifiedPatchOperation(
                id: original.id,
                kind: original.kind,
                sourcePath: original.sourcePath,
                destinationPath: original.destinationPath,
                before: original.before,
                after: original.after,
                strategy: .exactState
            )]
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.previewInverse(downgraded)
        }

        let malformed = VerifiedTextPatchHunk(
            beforeStartLine: firstHunk.beforeStartLine,
            beforeLineCount: firstHunk.beforeLineCount,
            afterStartLine: Int.max,
            afterLineCount: firstHunk.afterLineCount,
            prefixContext: firstHunk.prefixContext,
            afterLines: firstHunk.afterLines,
            beforeLines: firstHunk.beforeLines,
            suffixContext: firstHunk.suffixContext
        )
        let forgedRange = VerifiedPatchSet(
            id: patch.id,
            receipt: patch.receipt,
            operations: [VerifiedPatchOperation(
                id: original.id,
                kind: original.kind,
                sourcePath: original.sourcePath,
                destinationPath: original.destinationPath,
                before: original.before,
                after: original.after,
                strategy: .text(hunks: [malformed], lcsCellCount: cells)
            )]
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.previewInverse(forgedRange)
        }
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
        let review = try VerifiedPatchEngine.preparedPreviewForReview(prepared)
        #expect(review.patchID == prepared.patchID)
        #expect(review.operations.count == prepared.operations.count)
        #expect(
            review.operations.map(\.preparedMode)
                == prepared.operations.map(\.mode)
        )
        #expect(
            review.operations.map(\.expectations)
                == prepared.operations.map { operation in
                    operation.expectations.map {
                        VerifiedPreparedReviewPathState(
                            path: $0.path,
                            identity: $0.state?.stateIdentity
                        )
                    }
                }
        )
        #expect(
            review.operations.map(\.results)
                == prepared.operations.map { operation in
                    operation.results.map {
                        VerifiedPreparedReviewPathState(
                            path: $0.path,
                            identity: $0.state?.stateIdentity
                        )
                    }
                }
        )
        let model = try VerifiedDiffPreviewModel(prepared: prepared)
        #expect(model.patchID == prepared.patchID)
        #expect(model.rows.count == prepared.operations.count)
        let row = try #require(model.rows.first)
        #expect(row.preparedMode == .exactState)
        #expect(row.previewKind == .applyTextHunks)
        #expect(!row.hunks.isEmpty)
        #expect(row.presentationKind == .restoreExactFile)
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
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.preparedPreviewForReview(
                forgedPrepared
            )
        }
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedDiffPreviewModel(prepared: forgedPrepared)
        }
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
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.preparedPreviewForReview(forgedResult)
        }
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedDiffPreviewModel(prepared: forgedResult)
        }
        #expect(conflicts(VerifiedPatchEngine.applyPrepared(
            forgedResult,
            currentSnapshot: snapshot(["file.txt": file("after")])
        ))?.first?.reason == .invalidCurrentSnapshot)
    }
}

@Suite("Verified Patch Selection")
struct VerifiedPatchSelectionTests {
    @Test("One verified hunk reverts without touching accepted hunks")
    func selectedHunk() throws {
        let before = file("""
        human-old
        stable-0
        stable-1
        old-one
        stable-a
        stable-b
        stable-c
        stable-d
        stable-e
        old-two
        stable-2
        stable-3
        """)
        let after = file("""
        human-old
        stable-0
        stable-1
        agent-one
        stable-a
        stable-b
        stable-c
        stable-d
        stable-e
        agent-two
        stable-2
        stable-3
        """)
        let current = file("""
        human-new
        stable-0
        stable-1
        agent-one
        stable-a
        stable-b
        stable-c
        stable-d
        stable-e
        agent-two
        stable-2
        stable-3
        """)
        let patch = try singlePatch(before: before, after: after)
        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": current]
        )
        let operation = try #require(prepared.operations.first)
        #expect(operation.mode == .checkedText)
        #expect(operation.resolvedTextHunks.count == 2)

        let selected = try #require(try? selection(
            [.hunks(operationID: operation.operationID, indices: [0])],
            from: prepared
        ))
        let outcome = VerifiedPatchEngine.applySelection(
            selected,
            currentSnapshot: snapshot(["file.txt": current])
        )
        guard case .applied(let result, let previews) = outcome else {
            Issue.record("Expected selected hunk to apply")
            return
        }
        #expect(text(try #require(result.files["file.txt"])) == """
        human-new
        stable-0
        stable-1
        old-one
        stable-a
        stable-b
        stable-c
        stable-d
        stable-e
        agent-two
        stable-2
        stable-3
        """)
        #expect(previews.count == 1)
        #expect(previews[0].hunks.count == 1)
    }

    @Test("Concurrent edits to unselected paths are preserved")
    func unselectedConcurrentPath() throws {
        let after = file("agent\n")
        let patch = try singlePatch(before: file("before\n"), after: after)
        let prepared = try requirePrepared(
            patch,
            files: [
                "file.txt": after,
                "unrelated.txt": file("first\n")
            ]
        )
        let operation = try #require(prepared.operations.first)
        let selected = try #require(try? selection(
            [.operation(operation.operationID)],
            from: prepared
        ))

        let outcome = VerifiedPatchEngine.applySelection(
            selected,
            currentSnapshot: snapshot([
                "file.txt": after,
                "unrelated.txt": file("changed later\n")
            ])
        )
        guard case .applied(let result, _) = outcome else {
            Issue.record("Expected selection to preserve unrelated path")
            return
        }
        #expect(text(try #require(result.files["file.txt"])) == "before\n")
        #expect(text(try #require(result.files["unrelated.txt"])) == "changed later\n")
    }

    @Test("A stale selected path fails atomically")
    func staleSelectedPath() throws {
        let after = file("agent\n")
        let patch = try singlePatch(before: file("before\n"), after: after)
        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": after]
        )
        let operation = try #require(prepared.operations.first)
        let selected = try #require(try? selection(
            [.operation(operation.operationID)],
            from: prepared
        ))

        let outcome = VerifiedPatchEngine.applySelection(
            selected,
            currentSnapshot: snapshot([
                "file.txt": file("changed after review\n")
            ])
        )
        guard case .conflicted(let conflicts) = outcome else {
            Issue.record("Expected stale selection conflict")
            return
        }
        #expect(conflicts.count == 1)
        #expect(conflicts[0].reason == .snapshotChangedAfterPreparation)
    }

    @Test("Exact, empty, duplicate, and unknown selections fail closed")
    func invalidSelections() throws {
        let after = file(Data([0x00, 0x01]))
        let patch = try singlePatch(before: file(Data([0x02])), after: after)
        let prepared = try requirePrepared(
            patch,
            files: ["file.txt": after]
        )
        let operation = try #require(prepared.operations.first)

        #expect(selectionResult([], from: prepared) == .emptySelection)
        #expect(selectionResult([
            .operation(operation.operationID),
            .operation(operation.operationID)
        ], from: prepared) == .duplicateOperation(operation.operationID))
        #expect(selectionResult([
            .hunks(operationID: operation.operationID, indices: [0])
        ], from: prepared) == .hunkSelectionRequiresCheckedText(
            operation.operationID
        ))

        let unknownID = VerifiedPatchOperationID(
            patchID: id(250),
            transitionIDs: operation.operationID.transitionIDs
        )
        #expect(selectionResult([
            .operation(unknownID)
        ], from: prepared) == .unknownOperation(unknownID))
    }

    private func selection(
        _ choices: [VerifiedPatchReviewSelection],
        from prepared: PreparedInverse
    ) throws -> VerifiedPreparedSelection {
        switch VerifiedPatchEngine.prepareSelection(choices, from: prepared) {
        case .success(let value): value
        case .failure(let failure): throw failure
        }
    }

    private func selectionResult(
        _ choices: [VerifiedPatchReviewSelection],
        from prepared: PreparedInverse
    ) -> VerifiedPatchSelectionFailure? {
        switch VerifiedPatchEngine.prepareSelection(choices, from: prepared) {
        case .success: nil
        case .failure(let failure): failure
        }
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

    @Test("Operation overflow is rejected before any text planning")
    func operationOverflowPrecedesPlanning() throws {
        let before = file(alternatingLines(
            count: 1_413,
            replacement: "old\n"
        ))
        let after = file(alternatingLines(
            count: 1_413,
            replacement: "new\n"
        ))
        let records = (0...VerifiedPatchLimits.maximumOperationCount)
            .map { index in
                record(
                    envelopeID: id(index + 10_000),
                    cursor: UInt64(index + 1),
                    journalSequence: UInt64(index + 1),
                    changes: [change(
                        "adversarial/\(index).txt",
                        before,
                        after
                    )]
                )
            }
        let accepted = try receipt(records)
        var planningCount = 0

        #expect(throws: VerifiedPatchValidationError.tooManyOperations) {
            try makePatch(
                patchID: id(10_500),
                receipt: accepted,
                sources: records.map {
                    source(
                        $0,
                        ordinal: 0,
                        before: before,
                        after: after
                    )
                },
                planningObserver: {
                    planningCount += 1
                }
            )
        }
        #expect(planningCount == 0)
    }

    @Test("Canonical case ordering controls aggregate planning exhaustion")
    func canonicalOrderControlsPlanningBudget() throws {
        let before = file(singleEditLines(
            count: 1_413,
            replacementIndex: nil,
            replacement: ""
        ))
        let paths = [
            "Zeta.txt",
            "alpha.txt",
            "Beta.txt",
            "delta.txt",
            "charlie.txt"
        ]
        let records = paths.enumerated().map { index, path in
            let after = file(singleEditLines(
                count: 1_413,
                replacementIndex: 700,
                replacement: "agent-\(index)"
            ))
            return record(
                envelopeID: id(index + 11_000),
                cursor: UInt64(index + 1),
                journalSequence: UInt64(index + 1),
                changes: [change(path, before, after)]
            )
        }
        let sources = records.enumerated().map { index, value in
            source(
                value,
                ordinal: 0,
                before: before,
                after: file(singleEditLines(
                    count: 1_413,
                    replacementIndex: 700,
                    replacement: "agent-\(index)"
                ))
            )
        }
        let patch = try makePatch(
            patchID: id(11_500),
            receipt: try receipt(records),
            sources: Array(sources.reversed())
        )

        #expect(patch.operations.map(\.sourcePath) == [
            "alpha.txt",
            "Beta.txt",
            "charlie.txt",
            "delta.txt",
            "Zeta.txt"
        ])
        for operation in patch.operations.dropLast() {
            guard case .text = operation.strategy else {
                Issue.record("First four canonical operations must use text")
                return
            }
        }
        #expect(patch.operations.last?.strategy == .exactState)

        let forged = VerifiedPatchSet(
            id: patch.id,
            receipt: patch.receipt,
            operations: Array(patch.operations.reversed())
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.revalidate(forged)
        }
    }

    @Test("Failed hunk plans still consume the attempted cell budget")
    func attemptedPlanningBudget() throws {
        var planningCount = 0
        let patch = try hunkExhaustionPatch(
            patchID: id(11_600),
            envelopeSeed: 11_610,
            candidateCount: 20,
            planningObserver: {
                planningCount += 1
            }
        )
        let textHunkCount = patch.operations.reduce(into: 0) {
            if case .text(let hunks, _) = $1.strategy {
                $0 += hunks.count
            }
        }
        let exactCount = patch.operations.filter {
            $0.strategy == .exactState
        }.count

        #expect(textHunkCount == 1_023)
        #expect(exactCount == 20)
        #expect(planningCount == 5)
    }

    @Test("Revalidation preflights sorted oversized paths and hunks")
    func revalidationShapePreflight() throws {
        let state = file("x")
        let records = ["a.txt", "b.txt"].enumerated().map { index, path in
            record(
                envelopeID: id(11_700 + index),
                cursor: UInt64(index + 1),
                journalSequence: UInt64(index + 1),
                changes: [change(path, nil, state)]
            )
        }
        let patch = try makePatch(
            patchID: id(11_710),
            receipt: try receipt(records),
            sources: records.map {
                source($0, ordinal: 0, before: nil, after: state)
            }
        )
        let first = patch.operations[0]
        let second = patch.operations[1]
        let oversizedPath = String(
            repeating: "z",
            count: VerifiedPatchLimits.maximumPathByteCount + 1
        )
        let pathOperation = VerifiedPatchOperation(
            id: second.id,
            kind: second.kind,
            sourcePath: oversizedPath,
            destinationPath: second.destinationPath,
            before: second.before,
            after: second.after,
            strategy: second.strategy
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.revalidate(VerifiedPatchSet(
                id: patch.id,
                receipt: patch.receipt,
                operations: [first, pathOperation]
            ))
        }

        let emptyHunk = VerifiedTextPatchHunk(
            beforeStartLine: 0,
            beforeLineCount: 0,
            afterStartLine: 0,
            afterLineCount: 0,
            prefixContext: [],
            afterLines: [],
            beforeLines: [],
            suffixContext: []
        )
        let hunkOperation = VerifiedPatchOperation(
            id: second.id,
            kind: second.kind,
            sourcePath: second.sourcePath,
            destinationPath: second.destinationPath,
            before: second.before,
            after: second.after,
            strategy: .text(
                hunks: Array(
                    repeating: emptyHunk,
                    count: VerifiedPatchLimits.maximumHunkCount + 1
                ),
                lcsCellCount: 1
            )
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.revalidate(VerifiedPatchSet(
                id: patch.id,
                receipt: patch.receipt,
                operations: [first, hunkOperation]
            ))
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

    @Test("Long common-prefix lines use the exact estimated cell budget")
    func longLineComparisonBudget() throws {
        let before = longPrefixLines(
            count: 400,
            replacementIndex: nil,
            replacement: ""
        )
        let after = longPrefixLines(
            count: 400,
            replacementIndex: 200,
            replacement: "changed"
        )
        let estimate = try #require(
            VerifiedTextPatch.estimatedLCSCellCount(
                before: before,
                after: after
            )
        )
        let plan = try #require(VerifiedTextPatch.plan(
            before: before,
            after: after
        ))

        #expect(estimate == 160_801)
        #expect(plan.lcsCellCount == estimate)
        #expect(plan.hunks.count == 1)
    }

    @Test("Digest collisions are split by exact line equality")
    func lineDigestCollisionSafety() throws {
        let before = Data("alpha\nbravo\nomega\n".utf8)
        let after = Data("alpha\ndelta\nomega\n".utf8)
        let collision = try #require(ContentIdentity(
            sha256Hex: String(repeating: "0", count: 64),
            byteCount: 0
        ))
        let plan = try #require(VerifiedTextPatch.plan(
            before: before,
            after: after,
            lcsCellBudget: VerifiedPatchLimits
                .maximumLCSCellCountPerDiff,
            hunkBudget: VerifiedPatchLimits.maximumHunkCount,
            lineIdentityProvider: { _ in collision }
        ))
        let hunk = try #require(plan.hunks.first)

        #expect(hunk.beforeLines == [Data("bravo\n".utf8)])
        #expect(hunk.afterLines == [Data("delta\n".utf8)])
    }

    @Test("Positional mapping work accepts boundary and rejects +1")
    func positionalMappingBudget() throws {
        let before = Data(
            "human-old\nstable-a\nstable-b\nold\nstable-c\nstable-d\n"
                .utf8
        )
        let after = Data(
            "human-old\nstable-a\nstable-b\nagent\nstable-c\nstable-d\n"
                .utf8
        )
        let current = Data(
            "human-new\nstable-a\nstable-b\nagent\nstable-c\nstable-d\n"
                .utf8
        )
        let plan = try #require(VerifiedTextPatch.plan(
            before: before,
            after: after
        ))
        let tableCells = try #require(
            VerifiedTextPatch.estimatedLCSCellCount(
                before: after,
                after: current
            )
        )
        let mappingCells = tableCells * plan.hunks.count

        guard case .success = VerifiedTextPatch.prepareInverse(
            hunks: plan.hunks,
            capturedAfter: after,
            current: current,
            mappingCellBudget: mappingCells
        ) else {
            Issue.record("Exact mapping budget must be accepted")
            return
        }
        guard case .failure(.resourceLimitExceeded) =
                VerifiedTextPatch.prepareInverse(
            hunks: plan.hunks,
            capturedAfter: after,
            current: current,
            mappingCellBudget: mappingCells - 1
        ) else {
            Issue.record("Mapping budget +1 must fail closed")
            return
        }
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

    @Test("Prepared DTO preflight enforces shape, arithmetic, and aggregates")
    func preparedDTOPreflight() throws {
        let patch = try singlePatch(before: file("before"), after: nil)
        let prepared = try requirePrepared(patch, files: [:])
        let maximumState = file(Data(
            repeating: 0x61,
            count: VerifiedPatchLimits.maximumFileByteCount
        ))

        let boundaryOperations = (0..<8).map {
            shapedDeleteOperation(
                patchID: patch.id,
                ordinal: $0,
                path: "restored-\($0).txt",
                result: maximumState
            )
        }
        let boundary = PreparedInverse(
            patch: patch,
            coordinatorExpectations: prepared.coordinatorExpectations,
            operations: boundaryOperations
        )
        try VerifiedPatchEngine.preflightPreparedShape(boundary)

        let aggregateOverflow = PreparedInverse(
            patch: patch,
            coordinatorExpectations: prepared.coordinatorExpectations,
            operations: boundaryOperations + [shapedDeleteOperation(
                patchID: patch.id,
                ordinal: 8,
                path: "overflow.txt",
                result: file("x")
            )]
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.preflightPreparedShape(aggregateOverflow)
        }

        let original = try #require(prepared.operations.first)
        let duplicateExpectation = VerifiedPreparedInverseOperation(
            operationID: original.operationID,
            kind: original.kind,
            mode: original.mode,
            expectations: original.expectations + original.expectations,
            results: original.results,
            resolvedTextHunks: original.resolvedTextHunks,
            preview: original.preview
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.preflightPreparedShape(PreparedInverse(
                patch: patch,
                coordinatorExpectations: prepared.coordinatorExpectations,
                operations: [duplicateExpectation]
            ))
        }

        let textPatch = try singlePatch(
            patchID: id(20),
            envelopeID: id(21),
            before: file("old\n"),
            after: file("agent\n")
        )
        let textPrepared = try requirePrepared(
            textPatch,
            files: ["file.txt": file("agent\n")]
        )
        let textOperation = try #require(textPrepared.operations.first)
        let textHunk = try #require(textOperation.resolvedTextHunks.first)
        let previewHunk = try #require(textOperation.preview.hunks.first)
        let overflowHunk = VerifiedPreparedTextHunk(
            capturedAfterRange: Int.max..<Int.max,
            resolvedCurrentRange: Int.max..<Int.max,
            replacementLines: textHunk.replacementLines
        )
        let overflowPreviewHunk = VerifiedInverseHunkPreview(
            capturedAfterStartLine: Int.max,
            resolvedCurrentStartLine: Int.max,
            header: previewHunk.header,
            lines: previewHunk.lines
        )
        let arithmeticOverflow = VerifiedPreparedInverseOperation(
            operationID: textOperation.operationID,
            kind: textOperation.kind,
            mode: textOperation.mode,
            expectations: textOperation.expectations,
            results: textOperation.results,
            resolvedTextHunks: [overflowHunk],
            preview: VerifiedInverseOperationPreview(
                operationID: textOperation.preview.operationID,
                kind: textOperation.preview.kind,
                sourcePath: textOperation.preview.sourcePath,
                destinationPath: textOperation.preview.destinationPath,
                expectedCurrent: textOperation.preview.expectedCurrent,
                result: textOperation.preview.result,
                hunks: [overflowPreviewHunk]
            )
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.preflightPreparedShape(PreparedInverse(
                patch: textPatch,
                coordinatorExpectations: textPrepared
                    .coordinatorExpectations,
                operations: [arithmeticOverflow]
            ))
        }

        func operationWithPreviewLines(
            _ lines: [VerifiedInversePreviewLine]
        ) -> VerifiedPreparedInverseOperation {
            let forgedPreviewHunk = VerifiedInverseHunkPreview(
                capturedAfterStartLine: previewHunk
                    .capturedAfterStartLine,
                resolvedCurrentStartLine: previewHunk
                    .resolvedCurrentStartLine,
                header: previewHunk.header,
                lines: lines
            )
            return VerifiedPreparedInverseOperation(
                operationID: textOperation.operationID,
                kind: textOperation.kind,
                mode: textOperation.mode,
                expectations: textOperation.expectations,
                results: textOperation.results,
                resolvedTextHunks: textOperation.resolvedTextHunks,
                preview: VerifiedInverseOperationPreview(
                    operationID: textOperation.preview.operationID,
                    kind: textOperation.preview.kind,
                    sourcePath: textOperation.preview.sourcePath,
                    destinationPath: textOperation.preview.destinationPath,
                    expectedCurrent: textOperation.preview.expectedCurrent,
                    result: textOperation.preview.result,
                    hunks: [forgedPreviewHunk]
                )
            )
        }

        let excessiveLineCount = Array(
            repeating: VerifiedInversePreviewLine(
                kind: .context,
                bytes: Data()
            ),
            count: VerifiedPatchLimits.maximumPreviewLineCountPerHunk + 1
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.preflightPreparedShape(PreparedInverse(
                patch: textPatch,
                coordinatorExpectations: textPrepared
                    .coordinatorExpectations,
                operations: [
                    operationWithPreviewLines(excessiveLineCount)
                ]
            ))
        }

        let excessiveLineBytes = VerifiedInversePreviewLine(
            kind: .context,
            bytes: Data(
                repeating: 0x61,
                count: VerifiedPatchLimits.maximumFileByteCount + 1
            )
        )
        #expect(throws: VerifiedPatchValidationError.self) {
            try VerifiedPatchEngine.preflightPreparedShape(PreparedInverse(
                patch: textPatch,
                coordinatorExpectations: textPrepared
                    .coordinatorExpectations,
                operations: [
                    operationWithPreviewLines([excessiveLineBytes])
                ]
            ))
        }
    }

    @Test("Projected and final snapshots enforce all aggregate limits")
    func projectedAndFinalSnapshotLimits() throws {
        let restored = file("x")
        let patch = try singlePatch(before: restored, after: nil)

        let byteBoundaryFiles = byteSizedSnapshotFiles(
            totalBytes: VerifiedPatchLimits.maximumSnapshotByteCount - 1
        )
        _ = try requirePrepared(patch, files: byteBoundaryFiles)

        let byteOverflowFiles = byteSizedSnapshotFiles(
            totalBytes: VerifiedPatchLimits.maximumSnapshotByteCount
        )
        #expect(
            preparationConflicts(
                VerifiedPatchEngine.prepareCheckedInverse(
                    patch,
                    currentSnapshot: snapshot(byteOverflowFiles)
                )
            )?.first?.reason == .resourceLimitExceeded
        )

        var fileBoundary: [String: VerifiedPatchFileState] = [:]
        for index in 0..<(VerifiedPatchLimits.maximumSnapshotFileCount - 1) {
            fileBoundary["empty/\(index)"] = file(Data())
        }
        _ = try requirePrepared(patch, files: fileBoundary)
        fileBoundary["empty/overflow"] = file(Data())
        #expect(
            preparationConflicts(
                VerifiedPatchEngine.prepareCheckedInverse(
                    patch,
                    currentSnapshot: snapshot(fileBoundary)
                )
            )?.first?.reason == .resourceLimitExceeded
        )

        let pathBoundary = pathSizedSnapshotFiles(
            totalPathBytes: VerifiedPatchLimits
                .maximumSnapshotPathByteCount - "file.txt".utf8.count
        )
        _ = try requirePrepared(patch, files: pathBoundary)
        var pathOverflow = pathBoundary
        pathOverflow["z"] = file(Data())
        #expect(
            preparationConflicts(
                VerifiedPatchEngine.prepareCheckedInverse(
                    patch,
                    currentSnapshot: snapshot(pathOverflow)
                )
            )?.first?.reason == .resourceLimitExceeded
        )

        let prepared = try requirePrepared(patch, files: [:])
        let finalOverflow = VerifiedPatchEngine.applyPrepared(
            prepared,
            currentSnapshot: snapshot(byteOverflowFiles)
        )
        #expect(conflicts(finalOverflow)?.first?.reason
            == .resourceLimitExceeded)
    }

    @Test("Merged text respects per-file boundary and rejects +1")
    func projectedMergedFileLimit() throws {
        let stableSuffix = "\ns1\ns2\ns3\n"
        let beforePayloadCount = 2 * 1_024 * 1_024
            - stableSuffix.utf8.count
        let beforeText = String(repeating: "b", count: beforePayloadCount)
            + stableSuffix
        let afterText = "agent" + stableSuffix
        let patch = try singlePatch(
            before: file(beforeText),
            after: file(afterText)
        )
        let boundaryHumanBytes = VerifiedPatchLimits.maximumFileByteCount
            - beforeText.utf8.count
        let boundaryCurrent = file(
            afterText + String(repeating: "h", count: boundaryHumanBytes)
        )
        _ = try requirePrepared(
            patch,
            files: ["file.txt": boundaryCurrent]
        )

        let overflowCurrent = file(
            afterText
                + String(repeating: "h", count: boundaryHumanBytes + 1)
        )
        #expect(
            preparationConflicts(
                VerifiedPatchEngine.prepareCheckedInverse(
                    patch,
                    currentSnapshot: snapshot([
                        "file.txt": overflowCurrent
                    ])
                )
            )?.first?.reason == .resourceLimitExceeded
        )
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

    @Test("Writer authority replay is workspace-scoped across disjoint paths")
    func mediatedWriterReplayAcrossPaths() throws {
        let writerID = id(501)
        let transactionID = id(502)
        let casSequence: UInt64 = 900
        let firstRecord = record(
            envelopeID: id(510),
            cursor: 1,
            journalSequence: 10,
            sessionID: id(511),
            terminalID: id(512),
            writerReceiptID: writerID,
            descriptorTransactionID: transactionID,
            descriptorCASSequence: casSequence,
            changes: [change("one.txt", file("a"), file("b"))]
        )
        let secondRecord = record(
            envelopeID: id(520),
            cursor: 1,
            journalSequence: 20,
            sessionID: id(521),
            terminalID: id(522),
            writerReceiptID: writerID,
            descriptorTransactionID: transactionID,
            descriptorCASSequence: casSequence,
            changes: [change("two.txt", file("c"), file("d"))]
        )
        let first = try makePatch(
            patchID: id(530),
            receipt: try receipt([firstRecord]),
            sources: [source(
                firstRecord,
                ordinal: 0,
                before: file("a"),
                after: file("b")
            )]
        )
        let second = try makePatch(
            patchID: id(531),
            receipt: try receipt([secondRecord]),
            sources: [source(
                secondRecord,
                ordinal: 0,
                before: file("c"),
                after: file("d")
            )]
        )

        let reasons = versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([first, second])
        )?.map(\.reason) ?? []
        #expect(reasons.contains(.writerReceiptReplay(writerID)))
        #expect(reasons.contains(.descriptorTransactionReplay(transactionID)))
        #expect(
            reasons.contains(.descriptorCASSequenceCollision(casSequence))
        )

        let otherWorkspace = workspace(
            privateID: id(540),
            rootDevice: 33,
            rootInode: 44
        )
        let otherRecord = record(
            envelopeID: id(541),
            cursor: 1,
            journalSequence: 30,
            sessionID: id(542),
            terminalID: id(543),
            writerReceiptID: writerID,
            descriptorTransactionID: transactionID,
            descriptorCASSequence: casSequence,
            writerWorkspace: otherWorkspace,
            changes: [change("three.txt", file("e"), file("f"))]
        )
        let other = try makePatch(
            patchID: id(544),
            receipt: try receipt([otherRecord], workspace: otherWorkspace),
            sources: [source(
                otherRecord,
                ordinal: 0,
                before: file("e"),
                after: file("f")
            )]
        )
        guard case .valid =
                VerifiedPatchVersionChainDetector.analyze([first, other])
        else {
            Issue.record("Distinct private workspaces may reuse local IDs")
            return
        }
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

    @Test("Interleaved streams cannot hide reverse cursor order")
    func interleavedStreamCursorOrder() throws {
        let stateA = file("a")
        let stateB = file("b")
        let stateC = file("c")
        let stateD = file("d")
        let lateInContent = try singlePatch(
            patchID: id(1),
            envelopeID: id(11),
            cursor: 1,
            journalSequence: 1,
            before: stateC,
            after: stateD,
            sessionID: id(100),
            terminalID: id(200)
        )
        let middle = try singlePatch(
            patchID: id(2),
            envelopeID: id(12),
            cursor: 1,
            journalSequence: 2,
            before: stateB,
            after: stateC,
            sessionID: id(101),
            terminalID: id(201)
        )
        let earlyInContent = try singlePatch(
            patchID: id(3),
            envelopeID: id(13),
            cursor: 2,
            journalSequence: 3,
            before: stateA,
            after: stateB,
            sessionID: id(100),
            terminalID: id(200)
        )

        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                lateInContent,
                middle,
                earlyInContent
            ])
        )?.contains { $0.reason == .cursorOrderMismatch } == true)
    }

    @Test("Content chains preserve workspace journal and CAS order")
    func workspaceEvidenceOrder() throws {
        let stateA = file("a")
        let stateB = file("b")
        let stateC = file("c")
        let journalLate = try singlePatch(
            patchID: id(1),
            envelopeID: id(11),
            journalSequence: 2,
            before: stateA,
            after: stateB,
            sessionID: id(101),
            terminalID: id(201)
        )
        let journalEarly = try singlePatch(
            patchID: id(2),
            envelopeID: id(12),
            journalSequence: 1,
            before: stateB,
            after: stateC,
            sessionID: id(102),
            terminalID: id(202)
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                journalLate,
                journalEarly
            ])
        )?.contains {
            $0.reason == .journalOrderMismatch(previous: 2, actual: 1)
        } == true)

        let casLate = try singlePatch(
            patchID: id(3),
            envelopeID: id(13),
            journalSequence: 3,
            before: stateA,
            after: stateB,
            sessionID: id(103),
            terminalID: id(203),
            descriptorCASSequence: 4
        )
        let casEarly = try singlePatch(
            patchID: id(4),
            envelopeID: id(14),
            journalSequence: 4,
            before: stateB,
            after: stateC,
            sessionID: id(104),
            terminalID: id(204),
            descriptorCASSequence: 3
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                casLate,
                casEarly
            ])
        )?.contains {
            $0.reason == .descriptorCASOrderMismatch(
                previous: 4,
                actual: 3
            )
        } == true)
    }

    @Test("One stream enforces CAS order across disjoint paths")
    func streamCASOrderAcrossPaths() throws {
        let first = try singlePatch(
            patchID: id(15_001),
            envelopeID: id(15_011),
            cursor: 1,
            journalSequence: 10,
            path: "one.txt",
            before: file("one-before"),
            after: file("one-after"),
            descriptorCASSequence: 4
        )
        let second = try singlePatch(
            patchID: id(15_002),
            envelopeID: id(15_012),
            cursor: 2,
            journalSequence: 20,
            path: "two.txt",
            before: file("two-before"),
            after: file("two-after"),
            descriptorCASSequence: 3
        )

        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([second, first])
        )?.contains {
            $0.pathScope == nil
                && $0.reason == .descriptorCASOrderMismatch(
                    previous: 4,
                    actual: 3
                )
        } == true)
    }

    @Test("Version budget rejects prospective plans before revalidation")
    func versionProspectivePlanningBudget() throws {
        let base = try hunkExhaustionPatch(
            patchID: id(15_100),
            envelopeSeed: 15_110,
            candidateCount: 1
        )
        let patches = (0..<3).map { index in
            let patchID = id(15_120 + index)
            return VerifiedPatchSet(
                id: patchID,
                receipt: base.receipt,
                operations: base.operations.map { operation in
                    VerifiedPatchOperation(
                        id: VerifiedPatchOperationID(
                            patchID: patchID,
                            transitionIDs: operation.id.transitionIDs
                        ),
                        kind: operation.kind,
                        sourcePath: operation.sourcePath,
                        destinationPath: operation.destinationPath,
                        before: operation.before,
                        after: operation.after,
                        strategy: operation.strategy
                    )
                }
            )
        }
        var planningCount = 0

        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze(
                patches,
                planningObserver: {
                    planningCount += 1
                }
            )
        )?.first?.reason == .resourceLimitExceeded)
        #expect(planningCount == 0)
    }

    @Test("Private workspace and physical root identities are bijective")
    func workspaceIdentityBijection() throws {
        let before = file("base")
        let samePhysicalFirst = try singlePatch(
            patchID: id(1),
            envelopeID: id(11),
            before: before,
            after: file("one"),
            privateID: id(700)
        )
        let samePhysicalSecond = try singlePatch(
            patchID: id(2),
            envelopeID: id(12),
            journalSequence: 2,
            before: before,
            after: file("two"),
            sessionID: id(201),
            terminalID: id(301),
            privateID: id(701)
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                samePhysicalFirst,
                samePhysicalSecond
            ])
        )?.first?.reason == .workspaceIdentityMismatch)

        let samePrivateFirst = try singlePatch(
            patchID: id(3),
            envelopeID: id(13),
            before: before,
            after: file("three"),
            privateID: id(702),
            rootDevice: 30,
            rootInode: 40
        )
        let samePrivateSecond = try singlePatch(
            patchID: id(4),
            envelopeID: id(14),
            journalSequence: 2,
            before: before,
            after: file("four"),
            sessionID: id(202),
            terminalID: id(302),
            privateID: id(702),
            rootDevice: 31,
            rootInode: 41
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                samePrivateFirst,
                samePrivateSecond
            ])
        )?.first?.reason == .workspaceIdentityMismatch)
    }

    @Test("Version operation and node budget accepts boundary and rejects +1")
    func versionOperationAndNodeBudget() throws {
        let base = try singlePatch(
            before: file("before"),
            after: file("after")
        )
        let operation = try #require(base.operations.first)
        let atLimit = VerifiedPatchSet(
            id: base.id,
            receipt: base.receipt,
            operations: Array(
                repeating: operation,
                count: VerifiedPatchLimits.maximumVersionOperationCount
            )
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([atLimit])
        )?.first?.reason == .invalidPatch(base.id))

        let overLimit = VerifiedPatchSet(
            id: base.id,
            receipt: base.receipt,
            operations: atLimit.operations + [operation]
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([overLimit])
        )?.first?.reason == .resourceLimitExceeded)
    }

    @Test("Version declared LCS budget accepts boundary and rejects +1")
    func versionDeclaredLCSBudget() throws {
        let base = try singlePatch(
            before: file("before\n"),
            after: file("after\n")
        )
        let operation = try #require(base.operations.first)
        guard case .text(let hunks, _) = operation.strategy else {
            Issue.record("Fixture must use a text strategy")
            return
        }
        func replacingCells(_ cells: Int) -> VerifiedPatchSet {
            VerifiedPatchSet(
                id: base.id,
                receipt: base.receipt,
                operations: [VerifiedPatchOperation(
                    id: operation.id,
                    kind: operation.kind,
                    sourcePath: operation.sourcePath,
                    destinationPath: operation.destinationPath,
                    before: operation.before,
                    after: operation.after,
                    strategy: .text(
                        hunks: hunks,
                        lcsCellCount: cells
                    )
                )]
            )
        }

        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                replacingCells(
                    VerifiedPatchLimits.maximumVersionLCSCellCount
                )
            ])
        )?.first?.reason == .invalidPatch(base.id))
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                replacingCells(
                    VerifiedPatchLimits.maximumVersionLCSCellCount + 1
                )
            ])
        )?.first?.reason == .resourceLimitExceeded)
    }

    @Test("Version captured-content budget accepts boundary and rejects +1")
    func versionCapturedContentBudget() throws {
        let base = try singlePatch(
            before: file("before"),
            after: file("after")
        )
        let operation = try #require(base.operations.first)
        let large = file(Data(
            repeating: 0x61,
            count: VerifiedPatchLimits.maximumFileByteCount
        ))
        let largeOperation = VerifiedPatchOperation(
            id: operation.id,
            kind: .modify,
            sourcePath: operation.sourcePath,
            destinationPath: nil,
            before: large,
            after: large,
            strategy: .exactState
        )
        let statesPerOperation = 2
        let operationCount = VerifiedPatchLimits
            .maximumVersionCapturedByteCount
            / VerifiedPatchLimits.maximumFileByteCount
            / statesPerOperation
        let atLimit = VerifiedPatchSet(
            id: base.id,
            receipt: base.receipt,
            operations: Array(
                repeating: largeOperation,
                count: operationCount
            )
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([atLimit])
        )?.first?.reason == .invalidPatch(base.id))

        let oneMoreByte = VerifiedPatchOperation(
            id: operation.id,
            kind: .delete,
            sourcePath: operation.sourcePath,
            destinationPath: nil,
            before: file("x"),
            after: nil,
            strategy: .exactState
        )
        let overLimit = VerifiedPatchSet(
            id: base.id,
            receipt: base.receipt,
            operations: atLimit.operations + [oneMoreByte]
        )
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([overLimit])
        )?.first?.reason == .resourceLimitExceeded)
    }

    @Test("Version path budget accepts boundary and rejects +1")
    func versionPathBudget() throws {
        let base = try singlePatch(
            before: file("before"),
            after: file("after")
        )
        let operation = try #require(base.operations.first)
        let rootByteCount = base.receipt.workspace
            .canonicalRootPath.utf8.count
        let transitionPathByteCount = operation.sourcePath.utf8.count
        let retainedPathByteCount = 4 * rootByteCount
            + 2 * transitionPathByteCount
        let boundaryPath = String(
            repeating: "x",
            count: VerifiedPatchLimits.maximumVersionPathByteCount
                - retainedPathByteCount
        )
        func replacingPath(_ path: String) -> VerifiedPatchSet {
            VerifiedPatchSet(
                id: base.id,
                receipt: base.receipt,
                operations: [VerifiedPatchOperation(
                    id: operation.id,
                    kind: operation.kind,
                    sourcePath: path,
                    destinationPath: operation.destinationPath,
                    before: operation.before,
                    after: operation.after,
                    strategy: operation.strategy
                )]
            )
        }

        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                replacingPath(boundaryPath)
            ])
        )?.first?.reason == .invalidPatch(base.id))
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                replacingPath(boundaryPath + "x")
            ])
        )?.first?.reason == .resourceLimitExceeded)
    }

    @Test("Version event-metadata budget accepts boundary and rejects +1")
    func versionEventMetadataBudget() throws {
        let base = try singlePatch(
            before: file("before"),
            after: file("after")
        )
        let accepted = try #require(base.receipt.events.first)
        let envelope = accepted.envelope
        let fixedMetadataBytes = envelope.agentTypeRaw.utf8.count
            + envelope.location.worktreePath.utf8.count
            + envelope.location.cwd.utf8.count
        let command = String(
            repeating: "x",
            count: VerifiedPatchLimits
                .maximumVersionEventMetadataByteCount
                - fixedMetadataBytes
        )
        func replacingCommand(_ value: String) -> VerifiedPatchSet {
            let forgedEnvelope = AgentEventEnvelope(
                id: envelope.id,
                projectID: envelope.projectID,
                sessionID: envelope.sessionID,
                agentTypeRaw: envelope.agentTypeRaw,
                process: envelope.process,
                location: envelope.location,
                cursorValue: envelope.cursorValue,
                timestamp: envelope.timestamp,
                source: envelope.source,
                trustLevel: envelope.trustLevel,
                payload: .commandResult(AgentCommandResult(
                    command: value,
                    exitStatus: 0
                ))
            )
            let forgedEvent = VerifiedPatchAcceptedEvent(
                envelope: forgedEnvelope,
                durableIdentity: accepted.durableIdentity,
                mediatedWriterReceipt: accepted.mediatedWriterReceipt,
                transitions: accepted.transitions
            )
            let forgedReceipt = VerifiedPatchIngressReceipt(
                receiptID: base.receipt.receiptID,
                workspace: base.receipt.workspace,
                projectID: base.receipt.projectID,
                sessionID: base.receipt.sessionID,
                process: base.receipt.process,
                events: [forgedEvent]
            )
            return VerifiedPatchSet(
                id: base.id,
                receipt: forgedReceipt,
                operations: base.operations
            )
        }

        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                replacingCommand(command)
            ])
        )?.first?.reason == .invalidPatch(base.id))
        #expect(versionConflicts(
            VerifiedPatchVersionChainDetector.analyze([
                replacingCommand(command + "x")
            ])
        )?.first?.reason == .resourceLimitExceeded)
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
    rootPath: String = "/private/tmp/project",
    privateID: UUID = id(700),
    rootDevice: UInt64 = 11,
    rootInode: UInt64 = 22,
    descriptorCASSequence: UInt64? = nil
) throws -> VerifiedPatchSet {
    let workspaceIdentity = workspace(
        rootPath: rootPath,
        privateID: privateID,
        rootDevice: rootDevice,
        rootInode: rootInode
    )
    let value = record(
        envelopeID: envelopeID,
        cursor: cursor,
        journalSequence: journalSequence,
        sessionID: sessionID,
        terminalID: terminalID,
        workspaceIdentity: workspaceIdentity,
        descriptorCASSequence: descriptorCASSequence,
        changes: [change(path, before, after)]
    )
    return try makePatch(
        patchID: patchID,
        receipt: try receipt(
            [value],
            workspace: workspaceIdentity
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
    sources: [VerifiedPatchSourceOperation],
    planningObserver: (() -> Void)? = nil
) throws -> VerifiedPatchSet {
    try VerifiedPatchEngine.makePatch(
        id: patchID,
        receipt: receipt,
        operations: sources,
        planningObserver: planningObserver
    )
}

private func hunkExhaustionPatch(
    patchID: UUID,
    envelopeSeed: Int,
    candidateCount: Int,
    planningObserver: (() -> Void)? = nil
) throws -> VerifiedPatchSet {
    var states: [(
        path: String,
        before: VerifiedPatchFileState,
        after: VerifiedPatchFileState
    )] = []
    for (index, hunkCount) in [512, 511].enumerated() {
        let contents = separatedInsertionContents(
            hunkCount: hunkCount
        )
        states.append((
            path: "budget/0\(index)-hunks.txt",
            before: file(contents.before),
            after: file(contents.after)
        ))
    }
    let candidateBefore = file(editedStableLines(
        count: 1_413,
        replacements: [:]
    ))
    let candidateAfter = file(editedStableLines(
        count: 1_413,
        replacements: [
            400: "agent-first",
            1_000: "agent-second"
        ]
    ))
    for index in 0..<candidateCount {
        states.append((
            path: "budget/1-candidate-\(index).txt",
            before: candidateBefore,
            after: candidateAfter
        ))
    }
    let records = states.enumerated().map { index, value in
        record(
            envelopeID: id(envelopeSeed + index),
            cursor: UInt64(index + 1),
            journalSequence: UInt64(index + 1),
            changes: [change(
                value.path,
                value.before,
                value.after
            )]
        )
    }
    return try makePatch(
        patchID: patchID,
        receipt: try receipt(records),
        sources: records.enumerated().map { index, value in
            source(
                value,
                ordinal: 0,
                before: states[index].before,
                after: states[index].after
            )
        },
        planningObserver: planningObserver
    )
}

private func separatedInsertionContents(
    hunkCount: Int
) -> (before: Data, after: Data) {
    precondition(hunkCount > 0)
    var before = ""
    var after = ""
    for index in 0..<hunkCount {
        after += "agent-\(index)\n"
        if index < hunkCount - 1 {
            let stable = "stable-\(index)\n"
            before += stable
            after += stable
        }
    }
    return (Data(before.utf8), Data(after.utf8))
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
    workspaceIdentity: VerifiedPatchWorkspaceIdentity? = nil,
    source eventSource: EventSource = .explicitAgentEvent,
    payload: AgentEventPayload? = nil,
    mediatedByPine: Bool = true,
    writerReceiptID: UUID? = nil,
    descriptorTransactionID: UUID? = nil,
    descriptorCASSequence: UInt64? = nil,
    writerWorkspace: VerifiedPatchWorkspaceIdentity? = nil,
    changes: [VerifiedPatchContentTransition]
) -> VerifiedPatchUntrustedEventRecord {
    let selectedWorkspace = workspaceIdentity
        ?? workspace(rootPath: rootPath)
    let selectedRootPath = selectedWorkspace.canonicalRootPath
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
            worktreePath: selectedRootPath,
            cwd: selectedRootPath
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
            receiptID: writerReceiptID ?? UUID(),
            userApprovalID: UUID(),
            descriptorTransactionID: descriptorTransactionID ?? UUID(),
            descriptorCASSequence: descriptorCASSequence
                ?? journalSequence,
            workspace: writerWorkspace ?? selectedWorkspace,
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

private func shapedDeleteOperation(
    patchID: UUID,
    ordinal: Int,
    path: String,
    result state: VerifiedPatchFileState
) -> VerifiedPreparedInverseOperation {
    let operationID = VerifiedPatchOperationID(
        patchID: patchID,
        transitionIDs: [VerifiedPatchTransitionID(
            envelopeID: id(20_000 + ordinal),
            ordinal: 0
        )]
    )
    return VerifiedPreparedInverseOperation(
        operationID: operationID,
        kind: .delete,
        mode: .exactState,
        expectations: [VerifiedPreparedPathExpectation(
            path: path,
            state: nil
        )],
        results: [VerifiedPreparedPathResult(path: path, state: state)],
        resolvedTextHunks: [],
        preview: VerifiedInverseOperationPreview(
            operationID: operationID,
            kind: .restoreDeletedFile,
            sourcePath: path,
            destinationPath: nil,
            expectedCurrent: nil,
            result: state.stateIdentity,
            hunks: []
        )
    )
}

private func byteSizedSnapshotFiles(
    totalBytes: Int
) -> [String: VerifiedPatchFileState] {
    var files: [String: VerifiedPatchFileState] = [:]
    var remaining = totalBytes
    var index = 0
    let maximumState = file(Data(
        repeating: 0x62,
        count: VerifiedPatchLimits.maximumFileByteCount
    ))
    while remaining > 0 {
        let count = min(
            remaining,
            VerifiedPatchLimits.maximumFileByteCount
        )
        files["bytes-\(index).bin"] = count
            == VerifiedPatchLimits.maximumFileByteCount
            ? maximumState
            : file(Data(repeating: 0x62, count: count))
        remaining -= count
        index += 1
    }
    return files
}

private func pathSizedSnapshotFiles(
    totalPathBytes: Int
) -> [String: VerifiedPatchFileState] {
    var files: [String: VerifiedPatchFileState] = [:]
    var remaining = totalPathBytes
    var index = 0
    while remaining > 0 {
        let length = min(
            remaining,
            VerifiedPatchLimits.maximumPathByteCount
        )
        let suffix = "-\(index)"
        precondition(length >= suffix.utf8.count)
        let path = String(
            repeating: "p",
            count: length - suffix.utf8.count
        ) + suffix
        files[path] = file(Data())
        remaining -= length
        index += 1
    }
    return files
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

private func singleEditLines(
    count: Int,
    replacementIndex: Int?,
    replacement: String
) -> Data {
    let value = (0..<count).map { index in
        if index == replacementIndex {
            return "\(replacement)\n"
        }
        return "stable-\(index)\n"
    }.joined()
    return Data(value.utf8)
}

private func editedStableLines(
    count: Int,
    replacements: [Int: String]
) -> Data {
    let value = (0..<count).map { index in
        "\(replacements[index] ?? "stable-\(index)")\n"
    }.joined()
    return Data(value.utf8)
}

private func longPrefixLines(
    count: Int,
    replacementIndex: Int?,
    replacement: String
) -> Data {
    let prefix = String(repeating: "p", count: 3 * 1_024)
    let value = (0..<count).map { index in
        let suffix = index == replacementIndex
            ? replacement
            : "stable-\(index)"
        return "\(prefix)\(suffix)\n"
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
    private var expectations: [VerifiedPatchDurableEventExpectation] = []

    func revalidateMediatedWriterReceipts(
        _ receipts: [PineMediatedWriterReceipt]
    ) {
        writerReceiptCount += receipts.count
    }

    func revalidateDurableEvents(
        _ expectations: [VerifiedPatchDurableEventExpectation]
    ) {
        auditEventCount += expectations.count
        self.expectations.append(contentsOf: expectations)
    }

    func counts() -> (writer: Int, audit: Int) {
        (writerReceiptCount, auditEventCount)
    }

    func auditExpectations() -> [VerifiedPatchDurableEventExpectation] {
        expectations
    }
}
