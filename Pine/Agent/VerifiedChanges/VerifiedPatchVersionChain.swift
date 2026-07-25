//
//  VerifiedPatchVersionChain.swift
//  Pine
//
//  Pure overlap and version-chain analysis for verified agent patches (#933).
//

import Foundation

nonisolated enum VerifiedPatchVersionConflictReason: Sendable, Equatable {
    case replayedEnvelope(UUID)
    case cursorOverlap
    case cursorGap(expected: UInt64, actual: UInt64)
    case ambiguousVersionChain
    case cursorOrderMismatch
}

nonisolated struct VerifiedPatchPathScope: Sendable, Equatable, Hashable {
    let projectID: UUID
    let worktreePath: String
    let relativePath: String
}

nonisolated struct VerifiedPatchVersionConflict: Sendable, Equatable {
    let pathScope: VerifiedPatchPathScope?
    let patchIDs: [UUID]
    let sessionIDs: [UUID]
    let reason: VerifiedPatchVersionConflictReason

    var path: String? { pathScope?.relativePath }
}

nonisolated struct VerifiedPatchVersionChainReport: Sendable, Equatable {
    /// Exact identity order for every scoped path touched more than once.
    let orderedPatchIDsByPath: [VerifiedPatchPathScope: [UUID]]
}

nonisolated enum VerifiedPatchVersionChainResult: Sendable, Equatable {
    case valid(VerifiedPatchVersionChainReport)
    case conflicted([VerifiedPatchVersionConflict])
}

/// Detects cursor replay/gaps and divergent multi-agent file versions.
nonisolated enum VerifiedPatchVersionChainDetector {
    static func analyze(
        _ patches: [VerifiedPatchSet]
    ) -> VerifiedPatchVersionChainResult {
        let orderedPatches = patches.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        var conflicts: [VerifiedPatchVersionConflict] = []
        detectEnvelopeReplay(orderedPatches, conflicts: &conflicts)
        detectCursorConflicts(orderedPatches, conflicts: &conflicts)

        let nodesByPath = makeNodesByPath(orderedPatches)
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
            for envelopeID in patch.binding.envelopeIDs {
                if let existing = owners[envelopeID] {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: sortedUUIDs([existing.id, patch.id]),
                        sessionIDs: sortedUUIDs([
                            existing.binding.sessionID,
                            patch.binding.sessionID
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
                if $0.binding.firstCursorValue
                    != $1.binding.firstCursorValue {
                    return $0.binding.firstCursorValue
                        < $1.binding.firstCursorValue
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            for index in ordered.indices.dropFirst() {
                let previous = ordered[index - 1]
                let current = ordered[index]
                if current.binding.firstCursorValue
                    <= previous.binding.lastCursorValue {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: [previous.id, current.id],
                        sessionIDs: sortedUUIDs([
                            previous.binding.sessionID,
                            current.binding.sessionID
                        ]),
                        reason: .cursorOverlap
                    ))
                    continue
                }
                guard previous.binding.lastCursorValue < UInt64.max else {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: [previous.id, current.id],
                        sessionIDs: [current.binding.sessionID],
                        reason: .cursorGap(
                            expected: UInt64.max,
                            actual: current.binding.firstCursorValue
                        )
                    ))
                    continue
                }
                let expected = previous.binding.lastCursorValue + 1
                if current.binding.firstCursorValue != expected {
                    conflicts.append(VerifiedPatchVersionConflict(
                        pathScope: nil,
                        patchIDs: [previous.id, current.id],
                        sessionIDs: [current.binding.sessionID],
                        reason: .cursorGap(
                            expected: expected,
                            actual: current.binding.firstCursorValue
                        )
                    ))
                }
            }
        }
    }

    private static func makeNodesByPath(
        _ patches: [VerifiedPatchSet]
    ) -> [VerifiedPatchPathScope: [VersionNode]] {
        var result: [VerifiedPatchPathScope: [VersionNode]] = [:]
        for patch in patches {
            for operation in patch.operations {
                let common = (
                    patchID: patch.id,
                    sessionID: patch.binding.sessionID,
                    stream: StreamIdentity(patch),
                    firstCursor: patch.binding.firstCursorValue
                )
                if operation.kind == .rename,
                   let destinationPath = operation.destinationPath {
                    let sourceScope = pathScope(
                        patch,
                        relativePath: operation.sourcePath
                    )
                    let destinationScope = pathScope(
                        patch,
                        relativePath: destinationPath
                    )
                    result[sourceScope, default: []].append(
                        VersionNode(
                            patchID: common.patchID,
                            sessionID: common.sessionID,
                            stream: common.stream,
                            firstCursor: common.firstCursor,
                            before: operation.before?.identity,
                            after: nil
                        )
                    )
                    result[destinationScope, default: []].append(
                        VersionNode(
                            patchID: common.patchID,
                            sessionID: common.sessionID,
                            stream: common.stream,
                            firstCursor: common.firstCursor,
                            before: nil,
                            after: operation.after?.identity
                        )
                    )
                } else {
                    let scope = pathScope(
                        patch,
                        relativePath: operation.sourcePath
                    )
                    result[scope, default: []].append(
                        VersionNode(
                            patchID: common.patchID,
                            sessionID: common.sessionID,
                            stream: common.stream,
                            firstCursor: common.firstCursor,
                            before: operation.before?.identity,
                            after: operation.after?.identity
                        )
                    )
                }
            }
        }
        return result
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

    private static func streamOrder(
        _ lhs: StreamIdentity,
        _ rhs: StreamIdentity
    ) -> Bool {
        if lhs.projectID != rhs.projectID {
            return lhs.projectID.uuidString < rhs.projectID.uuidString
        }
        if lhs.worktreePath != rhs.worktreePath {
            return lhs.worktreePath < rhs.worktreePath
        }
        if lhs.sessionID != rhs.sessionID {
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
        if lhs.terminalID != rhs.terminalID {
            return lhs.terminalID.uuidString < rhs.terminalID.uuidString
        }
        return lhs.processGeneration < rhs.processGeneration
    }

    private static func pathScope(
        _ patch: VerifiedPatchSet,
        relativePath: String
    ) -> VerifiedPatchPathScope {
        VerifiedPatchPathScope(
            projectID: patch.binding.projectID,
            worktreePath: patch.binding.worktreePath,
            relativePath: relativePath
        )
    }

    private static func pathScopeOrder(
        _ lhs: VerifiedPatchPathScope,
        _ rhs: VerifiedPatchPathScope
    ) -> Bool {
        if lhs.projectID != rhs.projectID {
            return lhs.projectID.uuidString < rhs.projectID.uuidString
        }
        if lhs.worktreePath != rhs.worktreePath {
            return lhs.worktreePath < rhs.worktreePath
        }
        return lhs.relativePath < rhs.relativePath
    }

    private struct StreamIdentity: Hashable {
        let projectID: UUID
        let worktreePath: String
        let sessionID: UUID
        let terminalID: UUID
        let processGeneration: UInt64

        init(_ patch: VerifiedPatchSet) {
            projectID = patch.binding.projectID
            worktreePath = patch.binding.worktreePath
            sessionID = patch.binding.sessionID
            terminalID = patch.binding.process.terminalID
            processGeneration = patch.binding.process.processGeneration
        }
    }

    private struct VersionNode {
        let patchID: UUID
        let sessionID: UUID
        let stream: StreamIdentity
        let firstCursor: UInt64
        let before: ContentIdentity?
        let after: ContentIdentity?
    }

    private enum ChainFailure: Error {
        case ambiguous
    }
}
