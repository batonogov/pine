//
//  AgentHistoryStore.swift
//  Pine
//
//  Owns the persistent history of finished AI-agent sessions (vision #933,
//  Phase 2 — Visibility, issue #1073). Each finished session becomes an
//  `AgentHistoryEntry` appended to `.pine/agent-log.json`, so a user can
//  review observed activity after the process exits.
//
//  Architecture: the observable state (`entries`, `projectRoot`) lives on the
//  main actor so SwiftUI views observe it directly; all disk I/O is delegated
//  to a separate `nonisolated` `AgentHistoryLogWriter` that owns the serial
//  write queue. This split is required by Pine's `check_nonisolated.py` guard
//  (see issue #693): a `@MainActor` type that itself owns a background
//  `DispatchQueue` is the crash pattern that took down #613/#693/
//  SyntaxHighlighter — the queue's async closure inherits MainActor isolation
//  and traps on `dispatch_assert_queue`. Making the *writer* `nonisolated`
//  (mirroring `FileSystemWatcher`) keeps the guard green and the queue safe.
//
//  `init` is tolerant: a missing or corrupt `.pine/agent-log.json` yields an
//  empty log and never crashes on project open. The store never writes outside
//  the project root and never logs file contents — only relative paths + a
//  summary string.
//

import Foundation

/// Outcome of a revert operation for a single history entry.
nonisolated struct AgentHistoryRevertResult: Sendable, Equatable {
    /// Whether every affected file was restored to HEAD.
    let allSucceeded: Bool
    /// Per-file results (path + success/error), in entry order. Populated for
    /// the legacy whole-file refusal path; empty for checked-undo outcomes,
    /// which are carried in `checkedOutcomes`.
    let fileResults: [GitFileRevertResult]
    /// Safety reason when the entry was rejected before any mutation.
    let blockedReason: AgentHistoryUndoUnavailableReason?
    /// Per-file outcomes of a checked inverse apply (verified entries).
    /// Empty unless a verified change set reached the apply step.
    let checkedOutcomes: [AgentHistoryFileUndoOutcome]
    /// Owner-private backup retained for manual recovery after an incomplete
    /// rollback/cleanup. `nil` when no durable recovery artifact remains.
    let recoveryBackupPath: String?
    /// Retained workspace files that preserve original inodes against late
    /// writes through descriptors opened before the checked undo.
    let recoveryQuarantinePaths: [String]

    init(
        allSucceeded: Bool,
        fileResults: [GitFileRevertResult],
        blockedReason: AgentHistoryUndoUnavailableReason? = nil,
        checkedOutcomes: [AgentHistoryFileUndoOutcome] = [],
        recoveryBackupPath: String? = nil,
        recoveryQuarantinePaths: [String] = []
    ) {
        self.allSucceeded = allSucceeded
        self.fileResults = fileResults
        self.blockedReason = blockedReason
        self.checkedOutcomes = checkedOutcomes
        self.recoveryBackupPath = recoveryBackupPath
        self.recoveryQuarantinePaths = recoveryQuarantinePaths
    }
}

nonisolated private struct AgentHistoryCaptureRequest: Sendable {
    let agentTypeIdentifier: String
    let changes: [AgentHistoryRecordedFileChange]
    let beforeContents: [String: Data]
    let provenance: AgentHistoryWriterProvenance
    let workspace: AgentHistoryWorkspaceIdentity
    let root: URL
}

/// Persistent, observable log of finished AI-agent sessions, backed by
/// `.pine/agent-log.json` under the project root.
///
/// `@MainActor` + `@Observable` so SwiftUI views (`AgentHistoryView`) observe
/// `entries` directly. The in-memory `entries` array is the source of truth
/// that mutations update synchronously; disk writes trail asynchronously via
/// the owned `AgentHistoryLogWriter`.
@MainActor
@Observable
final class AgentHistoryStore {
    /// All recorded entries, newest-last (append order). Persisted to disk.
    private(set) var entries: [AgentHistoryEntry] = []

    /// Session IDs that have already been logged, to avoid double-logging a
    /// session finalized more than once (e.g. on both detection and termination).
    private var loggedSessionIDs: Set<UUID> = []

    /// Project root whose `.pine/` directory holds the log. `nil` when no
    /// project is open (e.g. the Welcome window); in that state the store is
    /// in-memory only and `finalize`/`revert` persist nothing. Set via
    /// `updateProjectRoot(_:)` once `WorkspaceManager` resolves the root.
    private(set) var projectRoot: URL?

    /// Owns the serial disk-write queue. `nonisolated` so the guard accepts it
    /// (see class doc). The store only hands it value-type snapshots.
    private let writer = AgentHistoryLogWriter()

    /// Owner-private store for checked-undo authority manifests and inverse
    /// payload blobs (#1183). Defaults to real Application Support; tests inject
    /// a temporary base directory via `init(privateStore:)`.
    private let privateStore: AgentHistoryPrivateStore
    /// Runtime authority availability, refreshed off-main. Rendering consults
    /// this cache and therefore never performs private-store I/O on MainActor.
    private var checkedUndoAvailabilityByEntryID:
        [UUID: AgentHistoryUndoAvailability] = [:]

    /// Durable checked-undo transactions that survived cleanup or were
    /// interrupted. These are display-only notices: discovery never restores
    /// bytes or grants mutation authority.
    private(set) var recoveryNotices: [AgentHistoryRecoveryRecord] = []
    private var recoveryRefreshGeneration = 0

    /// Cap on retained entries to bound `.pine/agent-log.json` growth. Older
    /// entries are trimmed first (FIFO) on append.
    private let maxEntries = 500

    init(
        projectRoot: URL? = nil,
        privateStore: AgentHistoryPrivateStore = AgentHistoryPrivateStore()
    ) {
        self.projectRoot = projectRoot
        self.privateStore = privateStore
        loadFromDisk()
        Task {
            async let availability: Void = refreshCheckedUndoAvailability()
            async let recovery: Void = refreshRecoveryNotices()
            _ = await (availability, recovery)
        }
    }

    // MARK: - Project root / loading

    /// Sets the project root and reloads the on-disk log, so the store picks
    /// up an existing `.pine/agent-log.json` as soon as the project opens
    /// (the root is unknown at `ProjectManager.init` time). Calling with a new
    /// root resets in-memory state and reloads.
    func updateProjectRoot(_ root: URL?) {
        projectRoot = root
        entries = []
        loggedSessionIDs = []
        checkedUndoAvailabilityByEntryID = [:]
        recoveryNotices = []
        recoveryRefreshGeneration &+= 1
        loadFromDisk()
        Task {
            async let availability: Void = refreshCheckedUndoAvailability()
            async let recovery: Void = refreshRecoveryNotices()
            _ = await (availability, recovery)
        }
    }

    /// Loads `.pine/agent-log.json` if present and valid. Tolerates a missing
    /// file (nothing to load) and a corrupt file (logs + starts empty) so a
    /// bad log never blocks project open. Runs synchronously in `init` because
    /// the in-memory `entries` must be populated before the first UI render.
    private func loadFromDisk() {
        guard let root = projectRoot else { return }
        let logURL = root.appendingPathComponent(".pine", isDirectory: true)
            .appendingPathComponent("agent-log.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        do {
            let data = try Data(contentsOf: logURL)
            // Tolerate an empty file (treat as no entries).
            guard !data.isEmpty else { return }
            let decoded = try Self.makeDecoder().decode([AgentHistoryEntry].self, from: data)
            entries = Self.quarantiningDuplicateIdentities(decoded)
            loggedSessionIDs = Set(entries.map(\.sessionID))
        } catch {
            // Corrupt or unreadable log: never crash — start empty and log.
            // The damaged file is left in place; the next successful persist
            // overwrites it atomically.
            NSLog("AgentHistoryStore: failed to decode agent-log.json — starting empty. \(error.localizedDescription)")
            entries = []
            loggedSessionIDs = []
        }
    }

    // MARK: - Recording

    /// Finalizes a finished agent session into a durable log entry.
    ///
    /// - Parameters:
    ///   - session: The finished `AgentSession` (typically `.done`).
    ///   - summary: Caller-computed summary, e.g. "5 files".
    ///   - affectedRelativePaths: Relative paths (from project root) of files
    ///     the session modified. Each is validated via `isValidRelativePath`;
    ///     invalid entries (traversal/absolute) are dropped.
    func finalize(
        session: AgentSession,
        summary: String,
        affectedRelativePaths: [String],
        attribution: AgentHistoryAttribution = .heuristic
    ) {
        // Avoid double-logging a session finalized twice (detection + termination).
        guard !loggedSessionIDs.contains(session.id) else { return }

        let safePaths = affectedRelativePaths.filter(Self.isValidRelativePath)
        let entry = AgentHistoryEntry(
            sessionID: session.id,
            agentTypeRaw: session.agentType.stableIdentifier,
            startedAt: session.startedAt,
            endedAt: Date(),
            affectedFiles: safePaths,
            attribution: attribution,
            summary: summary.isEmpty
                ? Self.defaultSummary(fileCount: safePaths.count)
                : summary
        )
        append(entry)
    }

    /// Appends an entry directly (used by tests and restore), trims to
    /// `maxEntries`, and schedules an asynchronous persist.
    func append(_ entry: AgentHistoryEntry) {
        guard !loggedSessionIDs.contains(entry.sessionID),
              !entries.contains(where: { $0.id == entry.id }),
              !hasPrivateIdentityCollision(entry) else {
            NSLog("AgentHistoryStore: quarantined duplicate history identity")
            return
        }

        loggedSessionIDs.insert(entry.sessionID)
        entries.append(entry)
        if entries.count > maxEntries {
            let surplus = entries.count - maxEntries
            entries.removeFirst(surplus)
        }
        persist()
    }

    /// Rejects duplicate private identities at append time. A private authority
    /// record and inverse blob are single-use capabilities; sharing either
    /// across rows would make a row selection ambiguous at the future mutation
    /// boundary.
    private func hasPrivateIdentityCollision(_ candidate: AgentHistoryEntry) -> Bool {
        guard let changeSet = candidate.verifiedChangeSet else { return false }
        return entries.contains { existing in
            guard let existingChangeSet = existing.verifiedChangeSet else { return false }
            return existingChangeSet.id == changeSet.id
                || existingChangeSet.authority.recordID == changeSet.authority.recordID
                || existingChangeSet.inversePayload.blobID == changeSet.inversePayload.blobID
        }
    }

    // MARK: - Checked undo engine integration

    /// The owner-private store backing verified change sets. Exposed read-only
    /// so capture paths (and tests) can write authority/payload pairs.
    var checkedUndoPrivateStore: AgentHistoryPrivateStore { privateStore }

    /// Test-only: replaces the in-store entry with a matching id without
    /// going through `append`. Used to inject tampered projections and
    /// corrupted payload references for the #1183 safety tests. Not for
    /// production use.
    func replaceEntryForTesting(_ entry: AgentHistoryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        }
    }

    /// Effective undo availability for an entry, consulting the owner-private
    /// authority. The UI reads this rather than the pure
    /// `entry.undoAvailability`, because confirming the engine can act requires
    /// filesystem access the entry does not have.
    ///
    /// Returns `.available` only for a verified entry whose change set passes
    /// the pure preflight AND owns an unconsumed authority record bound to the
    /// current workspace. The per-file content divergence check still runs at
    /// `revert` time and may refuse an `.available` entry.
    func effectiveUndoAvailability(for entry: AgentHistoryEntry) -> AgentHistoryUndoAvailability {
        switch entry.undoAvailability {
        case .available:
            return .available
        case .unavailable(.checkedUndoEngineUnavailable):
            return checkedUndoAvailabilityByEntryID[entry.id]
                ?? .unavailable(.checkedUndoEngineUnavailable)
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    /// Refreshes owner-private authority state without blocking MainActor.
    /// Safe to call when presenting Agent History and after tests deliberately
    /// mutate the injected private store.
    func refreshCheckedUndoAvailability() async {
        guard let root = projectRoot else {
            checkedUndoAvailabilityByEntryID = [:]
            return
        }
        let candidates = entries.compactMap { entry -> (UUID, VerifiedAgentChangeSet)? in
            guard case .unavailable(.checkedUndoEngineUnavailable) = entry.undoAvailability,
                  let changeSet = entry.verifiedChangeSet else {
                return nil
            }
            return (entry.id, changeSet)
        }
        let privateStore = privateStore
        let refreshed = await runOnBackground(qos: .utility) {
            Dictionary(uniqueKeysWithValues: candidates.map { entryID, changeSet in
                let availability: AgentHistoryUndoAvailability
                if let manifest = privateStore.loadAuthority(
                    recordID: changeSet.authority.recordID
                ) {
                    if manifest.consumed {
                        availability = .unavailable(.authorityConsumed)
                    } else if AgentHistoryContentHash.canonicalRootPath(root)
                        == manifest.resolvedRootPath,
                        let identity = AgentHistoryContentHash.rootIdentity(root),
                        identity.device == manifest.rootDevice,
                        identity.inode == manifest.rootInode {
                        availability = .available
                    } else {
                        availability = .unavailable(.checkedUndoEngineUnavailable)
                    }
                } else {
                    availability = .unavailable(.authorityRecordMissing)
                }
                return (entryID, availability)
            })
        }
        checkedUndoAvailabilityByEntryID = refreshed
    }

    /// Discovers owner-private recovery directories off-main and publishes
    /// only records related to this project. Corrupt records have no trusted
    /// identity, so they stay visible rather than being silently filtered.
    func refreshRecoveryNotices() async {
        let generation = recoveryRefreshGeneration
        guard let root = projectRoot else {
            recoveryNotices = []
            return
        }

        let canonicalRootPath = AgentHistoryContentHash.canonicalRootPath(root)
        let rootIdentity = AgentHistoryContentHash.rootIdentity(root)
        let historyEntryIDs = Set(entries.map(\.id))
        let changeSets = entries.compactMap(\.verifiedChangeSet)
        let changeSetIDs = Set(changeSets.map(\.id))
        let authorityRecordIDs = Set(
            changeSets.map(\.authority.recordID)
        )
        let privateStore = privateStore
        let discovered = await runOnBackground(qos: .utility) {
            privateStore.discoverRecoveryRecords()
        }

        guard generation == recoveryRefreshGeneration else { return }
        recoveryNotices = discovered
            .filter { record in
                guard let manifest = record.manifest else {
                    // There is no trusted metadata to attribute a corrupt
                    // directory. Keeping it visible is the fail-closed choice.
                    return true
                }
                let matchesRoot = manifest.resolvedRootPath
                        == canonicalRootPath
                    && rootIdentity?.device == manifest.rootDevice
                    && rootIdentity?.inode == manifest.rootInode
                return matchesRoot
                    || historyEntryIDs.contains(manifest.historyEntryID)
                    || changeSetIDs.contains(manifest.changeSetID)
                    || authorityRecordIDs.contains(manifest.authorityRecordID)
            }
            .sorted { first, second in
                let firstDate = first.manifest?.createdAt ?? .distantFuture
                let secondDate = second.manifest?.createdAt ?? .distantFuture
                if firstDate != secondDate {
                    return firstDate > secondDate
                }
                return first.directoryName < second.directoryName
            }
    }

    // MARK: - Capture (verified change sets)

    /// Captures a verified change set: writes the owner-private authority
    /// manifest and inverse payload, then appends a verified entry to the
    /// project log. This is the entry point a future trusted provenance
    /// pipeline (and tests) use to make an entry reversible.
    ///
    /// `beforeContents` maps each modified/deleted path to its exact pre-write
    /// bytes; created files omit an entry (their inverse is deletion).
    func recordVerifiedChangeSet(
        agentType: AgentType,
        changes: [AgentHistoryRecordedFileChange],
        beforeContents: [String: Data],
        provenance: AgentHistoryWriterProvenance,
        workspace: AgentHistoryWorkspaceIdentity
    ) async throws -> AgentHistoryEntry {
        let sessionID = provenance.sessionID
        guard let root = projectRoot else {
            throw AgentHistoryCaptureError.projectRootUnavailable
        }
        guard !loggedSessionIDs.contains(sessionID) else {
            throw AgentHistoryCaptureError.identityCollision
        }
        let privateStore = privateStore
        let agentTypeIdentifier = agentType.stableIdentifier
        let request = AgentHistoryCaptureRequest(
            agentTypeIdentifier: agentTypeIdentifier,
            changes: changes,
            beforeContents: beforeContents,
            provenance: provenance,
            workspace: workspace,
            root: root
        )
        let entry = try await runOnBackground {
            try Self.captureVerifiedEntry(
                request: request,
                privateStore: privateStore
            )
        }

        // Another capture for the same identity may have completed while the
        // background validation was running. Never orphan private authority.
        guard !loggedSessionIDs.contains(sessionID),
              !entries.contains(where: { $0.id == entry.id }),
              !hasPrivateIdentityCollision(entry) else {
            if let changeSet = entry.verifiedChangeSet {
                await runOnBackground(qos: .utility) {
                    privateStore.removeAuthority(recordID: changeSet.authority.recordID)
                    privateStore.removePayload(blobID: changeSet.inversePayload.blobID)
                }
            }
            throw AgentHistoryCaptureError.identityCollision
        }
        append(entry)
        checkedUndoAvailabilityByEntryID[entry.id] = .available
        return entry
    }

    nonisolated private static func captureVerifiedEntry(
        request: AgentHistoryCaptureRequest,
        privateStore: AgentHistoryPrivateStore
    ) throws -> AgentHistoryEntry {
        let agentTypeIdentifier = request.agentTypeIdentifier
        let changes = request.changes
        let beforeContents = request.beforeContents
        let provenance = request.provenance
        let workspace = request.workspace
        let root = request.root
        let expectedBeforePaths = Set(changes.compactMap { change in
            switch change.operation {
            case .modify, .delete: change.relativePath
            case .create, .rename, .symlink, .unsupported: nil
            }
        })
        guard Set(beforeContents.keys) == expectedBeforePaths else {
            throw AgentHistoryCaptureError.invalidContract
        }
        for change in changes {
            switch change.operation {
            case .modify, .delete:
                guard let before = change.before,
                      let bytes = beforeContents[change.relativePath],
                      UInt64(bytes.count) == before.byteCount,
                      AgentHistoryContentHash.sha256Hex(bytes) == before.contentSHA256 else {
                    throw AgentHistoryCaptureError.invalidContract
                }
            case .create:
                guard change.before == nil else {
                    throw AgentHistoryCaptureError.invalidContract
                }
            case .rename, .symlink, .unsupported:
                throw AgentHistoryCaptureError.invalidContract
            }
        }

        let currentHead = AgentHistoryContentHash.headOID(in: root)
        let currentIndex = AgentHistoryContentHash.indexSHA256(in: root)
        guard currentHead == workspace.headOID,
              currentIndex == workspace.indexSHA256,
              let rootIdentity = AgentHistoryContentHash.rootIdentity(root) else {
            throw AgentHistoryCaptureError.workspaceChanged
        }
        let safeWorkspace = try AgentHistorySafeWorkspace(
            root: root,
            expectedDevice: rootIdentity.device,
            expectedInode: rootIdentity.inode
        )
        for change in changes {
            guard try safeWorkspace.matchesCurrentState(change: change) else {
                throw AgentHistoryCaptureError.currentContentMismatch
            }
        }

        let entryID = UUID()
        let changeSetID = UUID()
        let recordID = UUID()
        let blobID = UUID()
        let capturedAt = Date()
        let payload = AgentHistoryInversePayload(
            formatVersion: AgentHistoryInversePayload.currentFormatVersion,
            entries: changes.map {
                AgentHistoryInverseFileEntry(
                    relativePath: $0.relativePath,
                    operation: $0.operation,
                    beforeContent: beforeContents[$0.relativePath],
                    permissions: $0.before?.permissions
                )
            }
        )
        let encodedPayload = try privateStore.encodePayload(payload)
        let payloadReference = AgentHistoryInversePayloadReference(
            storage: .applicationSupport,
            blobID: blobID,
            formatVersion: AgentHistoryInversePayloadReference.currentFormatVersion,
            byteCount: UInt64(encodedPayload.count),
            sha256: AgentHistoryContentHash.sha256Hex(encodedPayload)
        )
        let digestPlaceholder = String(repeating: "0", count: 64)
        let provisional = VerifiedAgentChangeSet(
            id: changeSetID,
            historyEntryID: entryID,
            schemaVersion: VerifiedAgentChangeSet.currentSchemaVersion,
            capturedAt: capturedAt,
            provenance: provenance,
            workspace: workspace,
            changes: changes,
            authority: AgentHistoryPrivateAuthorityReference(
                storage: .applicationSupport,
                recordID: recordID,
                manifestFormatVersion:
                    AgentHistoryPrivateAuthorityReference.currentManifestFormatVersion,
                canonicalContractSHA256: digestPlaceholder
            ),
            inversePayload: payloadReference
        )
        let digest = AgentHistoryCheckedUndoEngine.canonicalProjectionDigest(of: provisional)
        let changeSet = VerifiedAgentChangeSet(
            id: provisional.id,
            historyEntryID: provisional.historyEntryID,
            schemaVersion: provisional.schemaVersion,
            capturedAt: provisional.capturedAt,
            provenance: provisional.provenance,
            workspace: provisional.workspace,
            changes: provisional.changes,
            authority: AgentHistoryPrivateAuthorityReference(
                storage: .applicationSupport,
                recordID: recordID,
                manifestFormatVersion:
                    AgentHistoryPrivateAuthorityReference.currentManifestFormatVersion,
                canonicalContractSHA256: digest
            ),
            inversePayload: payloadReference
        )
        let entry = AgentHistoryEntry(
            id: entryID,
            sessionID: provenance.sessionID,
            agentTypeRaw: agentTypeIdentifier,
            startedAt: provenance.firstEventSequence > 0
                ? Date(timeIntervalSince1970: TimeInterval(provenance.firstEventSequence))
                : capturedAt,
            endedAt: capturedAt,
            affectedFiles: changes.map(\.relativePath),
            attribution: .verified,
            verifiedChangeSet: changeSet,
            summary: changes.count == 1 ? "1 file" : "\(changes.count) files"
        )
        guard AgentHistoryUndoPreflight.evaluate(entry)
            == .readyForPrivateAuthorityValidation else {
            throw AgentHistoryCaptureError.invalidContract
        }

        let payloadInfo = try privateStore.writePayload(payload, blobID: blobID)
        guard payloadInfo.sha256 == payloadReference.sha256,
              payloadInfo.byteCount == payloadReference.byteCount else {
            privateStore.removePayload(blobID: blobID)
            throw AgentHistoryCaptureError.invalidContract
        }
        let manifest = AgentHistoryAuthorityManifest(
            recordID: recordID,
            manifestFormatVersion: AgentHistoryAuthorityManifest.currentManifestFormatVersion,
            changeSetID: changeSetID,
            historyEntryID: entryID,
            sessionID: provenance.sessionID,
            privateWorkspaceID: workspace.privateWorkspaceID,
            resolvedRootPath: AgentHistoryContentHash.canonicalRootPath(root),
            rootDevice: rootIdentity.device,
            rootInode: rootIdentity.inode,
            capturedHeadOID: currentHead,
            capturedIndexSHA256: currentIndex,
            canonicalContractSHA256: digest,
            consumed: false,
            capturedAt: capturedAt
        )
        do {
            try privateStore.writeAuthority(manifest)
        } catch {
            privateStore.removePayload(blobID: blobID)
            throw error
        }
        do {
            guard AgentHistoryContentHash.headOID(in: root) == currentHead,
                  AgentHistoryContentHash.indexSHA256(in: root) == currentIndex else {
                throw AgentHistoryCaptureError.workspaceChanged
            }
            for change in changes {
                guard try safeWorkspace.matchesCurrentState(change: change) else {
                    throw AgentHistoryCaptureError.currentContentMismatch
                }
            }
        } catch {
            privateStore.removeAuthority(recordID: recordID)
            privateStore.removePayload(blobID: blobID)
            throw error
        }
        return entry
    }

    // MARK: - Verified undo preview (#1237)

    /// Prepares a read-only, verified undo preview for an entry without
    /// mutating the workspace. Loads the owner-private authority and inverse
    /// payload, runs the engine's pure preflight + read-only content-divergence
    /// check, and returns a display-only diff model — or a structured reason
    /// the undo must stay disabled.
    ///
    /// The preview is stale-able: the caller must `revalidateVerifiedUndoPreview`
    /// immediately before applying, and the engine re-checks everything under
    /// its private lock during `revert`.
    func prepareVerifiedUndoPreview(
        for entry: AgentHistoryEntry
    ) async -> AgentHistoryUndoPreviewResult {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return .unavailable(.entryNotFound)
        }
        let current = entries[index]
        guard let changeSet = current.verifiedChangeSet,
              let root = projectRoot else {
            return .unavailable(.notEligible)
        }
        let privateStore = privateStore
        return await runOnBackground {
            guard let manifest = privateStore.loadAuthority(
                recordID: changeSet.authority.recordID
            ) else {
                return AgentHistoryUndoPreviewResult.unavailable(
                    .authorityRecordMissing
                )
            }
            guard let payload = privateStore.loadPayload(
                blobID: changeSet.inversePayload.blobID,
                expectedSHA256: changeSet.inversePayload.sha256,
                expectedByteCount: changeSet.inversePayload.byteCount,
                expectedFormatVersion: changeSet.inversePayload.formatVersion
            ) else {
                return AgentHistoryUndoPreviewResult.unavailable(
                    .inversePayloadMissing
                )
            }
            return AgentHistoryUndoPreview.prepare(
                entry: current,
                changeSet: changeSet,
                payload: payload,
                root: root,
                manifest: manifest
            )
        }
    }

    /// Revalidates an already-prepared preview immediately before applying
    /// Undo. Returns `.available` only if the workspace still matches the
    /// recorded state; any race fails closed and disables the Undo button.
    func revalidateVerifiedUndoPreview(
        for entry: AgentHistoryEntry
    ) async -> AgentHistoryUndoPreviewResult {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return .unavailable(.entryNotFound)
        }
        let current = entries[index]
        guard let changeSet = current.verifiedChangeSet,
              let root = projectRoot else {
            return .unavailable(.notEligible)
        }
        let privateStore = privateStore
        return await runOnBackground {
            guard let manifest = privateStore.loadAuthority(
                recordID: changeSet.authority.recordID
            ) else {
                return AgentHistoryUndoPreviewResult.unavailable(
                    .authorityRecordMissing
                )
            }
            return AgentHistoryUndoPreview.revalidate(
                entry: current,
                changeSet: changeSet,
                root: root,
                manifest: manifest
            )
        }
    }

    // MARK: - Revert

    /// Safely reverts an entry. Heuristic/ambiguous entries and verified
    /// entries without a checked inverse change set are refused before any
    /// mutation. Verified entries that pass the engine (private authority,
    /// projection integrity, workspace-state, and per-file divergence checks)
    /// have only their recorded before-bytes restored, leaving unrelated edits
    /// byte-for-byte intact. A partial apply is rolled back from a backup.
    ///
    /// - Parameter entry: The entry to revert. Compared by `id` against
    ///   `entries`; passing a stale copy is safe (no-op if not found).
    func revert(entry: AgentHistoryEntry) async -> AgentHistoryRevertResult {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return AgentHistoryRevertResult(allSucceeded: false, fileResults: [])
        }

        // Never revert an already-reverted entry.
        guard !entries[index].reverted else {
            return AgentHistoryRevertResult(allSucceeded: false, fileResults: [])
        }

        switch entries[index].undoAvailability {
        case .available:
            // Defend in depth: the pure property should never return this.
            return AgentHistoryRevertResult(
                allSucceeded: false,
                fileResults: [],
                blockedReason: .checkedUndoEngineUnavailable
            )
        case .unavailable(.checkedUndoEngineUnavailable):
            // Structurally ready — attempt the checked engine path.
            return await runCheckedUndo(at: index)
        case .unavailable(let reason):
            return AgentHistoryRevertResult(
                allSucceeded: false,
                fileResults: [],
                blockedReason: reason
            )
        }
    }

    /// Runs the checked undo engine for a structurally-ready entry and applies
    /// the result to the entry/log.
    private func runCheckedUndo(at index: Int) async -> AgentHistoryRevertResult {
        let entry = entries[index]
        guard let changeSet = entry.verifiedChangeSet,
              let root = projectRoot else {
            return AgentHistoryRevertResult(
                allSucceeded: false,
                fileResults: [],
                blockedReason: .checkedUndoEngineUnavailable
            )
        }
        let privateStore = privateStore
        let result = await runOnBackground {
            do {
                return try privateStore.withAuthorityLock(
                    recordID: changeSet.authority.recordID
                ) {
                    guard let manifest = privateStore.loadAuthority(
                        recordID: changeSet.authority.recordID
                    ) else {
                        return AgentHistoryRevertResult(
                            allSucceeded: false,
                            fileResults: [],
                            blockedReason: .authorityRecordMissing
                        )
                    }
                    if let blocked = AgentHistoryCheckedUndoEngine.preflight(
                        entry: entry,
                        changeSet: changeSet,
                        currentRoot: root,
                        manifest: manifest
                    ) {
                        return AgentHistoryRevertResult(
                            allSucceeded: false,
                            fileResults: [],
                            blockedReason: Self.mapEngineBlock(blocked)
                        )
                    }
                    guard let payload = privateStore.loadPayload(
                        blobID: changeSet.inversePayload.blobID,
                        expectedSHA256: changeSet.inversePayload.sha256,
                        expectedByteCount: changeSet.inversePayload.byteCount,
                        expectedFormatVersion: changeSet.inversePayload.formatVersion
                    ) else {
                        return AgentHistoryRevertResult(
                            allSucceeded: false,
                            fileResults: [],
                            blockedReason: .inversePayloadMissing
                        )
                    }
                    guard let backup = try? privateStore.createRecoveryBackup(
                        recordID: changeSet.authority.recordID
                    ) else {
                        return AgentHistoryRevertResult(
                            allSucceeded: false,
                            fileResults: [],
                            blockedReason: .checkedUndoEngineUnavailable
                        )
                    }
                    let checked = AgentHistoryCheckedUndoEngine.apply(
                        changeSet: changeSet,
                        payload: payload,
                        context: AgentHistoryCheckedUndoContext(
                            root: root,
                            backup: backup,
                            manifest: manifest,
                            privateStore: privateStore
                        )
                    )
                    return AgentHistoryRevertResult(
                        allSucceeded: checked.allSucceeded,
                        fileResults: [],
                        blockedReason: checked.blockedReason.map(Self.mapEngineBlock),
                        checkedOutcomes: checked.outcomes,
                        recoveryBackupPath: checked.recoveryBackupPath,
                        recoveryQuarantinePaths:
                            checked.recoveryQuarantinePaths
                    )
                }
            } catch {
                return AgentHistoryRevertResult(
                    allSucceeded: false,
                    fileResults: [],
                    blockedReason: .checkedUndoEngineUnavailable
                )
            }
        }

        // The background transaction is single-use under the private lock. Only
        // its successful caller may update the observable projection.
        if result.allSucceeded,
           let currentIndex = entries.firstIndex(where: { $0.id == entry.id }),
           !entries[currentIndex].reverted {
            entries[currentIndex].reverted = true
            checkedUndoAvailabilityByEntryID[entry.id] = .unavailable(.authorityConsumed)
            persist()
        } else if let blockedReason = result.blockedReason {
            checkedUndoAvailabilityByEntryID[entry.id] = .unavailable(blockedReason)
        }
        await refreshRecoveryNotices()
        return result
    }

    /// Maps an engine block reason to the public UI-level unavailable reason.
    nonisolated private static func mapEngineBlock(
        _ reason: AgentHistoryEngineBlockReason
    ) -> AgentHistoryUndoUnavailableReason {
        switch reason {
        case .authorityRecordMissing: .authorityRecordMissing
        case .authorityConsumed: .authorityConsumed
        case .workspaceRootMismatch, .workspaceGitStateChanged: .workspaceChanged
        case .projectionTampered: .invalidVerifiedReversibleChangeSet
        case .currentContentDiverged: .currentContentDiverged
        case .inversePayloadMissing: .inversePayloadMissing
        case .fileSystemError, .applyFailed: .currentContentDiverged
        }
    }

    // MARK: - Persistence

    /// Schedules an atomic write of the current `entries` to disk via the
    /// nonisolated writer. Fire-and-forget from the main actor.
    private func persist() {
        writer.persist(snapshot: entries, root: projectRoot)
    }

    /// Blocks the calling (main) thread until every pending disk write has
    /// completed. Called from `applicationWillTerminate` so a session finalized
    /// at quit is guaranteed to reach `.pine/agent-log.json` before the OS
    /// reclaims the process — without this the feature's core durability
    /// promise ("a finished agent run is never lost") would be racy.
    func flush() {
        writer.flush()
    }

    // MARK: - Codable helpers

    /// Builds a decoder matching the encoder (ISO8601 dates, so the long-lived
    /// `.pine/agent-log.json` is human-readable and portable). Both sides MUST
    /// use the same date strategy or a round-trip silently fails to decode and
    /// the log appears empty on reload.
    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Builds the matching encoder.
    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - Identity quarantine

    /// Removes every row participating in an identity collision. Keeping the
    /// first row would make project-controlled JSON ordering an authority
    /// decision; quarantining the complete collision set stays fail-closed.
    private static func quarantiningDuplicateIdentities(
        _ decoded: [AgentHistoryEntry]
    ) -> [AgentHistoryEntry] {
        let changeSets = decoded.compactMap(\.verifiedChangeSet)
        let duplicateEntryIDs = duplicateValues(decoded.map(\.id))
        let duplicateSessionIDs = duplicateValues(decoded.map(\.sessionID))
        let duplicateChangeSetIDs = duplicateValues(changeSets.map(\.id))
        let duplicateAuthorityIDs = duplicateValues(changeSets.map(\.authority.recordID))
        let duplicatePayloadIDs = duplicateValues(changeSets.map(\.inversePayload.blobID))

        let filtered = decoded.filter { entry in
            guard !duplicateEntryIDs.contains(entry.id),
                  !duplicateSessionIDs.contains(entry.sessionID) else {
                return false
            }
            guard let changeSet = entry.verifiedChangeSet else { return true }
            return !duplicateChangeSetIDs.contains(changeSet.id)
                && !duplicateAuthorityIDs.contains(changeSet.authority.recordID)
                && !duplicatePayloadIDs.contains(changeSet.inversePayload.blobID)
        }

        if filtered.count != decoded.count {
            NSLog(
                "AgentHistoryStore: quarantined \(decoded.count - filtered.count) "
                    + "entries with duplicate identities"
            )
        }
        return filtered
    }

    private static func duplicateValues<Value: Hashable>(_ values: [Value]) -> Set<Value> {
        var seen: Set<Value> = []
        var duplicates: Set<Value> = []
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates
    }

    // MARK: - Path safety

    /// Validates that a relative path is safe to record and later revert: it
    /// must be relative (not absolute) and must not escape the project root via
    /// `..` components. Rejects empty paths too.
    static func isValidRelativePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Absolute paths are rejected outright.
        guard trimmed.first != "/" else { return false }
        // Reject any traversal component. Splitting on "/" matches both "../x"
        // and "a/../../b".
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains("..")
    }

    /// Builds a default summary when the caller did not supply one.
    private static func defaultSummary(fileCount: Int) -> String {
        fileCount == 1 ? "1 file" : "\(fileCount) files"
    }
}

// MARK: - AgentHistoryLogWriter

/// Serial, off-main writer for `.pine/agent-log.json`.
///
/// `nonisolated` (not `@MainActor`) because it owns a background
/// `DispatchQueue` — the canonical Pine pattern for background-queue owners
/// (see `FileSystemWatcher`, and issue #693 / the `check_nonisolated.py`
/// guard). `AgentHistoryStore` is `@MainActor` and observable, so it cannot
/// itself own the queue without tripping the guard's crash-class detector.
/// Instead it hands this writer immutable `[AgentHistoryEntry]` snapshots.
///
/// Writes are atomic (temp file + `FileManager.replaceItem`) so a crash
/// mid-write never leaves a truncated log. The serial queue guarantees writes
/// land in submission order, so the last snapshot for a burst always wins —
/// sufficient for this low-frequency log (written on session finalize / revert,
/// not on every keystroke).
nonisolated final class AgentHistoryLogWriter {
    private let writeQueue = DispatchQueue(label: "com.pine.agent-history", qos: .utility)

    /// Schedules an atomic write of `snapshot` to `<root>/.pine/agent-log.json`.
    /// A `nil` root (no project open) is a no-op — the in-memory log suffices.
    func persist(snapshot: [AgentHistoryEntry], root: URL?) {
        writeQueue.async { [weak self] in
            self?.write(snapshot: snapshot, root: root)
        }
    }

    /// Blocks the calling thread until all queued writes have completed. Used
    /// on app termination to guarantee durability. Safe because the queue never
    /// calls back onto its own thread (writes are fire-and-forget from main).
    func flush() {
        writeQueue.sync {}
    }

    private func write(snapshot: [AgentHistoryEntry], root: URL?) {
        guard let root else { return }
        let pineDir = root.appendingPathComponent(".pine", isDirectory: true)
        let logURL = pineDir.appendingPathComponent("agent-log.json", isDirectory: false)

        guard let data = try? AgentHistoryStore.makeEncoder().encode(snapshot) else { return }

        // Create .pine/ if missing (the store may persist after a fresh clone).
        if !FileManager.default.fileExists(atPath: pineDir.path) {
            do {
                try FileManager.default.createDirectory(at: pineDir, withIntermediateDirectories: true)
            } catch {
                NSLog("AgentHistoryLogWriter: failed to create .pine during persist. \(error.localizedDescription)")
                return
            }
        }

        // Atomic write: temp file in the same directory, then replace the
        // destination so a crash mid-write never leaves a truncated log.
        let tempURL = pineDir.appendingPathComponent(".agent-log.json.tmp", isDirectory: false)
        do {
            try data.write(to: tempURL, options: [.atomic])
            if FileManager.default.fileExists(atPath: logURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    logURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: tempURL, to: logURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            NSLog("AgentHistoryLogWriter: failed to persist agent-log.json. \(error.localizedDescription)")
        }
    }
}
