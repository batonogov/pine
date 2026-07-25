//
//  VerifiedPatchVersionChain.swift
//  Pine
//
//  Bounded multi-agent overlap and exact content-chain analysis (#933).
//

import Foundation

nonisolated enum VerifiedPatchVersionConflictReason: Sendable, Equatable {
    case invalidPatch(UUID)
    case duplicatePatchID(UUID)
    case resourceLimitExceeded
    case replayedEnvelope(UUID)
    case journalSequenceCollision(UInt64)
    case writerReceiptReplay(UUID)
    case descriptorTransactionReplay(UUID)
    case descriptorCASSequenceCollision(UInt64)
    case journalOrderMismatch(previous: UInt64, actual: UInt64)
    case descriptorCASOrderMismatch(previous: UInt64, actual: UInt64)
    case cursorOverlap
    case cursorGap(expected: UInt64, actual: UInt64)
    case workspaceIdentityMismatch
    case ambiguousVersionChain
    case cursorOrderMismatch
}

/// Workspace identity plus a conservative normalization/case alias key.
///
/// Equality deliberately ignores display spelling, so `File.swift`,
/// `file.swift`, and canonically equivalent spellings cannot split overlap
/// analysis even if the current volume happens to be case-sensitive.
nonisolated struct VerifiedPatchPathScope: Sendable, Hashable {
    let privateWorkspaceID: UUID
    let rootDevice: UInt64
    let rootInode: UInt64
    let conservativeRelativePath: String
    let displayRelativePath: String

    static func == (
        lhs: VerifiedPatchPathScope,
        rhs: VerifiedPatchPathScope
    ) -> Bool {
        lhs.privateWorkspaceID == rhs.privateWorkspaceID
            && lhs.rootDevice == rhs.rootDevice
            && lhs.rootInode == rhs.rootInode
            && lhs.conservativeRelativePath
                == rhs.conservativeRelativePath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(privateWorkspaceID)
        hasher.combine(rootDevice)
        hasher.combine(rootInode)
        hasher.combine(conservativeRelativePath)
    }
}

nonisolated struct VerifiedPatchVersionConflict: Sendable, Equatable {
    let pathScope: VerifiedPatchPathScope?
    let patchIDs: [UUID]
    let sessionIDs: [UUID]
    let reason: VerifiedPatchVersionConflictReason

    var path: String? { pathScope?.displayRelativePath }
}

nonisolated struct VerifiedPatchVersionChainReport: Sendable, Equatable {
    let orderedPatchIDsByPath: [VerifiedPatchPathScope: [UUID]]
}

nonisolated enum VerifiedPatchVersionChainResult: Sendable, Equatable {
    case valid(VerifiedPatchVersionChainReport)
    case conflicted([VerifiedPatchVersionConflict])
}

nonisolated enum VerifiedPatchVersionChainDetector {
    static func analyze(
        _ patches: [VerifiedPatchSet]
    ) -> VerifiedPatchVersionChainResult {
        guard patches.count
                <= VerifiedPatchLimits.maximumVersionPatchCount else {
            return resourceLimitConflict()
        }
        guard isWithinAnalysisBudget(patches) else {
            return resourceLimitConflict()
        }

        var seenPatchIDs: Set<UUID> = []
        for patch in patches {
            guard seenPatchIDs.insert(patch.id).inserted else {
                return .conflicted([VerifiedPatchVersionConflict(
                    pathScope: nil,
                    patchIDs: [patch.id],
                    sessionIDs: [patch.receipt.sessionID],
                    reason: .duplicatePatchID(patch.id)
                )])
            }
            do {
                try VerifiedPatchEngine.revalidate(patch)
            } catch {
                return .conflicted([VerifiedPatchVersionConflict(
                    pathScope: nil,
                    patchIDs: [patch.id],
                    sessionIDs: [patch.receipt.sessionID],
                    reason: .invalidPatch(patch.id)
                )])
            }
        }

        let orderedPatches = patches.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        if let conflict = workspaceIdentityConflict(orderedPatches) {
            return .conflicted([conflict])
        }
        var conflicts: [VerifiedPatchVersionConflict] = []
        detectEnvelopeReplay(orderedPatches, conflicts: &conflicts)
        detectJournalReplay(orderedPatches, conflicts: &conflicts)
        detectMediatedWriterReplay(orderedPatches, conflicts: &conflicts)
        detectCursorConflicts(orderedPatches, conflicts: &conflicts)

        guard let nodesByPath = makeNodesByPath(orderedPatches) else {
            conflicts.append(VerifiedPatchVersionConflict(
                pathScope: nil,
                patchIDs: [],
                sessionIDs: [],
                reason: .resourceLimitExceeded
            ))
            return .conflicted(conflicts)
        }
        var chains: [VerifiedPatchPathScope: [UUID]] = [:]
        for pathScope in nodesByPath.keys.sorted(by: pathScopeOrder) {
            guard let nodes = nodesByPath[pathScope],
                  nodes.count > 1 else {
                continue
            }
            switch linearChain(nodes) {
            case .success(let orderedNodes):
                if let reason = evidenceOrderConflict(orderedNodes) {
                    conflicts.append(makeConflict(
                        pathScope: pathScope,
                        nodes: orderedNodes,
                        reason: reason
                    ))
                } else {
                    chains[pathScope] = orderedNodes.map(\.patchID)
                }
            case .failure:
                conflicts.append(makeConflict(
                    pathScope: pathScope,
                    nodes: nodes,
                    reason: .ambiguousVersionChain
                ))
            }
        }

        if conflicts.isEmpty {
            return .valid(VerifiedPatchVersionChainReport(
                orderedPatchIDsByPath: chains
            ))
        }
        return .conflicted(conflicts)
    }

    /// Rejects aggregate work before any patch can trigger LCS recomputation.
    ///
    /// All fields are untrusted at this boundary. Declared costs are only a
    /// cheap upper gate; `VerifiedPatchEngine.revalidate` still recomputes and
    /// verifies every accepted value after the whole batch fits this budget.
    private static func isWithinAnalysisBudget(
        _ patches: [VerifiedPatchSet]
    ) -> Bool {
        var operationCount = 0
        var nodeCount = 0
        var eventCount = 0
        var transitionCount = 0
        var transitionReferenceCount = 0
        var capturedBytes = 0
        var pathBytes = 0
        var eventMetadataBytes = 0
        var lcsCells = 0
        var hunkCount = 0

        for patch in patches {
            guard accumulate(
                patch.operations.count,
                into: &operationCount,
                maximum: VerifiedPatchLimits.maximumVersionOperationCount
            ),
            accumulate(
                patch.receipt.events.count,
                into: &eventCount,
                maximum: VerifiedPatchLimits.maximumVersionEventCount
            ),
            consumePath(
                patch.receipt.workspace.canonicalRootPath,
                total: &pathBytes
            ) else {
                return false
            }

            for operation in patch.operations {
                let addedNodes = operation.kind == .rename ? 2 : 1
                guard accumulate(
                    addedNodes,
                    into: &nodeCount,
                    maximum: VerifiedPatchLimits.maximumVersionNodeCount
                ),
                accumulate(
                    operation.id.transitionIDs.count,
                    into: &transitionReferenceCount,
                    maximum: VerifiedPatchLimits
                        .maximumVersionTransitionCount
                ),
                consumePath(operation.sourcePath, total: &pathBytes)
                else {
                    return false
                }
                if let destinationPath = operation.destinationPath,
                   !consumePath(destinationPath, total: &pathBytes) {
                    return false
                }
                for state in [operation.before, operation.after]
                    .compactMap({ $0 }) {
                    guard accumulate(
                        state.content.count,
                        into: &capturedBytes,
                        maximum: VerifiedPatchLimits
                            .maximumVersionCapturedByteCount
                    ) else {
                        return false
                    }
                }
                if case .text(let hunks, let declaredCells)
                        = operation.strategy {
                    guard declaredCells >= 0,
                          accumulate(
                            declaredCells,
                            into: &lcsCells,
                            maximum: VerifiedPatchLimits
                                .maximumVersionLCSCellCount
                          ),
                          accumulate(
                            hunks.count,
                            into: &hunkCount,
                            maximum: VerifiedPatchLimits
                                .maximumVersionHunkCount
                          ) else {
                        return false
                    }
                }
            }

            for event in patch.receipt.events {
                guard let metadataCount = eventMetadataByteCount(
                    event.envelope
                ),
                accumulate(
                    metadataCount,
                    into: &eventMetadataBytes,
                    maximum: VerifiedPatchLimits
                        .maximumVersionEventMetadataByteCount
                ),
                accumulate(
                    event.transitions.count,
                    into: &transitionCount,
                    maximum: VerifiedPatchLimits
                        .maximumVersionTransitionCount
                ),
                consumePath(
                    event.durableIdentity.canonicalWorktreePath,
                    total: &pathBytes
                ),
                consumeTransitionPaths(
                    event.transitions,
                    total: &pathBytes
                ) else {
                    return false
                }
                if let writer = event.mediatedWriterReceipt {
                    guard writer.transitions.count
                            == event.transitions.count,
                          consumePath(
                            writer.workspace.canonicalRootPath,
                            total: &pathBytes
                          ),
                          consumePath(
                            writer.auditEvent.canonicalWorktreePath,
                            total: &pathBytes
                          ),
                          consumeTransitionPaths(
                            writer.transitions,
                            total: &pathBytes
                          ) else {
                        return false
                    }
                }
            }
        }
        return true
    }

    private static func workspaceIdentityConflict(
        _ patches: [VerifiedPatchSet]
    ) -> VerifiedPatchVersionConflict? {
        var privateOwners: [UUID: WorkspaceOwner] = [:]
        var physicalOwners: [PhysicalRoot: WorkspaceOwner] = [:]
        for patch in patches {
            let workspace = patch.receipt.workspace
            let physical = PhysicalRoot(
                device: workspace.rootDevice,
                inode: workspace.rootInode
            )
            if let existing = privateOwners[workspace.privateWorkspaceID],
               existing.physicalRoot != physical {
                return workspaceConflict(existing.patch, patch)
            }
            if let existing = physicalOwners[physical],
               existing.privateWorkspaceID
                    != workspace.privateWorkspaceID {
                return workspaceConflict(existing.patch, patch)
            }
            let owner = WorkspaceOwner(
                privateWorkspaceID: workspace.privateWorkspaceID,
                physicalRoot: physical,
                patch: patch
            )
            privateOwners[workspace.privateWorkspaceID] = owner
            physicalOwners[physical] = owner
        }
        return nil
    }

    private static func workspaceConflict(
        _ lhs: VerifiedPatchSet,
        _ rhs: VerifiedPatchSet
    ) -> VerifiedPatchVersionConflict {
        VerifiedPatchVersionConflict(
            pathScope: nil,
            patchIDs: sortedUUIDs([lhs.id, rhs.id]),
            sessionIDs: sortedUUIDs([
                lhs.receipt.sessionID,
                rhs.receipt.sessionID
            ]),
            reason: .workspaceIdentityMismatch
        )
    }

    private static func resourceLimitConflict()
        -> VerifiedPatchVersionChainResult {
        .conflicted([VerifiedPatchVersionConflict(
            pathScope: nil,
            patchIDs: [],
            sessionIDs: [],
            reason: .resourceLimitExceeded
        )])
    }

    private static func accumulate(
        _ value: Int,
        into total: inout Int,
        maximum: Int
    ) -> Bool {
        guard value >= 0 else { return false }
        let result = total.addingReportingOverflow(value)
        guard !result.overflow,
              result.partialValue <= maximum else {
            return false
        }
        total = result.partialValue
        return true
    }

    private static func consumePath(
        _ path: String,
        total: inout Int
    ) -> Bool {
        accumulate(
            path.utf8.count,
            into: &total,
            maximum: VerifiedPatchLimits.maximumVersionPathByteCount
        )
    }

    private static func consumeTransitionPaths(
        _ transitions: [VerifiedPatchContentTransition],
        total: inout Int
    ) -> Bool {
        for transition in transitions {
            guard consumePath(transition.sourcePath, total: &total) else {
                return false
            }
            if let destinationPath = transition.destinationPath,
               !consumePath(destinationPath, total: &total) {
                return false
            }
        }
        return true
    }

    private static func eventMetadataByteCount(
        _ envelope: AgentEventEnvelope
    ) -> Int? {
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
        var result = 0
        for string in strings {
            let updated = result.addingReportingOverflow(
                string.utf8.count
            )
            guard !updated.overflow else { return nil }
            result = updated.partialValue
        }
        return result
    }

    private static func detectEnvelopeReplay(
        _ patches: [VerifiedPatchSet],
        conflicts: inout [VerifiedPatchVersionConflict]
    ) {
        var owners: [UUID: VerifiedPatchSet] = [:]
        for patch in patches {
            for envelopeID in patch.receipt.envelopeIDs {
                if let existing = owners[envelopeID] {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: sortedUUIDs([existing.id, patch.id]),
                        sessionIDs: sortedUUIDs([
                            existing.receipt.sessionID,
                            patch.receipt.sessionID
                        ]),
                        reason: .replayedEnvelope(envelopeID)
                    ))
                } else {
                    owners[envelopeID] = patch
                }
            }
        }
    }

    private static func detectCursorConflicts(
        _ patches: [VerifiedPatchSet],
        conflicts: inout [VerifiedPatchVersionConflict]
    ) {
        let groups = Dictionary(grouping: patches, by: StreamIdentity.init)
        for stream in groups.keys.sorted(by: streamOrder) {
            guard let group = groups[stream],
                  group.count > 1 else {
                continue
            }
            let ordered = group.sorted {
                if $0.receipt.firstCursorValue
                    != $1.receipt.firstCursorValue {
                    return $0.receipt.firstCursorValue
                        < $1.receipt.firstCursorValue
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            for index in ordered.indices.dropFirst() {
                let previous = ordered[index - 1]
                let current = ordered[index]
                if current.receipt.firstCursorValue
                    <= previous.receipt.lastCursorValue {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: [previous.id, current.id],
                        sessionIDs: sortedUUIDs([
                            previous.receipt.sessionID,
                            current.receipt.sessionID
                        ]),
                        reason: .cursorOverlap
                    ))
                    continue
                }
                if current.receipt.firstJournalSequence
                    <= previous.receipt.lastJournalSequence {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: [previous.id, current.id],
                        sessionIDs: [current.receipt.sessionID],
                        reason: .journalOrderMismatch(
                            previous: previous.receipt.lastJournalSequence,
                            actual: current.receipt.firstJournalSequence
                        )
                    ))
                    continue
                }
                guard previous.receipt.lastCursorValue < UInt64.max else {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: [previous.id, current.id],
                        sessionIDs: [current.receipt.sessionID],
                        reason: .cursorGap(
                            expected: UInt64.max,
                            actual: current.receipt.firstCursorValue
                        )
                    ))
                    continue
                }
                let expected = previous.receipt.lastCursorValue + 1
                if current.receipt.firstCursorValue != expected {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: [previous.id, current.id],
                        sessionIDs: [current.receipt.sessionID],
                        reason: .cursorGap(
                            expected: expected,
                            actual: current.receipt.firstCursorValue
                        )
                    ))
                }
            }
        }
    }

    private static func detectJournalReplay(
        _ patches: [VerifiedPatchSet],
        conflicts: inout [VerifiedPatchVersionConflict]
    ) {
        var owners: [JournalSequenceScope: VerifiedPatchSet] = [:]
        for patch in patches {
            let workspace = patch.receipt.workspace
            for event in patch.receipt.durableEventIdentities {
                let scope = JournalSequenceScope(
                    privateWorkspaceID: workspace.privateWorkspaceID,
                    rootDevice: workspace.rootDevice,
                    rootInode: workspace.rootInode,
                    journalSequence: event.journalSequence
                )
                if let existing = owners[scope] {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: sortedUUIDs([existing.id, patch.id]),
                        sessionIDs: sortedUUIDs([
                            existing.receipt.sessionID,
                            patch.receipt.sessionID
                        ]),
                        reason: .journalSequenceCollision(
                            event.journalSequence
                        )
                    ))
                } else {
                    owners[scope] = patch
                }
            }
        }
    }

    private static func detectMediatedWriterReplay(
        _ patches: [VerifiedPatchSet],
        conflicts: inout [VerifiedPatchVersionConflict]
    ) {
        var receiptOwners: [WorkspaceUUIDScope: VerifiedPatchSet] = [:]
        var transactionOwners: [WorkspaceUUIDScope: VerifiedPatchSet] = [:]
        var sequenceOwners: [WorkspaceSequenceScope: VerifiedPatchSet] = [:]

        for patch in patches {
            let workspace = patch.receipt.workspace
            for receipt in patch.receipt.mediatedWriterReceipts {
                let receiptScope = WorkspaceUUIDScope(
                    privateWorkspaceID: workspace.privateWorkspaceID,
                    rootDevice: workspace.rootDevice,
                    rootInode: workspace.rootInode,
                    value: receipt.receiptID
                )
                if let existing = receiptOwners[receiptScope] {
                    conflicts.append(replayConflict(
                        existing: existing,
                        current: patch,
                        reason: .writerReceiptReplay(receipt.receiptID)
                    ))
                } else {
                    receiptOwners[receiptScope] = patch
                }

                let transactionScope = WorkspaceUUIDScope(
                    privateWorkspaceID: workspace.privateWorkspaceID,
                    rootDevice: workspace.rootDevice,
                    rootInode: workspace.rootInode,
                    value: receipt.descriptorTransactionID
                )
                if let existing = transactionOwners[transactionScope] {
                    conflicts.append(replayConflict(
                        existing: existing,
                        current: patch,
                        reason: .descriptorTransactionReplay(
                            receipt.descriptorTransactionID
                        )
                    ))
                } else {
                    transactionOwners[transactionScope] = patch
                }

                let sequenceScope = WorkspaceSequenceScope(
                    privateWorkspaceID: workspace.privateWorkspaceID,
                    rootDevice: workspace.rootDevice,
                    rootInode: workspace.rootInode,
                    value: receipt.descriptorCASSequence
                )
                if let existing = sequenceOwners[sequenceScope] {
                    conflicts.append(replayConflict(
                        existing: existing,
                        current: patch,
                        reason: .descriptorCASSequenceCollision(
                            receipt.descriptorCASSequence
                        )
                    ))
                } else {
                    sequenceOwners[sequenceScope] = patch
                }
            }
        }
    }

    private static func replayConflict(
        existing: VerifiedPatchSet,
        current: VerifiedPatchSet,
        reason: VerifiedPatchVersionConflictReason
    ) -> VerifiedPatchVersionConflict {
        VerifiedPatchVersionConflict(
            pathScope: nil,
            patchIDs: sortedUUIDs([existing.id, current.id]),
            sessionIDs: sortedUUIDs([
                existing.receipt.sessionID,
                current.receipt.sessionID
            ]),
            reason: reason
        )
    }

    private static func makeNodesByPath(
        _ patches: [VerifiedPatchSet]
    ) -> [VerifiedPatchPathScope: [VersionNode]]? {
        var result: [VerifiedPatchPathScope: [VersionNode]] = [:]
        var nodeCount = 0
        for patch in patches {
            guard let evidenceByTransition = transitionEvidence(in: patch)
            else {
                return nil
            }
            for operation in patch.operations {
                guard let evidence = evidenceRange(
                    for: operation.id.transitionIDs,
                    evidence: evidenceByTransition
                ) else {
                    return nil
                }
                let common = (
                    patchID: patch.id,
                    sessionID: patch.receipt.sessionID,
                    stream: StreamIdentity(patch),
                    evidence: evidence
                )
                if operation.kind == .rename,
                   let destinationPath = operation.destinationPath {
                    guard appendNode(
                        VersionNode(
                            patchID: common.patchID,
                            sessionID: common.sessionID,
                            stream: common.stream,
                            evidence: common.evidence,
                            before: operation.before?.stateIdentity,
                            after: nil
                        ),
                        scope: pathScope(
                            patch,
                            relativePath: operation.sourcePath
                        ),
                        result: &result,
                        count: &nodeCount
                    ),
                    appendNode(
                        VersionNode(
                            patchID: common.patchID,
                            sessionID: common.sessionID,
                            stream: common.stream,
                            evidence: common.evidence,
                            before: nil,
                            after: operation.after?.stateIdentity
                        ),
                        scope: pathScope(
                            patch,
                            relativePath: destinationPath
                        ),
                        result: &result,
                        count: &nodeCount
                    ) else {
                        return nil
                    }
                } else {
                    guard appendNode(
                        VersionNode(
                            patchID: common.patchID,
                            sessionID: common.sessionID,
                            stream: common.stream,
                            evidence: common.evidence,
                            before: operation.before?.stateIdentity,
                            after: operation.after?.stateIdentity
                        ),
                        scope: pathScope(
                            patch,
                            relativePath: operation.sourcePath
                        ),
                        result: &result,
                        count: &nodeCount
                    ) else {
                        return nil
                    }
                }
            }
        }
        return result
    }

    private static func transitionEvidence(
        in patch: VerifiedPatchSet
    ) -> [VerifiedPatchTransitionID: TransitionEvidence]? {
        var result: [VerifiedPatchTransitionID: TransitionEvidence] = [:]
        for event in patch.receipt.events {
            guard event.transitions.isEmpty
                    || event.mediatedWriterReceipt != nil else {
                return nil
            }
            for ordinal in event.transitions.indices {
                guard let receipt = event.mediatedWriterReceipt else {
                    return nil
                }
                let id = VerifiedPatchTransitionID(
                    envelopeID: event.envelope.id,
                    ordinal: ordinal
                )
                let evidence = TransitionEvidence(
                    cursor: event.envelope.cursorValue,
                    journalSequence: event.durableIdentity.journalSequence,
                    descriptorCASSequence: receipt.descriptorCASSequence
                )
                guard result.updateValue(evidence, forKey: id) == nil else {
                    return nil
                }
            }
        }
        return result
    }

    private static func evidenceRange(
        for transitionIDs: [VerifiedPatchTransitionID],
        evidence: [VerifiedPatchTransitionID: TransitionEvidence]
    ) -> TransitionEvidenceRange? {
        guard let firstID = transitionIDs.first,
              let first = evidence[firstID] else {
            return nil
        }
        var result = TransitionEvidenceRange(
            firstCursor: first.cursor,
            lastCursor: first.cursor,
            firstJournalSequence: first.journalSequence,
            lastJournalSequence: first.journalSequence,
            firstDescriptorCASSequence: first.descriptorCASSequence,
            lastDescriptorCASSequence: first.descriptorCASSequence
        )
        for id in transitionIDs.dropFirst() {
            guard let value = evidence[id] else { return nil }
            result.firstCursor = min(result.firstCursor, value.cursor)
            result.lastCursor = max(result.lastCursor, value.cursor)
            result.firstJournalSequence = min(
                result.firstJournalSequence,
                value.journalSequence
            )
            result.lastJournalSequence = max(
                result.lastJournalSequence,
                value.journalSequence
            )
            result.firstDescriptorCASSequence = min(
                result.firstDescriptorCASSequence,
                value.descriptorCASSequence
            )
            result.lastDescriptorCASSequence = max(
                result.lastDescriptorCASSequence,
                value.descriptorCASSequence
            )
        }
        return result
    }

    private static func appendNode(
        _ node: VersionNode,
        scope: VerifiedPatchPathScope,
        result: inout [VerifiedPatchPathScope: [VersionNode]],
        count: inout Int
    ) -> Bool {
        let updated = count.addingReportingOverflow(1)
        guard !updated.overflow,
              updated.partialValue
                <= VerifiedPatchLimits.maximumVersionNodeCount else {
            return false
        }
        count = updated.partialValue
        result[scope, default: []].append(node)
        return true
    }

    private static func linearChain(
        _ nodes: [VersionNode]
    ) -> Result<[VersionNode], ChainFailure> {
        var predecessors: [Int: [Int]] = [:]
        var successors: [Int: [Int]] = [:]
        for lhsIndex in nodes.indices {
            guard let after = nodes[lhsIndex].after else { continue }
            for rhsIndex in nodes.indices where lhsIndex != rhsIndex {
                if nodes[rhsIndex].before == after {
                    successors[lhsIndex, default: []].append(rhsIndex)
                    predecessors[rhsIndex, default: []].append(lhsIndex)
                }
            }
        }
        guard successors.values.allSatisfy({ $0.count <= 1 }),
              predecessors.values.allSatisfy({ $0.count <= 1 }) else {
            return .failure(.ambiguous)
        }
        let roots = nodes.indices.filter {
            predecessors[$0, default: []].isEmpty
        }
        guard roots.count == 1,
              let root = roots.first else {
            return .failure(.ambiguous)
        }

        var result: [VersionNode] = []
        var visited: Set<Int> = []
        var current: Int? = root
        while let index = current {
            guard visited.insert(index).inserted else {
                return .failure(.ambiguous)
            }
            result.append(nodes[index])
            current = successors[index, default: []].first
        }
        guard result.count == nodes.count else {
            return .failure(.ambiguous)
        }
        return .success(result)
    }

    private static func evidenceOrderConflict(
        _ nodes: [VersionNode]
    ) -> VerifiedPatchVersionConflictReason? {
        var lastCursorByStream: [StreamIdentity: UInt64] = [:]
        for node in nodes {
            if let lastCursor = lastCursorByStream[node.stream],
               node.evidence.firstCursor <= lastCursor {
                return .cursorOrderMismatch
            }
            lastCursorByStream[node.stream] = node.evidence.lastCursor
        }
        for index in nodes.indices.dropFirst() {
            let previous = nodes[index - 1].evidence
            let current = nodes[index].evidence
            if current.firstJournalSequence
                <= previous.lastJournalSequence {
                return .journalOrderMismatch(
                    previous: previous.lastJournalSequence,
                    actual: current.firstJournalSequence
                )
            }
            if current.firstDescriptorCASSequence
                <= previous.lastDescriptorCASSequence {
                return .descriptorCASOrderMismatch(
                    previous: previous.lastDescriptorCASSequence,
                    actual: current.firstDescriptorCASSequence
                )
            }
        }
        return nil
    }

    private static func makeConflict(
        pathScope: VerifiedPatchPathScope,
        nodes: [VersionNode],
        reason: VerifiedPatchVersionConflictReason
    ) -> VerifiedPatchVersionConflict {
        VerifiedPatchVersionConflict(
            pathScope: pathScope,
            patchIDs: sortedUUIDs(nodes.map(\.patchID)),
            sessionIDs: sortedUUIDs(nodes.map(\.sessionID)),
            reason: reason
        )
    }

    private static func sortedUUIDs(_ values: [UUID]) -> [UUID] {
        Array(Set(values)).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    private static func pathScope(
        _ patch: VerifiedPatchSet,
        relativePath: String
    ) -> VerifiedPatchPathScope {
        let workspace = patch.receipt.workspace
        return VerifiedPatchPathScope(
            privateWorkspaceID: workspace.privateWorkspaceID,
            rootDevice: workspace.rootDevice,
            rootInode: workspace.rootInode,
            conservativeRelativePath: VerifiedPatchIngressCoordinator
                .conservativePathKey(relativePath),
            displayRelativePath: relativePath
        )
    }

    private static func pathScopeOrder(
        _ lhs: VerifiedPatchPathScope,
        _ rhs: VerifiedPatchPathScope
    ) -> Bool {
        if lhs.privateWorkspaceID != rhs.privateWorkspaceID {
            return lhs.privateWorkspaceID.uuidString
                < rhs.privateWorkspaceID.uuidString
        }
        if lhs.rootDevice != rhs.rootDevice {
            return lhs.rootDevice < rhs.rootDevice
        }
        if lhs.rootInode != rhs.rootInode {
            return lhs.rootInode < rhs.rootInode
        }
        return lhs.conservativeRelativePath
            < rhs.conservativeRelativePath
    }

    private static func streamOrder(
        _ lhs: StreamIdentity,
        _ rhs: StreamIdentity
    ) -> Bool {
        if lhs.privateWorkspaceID != rhs.privateWorkspaceID {
            return lhs.privateWorkspaceID.uuidString
                < rhs.privateWorkspaceID.uuidString
        }
        if lhs.rootDevice != rhs.rootDevice {
            return lhs.rootDevice < rhs.rootDevice
        }
        if lhs.rootInode != rhs.rootInode {
            return lhs.rootInode < rhs.rootInode
        }
        if lhs.projectID != rhs.projectID {
            return lhs.projectID.uuidString < rhs.projectID.uuidString
        }
        if lhs.sessionID != rhs.sessionID {
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
        if lhs.terminalID != rhs.terminalID {
            return lhs.terminalID.uuidString < rhs.terminalID.uuidString
        }
        return lhs.processGeneration < rhs.processGeneration
    }

    private struct StreamIdentity: Hashable {
        let privateWorkspaceID: UUID
        let rootDevice: UInt64
        let rootInode: UInt64
        let projectID: UUID
        let sessionID: UUID
        let terminalID: UUID
        let processGeneration: UInt64

        init(_ patch: VerifiedPatchSet) {
            privateWorkspaceID = patch.receipt.workspace.privateWorkspaceID
            rootDevice = patch.receipt.workspace.rootDevice
            rootInode = patch.receipt.workspace.rootInode
            projectID = patch.receipt.projectID
            sessionID = patch.receipt.sessionID
            terminalID = patch.receipt.process.terminalID
            processGeneration = patch.receipt.process.processGeneration
        }
    }

    private struct JournalSequenceScope: Hashable {
        let privateWorkspaceID: UUID
        let rootDevice: UInt64
        let rootInode: UInt64
        let journalSequence: UInt64
    }

    private struct PhysicalRoot: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct WorkspaceOwner {
        let privateWorkspaceID: UUID
        let physicalRoot: PhysicalRoot
        let patch: VerifiedPatchSet
    }

    private struct TransitionEvidence {
        let cursor: UInt64
        let journalSequence: UInt64
        let descriptorCASSequence: UInt64
    }

    private struct TransitionEvidenceRange {
        var firstCursor: UInt64
        var lastCursor: UInt64
        var firstJournalSequence: UInt64
        var lastJournalSequence: UInt64
        var firstDescriptorCASSequence: UInt64
        var lastDescriptorCASSequence: UInt64
    }

    private struct WorkspaceUUIDScope: Hashable {
        let privateWorkspaceID: UUID
        let rootDevice: UInt64
        let rootInode: UInt64
        let value: UUID
    }

    private struct WorkspaceSequenceScope: Hashable {
        let privateWorkspaceID: UUID
        let rootDevice: UInt64
        let rootInode: UInt64
        let value: UInt64
    }

    private struct VersionNode {
        let patchID: UUID
        let sessionID: UUID
        let stream: StreamIdentity
        let evidence: TransitionEvidenceRange
        let before: VerifiedPatchStateIdentity?
        let after: VerifiedPatchStateIdentity?
    }

    private enum ChainFailure: Error {
        case ambiguous
    }
}
