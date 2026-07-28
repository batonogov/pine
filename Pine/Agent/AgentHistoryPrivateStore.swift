//
//  AgentHistoryPrivateStore.swift
//  Pine
//
//  Owner-only storage for the checked Agent History undo engine (#1183).
//
//  The project log (`.pine/agent-log.json`) is a portable, content-free
//  *projection*: it lives inside the project and a hostile project could
//  rewrite it. The actual authority — which workspace a verified change set is
//  bound to, the exact captured Git state, and the inverse payload bytes —
//  lives here, under `~/Library/Application Support/Pine/AgentHistory/`, which
//  the project cannot write. A change set in the log authorizes nothing until
//  this private store confirms it owns a matching, unconsumed authority record.
//
//  All types are `nonisolated` value/enum types so they can cross the
//  `@MainActor` store boundary as immutable snapshots, mirroring the contract
//  layer in `AgentHistoryChangeSet.swift`.
//

import Darwin
import CryptoKit
import Foundation

// MARK: - Inverse payload

/// The reversible bytes for one recorded file change, stored outside the
/// project. For `.modify` and `.delete` this is the exact pre-write content; a
/// `.create` carries no content because its inverse removes the file.
nonisolated struct AgentHistoryInverseFileEntry: Codable, Equatable, Sendable {
    let relativePath: String
    let operation: AgentHistoryFileOperation
    /// Exact pre-write bytes. `nil` for `.create` (inverse = delete).
    let beforeContent: Data?
    /// POSIX permission bits to restore when the operation recreates a file.
    let permissions: UInt16?
}

/// Owner-private container of inverse bytes for one verified change set.
nonisolated struct AgentHistoryInversePayload: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let entries: [AgentHistoryInverseFileEntry]
}

// MARK: - Authority manifest

/// The owner-private authority record. This is the source of truth that
/// authorizes a checked undo: it binds a verified change set to one resolved
/// workspace, records the exact captured Git state, and tracks consumption so
/// a replayed entry cannot mutate the tree twice.
nonisolated struct AgentHistoryAuthorityManifest: Codable, Equatable, Sendable {
    static let currentManifestFormatVersion = 2

    /// Matches `AgentHistoryPrivateAuthorityReference.recordID`; the on-disk
    /// lookup key shared by the contract and the engine.
    let recordID: UUID
    let manifestFormatVersion: Int
    let changeSetID: UUID
    let historyEntryID: UUID
    let sessionID: UUID
    let privateWorkspaceID: UUID
    /// Canonical (symlink-resolved) absolute path of the workspace root at
    /// capture time. Machine-specific, so it lives here rather than in the
    /// portable project log.
    let resolvedRootPath: String
    /// Device/inode identity of the opened canonical workspace directory. A
    /// path string alone is insufficient because the directory can be renamed
    /// and replaced between capture and undo.
    let rootDevice: UInt64
    let rootInode: UInt64
    /// Git HEAD object ID at capture (`git rev-parse HEAD`), or the empty
    /// string for a repository with no commits yet.
    let capturedHeadOID: String
    /// SHA-256 of the `.git/index` bytes at capture, or the empty string when
    /// no index exists. Detects any staging change since capture.
    let capturedIndexSHA256: String
    /// Canonical projection digest captured at write time. The engine recomputes
    /// the digest from the log entry and refuses on mismatch, so a tampered
    /// project log cannot drive an authority record it does not match.
    let canonicalContractSHA256: String
    /// `true` once a checked undo has consumed this authority. A consumed
    /// record can never authorize a second mutation.
    var consumed: Bool
    let capturedAt: Date
}

// MARK: - Private store

/// Filesystem-backed, owner-only store for authority manifests and inverse
/// payload blobs.
///
/// `nonisolated` (like `AgentHistoryLogWriter`) so it can be owned by the
/// `@MainActor` store and called from `async` revert paths without crossing
/// actor isolation. All disk access is synchronous and bounded: manifests are
/// small JSON, payloads are proportional to recorded file size.
nonisolated final class AgentHistoryPrivateStore: @unchecked Sendable {
    private enum DirectoryName: String {
        case authorities
        case payloads
        case recovery
    }

    private static let maximumRecoveryRecordCount = 256
    private static let maximumRecoveryEntryCount = 4_096
    private static let maximumAuthorityManifestByteCount = 1_048_576
    private static let maximumRecoveryManifestByteCount = 1_048_576
    private static let maximumRecoveryMarkerByteCount = 16_384
    private static let maximumRecoveryMetadataByteCount = 262_144
    private static let maximumRecoveryContentByteCount: UInt64 =
        1_073_741_824
    private static let maximumWorkspaceArtifactScanCount = 16_384
    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    /// Base directory. Defaults to real Application Support; tests inject a
    /// temporary directory so they never touch the user's private data.
    private let baseDirectory: URL
    private let beforeConsume: (@Sendable () throws -> Void)?
    private let descriptorLock = NSLock()
    private var baseDescriptor: Int32?
    private var directoryDescriptors: [DirectoryName: Int32] = [:]

    init(
        baseDirectory: URL? = nil,
        beforeConsume: (@Sendable () throws -> Void)? = nil
    ) {
        // Preserve the physical spelling supplied by the caller. On macOS,
        // `standardizedFileURL` rewrites `/private/var` to the compatibility
        // symlink `/var`; the descriptor walk below must retain
        // `/private/var` so O_NOFOLLOW can reject actual path redirection
        // without rejecting the system temporary directory itself.
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory
        self.beforeConsume = beforeConsume
    }

    deinit {
        descriptorLock.withLock {
            for descriptor in directoryDescriptors.values {
                close(descriptor)
            }
            if let baseDescriptor {
                close(baseDescriptor)
            }
        }
    }

    /// Real production base: `~/Library/Application Support/Pine/AgentHistory/`.
    static var defaultBaseDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pine", isDirectory: true)
            .appendingPathComponent("AgentHistory", isDirectory: true)
    }

    // MARK: Authority

    /// Serializes every preflight/apply/consume transaction for one authority
    /// across Pine processes. Lock files live directly under the validated,
    /// owner-private base descriptor. Keeping the namespace at this stable
    /// anchor prevents a replaced child directory from splitting two store
    /// instances onto different lock inodes.
    func withAuthorityLock<Result>(
        recordID: UUID,
        _ operation: () throws -> Result
    ) throws -> Result {
        let base = try duplicateBaseDescriptor()
        defer { close(base) }
        let fileName = ".\(recordID.uuidString).authority.lock"
        let descriptor = openat(
            base,
            fileName,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        defer { close(descriptor) }

        try validateOwnerOnlyRegularFile(descriptor)
        guard fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        defer { flock(descriptor, LOCK_UN) }

        // A path replacement while waiting for flock must not let this caller
        // proceed under an orphaned inode while another process locks a new
        // file at the same name.
        var descriptorInfo = stat()
        var linkedInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              fstatat(
                base,
                fileName,
                &linkedInfo,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              (linkedInfo.st_mode & S_IFMT) == S_IFREG,
              descriptorInfo.st_uid == geteuid(),
              descriptorInfo.st_nlink == 1,
              UInt64(descriptorInfo.st_dev) == UInt64(linkedInfo.st_dev),
              UInt64(descriptorInfo.st_ino) == UInt64(linkedInfo.st_ino) else {
            throw AgentHistoryPrivateStoreError.untrustedStorage
        }
        return try operation()
    }

    /// Persists an authority manifest atomically. Each `recordID` is
    /// single-use: created exactly once at capture time and never overwritten.
    func writeAuthority(_ manifest: AgentHistoryAuthorityManifest) throws {
        let directory = try duplicateDirectoryDescriptor(.authorities)
        defer { close(directory) }
        let data = try AgentHistoryStore.makeEncoder().encode(manifest)
        try writeExclusive(
            data,
            named: authorityFileName(manifest.recordID),
            directory: directory
        )
    }

    /// Loads the authority manifest for `recordID`, or `nil` if absent. A
    /// corrupt manifest returns `nil` (fail closed) rather than throwing.
    func loadAuthority(recordID: UUID) -> AgentHistoryAuthorityManifest? {
        guard let directory = try? duplicateDirectoryDescriptor(.authorities) else {
            return nil
        }
        defer { close(directory) }
        return loadAuthority(recordID: recordID, directory: directory)
    }

    /// Marks the authority consumed so it can never authorize a second undo.
    func markConsumed(recordID: UUID) throws {
        try beforeConsume?()
        let directory = try duplicateDirectoryDescriptor(.authorities)
        defer { close(directory) }
        guard var manifest = loadAuthority(
            recordID: recordID,
            directory: directory
        ) else {
            throw AgentHistoryPrivateStoreError.authorityMissing
        }
        guard !manifest.consumed else {
            throw AgentHistoryPrivateStoreError.authorityAlreadyConsumed
        }
        manifest.consumed = true
        let destination = authorityFileName(recordID)
        let replacement = ".\(recordID.uuidString).\(UUID().uuidString).tmp"
        let encoded = try AgentHistoryStore.makeEncoder().encode(manifest)
        try writeExclusive(
            encoded,
            named: replacement,
            directory: directory
        )
        defer { unlinkat(directory, replacement, 0) }
        guard renameat(directory, replacement, directory, destination) == 0,
              fsync(directory) == 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        guard loadAuthority(
            recordID: recordID,
            directory: directory
        )?.consumed == true else {
            throw AgentHistoryPrivateStoreError.consumptionNotDurable
        }
    }

    // MARK: Payload

    /// Persists an inverse payload blob atomically and returns its SHA-256 and
    /// byte count for the contract reference.
    func writePayload(
        _ payload: AgentHistoryInversePayload,
        blobID: UUID
    ) throws -> (sha256: String, byteCount: UInt64) {
        let directory = try duplicateDirectoryDescriptor(.payloads)
        defer { close(directory) }
        let data = try encodePayload(payload)
        try writeExclusive(
            data,
            named: payloadFileName(blobID),
            directory: directory
        )
        return (
            sha256: AgentHistoryContentHash.sha256Hex(data),
            byteCount: UInt64(data.count)
        )
    }

    func encodePayload(_ payload: AgentHistoryInversePayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    /// Loads and integrity-checks the inverse payload for `blobID`. Returns
    /// `nil` when the blob is absent, corrupt, or fails its recorded
    /// SHA-256/size/format check.
    func loadPayload(
        blobID: UUID,
        expectedSHA256: String,
        expectedByteCount: UInt64,
        expectedFormatVersion: Int
    ) -> AgentHistoryInversePayload? {
        guard let directory = try? duplicateDirectoryDescriptor(.payloads) else {
            return nil
        }
        defer { close(directory) }
        guard let data = try? readExactOwnerOnlyRegularFile(
            named: payloadFileName(blobID),
            directory: directory,
            expectedByteCount: expectedByteCount
        ),
        !data.isEmpty,
        UInt64(data.count) == expectedByteCount,
        AgentHistoryContentHash.sha256Hex(data) == expectedSHA256,
        let payload = try? JSONDecoder().decode(
            AgentHistoryInversePayload.self,
            from: data
        ),
        payload.formatVersion == expectedFormatVersion else {
            return nil
        }
        return payload
    }

    /// Removes an authority record (used by capture cleanup and tests).
    func removeAuthority(recordID: UUID) {
        guard let directory = try? duplicateDirectoryDescriptor(.authorities) else {
            return
        }
        defer { close(directory) }
        if unlinkat(directory, authorityFileName(recordID), 0) == 0 {
            _ = fsync(directory)
        }
    }

    func removePayload(blobID: UUID) {
        guard let directory = try? duplicateDirectoryDescriptor(.payloads) else {
            return
        }
        defer { close(directory) }
        if unlinkat(directory, payloadFileName(blobID), 0) == 0 {
            _ = fsync(directory)
        }
    }

    // MARK: Recovery backup

    /// Creates and durably links an owner-private recovery directory beneath
    /// the cached `recovery/` descriptor. The returned object keeps both parent
    /// and child descriptors open for the complete undo transaction.
    func createRecoveryBackup(
        recordID: UUID
    ) throws -> AgentHistoryRecoveryBackup {
        let parent = try duplicateDirectoryDescriptor(.recovery)
        let name = "\(recordID.uuidString)-\(UUID().uuidString)"
        guard mkdirat(parent, name, 0o700) == 0 else {
            close(parent)
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        var keepDirectory = false
        defer {
            if !keepDirectory {
                unlinkat(parent, name, AT_REMOVEDIR)
                close(parent)
            }
        }
        let directory = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        var keepDescriptor = false
        defer {
            if !keepDescriptor {
                close(directory)
            }
        }
        var info = stat()
        guard fstat(directory, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              fchmod(directory, 0o700) == 0,
              fsync(parent) == 0 else {
            throw AgentHistoryPrivateStoreError.untrustedStorage
        }

        keepDirectory = true
        keepDescriptor = true
        return AgentHistoryRecoveryBackup(
            url: baseDirectory
                .appendingPathComponent(DirectoryName.recovery.rawValue, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true),
            name: name,
            parentDescriptor: parent,
            directoryDescriptor: directory,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    /// Discovers durable checked-undo recovery records without following any
    /// link from the owner-private store. Corrupt records remain visible as
    /// explicit notices instead of disappearing from the recovery UI.
    func discoverRecoveryRecords() -> [AgentHistoryRecoveryRecord] {
        let recoveryURL = baseDirectory.appendingPathComponent(
            DirectoryName.recovery.rawValue,
            isDirectory: true
        )
        guard let parent = try? duplicateDirectoryDescriptor(.recovery) else {
            return [corruptRecoveryRecord(
                name: DirectoryName.recovery.rawValue,
                path: recoveryURL.path,
                reason: .invalidRecoveryRoot
            )]
        }
        defer { close(parent) }

        let listing: (names: [String], exceededLimit: Bool)
        do {
            listing = try directoryEntryNames(
                directory: parent,
                limit: Self.maximumRecoveryRecordCount
            )
        } catch {
            return [corruptRecoveryRecord(
                name: DirectoryName.recovery.rawValue,
                path: recoveryURL.path,
                reason: .invalidRecoveryRoot
            )]
        }

        var records = listing.names.sorted().map { name in
            discoverRecoveryRecord(
                named: name,
                parent: parent,
                recoveryURL: recoveryURL
            )
        }
        if listing.exceededLimit {
            records.append(corruptRecoveryRecord(
                name: DirectoryName.recovery.rawValue,
                path: recoveryURL.path,
                reason: .enumerationLimitExceeded
            ))
        }
        return records
    }

    private func discoverRecoveryRecord(
        named name: String,
        parent: Int32,
        recoveryURL: URL
    ) -> AgentHistoryRecoveryRecord {
        let directoryPath = recoveryURL.appendingPathComponent(
            name,
            isDirectory: true
        ).path
        guard isSafeFileName(name) else {
            return corruptRecoveryRecord(
                name: name,
                path: directoryPath,
                reason: .untrustedDirectory
            )
        }

        let directory = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            return corruptRecoveryRecord(
                name: name,
                path: directoryPath,
                reason: .untrustedDirectory
            )
        }
        defer { close(directory) }

        guard recoveryDirectoryIsTrusted(
            directory,
            parent: parent,
            name: name
        ) else {
            return corruptRecoveryRecord(
                name: name,
                path: directoryPath,
                reason: .untrustedDirectory
            )
        }

        let manifest: AgentHistoryRecoveryManifest
        do {
            let data = try readBoundedOwnerOnlyRegularFile(
                named: "manifest.json",
                directory: directory,
                maximumByteCount: Self.maximumRecoveryManifestByteCount
            )
            manifest = try AgentHistoryStore.makeDecoder().decode(
                AgentHistoryRecoveryManifest.self,
                from: data
            )
            guard recoveryManifestIsValid(manifest, directoryName: name),
                  recoveryContentFilesAreTrusted(
                    manifest.entries,
                    directory: directory
                  ) else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
        } catch {
            let remainsTrusted = recoveryDirectoryIsTrusted(
                directory,
                parent: parent,
                name: name
            )
            return AgentHistoryRecoveryRecord(
                directoryName: name,
                directoryPath: directoryPath,
                manifest: nil,
                state: .corrupt(
                    remainsTrusted ? .invalidManifest : .untrustedDirectory
                ),
                recoveryPaths: [],
                validatedPaths: remainsTrusted ? [directoryPath] : []
            )
        }

        var state: AgentHistoryRecoveryDiscoveryState
        do {
            state = try recoveryState(
                transactionID: manifest.transactionID,
                directory: directory
            )
        } catch {
            state = .corrupt(.invalidPhaseMarkers)
        }

        let directoryURL = recoveryURL.appendingPathComponent(
            name,
            isDirectory: true
        )
        var recoveryPaths: [String]
        do {
            recoveryPaths = try discoveredRecoveryPaths(
                directory: directory,
                directoryURL: directoryURL
            )
        } catch {
            state = corruptState(
                preserving: state,
                reason: .invalidRecoveryMetadata
            )
            recoveryPaths = privateRetainedPaths(
                directory: directory,
                directoryURL: directoryURL
            )
        }

        var workspaceArtifactPaths: [String] = []
        do {
            workspaceArtifactPaths = try discoveredWorkspaceArtifactPaths(
                manifest: manifest
            )
            recoveryPaths = uniqueSortedPaths(
                recoveryPaths + workspaceArtifactPaths
            )
        } catch {
            state = corruptState(
                preserving: state,
                reason: .invalidWorkspaceArtifacts
            )
        }
        let privateValidatedPaths = privateRetainedPaths(
            directory: directory,
            directoryURL: directoryURL
        )
        let validatedPaths = uniqueSortedPaths(
            [directoryPath] + privateValidatedPaths + workspaceArtifactPaths
        )

        guard recoveryDirectoryIsTrusted(
            directory,
            parent: parent,
            name: name
        ) else {
            return AgentHistoryRecoveryRecord(
                directoryName: name,
                directoryPath: directoryPath,
                manifest: manifest,
                state: .corrupt(.untrustedDirectory),
                recoveryPaths: recoveryPaths,
                workspaceArtifactPaths: workspaceArtifactPaths,
                validatedPaths: []
            )
        }
        return AgentHistoryRecoveryRecord(
            directoryName: name,
            directoryPath: directoryPath,
            manifest: manifest,
            state: state,
            recoveryPaths: recoveryPaths,
            workspaceArtifactPaths: workspaceArtifactPaths,
            validatedPaths: validatedPaths
        )
    }

    private func corruptRecoveryRecord(
        name: String,
        path: String,
        reason: AgentHistoryRecoveryCorruption
    ) -> AgentHistoryRecoveryRecord {
        AgentHistoryRecoveryRecord(
            directoryName: name,
            directoryPath: path,
            manifest: nil,
            state: .corrupt(reason),
            recoveryPaths: []
        )
    }

    // MARK: Recovery discovery helpers

    private func corruptState(
        preserving state: AgentHistoryRecoveryDiscoveryState,
        reason: AgentHistoryRecoveryCorruption
    ) -> AgentHistoryRecoveryDiscoveryState {
        if case .corrupt = state {
            return state
        }
        return .corrupt(reason)
    }

    private func recoveryManifestIsValid(
        _ manifest: AgentHistoryRecoveryManifest,
        directoryName: String
    ) -> Bool {
        guard manifest.formatVersion
                == AgentHistoryRecoveryManifest.currentFormatVersion,
              manifest.transactionID != Self.zeroUUID,
              manifest.authorityRecordID != Self.zeroUUID,
              manifest.historyEntryID != Self.zeroUUID,
              manifest.changeSetID != Self.zeroUUID,
              manifest.resolvedRootPath.hasPrefix("/"),
              !manifest.resolvedRootPath.utf8.contains(0),
              manifest.createdAt.timeIntervalSinceReferenceDate.isFinite,
              !manifest.entries.isEmpty,
              manifest.entries.count <= Self.maximumRecoveryEntryCount,
              directoryName.hasPrefix(
                "\(manifest.authorityRecordID.uuidString)-"
              ) else {
            return false
        }

        var paths = Set<String>()
        for (index, entry) in manifest.entries.enumerated() {
            guard isSafeRecoveryRelativePath(entry.relativePath),
                  paths.insert(entry.relativePath).inserted else {
                return false
            }
            if entry.existed {
                guard entry.permissions.map({ $0 <= 0o7777 }) == true,
                      entry.contentFile == "\(index).bin",
                      entry.byteCount != nil,
                      entry.contentSHA256.map(isCanonicalSHA256) == true else {
                    return false
                }
            } else if entry.permissions != nil
                        || entry.contentFile != nil
                        || entry.byteCount != nil
                        || entry.contentSHA256 != nil {
                return false
            }
        }
        return true
    }

    private func recoveryContentFilesAreTrusted(
        _ entries: [AgentHistoryRecoveryManifestEntry],
        directory: Int32
    ) -> Bool {
        var totalByteCount: UInt64 = 0
        for entry in entries {
            guard entry.existed,
                  let contentFile = entry.contentFile,
                  let byteCount = entry.byteCount,
                  let contentSHA256 = entry.contentSHA256,
                  byteCount <= Self.maximumRecoveryContentByteCount,
                  totalByteCount
                    <= Self.maximumRecoveryContentByteCount - byteCount,
                  recoveryContentFileIsTrusted(
                    named: contentFile,
                    expectedByteCount: byteCount,
                    expectedSHA256: contentSHA256,
                    directory: directory
                  ) else {
                if !entry.existed {
                    continue
                }
                return false
            }
            totalByteCount += byteCount
        }
        return true
    }

    private func recoveryContentFileIsTrusted(
        named name: String,
        expectedByteCount: UInt64,
        expectedSHA256: String,
        directory: Int32
    ) -> Bool {
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        do {
            try validateOwnerOnlyRegularFile(descriptor)
            var before = stat()
            guard fstat(descriptor, &before) == 0,
                  before.st_size >= 0,
                  UInt64(before.st_size) == expectedByteCount else {
                return false
            }

            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: false
            )
            var hasher = SHA256()
            var hashedByteCount: UInt64 = 0
            while hashedByteCount < expectedByteCount {
                let remaining = expectedByteCount - hashedByteCount
                let requested = Int(min(remaining, 65_536))
                guard let chunk = try handle.read(upToCount: requested),
                      !chunk.isEmpty else {
                    return false
                }
                hasher.update(data: chunk)
                hashedByteCount += UInt64(chunk.count)
            }
            guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else {
                return false
            }
            let digest = hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
            var after = stat()
            return digest == expectedSHA256
                && fstat(descriptor, &after) == 0
                && before.st_dev == after.st_dev
                && before.st_ino == after.st_ino
                && before.st_size == after.st_size
                && before.st_mode == after.st_mode
                && before.st_nlink == after.st_nlink
        } catch {
            return false
        }
    }

    private func recoveryState(
        transactionID: UUID,
        directory: Int32
    ) throws -> AgentHistoryRecoveryDiscoveryState {
        var phases = Set<AgentHistoryRecoveryPhase>()
        for phase in AgentHistoryRecoveryPhase.allCases {
            guard let data = try readOptionalBoundedOwnerOnlyRegularFile(
                named: phase.markerFileName,
                directory: directory,
                maximumByteCount: Self.maximumRecoveryMarkerByteCount
            ) else {
                continue
            }
            let marker = try AgentHistoryStore.makeDecoder().decode(
                AgentHistoryRecoveryPhaseMarker.self,
                from: data
            )
            guard marker.formatVersion
                    == AgentHistoryRecoveryPhaseMarker.currentFormatVersion,
                  marker.transactionID == transactionID,
                  marker.phase == phase,
                  marker.recordedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            phases.insert(phase)
        }

        guard phases.contains(.prepared) else {
            throw AgentHistoryPrivateStoreError.untrustedStorage
        }
        if phases.contains(.finalized) {
            guard phases.contains(.authorityConsumed) else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            return .finalized
        }
        if phases.contains(.authorityConsumed) {
            return .authorityConsumed
        }
        return .prepared
    }

    private func discoveredRecoveryPaths(
        directory: Int32,
        directoryURL: URL
    ) throws -> [String] {
        var paths = try privateRetainedPathsThrowing(
            directory: directory,
            directoryURL: directoryURL
        )
        if let data = try readOptionalBoundedOwnerOnlyRegularFile(
            named: "retained-quarantines.json",
            directory: directory,
            maximumByteCount: Self.maximumRecoveryMetadataByteCount
        ) {
            let metadata = try AgentHistoryStore.makeDecoder().decode(
                AgentHistoryRecoveryPathsManifest.self,
                from: data
            )
            guard metadata.formatVersion
                    == AgentHistoryRecoveryPathsManifest.currentFormatVersion,
                  metadata.recoveryPaths.count
                    <= Self.maximumRecoveryEntryCount,
                  metadata.recoveryPaths.allSatisfy({ path in
                      path.hasPrefix("/")
                          && path.utf8.count <= 4_096
                          && !path.utf8.contains(0)
                          && path.split(
                              separator: "/",
                              omittingEmptySubsequences: false
                          ).dropFirst().allSatisfy {
                              !$0.isEmpty && $0 != "." && $0 != ".."
                          }
                  }) else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            paths.append(contentsOf: metadata.recoveryPaths)
        }

        return uniqueSortedPaths(paths)
    }

    private func uniqueSortedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.sorted()
    }

    /// Inventories transaction-scoped workspace quarantine names that may
    /// survive a crash between a same-directory rename and the later move into
    /// owner-private recovery. Every lookup stays descriptor-relative to the
    /// root identity captured in the manifest and never follows a symlink.
    private func discoveredWorkspaceArtifactPaths(
        manifest: AgentHistoryRecoveryManifest
    ) throws -> [String] {
        guard let root = openValidatedRecoveryWorkspaceRoot(
            manifest: manifest
        ) else {
            return []
        }
        defer { close(root) }

        let parentPaths = Set(manifest.entries.map { entry in
            entry.relativePath
                .split(separator: "/", omittingEmptySubsequences: false)
                .dropLast()
                .joined(separator: "/")
        })
        var remainingScanCount = Self.maximumWorkspaceArtifactScanCount
        var artifactPaths: [String] = []
        for parentPath in parentPaths.sorted() {
            guard remainingScanCount > 0 else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            guard let parent = try openRecoveryWorkspaceParent(
                root: root,
                relativeParentPath: parentPath
            ) else {
                continue
            }
            defer { close(parent) }

            let listing = try directoryEntryNames(
                directory: parent,
                limit: remainingScanCount
            )
            guard !listing.exceededLimit else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            remainingScanCount -= listing.names.count
            for name in listing.names where workspaceArtifactName(
                name,
                matches: manifest.transactionID
            ) {
                var info = stat()
                guard fstatat(
                    parent,
                    name,
                    &info,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                (info.st_mode & S_IFMT) == S_IFREG,
                info.st_uid == geteuid(),
                info.st_nlink == 1 else {
                    throw AgentHistoryPrivateStoreError.untrustedStorage
                }
                artifactPaths.append(
                    workspaceArtifactPath(
                        rootPath: manifest.resolvedRootPath,
                        parentPath: parentPath,
                        name: name
                    )
                )
            }
        }
        return uniqueSortedPaths(artifactPaths)
    }

    private func openValidatedRecoveryWorkspaceRoot(
        manifest: AgentHistoryRecoveryManifest
    ) -> Int32? {
        let components = URL(
            fileURLWithPath: manifest.resolvedRootPath,
            isDirectory: true
        ).pathComponents.dropFirst()
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            return nil
        }

        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard current >= 0 else { return nil }
        for component in components {
            let next = openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            close(current)
            guard next >= 0 else { return nil }
            current = next
        }

        var info = stat()
        guard fstat(current, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              UInt64(info.st_dev) == manifest.rootDevice,
              UInt64(info.st_ino) == manifest.rootInode else {
            close(current)
            return nil
        }
        return current
    }

    private func openRecoveryWorkspaceParent(
        root: Int32,
        relativeParentPath: String
    ) throws -> Int32? {
        guard let duplicated = duplicate(root) else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        var current = duplicated
        for component in relativeParentPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            guard !component.isEmpty,
                  component != ".",
                  component != ".." else {
                close(current)
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            let next = openat(
                current,
                String(component),
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            let openError = errno
            close(current)
            guard next >= 0 else {
                if openError == ENOENT {
                    return nil
                }
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            current = next
        }
        return current
    }

    private func workspaceArtifactName(
        _ name: String,
        matches transactionID: UUID
    ) -> Bool {
        let transaction = transactionID.uuidString
        let prefixes = [
            ".pine-undo-\(transaction)-",
            ".pine-undo-new-\(transaction)-",
            ".pine-undo-original-\(transaction)-",
            ".pine-undo-rollback-\(transaction)-"
        ]
        return prefixes.contains { prefix in
            guard name.hasPrefix(prefix) else { return false }
            let suffix = String(name.dropFirst(prefix.count))
            return UUID(uuidString: suffix)?.uuidString == suffix
        }
    }

    private func workspaceArtifactPath(
        rootPath: String,
        parentPath: String,
        name: String
    ) -> String {
        var url = URL(fileURLWithPath: rootPath, isDirectory: true)
        if !parentPath.isEmpty {
            url.append(path: parentPath, directoryHint: .isDirectory)
        }
        url.append(path: name, directoryHint: .notDirectory)
        return url.path
    }

    private func privateRetainedPaths(
        directory: Int32,
        directoryURL: URL
    ) -> [String] {
        (try? privateRetainedPathsThrowing(
            directory: directory,
            directoryURL: directoryURL
        )) ?? []
    }

    private func privateRetainedPathsThrowing(
        directory: Int32,
        directoryURL: URL
    ) throws -> [String] {
        let listing = try directoryEntryNames(
            directory: directory,
            limit: Self.maximumRecoveryEntryCount
        )
        guard !listing.exceededLimit else {
            throw AgentHistoryPrivateStoreError.untrustedStorage
        }
        return try listing.names.compactMap { name in
            guard name.hasPrefix("workspace-retained-") else {
                return nil
            }
            guard isSafeFileName(name) else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            var info = stat()
            guard fstatat(
                directory,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == geteuid(),
            info.st_nlink == 1,
            (info.st_mode & 0o077) == 0 else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            return directoryURL.appendingPathComponent(
                name,
                isDirectory: false
            ).path
        }
    }

    private func recoveryDirectoryIsTrusted(
        _ directory: Int32,
        parent: Int32,
        name: String
    ) -> Bool {
        var openedInfo = stat()
        var linkedInfo = stat()
        return fstat(directory, &openedInfo) == 0
            && fstatat(
                parent,
                name,
                &linkedInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0
            && (openedInfo.st_mode & S_IFMT) == S_IFDIR
            && (linkedInfo.st_mode & S_IFMT) == S_IFDIR
            && openedInfo.st_uid == geteuid()
            && (openedInfo.st_mode & 0o077) == 0
            && openedInfo.st_dev == linkedInfo.st_dev
            && openedInfo.st_ino == linkedInfo.st_ino
    }

    private func directoryEntryNames(
        directory: Int32,
        limit: Int
    ) throws -> (names: [String], exceededLimit: Bool) {
        // dup(2) shares a directory stream offset with the cached descriptor.
        // Concurrent or repeated discovery would therefore observe EOF after
        // another scan. Opening "." creates an independent open-file
        // description while remaining anchored to the validated directory.
        let opened = openat(
            directory,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard opened >= 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        guard sameIdentity(directory, opened) else {
            close(opened)
            throw AgentHistoryPrivateStoreError.untrustedStorage
        }
        guard let stream = fdopendir(opened) else {
            let openError = errno
            close(opened)
            throw AgentHistoryPrivateStoreError.posixFailure(openError)
        }
        defer { closedir(stream) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    throw AgentHistoryPrivateStoreError.posixFailure(errno)
                }
                return (names, false)
            }
            let name = withUnsafePointer(
                to: &entry.pointee.d_name
            ) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            if names.count == limit {
                return (names, true)
            }
            names.append(name)
        }
    }

    private func readOptionalBoundedOwnerOnlyRegularFile(
        named name: String,
        directory: Int32,
        maximumByteCount: Int
    ) throws -> Data? {
        var info = stat()
        guard fstatat(
            directory,
            name,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        return try readBoundedOwnerOnlyRegularFile(
            named: name,
            directory: directory,
            maximumByteCount: maximumByteCount
        )
    }

    private func readBoundedOwnerOnlyRegularFile(
        named name: String,
        directory: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        defer { close(descriptor) }
        try validateOwnerOnlyRegularFile(descriptor)

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_size >= 0,
              UInt64(info.st_size) <= UInt64(maximumByteCount) else {
            throw AgentHistoryPrivateStoreError.untrustedStorage
        }
        return try AgentHistoryBoundedFileReader.readExact(
            descriptor: descriptor,
            expectedByteCount: UInt64(info.st_size)
        )
    }

    private func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
            && name.utf8.count <= 255
    }

    private func isSafeRecoveryRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.utf8.contains(0),
              path.utf8.count <= 4_096 else {
            return false
        }
        return path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    // MARK: Descriptor helpers

    private func duplicateDirectoryDescriptor(
        _ name: DirectoryName
    ) throws -> Int32 {
        let base = try duplicateBaseDescriptor()
        defer { close(base) }

        if let cached = descriptorLock.withLock({
            directoryDescriptors[name].flatMap { duplicate($0) }
        }) {
            defer { close(cached) }
            let linked = openat(
                base,
                name.rawValue,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard linked >= 0 else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            defer { close(linked) }
            try validateOwnerDirectory(linked)
            guard sameIdentity(cached, linked),
                  let duplicated = duplicate(cached) else {
                throw AgentHistoryPrivateStoreError.untrustedStorage
            }
            return duplicated
        }

        if mkdirat(base, name.rawValue, 0o700) != 0, errno != EEXIST {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        let opened = openat(
            base,
            name.rawValue,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard opened >= 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        var keepOpened = false
        defer {
            if !keepOpened {
                close(opened)
            }
        }
        try validateOwnerDirectory(opened)
        guard fchmod(opened, 0o700) == 0,
              fsync(base) == 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }

        return try descriptorLock.withLock {
            if let existing = directoryDescriptors[name] {
                guard sameIdentity(existing, opened) else {
                    throw AgentHistoryPrivateStoreError.untrustedStorage
                }
                guard let duplicated = duplicate(existing) else {
                    throw AgentHistoryPrivateStoreError.posixFailure(errno)
                }
                return duplicated
            }
            directoryDescriptors[name] = opened
            keepOpened = true
            guard let duplicated = duplicate(opened) else {
                throw AgentHistoryPrivateStoreError.posixFailure(errno)
            }
            return duplicated
        }
    }

    private func duplicateBaseDescriptor() throws -> Int32 {
        let opened = try openBaseDirectoryWithoutFollowingLinks()
        var keepOpened = false
        defer {
            if !keepOpened {
                close(opened)
            }
        }
        return try descriptorLock.withLock {
            if let existing = baseDescriptor {
                guard sameIdentity(existing, opened) else {
                    throw AgentHistoryPrivateStoreError.untrustedStorage
                }
                guard let duplicated = duplicate(existing) else {
                    throw AgentHistoryPrivateStoreError.posixFailure(errno)
                }
                return duplicated
            }
            baseDescriptor = opened
            keepOpened = true
            guard let duplicated = duplicate(opened) else {
                throw AgentHistoryPrivateStoreError.posixFailure(errno)
            }
            return duplicated
        }
    }

    /// Walks the absolute base path one component at a time with O_NOFOLLOW.
    /// This rejects an intermediate symlink instead of allowing Application
    /// Support storage to be redirected into a project workspace.
    private func openBaseDirectoryWithoutFollowingLinks() throws -> Int32 {
        let components = baseDirectory.pathComponents.dropFirst()
        guard baseDirectory.isFileURL,
              baseDirectory.path.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AgentHistoryPrivateStoreError.untrustedStorage
        }
        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        var descriptors = [root]
        defer {
            for descriptor in descriptors {
                close(descriptor)
            }
        }

        for component in components {
            var next = openat(
                descriptors[descriptors.count - 1],
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if next < 0, errno == ENOENT {
                let current = descriptors[descriptors.count - 1]
                guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else {
                    throw AgentHistoryPrivateStoreError.posixFailure(errno)
                }
                next = openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard next >= 0 else {
                let openError = errno
                // macOS reports ENOTDIR (rather than ELOOP) when
                // O_NOFOLLOW | O_DIRECTORY encounters an intermediate
                // symlink.
                if openError == ELOOP || openError == ENOTDIR {
                    throw AgentHistoryPrivateStoreError.untrustedStorage
                }
                throw AgentHistoryPrivateStoreError.posixFailure(openError)
            }
            descriptors.append(next)
        }

        let current = descriptors[descriptors.count - 1]
        try validateOwnerDirectory(current)
        guard fchmod(current, 0o700) == 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        return descriptors.removeLast()
    }

    private func loadAuthority(
        recordID: UUID,
        directory: Int32
    ) -> AgentHistoryAuthorityManifest? {
        guard let data = try? readBoundedOwnerOnlyRegularFile(
            named: authorityFileName(recordID),
            directory: directory,
            maximumByteCount: Self.maximumAuthorityManifestByteCount
        ),
        !data.isEmpty,
        let manifest = try? AgentHistoryStore.makeDecoder().decode(
            AgentHistoryAuthorityManifest.self,
            from: data
        ),
        manifest.recordID == recordID,
        manifest.manifestFormatVersion
            == AgentHistoryAuthorityManifest.currentManifestFormatVersion else {
            return nil
        }
        return manifest
    }

    private func authorityFileName(_ recordID: UUID) -> String {
        "\(recordID.uuidString).json"
    }

    private func payloadFileName(_ blobID: UUID) -> String {
        "\(blobID.uuidString).bin"
    }

    private func duplicate(_ descriptor: Int32) -> Int32? {
        let duplicated = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        return duplicated >= 0 ? duplicated : nil
    }

    private func sameIdentity(_ first: Int32, _ second: Int32) -> Bool {
        var firstInfo = stat()
        var secondInfo = stat()
        return fstat(first, &firstInfo) == 0
            && fstat(second, &secondInfo) == 0
            && UInt64(firstInfo.st_dev) == UInt64(secondInfo.st_dev)
            && UInt64(firstInfo.st_ino) == UInt64(secondInfo.st_ino)
    }

    private func validateOwnerDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw AgentHistoryPrivateStoreError.untrustedStorage
        }
    }

    private func validateOwnerOnlyRegularFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            throw AgentHistoryPrivateStoreError.untrustedStorage
        }
    }

    private func writeExclusive(
        _ data: Data,
        named name: String,
        directory: Int32
    ) throws {
        let descriptor = openat(
            directory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw AgentHistoryPrivateStoreError.authorityAlreadyExists
            }
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded {
                unlinkat(directory, name, 0)
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard fchmod(descriptor, 0o600) == 0,
              fsync(descriptor) == 0,
              fsync(directory) == 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        succeeded = true
    }

    private func readExactOwnerOnlyRegularFile(
        named name: String,
        directory: Int32,
        expectedByteCount: UInt64
    ) throws -> Data {
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        defer { close(descriptor) }
        try validateOwnerOnlyRegularFile(descriptor)
        return try AgentHistoryBoundedFileReader.readExact(
            descriptor: descriptor,
            expectedByteCount: expectedByteCount
        )
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw AgentHistoryPrivateStoreError.posixFailure(errno)
                }
                offset += written
            }
        }
    }
}

/// Open, descriptor-anchored recovery directory for one checked transaction.
/// It tracks the files written through it so successful cleanup cannot follow
/// a swapped path or accidentally remove an unrelated directory.
nonisolated final class AgentHistoryRecoveryBackup: @unchecked Sendable {
    let url: URL
    private let name: String
    private let parentDescriptor: Int32
    private let directoryDescriptor: Int32
    private let device: UInt64
    private let inode: UInt64
    private let namesLock = NSLock()
    private var writtenNames: [String] = []

    fileprivate init(
        url: URL,
        name: String,
        parentDescriptor: Int32,
        directoryDescriptor: Int32,
        device: UInt64,
        inode: UInt64
    ) {
        self.url = url
        self.name = name
        self.parentDescriptor = parentDescriptor
        self.directoryDescriptor = directoryDescriptor
        self.device = device
        self.inode = inode
    }

    deinit {
        close(directoryDescriptor)
        close(parentDescriptor)
    }

    var path: String { url.path }

    func writeExclusive(_ data: Data, named fileName: String) throws {
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded {
                unlinkat(directoryDescriptor, fileName, 0)
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard fchmod(descriptor, 0o600) == 0,
              fsync(descriptor) == 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
        succeeded = true
        namesLock.withLock { writtenNames.append(fileName) }
    }

    func synchronize() throws {
        guard fsync(directoryDescriptor) == 0 else {
            throw AgentHistoryPrivateStoreError.posixFailure(errno)
        }
    }

    /// Appends one durable transaction phase marker. O_EXCL makes every phase
    /// immutable: an interrupted process cannot rewrite history on restart.
    func markPhase(
        _ phase: AgentHistoryRecoveryPhase,
        transactionID: UUID,
        recordedAt: Date = Date()
    ) throws {
        let marker = AgentHistoryRecoveryPhaseMarker(
            formatVersion: AgentHistoryRecoveryPhaseMarker.currentFormatVersion,
            transactionID: transactionID,
            phase: phase,
            recordedAt: recordedAt
        )
        let data = try AgentHistoryStore.makeEncoder().encode(marker)
        try writeExclusive(data, named: phase.markerFileName)
        try synchronize()
    }

    func isDurablyLinked() -> Bool {
        var info = stat()
        return fstatat(
            parentDescriptor,
            name,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && UInt64(info.st_dev) == device
            && UInt64(info.st_ino) == inode
    }

    /// Moves a workspace inode into this owner-private recovery directory
    /// without copying or unlinking it. This preserves writes through file
    /// descriptors opened before checked undo while keeping normal recovery
    /// artifacts out of the user's working tree. Cross-volume moves fail
    /// closed; the caller then retains the same inode inside the workspace and
    /// reports a recovery conflict.
    func retainWorkspaceFile(
        sourceDirectory: Int32,
        sourceName: String,
        expectation: AgentHistoryRetainedFileExpectation
    ) -> AgentHistoryRecoveryRetentionResult {
        guard isDurablyLinked(),
              let expectedDevice = expectation.device,
              let expectedInode = expectation.inode,
              let expectedContentSHA256 = expectation.contentSHA256,
              let expectedByteCount = expectation.byteCount,
              let expectedPermissions = expectation.permissions else {
            return .failed(nil)
        }
        let retainedName = "workspace-retained-\(UUID().uuidString).bin"
        guard renameatx_np(
            sourceDirectory,
            sourceName,
            directoryDescriptor,
            retainedName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            return .failed(nil)
        }
        let retainedPath = url
            .appendingPathComponent(retainedName, isDirectory: false)
            .path
        namesLock.withLock { writtenNames.append(retainedName) }

        let descriptor = openat(
            directoryDescriptor,
            retainedName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return .failed(retainedPath)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              UInt64(info.st_dev) == expectedDevice,
              UInt64(info.st_ino) == expectedInode,
              UInt16(info.st_mode & 0o7777) == expectedPermissions,
              fsync(sourceDirectory) == 0,
              fsync(directoryDescriptor) == 0,
              isDurablyLinked() else {
            return .failed(retainedPath)
        }
        guard let data = try? AgentHistoryBoundedFileReader.readExact(
            descriptor: descriptor,
            expectedByteCount: expectedByteCount
        ),
              AgentHistoryContentHash.sha256Hex(data)
                == expectedContentSHA256 else {
            return .failed(retainedPath)
        }
        return .retained(retainedPath)
    }

    /// Removes only files created through this descriptor and then removes the
    /// exact directory entry. Returns false if any identity changed or cleanup
    /// could not be confirmed durable.
    func remove() -> Bool {
        guard isDurablyLinked() else { return false }
        let names = namesLock.withLock { writtenNames }
        for fileName in names {
            if unlinkat(directoryDescriptor, fileName, 0) != 0, errno != ENOENT {
                return false
            }
        }
        guard fsync(directoryDescriptor) == 0,
              unlinkat(parentDescriptor, name, AT_REMOVEDIR) == 0,
              fsync(parentDescriptor) == 0 else {
            return false
        }
        return true
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw AgentHistoryPrivateStoreError.posixFailure(errno)
                }
                offset += written
            }
        }
    }
}

// MARK: - Errors

enum AgentHistoryPrivateStoreError: Error, Equatable {
    case authorityAlreadyExists
    case authorityAlreadyConsumed
    case authorityMissing
    case payloadMissing
    case untrustedStorage
    case consumptionNotDurable
    case posixFailure(Int32)
}

nonisolated enum AgentHistoryRecoveryRetentionResult: Sendable, Equatable {
    case retained(String)
    case failed(String?)
}

nonisolated struct AgentHistoryRetainedFileExpectation: Sendable, Equatable {
    let device: UInt64?
    let inode: UInt64?
    let contentSHA256: String?
    let byteCount: UInt64?
    let permissions: UInt16?
}

/// Capture-path errors for recording a verified change set.
enum AgentHistoryCaptureError: Error, Equatable {
    case projectRootUnavailable
    case identityCollision
    case invalidContract
    case workspaceChanged
    case currentContentMismatch
}
