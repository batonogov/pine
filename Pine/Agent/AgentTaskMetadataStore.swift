//
//  AgentTaskMetadataStore.swift
//  Pine
//
//  Bounded, project-scoped durable task metadata (#1302).
//

import CryptoKit
import Darwin
import Foundation

nonisolated struct AgentTaskPersistenceLimits: Sendable {
    let maxTasksPerProject: Int
    let maxRunsPerTask: Int
    let maxHistoricalRunIDs: Int
    let maxFileBytes: Int
    let maxAgentIdentifierBytes: Int
    let maxProcessStartBytes: Int
    let maxTitleBytes: Int
    let maxObjectiveBytes: Int

    init(
        maxTasksPerProject: Int = 200,
        maxRunsPerTask: Int = 50,
        maxHistoricalRunIDs: Int = 8_192,
        maxFileBytes: Int = 1_048_576
    ) {
        self.maxTasksPerProject = max(1, maxTasksPerProject)
        self.maxRunsPerTask = max(1, maxRunsPerTask)
        self.maxHistoricalRunIDs = max(1, maxHistoricalRunIDs)
        self.maxFileBytes = max(1_024, maxFileBytes)
        maxAgentIdentifierBytes = 128
        maxProcessStartBytes = 512
        maxTitleBytes = 256
        maxObjectiveBytes = 2_048
    }
}

nonisolated enum AgentTaskStorePhase: Sendable {
    case directoryOpened
    case lockAcquired
    case beforeReadOpen
    case readOpened
    case beforeTemporaryCreate
    case temporaryWritten
    case beforePublish
    case beforeCleanupRetire
    case beforeRetireMutation
}

nonisolated enum AgentTaskSyncTarget: Hashable, Sendable {
    case parentDirectory
    case createdDirectory
    case metadataFile
    case storageDirectory
}

nonisolated struct AgentTaskCleanupConfiguration: Sendable {
    let staleAge: TimeInterval
    let scanLimit: Int
    let retireLimit: Int
    let tombstoneLimit: Int
    let directoryEntryLimit: Int
    let now: @Sendable () -> Date

    init(
        staleAge: TimeInterval = 3_600,
        scanLimit: Int = 256,
        retireLimit: Int = 32,
        tombstoneLimit: Int = 64,
        directoryEntryLimit: Int = 4_096,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.staleAge = max(0, staleAge)
        self.scanLimit = max(1, scanLimit)
        self.retireLimit = max(0, retireLimit)
        self.tombstoneLimit = max(1, tombstoneLimit)
        self.directoryEntryLimit = max(self.tombstoneLimit, max(1, directoryEntryLimit))
        self.now = now
    }
}

#if DEBUG
nonisolated struct AgentTaskStoreHooks: Sendable {
    let phase: @Sendable (AgentTaskStorePhase) -> Void
    let didSync: @Sendable (AgentTaskSyncTarget) -> Void
    let shouldSync: @Sendable (AgentTaskSyncTarget) -> Bool

    init(
        didSync: @escaping @Sendable (AgentTaskSyncTarget) -> Void = { _ in },
        shouldSync: @escaping @Sendable (AgentTaskSyncTarget) -> Bool = { _ in true },
        phase: @escaping @Sendable (AgentTaskStorePhase) -> Void = { _ in }
    ) {
        self.phase = phase
        self.didSync = didSync
        self.shouldSync = shouldSync
    }
}
#endif

nonisolated struct AgentTaskStoreConfiguration: Sendable {
    let privateComponentCount: Int?
    let cleanup: AgentTaskCleanupConfiguration
    #if DEBUG
    let hooks: AgentTaskStoreHooks
    #endif

    #if DEBUG
    init(
        privateComponentCount: Int? = nil,
        cleanup: AgentTaskCleanupConfiguration = AgentTaskCleanupConfiguration(),
        hooks: AgentTaskStoreHooks = AgentTaskStoreHooks()
    ) {
        self.privateComponentCount = privateComponentCount
        self.cleanup = cleanup
        self.hooks = hooks
    }
    #else
    init(
        privateComponentCount: Int? = nil,
        cleanup: AgentTaskCleanupConfiguration = AgentTaskCleanupConfiguration()
    ) {
        self.privateComponentCount = privateComponentCount
        self.cleanup = cleanup
    }
    #endif
}

nonisolated enum AgentTaskMetadataRejection: Error, Equatable, Sendable {
    case corrupt
    case unknownSchema
    case missingProject
    case invalidMetadata
    case storageLimit
    case ioFailure
    case unsafeFilesystemObject
    case lockContention
    case transientIO
    case durabilityUnknown
    case concurrentMutation
    case superseded
}

nonisolated enum AgentTaskMetadataSaveResult: Equatable, Sendable {
    case saved(taskCount: Int)
    case publishedButDurabilityUnknown(taskCount: Int, revision: UUID)
    case rejected(AgentTaskMetadataRejection)

    var isDurablySaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

nonisolated enum AgentTaskMetadataLoadStatus: Equatable, Sendable {
    case missing
    case loaded
    case loadedWithMissingWorktrees(Int)
    case rejected(AgentTaskMetadataRejection)
}

nonisolated enum AgentTaskDiskRevision: Equatable, Hashable, Sendable {
    case versioned(UUID)
    case legacySHA256(Data)
}

nonisolated struct AgentTaskMetadataLoadResult: Sendable {
    let status: AgentTaskMetadataLoadStatus
    let tasks: [AgentTask]
    let revision: AgentTaskDiskRevision?
    let requiresMigration: Bool

    init(
        status: AgentTaskMetadataLoadStatus,
        tasks: [AgentTask],
        revision: AgentTaskDiskRevision? = nil,
        requiresMigration: Bool = false
    ) {
        self.status = status
        self.tasks = tasks
        self.revision = revision
        self.requiresMigration = requiresMigration
    }
}

nonisolated struct AgentTaskPersistenceTicket: Equatable, Hashable, Sendable {
    let generation: UUID
    let sequence: UInt64
    let projectKey: String
    let expectedDiskRevision: AgentTaskDiskRevision?
    let nextDiskRevision: UUID

    init(
        generation: UUID,
        sequence: UInt64,
        projectKey: String,
        expectedDiskRevision: AgentTaskDiskRevision? = nil,
        nextDiskRevision: UUID = UUID()
    ) {
        self.generation = generation
        self.sequence = sequence
        self.projectKey = projectKey
        self.expectedDiskRevision = expectedDiskRevision
        self.nextDiskRevision = nextDiskRevision
    }
}

nonisolated enum AgentTaskPublicationDecision: Sendable {
    case published
    case failed
    case superseded
}

/// The short state lock protects authorization and receipts. A separate
/// publication lock serializes final renames, but generation advancement never
/// waits for filesystem I/O: an operation that already passed its final check
/// may finish and publish a receipt, while every later generation waits behind
/// it and revalidates CAS before rename.
nonisolated final class AgentTaskPublicationFence: @unchecked Sendable {
    private let stateLock = NSLock()
    private let publicationLock = NSLock()
    private var generation: UUID
    private var latestTicketByProject: [String: AgentTaskPersistenceTicket] = [:]
    private var publishedRevisionByProject: [String: AgentTaskDiskRevision] = [:]

    init(generation: UUID) {
        self.generation = generation
    }

    func authorize(_ ticket: AgentTaskPersistenceTicket) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard ticket.generation == generation else { return }
        if let latest = latestTicketByProject[ticket.projectKey],
           latest.sequence >= ticket.sequence {
            return
        }
        latestTicketByProject[ticket.projectKey] = ticket
    }

    @discardableResult
    func advance(to generation: UUID) -> [String: AgentTaskDiskRevision] {
        stateLock.lock()
        defer { stateLock.unlock() }
        let published = publishedRevisionByProject
        self.generation = generation
        latestTicketByProject.removeAll(keepingCapacity: true)
        return published
    }

    func publishedRevision(
        for projectKey: String
    ) -> AgentTaskDiskRevision? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return publishedRevisionByProject[projectKey]
    }

    fileprivate func publish(
        _ ticket: AgentTaskPersistenceTicket,
        operation: () -> Bool
    ) -> AgentTaskPublicationDecision {
        publicationLock.lock()
        defer { publicationLock.unlock() }

        stateLock.lock()
        let isAuthorized = generation == ticket.generation
            && latestTicketByProject[ticket.projectKey] == ticket
        stateLock.unlock()
        guard isAuthorized else { return .superseded }
        guard operation() else { return .failed }

        stateLock.lock()
        publishedRevisionByProject[ticket.projectKey] = .versioned(
            ticket.nextDiskRevision
        )
        stateLock.unlock()
        return .published
    }
}

nonisolated struct AgentTaskPublicationAuthorization: Sendable {
    let ticket: AgentTaskPersistenceTicket
    fileprivate let fence: AgentTaskPublicationFence

    init(ticket: AgentTaskPersistenceTicket, fence: AgentTaskPublicationFence) {
        self.ticket = ticket
        self.fence = fence
    }

    fileprivate func publish(operation: () -> Bool) -> AgentTaskPublicationDecision {
        fence.publish(ticket, operation: operation)
    }

    #if DEBUG
    func publishForTesting(
        operation: () -> Bool
    ) -> AgentTaskPublicationDecision {
        publish(operation: operation)
    }
    #endif
}

nonisolated protocol AgentTaskPersisting: Sendable {
    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult

    func load(
        project: AgentTaskProjectIdentity
    ) async -> AgentTaskMetadataLoadResult
}

nonisolated extension AgentTaskPersisting {
    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity
    ) async -> AgentTaskMetadataSaveResult {
        await save(tasks: tasks, project: project, authorization: nil)
    }
}

nonisolated private struct AgentTaskMetadataHeader: Decodable, Sendable {
    let schemaVersion: Int
    let revision: UUID?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
    }
}

nonisolated private struct AgentTaskMetadataEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let revision: UUID
    let canonicalProjectPath: String
    let canonicalWorktreePath: String
    let tasks: [AgentTask]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case canonicalProjectPath
        case canonicalWorktreePath
        case tasks
    }
}

nonisolated private struct AgentTaskLegacyMetadataEnvelope: Decodable, Sendable {
    let schemaVersion: Int
    let canonicalProjectPath: String
    let canonicalWorktreePath: String
    let tasks: [AgentTask]
}

nonisolated private enum AgentTaskSecureReadResult: Sendable {
    case data(Data)
    case missing
    case rejected(AgentTaskMetadataRejection)
}

nonisolated private enum AgentTaskDirectoryError: Error, Sendable {
    case missing
    case unsafe
    case transient
    case durabilityUnknown
    case durabilityUnknownAfterPublication
    case lockContention
    case superseded
    case storageLimit
}

nonisolated private struct AgentTaskCleanupDirectory: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

nonisolated private struct AgentTaskCleanupCandidate: Sendable {
    let name: String
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

nonisolated private final class AgentTaskStorageHandle {
    let descriptors: [Int32]
    let componentNames: [String]
    let privateDescriptorStart: Int

    init(
        descriptors: [Int32],
        componentNames: [String],
        privateDescriptorStart: Int
    ) {
        self.descriptors = descriptors
        self.componentNames = componentNames
        self.privateDescriptorStart = privateDescriptorStart
    }

    var leaf: Int32 { descriptors[descriptors.count - 1] }

    deinit {
        for descriptor in descriptors.reversed() { Darwin.close(descriptor) }
    }
}

/// Serializes all metadata I/O away from MainActor. Files are scoped by a hash
/// of the canonical project path and contain value metadata only.
actor AgentTaskMetadataStore: AgentTaskPersisting {
    static let currentSchemaVersion = 2
    private static let directoryName = ".pine-agent-tasks-private"

    private let storageRoot: URL?
    private let limits: AgentTaskPersistenceLimits
    private let configuration: AgentTaskStoreConfiguration
    private let fileManager = FileManager()
    private var cleanupCursorByDirectory: [AgentTaskCleanupDirectory: Int] = [:]

    init(
        storageRoot: URL? = nil,
        limits: AgentTaskPersistenceLimits = AgentTaskPersistenceLimits(),
        configuration: AgentTaskStoreConfiguration = AgentTaskStoreConfiguration()
    ) {
        self.storageRoot = storageRoot
        self.limits = limits
        self.configuration = configuration
    }

    nonisolated static func metadataURL(
        for project: AgentTaskProjectIdentity,
        storageRoot: URL
    ) -> URL {
        let digest = SHA256.hash(
            data: Data(project.persistenceKey.utf8)
        )
        let fileName = digest.prefix(16)
            .map { String(format: "%02x", $0) }
            .joined() + ".json"
        return storageRoot.appendingPathComponent(fileName)
    }

    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) -> AgentTaskMetadataSaveResult {
        guard !Task.isCancelled else { return .rejected(.superseded) }
        guard canonicalExistingDirectory(project.canonicalProjectPath)
                == project.canonicalProjectPath else {
            return .rejected(.missingProject)
        }
        let bounded: [AgentTask]
        switch boundedTasks(tasks, project: project) {
        case .success(let value): bounded = value
        case .failure(let rejection): return .rejected(rejection)
        }
        let nextDiskRevision = authorization?.ticket.nextDiskRevision ?? UUID()
        let envelope = AgentTaskMetadataEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            revision: nextDiskRevision,
            canonicalProjectPath: project.canonicalProjectPath,
            canonicalWorktreePath: project.canonicalWorktreePath,
            tasks: bounded
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(envelope) else {
            return .rejected(.invalidMetadata)
        }
        data.append(0x0A)
        guard data.count <= limits.maxFileBytes else {
            return .rejected(.storageLimit)
        }

        do {
            let directory = resolvedStorageRoot()
            let storage = try openStorageDirectory(
                directory,
                create: true
            )
            guard verifyStorageChain(storage) else {
                throw AgentTaskDirectoryError.unsafe
            }
            let lock = try acquireLock(storage.leaf)
            defer { releaseLock(lock) }
            reportPhase(.lockAcquired)
            guard verifyStorageChain(storage),
                  verifyLock(lock, directoryDescriptor: storage.leaf) else {
                throw AgentTaskDirectoryError.unsafe
            }
            let fileURL = Self.metadataURL(
                for: project,
                storageRoot: directory
            )
            try preflightPrivateFile(
                fileURL.lastPathComponent,
                directoryDescriptor: storage.leaf,
                allowsMissing: true
            )
            guard verifyStorageChain(storage),
                  verifyLock(lock, directoryDescriptor: storage.leaf) else {
                throw AgentTaskDirectoryError.unsafe
            }
            guard !Task.isCancelled else {
                throw AgentTaskDirectoryError.superseded
            }
            cleanupStaleTemporaryFiles(
                directoryDescriptor: storage.leaf,
                verifyContext: {
                    self.verifyStorageChain(storage)
                        && self.verifyLock(
                            lock,
                            directoryDescriptor: storage.leaf
                        )
                }
            )
            try secureAtomicWrite(
                data,
                fileName: fileURL.lastPathComponent,
                directoryDescriptor: storage.leaf,
                authorization: authorization,
                verifyContext: {
                    self.verifyStorageChain(storage)
                        && self.verifyLock(
                            lock,
                            directoryDescriptor: storage.leaf
                        )
                }
            )
            guard verifyStorageChain(storage),
                  verifyLock(lock, directoryDescriptor: storage.leaf) else {
                throw AgentTaskDirectoryError.durabilityUnknownAfterPublication
            }
            return .saved(taskCount: bounded.count)
        } catch AgentTaskDirectoryError.unsafe {
            return .rejected(.unsafeFilesystemObject)
        } catch AgentTaskDirectoryError.durabilityUnknown {
            return .rejected(.durabilityUnknown)
        } catch AgentTaskDirectoryError.durabilityUnknownAfterPublication {
            return .publishedButDurabilityUnknown(
                taskCount: bounded.count,
                revision: nextDiskRevision
            )
        } catch AgentTaskDirectoryError.superseded {
            return .rejected(.superseded)
        } catch AgentTaskDirectoryError.storageLimit {
            return .rejected(.storageLimit)
        } catch AgentTaskDirectoryError.lockContention {
            return .rejected(.lockContention)
        } catch AgentTaskDirectoryError.transient {
            return .rejected(.transientIO)
        } catch {
            return .rejected(.transientIO)
        }
    }

    func load(
        project: AgentTaskProjectIdentity
    ) -> AgentTaskMetadataLoadResult {
        guard canonicalExistingDirectory(project.canonicalProjectPath)
                == project.canonicalProjectPath else {
            return rejectedLoad(.missingProject)
        }
        let fileURL = Self.metadataURL(
            for: project,
            storageRoot: resolvedStorageRoot()
        )
        let storage: AgentTaskStorageHandle
        do {
            storage = try openStorageDirectory(
                resolvedStorageRoot(),
                create: false
            )
        } catch AgentTaskDirectoryError.missing {
            return AgentTaskMetadataLoadResult(status: .missing, tasks: [])
        } catch AgentTaskDirectoryError.unsafe {
            return rejectedLoad(.unsafeFilesystemObject)
        } catch {
            return rejectedLoad(.transientIO)
        }
        let lock: Int32
        do {
            guard verifyStorageChain(storage) else {
                throw AgentTaskDirectoryError.unsafe
            }
            lock = try acquireLock(storage.leaf)
        } catch AgentTaskDirectoryError.unsafe {
            return rejectedLoad(.unsafeFilesystemObject)
        } catch AgentTaskDirectoryError.lockContention {
            return rejectedLoad(.lockContention)
        } catch {
            return rejectedLoad(.transientIO)
        }
        defer { releaseLock(lock) }
        reportPhase(.lockAcquired)
        guard verifyStorageChain(storage),
              verifyLock(lock, directoryDescriptor: storage.leaf) else {
            return rejectedLoad(.unsafeFilesystemObject)
        }
        do {
            try preflightPrivateFile(
                fileURL.lastPathComponent,
                directoryDescriptor: storage.leaf,
                allowsMissing: true
            )
        } catch AgentTaskDirectoryError.unsafe {
            return rejectedLoad(.unsafeFilesystemObject)
        } catch {
            return rejectedLoad(.transientIO)
        }
        guard verifyStorageChain(storage),
              verifyLock(lock, directoryDescriptor: storage.leaf) else {
            return rejectedLoad(.unsafeFilesystemObject)
        }
        cleanupStaleTemporaryFiles(
            directoryDescriptor: storage.leaf,
            verifyContext: {
                self.verifyStorageChain(storage)
                    && self.verifyLock(
                        lock,
                        directoryDescriptor: storage.leaf
                    )
            }
        )
        let read = secureBoundedRead(
            fileName: fileURL.lastPathComponent,
            directoryDescriptor: storage.leaf
        )
        guard verifyStorageChain(storage),
              verifyLock(lock, directoryDescriptor: storage.leaf) else {
            return rejectedLoad(.unsafeFilesystemObject)
        }
        let data: Data
        switch read {
        case .data(let value): data = value
        case .missing:
            return AgentTaskMetadataLoadResult(status: .missing, tasks: [])
        case .rejected(let rejection):
            return rejectedLoad(rejection)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let header = try? decoder.decode(
            AgentTaskMetadataHeader.self,
            from: data
        ) else {
            return rejectedLoad(.corrupt)
        }
        let storedProjectPath: String
        let storedWorktreePath: String
        let storedTasks: [AgentTask]
        let revision: AgentTaskDiskRevision?
        let requiresMigration: Bool
        switch header.schemaVersion {
        case 1:
            guard let envelope = try? decoder.decode(
                AgentTaskLegacyMetadataEnvelope.self,
                from: data
            ) else {
                return rejectedLoad(.corrupt)
            }
            storedProjectPath = envelope.canonicalProjectPath
            storedWorktreePath = envelope.canonicalWorktreePath
            storedTasks = envelope.tasks
            revision = .legacySHA256(Data(SHA256.hash(data: data)))
            requiresMigration = true
        case Self.currentSchemaVersion:
            guard let envelope = try? decoder.decode(
                AgentTaskMetadataEnvelope.self,
                from: data
            ) else {
                return rejectedLoad(.corrupt)
            }
            storedProjectPath = envelope.canonicalProjectPath
            storedWorktreePath = envelope.canonicalWorktreePath
            storedTasks = envelope.tasks
            revision = .versioned(envelope.revision)
            requiresMigration = false
        default:
            return rejectedLoad(.unknownSchema)
        }
        guard storedProjectPath == project.canonicalProjectPath,
              storedWorktreePath == project.canonicalWorktreePath,
              storedTasks.count <= limits.maxTasksPerProject,
              validateLoadedTasks(storedTasks, project: project) else {
            return rejectedLoad(.invalidMetadata)
        }

        var tasks = storedTasks
        var missingWorktrees = 0
        for index in tasks.indices where canonicalExistingDirectory(
            tasks[index].project.canonicalWorktreePath
        ) != tasks[index].project.canonicalWorktreePath {
            missingWorktrees += 1
            tasks[index].route.availability = .missing
        }
        let status: AgentTaskMetadataLoadStatus = missingWorktrees == 0
            ? .loaded
            : .loadedWithMissingWorktrees(missingWorktrees)
        return AgentTaskMetadataLoadResult(
            status: status,
            tasks: tasks,
            revision: revision,
            requiresMigration: requiresMigration
        )
    }

    private func resolvedStorageRoot() -> URL {
        if let storageRoot {
            return storageRoot.standardizedFileURL
        }
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return URL(fileURLWithPath: "/dev/null/pine-agent-tasks")
        }
        return base.resolvingSymlinksInPath()
            .appendingPathComponent(Self.directoryName)
    }

    private func openStorageDirectory(
        _ url: URL,
        create: Bool
    ) throws -> AgentTaskStorageHandle {
        let components = url.standardizedFileURL.pathComponents.dropFirst()
        let names = Array(components)
        let privateCount = configuration.privateComponentCount
            ?? (storageRoot == nil ? 2 : 1)
        guard !names.isEmpty, (1...names.count).contains(privateCount) else {
            throw AgentTaskDirectoryError.unsafe
        }
        let privateComponentStart = max(0, names.count - privateCount)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentTaskDirectoryError.transient }
        var descriptors = [descriptor]
        var transferred = false
        defer {
            if !transferred {
                for openDescriptor in descriptors.reversed() {
                    Darwin.close(openDescriptor)
                }
            }
        }
        for (componentIndex, component) in names.enumerated() {
            var created = false
            var next = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if next < 0, errno == ENOENT, create {
                guard componentIndex >= privateComponentStart,
                      verifyDescriptorLinks(
                          descriptors: descriptors,
                          names: Array(names.prefix(componentIndex)),
                          privateDescriptorStart: privateComponentStart + 1
                      ) else {
                    throw AgentTaskDirectoryError.unsafe
                }
                guard mkdirat(descriptor, component, mode_t(0o700)) == 0
                        || errno == EEXIST else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                created = true
                guard durableSync(
                    descriptor,
                    target: .parentDirectory
                ) else {
                    throw AgentTaskDirectoryError.durabilityUnknown
                }
                next = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard next >= 0 else {
                let wasMissing = errno == ENOENT
                throw wasMissing
                    ? AgentTaskDirectoryError.missing
                    : AgentTaskDirectoryError.unsafe
            }
            descriptor = next
            descriptors.append(next)
            var opened = stat()
            var live = stat()
            guard fstat(next, &opened) == 0,
                  fstatat(descriptors[descriptors.count - 2], component, &live,
                          AT_SYMLINK_NOFOLLOW) == 0,
                  sameObject(opened, live) else {
                throw AgentTaskDirectoryError.unsafe
            }
            if componentIndex >= privateComponentStart {
                guard opened.st_uid == getuid(),
                      (opened.st_mode & S_IFMT) == S_IFDIR,
                      (opened.st_mode & 0o777) == 0o700,
                      descriptorHasNoExtendedACL(next) else {
                    throw AgentTaskDirectoryError.unsafe
                }
            }
            guard !created || durableSync(
                next,
                target: .createdDirectory
            ) else {
                throw AgentTaskDirectoryError.durabilityUnknown
            }
        }
        guard verifyDescriptorLinks(
            descriptors: descriptors,
            names: names,
            privateDescriptorStart: privateComponentStart + 1
        ) else {
            throw AgentTaskDirectoryError.unsafe
        }
        transferred = true
        reportPhase(.directoryOpened)
        return AgentTaskStorageHandle(
            descriptors: descriptors,
            componentNames: names,
            privateDescriptorStart: privateComponentStart + 1
        )
    }

    private func verifyStorageChain(_ storage: AgentTaskStorageHandle) -> Bool {
        verifyDescriptorLinks(
            descriptors: storage.descriptors,
            names: storage.componentNames,
            privateDescriptorStart: storage.privateDescriptorStart
        )
    }

    private func verifyDescriptorLinks(
        descriptors: [Int32],
        names: [String],
        privateDescriptorStart: Int
    ) -> Bool {
        guard descriptors.count == names.count + 1 else { return false }
        for index in descriptors.indices {
            var opened = stat()
            guard fstat(descriptors[index], &opened) == 0 else { return false }
            if index > 0 {
                var live = stat()
                guard fstatat(
                    descriptors[index - 1], names[index - 1], &live,
                    AT_SYMLINK_NOFOLLOW
                ) == 0, sameObject(opened, live) else { return false }
            }
            if index >= privateDescriptorStart {
                guard opened.st_uid == getuid(),
                      (opened.st_mode & S_IFMT) == S_IFDIR,
                      (opened.st_mode & 0o777) == 0o700,
                      descriptorHasNoExtendedACL(descriptors[index]) else {
                    return false
                }
            }
        }
        return true
    }

    private func acquireLock(_ directoryDescriptor: Int32) throws -> Int32 {
        try preflightPrivateFile(
            ".agent-tasks.lock",
            directoryDescriptor: directoryDescriptor,
            allowsMissing: true
        )
        let descriptor = openat(
            directoryDescriptor,
            ".agent-tasks.lock",
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw unsafeOpenError(errno)
                ? AgentTaskDirectoryError.unsafe
                : AgentTaskDirectoryError.transient
        }
        guard verifyLock(descriptor, directoryDescriptor: directoryDescriptor) else {
            Darwin.close(descriptor)
            throw AgentTaskDirectoryError.unsafe
        }
        var lockResult: Int32
        repeat {
            lockResult = flock(descriptor, LOCK_EX | LOCK_NB)
        } while lockResult != 0 && errno == EINTR
        guard lockResult == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw failure == EWOULDBLOCK
                ? AgentTaskDirectoryError.lockContention
                : AgentTaskDirectoryError.transient
        }
        guard verifyLock(descriptor, directoryDescriptor: directoryDescriptor) else {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw AgentTaskDirectoryError.unsafe
        }
        return descriptor
    }

    private func verifyLock(
        _ descriptor: Int32,
        directoryDescriptor: Int32
    ) -> Bool {
        var opened = stat()
        var live = stat()
        return fstat(descriptor, &opened) == 0
            && fstatat(directoryDescriptor, ".agent-tasks.lock", &live,
                       AT_SYMLINK_NOFOLLOW) == 0
            && samePrivateFile(opened, live)
            && descriptorHasNoExtendedACL(descriptor)
    }

    private func releaseLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private func secureBoundedRead(
        fileName: String,
        directoryDescriptor: Int32
    ) -> AgentTaskSecureReadResult {
        reportPhase(.beforeReadOpen)
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0, errno == ENOENT { return .missing }
        guard descriptor >= 0 else {
            return .rejected(
                errno == ELOOP ? .unsafeFilesystemObject : .transientIO
            )
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        var liveBefore = stat()
        guard fstat(descriptor, &info) == 0,
              fstatat(
                  directoryDescriptor,
                  fileName,
                  &liveBefore,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              samePrivateFile(info, liveBefore),
              descriptorHasNoExtendedACL(descriptor),
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o077) == 0,
              info.st_size >= 0 else {
            return .rejected(.unsafeFilesystemObject)
        }
        guard UInt64(info.st_size) <= UInt64(limits.maxFileBytes) else {
            return .rejected(.storageLimit)
        }
        reportPhase(.readOpened)
        var data = Data(count: Int(info.st_size))
        let succeeded = data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard succeeded else {
            var changed = stat()
            if fstat(descriptor, &changed) == 0,
               changed.st_size != info.st_size {
                return .rejected(.concurrentMutation)
            }
            return .rejected(.transientIO)
        }
        var extra: UInt8 = 0
        var extraCount: Int
        repeat {
            extraCount = Darwin.read(descriptor, &extra, 1)
        } while extraCount < 0 && errno == EINTR
        var after = stat()
        var live = stat()
        guard extraCount == 0,
              fstat(descriptor, &after) == 0,
              fstatat(
                  directoryDescriptor,
                  fileName,
                  &live,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              stableReadIdentity(info, after),
              samePrivateFile(after, live) else {
            return .rejected(.concurrentMutation)
        }
        return .data(data)
    }

    private func secureAtomicWrite(
        _ data: Data,
        fileName: String,
        directoryDescriptor: Int32,
        authorization: AgentTaskPublicationAuthorization?,
        verifyContext: () -> Bool
    ) throws {
        guard verifyContext() else { throw AgentTaskDirectoryError.unsafe }
        let initialFinalIdentity = try existingPrivateFileIdentity(
            fileName,
            directoryDescriptor: directoryDescriptor,
            allowsMissing: true
        )
        if let authorization,
           !diskRevisionMatches(
               authorization.ticket.expectedDiskRevision,
               fileName: fileName,
               directoryDescriptor: directoryDescriptor
           ) {
            throw AgentTaskDirectoryError.superseded
        }
        try enforceTombstoneCapacity(directoryDescriptor)
        let temporaryName = ".agent-tasks-\(UUID().uuidString).tmp"
        reportPhase(.beforeTemporaryCreate)
        guard verifyContext() else { throw AgentTaskDirectoryError.unsafe }
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        var published = false
        var writerIdentity: stat?
        defer {
            Darwin.close(descriptor)
            if !published,
               let writerIdentity {
                retirePrivateFileIfUnchanged(
                    temporaryName,
                    expectedDevice: UInt64(writerIdentity.st_dev),
                    expectedInode: UInt64(writerIdentity.st_ino),
                    directoryDescriptor: directoryDescriptor,
                    verifyContext: verifyContext
                )
            }
        }
        var opened = stat()
        var live = stat()
        guard verifyContext(),
              fstat(descriptor, &opened) == 0,
              fstatat(
                  directoryDescriptor,
                  temporaryName,
                  &live,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              samePrivateFile(opened, live),
              descriptorHasNoExtendedACL(descriptor) else {
            throw AgentTaskDirectoryError.unsafe
        }
        writerIdentity = opened
        try writeAll(data, descriptor: descriptor)
        guard durableSync(descriptor, target: .metadataFile) else {
            throw AgentTaskDirectoryError.durabilityUnknown
        }
        reportPhase(.temporaryWritten)
        guard verifyContext(),
              fstat(descriptor, &opened) == 0,
              fstatat(
                  directoryDescriptor,
                  temporaryName,
                  &live,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              samePrivateFile(opened, live),
              descriptorHasNoExtendedACL(descriptor) else {
            throw AgentTaskDirectoryError.unsafe
        }
        reportPhase(.beforePublish)
        guard verifyContext(),
              fstat(descriptor, &opened) == 0,
              fstatat(
                  directoryDescriptor,
                  temporaryName,
                  &live,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              samePrivateFile(opened, live),
              descriptorHasNoExtendedACL(descriptor),
              privateFileUnchanged(
                  initialFinalIdentity,
                  name: fileName,
                  directoryDescriptor: directoryDescriptor
              ) else {
            throw AgentTaskDirectoryError.unsafe
        }
        guard !Task.isCancelled,
              verifyContext(),
              fstat(descriptor, &opened) == 0,
              fstatat(
                directoryDescriptor,
                temporaryName,
                &live,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              samePrivateFile(opened, live),
              descriptorHasNoExtendedACL(descriptor),
              privateFileUnchanged(
                initialFinalIdentity,
                name: fileName,
                directoryDescriptor: directoryDescriptor
              ) else {
            throw AgentTaskDirectoryError.unsafe
        }
        let publish = {
            guard verifyContext(),
                  fstat(descriptor, &opened) == 0,
                  fstatat(
                    directoryDescriptor,
                    temporaryName,
                    &live,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  samePrivateFile(opened, live),
                  descriptorHasNoExtendedACL(descriptor),
                  privateFileUnchanged(
                    initialFinalIdentity,
                    name: fileName,
                    directoryDescriptor: directoryDescriptor
                  ),
                  authorization.map({
                    self.diskRevisionMatches(
                        $0.ticket.expectedDiskRevision,
                        fileName: fileName,
                        directoryDescriptor: directoryDescriptor
                    )
                  }) ?? true else {
                return false
            }
            return renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                fileName
            ) == 0
        }
        let decision = authorization?.publish(operation: publish)
            ?? (publish() ? .published : .failed)
        switch decision {
        case .published:
            break
        case .failed:
            throw CocoaError(.fileWriteUnknown)
        case .superseded:
            throw AgentTaskDirectoryError.superseded
        }
        published = true
        guard verifyContext(),
              fstatat(
                  directoryDescriptor,
                  fileName,
                  &live,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              samePrivateFile(opened, live),
              descriptorHasNoExtendedACL(descriptor) else {
            throw AgentTaskDirectoryError.durabilityUnknownAfterPublication
        }
        guard durableSync(
            directoryDescriptor,
            target: .storageDirectory
        ) else {
            throw AgentTaskDirectoryError.durabilityUnknownAfterPublication
        }
        guard verifyContext() else {
            throw AgentTaskDirectoryError.durabilityUnknownAfterPublication
        }
    }

    private func diskRevisionMatches(
        _ expected: AgentTaskDiskRevision?,
        fileName: String,
        directoryDescriptor: Int32
    ) -> Bool {
        switch secureBoundedRead(
            fileName: fileName,
            directoryDescriptor: directoryDescriptor
        ) {
        case .missing:
            return expected == nil
        case .rejected:
            return false
        case .data(let data):
            let decoder = JSONDecoder()
            guard let header = try? decoder.decode(
                AgentTaskMetadataHeader.self,
                from: data
            ) else { return false }
            if header.schemaVersion == 1, header.revision == nil {
                return expected == .legacySHA256(Data(SHA256.hash(data: data)))
            }
            guard header.schemaVersion == Self.currentSchemaVersion,
                  let revision = header.revision else { return false }
            return expected == .versioned(revision)
        }
    }

    private func durableSync(
        _ descriptor: Int32,
        target: AgentTaskSyncTarget
    ) -> Bool {
        guard shouldAttemptSync(target) else { return false }
        #if os(macOS)
        if fcntl(descriptor, F_FULLFSYNC) == 0 {
            reportSync(target)
            return true
        }
        #endif
        let succeeded = Darwin.fsync(descriptor) == 0
        if succeeded { reportSync(target) }
        return succeeded
    }

    private func reportPhase(_ phase: AgentTaskStorePhase) {
        #if DEBUG
        configuration.hooks.phase(phase)
        #endif
    }

    private func shouldAttemptSync(_ target: AgentTaskSyncTarget) -> Bool {
        #if DEBUG
        return configuration.hooks.shouldSync(target)
        #else
        return true
        #endif
    }

    private func reportSync(_ target: AgentTaskSyncTarget) {
        #if DEBUG
        configuration.hooks.didSync(target)
        #endif
    }

    private func enforceTombstoneCapacity(
        _ directoryDescriptor: Int32
    ) throws {
        let duplicate = Darwin.dup(directoryDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw AgentTaskDirectoryError.transient
        }
        defer { closedir(directory) }
        var scanned = 0
        var tombstones = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0)
                    .assumingMemoryBound(to: CChar.self))
            }
            guard name != ".", name != ".." else { continue }
            scanned += 1
            guard scanned < configuration.cleanup.directoryEntryLimit else {
                throw AgentTaskDirectoryError.storageLimit
            }
            guard isCanonicalTemporaryName(name) else { continue }
            var info = stat()
            guard fstatat(
                directoryDescriptor,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                if errno == ENOENT { continue }
                throw AgentTaskDirectoryError.transient
            }
            guard info.st_uid == getuid(),
                  info.st_nlink == 1,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  (info.st_mode & 0o777) == 0 else { continue }
            tombstones += 1
            guard tombstones < configuration.cleanup.tombstoneLimit else {
                throw AgentTaskDirectoryError.storageLimit
            }
        }
    }

    private func isCanonicalTemporaryName(_ name: String) -> Bool {
        let prefix = ".agent-tasks-"
        guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else {
            return false
        }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -4)
        let identifier = String(name[start..<end])
        guard let parsed = UUID(uuidString: identifier) else { return false }
        return parsed.uuidString == identifier.uppercased()
    }

    private func cleanupStaleTemporaryFiles(
        directoryDescriptor: Int32,
        verifyContext: () -> Bool
    ) {
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0 else { return }
        let identity = AgentTaskCleanupDirectory(
            device: UInt64(directoryInfo.st_dev),
            inode: UInt64(directoryInfo.st_ino)
        )
        guard let directory = fdopendir(dup(directoryDescriptor)) else { return }
        defer { closedir(directory) }
        if let cursor = cleanupCursorByDirectory[identity], cursor > 0 {
            seekdir(directory, cursor)
        }
        var scanned = 0
        var reachedEnd = false
        var candidates: [AgentTaskCleanupCandidate] = []
        let staleBefore = configuration.cleanup.now().timeIntervalSince1970
            - configuration.cleanup.staleAge
        while scanned < configuration.cleanup.scanLimit {
            guard let entry = readdir(directory) else {
                reachedEnd = true
                break
            }
            scanned += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0)
                    .assumingMemoryBound(to: CChar.self))
            }
            guard isCanonicalTemporaryName(name) else { continue }
            var info = stat()
            guard fstatat(
                directoryDescriptor,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            info.st_uid == getuid(),
            info.st_nlink == 1,
            (info.st_mode & S_IFMT) == S_IFREG,
            (info.st_mode & 0o777) == 0o600,
            TimeInterval(info.st_mtimespec.tv_sec) <= staleBefore else {
                continue
            }
            candidates.append(AgentTaskCleanupCandidate(
                name: name,
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
            ))
        }
        if reachedEnd {
            cleanupCursorByDirectory[identity] = 0
        } else {
            cleanupCursorByDirectory[identity] = max(0, telldir(directory))
        }
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.modifiedSeconds != rhs.modifiedSeconds {
                return lhs.modifiedSeconds < rhs.modifiedSeconds
            }
            if lhs.modifiedNanoseconds != rhs.modifiedNanoseconds {
                return lhs.modifiedNanoseconds < rhs.modifiedNanoseconds
            }
            return lhs.name < rhs.name
        }
        for candidate in ordered.prefix(configuration.cleanup.retireLimit) {
            retireCleanupCandidateIfUnchanged(
                candidate,
                directoryDescriptor: directoryDescriptor,
                verifyContext: verifyContext
            )
        }
    }

    private func retireCleanupCandidateIfUnchanged(
        _ candidate: AgentTaskCleanupCandidate,
        directoryDescriptor: Int32,
        verifyContext: () -> Bool
    ) {
        reportPhase(.beforeCleanupRetire)
        retirePrivateFileIfUnchanged(
            candidate.name,
            expectedDevice: candidate.device,
            expectedInode: candidate.inode,
            directoryDescriptor: directoryDescriptor,
            verifyContext: verifyContext
        )
    }

    private func retirePrivateFileIfUnchanged(
        _ fileName: String,
        expectedDevice: UInt64,
        expectedInode: UInt64,
        directoryDescriptor: Int32,
        verifyContext: () -> Bool
    ) {
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var live = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(
                directoryDescriptor,
                fileName,
                &live,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              UInt64(opened.st_dev) == expectedDevice,
              UInt64(opened.st_ino) == expectedInode,
              exactPrivateIdentity(opened, live),
              descriptorHasNoExtendedACL(descriptor) else { return }
        reportPhase(.beforeRetireMutation)
        var finalOpened = stat()
        var finalLive = stat()
        guard verifyContext(),
              fstat(descriptor, &finalOpened) == 0,
              fstatat(
                  directoryDescriptor,
                  fileName,
                  &finalLive,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              UInt64(finalOpened.st_dev) == expectedDevice,
              UInt64(finalOpened.st_ino) == expectedInode,
              exactPrivateIdentity(finalOpened, finalLive),
              descriptorHasNoExtendedACL(descriptor) else { return }
        guard ftruncate(descriptor, 0) == 0,
              verifyContext(),
              fstat(descriptor, &finalOpened) == 0,
              fstatat(
                directoryDescriptor,
                fileName,
                &finalLive,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              UInt64(finalOpened.st_dev) == expectedDevice,
              UInt64(finalOpened.st_ino) == expectedInode,
              exactPrivateIdentity(finalOpened, finalLive),
              descriptorHasNoExtendedACL(descriptor) else { return }
        _ = fchmod(descriptor, mode_t(0o000))
    }

    private func descriptorHasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT
        }
        _ = acl_free(UnsafeMutableRawPointer(acl))
        return false
    }

    private func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private func samePrivateFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameObject(lhs, rhs)
            && lhs.st_uid == getuid()
            && rhs.st_uid == getuid()
            && lhs.st_nlink == 1
            && rhs.st_nlink == 1
            && (lhs.st_mode & S_IFMT) == S_IFREG
            && (rhs.st_mode & S_IFMT) == S_IFREG
            && (lhs.st_mode & 0o777) == 0o600
            && (rhs.st_mode & 0o777) == 0o600
    }

    private func exactPrivateIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        samePrivateFile(lhs, rhs)
            && lhs.st_mode == rhs.st_mode
    }

    private func preflightPrivateFile(
        _ name: String,
        directoryDescriptor: Int32,
        allowsMissing: Bool
    ) throws {
        _ = try existingPrivateFileIdentity(
            name,
            directoryDescriptor: directoryDescriptor,
            allowsMissing: allowsMissing
        )
    }

    private func existingPrivateFileIdentity(
        _ name: String,
        directoryDescriptor: Int32,
        allowsMissing: Bool
    ) throws -> stat? {
        var info = stat()
        if fstatat(
            directoryDescriptor,
            name,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard info.st_uid == getuid(),
                  info.st_nlink == 1,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  (info.st_mode & 0o777) == 0o600 else {
                throw AgentTaskDirectoryError.unsafe
            }
            return info
        }
        if allowsMissing, errno == ENOENT { return nil }
        throw unsafeOpenError(errno)
            ? AgentTaskDirectoryError.unsafe
            : AgentTaskDirectoryError.transient
    }

    private func privateFileUnchanged(
        _ initial: stat?,
        name: String,
        directoryDescriptor: Int32
    ) -> Bool {
        var current = stat()
        let result = fstatat(
            directoryDescriptor,
            name,
            &current,
            AT_SYMLINK_NOFOLLOW
        )
        if let initial {
            return result == 0 && exactPrivateIdentity(initial, current)
        }
        return result < 0 && errno == ENOENT
    }

    private func unsafeOpenError(_ code: Int32) -> Bool {
        code == ELOOP || code == ENOTDIR || code == EISDIR
    }

    private func stableReadIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        sameObject(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                offset += count
            }
        }
    }

    private func boundedTasks(
        _ tasks: [AgentTask],
        project: AgentTaskProjectIdentity
    ) -> Result<[AgentTask], AgentTaskMetadataRejection> {
        var identifiers = Set<UUID>()
        var sessionIdentifiers = Set<UUID>()
        var candidates: [AgentTask] = []
        for task in tasks where task.project == project {
            guard identifiers.insert(task.id).inserted,
                  validateTask(task),
                  task.runs.allSatisfy({
                      sessionIdentifiers.insert($0.id).inserted
                  }) else {
                return .failure(.invalidMetadata)
            }
            var bounded = task
            if bounded.runs.count > limits.maxRunsPerTask {
                bounded.runs = Array(
                    bounded.runs.suffix(limits.maxRunsPerTask)
                )
            }
            candidates.append(bounded)
        }
        candidates.sort(by: newestTaskFirst)
        let protected = candidates.filter(isRetentionProtected)
        guard protected.count <= limits.maxTasksPerProject else {
            return .failure(.storageLimit)
        }
        let protectedIDs = Set(protected.map(\.id))
        let terminal = candidates.filter { !protectedIDs.contains($0.id) }
        let retained = protected + terminal.prefix(
            limits.maxTasksPerProject - protected.count
        )
        return .success(retained.sorted(by: oldestTaskFirst))
    }

    private func validateLoadedTasks(
        _ tasks: [AgentTask],
        project: AgentTaskProjectIdentity
    ) -> Bool {
        var taskIDs = Set<UUID>()
        var runIDs = Set<UUID>()
        for task in tasks {
            guard task.project == project,
                  taskIDs.insert(task.id).inserted,
                  task.runs.count <= limits.maxRunsPerTask,
                  validateTask(task),
                  task.runs.allSatisfy({ runIDs.insert($0.id).inserted }) else {
                return false
            }
        }
        return true
    }

    private func validateTask(_ task: AgentTask) -> Bool {
        guard isCanonicalAbsolute(task.project.canonicalProjectPath),
              isCanonicalAbsolute(task.project.canonicalWorktreePath),
              validText(
                  task.descriptor.typeIdentifier,
                  maximum: limits.maxAgentIdentifierBytes,
                  allowsEmpty: false
              ),
              validOptionalExecutable(
                  task.descriptor.launchExecutable,
                  maximum: limits.maxAgentIdentifierBytes
              ),
              validOptionalText(task.title, maximum: limits.maxTitleBytes),
              validOptionalText(
                  task.objective,
                  maximum: limits.maxObjectiveBytes
              ),
              validDate(task.createdAt),
              validDate(task.updatedAt),
              validDate(task.lastActivityAt),
              task.updatedAt >= task.createdAt,
              task.lastActivityAt >= task.createdAt,
              task.completedAt == nil,
              task.lifecycle != .completed,
              task.attention != .completed,
              task.attention != .failed,
              validOptionalDate(task.completedAt),
              task.runs.allSatisfy(validateRun),
              validateChronology(task) else {
            return false
        }
        return true
    }

    private func validateRun(_ run: AgentTaskRun) -> Bool {
        guard run.process.processGeneration > 0,
              validDate(run.process.observedStartedAt),
              validOptionalText(
                  run.process.startIdentifier,
                  maximum: limits.maxProcessStartBytes
              ),
              run.process.processIdentifier.map({ $0 > 0 }) ?? true,
              validDate(run.startedAt),
              run.startedAt == run.process.observedStartedAt,
              validDate(run.lastObservedAt),
              run.lastObservedAt >= run.startedAt,
              validOptionalDate(run.endedAt) else {
            return false
        }
        if let endedAt = run.endedAt, endedAt < run.startedAt {
            return false
        }
        if let endedAt = run.endedAt, endedAt < run.lastObservedAt {
            return false
        }
        guard (run.liveness == .terminated) == (run.endedAt != nil) else {
            return false
        }
        return true
    }

    private func validateChronology(_ task: AgentTask) -> Bool {
        guard task.route.tabID == task.route.terminalID else { return false }
        guard !task.runs.isEmpty else {
            return (task.lifecycle == .paused || task.lifecycle == .dismissed)
                && task.route.availability == .missing
                && task.attention == .none
        }
        var prior: AgentTaskRun?
        var generationByTerminal: [UUID: UInt64] = [:]
        for run in task.runs {
            if let prior {
                let priorTail = prior.endedAt ?? prior.lastObservedAt
                guard run.startedAt >= priorTail else {
                    return false
                }
            }
            if let generation = generationByTerminal[run.terminalID],
               run.process.processGeneration <= generation { return false }
            generationByTerminal[run.terminalID] = run.process.processGeneration
            prior = run
        }
        if let last = task.runs.last {
            guard task.route.terminalID == last.terminalID,
                  task.updatedAt >= last.lastObservedAt,
                  task.updatedAt >= (last.endedAt ?? last.lastObservedAt),
                  task.lastActivityAt >= last.lastObservedAt,
                  task.lastActivityAt >= (last.endedAt ?? last.lastObservedAt)
            else {
                return false
            }
            if task.lifecycle == .active {
                guard last.liveness != .terminated,
                      task.route.availability != .missing else { return false }
            }
            if task.lifecycle == .paused {
                guard last.liveness != .live,
                      task.route.availability == .missing else { return false }
            }
            if task.lifecycle == .dismissed {
                guard last.liveness == .terminated,
                      task.route.availability == .missing else { return false }
            }
            let waitingIsAllowed = task.lifecycle == .active
                && last.liveness == .live
                && last.state == .waitingInput
            guard task.attention == .none
                    || (waitingIsAllowed && task.attention == .waitingInput) else {
                return false
            }
        } else if task.lifecycle == .active {
            return false
        } else if task.lifecycle == .paused {
            guard task.route.availability == .missing else { return false }
        } else if task.lifecycle == .dismissed {
            guard task.route.availability == .missing else { return false }
        }
        return true
    }

    private func validOptionalExecutable(
        _ value: String?,
        maximum: Int
    ) -> Bool {
        guard let value,
              validText(value, maximum: maximum, allowsEmpty: false) else {
            return value == nil
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D
                || byte == 0x5F
        }
    }

    private func validOptionalText(
        _ value: String?,
        maximum: Int
    ) -> Bool {
        guard let value else { return true }
        return validText(value, maximum: maximum, allowsEmpty: false)
    }

    private func validText(
        _ value: String,
        maximum: Int,
        allowsEmpty: Bool
    ) -> Bool {
        let size = value.utf8.count
        return (allowsEmpty || size > 0)
            && size <= maximum
            && !value.contains("\0")
    }

    private func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    private func validOptionalDate(_ date: Date?) -> Bool {
        date.map(validDate) ?? true
    }

    private func isCanonicalAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private func canonicalExistingDirectory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return ProjectRegistry.canonicalProjectURL(
            URL(fileURLWithPath: path, isDirectory: true)
        ).path
    }

    private func newestTaskFirst(_ lhs: AgentTask, _ rhs: AgentTask) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func isRetentionProtected(_ task: AgentTask) -> Bool {
        task.lifecycle == .active || task.lifecycle == .paused
    }

    private func oldestTaskFirst(_ lhs: AgentTask, _ rhs: AgentTask) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func rejectedLoad(
        _ rejection: AgentTaskMetadataRejection
    ) -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
            status: .rejected(rejection),
            tasks: []
        )
    }
}
