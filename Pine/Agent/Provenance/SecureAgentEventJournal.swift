//
//  SecureAgentEventJournal.swift
//  Pine
//
//  Descriptor-relative, owner-private journal used only by
//  AgentEventProvenanceStore (epic #933, storage slice).
//

import CryptoKit
import Darwin
import Foundation

nonisolated struct AgentEventJournalLoadedState: Sendable {
    let records: [StoredAgentEvent]
    let lastSequence: UInt64
    let streamWatermarks: [AgentEventStreamIdentity: UInt64]
    let recentIdentities: [AgentEventRecentIdentity]
}

/// Low-level file-descriptor owner.
///
/// The unchecked conformance is intentionally narrow: one
/// `AgentEventProvenanceStore` actor creates and exclusively owns this object.
/// No descriptor or mutable state escapes that actor.
nonisolated final class SecureAgentEventJournal: @unchecked Sendable {
    struct Opened {
        let journal: SecureAgentEventJournal
        let state: AgentEventJournalLoadedState
        let integrity: AgentEventStoreIntegrity
    }

    static let journalFileName = "events.pinejournal"
    static let frameMagic = Data([0x50, 0x4E, 0x45, 0x56]) // "PNEV"

    let scopeDirectoryURL: URL
    let journalURL: URL

    private let scope: AgentEventStoreScope
    private let limits: AgentEventStoreLimits
    private let storageRoot: URL
    private let scopeDirectoryName: String

    private var rootDescriptor: Int32
    private var scopeDescriptor: Int32
    private var journalDescriptor: Int32
    private var rootIdentity: FileIdentity
    private var scopeIdentity: FileIdentity
    private var journalIdentity: FileIdentity
    private var journalByteCount: Int
    private var persistedRecordCount: Int

    deinit {
        Darwin.close(journalDescriptor)
        Darwin.close(scopeDescriptor)
        Darwin.close(rootDescriptor)
    }

    static func open(
        scope: AgentEventStoreScope,
        storageRoot: URL,
        limits: AgentEventStoreLimits
    ) throws -> Opened {
        guard storageRoot.isFileURL,
              AgentEventStoreScope.isSafeAbsolutePath(storageRoot.path) else {
            throw AgentEventStorageFailure.unsafeDirectory
        }
        try createStorageRootIfNeeded(storageRoot)

        let root = try openDirectory(path: storageRoot.path)
        let rootDescriptor = root.descriptor
        var scopeDescriptor: Int32 = -1
        var journalDescriptor: Int32 = -1
        var shouldClose = true
        defer {
            if shouldClose {
                if journalDescriptor >= 0 { Darwin.close(journalDescriptor) }
                if scopeDescriptor >= 0 { Darwin.close(scopeDescriptor) }
                Darwin.close(rootDescriptor)
            }
        }

        let scopeName = scopeDirectoryName(for: scope)
        let createdScope: Bool
        if Darwin.mkdirat(rootDescriptor, scopeName, mode_t(0o700)) == 0 {
            createdScope = true
        } else if errno == EEXIST {
            createdScope = false
        } else {
            throw AgentEventStorageFailure.createDirectory
        }

        scopeDescriptor = Darwin.openat(
            rootDescriptor,
            scopeName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard scopeDescriptor >= 0 else {
            throw AgentEventStorageFailure.openDirectory
        }
        let scopeInfo = try checkedDirectory(
            descriptor: scopeDescriptor,
            parentDescriptor: rootDescriptor,
            name: scopeName
        )
        let scopeMode = try fileInfo(descriptor: scopeDescriptor).st_mode
        let scopeModeNeedsSync = scopeMode & mode_t(0o777) != mode_t(0o700)
        guard Darwin.fchmod(scopeDescriptor, mode_t(0o700)) == 0 else {
            throw AgentEventStorageFailure.unsafeDirectory
        }
        if scopeModeNeedsSync {
            try synchronizeDirectory(scopeDescriptor)
        }
        if createdScope {
            try synchronizeDirectory(rootDescriptor)
        }

        var createdJournal = false
        journalDescriptor = Darwin.openat(
            scopeDescriptor,
            journalFileName,
            O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        if journalDescriptor >= 0 {
            createdJournal = true
        } else if errno == EEXIST {
            journalDescriptor = Darwin.openat(
                scopeDescriptor,
                journalFileName,
                O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard journalDescriptor >= 0 else {
            throw AgentEventStorageFailure.openJournal
        }
        let journalInfo = try checkedJournal(
            descriptor: journalDescriptor,
            directoryDescriptor: scopeDescriptor
        )
        guard Darwin.fchmod(journalDescriptor, mode_t(0o600)) == 0 else {
            throw AgentEventStorageFailure.unsafeJournal
        }
        if createdJournal {
            try synchronizeDirectory(scopeDescriptor)
        }

        let scopeURL = storageRoot.appendingPathComponent(scopeName, isDirectory: true)
        let instance = SecureAgentEventJournal(
            scope: scope,
            limits: limits,
            storageRoot: storageRoot,
            scopeDirectoryName: scopeName,
            scopeDirectoryURL: scopeURL,
            journalURL: scopeURL.appendingPathComponent(journalFileName),
            rootDescriptor: rootDescriptor,
            scopeDescriptor: scopeDescriptor,
            journalDescriptor: journalDescriptor,
            rootIdentity: root.identity,
            scopeIdentity: scopeInfo,
            journalIdentity: journalInfo.identity,
            journalByteCount: journalInfo.byteCount,
            persistedRecordCount: 0
        )
        shouldClose = false

        let loaded = try instance.load()
        instance.persistedRecordCount = loaded.state.records.count
        return Opened(
            journal: instance,
            state: loaded.state,
            integrity: loaded.integrity
        )
    }

    /// Persists one append. A normal record is written with `O_APPEND`; when
    /// retention would be crossed, the immutable retained suffix is rewritten
    /// to a temp inode and atomically renamed over the active path.
    func persist(
        appended record: StoredAgentEvent,
        prospectiveRecords: [StoredAgentEvent],
        checkpoint: AgentEventJournalCheckpoint
    ) throws -> [StoredAgentEvent] {
        try verifyLivePaths()
        let eventFrame = try Self.frame(for: .event(record))
        guard eventFrame.count <= limits.maxRecordBytes + Self.frameOverhead else {
            throw AgentEventStorageFailure.storageLimit
        }

        if persistedRecordCount + 1 <= limits.maxRecords,
           journalByteCount + eventFrame.count <= limits.maxLogBytes {
            let originalSize = journalByteCount
            do {
                try writeAll(eventFrame, to: journalDescriptor)
                try Self.synchronizeFile(journalDescriptor)
            } catch {
                _ = Darwin.ftruncate(journalDescriptor, off_t(originalSize))
                _ = Self.synchronizeFileBestEffort(journalDescriptor)
                throw AgentEventStorageFailure.write
            }
            journalByteCount += eventFrame.count
            persistedRecordCount += 1
            return prospectiveRecords
        }

        return try compact(
            prospectiveRecords: prospectiveRecords,
            checkpoint: checkpoint
        )
    }

    static func digest(of envelope: AgentEventEnvelope) throws -> String {
        let data = try codecEncoder().encode(envelope)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encodedEventSize(_ record: StoredAgentEvent) -> Int {
        guard let data = try? codecEncoder().encode(DiskEntry.event(record)) else {
            return Int.max
        }
        return data.count
    }

    static func scopeDirectoryURL(
        storageRoot: URL,
        scope: AgentEventStoreScope
    ) -> URL {
        storageRoot.appendingPathComponent(scopeDirectoryName(for: scope), isDirectory: true)
    }

    // MARK: - Opening and recovery

    private init(
        scope: AgentEventStoreScope,
        limits: AgentEventStoreLimits,
        storageRoot: URL,
        scopeDirectoryName: String,
        scopeDirectoryURL: URL,
        journalURL: URL,
        rootDescriptor: Int32,
        scopeDescriptor: Int32,
        journalDescriptor: Int32,
        rootIdentity: FileIdentity,
        scopeIdentity: FileIdentity,
        journalIdentity: FileIdentity,
        journalByteCount: Int,
        persistedRecordCount: Int
    ) {
        self.scope = scope
        self.limits = limits
        self.storageRoot = storageRoot
        self.scopeDirectoryName = scopeDirectoryName
        self.scopeDirectoryURL = scopeDirectoryURL
        self.journalURL = journalURL
        self.rootDescriptor = rootDescriptor
        self.scopeDescriptor = scopeDescriptor
        self.journalDescriptor = journalDescriptor
        self.rootIdentity = rootIdentity
        self.scopeIdentity = scopeIdentity
        self.journalIdentity = journalIdentity
        self.journalByteCount = journalByteCount
        self.persistedRecordCount = persistedRecordCount
    }

    private func load() throws -> (
        state: AgentEventJournalLoadedState,
        integrity: AgentEventStoreIntegrity
    ) {
        try verifyLivePaths()
        guard journalByteCount > 0 else {
            return (.empty, .healthy)
        }

        let hardReadLimit = limits.maxLogBytes + limits.maxRecordBytes + Self.frameOverhead
        if journalByteCount > hardReadLimit {
            let report = try quarantineAndRecover(
                validPrefixByteCount: 0,
                kind: .oversizedJournal,
                state: .empty
            )
            return (.empty, .recovered(report))
        }

        let bytes = try readExactly(
            descriptor: journalDescriptor,
            byteCount: journalByteCount,
            offset: 0
        )
        let parsed = parse(bytes)
        if let corruption = parsed.corruption {
            let report = try quarantineAndRecover(
                validPrefixByteCount: parsed.validPrefixByteCount,
                kind: corruption,
                state: parsed.state
            )
            return (parsed.state, .recovered(report))
        }
        return (parsed.state, .healthy)
    }

    private func parse(_ data: Data) -> ParseResult {
        var offset = 0
        var records: [StoredAgentEvent] = []
        var checkpoint: AgentEventJournalCheckpoint?
        var checkpointFrameSeen = false
        var lastSequence: UInt64 = 0
        var streamWatermarks: [AgentEventStreamIdentity: UInt64] = [:]
        var localRecordWatermarks: [AgentEventStreamIdentity: UInt64] = [:]
        var checkpointRecordWatermarks: [AgentEventStreamIdentity: UInt64] = [:]
        var recentIdentities: [AgentEventRecentIdentity] = []
        var seenRecordIDs: Set<UUID> = []
        var sawCheckpointLastRecord = false
        var enteredPostCheckpointRecords = false

        func result(
            corruption: AgentEventCorruptionReport.Kind?,
            validPrefix: Int
        ) -> ParseResult {
            if checkpointFrameSeen,
               !sawCheckpointLastRecord,
               corruption != nil {
                return ParseResult(
                    state: .empty,
                    validPrefixByteCount: 0,
                    corruption: .invalidCheckpoint
                )
            }
            return ParseResult(
                state: AgentEventJournalLoadedState(
                    records: records,
                    lastSequence: lastSequence,
                    streamWatermarks: streamWatermarks,
                    recentIdentities: recentIdentities
                ),
                validPrefixByteCount: validPrefix,
                corruption: corruption
            )
        }

        while offset < data.count {
            let frameStart = offset
            guard data.count - offset >= Self.headerByteCount else {
                return result(corruption: .truncatedFrame, validPrefix: frameStart)
            }
            guard data[offset..<(offset + 4)].elementsEqual(Self.frameMagic) else {
                return result(corruption: .invalidMagic, validPrefix: frameStart)
            }

            let payloadLength = Self.decodeLength(data, at: offset + 4)
            guard payloadLength > 0,
                  payloadLength <= limits.maxLogBytes else {
                return result(corruption: .oversizedFrame, validPrefix: frameStart)
            }
            let totalLength = Self.headerByteCount + payloadLength + Self.digestByteCount
            guard data.count - offset >= totalLength else {
                return result(corruption: .truncatedFrame, validPrefix: frameStart)
            }

            let payloadStart = offset + Self.headerByteCount
            let payloadEnd = payloadStart + payloadLength
            let payload = Data(data[payloadStart..<payloadEnd])
            let expectedDigest = Data(data[payloadEnd..<(payloadEnd + Self.digestByteCount)])
            let actualDigest = Data(SHA256.hash(data: payload))
            guard expectedDigest == actualDigest else {
                return result(corruption: .checksumMismatch, validPrefix: frameStart)
            }

            let entry: DiskEntry
            do {
                entry = try Self.codecDecoder().decode(DiskEntry.self, from: payload)
            } catch {
                return result(corruption: .decodeFailure, validPrefix: frameStart)
            }

            switch entry {
            case .checkpoint(let loadedCheckpoint):
                guard !checkpointFrameSeen,
                      records.isEmpty,
                      loadedCheckpoint.projectID == scope.projectID,
                      loadedCheckpoint.worktreePath == scope.worktreePath else {
                    return result(corruption: .invalidCheckpoint, validPrefix: frameStart)
                }
                guard loadedCheckpoint.streamWatermarks.count <= limits.maxTrackedStreams,
                      loadedCheckpoint.recentIdentities.count <= limits.maxDedupeEntries,
                      Self.validCheckpoint(loadedCheckpoint) else {
                    return result(corruption: .invalidCheckpoint, validPrefix: frameStart)
                }
                checkpointFrameSeen = true
                checkpoint = loadedCheckpoint
                lastSequence = loadedCheckpoint.lastSequence
                streamWatermarks = loadedCheckpoint.streamWatermarks
                recentIdentities = loadedCheckpoint.recentIdentities

            case .event(let persistedRecord):
                guard totalLength <= limits.maxRecordBytes + Self.frameOverhead else {
                    return result(corruption: .oversizedFrame, validPrefix: frameStart)
                }
                let normalizedEnvelope: AgentEventEnvelope
                do {
                    normalizedEnvelope = try AgentEventEnvelopeNormalizer.normalize(
                        persistedRecord.envelope,
                        scope: scope,
                        limits: limits
                    )
                } catch AgentEventAppendRejection.wrongProject,
                        AgentEventAppendRejection.wrongWorktree {
                    return result(corruption: .scopeMismatch, validPrefix: frameStart)
                } catch {
                    return result(corruption: .decodeFailure, validPrefix: frameStart)
                }
                guard normalizedEnvelope == persistedRecord.envelope,
                      persistedRecord.sequence > 0 else {
                    return result(corruption: .decodeFailure, validPrefix: frameStart)
                }
                let record = StoredAgentEvent(
                    sequence: persistedRecord.sequence,
                    envelope: normalizedEnvelope
                )
                guard !seenRecordIDs.contains(record.envelope.id) else {
                    return result(corruption: .decodeFailure, validPrefix: frameStart)
                }
                if let previousSequence = records.last?.sequence {
                    guard previousSequence < UInt64.max,
                          record.sequence == previousSequence + 1 else {
                        return result(corruption: .decodeFailure, validPrefix: frameStart)
                    }
                } else if checkpoint == nil, record.sequence != 1 {
                    return result(corruption: .decodeFailure, validPrefix: frameStart)
                }
                let stream = AgentEventStreamIdentity(envelope: record.envelope)
                if let prior = localRecordWatermarks[stream],
                   record.envelope.cursorValue <= prior {
                    return result(corruption: .decodeFailure, validPrefix: frameStart)
                }
                localRecordWatermarks[stream] = record.envelope.cursorValue
                seenRecordIDs.insert(record.envelope.id)
                records.append(record)
                guard records.count <= limits.maxRecords else {
                    records.removeLast()
                    return result(corruption: .tooManyRecords, validPrefix: frameStart)
                }

                // Retained frames covered by a compaction checkpoint are query
                // history only. Frames appended afterwards advance state.
                let coveredByCheckpoint = checkpoint.map {
                    record.sequence <= $0.lastSequence
                } ?? false
                if let checkpoint {
                    if coveredByCheckpoint {
                        guard !enteredPostCheckpointRecords else {
                            return result(
                                corruption: .invalidCheckpoint,
                                validPrefix: frameStart
                            )
                        }
                        checkpointRecordWatermarks[stream] = record.envelope.cursorValue
                        if record.sequence == checkpoint.lastSequence {
                            guard Self.checkpoint(
                                checkpoint,
                                matches: records,
                                recordWatermarks: checkpointRecordWatermarks
                            ) else {
                                return ParseResult(
                                    state: .empty,
                                    validPrefixByteCount: 0,
                                    corruption: .invalidCheckpoint
                                )
                            }
                            sawCheckpointLastRecord = true
                        }
                    } else {
                        guard sawCheckpointLastRecord else {
                            return ParseResult(
                                state: .empty,
                                validPrefixByteCount: 0,
                                corruption: .invalidCheckpoint
                            )
                        }
                        enteredPostCheckpointRecords = true
                    }
                }
                if !coveredByCheckpoint {
                    guard record.sequence > lastSequence,
                          streamWatermarks.count < limits.maxTrackedStreams
                            || streamWatermarks[stream] != nil,
                          streamWatermarks[stream].map({
                              record.envelope.cursorValue > $0
                          }) ?? true else {
                        return result(corruption: .decodeFailure, validPrefix: frameStart)
                    }
                    lastSequence = record.sequence
                    streamWatermarks[stream] = record.envelope.cursorValue
                    guard let digest = try? Self.digest(of: record.envelope) else {
                        return result(corruption: .decodeFailure, validPrefix: frameStart)
                    }
                    let identity = AgentEventRecentIdentity(
                        id: record.envelope.id,
                        digest: digest,
                        sequence: record.sequence
                    )
                    recentIdentities.removeAll { $0.id == identity.id }
                    recentIdentities.append(identity)
                    if recentIdentities.count > limits.maxDedupeEntries {
                        recentIdentities.removeFirst()
                    }
                }
            }

            offset += totalLength
        }

        // A checkpoint is authoritative only after its retained suffix proves
        // the final sequence, stream watermarks, and recent identity digest.
        if checkpoint == nil {
            lastSequence = records.last?.sequence ?? 0
        } else if let checkpoint {
            guard sawCheckpointLastRecord,
                  Self.checkpoint(
                      checkpoint,
                      matches: records,
                      recordWatermarks: checkpointRecordWatermarks
                  ) else {
                return ParseResult(
                    state: .empty,
                    validPrefixByteCount: 0,
                    corruption: .invalidCheckpoint
                )
            }
        }
        return result(corruption: nil, validPrefix: offset)
    }

    private func quarantineAndRecover(
        validPrefixByteCount: Int,
        kind: AgentEventCorruptionReport.Kind,
        state: AgentEventJournalLoadedState
    ) throws -> AgentEventCorruptionReport {
        try verifyLivePaths()
        let discarded = max(0, journalByteCount - validPrefixByteCount)
        let quarantineName = Self.quarantineFileName()
        let quarantineDescriptor = Darwin.openat(
            scopeDescriptor,
            quarantineName,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        guard quarantineDescriptor >= 0 else {
            throw AgentEventStorageFailure.quarantine
        }
        var quarantineSucceeded = false
        defer {
            Darwin.close(quarantineDescriptor)
            if !quarantineSucceeded {
                _ = Darwin.unlinkat(scopeDescriptor, quarantineName, 0)
            }
        }

        let capturedCount = min(discarded, limits.maxQuarantineBytes)
        do {
            var copied = 0
            let chunkSize = 64 * 1_024
            while copied < capturedCount {
                let count = min(chunkSize, capturedCount - copied)
                let chunk = try readExactly(
                    descriptor: journalDescriptor,
                    byteCount: count,
                    offset: validPrefixByteCount + copied
                )
                try Self.writeAll(chunk, to: quarantineDescriptor)
                copied += count
            }
            guard Darwin.fchmod(quarantineDescriptor, mode_t(0o600)) == 0 else {
                throw AgentEventStorageFailure.quarantine
            }
            let quarantineInfo = try Self.fileInfo(descriptor: quarantineDescriptor)
            guard Self.isSafeRegularFile(quarantineInfo),
                  quarantineInfo.st_nlink == 1 else {
                throw AgentEventStorageFailure.quarantine
            }
            try Self.synchronizeFile(quarantineDescriptor)
            try Self.synchronizeDirectory(scopeDescriptor)
            quarantineSucceeded = true
        } catch {
            throw AgentEventStorageFailure.quarantine
        }

        // Evidence is durable before the active journal is repaired.
        guard Darwin.ftruncate(journalDescriptor, off_t(validPrefixByteCount)) == 0 else {
            throw AgentEventStorageFailure.write
        }
        try Self.synchronizeFile(journalDescriptor)
        journalByteCount = validPrefixByteCount
        persistedRecordCount = state.records.count
        try pruneQuarantineFiles()

        return AgentEventCorruptionReport(
            kind: kind,
            retainedRecordCount: state.records.count,
            discardedByteCount: discarded,
            quarantinedByteCount: capturedCount,
            quarantineFileName: quarantineName
        )
    }

    // MARK: - Append and compaction

    private func compact(
        prospectiveRecords: [StoredAgentEvent],
        checkpoint: AgentEventJournalCheckpoint
    ) throws -> [StoredAgentEvent] {
        let checkpointFrame = try Self.frame(for: .checkpoint(checkpoint))
        guard checkpointFrame.count < limits.maxLogBytes else {
            throw AgentEventStorageFailure.storageLimit
        }

        var retained = Array(prospectiveRecords.suffix(limits.maxRecords))
        var eventFrames = try retained.map { try Self.frame(for: .event($0)) }
        var total = checkpointFrame.count + eventFrames.reduce(0) { $0 + $1.count }
        while total > limits.maxLogBytes, retained.count > 1 {
            total -= eventFrames.removeFirst().count
            retained.removeFirst()
        }
        guard total <= limits.maxLogBytes,
              retained.last?.sequence == prospectiveRecords.last?.sequence else {
            throw AgentEventStorageFailure.storageLimit
        }

        let temporaryName = ".events-\(UUID().uuidString).tmp"
        let temporaryDescriptor = Darwin.openat(
            scopeDescriptor,
            temporaryName,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        guard temporaryDescriptor >= 0 else {
            throw AgentEventStorageFailure.compact
        }

        var renamed = false
        defer {
            Darwin.close(temporaryDescriptor)
            if !renamed {
                _ = Darwin.unlinkat(scopeDescriptor, temporaryName, 0)
            }
        }

        do {
            try Self.writeAll(checkpointFrame, to: temporaryDescriptor)
            for frame in eventFrames {
                try Self.writeAll(frame, to: temporaryDescriptor)
            }
            guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
                throw AgentEventStorageFailure.compact
            }
            let temporaryInfo = try Self.fileInfo(descriptor: temporaryDescriptor)
            guard Self.isSafeRegularFile(temporaryInfo),
                  temporaryInfo.st_nlink == 1 else {
                throw AgentEventStorageFailure.compact
            }
            try Self.synchronizeFile(temporaryDescriptor)
            try verifyLivePaths()
            guard Darwin.renameat(
                scopeDescriptor,
                temporaryName,
                scopeDescriptor,
                Self.journalFileName
            ) == 0 else {
                throw AgentEventStorageFailure.compact
            }
            renamed = true
            try Self.synchronizeDirectory(scopeDescriptor)
        } catch let failure as AgentEventStorageFailure {
            throw failure
        } catch {
            throw AgentEventStorageFailure.compact
        }

        let replacementDescriptor = Darwin.openat(
            scopeDescriptor,
            Self.journalFileName,
            O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        )
        guard replacementDescriptor >= 0 else {
            throw AgentEventStorageFailure.openJournal
        }
        let replacement: (identity: FileIdentity, byteCount: Int)
        do {
            replacement = try Self.checkedJournal(
                descriptor: replacementDescriptor,
                directoryDescriptor: scopeDescriptor
            )
        } catch {
            Darwin.close(replacementDescriptor)
            throw AgentEventStorageFailure.unsafeJournal
        }

        Darwin.close(journalDescriptor)
        journalDescriptor = replacementDescriptor
        journalIdentity = replacement.identity
        journalByteCount = replacement.byteCount
        persistedRecordCount = retained.count
        return retained
    }

    // MARK: - Descriptor security

    private func verifyLivePaths() throws {
        let rootPathInfo = try Self.pathInfo(path: storageRoot.path)
        let rootFDInfo = try Self.fileInfo(descriptor: rootDescriptor)
        guard Self.identity(rootPathInfo) == rootIdentity,
              Self.identity(rootFDInfo) == rootIdentity,
              Self.isSafeDirectory(rootFDInfo) else {
            throw AgentEventStorageFailure.pathReplaced
        }

        let scopePathInfo = try Self.pathInfo(
            parentDescriptor: rootDescriptor,
            name: scopeDirectoryName
        )
        let scopeFDInfo = try Self.fileInfo(descriptor: scopeDescriptor)
        guard Self.identity(scopePathInfo) == scopeIdentity,
              Self.identity(scopeFDInfo) == scopeIdentity,
              Self.isSafeDirectory(scopeFDInfo) else {
            throw AgentEventStorageFailure.pathReplaced
        }

        let journalPathInfo = try Self.pathInfo(
            parentDescriptor: scopeDescriptor,
            name: Self.journalFileName
        )
        let journalFDInfo = try Self.fileInfo(descriptor: journalDescriptor)
        guard Self.identity(journalPathInfo) == journalIdentity,
              Self.identity(journalFDInfo) == journalIdentity else {
            throw AgentEventStorageFailure.pathReplaced
        }
        guard Self.isSafeRegularFile(journalFDInfo),
              journalFDInfo.st_nlink == 1,
              journalFDInfo.st_size == off_t(journalByteCount) else {
            throw AgentEventStorageFailure.unsafeJournal
        }
    }

    private static func createStorageRootIfNeeded(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw AgentEventStorageFailure.createDirectory
        }
    }

    private static func openDirectory(path: String) throws -> (
        descriptor: Int32,
        identity: FileIdentity
    ) {
        let pathBefore = try pathInfo(path: path)
        guard isDirectory(pathBefore), pathBefore.st_uid == geteuid() else {
            throw AgentEventStorageFailure.unsafeDirectory
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AgentEventStorageFailure.openDirectory
        }
        do {
            let descriptorInfo = try fileInfo(descriptor: descriptor)
            guard identity(pathBefore) == identity(descriptorInfo),
                  isDirectory(descriptorInfo),
                  descriptorInfo.st_uid == geteuid(),
                  Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw AgentEventStorageFailure.unsafeDirectory
            }
            if descriptorInfo.st_mode & mode_t(0o777) != mode_t(0o700) {
                try synchronizeDirectory(descriptor)
            }
            return (descriptor, identity(descriptorInfo))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func checkedDirectory(
        descriptor: Int32,
        parentDescriptor: Int32,
        name: String
    ) throws -> FileIdentity {
        let path = try pathInfo(parentDescriptor: parentDescriptor, name: name)
        let opened = try fileInfo(descriptor: descriptor)
        guard identity(path) == identity(opened),
              isSafeDirectory(opened) else {
            throw AgentEventStorageFailure.unsafeDirectory
        }
        return identity(opened)
    }

    private static func checkedJournal(
        descriptor: Int32,
        directoryDescriptor: Int32
    ) throws -> (identity: FileIdentity, byteCount: Int) {
        let path = try pathInfo(
            parentDescriptor: directoryDescriptor,
            name: journalFileName
        )
        let opened = try fileInfo(descriptor: descriptor)
        guard identity(path) == identity(opened),
              isSafeRegularFile(opened),
              opened.st_nlink == 1,
              opened.st_size >= 0,
              opened.st_size <= off_t(Int.max) else {
            throw AgentEventStorageFailure.unsafeJournal
        }
        return (identity(opened), Int(opened.st_size))
    }

    private static func isSafeDirectory(_ info: stat) -> Bool {
        isDirectory(info)
            && info.st_uid == geteuid()
            && (info.st_mode & mode_t(0o077)) == 0
    }

    private static func isSafeRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == geteuid()
            && (info.st_mode & mode_t(0o077)) == 0
    }

    private static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func identity(_ info: stat) -> FileIdentity {
        FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func fileInfo(descriptor: Int32) throws -> stat {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw AgentEventStorageFailure.read
        }
        return info
    }

    private static func pathInfo(path: String) throws -> stat {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else {
            throw AgentEventStorageFailure.read
        }
        return info
    }

    private static func pathInfo(
        parentDescriptor: Int32,
        name: String
    ) throws -> stat {
        var info = stat()
        guard Darwin.fstatat(
            parentDescriptor,
            name,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw AgentEventStorageFailure.pathReplaced
        }
        return info
    }

    // MARK: - Framing and I/O

    private static let headerByteCount = 8
    private static let digestByteCount = 32
    private static let frameOverhead = headerByteCount + digestByteCount

    private static func frame(for entry: DiskEntry) throws -> Data {
        let payload = try codecEncoder().encode(entry)
        guard payload.count <= Int(UInt32.max) else {
            throw AgentEventStorageFailure.storageLimit
        }
        var frame = frameMagic
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        frame.append(contentsOf: SHA256.hash(data: payload))
        return frame
    }

    private static func decodeLength(_ data: Data, at offset: Int) -> Int {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            data.copyBytes(
                to: destination,
                from: offset..<(offset + MemoryLayout<UInt32>.size)
            )
        }
        return Int(UInt32(bigEndian: value))
    }

    private static func codecEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func codecDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw AgentEventStorageFailure.write
                }
                written += result
            }
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try Self.writeAll(data, to: descriptor)
    }

    private func readExactly(
        descriptor: Int32,
        byteCount: Int,
        offset: Int
    ) throws -> Data {
        guard byteCount >= 0, offset >= 0 else {
            throw AgentEventStorageFailure.read
        }
        var output = Data(count: byteCount)
        try output.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var consumed = 0
            while consumed < byteCount {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: consumed),
                    byteCount - consumed,
                    off_t(offset + consumed)
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw AgentEventStorageFailure.read
                }
                consumed += result
            }
        }
        return output
    }

    private static func synchronizeFile(_ descriptor: Int32) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw AgentEventStorageFailure.synchronize
        }
    }

    private static func synchronizeFileBestEffort(_ descriptor: Int32) -> Bool {
        (Darwin.fcntl(descriptor, F_FULLFSYNC) == 0) || (Darwin.fsync(descriptor) == 0)
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw AgentEventStorageFailure.synchronize
        }
    }

    private func pruneQuarantineFiles() throws {
        let duplicate = Darwin.dup(scopeDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw AgentEventStorageFailure.quarantine
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name.hasPrefix("quarantine-"), name.hasSuffix(".bin") {
                names.append(name)
            }
        }
        names.sort()
        let surplus = names.count - limits.maxQuarantineFiles
        guard surplus > 0 else { return }
        for name in names.prefix(surplus) {
            guard Darwin.unlinkat(scopeDescriptor, name, 0) == 0 else {
                throw AgentEventStorageFailure.quarantine
            }
        }
        try Self.synchronizeDirectory(scopeDescriptor)
    }

    private static func quarantineFileName() -> String {
        let milliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        return String(format: "quarantine-%020llu-%@.bin", milliseconds, UUID().uuidString)
    }

    private static func scopeDirectoryName(for scope: AgentEventStoreScope) -> String {
        let material = "\(scope.projectID.uuidString.lowercased())\u{0}\(scope.worktreePath)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let suffix = digest.prefix(20).map { String(format: "%02x", $0) }.joined()
        return "scope-\(suffix)"
    }

    private static func validCheckpoint(
        _ checkpoint: AgentEventJournalCheckpoint
    ) -> Bool {
        let identities = checkpoint.recentIdentities
        let sequences = identities.map(\.sequence)
        return Set(identities.map(\.id)).count == identities.count
            && zip(sequences, sequences.dropFirst()).allSatisfy {
                $0.0 < $0.1
            }
            && identities.allSatisfy {
                $0.sequence > 0
                    && $0.sequence <= checkpoint.lastSequence
                    && $0.digest.count == 64
                    && $0.digest.allSatisfy { character in
                        ("0"..."9").contains(character) || ("a"..."f").contains(character)
                    }
            }
            && checkpoint.lastSequence > 0
            && checkpoint.streamWatermarks.allSatisfy { stream, cursor in
                stream.sessionID != AgentEventStoreScope.zeroUUID
                    && stream.terminalID != AgentEventStoreScope.zeroUUID
                    && stream.processGeneration > 0
                    && cursor > 0
            }
    }

    private static func checkpoint(
        _ checkpoint: AgentEventJournalCheckpoint,
        matches records: [StoredAgentEvent],
        recordWatermarks: [AgentEventStreamIdentity: UInt64]
    ) -> Bool {
        guard recordWatermarks.allSatisfy({
            checkpoint.streamWatermarks[$0.key] == $0.value
        }),
        let finalRecord = records.first(where: {
            $0.sequence == checkpoint.lastSequence
        }),
        let finalIdentity = checkpoint.recentIdentities.last,
        finalIdentity.id == finalRecord.envelope.id,
        finalIdentity.sequence == finalRecord.sequence else {
            return false
        }

        let recordsByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.envelope.id, $0) }
        )
        return checkpoint.recentIdentities.allSatisfy { identity in
            guard let record = recordsByID[identity.id] else { return true }
            guard record.sequence == identity.sequence,
                  let digest = try? digest(of: record.envelope) else {
                return false
            }
            return digest == identity.digest
        }
    }
}

nonisolated private extension AgentEventJournalLoadedState {
    static let empty = AgentEventJournalLoadedState(
        records: [],
        lastSequence: 0,
        streamWatermarks: [:],
        recentIdentities: []
    )
}

nonisolated private extension SecureAgentEventJournal {
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    struct ParseResult {
        let state: AgentEventJournalLoadedState
        let validPrefixByteCount: Int
        let corruption: AgentEventCorruptionReport.Kind?
    }

    enum DiskEntry: Codable {
        case checkpoint(AgentEventJournalCheckpoint)
        case event(StoredAgentEvent)

        private enum CodingKeys: String, CodingKey {
            case version, kind, checkpoint, event
        }

        private enum Kind: String, Codable {
            case checkpoint
            case event
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .version)
            guard version == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: container,
                    debugDescription: "Unsupported provenance journal version"
                )
            }
            switch try container.decode(Kind.self, forKey: .kind) {
            case .checkpoint:
                self = .checkpoint(
                    try container.decode(
                        AgentEventJournalCheckpoint.self,
                        forKey: .checkpoint
                    )
                )
            case .event:
                self = .event(
                    try container.decode(StoredAgentEvent.self, forKey: .event)
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(1, forKey: .version)
            switch self {
            case .checkpoint(let checkpoint):
                try container.encode(Kind.checkpoint, forKey: .kind)
                try container.encode(checkpoint, forKey: .checkpoint)
            case .event(let event):
                try container.encode(Kind.event, forKey: .kind)
                try container.encode(event, forKey: .event)
            }
        }
    }
}
