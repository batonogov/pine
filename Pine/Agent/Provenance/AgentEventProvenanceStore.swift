//
//  AgentEventProvenanceStore.swift
//  Pine
//
//  Owner-private append-only storage for trusted agent-event provenance
//  (epic #933, storage slice).
//
//  This actor is deliberately not wired into terminal observation, Agent
//  Activity, Agent History, or undo. It is a persistence and query boundary
//  only. Recording metadata here never authorizes a working-tree mutation.
//

import CryptoKit
import Foundation

/// Project/worktree identity that owns one provenance journal.
///
/// The worktree path is canonicalized once when the scope is created. Every
/// appended envelope is checked against both fields, so copying a valid record
/// into another project's journal cannot make it authoritative there.
nonisolated struct AgentEventStoreScope: Sendable, Equatable {
    let projectID: UUID
    let worktreePath: String

    init(projectID: UUID, worktreeURL: URL) throws {
        guard projectID != Self.zeroUUID,
              worktreeURL.isFileURL,
              Self.isSafeAbsolutePath(worktreeURL.path) else {
            throw AgentEventStoreError.invalidScope
        }
        let canonicalPath = Self.canonicalPath(worktreeURL.path)
        guard Self.isSafeAbsolutePath(canonicalPath) else {
            throw AgentEventStoreError.invalidScope
        }
        self.projectID = projectID
        self.worktreePath = canonicalPath
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func isSafeAbsolutePath(_ path: String) -> Bool {
        !path.isEmpty
            && path.hasPrefix("/")
            && !path.utf8.contains(0)
            && path.utf8.count <= AgentEventStoreLimits.maximumPathBytes
    }

    static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

/// Bounded storage and input limits for one journal.
nonisolated struct AgentEventStoreLimits: Sendable, Equatable {
    static let maximumPathBytes = 4_096
    private static let maximumRecords = 100_000
    private static let maximumLogBytes = 256 * 1_024 * 1_024
    private static let maximumRecordBytes = 8 * 1_024 * 1_024
    private static let maximumDedupeEntries = 200_000
    private static let maximumTrackedStreams = 100_000
    private static let maximumQueryResults = 10_000
    private static let maximumMetadataBytes = 4_096
    private static let maximumCommandBytes = 1 * 1_024 * 1_024
    private static let maximumQuarantineFiles = 64
    private static let maximumQuarantineBytes = 16 * 1_024 * 1_024

    let maxRecords: Int
    let maxLogBytes: Int
    let maxRecordBytes: Int
    let maxDedupeEntries: Int
    let maxTrackedStreams: Int
    let maxQueryResults: Int
    let maxAgentTypeBytes: Int
    let maxSourceBytes: Int
    let maxCommandBytes: Int
    let maxQuarantineFiles: Int
    let maxQuarantineBytes: Int

    init(
        maxRecords: Int = 2_000,
        maxLogBytes: Int = 8 * 1_024 * 1_024,
        maxRecordBytes: Int = 128 * 1_024,
        maxDedupeEntries: Int = 4_000,
        maxTrackedStreams: Int = 1_024,
        maxQueryResults: Int = 1_000,
        maxAgentTypeBytes: Int = 256,
        maxSourceBytes: Int = 256,
        maxCommandBytes: Int = 32 * 1_024,
        maxQuarantineFiles: Int = 4,
        maxQuarantineBytes: Int = 1 * 1_024 * 1_024
    ) throws {
        guard maxRecords > 0,
              maxRecords <= Self.maximumRecords,
              maxLogBytes >= 4_096,
              maxLogBytes <= Self.maximumLogBytes,
              maxRecordBytes > 0,
              maxRecordBytes <= Self.maximumRecordBytes,
              maxRecordBytes < maxLogBytes,
              maxDedupeEntries > 0,
              maxDedupeEntries <= Self.maximumDedupeEntries,
              maxTrackedStreams > 0,
              maxTrackedStreams <= Self.maximumTrackedStreams,
              maxQueryResults > 0,
              maxQueryResults <= Self.maximumQueryResults,
              maxAgentTypeBytes > 0,
              maxAgentTypeBytes <= Self.maximumMetadataBytes,
              maxSourceBytes > 0,
              maxSourceBytes <= Self.maximumMetadataBytes,
              maxCommandBytes > 0,
              maxCommandBytes <= Self.maximumCommandBytes,
              maxQuarantineFiles > 0,
              maxQuarantineFiles <= Self.maximumQuarantineFiles,
              maxQuarantineBytes > 0,
              maxQuarantineBytes <= Self.maximumQuarantineBytes else {
            throw AgentEventStoreError.invalidLimits
        }
        self.maxRecords = maxRecords
        self.maxLogBytes = maxLogBytes
        self.maxRecordBytes = maxRecordBytes
        self.maxDedupeEntries = maxDedupeEntries
        self.maxTrackedStreams = maxTrackedStreams
        self.maxQueryResults = maxQueryResults
        self.maxAgentTypeBytes = maxAgentTypeBytes
        self.maxSourceBytes = maxSourceBytes
        self.maxCommandBytes = maxCommandBytes
        self.maxQuarantineFiles = maxQuarantineFiles
        self.maxQuarantineBytes = maxQuarantineBytes
    }

    static var `default`: AgentEventStoreLimits {
        // These constants are validated above and cannot fail.
        do {
            return try AgentEventStoreLimits()
        } catch {
            preconditionFailure("Invalid built-in AgentEventStoreLimits")
        }
    }
}

/// Opening or operating the secure journal failed.
nonisolated enum AgentEventStoreError: Error, Sendable, Equatable {
    case invalidScope
    case invalidLimits
    case unsafeStorage(AgentEventStorageFailure)
}

/// Fail-closed storage failure categories. Raw errno/path details are not
/// exposed because callers only need to know that the journal lost authority.
nonisolated enum AgentEventStorageFailure: String, Error, Codable, Sendable, Equatable {
    case createDirectory
    case openDirectory
    case unsafeDirectory
    case openJournal
    case unsafeJournal
    case pathReplaced
    case read
    case write
    case synchronize
    case compact
    case quarantine
    case storageLimit
}

/// Why an otherwise structured envelope was refused.
nonisolated enum AgentEventAppendRejection: Error, Sendable, Equatable {
    case wrongProject
    case wrongWorktree
    case invalidProvenance
    case invalidPayload
    case oversizedRecord
    case identityCollision
    case nonMonotonicCursor
    case streamLimitReached
    case sequenceExhausted
    case storage(AgentEventStorageFailure)
}

/// Typed result for callers that need to distinguish a durable append from a
/// retained-window duplicate or a fail-closed rejection.
nonisolated enum AgentEventAppendOutcome: Sendable, Equatable {
    case appended(sequence: UInt64)
    case duplicate(existingSequence: UInt64)
    case rejected(AgentEventAppendRejection)
}

/// One durable journal row. `sequence` is global within this scoped store;
/// `envelope.cursorValue` remains monotonic within its process stream.
nonisolated struct StoredAgentEvent: Codable, Sendable, Equatable {
    let sequence: UInt64
    let envelope: AgentEventEnvelope
}

/// Integrity condition observed while opening the current journal.
nonisolated enum AgentEventStoreIntegrity: Sendable, Equatable {
    case healthy
    case recovered(AgentEventCorruptionReport)
    case unavailable(AgentEventStorageFailure)
}

/// Typed evidence that an invalid suffix was quarantined before recovery.
nonisolated struct AgentEventCorruptionReport: Sendable, Equatable {
    enum Kind: String, Codable, Sendable, Equatable {
        case truncatedFrame
        case invalidMagic
        case oversizedFrame
        case checksumMismatch
        case decodeFailure
        case scopeMismatch
        case invalidCheckpoint
        case tooManyRecords
        case oversizedJournal
    }

    let kind: Kind
    let retainedRecordCount: Int
    let discardedByteCount: Int
    let quarantinedByteCount: Int
    let quarantineFileName: String
}

/// Value-type snapshot for read-only consumers.
nonisolated struct AgentEventStoreSnapshot: Sendable, Equatable {
    let scope: AgentEventStoreScope
    let integrity: AgentEventStoreIntegrity
    let lastSequence: UInt64
    let records: [StoredAgentEvent]

    var verified: [StoredAgentEvent] {
        records.filter { $0.envelope.trustLevel == .verified }
    }

    var inferred: [StoredAgentEvent] {
        records.filter { $0.envelope.trustLevel == .inferred }
    }

    var observed: [StoredAgentEvent] {
        records.filter { $0.envelope.trustLevel == .observed }
    }
}

/// Bounded read-only filter. Nil fields match every value.
nonisolated struct AgentEventQuery: Sendable, Equatable {
    let sessionID: UUID?
    let terminalID: UUID?
    let trustLevel: TrustLevel?
    let source: EventSource?
    let sequenceAfter: UInt64?
    let sequenceThrough: UInt64?
    let limit: Int?

    init(
        sessionID: UUID? = nil,
        terminalID: UUID? = nil,
        trustLevel: TrustLevel? = nil,
        source: EventSource? = nil,
        sequenceAfter: UInt64? = nil,
        sequenceThrough: UInt64? = nil,
        limit: Int? = nil
    ) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.trustLevel = trustLevel
        self.source = source
        self.sequenceAfter = sequenceAfter
        self.sequenceThrough = sequenceThrough
        self.limit = limit
    }
}

/// Typed query response that never separates rows from the journal integrity
/// state under which they were read.
nonisolated struct AgentEventQueryResult: Sendable, Equatable {
    let scope: AgentEventStoreScope
    let integrity: AgentEventStoreIntegrity
    let records: [StoredAgentEvent]

    var verified: [StoredAgentEvent] {
        records.filter { $0.envelope.trustLevel == .verified }
    }

    var inferred: [StoredAgentEvent] {
        records.filter { $0.envelope.trustLevel == .inferred }
    }

    var observed: [StoredAgentEvent] {
        records.filter { $0.envelope.trustLevel == .observed }
    }
}

/// Stream identity used for cursor monotonicity across restarts.
nonisolated struct AgentEventStreamIdentity: Codable, Hashable, Sendable {
    let sessionID: UUID
    let terminalID: UUID
    let processGeneration: UInt64

    init(envelope: AgentEventEnvelope) {
        self.sessionID = envelope.sessionID
        self.terminalID = envelope.process.terminalID
        self.processGeneration = envelope.process.processGeneration
    }
}

/// Persisted dedupe identity. The digest detects UUID reuse with different
/// content instead of silently treating the collision as a duplicate.
nonisolated struct AgentEventRecentIdentity: Codable, Sendable, Equatable {
    let id: UUID
    let digest: String
    let sequence: UInt64
}

/// Metadata included whenever retention compacts the event suffix.
nonisolated struct AgentEventJournalCheckpoint: Codable, Sendable, Equatable {
    let projectID: UUID
    let worktreePath: String
    let lastSequence: UInt64
    let streamWatermarks: [AgentEventStreamIdentity: UInt64]
    let recentIdentities: [AgentEventRecentIdentity]
}

/// Serialized, owner-private provenance collector and query store.
///
/// Actor isolation is the single mutation boundary. The secure journal itself
/// performs synchronous POSIX I/O, but is private to this actor and is never
/// called from the main actor by this slice.
actor AgentEventProvenanceStore: AgentEventProvenanceCollector {
    private let scope: AgentEventStoreScope
    private let limits: AgentEventStoreLimits
    private let journal: SecureAgentEventJournal

    private var records: [StoredAgentEvent]
    private var lastSequence: UInt64
    private var streamWatermarks: [AgentEventStreamIdentity: UInt64]
    private var recentIdentities: [UUID: AgentEventRecentIdentity]
    private var recentIdentityOrder: [UUID]
    private var integrity: AgentEventStoreIntegrity

    init(
        scope: AgentEventStoreScope,
        storageRoot: URL = AgentEventProvenanceStore.defaultStorageRoot,
        limits: AgentEventStoreLimits = .default
    ) throws {
        let opened: SecureAgentEventJournal.Opened
        do {
            opened = try SecureAgentEventJournal.open(
                scope: scope,
                storageRoot: storageRoot,
                limits: limits
            )
        } catch let failure as AgentEventStorageFailure {
            throw AgentEventStoreError.unsafeStorage(failure)
        }

        self.scope = scope
        self.limits = limits
        self.journal = opened.journal
        self.records = opened.state.records
        self.lastSequence = opened.state.lastSequence
        self.streamWatermarks = opened.state.streamWatermarks
        self.recentIdentityOrder = opened.state.recentIdentities.map(\.id)
        self.recentIdentities = Dictionary(
            uniqueKeysWithValues: opened.state.recentIdentities.map { ($0.id, $0) }
        )
        self.integrity = opened.integrity
    }

    /// Safe protocol adapter. Callers that require typed refusal information
    /// use `append(_:)`; the original #1204 collector seam remains source
    /// compatible and fail-closed.
    func record(_ envelope: AgentEventEnvelope) async {
        _ = append(envelope)
    }

    /// Validates, deduplicates, durably appends, and only then publishes the
    /// record to in-memory queries.
    @discardableResult
    func append(_ envelope: AgentEventEnvelope) -> AgentEventAppendOutcome {
        if case .unavailable(let failure) = integrity {
            return .rejected(.storage(failure))
        }

        let normalized: AgentEventEnvelope
        do {
            normalized = try AgentEventEnvelopeNormalizer.normalize(
                envelope,
                scope: scope,
                limits: limits
            )
        } catch let rejection as AgentEventAppendRejection {
            return .rejected(rejection)
        } catch {
            return .rejected(.invalidProvenance)
        }

        let digest: String
        do {
            digest = try SecureAgentEventJournal.digest(of: normalized)
        } catch {
            return .rejected(.oversizedRecord)
        }

        if let existing = recentIdentities[normalized.id] {
            if existing.digest == digest {
                return .duplicate(existingSequence: existing.sequence)
            }
            return .rejected(.identityCollision)
        }
        if let retained = records.first(where: { $0.envelope.id == normalized.id }) {
            guard let retainedDigest = try? SecureAgentEventJournal.digest(
                of: retained.envelope
            ) else {
                return .rejected(.identityCollision)
            }
            if retainedDigest == digest {
                return .duplicate(existingSequence: retained.sequence)
            }
            return .rejected(.identityCollision)
        }

        let stream = AgentEventStreamIdentity(envelope: normalized)
        if let watermark = streamWatermarks[stream],
           normalized.cursorValue <= watermark {
            return .rejected(.nonMonotonicCursor)
        }
        if streamWatermarks[stream] == nil,
           streamWatermarks.count >= limits.maxTrackedStreams {
            return .rejected(.streamLimitReached)
        }
        guard lastSequence < UInt64.max else {
            return .rejected(.sequenceExhausted)
        }

        let sequence = lastSequence + 1
        let record = StoredAgentEvent(sequence: sequence, envelope: normalized)
        guard SecureAgentEventJournal.encodedEventSize(record) <= limits.maxRecordBytes else {
            return .rejected(.oversizedRecord)
        }

        var nextRecords = records
        nextRecords.append(record)

        var nextWatermarks = streamWatermarks
        nextWatermarks[stream] = normalized.cursorValue

        var nextIdentityOrder = recentIdentityOrder.filter { $0 != normalized.id }
        nextIdentityOrder.append(normalized.id)
        if nextIdentityOrder.count > limits.maxDedupeEntries {
            nextIdentityOrder.removeFirst(nextIdentityOrder.count - limits.maxDedupeEntries)
        }

        var nextIdentities = recentIdentities
        nextIdentities[normalized.id] = AgentEventRecentIdentity(
            id: normalized.id,
            digest: digest,
            sequence: sequence
        )
        let retainedIdentityIDs = Set(nextIdentityOrder)
        nextIdentities = nextIdentities.filter { retainedIdentityIDs.contains($0.key) }

        let checkpoint = AgentEventJournalCheckpoint(
            projectID: scope.projectID,
            worktreePath: scope.worktreePath,
            lastSequence: sequence,
            streamWatermarks: nextWatermarks,
            recentIdentities: nextIdentityOrder.compactMap { nextIdentities[$0] }
        )

        let retained: [StoredAgentEvent]
        do {
            retained = try journal.persist(
                appended: record,
                prospectiveRecords: nextRecords,
                checkpoint: checkpoint
            )
        } catch let failure as AgentEventStorageFailure {
            integrity = .unavailable(failure)
            return .rejected(.storage(failure))
        } catch {
            integrity = .unavailable(.write)
            return .rejected(.storage(.write))
        }

        records = retained
        lastSequence = sequence
        streamWatermarks = nextWatermarks
        recentIdentityOrder = nextIdentityOrder
        recentIdentities = nextIdentities
        return .appended(sequence: sequence)
    }

    /// Full retained suffix plus typed recovery state.
    func snapshot() -> AgentEventStoreSnapshot {
        AgentEventStoreSnapshot(
            scope: scope,
            integrity: integrity,
            lastSequence: lastSequence,
            records: records
        )
    }

    /// Chronological, bounded read-only query with inseparable integrity state.
    func query(_ query: AgentEventQuery = AgentEventQuery()) -> AgentEventQueryResult {
        let requestedLimit = query.limit ?? limits.maxQueryResults
        let safeLimit = max(0, min(requestedLimit, limits.maxQueryResults))
        let matches: [StoredAgentEvent]
        if safeLimit == 0 {
            matches = []
        } else {
            matches = Array(records.lazy.filter { record in
                let envelope = record.envelope
                return (query.sessionID == nil || envelope.sessionID == query.sessionID)
                    && (query.terminalID == nil
                        || envelope.process.terminalID == query.terminalID)
                    && (query.trustLevel == nil || envelope.trustLevel == query.trustLevel)
                    && (query.source == nil || envelope.source == query.source)
                    && (query.sequenceAfter.map { record.sequence > $0 } ?? true)
                    && (query.sequenceThrough.map { record.sequence <= $0 } ?? true)
            }.prefix(safeLimit))
        }
        return AgentEventQueryResult(
            scope: scope,
            integrity: integrity,
            records: matches
        )
    }

    /// Stable paths are exposed for diagnostics/tests only; callers must never
    /// mutate them. Runtime I/O remains descriptor-relative.
    func storageLocations() -> (scopeDirectory: URL, journal: URL) {
        (journal.scopeDirectoryURL, journal.journalURL)
    }

    nonisolated static var defaultStorageRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pine", isDirectory: true)
            .appendingPathComponent("AgentProvenance", isDirectory: true)
    }
}

/// Shared fail-closed normalization used for both live appends and decoded
/// journal frames. Keeping one implementation prevents a hand-crafted,
/// checksummed on-disk record from bypassing the live collector's rules.
nonisolated enum AgentEventEnvelopeNormalizer {
    static func normalize(
        _ envelope: AgentEventEnvelope,
        scope: AgentEventStoreScope,
        limits: AgentEventStoreLimits
    ) throws -> AgentEventEnvelope {
        guard envelope.projectID == scope.projectID else {
            throw AgentEventAppendRejection.wrongProject
        }

        guard AgentEventStoreScope.isSafeAbsolutePath(envelope.location.worktreePath),
              AgentEventStoreScope.isSafeAbsolutePath(envelope.location.cwd) else {
            throw AgentEventAppendRejection.invalidProvenance
        }
        let eventWorktree = AgentEventStoreScope.canonicalPath(envelope.location.worktreePath)
        guard eventWorktree == scope.worktreePath else {
            throw AgentEventAppendRejection.wrongWorktree
        }

        let canonicalCWD = AgentEventStoreScope.canonicalPath(envelope.location.cwd)
        guard AgentEventStoreScope.isSafeAbsolutePath(canonicalCWD),
              isWithinScope(canonicalCWD, root: scope.worktreePath),
              envelope.id != AgentEventStoreScope.zeroUUID,
              envelope.cursorValue > 0,
              envelope.sessionID != AgentEventStoreScope.zeroUUID,
              envelope.process.terminalID != AgentEventStoreScope.zeroUUID,
              envelope.process.processGeneration > 0,
              envelope.agentTypeRaw.utf8.count <= limits.maxAgentTypeBytes,
              !envelope.agentTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !envelope.agentTypeRaw.utf8.contains(0),
              envelope.source.stableIdentifier.utf8.count <= limits.maxSourceBytes,
              !envelope.source.stableIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !envelope.source.stableIdentifier.utf8.contains(0),
              envelope.timestamp.timeIntervalSince1970.isFinite,
              envelope.timestamp.timeIntervalSince1970 != 0 else {
            throw AgentEventAppendRejection.invalidProvenance
        }

        guard isSafePayload(envelope.payload, limits: limits) else {
            throw AgentEventAppendRejection.invalidPayload
        }

        // Reconstructing is intentional: the #1204 initializer recomputes the
        // effective trust level. A malformed/incomplete caller can never
        // preserve `.verified` merely because it arrived as an in-memory value.
        return AgentEventEnvelope(
            id: envelope.id,
            projectID: envelope.projectID,
            sessionID: envelope.sessionID,
            agentTypeRaw: envelope.agentTypeRaw,
            process: envelope.process,
            location: AgentEventLocation(
                worktreePath: scope.worktreePath,
                cwd: canonicalCWD
            ),
            cursorValue: envelope.cursorValue,
            timestamp: envelope.timestamp,
            source: envelope.source,
            trustLevel: envelope.trustLevel,
            payload: envelope.payload
        )
    }

    private static func isWithinScope(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func isSafePayload(
        _ payload: AgentEventPayload,
        limits: AgentEventStoreLimits
    ) -> Bool {
        switch payload {
        case .none:
            return true
        case .commandResult(let result):
            return !result.command.utf8.contains(0)
                && result.command.utf8.count <= limits.maxCommandBytes
        case .fileChange(let change):
            return isSafeRelativePath(change.relativePath)
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= AgentEventStoreLimits.maximumPathBytes,
              !path.hasPrefix("/"),
              !path.utf8.contains(0) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
