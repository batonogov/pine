//
//  AgentHistoryUndoPreflight.swift
//  Pine
//
//  Pure, fail-closed validation for the verified Agent History change-set
//  contract (#1183). This validates the project-log projection only; a future
//  undo engine must treat the owner-private manifest as authority, resolve the
//  current workspace, lstat every path, re-hash content/index state, preview
//  the inverse, and apply atomically.
//

import Foundation

/// Why a stored entry is not eligible to reach the future checked-undo engine.
nonisolated enum AgentHistoryUndoPreflightFailure: Equatable, Sendable {
    case attributionNotVerified(AgentHistoryAttribution)
    case missingChangeSet
    case unsupportedSchemaVersion(Int)
    case invalidChangeSetIdentity
    case entryIdentityMismatch
    case sessionMismatch
    case invalidProvenance
    case invalidPrivateAuthority
    case invalidWorkspaceIdentity
    case invalidInversePayload
    case emptyChangeSet
    case affectedFilesMismatch
    case invalidRelativePath(String)
    case duplicatePath(String)
    case unsupportedOperation(String)
    case invalidFileState(String)
}

/// Result of validating the immutable, persisted undo contract.
nonisolated enum AgentHistoryUndoPreflightDecision: Equatable, Sendable {
    /// The contract is structurally complete. This does not authorize mutation:
    /// private-authority lookup, runtime divergence checks, and a checked apply
    /// engine are still required.
    case readyForPrivateAuthorityValidation
    case blocked(AgentHistoryUndoPreflightFailure)
}

/// Structural validation shared by the history model and the future mutation
/// boundary. It is pure so malformed/legacy/future records can be tested
/// exhaustively without touching the file system.
nonisolated enum AgentHistoryUndoPreflight {
    static func evaluate(_ entry: AgentHistoryEntry) -> AgentHistoryUndoPreflightDecision {
        guard entry.attribution == .verified else {
            return .blocked(.attributionNotVerified(entry.attribution))
        }
        guard let changeSet = entry.verifiedChangeSet else {
            return .blocked(.missingChangeSet)
        }
        guard changeSet.schemaVersion == VerifiedAgentChangeSet.currentSchemaVersion else {
            return .blocked(.unsupportedSchemaVersion(changeSet.schemaVersion))
        }
        guard changeSet.id != zeroUUID,
              changeSet.historyEntryID != zeroUUID,
              changeSet.capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            return .blocked(.invalidChangeSetIdentity)
        }
        guard changeSet.historyEntryID == entry.id else {
            return .blocked(.entryIdentityMismatch)
        }
        guard changeSet.provenance.sessionID == entry.sessionID else {
            return .blocked(.sessionMismatch)
        }
        guard isValid(changeSet.provenance) else {
            return .blocked(.invalidProvenance)
        }
        guard isValid(changeSet.authority) else {
            return .blocked(.invalidPrivateAuthority)
        }
        guard isValid(changeSet.workspace) else {
            return .blocked(.invalidWorkspaceIdentity)
        }
        guard isValid(changeSet.inversePayload) else {
            return .blocked(.invalidInversePayload)
        }
        guard !changeSet.changes.isEmpty else {
            return .blocked(.emptyChangeSet)
        }

        let recordedPaths = changeSet.changes.map(\.relativePath)
        guard recordedPaths == entry.affectedFiles else {
            return .blocked(.affectedFilesMismatch)
        }

        var canonicalPathKeys: Set<String> = []
        for change in changeSet.changes {
            guard isCanonicalRelativePath(change.relativePath) else {
                return .blocked(.invalidRelativePath(change.relativePath))
            }

            let pathKey = conservativePathKey(change.relativePath)
            guard canonicalPathKeys.insert(pathKey).inserted else {
                return .blocked(.duplicatePath(change.relativePath))
            }

            if let failure = validateChange(change) {
                return .blocked(failure)
            }
        }

        return .readyForPrivateAuthorityValidation
    }

    private static func isValid(_ provenance: AgentHistoryWriterProvenance) -> Bool {
        provenance.sessionID != zeroUUID
            && provenance.writerInstanceID != zeroUUID
            && provenance.processIdentifier > 0
            && provenance.processGeneration > 0
            && provenance.firstEventSequence <= provenance.lastEventSequence
    }

    private static func isValid(_ workspace: AgentHistoryWorkspaceIdentity) -> Bool {
        workspace.privateWorkspaceID != zeroUUID
            && isGitObjectID(workspace.headOID)
            && isCanonicalSHA256(workspace.indexSHA256)
    }

    private static func isValid(_ authority: AgentHistoryPrivateAuthorityReference) -> Bool {
        guard case .applicationSupport = authority.storage else { return false }
        return authority.recordID != zeroUUID
            && authority.manifestFormatVersion
                == AgentHistoryPrivateAuthorityReference.currentManifestFormatVersion
            && isCanonicalSHA256(authority.canonicalContractSHA256)
    }

    private static func isValid(_ payload: AgentHistoryInversePayloadReference) -> Bool {
        guard case .applicationSupport = payload.storage else { return false }
        return payload.formatVersion == AgentHistoryInversePayloadReference.currentFormatVersion
            && payload.blobID != zeroUUID
            && payload.byteCount > 0
            && isCanonicalSHA256(payload.sha256)
    }

    private static func validateChange(
        _ change: AgentHistoryRecordedFileChange
    ) -> AgentHistoryUndoPreflightFailure? {
        switch change.operation {
        case .modify:
            guard let before = change.before,
                  let after = change.after,
                  isValid(before),
                  isValid(after),
                  before != after else {
                return .invalidFileState(change.relativePath)
            }
        case .create:
            guard change.before == nil,
                  let after = change.after,
                  isValid(after) else {
                return .invalidFileState(change.relativePath)
            }
        case .delete:
            guard let before = change.before,
                  isValid(before),
                  change.after == nil else {
                return .invalidFileState(change.relativePath)
            }
        case .rename, .symlink:
            return .unsupportedOperation(change.operation.persistedValue)
        case .unsupported(let value):
            return .unsupportedOperation(value)
        }
        return nil
    }

    private static func isValid(_ state: AgentHistoryRecordedFileState) -> Bool {
        guard case .regularFile = state.kind else { return false }
        return isCanonicalSHA256(state.contentSHA256)
            && state.permissions <= 0o7777
    }

    /// Requires an NFC-normalized, unambiguous relative POSIX path and refuses
    /// Git metadata or Pine's own history log. Runtime validation must still
    /// resolve beneath a root directory descriptor without following links,
    /// compare device/inode/link-count identities, and revalidate immediately
    /// before the atomic apply.
    private static func isCanonicalRelativePath(_ path: String) -> Bool {
        let normalizedPath = path.precomposedStringWithCanonicalMapping
        guard !path.isEmpty,
              path.utf8.elementsEqual(normalizedPath.utf8),
              !path.hasPrefix("/"),
              !path.utf8.contains(0) else {
            return false
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".."
        }) else {
            return false
        }

        let componentKeys = components.map { conservativePathKey(String($0)) }
        guard !componentKeys.contains(".git") else { return false }
        guard componentKeys.count >= 2 else { return true }
        return !(0..<(componentKeys.count - 1)).contains { index in
            componentKeys[index] == ".pine"
                && componentKeys[index + 1] == "agent-log.json"
        }
    }

    /// Rejects aliases conservatively across case-insensitive and
    /// normalization-insensitive volumes. Refusing two legitimate paths on a
    /// case-sensitive volume is safer than applying an inverse to the wrong
    /// object after a project moves to a different volume.
    private static func conservativePathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        isLowercaseHex(value, lengths: [64])
    }

    private static func isGitObjectID(_ value: String) -> Bool {
        // Git repositories may use SHA-1 or SHA-256 object formats.
        isLowercaseHex(value, lengths: [40, 64])
            && value.utf8.contains(where: { $0 != 48 })
    }

    private static func isLowercaseHex(_ value: String, lengths: Set<Int>) -> Bool {
        guard lengths.contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
