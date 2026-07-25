//
//  VerifiedPatchEngine.swift
//  Pine
//
//  Pure construction, preview, and checked inverse application for #933.
//

import Foundation

/// Deterministic, side-effect-free verified patch engine.
///
/// The engine never reads or writes a working tree. Callers provide captured
/// bytes and an in-memory current snapshot; success returns a new snapshot.
/// Any conflict returns no partially transformed state.
nonisolated enum VerifiedPatchEngine {
    private static let maximumOperationCount = 1_024
    private static let maximumContentByteCount = 16 * 1_024 * 1_024

    static func makePatch(
        id: UUID,
        binding: VerifiedPatchEventBinding,
        operations sourceOperations: [VerifiedPatchSourceOperation]
    ) throws -> VerifiedPatchSet {
        guard id != zeroUUID else {
            throw VerifiedPatchValidationError.invalidPatchID
        }
        guard !sourceOperations.isEmpty,
              sourceOperations.count <= maximumOperationCount else {
            throw VerifiedPatchValidationError.noOperations
        }

        var boundTransitions: [BoundTransition: Int] = [:]
        for event in binding.events {
            for transition in event.transitions {
                let key = BoundTransition(
                    envelopeID: event.envelopeID,
                    transition: transition
                )
                boundTransitions[key, default: 0] += 1
                guard boundTransitions[key] == 1 else {
                    throw VerifiedPatchValidationError
                        .duplicateBoundTransition
                }
            }
        }

        var operations: [VerifiedPatchOperation] = []
        var touchedPaths: Set<String> = []
        for source in sourceOperations {
            let operation = try makeOperation(source)
            for path in operation.touchedPaths {
                guard touchedPaths.insert(path).inserted else {
                    throw VerifiedPatchValidationError
                        .duplicateTouchedPath(path)
                }
            }

            let bound = BoundTransition(
                envelopeID: operation.eventEnvelopeID,
                transition: operation.transition
            )
            guard let count = boundTransitions[bound],
                  count == 1 else {
                throw VerifiedPatchValidationError.unboundOperation
            }
            boundTransitions[bound] = 0
            operations.append(operation)
        }

        guard boundTransitions.values.allSatisfy({ $0 == 0 }) else {
            throw VerifiedPatchValidationError.unusedBoundTransition
        }
        operations.sort(by: operationOrder)
        return VerifiedPatchSet(
            id: id,
            binding: binding,
            operations: operations
        )
    }

    /// Returns one structured preview for every operation, in deterministic
    /// patch order.
    static func previewInverse(
        _ patch: VerifiedPatchSet
    ) -> [VerifiedInverseOperationPreview] {
        patch.operations.map { operation in
            let previewKind: VerifiedInversePreviewKind
            switch operation.kind {
            case .modify:
                if case .text = operation.strategy {
                    previewKind = .applyTextHunks
                } else {
                    previewKind = .restoreExactBytes
                }
            case .create:
                previewKind = .removeCreatedFile
            case .delete:
                previewKind = .restoreDeletedFile
            case .rename:
                previewKind = .restoreRenamedFile
            }
            let hunkPreviews: [VerifiedInverseHunkPreview]
            switch operation.strategy {
            case .text(let hunks):
                hunkPreviews = hunks.map(preview)
            case .exactState:
                hunkPreviews = []
            }
            return VerifiedInverseOperationPreview(
                operationKey: operation.operationKey,
                eventEnvelopeID: operation.eventEnvelopeID,
                kind: previewKind,
                sourcePath: operation.sourcePath,
                destinationPath: operation.destinationPath,
                expectedCurrentIdentity: operation.after?.identity,
                resultIdentity: operation.before?.identity,
                hunks: hunkPreviews
            )
        }
    }

    static func applyCheckedInverse(
        _ patch: VerifiedPatchSet,
        to snapshot: VerifiedPatchWorkspaceSnapshot
    ) -> VerifiedCheckedInverseResult {
        var transformed = snapshot.files
        for operation in patch.operations {
            if let conflict = apply(operation, files: &transformed) {
                return .conflicted([conflict])
            }
        }
        return .applied(
            snapshot: VerifiedPatchWorkspaceSnapshot(files: transformed),
            previews: previewInverse(patch)
        )
    }

    private static func makeOperation(
        _ source: VerifiedPatchSourceOperation
    ) throws -> VerifiedPatchOperation {
        guard source.eventEnvelopeID != zeroUUID,
              VerifiedPatchEventBinding.isSafeRelativePath(
                source.sourcePath
              ) else {
            throw VerifiedPatchValidationError.invalidOperation
        }
        guard (source.beforeContent?.count ?? 0)
                <= maximumContentByteCount,
              (source.afterContent?.count ?? 0)
                <= maximumContentByteCount else {
            throw VerifiedPatchValidationError.contentTooLarge
        }
        if let destinationPath = source.destinationPath {
            guard VerifiedPatchEventBinding.isSafeRelativePath(
                destinationPath
            ),
            destinationPath != source.sourcePath else {
                throw VerifiedPatchValidationError.invalidPath(
                    destinationPath
                )
            }
        }

        let before = source.beforeContent.map(VerifiedPatchFileState.init)
        let after = source.afterContent.map(VerifiedPatchFileState.init)
        let kind: VerifiedPatchOperationKind
        switch (
            source.destinationPath,
            before != nil,
            after != nil
        ) {
        case (nil, true, true):
            kind = .modify
        case (nil, false, true):
            kind = .create
        case (nil, true, false):
            kind = .delete
        case (.some, true, true):
            kind = .rename
        default:
            throw VerifiedPatchValidationError.invalidOperation
        }
        if kind == .modify,
           before?.identity == after?.identity {
            throw VerifiedPatchValidationError.invalidOperation
        }

        let strategy: VerifiedPatchApplicationStrategy
        if kind == .modify,
           let beforeContent = source.beforeContent,
           let afterContent = source.afterContent,
           VerifiedTextPatch.canDiff(
            before: beforeContent,
            after: afterContent
           ) {
            let hunks = VerifiedTextPatch.makeHunks(
                before: beforeContent,
                after: afterContent
            )
            guard !hunks.isEmpty else {
                throw VerifiedPatchValidationError.invalidOperation
            }
            strategy = .text(hunks: hunks)
        } else {
            strategy = .exactState
        }

        return VerifiedPatchOperation(
            eventEnvelopeID: source.eventEnvelopeID,
            kind: kind,
            sourcePath: source.sourcePath,
            destinationPath: source.destinationPath,
            before: before,
            after: after,
            strategy: strategy
        )
    }

    private static func apply(
        _ operation: VerifiedPatchOperation,
        files: inout [String: Data]
    ) -> VerifiedPatchConflict? {
        switch operation.kind {
        case .modify:
            return applyModify(operation, files: &files)
        case .create:
            guard let after = operation.after else {
                return conflict(operation, .exactStateDiverged)
            }
            guard let current = files[operation.sourcePath] else {
                return conflict(operation, .expectedFileMissing)
            }
            guard current == after.content else {
                return conflict(operation, .exactStateDiverged)
            }
            files.removeValue(forKey: operation.sourcePath)
            return nil
        case .delete:
            guard let before = operation.before else {
                return conflict(operation, .exactStateDiverged)
            }
            guard files[operation.sourcePath] == nil else {
                return conflict(operation, .unexpectedFilePresent)
            }
            files[operation.sourcePath] = before.content
            return nil
        case .rename:
            guard let destinationPath = operation.destinationPath,
                  let before = operation.before,
                  let after = operation.after else {
                return conflict(operation, .exactStateDiverged)
            }
            guard files[operation.sourcePath] == nil else {
                return conflict(operation, .unexpectedFilePresent)
            }
            guard let destinationContent = files[destinationPath] else {
                return conflict(
                    operation,
                    .expectedFileMissing,
                    path: destinationPath
                )
            }
            guard destinationContent == after.content else {
                return conflict(
                    operation,
                    .exactStateDiverged,
                    path: destinationPath
                )
            }
            files.removeValue(forKey: destinationPath)
            files[operation.sourcePath] = before.content
            return nil
        }
    }

    private static func applyModify(
        _ operation: VerifiedPatchOperation,
        files: inout [String: Data]
    ) -> VerifiedPatchConflict? {
        guard let before = operation.before,
              let after = operation.after else {
            return conflict(operation, .exactStateDiverged)
        }
        guard let current = files[operation.sourcePath] else {
            return conflict(operation, .expectedFileMissing)
        }
        if current == after.content {
            files[operation.sourcePath] = before.content
            return nil
        }

        switch operation.strategy {
        case .exactState:
            return conflict(operation, .exactStateDiverged)
        case .text(let hunks):
            switch VerifiedTextPatch.applyInverse(
                hunks: hunks,
                to: current
            ) {
            case .success(let merged):
                files[operation.sourcePath] = merged
                return nil
            case .failure(let reason):
                return conflict(operation, reason)
            }
        }
    }

    private static func preview(
        _ hunk: VerifiedTextPatchHunk
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
        return VerifiedInverseHunkPreview(
            header: "@@ -\(hunk.afterStartLine + 1),\(hunk.afterLineCount) "
                + "+\(hunk.beforeStartLine + 1),\(hunk.beforeLineCount) @@",
            lines: lines
        )
    }

    private static func conflict(
        _ operation: VerifiedPatchOperation,
        _ reason: VerifiedPatchConflictReason,
        path: String? = nil
    ) -> VerifiedPatchConflict {
        VerifiedPatchConflict(
            operationKey: operation.operationKey,
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
        if lhs.destinationPath != rhs.destinationPath {
            return (lhs.destinationPath ?? "") < (rhs.destinationPath ?? "")
        }
        return lhs.eventEnvelopeID.uuidString
            < rhs.eventEnvelopeID.uuidString
    }

    private struct BoundTransition: Hashable {
        let envelopeID: UUID
        let transition: VerifiedPatchContentTransition
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
