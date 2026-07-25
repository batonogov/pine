//
//  VerifiedPatchEngine.swift
//  Pine
//
//  Pure ingress, preparation, preview, and rechecked application for #933.
//

import Foundation

/// Pure ingress validation for full provenance envelopes.
///
/// The future live coordinator owns where these records came from. This layer
/// verifies source/trust/scope/cursor/transition consistency but never treats
/// the resulting receipt as #1207 mutation authority.
nonisolated enum VerifiedPatchIngressCoordinator {
    static func accept(
        receiptID: UUID,
        workspace: VerifiedPatchWorkspaceIdentity,
        records: [VerifiedPatchUntrustedEventRecord]
    ) throws -> VerifiedPatchIngressReceipt {
        guard receiptID != zeroUUID,
              isValidWorkspace(workspace) else {
            throw VerifiedPatchValidationError.invalidWorkspaceIdentity
        }
        guard !records.isEmpty else {
            throw VerifiedPatchValidationError.invalidReceipt
        }
        guard records.count <= VerifiedPatchLimits.maximumEventCount else {
            throw VerifiedPatchValidationError.tooManyEvents
        }

        let ordered = records.sorted(by: eventOrder)
        guard let first = ordered.first else {
            throw VerifiedPatchValidationError.invalidReceipt
        }
        let projectID = first.envelope.projectID
        let sessionID = first.envelope.sessionID
        let process = first.envelope.process
        var envelopeIDs: Set<UUID> = []
        var durableIdentities: Set<VerifiedPatchDurableEventIdentity> = []
        var journalSequences: Set<UInt64> = []
        var mediatedState = MediatedReceiptValidationState()
        var transitionCount = 0
        var eventMetadataBytes = 0
        var accepted: [VerifiedPatchAcceptedEvent] = []

        for (index, record) in ordered.enumerated() {
            let envelope = record.envelope
            guard envelope.id != zeroUUID,
                  envelope.projectID == projectID,
                  envelope.sessionID == sessionID,
                  envelope.process == process,
                  envelope.location.worktreePath
                    == workspace.canonicalRootPath,
                  envelope.cursorValue > 0,
                  envelope.timestamp.timeIntervalSinceReferenceDate.isFinite
            else {
                throw VerifiedPatchValidationError.invalidEnvelope(
                    envelope.id
                )
            }
            guard envelope.source == .explicitAgentEvent,
                  envelope.trustLevel == .verified else {
                throw VerifiedPatchValidationError.unverifiedEnvelope(
                    envelope.id
                )
            }
            guard let envelopeMetadataBytes = metadataByteCount(envelope),
                  envelopeMetadataBytes
                    <= VerifiedPatchLimits.maximumEventMetadataByteCount,
                  let aggregateMetadataBytes = checkedAdd(
                    eventMetadataBytes,
                    envelopeMetadataBytes
                  ),
                  aggregateMetadataBytes <= VerifiedPatchLimits
                    .maximumAggregateEventMetadataByteCount else {
                throw VerifiedPatchValidationError.eventMetadataTooLarge
            }
            eventMetadataBytes = aggregateMetadataBytes
            guard envelopeIDs.insert(envelope.id).inserted else {
                throw VerifiedPatchValidationError.duplicateEnvelope(
                    envelope.id
                )
            }
            try validateDurableIdentity(
                record.durableIdentity,
                envelope: envelope,
                workspace: workspace
            )
            guard durableIdentities.insert(
                record.durableIdentity
            ).inserted else {
                throw VerifiedPatchValidationError.invalidDurableEvent(
                    envelope.id
                )
            }
            guard journalSequences.insert(
                record.durableIdentity.journalSequence
            ).inserted else {
                throw VerifiedPatchValidationError
                    .duplicateJournalSequence(
                        record.durableIdentity.journalSequence
                    )
            }
            guard let updatedTransitionCount = checkedAdd(
                transitionCount,
                record.transitions.count
            ),
            updatedTransitionCount
                <= VerifiedPatchLimits.maximumTransitionCount else {
                throw VerifiedPatchValidationError.tooManyTransitions
            }
            transitionCount = updatedTransitionCount
            for (ordinal, transition) in record.transitions.enumerated() {
                try validate(
                    transition,
                    id: VerifiedPatchTransitionID(
                        envelopeID: envelope.id,
                        ordinal: ordinal
                    )
                )
            }
            try validateMediatedWriterReceipt(
                record,
                workspace: workspace,
                state: &mediatedState
            )
            try validatePayloadBinding(record)

            if index > 0 {
                let previousRecord = ordered[index - 1]
                let previousCursor = previousRecord.envelope.cursorValue
                if envelope.cursorValue == previousCursor {
                    throw VerifiedPatchValidationError.cursorReplay(
                        previousCursor
                    )
                }
                guard previousCursor < UInt64.max else {
                    throw VerifiedPatchValidationError.cursorGap(
                        expected: UInt64.max,
                        actual: envelope.cursorValue
                    )
                }
                let expected = previousCursor + 1
                guard envelope.cursorValue == expected else {
                    throw VerifiedPatchValidationError.cursorGap(
                        expected: expected,
                        actual: envelope.cursorValue
                    )
                }
                let previousSequence = previousRecord
                    .durableIdentity.journalSequence
                guard previousSequence
                        < record.durableIdentity.journalSequence else {
                    throw VerifiedPatchValidationError.journalOrderMismatch(
                        previous: previousSequence,
                        actual: record.durableIdentity.journalSequence
                    )
                }
            }
            accepted.append(VerifiedPatchAcceptedEvent(
                envelope: envelope,
                durableIdentity: record.durableIdentity,
                mediatedWriterReceipt: record.mediatedWriterReceipt,
                transitions: record.transitions
            ))
        }

        return VerifiedPatchIngressReceipt(
            receiptID: receiptID,
            workspace: workspace,
            projectID: projectID,
            sessionID: sessionID,
            process: process,
            events: accepted
        )
    }

    /// Revalidates a synthesized or decoded receipt by passing it through the
    /// same untrusted DTO boundary. No receipt field is trusted by shape.
    static func revalidate(
        _ receipt: VerifiedPatchIngressReceipt
    ) throws -> VerifiedPatchIngressReceipt {
        let rebuilt = try accept(
            receiptID: receipt.receiptID,
            workspace: receipt.workspace,
            records: receipt.events.map {
                VerifiedPatchUntrustedEventRecord(
                    envelope: $0.envelope,
                    durableIdentity: $0.durableIdentity,
                    mediatedWriterReceipt: $0.mediatedWriterReceipt,
                    transitions: $0.transitions
                )
            }
        )
        guard rebuilt == receipt else {
            throw VerifiedPatchValidationError.invalidReceipt
        }
        return rebuilt
    }

    static func isAllowedRelativePath(_ path: String) -> Bool {
        guard path.utf8.count
                <= VerifiedPatchLimits.maximumPathByteCount,
              AgentHistoryUndoPreflight.isCanonicalRelativePath(path) else {
            return false
        }
        return !path.split(separator: "/").contains {
            AgentHistoryUndoPreflight.conservativePathKey(String($0))
                == ".pine"
        }
    }

    static func conservativePathKey(_ path: String) -> String {
        AgentHistoryUndoPreflight.conservativePathKey(path)
    }

    private static func validate(
        _ transition: VerifiedPatchContentTransition,
        id: VerifiedPatchTransitionID
    ) throws {
        guard isAllowedRelativePath(transition.sourcePath) else {
            throw pathError(transition.sourcePath)
        }
        if let destinationPath = transition.destinationPath {
            guard isAllowedRelativePath(destinationPath) else {
                throw pathError(destinationPath)
            }
            guard conservativePathKey(destinationPath)
                    != conservativePathKey(transition.sourcePath),
                  transition.before != nil,
                  transition.after != nil else {
                throw VerifiedPatchValidationError.invalidTransition(id)
            }
        }
        guard transition.before != nil || transition.after != nil,
              transition.before.map(isValidStateIdentity) ?? true,
              transition.after.map(isValidStateIdentity) ?? true else {
            throw VerifiedPatchValidationError.invalidTransition(id)
        }
    }

    private static func validateDurableIdentity(
        _ identity: VerifiedPatchDurableEventIdentity,
        envelope: AgentEventEnvelope,
        workspace: VerifiedPatchWorkspaceIdentity
    ) throws {
        guard identity.projectID == envelope.projectID,
              identity.canonicalWorktreePath
                == workspace.canonicalRootPath,
              identity.canonicalWorktreePath
                == envelope.location.worktreePath,
              identity.sessionID == envelope.sessionID,
              identity.terminalID == envelope.process.terminalID,
              identity.processGeneration
                == envelope.process.processGeneration,
              identity.eventCursor == envelope.cursorValue,
              identity.envelopeID == envelope.id,
              identity.journalSequence > 0 else {
            throw VerifiedPatchValidationError.invalidDurableEvent(
                envelope.id
            )
        }
    }

    private static func validateMediatedWriterReceipt(
        _ record: VerifiedPatchUntrustedEventRecord,
        workspace: VerifiedPatchWorkspaceIdentity,
        state: inout MediatedReceiptValidationState
    ) throws {
        guard !record.transitions.isEmpty else {
            guard record.mediatedWriterReceipt == nil else {
                throw VerifiedPatchValidationError
                    .invalidMediatedWriterReceipt(record.envelope.id)
            }
            return
        }
        guard let receipt = record.mediatedWriterReceipt else {
            throw VerifiedPatchValidationError
                .missingMediatedWriterReceipt(record.envelope.id)
        }
        guard receipt.receiptID != zeroUUID,
              receipt.userApprovalID != zeroUUID,
              receipt.descriptorTransactionID != zeroUUID,
              receipt.descriptorCASSequence > 0,
              receipt.workspace == workspace,
              receipt.auditEvent == record.durableIdentity,
              receipt.transitions == record.transitions else {
            throw VerifiedPatchValidationError
                .invalidMediatedWriterReceipt(record.envelope.id)
        }
        guard state.receiptIDs.insert(receipt.receiptID).inserted,
              state.transactionIDs.insert(
                receipt.descriptorTransactionID
              ).inserted,
              state.casSequences.insert(
                receipt.descriptorCASSequence
              ).inserted else {
            throw VerifiedPatchValidationError
                .duplicateMediatedWriterReceipt(receipt.receiptID)
        }
        if let lastSequence = state.lastSequence {
            guard receipt.descriptorCASSequence > lastSequence else {
                throw VerifiedPatchValidationError
                    .invalidMediatedWriterReceipt(record.envelope.id)
            }
        }
        state.lastSequence = receipt.descriptorCASSequence
    }

    private static func validatePayloadBinding(
        _ record: VerifiedPatchUntrustedEventRecord
    ) throws {
        guard case .fileChange(let change) = record.envelope.payload else {
            return
        }
        let matches = record.transitions.filter { transition in
            transition.destinationPath == nil
                && transition.sourcePath == change.relativePath
                && transition.before?.contentIdentity == change.before
                && transition.after?.contentIdentity == change.after
        }
        guard matches.count == 1 else {
            throw VerifiedPatchValidationError.invalidEnvelope(
                record.envelope.id
            )
        }
    }

    private static func metadataByteCount(
        _ envelope: AgentEventEnvelope
    ) -> Int? {
        var result = 0
        let strings: [String]
        switch envelope.payload {
        case .none:
            strings = [
                envelope.agentTypeRaw,
                envelope.location.worktreePath,
                envelope.location.cwd
            ]
        case .commandResult(let command):
            strings = [
                envelope.agentTypeRaw,
                envelope.location.worktreePath,
                envelope.location.cwd,
                command.command
            ]
        case .fileChange(let change):
            strings = [
                envelope.agentTypeRaw,
                envelope.location.worktreePath,
                envelope.location.cwd,
                change.relativePath
            ]
        }
        for string in strings {
            guard let updated = checkedAdd(result, string.utf8.count) else {
                return nil
            }
            result = updated
        }
        return result
    }

    private static func isValidStateIdentity(
        _ state: VerifiedPatchStateIdentity
    ) -> Bool {
        state.kind == .regularFile
            && state.posixMode <= 0o7777
    }

    static func isValidWorkspace(
        _ workspace: VerifiedPatchWorkspaceIdentity
    ) -> Bool {
        workspace.privateWorkspaceID != zeroUUID
            && workspace.rootDevice > 0
            && workspace.rootInode > 0
            && isCanonicalAbsolutePath(workspace.canonicalRootPath)
            && isGitOIDOrEmpty(workspace.capturedHeadOID)
            && isSHA256OrEmpty(workspace.capturedIndexSHA256)
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        let normalized = path.precomposedStringWithCanonicalMapping
        guard path.hasPrefix("/"),
              path != "/",
              path.utf8.elementsEqual(normalized.utf8),
              !path.utf8.contains(0),
              path.utf8.count
                <= VerifiedPatchLimits.maximumPathByteCount else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.first?.isEmpty == true
            && components.dropFirst().allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func isGitOIDOrEmpty(_ value: String) -> Bool {
        value.isEmpty || isLowercaseHex(value, allowedCounts: [40, 64])
    }

    private static func isSHA256OrEmpty(_ value: String) -> Bool {
        value.isEmpty || isLowercaseHex(value, allowedCounts: [64])
    }

    private static func isLowercaseHex(
        _ value: String,
        allowedCounts: Set<Int>
    ) -> Bool {
        allowedCounts.contains(value.utf8.count)
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func pathError(
        _ path: String
    ) -> VerifiedPatchValidationError {
        let keyComponents = path.split(separator: "/").map {
            conservativePathKey(String($0))
        }
        if keyComponents.contains(".git")
            || keyComponents.contains(".pine") {
            return .protectedPath(path)
        }
        return .invalidPath(path)
    }

    private static func eventOrder(
        _ lhs: VerifiedPatchUntrustedEventRecord,
        _ rhs: VerifiedPatchUntrustedEventRecord
    ) -> Bool {
        if lhs.envelope.cursorValue != rhs.envelope.cursorValue {
            return lhs.envelope.cursorValue < rhs.envelope.cursorValue
        }
        return lhs.envelope.id.uuidString < rhs.envelope.id.uuidString
    }

    private struct MediatedReceiptValidationState {
        var receiptIDs: Set<UUID> = []
        var transactionIDs: Set<UUID> = []
        var casSequences: Set<UInt64> = []
        var lastSequence: UInt64?
    }
}

/// Deterministic, side-effect-free patch simulation engine.
nonisolated enum VerifiedPatchEngine {
    static func makePatch(
        id: UUID,
        receipt: VerifiedPatchIngressReceipt,
        operations sources: [VerifiedPatchSourceOperation]
    ) throws -> VerifiedPatchSet {
        guard id != zeroUUID else {
            throw VerifiedPatchValidationError.invalidPatchID
        }
        let validatedReceipt = try VerifiedPatchIngressCoordinator.revalidate(
            receipt
        )
        guard !sources.isEmpty else {
            throw VerifiedPatchValidationError.noOperations
        }
        guard sources.count
                <= VerifiedPatchLimits.maximumTransitionCount else {
            throw VerifiedPatchValidationError.tooManyTransitions
        }

        let boundTransitions = try transitionMap(validatedReceipt)
        var seenTransitionIDs: Set<VerifiedPatchTransitionID> = []
        var validatedSources: [OrderedSource] = []
        var capturedBytes = 0

        for source in sources {
            guard seenTransitionIDs.insert(source.transitionID).inserted else {
                throw VerifiedPatchValidationError.duplicateTransition(
                    source.transitionID
                )
            }
            guard let bound = boundTransitions[source.transitionID] else {
                throw VerifiedPatchValidationError.unboundOperation(
                    source.transitionID
                )
            }
            try validateSource(source, bound: bound.transition)
            for state in [source.before, source.after].compactMap({ $0 }) {
                guard let updated = checkedAdd(
                    capturedBytes,
                    state.content.count
                ),
                updated
                    <= VerifiedPatchLimits.maximumCapturedByteCount else {
                    throw VerifiedPatchValidationError
                        .aggregateContentTooLarge
                }
                capturedBytes = updated
            }
            validatedSources.append(OrderedSource(
                cursor: bound.cursor,
                source: source
            ))
        }
        for transitionID in boundTransitions.keys
        where !seenTransitionIDs.contains(transitionID) {
            throw VerifiedPatchValidationError.unusedTransition(transitionID)
        }

        let collapsed = try collapse(
            validatedSources,
            patchID: id
        )
        guard !collapsed.isEmpty else {
            throw VerifiedPatchValidationError.noOperations
        }
        guard collapsed.count
                <= VerifiedPatchLimits.maximumOperationCount else {
            throw VerifiedPatchValidationError.tooManyOperations
        }
        let patch = VerifiedPatchSet(
            id: id,
            receipt: validatedReceipt,
            operations: collapsed.sorted(by: operationOrder)
        )
        try revalidate(patch)
        return patch
    }

    /// Nominal preview from captured states only. It is display data and does
    /// not imply the inverse can be applied to a current snapshot.
    static func previewInverse(
        _ patch: VerifiedPatchSet
    ) -> [VerifiedInverseOperationPreview] {
        patch.operations.map { operation in
            preview(
                operation,
                expectedCurrent: operation.after,
                result: operation.before,
                resolvedHunks: nil
            )
        }
    }

    /// Resolves all actual current ranges and result bytes without I/O.
    ///
    /// Rename remains previewable but is deliberately not preparable because
    /// #1207's mutation transaction does not authorize rename yet.
    static func prepareCheckedInverse(
        _ patch: VerifiedPatchSet,
        currentSnapshot: VerifiedPatchWorkspaceSnapshot
    ) -> Result<PreparedInverse, VerifiedPatchPreparationFailure> {
        do {
            try revalidate(patch)
            try validateSnapshot(currentSnapshot)
        } catch let error as VerifiedPatchValidationError {
            return .failure(.invalidPatch(error))
        } catch {
            return .failure(.invalidPatch(.invalidSnapshot))
        }

        var prepared: [VerifiedPreparedInverseOperation] = []
        var aggregateLCSCells = 0
        for operation in patch.operations {
            if operation.kind == .rename {
                return .failure(.unsupportedOperation(
                    operation.id,
                    .rename
                ))
            }
            switch prepare(
                operation,
                snapshot: currentSnapshot,
                aggregateLCSCells: &aggregateLCSCells
            ) {
            case .success(let value):
                prepared.append(value)
            case .failure(let conflict):
                return .failure(.conflicts([conflict]))
            }
        }
        let workspace = patch.receipt.workspace
        return .success(PreparedInverse(
            patch: patch,
            coordinatorExpectations: VerifiedPatchCoordinatorExpectations(
                privateWorkspaceID: workspace.privateWorkspaceID,
                canonicalRootPath: workspace.canonicalRootPath,
                rootDevice: workspace.rootDevice,
                rootInode: workspace.rootInode,
                capturedHeadOID: workspace.capturedHeadOID,
                capturedIndexSHA256: workspace.capturedIndexSHA256,
                durableEvents: patch.receipt.durableEventIdentities,
                mediatedWriterReceipts: patch.receipt
                    .mediatedWriterReceipts
            ),
            operations: prepared
        ))
    }

    /// Rechecks exact prepared expectations against a fresh in-memory snapshot.
    ///
    /// The final coordinator must still perform the equivalent checks through
    /// open descriptors and revalidate root/HEAD/index immediately before its
    /// atomic #1207 transaction.
    static func applyPrepared(
        _ prepared: PreparedInverse,
        currentSnapshot: VerifiedPatchWorkspaceSnapshot
    ) -> VerifiedCheckedInverseResult {
        do {
            try validateSnapshot(currentSnapshot)
            try validatePrepared(prepared)
        } catch {
            return .conflicted([VerifiedPatchConflict(
                operationID: nil,
                path: nil,
                reason: .invalidCurrentSnapshot
            )])
        }

        for operation in prepared.operations {
            for expectation in operation.expectations {
                guard currentSnapshot.files[expectation.path]
                        == expectation.state else {
                    return .conflicted([VerifiedPatchConflict(
                        operationID: operation.operationID,
                        path: expectation.path,
                        reason: .snapshotChangedAfterPreparation
                    )])
                }
            }
        }

        var transformed = currentSnapshot.files
        for operation in prepared.operations {
            for result in operation.results {
                transformed[result.path] = result.state
            }
        }
        return .applied(
            snapshot: VerifiedPatchWorkspaceSnapshot(files: transformed),
            previews: prepared.previews
        )
    }

    /// Revalidates both authorship and nested journal audit evidence.
    ///
    /// Success is still not mutation authority. The caller must continue into
    /// #1207's descriptor/root/HEAD/index checks and one-shot authority
    /// consumption. Taking the combined protocol here prevents a
    /// journal-only receipt from crossing this seam.
    static func revalidateAuthorityEvidence(
        _ prepared: PreparedInverse,
        using revalidator: any PatchAuthorityEvidenceRevalidator
    ) async throws {
        try validatePrepared(prepared)
        let expectations = prepared.coordinatorExpectations
        guard !expectations.mediatedWriterReceipts.isEmpty else {
            throw VerifiedPatchValidationError.invalidReceipt
        }
        try await revalidator.revalidateMediatedWriterReceipts(
            expectations.mediatedWriterReceipts
        )
        try await revalidator.revalidateDurableEvents(
            expectations.durableEvents
        )
    }

    private static func prepare(
        _ operation: VerifiedPatchOperation,
        snapshot: VerifiedPatchWorkspaceSnapshot,
        aggregateLCSCells: inout Int
    ) -> Result<VerifiedPreparedInverseOperation, VerifiedPatchConflict> {
        switch operation.kind {
        case .modify:
            return prepareModify(
                operation,
                snapshot: snapshot,
                aggregateLCSCells: &aggregateLCSCells
            )
        case .create:
            guard let after = operation.after else {
                return .failure(conflict(operation, .exactStateDiverged))
            }
            guard let current = snapshot.files[operation.sourcePath] else {
                return .failure(conflict(operation, .expectedFileMissing))
            }
            guard current == after else {
                return .failure(conflict(operation, .exactStateDiverged))
            }
            guard let prepared = preparedExact(
                operation,
                expectations: [expectation(
                    operation.sourcePath,
                    current
                )],
                results: [result(operation.sourcePath, nil)]
            ) else {
                return .failure(conflict(
                    operation,
                    .resourceLimitExceeded
                ))
            }
            return .success(prepared)
        case .delete:
            guard let before = operation.before else {
                return .failure(conflict(operation, .exactStateDiverged))
            }
            guard snapshot.files[operation.sourcePath] == nil else {
                return .failure(
                    conflict(operation, .unexpectedFilePresent)
                )
            }
            guard let prepared = preparedExact(
                operation,
                expectations: [expectation(operation.sourcePath, nil)],
                results: [result(operation.sourcePath, before)]
            ) else {
                return .failure(conflict(
                    operation,
                    .resourceLimitExceeded
                ))
            }
            return .success(prepared)
        case .rename:
            return .failure(conflict(operation, .exactStateDiverged))
        }
    }

    private static func prepareModify(
        _ operation: VerifiedPatchOperation,
        snapshot: VerifiedPatchWorkspaceSnapshot,
        aggregateLCSCells: inout Int
    ) -> Result<VerifiedPreparedInverseOperation, VerifiedPatchConflict> {
        guard let before = operation.before,
              let after = operation.after else {
            return .failure(conflict(operation, .exactStateDiverged))
        }
        guard let current = snapshot.files[operation.sourcePath] else {
            return .failure(conflict(operation, .expectedFileMissing))
        }
        guard current.kind == .regularFile else {
            return .failure(
                conflict(operation, .unsupportedCurrentFileKind)
            )
        }
        if current == after {
            guard let prepared = preparedExact(
                operation,
                expectations: [expectation(
                    operation.sourcePath,
                    current
                )],
                results: [result(operation.sourcePath, before)]
            ) else {
                return .failure(conflict(
                    operation,
                    .resourceLimitExceeded
                ))
            }
            return .success(prepared)
        }
        guard current.posixMode == after.posixMode else {
            return .failure(conflict(operation, .exactStateDiverged))
        }
        guard case .text(let hunks, _) = operation.strategy,
              let estimate = VerifiedTextPatch.estimatedLCSCellCount(
                before: after.content,
                after: current.content
              ),
              let newAggregate = checkedAdd(
                aggregateLCSCells,
                estimate
              ),
              newAggregate
                <= VerifiedPatchLimits.maximumAggregateLCSCellCount else {
            return .failure(conflict(operation, .resourceLimitExceeded))
        }
        aggregateLCSCells = newAggregate

        switch VerifiedTextPatch.prepareInverse(
            hunks: hunks,
            capturedAfter: after.content,
            current: current.content
        ) {
        case .failure(let reason):
            return .failure(conflict(operation, reason))
        case .success(let textResult):
            let merged = VerifiedPatchFileState(
                content: textResult.content,
                kind: .regularFile,
                posixMode: before.posixMode
            )
            let operationPreview = preview(
                operation,
                expectedCurrent: current,
                result: merged,
                resolvedHunks: textResult.hunks
            )
            return .success(VerifiedPreparedInverseOperation(
                operationID: operation.id,
                kind: operation.kind,
                mode: .checkedText,
                expectations: [expectation(
                    operation.sourcePath,
                    current
                )],
                results: [result(operation.sourcePath, merged)],
                resolvedTextHunks: textResult.hunks,
                preview: operationPreview
            ))
        }
    }

    private static func preparedExact(
        _ operation: VerifiedPatchOperation,
        expectations: [VerifiedPreparedPathExpectation],
        results: [VerifiedPreparedPathResult]
    ) -> VerifiedPreparedInverseOperation? {
        let resolvedHunks: [VerifiedPreparedTextHunk]
        switch operation.strategy {
        case .exactState:
            resolvedHunks = []
        case .text(let hunks, _):
            var checkedHunks: [VerifiedPreparedTextHunk] = []
            for hunk in hunks {
                guard let end = checkedAdd(
                    hunk.afterStartLine,
                    hunk.afterLineCount
                ) else {
                    return nil
                }
                let range = hunk.afterStartLine..<end
                checkedHunks.append(VerifiedPreparedTextHunk(
                    capturedAfterRange: range,
                    resolvedCurrentRange: range,
                    replacementLines: hunk.beforeLines
                ))
            }
            resolvedHunks = checkedHunks
        }
        return VerifiedPreparedInverseOperation(
            operationID: operation.id,
            kind: operation.kind,
            mode: .exactState,
            expectations: expectations,
            results: results,
            resolvedTextHunks: resolvedHunks,
            preview: preview(
                operation,
                expectedCurrent: expectations.first?.state,
                result: results.first?.state,
                resolvedHunks: resolvedHunks
            )
        )
    }

    private static func collapse(
        _ orderedSources: [OrderedSource],
        patchID: UUID
    ) throws -> [VerifiedPatchOperation] {
        let sorted = orderedSources.sorted(by: sourceOrder)
        var groups: [String: [VerifiedPatchSourceOperation]] = [:]
        var spellings: [String: String] = [:]
        for ordered in sorted {
            let source = ordered.source
            let key = VerifiedPatchIngressCoordinator.conservativePathKey(
                source.sourcePath
            )
            if let existing = spellings[key],
               existing != source.sourcePath {
                throw VerifiedPatchValidationError.aliasedPath(
                    source.sourcePath
                )
            }
            spellings[key] = source.sourcePath
            groups[key, default: []].append(source)
        }

        var operations: [VerifiedPatchOperation] = []
        var occupiedPathKeys: Set<String> = []
        var aggregateLCSCells = 0
        var aggregateHunks = 0
        for key in groups.keys.sorted() {
            guard let chain = groups[key],
                  let first = chain.first,
                  let last = chain.last else {
                continue
            }
            if chain.contains(where: { $0.destinationPath != nil }) {
                guard chain.count == 1 else {
                    throw VerifiedPatchValidationError
                        .transitionChainMismatch(first.sourcePath)
                }
            } else {
                for index in chain.indices.dropFirst() {
                    guard chain[index - 1].after == chain[index].before else {
                        throw VerifiedPatchValidationError
                            .transitionChainMismatch(first.sourcePath)
                    }
                }
            }

            let before = first.before
            let after = last.after
            guard before != after else {
                throw VerifiedPatchValidationError.invalidOperation(
                    first.transitionID
                )
            }
            let kind = try operationKind(
                destinationPath: first.destinationPath,
                before: before,
                after: after,
                transitionID: first.transitionID
            )
            var strategy: VerifiedPatchApplicationStrategy = .exactState
            if kind == .modify,
               let before,
               let after,
               before.content != after.content,
               let estimate = VerifiedTextPatch.estimatedLCSCellCount(
                before: before.content,
                after: after.content
               ),
               let estimatedAggregate = checkedAdd(
                aggregateLCSCells,
                estimate
               ),
               estimatedAggregate
                <= VerifiedPatchLimits.maximumAggregateLCSCellCount,
               let plan = VerifiedTextPatch.plan(
                before: before.content,
                after: after.content
               ),
               let hunkAggregate = checkedAdd(
                aggregateHunks,
                plan.hunks.count
               ),
               hunkAggregate <= VerifiedPatchLimits.maximumHunkCount {
                aggregateLCSCells = estimatedAggregate
                aggregateHunks = hunkAggregate
                strategy = .text(
                    hunks: plan.hunks,
                    lcsCellCount: plan.lcsCellCount
                )
            }
            let operation = VerifiedPatchOperation(
                id: VerifiedPatchOperationID(
                    patchID: patchID,
                    transitionIDs: chain.map(\.transitionID)
                ),
                kind: kind,
                sourcePath: first.sourcePath,
                destinationPath: first.destinationPath,
                before: before,
                after: after,
                strategy: strategy
            )
            for path in operation.touchedPaths {
                let touchedKey = VerifiedPatchIngressCoordinator
                    .conservativePathKey(path)
                guard occupiedPathKeys.insert(touchedKey).inserted else {
                    throw VerifiedPatchValidationError.aliasedPath(path)
                }
            }
            operations.append(operation)
        }
        return operations
    }

    private static func transitionMap(
        _ receipt: VerifiedPatchIngressReceipt
    ) throws -> [VerifiedPatchTransitionID: BoundTransition] {
        var result: [VerifiedPatchTransitionID: BoundTransition] = [:]
        for event in receipt.events {
            for (ordinal, transition) in event.transitions.enumerated() {
                let id = VerifiedPatchTransitionID(
                    envelopeID: event.envelope.id,
                    ordinal: ordinal
                )
                guard result[id] == nil else {
                    throw VerifiedPatchValidationError.duplicateTransition(id)
                }
                result[id] = BoundTransition(
                    cursor: event.envelope.cursorValue,
                    transition: transition
                )
            }
        }
        return result
    }

    private static func validateSource(
        _ source: VerifiedPatchSourceOperation,
        bound: VerifiedPatchContentTransition
    ) throws {
        guard source.sourcePath == bound.sourcePath,
              source.destinationPath == bound.destinationPath,
              source.before?.stateIdentity == bound.before,
              source.after?.stateIdentity == bound.after else {
            throw VerifiedPatchValidationError.unboundOperation(
                source.transitionID
            )
        }
        for state in [source.before, source.after].compactMap({ $0 }) {
            guard state.kind == .regularFile,
                  state.posixMode <= 0o7777 else {
                throw VerifiedPatchValidationError.invalidOperation(
                    source.transitionID
                )
            }
            guard state.content.count
                    <= VerifiedPatchLimits.maximumFileByteCount else {
                throw VerifiedPatchValidationError.contentTooLarge
            }
        }
    }

    static func revalidate(_ patch: VerifiedPatchSet) throws {
        guard patch.id != zeroUUID,
              !patch.operations.isEmpty,
              patch.operations.count
                <= VerifiedPatchLimits.maximumOperationCount else {
            throw VerifiedPatchValidationError.invalidPatchID
        }
        let receipt = try VerifiedPatchIngressCoordinator.revalidate(
            patch.receipt
        )
        let transitions = try transitionMap(receipt)
        var transitionIDs: Set<VerifiedPatchTransitionID> = []
        var pathKeys: Set<String> = []
        var capturedBytes = 0
        var hunkCount = 0
        var lcsCells = 0

        for operation in patch.operations {
            guard operation.id.patchID == patch.id,
                  !operation.id.transitionIDs.isEmpty else {
                throw VerifiedPatchValidationError.invalidOperation(nil)
            }
            var priorAfter: VerifiedPatchStateIdentity?
            var priorCursor: UInt64?
            var priorOrdinal: Int?
            for (index, transitionID) in operation.id.transitionIDs
                .enumerated() {
                guard transitionIDs.insert(transitionID).inserted,
                      let bound = transitions[transitionID] else {
                    throw VerifiedPatchValidationError.unboundOperation(
                        transitionID
                    )
                }
                if let priorCursor, let priorOrdinal {
                    guard bound.cursor > priorCursor
                            || (
                                bound.cursor == priorCursor
                                    && transitionID.ordinal > priorOrdinal
                            ) else {
                        throw VerifiedPatchValidationError
                            .transitionChainMismatch(operation.sourcePath)
                    }
                }
                if index == 0 {
                    guard bound.transition.sourcePath
                            == operation.sourcePath,
                          bound.transition.destinationPath
                            == operation.destinationPath,
                          bound.transition.before
                            == operation.before?.stateIdentity else {
                        throw VerifiedPatchValidationError
                            .invalidOperation(transitionID)
                    }
                } else {
                    guard bound.transition.sourcePath
                            == operation.sourcePath,
                          bound.transition.destinationPath == nil,
                          bound.transition.before == priorAfter else {
                        throw VerifiedPatchValidationError
                            .transitionChainMismatch(operation.sourcePath)
                    }
                }
                priorAfter = bound.transition.after
                priorCursor = bound.cursor
                priorOrdinal = transitionID.ordinal
            }
            guard priorAfter == operation.after?.stateIdentity,
                  try operationKind(
                    destinationPath: operation.destinationPath,
                    before: operation.before,
                    after: operation.after,
                    transitionID: operation.id.transitionIDs[0]
                  ) == operation.kind else {
                throw VerifiedPatchValidationError.invalidOperation(
                    operation.id.transitionIDs[0]
                )
            }
            for path in operation.touchedPaths {
                guard VerifiedPatchIngressCoordinator
                    .isAllowedRelativePath(path) else {
                    throw VerifiedPatchValidationError.invalidPath(path)
                }
                let key = VerifiedPatchIngressCoordinator
                    .conservativePathKey(path)
                guard pathKeys.insert(key).inserted else {
                    throw VerifiedPatchValidationError.aliasedPath(path)
                }
            }
            for state in [operation.before, operation.after]
                .compactMap({ $0 }) {
                guard state.kind == .regularFile,
                      state.posixMode <= 0o7777,
                      state.identity == ContentIdentity(
                        content: state.content
                      ),
                      state.content.count
                        <= VerifiedPatchLimits.maximumFileByteCount,
                      let updated = checkedAdd(
                        capturedBytes,
                        state.content.count
                      ),
                      updated
                        <= VerifiedPatchLimits.maximumCapturedByteCount else {
                    throw VerifiedPatchValidationError
                        .aggregateContentTooLarge
                }
                capturedBytes = updated
            }
            switch operation.strategy {
            case .exactState:
                break
            case .text(let hunks, let cells):
                guard operation.kind == .modify,
                      let before = operation.before,
                      let after = operation.after,
                      let recomputed = VerifiedTextPatch.plan(
                        before: before.content,
                        after: after.content
                      ),
                      recomputed.hunks == hunks,
                      recomputed.lcsCellCount == cells,
                      let newHunks = checkedAdd(hunkCount, hunks.count),
                      newHunks
                        <= VerifiedPatchLimits.maximumHunkCount,
                      let newCells = checkedAdd(lcsCells, cells),
                      newCells <= VerifiedPatchLimits
                        .maximumAggregateLCSCellCount else {
                    throw VerifiedPatchValidationError.lcsBudgetExceeded
                }
                hunkCount = newHunks
                lcsCells = newCells
            }
        }
        guard transitionIDs.count == transitions.count else {
            let unused = transitions.keys.first {
                !transitionIDs.contains($0)
            }
            if let unused {
                throw VerifiedPatchValidationError.unusedTransition(unused)
            }
            throw VerifiedPatchValidationError.invalidReceipt
        }
        guard patch.operations == patch.operations.sorted(
            by: operationOrder
        ) else {
            throw VerifiedPatchValidationError.invalidOperation(nil)
        }
    }

    private static func validateSnapshot(
        _ snapshot: VerifiedPatchWorkspaceSnapshot
    ) throws {
        guard snapshot.files.count
                <= VerifiedPatchLimits.maximumSnapshotFileCount else {
            throw VerifiedPatchValidationError.invalidSnapshot
        }
        var byteCount = 0
        var pathByteCount = 0
        var keys: Set<String> = []
        for (path, state) in snapshot.files {
            guard VerifiedPatchIngressCoordinator
                    .isAllowedRelativePath(path),
                  state.posixMode <= 0o7777,
                  state.content.count
                    <= VerifiedPatchLimits.maximumFileByteCount,
                  state.identity == ContentIdentity(
                    content: state.content
                  ),
                  let newBytes = checkedAdd(
                    byteCount,
                    state.content.count
                  ),
                  newBytes
                    <= VerifiedPatchLimits.maximumSnapshotByteCount,
                  let newPathBytes = checkedAdd(
                    pathByteCount,
                    path.utf8.count
                  ),
                  newPathBytes <= VerifiedPatchLimits
                    .maximumSnapshotPathByteCount else {
                throw VerifiedPatchValidationError.invalidSnapshot
            }
            let key = VerifiedPatchIngressCoordinator
                .conservativePathKey(path)
            guard keys.insert(key).inserted else {
                throw VerifiedPatchValidationError.aliasedPath(path)
            }
            byteCount = newBytes
            pathByteCount = newPathBytes
        }
    }

    private static func validatePrepared(
        _ prepared: PreparedInverse
    ) throws {
        try revalidate(prepared.patch)
        let workspace = prepared.patch.receipt.workspace
        let expectedCoordinator = VerifiedPatchCoordinatorExpectations(
            privateWorkspaceID: workspace.privateWorkspaceID,
            canonicalRootPath: workspace.canonicalRootPath,
            rootDevice: workspace.rootDevice,
            rootInode: workspace.rootInode,
            capturedHeadOID: workspace.capturedHeadOID,
            capturedIndexSHA256: workspace.capturedIndexSHA256,
            durableEvents: prepared.patch.receipt.durableEventIdentities,
            mediatedWriterReceipts: prepared.patch.receipt
                .mediatedWriterReceipts
        )
        guard prepared.patchID != zeroUUID,
              prepared.coordinatorExpectations == expectedCoordinator,
              !prepared.operations.isEmpty,
              prepared.operations.count
                <= VerifiedPatchLimits.maximumOperationCount,
              prepared.previews == prepared.operations.map(\.preview),
              VerifiedPatchIngressCoordinator.isValidWorkspace(
                VerifiedPatchWorkspaceIdentity(
                    privateWorkspaceID: prepared
                        .coordinatorExpectations.privateWorkspaceID,
                    canonicalRootPath: prepared
                        .coordinatorExpectations.canonicalRootPath,
                    rootDevice: prepared
                        .coordinatorExpectations.rootDevice,
                    rootInode: prepared
                        .coordinatorExpectations.rootInode,
                    capturedHeadOID: prepared
                        .coordinatorExpectations.capturedHeadOID,
                    capturedIndexSHA256: prepared
                        .coordinatorExpectations.capturedIndexSHA256
                )
              ),
              validateDurableExpectations(
                prepared.coordinatorExpectations.durableEvents,
                workspace: prepared.coordinatorExpectations
              ) else {
            throw VerifiedPatchValidationError.invalidOperation(nil)
        }
        var operationIDs: Set<VerifiedPatchOperationID> = []
        var pathKeys: Set<String> = []
        var expectationFiles: [String: VerifiedPatchFileState] = [:]
        for operation in prepared.operations {
            guard operation.operationID.patchID == prepared.patchID,
                  operationIDs.insert(operation.operationID).inserted,
                  operation.kind != .rename else {
                throw VerifiedPatchValidationError.invalidOperation(nil)
            }
            for expectation in operation.expectations {
                try validatePreparedPath(
                    expectation.path,
                    state: expectation.state,
                    keys: &pathKeys
                )
                if let state = expectation.state {
                    expectationFiles[expectation.path] = state
                }
            }
            for result in operation.results {
                guard VerifiedPatchIngressCoordinator
                    .isAllowedRelativePath(result.path) else {
                    throw VerifiedPatchValidationError
                        .invalidPath(result.path)
                }
                if let state = result.state {
                    try validatePreparedState(state)
                }
            }
        }
        let regenerated = prepareCheckedInverse(
            prepared.patch,
            currentSnapshot: VerifiedPatchWorkspaceSnapshot(
                files: expectationFiles
            )
        )
        guard case .success(let expected) = regenerated,
              expected == prepared else {
            throw VerifiedPatchValidationError.invalidOperation(nil)
        }
    }

    private static func validateDurableExpectations(
        _ events: [VerifiedPatchDurableEventIdentity],
        workspace: VerifiedPatchCoordinatorExpectations
    ) -> Bool {
        guard !events.isEmpty,
              events.count <= VerifiedPatchLimits.maximumEventCount,
              let first = events.first else {
            return false
        }
        var envelopeIDs: Set<UUID> = []
        var journalSequences: Set<UInt64> = []
        for (index, event) in events.enumerated() {
            guard event.projectID == first.projectID,
                  event.canonicalWorktreePath
                    == workspace.canonicalRootPath,
                  event.sessionID == first.sessionID,
                  event.terminalID == first.terminalID,
                  event.processGeneration == first.processGeneration,
                  event.eventCursor > 0,
                  event.envelopeID != zeroUUID,
                  event.journalSequence > 0,
                  envelopeIDs.insert(event.envelopeID).inserted,
                  journalSequences.insert(
                    event.journalSequence
                  ).inserted else {
                return false
            }
            guard index > 0 else { continue }
            let previous = events[index - 1]
            guard previous.eventCursor < UInt64.max,
                  event.eventCursor == previous.eventCursor + 1,
                  event.journalSequence > previous.journalSequence else {
                return false
            }
        }
        return true
    }

    private static func validatePreparedPath(
        _ path: String,
        state: VerifiedPatchFileState?,
        keys: inout Set<String>
    ) throws {
        guard VerifiedPatchIngressCoordinator.isAllowedRelativePath(path),
              keys.insert(
                VerifiedPatchIngressCoordinator.conservativePathKey(path)
              ).inserted else {
            throw VerifiedPatchValidationError.aliasedPath(path)
        }
        if let state {
            try validatePreparedState(state)
        }
    }

    private static func validatePreparedState(
        _ state: VerifiedPatchFileState
    ) throws {
        guard state.kind == .regularFile,
              state.posixMode <= 0o7777,
              state.content.count
                <= VerifiedPatchLimits.maximumFileByteCount,
              state.identity == ContentIdentity(content: state.content) else {
            throw VerifiedPatchValidationError.invalidOperation(nil)
        }
    }

    private static func operationKind(
        destinationPath: String?,
        before: VerifiedPatchFileState?,
        after: VerifiedPatchFileState?,
        transitionID: VerifiedPatchTransitionID
    ) throws -> VerifiedPatchOperationKind {
        return switch (destinationPath, before != nil, after != nil) {
        case (nil, true, true): .modify
        case (nil, false, true): .create
        case (nil, true, false): .delete
        case (.some, true, true): .rename
        default:
            throw VerifiedPatchValidationError.invalidOperation(
                transitionID
            )
        }
    }

    private static func preview(
        _ operation: VerifiedPatchOperation,
        expectedCurrent: VerifiedPatchFileState?,
        result: VerifiedPatchFileState?,
        resolvedHunks: [VerifiedPreparedTextHunk]?
    ) -> VerifiedInverseOperationPreview {
        let previewKind: VerifiedInversePreviewKind = switch operation.kind {
        case .modify:
            if case .text = operation.strategy {
                .applyTextHunks
            } else {
                .restoreExactFile
            }
        case .create: .removeCreatedFile
        case .delete: .restoreDeletedFile
        case .rename: .simulateRenamedFile
        }
        let hunkPreviews: [VerifiedInverseHunkPreview]
        switch operation.strategy {
        case .exactState:
            hunkPreviews = []
        case .text(let hunks, _):
            hunkPreviews = hunks.enumerated().map { index, hunk in
                hunkPreview(
                    hunk,
                    resolved: resolvedHunks?[safe: index]
                )
            }
        }
        return VerifiedInverseOperationPreview(
            operationID: operation.id,
            kind: previewKind,
            sourcePath: operation.sourcePath,
            destinationPath: operation.destinationPath,
            expectedCurrent: expectedCurrent?.stateIdentity,
            result: result?.stateIdentity,
            hunks: hunkPreviews
        )
    }

    private static func hunkPreview(
        _ hunk: VerifiedTextPatchHunk,
        resolved: VerifiedPreparedTextHunk?
    ) -> VerifiedInverseHunkPreview {
        var lines: [VerifiedInversePreviewLine] = []
        lines.append(contentsOf: hunk.prefixContext.map {
            VerifiedInversePreviewLine(kind: .context, bytes: $0)
        })
        lines.append(contentsOf: hunk.afterLines.map {
            VerifiedInversePreviewLine(kind: .remove, bytes: $0)
        })
        lines.append(contentsOf: hunk.beforeLines.map {
            VerifiedInversePreviewLine(kind: .add, bytes: $0)
        })
        lines.append(contentsOf: hunk.suffixContext.map {
            VerifiedInversePreviewLine(kind: .context, bytes: $0)
        })
        let currentStart = resolved?.resolvedCurrentRange.lowerBound
        let headerStart = (currentStart ?? hunk.afterStartLine) + 1
        return VerifiedInverseHunkPreview(
            capturedAfterStartLine: hunk.afterStartLine,
            resolvedCurrentStartLine: currentStart,
            header: "@@ -\(headerStart),\(hunk.afterLineCount) "
                + "+\(headerStart),\(hunk.beforeLineCount) @@",
            lines: lines
        )
    }

    private static func expectation(
        _ path: String,
        _ state: VerifiedPatchFileState?
    ) -> VerifiedPreparedPathExpectation {
        VerifiedPreparedPathExpectation(path: path, state: state)
    }

    private static func result(
        _ path: String,
        _ state: VerifiedPatchFileState?
    ) -> VerifiedPreparedPathResult {
        VerifiedPreparedPathResult(path: path, state: state)
    }

    private static func conflict(
        _ operation: VerifiedPatchOperation,
        _ reason: VerifiedPatchConflictReason,
        path: String? = nil
    ) -> VerifiedPatchConflict {
        VerifiedPatchConflict(
            operationID: operation.id,
            path: path ?? operation.sourcePath,
            reason: reason
        )
    }

    private static func operationOrder(
        _ lhs: VerifiedPatchOperation,
        _ rhs: VerifiedPatchOperation
    ) -> Bool {
        if lhs.sourcePath != rhs.sourcePath {
            return lhs.sourcePath < rhs.sourcePath
        }
        let lhsDestination = lhs.destinationPath ?? ""
        let rhsDestination = rhs.destinationPath ?? ""
        if lhsDestination != rhsDestination {
            return lhsDestination < rhsDestination
        }
        return transitionIDOrder(
            lhs.id.transitionIDs[0],
            rhs.id.transitionIDs[0]
        )
    }

    private static func sourceOrder(
        _ lhs: OrderedSource,
        _ rhs: OrderedSource
    ) -> Bool {
        if lhs.cursor != rhs.cursor {
            return lhs.cursor < rhs.cursor
        }
        return lhs.source.transitionID.ordinal
            < rhs.source.transitionID.ordinal
    }

    private static func transitionIDOrder(
        _ lhs: VerifiedPatchTransitionID,
        _ rhs: VerifiedPatchTransitionID
    ) -> Bool {
        if lhs.envelopeID != rhs.envelopeID {
            return lhs.envelopeID.uuidString < rhs.envelopeID.uuidString
        }
        return lhs.ordinal < rhs.ordinal
    }

    private struct BoundTransition {
        let cursor: UInt64
        let transition: VerifiedPatchContentTransition
    }

    private struct OrderedSource {
        let cursor: UInt64
        let source: VerifiedPatchSourceOperation
    }

}

nonisolated private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

nonisolated private func checkedAdd(
    _ lhs: Int,
    _ rhs: Int
) -> Int? {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? nil : result.partialValue
}

nonisolated private let zeroUUID = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
)
