//
//  VerifiedPatchModels.swift
//  Pine
//
//  Pure, owner-private patch contracts for verified agent events (#933).
//  These values perform no file-system I/O and grant no mutation authority.
//

import Foundation

/// One exact content transition reported by a verified event.
///
/// The transition contains identities only. Patch bytes are supplied
/// separately to `VerifiedPatchEngine.makePatch` and must match these values.
nonisolated struct VerifiedPatchContentTransition: Sendable, Equatable, Hashable {
    let sourcePath: String
    let destinationPath: String?
    let beforeIdentity: ContentIdentity?
    let afterIdentity: ContentIdentity?

    init(
        sourcePath: String,
        destinationPath: String? = nil,
        beforeIdentity: ContentIdentity?,
        afterIdentity: ContentIdentity?
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.beforeIdentity = beforeIdentity
        self.afterIdentity = afterIdentity
    }
}

/// A verified envelope and the exact file transitions it carries.
nonisolated struct VerifiedPatchEventReference: Sendable, Equatable {
    let envelopeID: UUID
    let cursorValue: UInt64
    let transitions: [VerifiedPatchContentTransition]
}

/// Complete provenance scope for one patch.
///
/// Events are normalized into cursor order and must form one contiguous,
/// replay-free range. A future live bridge creates this value only after the
/// corresponding envelopes have been durably accepted by the provenance
/// store.
nonisolated struct VerifiedPatchEventBinding: Sendable, Equatable {
    let projectID: UUID
    let worktreePath: String
    let sessionID: UUID
    let process: AgentProcessIdentity
    let events: [VerifiedPatchEventReference]

    var envelopeIDs: [UUID] { events.map(\.envelopeID) }
    var firstCursorValue: UInt64 { events[0].cursorValue }
    var lastCursorValue: UInt64 { events[events.count - 1].cursorValue }

    init(
        projectID: UUID,
        worktreePath: String,
        sessionID: UUID,
        process: AgentProcessIdentity,
        events: [VerifiedPatchEventReference]
    ) throws {
        guard projectID != Self.zeroUUID,
              sessionID != Self.zeroUUID,
              process.terminalID != Self.zeroUUID,
              process.processGeneration > 0,
              Self.isSafeAbsolutePath(worktreePath),
              !events.isEmpty else {
            throw VerifiedPatchValidationError.invalidBinding
        }

        let ordered = events.sorted {
            if $0.cursorValue != $1.cursorValue {
                return $0.cursorValue < $1.cursorValue
            }
            return $0.envelopeID.uuidString < $1.envelopeID.uuidString
        }
        var seenEnvelopeIDs: Set<UUID> = []
        for (index, event) in ordered.enumerated() {
            guard event.envelopeID != Self.zeroUUID,
                  event.cursorValue > 0,
                  !event.transitions.isEmpty else {
                throw VerifiedPatchValidationError.invalidBinding
            }
            guard seenEnvelopeIDs.insert(event.envelopeID).inserted else {
                throw VerifiedPatchValidationError.duplicateEnvelope(
                    event.envelopeID
                )
            }
            for transition in event.transitions {
                try Self.validate(transition)
            }
            guard index > 0 else { continue }
            let previous = ordered[index - 1].cursorValue
            if event.cursorValue == previous {
                throw VerifiedPatchValidationError.cursorReplay(previous)
            }
            guard previous < UInt64.max else {
                throw VerifiedPatchValidationError.cursorGap(
                    expected: UInt64.max,
                    actual: event.cursorValue
                )
            }
            let expected = previous + 1
            guard event.cursorValue == expected else {
                throw VerifiedPatchValidationError.cursorGap(
                    expected: expected,
                    actual: event.cursorValue
                )
            }
        }

        self.projectID = projectID
        self.worktreePath = worktreePath
        self.sessionID = sessionID
        self.process = process
        self.events = ordered
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.utf8.contains(0),
              path.utf8.count <= 4_096 else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !components.isEmpty
            && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func validate(
        _ transition: VerifiedPatchContentTransition
    ) throws {
        guard isSafeRelativePath(transition.sourcePath),
              transition.beforeIdentity != nil
                || transition.afterIdentity != nil else {
            throw VerifiedPatchValidationError.invalidTransition
        }
        if let destinationPath = transition.destinationPath {
            guard isSafeRelativePath(destinationPath),
                  destinationPath != transition.sourcePath,
                  transition.beforeIdentity != nil,
                  transition.afterIdentity != nil else {
                throw VerifiedPatchValidationError.invalidTransition
            }
        }
    }

    private static func isSafeAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.utf8.contains(0),
              path.utf8.count <= 4_096 else {
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

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Exact bytes supplied by a trusted capture boundary.
nonisolated struct VerifiedPatchSourceOperation: Sendable, Equatable {
    let eventEnvelopeID: UUID
    let sourcePath: String
    let destinationPath: String?
    let beforeContent: Data?
    let afterContent: Data?

    init(
        eventEnvelopeID: UUID,
        sourcePath: String,
        destinationPath: String? = nil,
        beforeContent: Data?,
        afterContent: Data?
    ) {
        self.eventEnvelopeID = eventEnvelopeID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.beforeContent = beforeContent
        self.afterContent = afterContent
    }
}

nonisolated enum VerifiedPatchOperationKind: String, Sendable, Equatable {
    case modify
    case create
    case delete
    case rename
}

/// One exact file state retained only in the owner-private patch payload.
nonisolated struct VerifiedPatchFileState: Sendable, Equatable {
    let identity: ContentIdentity
    let content: Data

    init(content: Data) {
        self.identity = ContentIdentity(content: content)
        self.content = content
    }
}

/// One deterministic line hunk for a text modification.
///
/// Lines retain their original newline bytes, including CRLF. Context is
/// deliberately exact and bounded; inverse application requires a unique
/// context match in the current text.
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
    /// Checked, uniquely matched text hunks.
    case text(hunks: [VerifiedTextPatchHunk])
    /// Exact-state replacement/removal only.
    case exactState
}

/// One validated operation in a verified patch set.
nonisolated struct VerifiedPatchOperation: Sendable, Equatable {
    let eventEnvelopeID: UUID
    let kind: VerifiedPatchOperationKind
    let sourcePath: String
    let destinationPath: String?
    let before: VerifiedPatchFileState?
    let after: VerifiedPatchFileState?
    let strategy: VerifiedPatchApplicationStrategy

    var operationKey: String {
        [
            eventEnvelopeID.uuidString,
            kind.rawValue,
            sourcePath,
            destinationPath ?? ""
        ].joined(separator: ":")
    }

    var transition: VerifiedPatchContentTransition {
        VerifiedPatchContentTransition(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            beforeIdentity: before?.identity,
            afterIdentity: after?.identity
        )
    }

    var touchedPaths: [String] {
        if let destinationPath {
            return [sourcePath, destinationPath]
        }
        return [sourcePath]
    }
}

/// A deterministic patch tied to an exact verified event range.
nonisolated struct VerifiedPatchSet: Sendable, Equatable, Identifiable {
    let id: UUID
    let binding: VerifiedPatchEventBinding
    let operations: [VerifiedPatchOperation]
}

nonisolated enum VerifiedInversePreviewKind: String, Sendable, Equatable {
    case applyTextHunks
    case restoreExactBytes
    case removeCreatedFile
    case restoreDeletedFile
    case restoreRenamedFile
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
    let header: String
    let lines: [VerifiedInversePreviewLine]
}

/// Structured, deterministic preview for every inverse operation.
nonisolated struct VerifiedInverseOperationPreview: Sendable, Equatable {
    let operationKey: String
    let eventEnvelopeID: UUID
    let kind: VerifiedInversePreviewKind
    let sourcePath: String
    let destinationPath: String?
    let expectedCurrentIdentity: ContentIdentity?
    let resultIdentity: ContentIdentity?
    let hunks: [VerifiedInverseHunkPreview]
}

/// In-memory workspace state consumed and returned by the pure engine.
nonisolated struct VerifiedPatchWorkspaceSnapshot: Sendable, Equatable {
    let files: [String: Data]
}

nonisolated enum VerifiedPatchConflictReason: Error, Sendable, Equatable {
    case expectedFileMissing
    case unexpectedFilePresent
    case exactStateDiverged
    case currentContentIsNotText
    case textContextMissing(hunkIndex: Int)
    case ambiguousTextContext(hunkIndex: Int)
    case overlappingResolvedHunks
}

nonisolated struct VerifiedPatchConflict: Sendable, Equatable {
    let operationKey: String
    let path: String
    let reason: VerifiedPatchConflictReason
}

/// Atomic result: conflicts expose no partially transformed snapshot.
nonisolated enum VerifiedCheckedInverseResult: Sendable, Equatable {
    case applied(
        snapshot: VerifiedPatchWorkspaceSnapshot,
        previews: [VerifiedInverseOperationPreview]
    )
    case conflicted([VerifiedPatchConflict])
}

nonisolated enum VerifiedPatchValidationError: Error, Sendable, Equatable {
    case invalidBinding
    case duplicateEnvelope(UUID)
    case cursorReplay(UInt64)
    case cursorGap(expected: UInt64, actual: UInt64)
    case invalidTransition
    case invalidPatchID
    case noOperations
    case invalidOperation
    case invalidPath(String)
    case duplicateTouchedPath(String)
    case duplicateBoundTransition
    case unboundOperation
    case unusedBoundTransition
    case contentTooLarge
}
