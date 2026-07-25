//
//  VerifiedPatchModels.swift
//  Pine
//
//  Bounded, pure simulation contracts for verified-change review (#933).
//

import Foundation

/// Aggregate limits applied at every construction and preparation boundary.
///
/// These are correctness limits, not tuning hints. Inputs above a limit fail
/// closed before allocating a quadratic table or retaining attacker-sized
/// content. The final descriptor transaction remains owned by #1207.
nonisolated enum VerifiedPatchLimits {
    static let maximumEventCount = 512
    static let maximumTransitionCount = 1_024
    static let maximumOperationCount = 256
    static let maximumVersionPatchCount = 128
    static let maximumVersionOperationCount = 1_024
    static let maximumVersionNodeCount = 1_024
    static let maximumVersionEventCount = 4_096
    static let maximumVersionTransitionCount = 4_096
    static let maximumVersionCapturedByteCount = 64 * 1_024 * 1_024
    static let maximumVersionPathByteCount = 4 * 1_024 * 1_024
    static let maximumVersionEventMetadataByteCount = 4 * 1_024 * 1_024
    static let maximumVersionLCSCellCount = 8_000_000
    static let maximumVersionHunkCount = 4_096
    static let maximumFileByteCount = 4 * 1_024 * 1_024
    static let maximumCapturedByteCount = 16 * 1_024 * 1_024
    static let maximumSnapshotFileCount = 4_096
    static let maximumSnapshotByteCount = 32 * 1_024 * 1_024
    static let maximumSnapshotPathByteCount = 4 * 1_024 * 1_024
    static let maximumEventMetadataByteCount = 64 * 1_024
    static let maximumAggregateEventMetadataByteCount = 1 * 1_024 * 1_024
    static let maximumLineCount = 4_096
    static let maximumLCSCellCountPerDiff = 2_000_000
    static let maximumAggregateLCSCellCount = 8_000_000
    static let maximumAggregateMappingCellCount = 8_000_000
    static let maximumHunkCount = 1_024
    static let maximumPathByteCount = 4_096
}

/// Canonical owner-private workspace identity supplied by an ingress receipt.
///
/// This value is still data, not authority. A final #1207 coordinator must
/// load it from the owner-private store and recheck root device/inode, HEAD,
/// and index state through its descriptor transaction.
nonisolated struct VerifiedPatchWorkspaceIdentity:
    Sendable,
    Equatable,
    Hashable {
    let privateWorkspaceID: UUID
    let canonicalRootPath: String
    let rootDevice: UInt64
    let rootInode: UInt64
    let capturedHeadOID: String
    let capturedIndexSHA256: String
}

nonisolated enum VerifiedPatchFileKind: String, Sendable, Equatable, Hashable {
    case regularFile
    case symbolicLink
}

/// File bytes plus regular-file metadata used by the pure simulator.
///
/// The initializer always recomputes the content identity, so an identity
/// cannot be paired with different bytes inside this model.
nonisolated struct VerifiedPatchFileState: Sendable, Equatable {
    let identity: ContentIdentity
    let kind: VerifiedPatchFileKind
    let posixMode: UInt16
    let content: Data

    init(
        content: Data,
        kind: VerifiedPatchFileKind = .regularFile,
        posixMode: UInt16 = 0o644
    ) {
        self.identity = ContentIdentity(content: content)
        self.kind = kind
        self.posixMode = posixMode
        self.content = content
    }

    var stateIdentity: VerifiedPatchStateIdentity {
        VerifiedPatchStateIdentity(
            contentIdentity: identity,
            kind: kind,
            posixMode: posixMode
        )
    }
}

/// Content plus metadata identity retained in accepted transition receipts.
nonisolated struct VerifiedPatchStateIdentity:
    Sendable,
    Equatable,
    Hashable {
    let contentIdentity: ContentIdentity
    let kind: VerifiedPatchFileKind
    let posixMode: UInt16
}

/// One transition asserted by owner-private capture evidence.
nonisolated struct VerifiedPatchContentTransition:
    Sendable,
    Equatable,
    Hashable {
    let sourcePath: String
    let destinationPath: String?
    let before: VerifiedPatchStateIdentity?
    let after: VerifiedPatchStateIdentity?

    init(
        sourcePath: String,
        destinationPath: String? = nil,
        before: VerifiedPatchStateIdentity?,
        after: VerifiedPatchStateIdentity?
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.before = before
        self.after = after
    }
}

/// Collision-free address of one transition in one full event envelope.
nonisolated struct VerifiedPatchTransitionID:
    Sendable,
    Equatable,
    Hashable {
    let envelopeID: UUID
    let ordinal: Int
}

/// Durable journal evidence adapted from `AgentEventJournalReceipt`.
///
/// The surrounding scope is repeated deliberately. Ingress must prove that
/// the compact journal receipt belongs to this exact envelope and stream; the
/// final authority coordinator must query the owner-private journal again
/// using every field before it may consume #1207 authority.
nonisolated struct VerifiedPatchDurableEventIdentity:
    Sendable,
    Equatable,
    Hashable {
    let projectID: UUID
    let canonicalWorktreePath: String
    let sessionID: UUID
    let terminalID: UUID
    let processGeneration: UInt64
    let eventCursor: UInt64
    let envelopeID: UUID
    let journalSequence: UInt64
}

/// Owner-private journal seam used by the future authority coordinator.
///
/// A conformer must query durable records and compare the complete envelope,
/// not merely confirm that a sequence number exists.
nonisolated protocol VerifiedPatchJournalRevalidating: Sendable {
    func revalidateDurableEvents(
        _ identities: [VerifiedPatchDurableEventIdentity]
    ) async throws
}

/// Owner-private proof that Pine itself applied this exact transition batch.
///
/// This is intentionally separate from authenticated agent-event evidence.
/// The nested durable event is audit context only: file authorship/preimages
/// come from a Pine-owned descriptor CAS performed after explicit user
/// approval. Constructed values are still untrusted until the final
/// coordinator revalidates them against its private writer-receipt store.
nonisolated struct PineMediatedWriterReceipt: Sendable, Equatable, Hashable {
    let receiptID: UUID
    let userApprovalID: UUID
    let descriptorTransactionID: UUID
    let descriptorCASSequence: UInt64
    let workspace: VerifiedPatchWorkspaceIdentity
    let auditEvent: VerifiedPatchDurableEventIdentity
    let transitions: [VerifiedPatchContentTransition]
}

/// Store seam that establishes mutation authorship for a prepared inverse.
///
/// Journal revalidation alone is never an implementation of this protocol.
/// A production conformer must load owner-private receipts created only after
/// Pine completed the descriptor CAS and bound the user approval.
nonisolated protocol PineMediatedWriterReceiptRevalidating: Sendable {
    func revalidateMediatedWriterReceipts(
        _ receipts: [PineMediatedWriterReceipt]
    ) async throws
}

/// Combined read-only authority-evidence seam.
///
/// Code preparing a #1207 mutation must use this combined contract, so a
/// journal-only implementation cannot accidentally satisfy the boundary.
nonisolated protocol PatchAuthorityEvidenceRevalidator:
    VerifiedPatchJournalRevalidating,
    PineMediatedWriterReceiptRevalidating {}

/// Untrusted DTO presented to the ingress coordinator.
///
/// It deliberately carries the complete envelope, including source and
/// effective trust, plus durable journal evidence. All public simulation
/// boundaries revalidate this DTO even though its value types are constructible
/// inside the module.
nonisolated struct VerifiedPatchUntrustedEventRecord: Sendable, Equatable {
    let envelope: AgentEventEnvelope
    let durableIdentity: VerifiedPatchDurableEventIdentity
    let mediatedWriterReceipt: PineMediatedWriterReceipt?
    let transitions: [VerifiedPatchContentTransition]
}

/// One accepted envelope retained by a revalidated ingress receipt.
nonisolated struct VerifiedPatchAcceptedEvent: Sendable, Equatable {
    let envelope: AgentEventEnvelope
    let durableIdentity: VerifiedPatchDurableEventIdentity
    let mediatedWriterReceipt: PineMediatedWriterReceipt?
    let transitions: [VerifiedPatchContentTransition]
}

/// Coordinator-issued evidence that full envelopes passed pure ingress checks.
///
/// This receipt proves only that the in-memory DTO was internally consistent
/// with durable audit and Pine-mediated writer receipt fields. It does not
/// authorize undo. The live coordinator must revalidate the writer receipts
/// in its private store, query the journal for nested audit identities, source
/// content from #1207's owner-private store, and perform final root/Git/index
/// checks.
nonisolated struct VerifiedPatchIngressReceipt: Sendable, Equatable {
    let receiptID: UUID
    let workspace: VerifiedPatchWorkspaceIdentity
    let projectID: UUID
    let sessionID: UUID
    let process: AgentProcessIdentity
    let events: [VerifiedPatchAcceptedEvent]

    var envelopeIDs: [UUID] { events.map(\.envelope.id) }
    var durableEventIdentities: [VerifiedPatchDurableEventIdentity] {
        events.map(\.durableIdentity)
    }
    var mediatedWriterReceipts: [PineMediatedWriterReceipt] {
        events.compactMap(\.mediatedWriterReceipt)
    }
    var firstCursorValue: UInt64 { events[0].envelope.cursorValue }
    var lastCursorValue: UInt64 {
        events[events.count - 1].envelope.cursorValue
    }
    var firstJournalSequence: UInt64 {
        events[0].durableIdentity.journalSequence
    }
    var lastJournalSequence: UInt64 {
        events[events.count - 1].durableIdentity.journalSequence
    }

    init(
        receiptID: UUID,
        workspace: VerifiedPatchWorkspaceIdentity,
        projectID: UUID,
        sessionID: UUID,
        process: AgentProcessIdentity,
        events: [VerifiedPatchAcceptedEvent]
    ) {
        self.receiptID = receiptID
        self.workspace = workspace
        self.projectID = projectID
        self.sessionID = sessionID
        self.process = process
        self.events = events
    }
}

/// Exact captured bytes supplied for one accepted transition.
nonisolated struct VerifiedPatchSourceOperation: Sendable, Equatable {
    let transitionID: VerifiedPatchTransitionID
    let sourcePath: String
    let destinationPath: String?
    let before: VerifiedPatchFileState?
    let after: VerifiedPatchFileState?

    init(
        transitionID: VerifiedPatchTransitionID,
        sourcePath: String,
        destinationPath: String? = nil,
        before: VerifiedPatchFileState?,
        after: VerifiedPatchFileState?
    ) {
        self.transitionID = transitionID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.before = before
        self.after = after
    }
}

nonisolated enum VerifiedPatchOperationKind: String, Sendable, Equatable {
    case modify
    case create
    case delete
    case rename
}

/// Structured operation identity; no delimiter-based path concatenation.
nonisolated struct VerifiedPatchOperationID:
    Sendable,
    Equatable,
    Hashable {
    let patchID: UUID
    let transitionIDs: [VerifiedPatchTransitionID]
}

/// Deterministic line hunk from captured before bytes to captured after bytes.
///
/// Lines include their newline bytes, preserving CRLF and missing final
/// newlines exactly.
nonisolated struct VerifiedTextPatchHunk: Sendable, Equatable {
    let beforeStartLine: Int
    let beforeLineCount: Int
    let afterStartLine: Int
    let afterLineCount: Int
    let prefixContext: [Data]
    let afterLines: [Data]
    let beforeLines: [Data]
    let suffixContext: [Data]
}

nonisolated enum VerifiedPatchApplicationStrategy: Sendable, Equatable {
    case text(hunks: [VerifiedTextPatchHunk], lcsCellCount: Int)
    case exactState
}

/// One collapsed transition chain in a pure patch simulation.
nonisolated struct VerifiedPatchOperation: Sendable, Equatable {
    let id: VerifiedPatchOperationID
    let kind: VerifiedPatchOperationKind
    let sourcePath: String
    let destinationPath: String?
    let before: VerifiedPatchFileState?
    let after: VerifiedPatchFileState?
    let strategy: VerifiedPatchApplicationStrategy

    var touchedPaths: [String] {
        if let destinationPath {
            return [sourcePath, destinationPath]
        }
        return [sourcePath]
    }
}

/// Pure simulation model tied to an accepted ingress receipt.
///
/// This type grants no mutation authority. Only #1207's final coordinator may
/// interpret a prepared result after revalidating private authority, root,
/// file descriptors, HEAD, index state, and authority consumption.
nonisolated struct VerifiedPatchSet: Sendable, Equatable, Identifiable {
    let id: UUID
    let receipt: VerifiedPatchIngressReceipt
    let operations: [VerifiedPatchOperation]
}

nonisolated enum VerifiedInversePreviewKind: String, Sendable, Equatable {
    case applyTextHunks
    case restoreExactFile
    case removeCreatedFile
    case restoreDeletedFile
    case simulateRenamedFile
}

nonisolated enum VerifiedInversePreviewLineKind: String, Sendable, Equatable {
    case context
    case remove
    case add
}

nonisolated struct VerifiedInversePreviewLine: Sendable, Equatable {
    let kind: VerifiedInversePreviewLineKind
    let bytes: Data
}

nonisolated struct VerifiedInverseHunkPreview: Sendable, Equatable {
    let capturedAfterStartLine: Int
    let resolvedCurrentStartLine: Int?
    let header: String
    let lines: [VerifiedInversePreviewLine]
}

/// Structured preview. Prepared previews describe resolved current ranges;
/// nominal previews have `resolvedCurrentStartLine == nil`.
nonisolated struct VerifiedInverseOperationPreview: Sendable, Equatable {
    let operationID: VerifiedPatchOperationID
    let kind: VerifiedInversePreviewKind
    let sourcePath: String
    let destinationPath: String?
    let expectedCurrent: VerifiedPatchStateIdentity?
    let result: VerifiedPatchStateIdentity?
    let hunks: [VerifiedInverseHunkPreview]
}

/// In-memory current state supplied by the future descriptor coordinator.
nonisolated struct VerifiedPatchWorkspaceSnapshot: Sendable, Equatable {
    let files: [String: VerifiedPatchFileState]
}

nonisolated enum VerifiedPatchConflictReason: Error, Sendable, Equatable {
    case expectedFileMissing
    case unexpectedFilePresent
    case exactStateDiverged
    case unsupportedCurrentFileKind
    case currentContentIsNotText
    case humanEditOverlapsAgentRegion(hunkIndex: Int)
    case ambiguousCurrentMapping(hunkIndex: Int)
    case mappedRegionMismatch(hunkIndex: Int)
    case overlappingResolvedHunks
    case snapshotChangedAfterPreparation
    case invalidCurrentSnapshot
    case resourceLimitExceeded
}

nonisolated struct VerifiedPatchConflict: Error, Sendable, Equatable {
    let operationID: VerifiedPatchOperationID?
    let path: String?
    let reason: VerifiedPatchConflictReason
}

nonisolated enum VerifiedPatchPreparedMode: Sendable, Equatable {
    case checkedText
    case exactState
}

nonisolated struct VerifiedPreparedPathExpectation: Sendable, Equatable {
    let path: String
    let state: VerifiedPatchFileState?
}

nonisolated struct VerifiedPreparedPathResult: Sendable, Equatable {
    let path: String
    let state: VerifiedPatchFileState?
}

nonisolated struct VerifiedPreparedTextHunk: Sendable, Equatable {
    let capturedAfterRange: Range<Int>
    let resolvedCurrentRange: Range<Int>
    let replacementLines: [Data]
}

nonisolated struct VerifiedPreparedInverseOperation: Sendable, Equatable {
    let operationID: VerifiedPatchOperationID
    let kind: VerifiedPatchOperationKind
    let mode: VerifiedPatchPreparedMode
    let expectations: [VerifiedPreparedPathExpectation]
    let results: [VerifiedPreparedPathResult]
    let resolvedTextHunks: [VerifiedPreparedTextHunk]
    let preview: VerifiedInverseOperationPreview
}

/// Values the final coordinator must revalidate before any disk mutation.
nonisolated struct VerifiedPatchCoordinatorExpectations:
    Sendable,
    Equatable {
    let privateWorkspaceID: UUID
    let canonicalRootPath: String
    let rootDevice: UInt64
    let rootInode: UInt64
    let capturedHeadOID: String
    let capturedIndexSHA256: String
    let durableEvents: [VerifiedPatchDurableEventIdentity]
    let mediatedWriterReceipts: [PineMediatedWriterReceipt]
}

/// Fully resolved pure inverse plan.
///
/// `applyPrepared` revalidates every value-level expectation, so synthesized or
/// stale values cannot bypass the prepare/apply boundary. This still grants no
/// authority: the final coordinator must call
/// `revalidateAuthorityEvidence`, then perform #1207's
/// descriptor/root/Git/index checks and consume its separate authority.
nonisolated struct PreparedInverse: Sendable, Equatable {
    let patch: VerifiedPatchSet
    let coordinatorExpectations: VerifiedPatchCoordinatorExpectations
    let operations: [VerifiedPreparedInverseOperation]
    let previews: [VerifiedInverseOperationPreview]

    var patchID: UUID { patch.id }

    init(
        patch: VerifiedPatchSet,
        coordinatorExpectations: VerifiedPatchCoordinatorExpectations,
        operations: [VerifiedPreparedInverseOperation]
    ) {
        self.patch = patch
        self.coordinatorExpectations = coordinatorExpectations
        self.operations = operations
        self.previews = operations.map(\.preview)
    }
}

nonisolated enum VerifiedPatchPreparationFailure:
    Error,
    Sendable,
    Equatable {
    case invalidPatch(VerifiedPatchValidationError)
    case conflicts([VerifiedPatchConflict])
    case unsupportedOperation(
        VerifiedPatchOperationID,
        VerifiedPatchOperationKind
    )
}

/// Atomic result: a conflict never exposes a partially transformed snapshot.
nonisolated enum VerifiedCheckedInverseResult: Sendable, Equatable {
    case applied(
        snapshot: VerifiedPatchWorkspaceSnapshot,
        previews: [VerifiedInverseOperationPreview]
    )
    case conflicted([VerifiedPatchConflict])
}

nonisolated enum VerifiedPatchValidationError: Error, Sendable, Equatable {
    case invalidWorkspaceIdentity
    case invalidReceipt
    case invalidEnvelope(UUID)
    case eventMetadataTooLarge
    case unverifiedEnvelope(UUID)
    case duplicateEnvelope(UUID)
    case invalidDurableEvent(UUID)
    case duplicateJournalSequence(UInt64)
    case journalOrderMismatch(previous: UInt64, actual: UInt64)
    case missingMediatedWriterReceipt(UUID)
    case invalidMediatedWriterReceipt(UUID)
    case duplicateMediatedWriterReceipt(UUID)
    case cursorReplay(UInt64)
    case cursorGap(expected: UInt64, actual: UInt64)
    case tooManyEvents
    case tooManyTransitions
    case invalidTransition(VerifiedPatchTransitionID?)
    case invalidPatchID
    case noOperations
    case tooManyOperations
    case invalidOperation(VerifiedPatchTransitionID?)
    case invalidPath(String)
    case protectedPath(String)
    case aliasedPath(String)
    case duplicateTransition(VerifiedPatchTransitionID)
    case unboundOperation(VerifiedPatchTransitionID)
    case unusedTransition(VerifiedPatchTransitionID)
    case transitionChainMismatch(String)
    case contentTooLarge
    case aggregateContentTooLarge
    case tooManyHunks
    case lcsBudgetExceeded
    case invalidSnapshot
    case tooManyVersionPatches
    case tooManyVersionNodes
    case duplicatePatchID(UUID)
}
