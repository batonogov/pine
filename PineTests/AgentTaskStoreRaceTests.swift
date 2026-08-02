import Darwin
import Foundation
import Testing
@testable import Pine

@Suite("Agent task descriptor storage races")
struct AgentTaskStoreRaceTests {
    @Test("permissive owned parent is rejected before side effects")
    func permissiveParentHasNoSideEffects() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let ownedParent = fixture.root.appendingPathComponent("private")
        let storage = ownedParent.appendingPathComponent("leaf")
        try FileManager.default.createDirectory(
            at: ownedParent, withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: ownedParent.path
        )
        let store = AgentTaskMetadataStore(
            storageRoot: storage,
            configuration: AgentTaskStoreConfiguration(privateComponentCount: 2)
        )

        #expect(await store.save(tasks: [], project: fixture.identity)
            == .rejected(.unsafeFilesystemObject))
        #expect(!FileManager.default.fileExists(atPath: storage.path))
        #expect(!FileManager.default.fileExists(
            atPath: ownedParent.appendingPathComponent(".agent-tasks.lock").path
        ))
    }

    @Test("trusted permissive anchor creates one private storage leaf")
    func trustedAnchorCreatesPrivateLeaf() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let anchor = fixture.root.appendingPathComponent("trusted-anchor")
        let storage = anchor.appendingPathComponent("private-leaf")
        try FileManager.default.createDirectory(
            at: anchor,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let store = AgentTaskMetadataStore(
            storageRoot: storage,
            configuration: AgentTaskStoreConfiguration(privateComponentCount: 1)
        )

        #expect(await store.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: storage.path
        )
        let permissions = try #require(
            attributes[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o700)
    }

    @Test("owned intermediate symlink is rejected without traversal")
    func ownedIntermediateSymlinkIsRejected() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("target")
        let ownedParent = fixture.root.appendingPathComponent("private")
        let storage = ownedParent.appendingPathComponent("leaf")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: ownedParent, withDestinationURL: target)
        let store = AgentTaskMetadataStore(
            storageRoot: storage,
            configuration: AgentTaskStoreConfiguration(privateComponentCount: 2)
        )

        #expect(await store.save(tasks: [], project: fixture.identity)
            == .rejected(.unsafeFilesystemObject))
        #expect(!FileManager.default.fileExists(
            atPath: target.appendingPathComponent("leaf").path
        ))
    }

    @Test("directory pathname replacement after open fails closed")
    func directoryReplacementFailsClosed() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let storagePath = fixture.storage.path
        let displaced = storagePath + ".displaced"
        let hooked = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks { phase in
                    if case .directoryOpened = phase {
                        StoreRacePOSIX.replaceDirectory(storagePath, displaced: displaced)
                    }
                }
            )
        )

        #expect(await hooked.save(tasks: [], project: fixture.identity)
            == .rejected(.unsafeFilesystemObject))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.storage.appendingPathComponent(".agent-tasks.lock").path
        ))
    }

    @Test("directory replacement immediately before temp creation has no side effect")
    func directoryReplacementBeforeTempCreateFailsClosed() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let storagePath = fixture.storage.path
        let displaced = storagePath + ".before-temp-displaced"
        let hooked = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks { phase in
                    if case .beforeTemporaryCreate = phase {
                        StoreRacePOSIX.replaceDirectory(
                            storagePath,
                            displaced: displaced
                        )
                    }
                }
            )
        )

        #expect(await hooked.save(tasks: [], project: fixture.identity)
            == .rejected(.unsafeFilesystemObject))
        let displacedEntries = try FileManager.default.contentsOfDirectory(
            atPath: displaced
        )
        #expect(displacedEntries.allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test("directory replacement before cleanup mutation preserves candidate")
    func directoryReplacementBeforeRetirementFailsClosed() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let now = Date(timeIntervalSince1970: 26_000)
        let stale = try fixture.makeTemporary(age: 1_000, now: now)
        let original = try Data(contentsOf: stale)
        let storagePath = fixture.storage.path
        let displaced = storagePath + ".retire-displaced"
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                cleanup: AgentTaskCleanupConfiguration(
                    staleAge: 100,
                    scanLimit: 256,
                    retireLimit: 1,
                    now: { now }
                ),
                hooks: AgentTaskStoreHooks { phase in
                    if case .beforeRetireMutation = phase {
                        StoreRacePOSIX.replaceDirectory(
                            storagePath,
                            displaced: displaced
                        )
                    }
                }
            )
        )

        #expect(await store.load(project: fixture.identity).status
            == .rejected(.unsafeFilesystemObject))
        let displacedCandidate = URL(fileURLWithPath: displaced)
            .appendingPathComponent(stale.lastPathComponent)
        #expect(try Data(contentsOf: displacedCandidate) == original)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: displacedCandidate.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("load revalidates storage before creating its lock")
    func loadDirectoryReplacementFailsClosed() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let storagePath = fixture.storage.path
        let displaced = storagePath + ".load-displaced"
        let hooked = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks { phase in
                    if case .directoryOpened = phase {
                        StoreRacePOSIX.replaceDirectory(
                            storagePath,
                            displaced: displaced
                        )
                    }
                }
            )
        )

        #expect(await hooked.load(project: fixture.identity).status
            == .rejected(.unsafeFilesystemObject))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.storage.appendingPathComponent(".agent-tasks.lock").path
        ))
    }

    @Test("verified advisory lock serializes store instances")
    func advisoryLockSerializesStores() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await store.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let lockPath = fixture.storage.appendingPathComponent(".agent-tasks.lock").path
        let lock = StoreRacePOSIX.lock(lockPath)
        defer { StoreRacePOSIX.unlock(lock) }
        let contender = AgentTaskMetadataStore(storageRoot: fixture.storage)

        #expect(await contender.save(tasks: [], project: fixture.identity)
            == .rejected(.lockContention))
    }

    @Test("lock pathname replacement after flock fails closed")
    func lockReplacementFailsClosed() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let lockPath = fixture.storage.appendingPathComponent(".agent-tasks.lock").path
        let hooked = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks { phase in
                    if case .lockAcquired = phase {
                        StoreRacePOSIX.replacePrivateFile(lockPath)
                    }
                }
            )
        )

        #expect(await hooked.save(tasks: [], project: fixture.identity)
            == .rejected(.unsafeFilesystemObject))
    }

    @Test("metadata growth and shrink during read are rejected")
    func concurrentReadMutationIsRejected() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let filePath = AgentTaskMetadataStore.metadataURL(
            for: fixture.identity, storageRoot: fixture.storage
        ).path
        let growing = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks { phase in
                    if case .readOpened = phase { StoreRacePOSIX.appendByte(filePath) }
                }
            )
        )
        #expect(await growing.load(project: fixture.identity).status
            == .rejected(.concurrentMutation))

        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let shrinking = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks { phase in
                    if case .readOpened = phase { StoreRacePOSIX.truncateFile(filePath) }
                }
            )
        )
        #expect(await shrinking.load(project: fixture.identity).status
            == .rejected(.concurrentMutation))
    }

    @Test("metadata FIFO replacement cannot block the store")
    func fifoReplacementFailsClosed() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let filePath = AgentTaskMetadataStore.metadataURL(
            for: fixture.identity,
            storageRoot: fixture.storage
        ).path
        let hooked = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks { phase in
                    if case .beforeReadOpen = phase {
                        StoreRacePOSIX.replaceWithFIFO(filePath)
                    }
                }
            )
        )

        #expect(await hooked.load(project: fixture.identity).status
            == .rejected(.unsafeFilesystemObject))
    }

    @Test("superseded publication cannot replace current metadata")
    func supersededPublicationIsFencedAtRename() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await store.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let baseline = await store.load(project: fixture.identity)
        let baselineRevision = try #require(baseline.revision)
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: fixture.identity,
            storageRoot: fixture.storage
        )
        let generation = UUID()
        let fence = AgentTaskPublicationFence(generation: generation)
        let staleTicket = AgentTaskPersistenceTicket(
            generation: generation,
            sequence: 1,
            projectKey: fixture.identity.persistenceKey,
            expectedDiskRevision: baselineRevision
        )
        let currentTicket = AgentTaskPersistenceTicket(
            generation: generation,
            sequence: 2,
            projectKey: fixture.identity.persistenceKey,
            expectedDiskRevision: baselineRevision
        )
        fence.authorize(staleTicket)
        fence.authorize(currentTicket)
        let current = AgentTaskPublicationAuthorization(
            ticket: currentTicket,
            fence: fence
        )
        let stale = AgentTaskPublicationAuthorization(
            ticket: staleTicket,
            fence: fence
        )

        #expect(await store.save(
            tasks: [],
            project: fixture.identity,
            authorization: current
        ) == .saved(taskCount: 0))
        let published = try Data(contentsOf: fileURL)
        #expect(await store.save(
            tasks: [],
            project: fixture.identity,
            authorization: stale
        ) == .rejected(.superseded))
        #expect(try Data(contentsOf: fileURL) == published)
    }

    @Test("publication generation advance never waits for in-flight rename")
    func publicationAdvanceIsNonblocking() async {
        let generation = UUID()
        let fence = AgentTaskPublicationFence(generation: generation)
        let ticket = AgentTaskPersistenceTicket(
            generation: generation,
            sequence: 1,
            projectKey: "deadline-project",
            expectedDiskRevision: nil
        )
        fence.authorize(ticket)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let publication = Task.detached {
            fence.publishForTesting {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                return true
            }
        }
        let didEnter = await Task.detached {
            entered.wait(timeout: .now() + 1) == .success
        }.value
        #expect(didEnter)
        let clock = ContinuousClock()
        let started = clock.now
        _ = fence.advance(to: UUID())
        #expect(started.duration(to: clock.now) < .milliseconds(250))
        release.signal()
        let decision = await publication.value
        switch decision {
        case .published:
            break
        case .failed, .superseded:
            Issue.record("in-flight authorized publication was lost")
        }
        #expect(
            fence.publishedRevision(for: ticket.projectKey)
                == .versioned(ticket.nextDiskRevision)
        )
    }

    @Test("temporary pathname replacement cannot publish")
    func temporaryReplacementCannotPublish() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: fixture.identity, storageRoot: fixture.storage
        )
        let original = try Data(contentsOf: fileURL)
        let storagePath = fixture.storage.path
        let hooked = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks { phase in
                    if case .beforePublish = phase {
                        StoreRacePOSIX.replaceTemporaryFile(in: storagePath)
                    }
                }
            )
        )

        #expect(await hooked.save(tasks: [], project: fixture.identity)
            == .rejected(.unsafeFilesystemObject))
        #expect(try Data(contentsOf: fileURL) == original)
        let survivors = try FileManager.default.contentsOfDirectory(
            atPath: storagePath
        ).filter { $0.hasPrefix(".agent-tasks-") && $0.hasSuffix(".tmp") }
        #expect(survivors.count == 1)
    }

    @Test("failed-writer retirement mutates descriptor not replacement pathname")
    func failedWriterRetirementPreservesReplacement() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let replacement = fixture.root.appendingPathComponent("writer-replacement")
        let replacementBytes = Data("writer-replacement-must-survive".utf8)
        try replacementBytes.write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacement.path
        )
        let storagePath = fixture.storage.path
        let hooked = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks(
                    shouldSync: { $0 != .metadataFile },
                    phase: { phase in
                        if case .beforeRetireMutation = phase {
                            StoreRacePOSIX.replaceTemporaryPath(
                                in: storagePath,
                                with: replacement.path
                            )
                        }
                    }
                )
            )
        )

        #expect(await hooked.save(tasks: [], project: fixture.identity)
            == .rejected(.durabilityUnknown))
        let survivorNames = try FileManager.default.contentsOfDirectory(
            atPath: storagePath
        ).filter { $0.hasPrefix(".agent-tasks-") && $0.hasSuffix(".tmp") }
        let survivor = try #require(survivorNames.first)
        #expect(survivorNames.count == 1)
        #expect(
            try Data(contentsOf: fixture.storage.appendingPathComponent(survivor))
                == replacementBytes
        )
    }

    @Test("final pathname replacement before publish fails closed")
    func finalReplacementBeforePublishFailsClosed() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: fixture.identity,
            storageRoot: fixture.storage
        )
        let hooked = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks { phase in
                    if case .beforePublish = phase {
                        StoreRacePOSIX.replacePrivateFile(fileURL.path)
                    }
                }
            )
        )

        #expect(await hooked.save(tasks: [], project: fixture.identity)
            == .rejected(.unsafeFilesystemObject))
        #expect(try Data(contentsOf: fileURL).isEmpty)
    }

    @Test("cleanup honors grammar age mode and retirement cap")
    func cleanupIsBoundedAndExact() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let now = Date(timeIntervalSince1970: 20_000)
        let fresh = try fixture.makeTemporary(age: 10, now: now)
        let stale = try fixture.makeTemporary(age: 1_000, now: now)
        let oldest = try fixture.makeTemporary(age: 2_000, now: now)
        let permissive = try fixture.makeTemporary(age: 1_000, now: now, mode: 0o644)
        let malformed = fixture.storage.appendingPathComponent(".agent-tasks-not-a-uuid.tmp")
        try Data([1]).write(to: malformed)
        let cleanup = AgentTaskCleanupConfiguration(
            staleAge: 100, scanLimit: 256, retireLimit: 1, now: { now }
        )
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(cleanup: cleanup)
        )

        #expect(await store.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: oldest.path))
        let retired = try FileManager.default.attributesOfItem(
            atPath: oldest.path
        )
        #expect((retired[.size] as? NSNumber)?.intValue == 0)
        #expect((retired[.posixPermissions] as? NSNumber)?.intValue == 0)
        #expect(FileManager.default.fileExists(atPath: permissive.path))
        #expect(FileManager.default.fileExists(atPath: malformed.path))
    }

    @Test("cleanup preserves a pathname replacement before unlink")
    func cleanupReplacementRaceFailsClosed() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let now = Date(timeIntervalSince1970: 25_000)
        let stale = try fixture.makeTemporary(age: 1_000, now: now)
        let replacement = fixture.root.appendingPathComponent("cleanup-replacement")
        let replacementBytes = Data("replacement-must-survive".utf8)
        try replacementBytes.write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacement.path
        )
        let cleanup = AgentTaskCleanupConfiguration(
            staleAge: 100,
            scanLimit: 256,
            retireLimit: 1,
            now: { now }
        )
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                cleanup: cleanup,
                hooks: AgentTaskStoreHooks { phase in
                    if case .beforeRetireMutation = phase {
                        StoreRacePOSIX.replacePath(
                            stale.path,
                            with: replacement.path
                        )
                    }
                }
            )
        )

        #expect(await store.load(project: fixture.identity).status == .loaded)
        #expect(try Data(contentsOf: stale) == replacementBytes)
    }

    @Test("retirement rejects a hard link added after validation")
    func cleanupHardLinkRaceFailsClosed() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        try fixture.prepareStorage()
        let staleURL = fixture.storage.appendingPathComponent(
            ".agent-tasks-66666666-6666-4666-8666-666666666666.tmp"
        )
        let aliasURL = fixture.root.appendingPathComponent("hard-link-alias")
        let bytes = Data("preserve-shared-inode".utf8)
        try bytes.write(to: staleURL)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .modificationDate: Date(timeIntervalSince1970: 0),
            ],
            ofItemAtPath: staleURL.path
        )
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                cleanup: AgentTaskCleanupConfiguration(
                    staleAge: 1,
                    now: { Date(timeIntervalSince1970: 10_000) }
                ),
                hooks: AgentTaskStoreHooks { phase in
                    if case .beforeRetireMutation = phase {
                        StoreRacePOSIX.createHardLink(
                            from: staleURL.path,
                            to: aliasURL.path
                        )
                    }
                }
            )
        )

        _ = await store.load(project: fixture.identity)
        #expect(try Data(contentsOf: staleURL) == bytes)
        #expect(try Data(contentsOf: aliasURL) == bytes)
    }

    @Test("tombstone cap rejects before creating a new writer temp")
    func tombstoneCapFailsBeforeCreate() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        try fixture.prepareStorage()
        for suffix in [
            "77777777-7777-4777-8777-777777777777",
            "88888888-8888-4888-8888-888888888888",
        ] {
            let url = fixture.storage.appendingPathComponent(
                ".agent-tasks-\(suffix).tmp"
            )
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: url.path
            )
        }
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                cleanup: AgentTaskCleanupConfiguration(
                    tombstoneLimit: 2,
                    directoryEntryLimit: 16
                )
            )
        )

        #expect(await store.save(tasks: [], project: fixture.identity)
            == .rejected(.storageLimit))
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.storage.path
        )
        #expect(entries.filter { $0.hasSuffix(".tmp") }.count == 2)
    }

    @Test("directory entry cap rejects at exact capacity before writer temp")
    func directoryEntryCapFailsAtEquality() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for name in ["unrelated-one", "unrelated-two"] {
            let url = fixture.storage.appendingPathComponent(name)
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                cleanup: AgentTaskCleanupConfiguration(
                    tombstoneLimit: 3,
                    directoryEntryLimit: 3
                )
            )
        )

        #expect(await store.save(tasks: [], project: fixture.identity)
            == .rejected(.storageLimit))
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.storage.path
        )
        #expect(entries.filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test("bounded cleanup cursor cannot starve a stale orphan")
    func cleanupCursorReachesStaleOrphan() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let plain = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await plain.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        let now = Date(timeIntervalSince1970: 30_000)
        for index in 0..<12 {
            let unrelated = fixture.storage.appendingPathComponent("unrelated-\(index)")
            try Data([1]).write(to: unrelated)
        }
        let stale = try fixture.makeTemporary(age: 1_000, now: now)
        let cleanup = AgentTaskCleanupConfiguration(
            staleAge: 100,
            scanLimit: 1,
            retireLimit: 1,
            now: { now }
        )
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(cleanup: cleanup)
        )

        for _ in 0..<32 {
            _ = await store.load(project: fixture.identity)
        }
        let retired = try FileManager.default.attributesOfItem(
            atPath: stale.path
        )
        #expect((retired[.size] as? NSNumber)?.intValue == 0)
        #expect((retired[.posixPermissions] as? NSNumber)?.intValue == 0)
    }

    @Test("creating private storage durably syncs parent and child")
    func createdStorageSyncsDescriptors() async throws {
        let fixture = try StoreRaceFixture()
        defer { fixture.cleanup() }
        let counter = StoreRaceCounter()
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks(didSync: { counter.record($0) })
            )
        )

        #expect(await store.save(tasks: [], project: fixture.identity)
            == .saved(taskCount: 0))
        #expect(counter.targets == [
            .parentDirectory,
            .createdDirectory,
            .metadataFile,
            .storageDirectory,
        ])
    }
}

nonisolated private final class StoreRaceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTargets: [AgentTaskSyncTarget] = []

    var targets: [AgentTaskSyncTarget] {
        lock.withLock { recordedTargets }
    }

    func record(_ target: AgentTaskSyncTarget) {
        lock.withLock { recordedTargets.append(target) }
    }
}

nonisolated private enum StoreRacePOSIX {
    static func replaceDirectory(_ path: String, displaced: String) {
        _ = path.withCString { source in
            displaced.withCString { destination in Darwin.rename(source, destination) }
        }
        _ = path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
    }

    static func lock(_ path: String) -> Int32 {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return -1
        }
        return descriptor
    }

    static func unlock(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    static func replacePrivateFile(_ path: String) {
        _ = path.withCString { Darwin.unlink($0) }
        let descriptor = path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    static func replacePath(_ path: String, with replacement: String) {
        _ = path.withCString { Darwin.unlink($0) }
        _ = replacement.withCString { source in
            path.withCString { destination in Darwin.rename(source, destination) }
        }
    }

    static func createHardLink(from source: String, to destination: String) {
        _ = destination.withCString { Darwin.unlink($0) }
        _ = source.withCString { sourcePath in
            destination.withCString { destinationPath in
                Darwin.link(sourcePath, destinationPath)
            }
        }
    }

    static func replaceWithFIFO(_ path: String) {
        _ = path.withCString { Darwin.unlink($0) }
        _ = path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
    }

    static func appendByte(_ path: String) {
        let descriptor = path.withCString { Darwin.open($0, O_WRONLY | O_APPEND) }
        guard descriptor >= 0 else { return }
        var byte: UInt8 = 0x20
        _ = Darwin.write(descriptor, &byte, 1)
        Darwin.close(descriptor)
    }

    static func truncateFile(_ path: String) {
        _ = path.withCString { Darwin.truncate($0, 0) }
    }

    static func replaceTemporaryFile(in directoryPath: String) {
        guard let directory = directoryPath.withCString({ opendir($0) }) else { return }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard name.hasPrefix(".agent-tasks-"), name.hasSuffix(".tmp") else {
                continue
            }
            replacePrivateFile(directoryPath + "/" + name)
            return
        }
    }

    static func replaceTemporaryPath(
        in directoryPath: String,
        with replacement: String
    ) {
        guard let directory = directoryPath.withCString({ opendir($0) }) else { return }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard name.hasPrefix(".agent-tasks-"), name.hasSuffix(".tmp") else {
                continue
            }
            replacePath(directoryPath + "/" + name, with: replacement)
            return
        }
    }
}

private struct StoreRaceFixture {
    let root: URL
    let project: URL
    let storage: URL
    let identity: AgentTaskProjectIdentity

    init() throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PineStoreRace-\(UUID().uuidString)")
        project = root.appendingPathComponent("project")
        storage = root.appendingPathComponent("storage")
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        identity = AgentTaskProjectIdentity(
            canonicalProjectPath: project.path,
            canonicalWorktreePath: project.path
        )
    }

    func prepareStorage() throws {
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func makeTemporary(
        age: TimeInterval,
        now: Date,
        mode: Int = 0o600
    ) throws -> URL {
        let url = storage.appendingPathComponent(
            ".agent-tasks-\(UUID().uuidString).tmp"
        )
        try Data([1]).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: mode, .modificationDate: now.addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
