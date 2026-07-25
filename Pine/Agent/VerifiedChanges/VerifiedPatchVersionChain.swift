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
    case journalOrderMismatch(previous: UInt64, actual: UInt64)
    case cursorOverlap
    case cursorGap(expected: UInt64, actual: UInt64)
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
            return .conflicted([VerifiedPatchVersionConflict(
                pathScope: nil,
                patchIDs: [],
                sessionIDs: [],
                reason: .resourceLimitExceeded
            )])
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
        var conflicts: [VerifiedPatchVersionConflict] = []
        detectEnvelopeReplay(orderedPatches, conflicts: &conflicts)
        detectJournalReplay(orderedPatches, conflicts: &conflicts)
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
                if cursorOrderConflicts(orderedNodes) {
                    conflicts.append(makeConflict(
                        pathScope: pathScope,
                        nodes: orderedNodes,
                        reason: .cursorOrderMismatch
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

    private static func makeNodesByPath(
        _ patches: [VerifiedPatchSet]
    ) -> [VerifiedPatchPathScope: [VersionNode]]? {
        var result: [VerifiedPatchPathScope: [VersionNode]] = [:]
        var nodeCount = 0
        for patch in patches {
            for operation in patch.operations {
                let common = (
                    patchID: patch.id,
                    sessionID: patch.receipt.sessionID,
                    stream: StreamIdentity(patch),
                    firstCursor: patch.receipt.firstCursorValue
                )
                if operation.kind == .rename,
                   let destinationPath = operation.destinationPath {
                    guard appendNode(
                        VersionNode(
                            patchID: common.patchID,
                            sessionID: common.sessionID,
                            stream: common.stream,
                            firstCursor: common.firstCursor,
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
                            firstCursor: common.firstCursor,
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
                            firstCursor: common.firstCursor,
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

    private static func cursorOrderConflicts(
        _ nodes: [VersionNode]
    ) -> Bool {
        for index in nodes.indices.dropFirst() {
            let previous = nodes[index - 1]
            let current = nodes[index]
            if previous.stream == current.stream,
               previous.firstCursor >= current.firstCursor {
                return true
            }
        }
        return false
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

    private struct VersionNode {
        let patchID: UUID
        let sessionID: UUID
        let stream: StreamIdentity
        let firstCursor: UInt64
        let before: VerifiedPatchStateIdentity?
        let after: VerifiedPatchStateIdentity?
    }

    private enum ChainFailure: Error {
        case ambiguous
    }
}
