//
//  AgentHistoryCheckedUndoEngine.swift
//  Pine
//
//  The checked inverse-apply engine for verified Agent History entries
//  (#1183). Where the fail-closed floor refuses every entry, this engine is
//  the durable safe-undo path: it loads the owner-private authority, re-validates
//  the project-log projection against it, re-checks every file's current
//  identity against the recorded after-state, and applies the inverse
//  (restore recorded before-bytes / remove created files / recreate deleted
//  files) atomically with a recoverable backup.
//
//  Safety invariants (mirrors the #1183 acceptance criteria):
//
//  1. A heuristic/ambiguous entry, or a verified entry with no matching
//     unconsumed private authority, never reaches the apply path.
//  2. If any recorded file has diverged from its expected after-state, or the
//     workspace Git state changed since capture, the whole entry is refused
//     before a single byte is mutated.
//  3. The inverse restores only the recorded before-bytes; pre-existing
//     unrelated edits encoded in the before-state survive byte-for-byte.
//  4. A partial apply is rolled back from the backup; on success the authority
//     is marked consumed so it can never be replayed.
//
//  All file access is confined beneath the workspace root without following
//  symlinks at the recorded path (the capture path already normalized them).
//

import Darwin
import Foundation

/// Why a verified entry cannot proceed past the engine to the apply step.
/// Additive over the pure `AgentHistoryUndoUnavailableReason` cases so the UI
/// can explain each runtime refusal.
nonisolated enum AgentHistoryEngineBlockReason: Equatable, Sendable {
    case authorityRecordMissing
    case authorityConsumed
    case workspaceRootMismatch
    case projectionTampered
    case workspaceGitStateChanged
    case currentContentDiverged(path: String)
    case inversePayloadMissing
    case fileSystemError(String)
    case applyFailed(path: String)
}

/// Outcome of a single file in a checked undo.
nonisolated struct AgentHistoryFileUndoOutcome: Sendable, Equatable {
    let relativePath: String
    let succeeded: Bool
    let message: String
}

/// Result of a checked undo attempt.
nonisolated struct AgentHistoryCheckedUndoResult: Sendable, Equatable {
    let allSucceeded: Bool
    let outcomes: [AgentHistoryFileUndoOutcome]
    let blockedReason: AgentHistoryEngineBlockReason?
    /// Persistent owner-private backup retained when rollback or cleanup could
    /// not be proven complete. Surfaced to the user for manual recovery.
    let recoveryBackupPath: String?
    /// Workspace files whose original inodes are intentionally retained so a
    /// writer holding an old descriptor cannot lose a concurrent late write.
    let recoveryQuarantinePaths: [String]
}

nonisolated struct AgentHistoryCheckedUndoHooks: Sendable {
    var beforeMutation: (@Sendable (String) -> Void)?
    var afterWorkspaceQuarantineRename: (@Sendable (String) -> Void)?
    var afterQuarantineValidation: (@Sendable (String) -> Void)?
    var afterRollbackInstalledValidation: (@Sendable (String) -> Void)?

    static let none = AgentHistoryCheckedUndoHooks()
}

nonisolated struct AgentHistoryCheckedUndoContext: Sendable {
    let root: URL
    let backup: AgentHistoryRecoveryBackup
    let manifest: AgentHistoryAuthorityManifest
    let privateStore: AgentHistoryPrivateStore
}

nonisolated private struct AgentHistoryRollbackSummary: Sendable {
    let succeeded: Bool
    let retainedRelativePaths: [String]
}

/// The checked undo engine. `nonisolated` so it runs off the main actor during
/// `revert`; it receives immutable snapshots and returns a value-type result,
/// never touching `@MainActor` state itself.
nonisolated enum AgentHistoryCheckedUndoEngine {

    // MARK: - Canonical projection digest

    /// Recomputes the canonical projection digest of a verified change set,
    /// excluding the stored digest field itself. The authority manifest records
    /// the digest computed at capture; a mismatch means the project-log
    /// projection was edited after capture and must be refused.
    static func canonicalProjectionDigest(of changeSet: VerifiedAgentChangeSet) -> String {
        var copy = changeSet
        // The authority's digest field is excluded from its own input.
        let excluded = AgentHistoryPrivateAuthorityReference(
            storage: copy.authority.storage,
            recordID: copy.authority.recordID,
            manifestFormatVersion: copy.authority.manifestFormatVersion,
            canonicalContractSHA256: String(repeating: "0", count: 64)
        )
        copy = VerifiedAgentChangeSet(
            id: copy.id,
            historyEntryID: copy.historyEntryID,
            schemaVersion: copy.schemaVersion,
            capturedAt: copy.capturedAt,
            provenance: copy.provenance,
            workspace: copy.workspace,
            changes: copy.changes,
            authority: excluded,
            inversePayload: copy.inversePayload
        )
        let data = (try? AgentHistoryStore.makeEncoder().encode(copy)) ?? Data()
        return AgentHistoryContentHash.sha256Hex(data)
    }

    // MARK: - Preflight (no filesystem mutation)

    /// Validates the private authority, projection integrity, workspace root,
    /// and captured Git state without reading any recorded file's content.
    /// Returns `nil` when the entry may proceed to the content divergence
    /// check, otherwise the block reason.
    static func preflight(
        entry: AgentHistoryEntry,
        changeSet: VerifiedAgentChangeSet,
        currentRoot: URL,
        manifest: AgentHistoryAuthorityManifest
    ) -> AgentHistoryEngineBlockReason? {
        guard AgentHistoryUndoPreflight.evaluate(entry)
            == .readyForPrivateAuthorityValidation else {
            return .projectionTampered
        }
        if manifest.consumed {
            return .authorityConsumed
        }
        // Anti-tamper: the manifest must bind the same identities.
        guard manifest.changeSetID == changeSet.id,
              manifest.historyEntryID == changeSet.historyEntryID,
              manifest.sessionID == changeSet.provenance.sessionID,
              manifest.privateWorkspaceID == changeSet.workspace.privateWorkspaceID,
              manifest.capturedHeadOID == changeSet.workspace.headOID,
              manifest.capturedIndexSHA256 == changeSet.workspace.indexSHA256,
              manifest.canonicalContractSHA256
                == changeSet.authority.canonicalContractSHA256,
              manifest.manifestFormatVersion
                == AgentHistoryAuthorityManifest.currentManifestFormatVersion,
              changeSet.authority.manifestFormatVersion
                == AgentHistoryPrivateAuthorityReference.currentManifestFormatVersion else {
            return .projectionTampered
        }
        // Projection digest: the log entry's change set must hash to the
        // digest the authority recorded at capture.
        let recomputed = canonicalProjectionDigest(of: changeSet)
        guard recomputed == manifest.canonicalContractSHA256 else {
            return .projectionTampered
        }
        // Workspace root must still resolve to the captured canonical path.
        guard AgentHistoryContentHash.canonicalRootPath(currentRoot) == manifest.resolvedRootPath else {
            return .workspaceRootMismatch
        }
        guard let rootIdentity = AgentHistoryContentHash.rootIdentity(currentRoot),
              rootIdentity.device == manifest.rootDevice,
              rootIdentity.inode == manifest.rootInode else {
            return .workspaceRootMismatch
        }
        // Captured Git state must be unchanged: a moved HEAD or a changed
        // index means the baseline the inverse assumes no longer holds.
        let currentHead = AgentHistoryContentHash.headOID(in: currentRoot)
        guard currentHead == manifest.capturedHeadOID else {
            return .workspaceGitStateChanged
        }
        let currentIndex = AgentHistoryContentHash.indexSHA256(in: currentRoot)
        guard currentIndex == manifest.capturedIndexSHA256 else {
            return .workspaceGitStateChanged
        }
        return nil
    }

    // MARK: - Content divergence check (read-only)

    /// Verifies every recorded file's current identity matches its expected
    /// after-state. Returns the first divergence, or `nil` if all match. No
    /// mutation occurs here, so a divergence leaves the tree untouched.
    static func contentDivergence(
        changeSet: VerifiedAgentChangeSet,
        root: URL,
        manifest: AgentHistoryAuthorityManifest? = nil
    ) -> AgentHistoryEngineBlockReason? {
        do {
            let workspace = try AgentHistorySafeWorkspace(
                root: root,
                expectedDevice: manifest?.rootDevice,
                expectedInode: manifest?.rootInode
            )
            for change in changeSet.changes {
                guard try workspace.matchesCurrentState(change: change) else {
                    return .currentContentDiverged(path: change.relativePath)
                }
            }
        } catch {
            return .currentContentDiverged(path: changeSet.changes.first?.relativePath ?? "")
        }
        return nil
    }

    // MARK: - Atomic apply

    /// Applies the checked inverse for a verified change set. The backup is
    /// written first; any apply failure rolls the affected files back from it.
    /// On full success the caller marks the authority consumed.
    static func apply(
        changeSet: VerifiedAgentChangeSet,
        payload: AgentHistoryInversePayload,
        context: AgentHistoryCheckedUndoContext,
        hooks: AgentHistoryCheckedUndoHooks = .none
    ) -> AgentHistoryCheckedUndoResult {
        let root = context.root
        let backup = context.backup
        let backupPath = backup.path
        let manifest = context.manifest
        let privateStore = context.privateStore
        var workspaceForRollback: AgentHistorySafeWorkspace?
        guard let entriesByPath = validatedPayloadEntries(
            changeSet: changeSet,
            payload: payload
        ) else {
            return blockedApplyResult(
                changeSet: changeSet,
                reason: .inversePayloadMissing,
                detail: "inverse payload does not exactly match the verified contract"
            )
        }

        let transactionID = UUID()
        var mutations: [AgentHistorySafeMutation] = []
        do {
            let workspace = try AgentHistorySafeWorkspace(
                root: root,
                expectedDevice: manifest.rootDevice,
                expectedInode: manifest.rootInode
            )
            workspaceForRollback = workspace
            let snapshots = try changeSet.changes.map {
                try workspace.snapshot(relativePath: $0.relativePath)
            }
            guard zip(changeSet.changes, snapshots).allSatisfy({
                currentSnapshot($0.1, matches: $0.0)
            }) else {
                return blockedApplyResult(
                    changeSet: changeSet,
                    reason: .currentContentDiverged(
                        path: firstDivergedPath(
                            changes: changeSet.changes,
                            snapshots: snapshots
                        )
                    ),
                    detail: "current content diverged"
                )
            }
            try writeRecoverableBackup(
                snapshots: snapshots,
                transactionID: transactionID,
                backup: backup,
                manifest: manifest
            )
            guard workspace.isStillBoundToCanonicalPath(),
                  workspaceGitStateMatches(root: root, manifest: manifest) else {
                throw AgentHistoryCheckedUndoError.workspaceChanged
            }

            for change in changeSet.changes {
                hooks.beforeMutation?(change.relativePath)
                guard try workspace.matchesCurrentState(change: change) else {
                    throw AgentHistoryCheckedUndoError.currentContentChanged(
                        change.relativePath
                    )
                }
                guard let entry = entriesByPath[change.relativePath] else {
                    throw AgentHistoryCheckedUndoError.missingBeforeContent(
                        change.relativePath
                    )
                }

                switch change.operation {
                case .modify:
                    let quarantined = try workspace.quarantineExpectedFile(
                        change: change,
                        transactionID: transactionID,
                        afterRename: {
                            hooks.afterWorkspaceQuarantineRename?(
                                change.relativePath
                            )
                        }
                    )
                    let rollbackOnly = AgentHistorySafeMutation(
                        transactionID: transactionID,
                        kind: .removed,
                        relativePath: quarantined.relativePath,
                        quarantineName: quarantined.quarantineName,
                        quarantinedDevice: quarantined.quarantinedDevice,
                        quarantinedInode: quarantined.quarantinedInode,
                        quarantinedContentSHA256:
                            quarantined.quarantinedContentSHA256,
                        quarantinedByteCount:
                            quarantined.quarantinedByteCount,
                        quarantinedPermissions:
                            quarantined.quarantinedPermissions,
                        installedDevice: nil,
                        installedInode: nil,
                        installedContentSHA256: nil,
                        installedByteCount: nil,
                        installedPermissions: nil
                    )
                    mutations.append(rollbackOnly)
                    guard let content = entry.beforeContent,
                          let permissions = entry.permissions else {
                        throw AgentHistoryCheckedUndoError.missingBeforeContent(
                            change.relativePath
                        )
                    }
                    let installed = try workspace.installExclusive(
                        relativePath: change.relativePath,
                        data: content,
                        permissions: permissions,
                        installation: AgentHistorySafeInstallation(
                            transactionID: transactionID,
                            kind: .replaced,
                            quarantine: quarantined
                        )
                    )
                    mutations[mutations.count - 1] = installed
                    guard workspace.matchesInstalledState(installed) else {
                        throw AgentHistoryCheckedUndoError.currentContentChanged(
                            change.relativePath
                        )
                    }
                case .create:
                    let quarantined = try workspace.quarantineExpectedFile(
                        change: change,
                        transactionID: transactionID,
                        afterRename: {
                            hooks.afterWorkspaceQuarantineRename?(
                                change.relativePath
                            )
                        }
                    )
                    mutations.append(quarantined)
                case .delete:
                    guard let content = entry.beforeContent,
                          let permissions = entry.permissions else {
                        throw AgentHistoryCheckedUndoError.missingBeforeContent(
                            change.relativePath
                        )
                    }
                    let installed = try workspace.installExclusive(
                        relativePath: change.relativePath,
                        data: content,
                        permissions: permissions,
                        installation: AgentHistorySafeInstallation(
                            transactionID: transactionID,
                            kind: .created,
                            quarantine: nil
                        )
                    )
                    mutations.append(installed)
                    guard workspace.matchesInstalledState(installed) else {
                        throw AgentHistoryCheckedUndoError.currentContentChanged(
                            change.relativePath
                        )
                    }
                case .rename, .symlink, .unsupported:
                    throw AgentHistoryCheckedUndoError.unsupportedOperation(
                        change.relativePath
                    )
                }
            }

            // Consumption is part of the transaction. If it cannot be
            // confirmed durable, restore every path and report failure.
            guard workspace.isStillBoundToCanonicalPath(),
                  workspaceGitStateMatches(root: root, manifest: manifest) else {
                throw AgentHistoryCheckedUndoError.workspaceChanged
            }
            do {
                try privateStore.markConsumed(recordID: manifest.recordID)
            } catch {
                let rollbackSummary = rollback(
                    mutations: mutations,
                    workspace: workspace,
                    recoveryBackup: backup,
                    hooks: hooks
                )
                let retainedRelativePaths = uniquePaths(
                    rollbackSummary.retainedRelativePaths
                        + retainedRecoveryRelativePaths(
                            mutations: mutations,
                            workspace: workspace
                        )
                )
                let retainedPaths = absoluteRecoveryPaths(
                    retainedRelativePaths,
                    root: root
                )
                _ = writeRetainedQuarantineMetadata(
                    retainedPaths,
                    backup: backup
                )
                return blockedApplyResult(
                    changeSet: changeSet,
                    reason: .applyFailed(path: changeSet.changes.last?.relativePath ?? ""),
                    detail: rollbackSummary.succeeded
                        ? "authority consumption failed; changes rolled back; backup: \(backupPath)"
                        : "authority consumption failed; recover from backup: \(backupPath)",
                    recoveryBackupPath: backupPath,
                    recoveryQuarantinePaths: retainedPaths
                )
            }
            // The owner-private authority is now durably single-use. Append
            // this marker before deleting any quarantine inode so a restart
            // can distinguish a prepared transaction from one that crossed
            // the irreversible authority boundary.
            try backup.markPhase(
                .authorityConsumed,
                transactionID: transactionID
            )

            var cleanupSucceeded = true
            var retainedQuarantines: [String] = []
            for mutation in mutations {
                switch workspace.commit(
                    mutation,
                    recoveryBackup: backup,
                    afterQuarantineValidation: {
                        hooks.afterQuarantineValidation?(
                            mutation.relativePath
                        )
                    }
                ) {
                case .complete:
                    break
                case .retained(let path):
                    retainedQuarantines.append(path)
                case .failed(let path):
                    cleanupSucceeded = false
                    if let path {
                        retainedQuarantines.append(path)
                    }
                }
            }
            let unresolvedRecoveryPaths = workspace.unresolvedRecoveryPaths()
            if !unresolvedRecoveryPaths.isEmpty {
                cleanupSucceeded = false
                retainedQuarantines.append(
                    contentsOf: unresolvedRecoveryPaths
                )
            }
            retainedQuarantines = uniquePaths(retainedQuarantines)
            if !workspace.isStillBoundToCanonicalPath()
                || !workspaceGitStateMatches(root: root, manifest: manifest) {
                cleanupSucceeded = false
            }
            if cleanupSucceeded {
                for change in changeSet.changes {
                    guard let entry = entriesByPath[change.relativePath],
                          inverseStateMatches(
                            change: change,
                            entry: entry,
                            workspace: workspace
                          ) else {
                        cleanupSucceeded = false
                        break
                    }
                }
            }
            let absoluteQuarantinePaths = absoluteRecoveryPaths(
                retainedQuarantines,
                root: root
            )
            let metadataSucceeded = writeRetainedQuarantineMetadata(
                absoluteQuarantinePaths,
                backup: backup
            )
            guard cleanupSucceeded, metadataSucceeded else {
                return blockedApplyResult(
                    changeSet: changeSet,
                    reason: .applyFailed(
                        path: changeSet.changes.last?.relativePath ?? ""
                    ),
                    detail: "inverse finalization could not be verified; "
                        + "recover from backup: \(backupPath)",
                    recoveryBackupPath: backupPath,
                    recoveryQuarantinePaths: absoluteQuarantinePaths
                )
            }
            // Failure to append the final marker must retain the backup, but
            // the already-verified inverse remains a success. The next launch
            // surfaces the authority-consumed recovery record for review.
            let finalizationMarkerSucceeded: Bool
            do {
                try backup.markPhase(
                    .finalized,
                    transactionID: transactionID
                )
                finalizationMarkerSucceeded = true
            } catch {
                finalizationMarkerSucceeded = false
            }
            if !retainedQuarantines.isEmpty {
                return AgentHistoryCheckedUndoResult(
                    allSucceeded: true,
                    outcomes: changeSet.changes.map {
                        AgentHistoryFileUndoOutcome(
                            relativePath: $0.relativePath,
                            succeeded: true,
                            message: inverseSuccessMessage(for: $0)
                        )
                    },
                    blockedReason: nil,
                    recoveryBackupPath: backupPath,
                    recoveryQuarantinePaths: absoluteQuarantinePaths
                )
            }
            guard finalizationMarkerSucceeded else {
                return AgentHistoryCheckedUndoResult(
                    allSucceeded: true,
                    outcomes: changeSet.changes.map {
                        AgentHistoryFileUndoOutcome(
                            relativePath: $0.relativePath,
                            succeeded: true,
                            message: inverseSuccessMessage(for: $0)
                        )
                    },
                    blockedReason: nil,
                    recoveryBackupPath: backupPath,
                    recoveryQuarantinePaths: []
                )
            }
            let backupRemoved = backup.remove()
            return AgentHistoryCheckedUndoResult(
                allSucceeded: true,
                outcomes: changeSet.changes.map {
                    AgentHistoryFileUndoOutcome(
                        relativePath: $0.relativePath,
                        succeeded: true,
                        message: inverseSuccessMessage(for: $0)
                    )
                },
                blockedReason: nil,
                recoveryBackupPath: backupRemoved || !backup.isDurablyLinked()
                    ? nil
                    : backupPath,
                recoveryQuarantinePaths: []
            )
        } catch {
            let rollbackSummary: AgentHistoryRollbackSummary
            if let workspaceForRollback {
                rollbackSummary = rollback(
                    mutations: mutations,
                    workspace: workspaceForRollback,
                    recoveryBackup: backup,
                    hooks: hooks
                )
            } else {
                rollbackSummary = rollback(
                    mutations: mutations,
                    root: root,
                    manifest: manifest,
                    recoveryBackup: backup,
                    hooks: hooks
                )
            }
            let recoveryPath = backup.isDurablyLinked() ? backupPath : nil
            let retainedRelativePaths = uniquePaths(
                rollbackSummary.retainedRelativePaths
                    + (workspaceForRollback.map {
                        retainedRecoveryRelativePaths(
                            mutations: mutations,
                            workspace: $0
                        )
                    } ?? [])
            )
            let retainedPaths = absoluteRecoveryPaths(
                retainedRelativePaths,
                root: root
            )
            if recoveryPath != nil {
                _ = writeRetainedQuarantineMetadata(
                    retainedPaths,
                    backup: backup
                )
            }
            return blockedApplyResult(
                changeSet: changeSet,
                reason: .applyFailed(path: changeSet.changes.first?.relativePath ?? ""),
                detail: rollbackSummary.succeeded
                    ? "inverse refused and rolled back; backup: \(backupPath)"
                    : "partial inverse needs recovery from: \(backupPath)",
                recoveryBackupPath: recoveryPath,
                recoveryQuarantinePaths: retainedPaths
            )
        }
    }

    private static func inverseSuccessMessage(
        for change: AgentHistoryRecordedFileChange
    ) -> String {
        switch change.operation {
        case .modify: "restored to recorded before-state"
        case .create: "removed created file"
        case .delete: "recreated deleted file"
        case .rename, .symlink, .unsupported: "no-op"
        }
    }

    // MARK: - Payload and transaction helpers

    private static func validatedPayloadEntries(
        changeSet: VerifiedAgentChangeSet,
        payload: AgentHistoryInversePayload
    ) -> [String: AgentHistoryInverseFileEntry]? {
        guard payload.formatVersion == AgentHistoryInversePayload.currentFormatVersion,
              payload.entries.count == changeSet.changes.count else {
            return nil
        }
        var entries: [String: AgentHistoryInverseFileEntry] = [:]
        for entry in payload.entries {
            guard entries[entry.relativePath] == nil else { return nil }
            entries[entry.relativePath] = entry
        }
        for change in changeSet.changes {
            guard let entry = entries[change.relativePath],
                  entry.operation == change.operation else {
                return nil
            }
            switch change.operation {
            case .modify, .delete:
                guard let before = change.before,
                      let content = entry.beforeContent,
                      entry.permissions == before.permissions,
                      UInt64(content.count) == before.byteCount,
                      AgentHistoryContentHash.sha256Hex(content)
                        == before.contentSHA256 else {
                    return nil
                }
            case .create:
                guard entry.beforeContent == nil,
                      entry.permissions == nil else {
                    return nil
                }
            case .rename, .symlink, .unsupported:
                return nil
            }
        }
        return entries
    }

    private static func currentSnapshot(
        _ snapshot: AgentHistorySafeFileSnapshot,
        matches change: AgentHistoryRecordedFileChange
    ) -> Bool {
        switch change.operation {
        case .modify, .create:
            guard let after = change.after,
                  let data = snapshot.data,
                  snapshot.permissions == after.permissions,
                  UInt64(data.count) == after.byteCount else {
                return false
            }
            return AgentHistoryContentHash.sha256Hex(data) == after.contentSHA256
        case .delete:
            return !snapshot.exists
        case .rename, .symlink, .unsupported:
            return false
        }
    }

    private static func inverseStateMatches(
        change: AgentHistoryRecordedFileChange,
        entry: AgentHistoryInverseFileEntry,
        workspace: AgentHistorySafeWorkspace
    ) -> Bool {
        guard let snapshot = try? workspace.snapshot(
            relativePath: change.relativePath
        ) else {
            return false
        }
        switch change.operation {
        case .modify, .delete:
            guard let content = entry.beforeContent,
                  let permissions = entry.permissions,
                  let current = snapshot.data,
                  snapshot.permissions == permissions,
                  current == content else {
                return false
            }
            return true
        case .create:
            return !snapshot.exists
        case .rename, .symlink, .unsupported:
            return false
        }
    }

    private static func firstDivergedPath(
        changes: [AgentHistoryRecordedFileChange],
        snapshots: [AgentHistorySafeFileSnapshot]
    ) -> String {
        zip(changes, snapshots).first {
            !currentSnapshot($0.1, matches: $0.0)
        }?.0.relativePath ?? ""
    }

    private static func workspaceGitStateMatches(
        root: URL,
        manifest: AgentHistoryAuthorityManifest
    ) -> Bool {
        AgentHistoryContentHash.headOID(in: root) == manifest.capturedHeadOID
            && AgentHistoryContentHash.indexSHA256(in: root)
                == manifest.capturedIndexSHA256
    }

    private static func rollback(
        mutations: [AgentHistorySafeMutation],
        root: URL,
        manifest: AgentHistoryAuthorityManifest,
        recoveryBackup: AgentHistoryRecoveryBackup,
        hooks: AgentHistoryCheckedUndoHooks
    ) -> AgentHistoryRollbackSummary {
        guard !mutations.isEmpty else {
            return AgentHistoryRollbackSummary(
                succeeded: true,
                retainedRelativePaths: []
            )
        }
        guard let workspace = try? AgentHistorySafeWorkspace(
            root: root,
            expectedDevice: manifest.rootDevice,
            expectedInode: manifest.rootInode
        ) else {
            return AgentHistoryRollbackSummary(
                succeeded: false,
                retainedRelativePaths: []
            )
        }
        return rollback(
            mutations: mutations,
            workspace: workspace,
            recoveryBackup: recoveryBackup,
            hooks: hooks
        )
    }

    private static func rollback(
        mutations: [AgentHistorySafeMutation],
        workspace: AgentHistorySafeWorkspace,
        recoveryBackup: AgentHistoryRecoveryBackup,
        hooks: AgentHistoryCheckedUndoHooks
    ) -> AgentHistoryRollbackSummary {
        var succeeded = true
        var retainedRelativePaths: [String] = []
        for mutation in mutations.reversed() {
            let result = workspace.rollback(
                mutation,
                recoveryBackup: recoveryBackup,
                afterInstalledValidation: {
                    hooks.afterRollbackInstalledValidation?(
                        mutation.relativePath
                    )
                }
            )
            if !result.succeeded {
                succeeded = false
            }
            retainedRelativePaths.append(contentsOf: result.retainedPaths)
        }
        return AgentHistoryRollbackSummary(
            succeeded: succeeded,
            retainedRelativePaths: uniquePaths(retainedRelativePaths)
        )
    }

    private static func retainedRecoveryRelativePaths(
        mutations: [AgentHistorySafeMutation],
        workspace: AgentHistorySafeWorkspace
    ) -> [String] {
        uniquePaths(
            mutations.compactMap {
                workspace.retainedQuarantinePath(for: $0)
            } + workspace.unresolvedRecoveryPaths()
        )
    }

    private static func absoluteRecoveryPaths(
        _ relativePaths: [String],
        root: URL
    ) -> [String] {
        relativePaths.map {
            if $0.hasPrefix("/") {
                return URL(fileURLWithPath: $0).standardizedFileURL.path
            }
            return root.appendingPathComponent(
                $0,
                isDirectory: false
            ).path
        }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func blockedApplyResult(
        changeSet: VerifiedAgentChangeSet,
        reason: AgentHistoryEngineBlockReason,
        detail: String,
        recoveryBackupPath: String? = nil,
        recoveryQuarantinePaths: [String] = []
    ) -> AgentHistoryCheckedUndoResult {
        AgentHistoryCheckedUndoResult(
            allSucceeded: false,
            outcomes: changeSet.changes.map {
                AgentHistoryFileUndoOutcome(
                    relativePath: $0.relativePath,
                    succeeded: false,
                    message: detail
                )
            },
            blockedReason: reason,
            recoveryBackupPath: recoveryBackupPath,
            recoveryQuarantinePaths: recoveryQuarantinePaths
        )
    }

    private static func writeRecoverableBackup(
        snapshots: [AgentHistorySafeFileSnapshot],
        transactionID: UUID,
        backup: AgentHistoryRecoveryBackup,
        manifest authority: AgentHistoryAuthorityManifest
    ) throws {
        do {
            var manifestEntries: [AgentHistoryRecoveryManifestEntry] = []
            for (index, snapshot) in snapshots.enumerated() {
                let contentFile = snapshot.data == nil ? nil : "\(index).bin"
                if let data = snapshot.data, let contentFile {
                    try backup.writeExclusive(data, named: contentFile)
                }
                manifestEntries.append(AgentHistoryRecoveryManifestEntry(
                    relativePath: snapshot.relativePath,
                    existed: snapshot.exists,
                    permissions: snapshot.permissions,
                    contentFile: contentFile,
                    byteCount: snapshot.data.map { UInt64($0.count) },
                    contentSHA256: snapshot.data.map(AgentHistoryContentHash.sha256Hex)
                ))
            }
            let manifest = AgentHistoryRecoveryManifest(
                formatVersion:
                    AgentHistoryRecoveryManifest.currentFormatVersion,
                transactionID: transactionID,
                authorityRecordID: authority.recordID,
                historyEntryID: authority.historyEntryID,
                changeSetID: authority.changeSetID,
                resolvedRootPath: authority.resolvedRootPath,
                rootDevice: authority.rootDevice,
                rootInode: authority.rootInode,
                createdAt: Date(),
                entries: manifestEntries
            )
            let data = try AgentHistoryStore.makeEncoder().encode(manifest)
            try backup.writeExclusive(data, named: "manifest.json")
            try backup.synchronize()
            try backup.markPhase(.prepared, transactionID: transactionID)
        } catch {
            _ = backup.remove()
            throw AgentHistoryCheckedUndoError.backupCreationFailed
        }
    }

    private static func writeRetainedQuarantineMetadata(
        _ relativePaths: [String],
        backup: AgentHistoryRecoveryBackup
    ) -> Bool {
        guard !relativePaths.isEmpty else { return true }
        do {
            let metadata = AgentHistoryRecoveryPathsManifest(
                formatVersion:
                    AgentHistoryRecoveryPathsManifest.currentFormatVersion,
                recoveryPaths: relativePaths
            )
            let data = try AgentHistoryStore.makeEncoder().encode(metadata)
            try backup.writeExclusive(
                data,
                named: "retained-quarantines.json"
            )
            try backup.synchronize()
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Errors

enum AgentHistoryCheckedUndoError: Error, Equatable {
    case missingBeforeContent(String)
    case unsupportedOperation(String)
    case currentContentChanged(String)
    case workspaceChanged
    case backupCreationFailed
}
