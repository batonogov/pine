import Foundation
import Testing

@testable import Pine

@Suite("Persistence fault injection", .serialized)
@MainActor
struct PersistenceFaultInjectionTests {
    @Test("fault encoding is stable and plans consume only matching checkpoints")
    func faultEncodingAndOrdering() throws {
        for store in PersistenceStoreKind.allCases {
            for phase in PersistenceWritePhase.allCases {
                for failure in PersistenceFailureKind.allCases {
                    let fault = PersistenceFault(
                        store: store,
                        phase: phase,
                        failure: failure
                    )
                    #expect(PersistenceFault(encoded: fault.encoded) == fault)
                }
            }
        }
        #expect(PersistenceFault(encoded: "session:unknown:interrupted") == nil)

        let first = PersistenceFault(
            store: .session,
            phase: .beforeWrite,
            failure: .permissionDenied
        )
        let second = PersistenceFault(
            store: .recovery,
            phase: .beforeAtomicReplace,
            failure: .atomicRename
        )
        let plan = PersistenceFaultPlan([first, second])
        let injector = plan.injector

        try injector.checkpoint(store: .recovery, phase: .beforeAtomicReplace)
        #expect(plan.remainingFaults == [first, second])
        #expect(throws: PersistenceFailureKind.permissionDenied) {
            try injector.checkpoint(store: .session, phase: .beforeWrite)
        }
        #expect(throws: PersistenceFailureKind.atomicRename) {
            try injector.checkpoint(
                store: .recovery,
                phase: .beforeAtomicReplace
            )
        }
        #expect(plan.remainingFaults.isEmpty)
    }

    @Test("session failures before replacement preserve last-known-good data")
    func sessionFailureMatrix() throws {
        let project = try makeProject(named: "session")
        defer { try? FileManager.default.removeItem(at: project) }
        let oldFile = project.appendingPathComponent("old.swift")
        let newFile = project.appendingPathComponent("new.swift")
        try Data("old\n".utf8).write(to: oldFile)
        try Data("new\n".utf8).write(to: newFile)
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SessionState.save(
            projectURL: project,
            openFileURLs: [oldFile],
            defaults: defaults,
            faultInjector: .none
        ))
        let (key, baseline) = try sessionRecord(in: defaults)

        for scenario in preReplacementFailures() {
            defaults.set(baseline, forKey: key)
            let plan = PersistenceFaultPlan([
                PersistenceFault(
                    store: .session,
                    phase: scenario.phase,
                    failure: scenario.failure
                ),
            ])
            #expect(!SessionState.save(
                projectURL: project,
                openFileURLs: [newFile],
                defaults: defaults,
                faultInjector: plan.injector
            ))
            #expect(defaults.data(forKey: key) == baseline)
            #expect(plan.remainingFaults.isEmpty)
        }

        let postReplace = PersistenceFaultPlan([
            PersistenceFault(
                store: .session,
                phase: .afterAtomicReplace,
                failure: .interrupted
            ),
        ])
        #expect(!SessionState.save(
            projectURL: project,
            openFileURLs: [newFile],
            defaults: defaults,
            faultInjector: postReplace.injector
        ))
        let restored = try #require(
            SessionState.load(for: project, defaults: defaults)
        )
        #expect(restored.openFilePaths == [newFile.path])
        #expect(postReplace.remainingFaults.isEmpty)
    }

    @Test("preference migration failures roll back the complete domain")
    func preferenceFailureMatrix() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: MigrationManager.schemaVersionKey)
        defaults.set("known-good", forKey: "fixtureValue")
        let baseline = defaults.dictionaryRepresentation()

        for scenario in preReplacementFailures() {
            restore(defaults: defaults, snapshot: baseline)
            let plan = PersistenceFaultPlan([
                PersistenceFault(
                    store: .preferences,
                    phase: scenario.phase,
                    failure: scenario.failure
                ),
            ])
            var manager = MigrationManager(
                defaults: defaults,
                faultInjector: plan.injector
            )
            manager.registerMigration(from: 0, to: 1) { migrationDefaults in
                migrationDefaults.set("migrated", forKey: "fixtureValue")
                migrationDefaults.set("new", forKey: "migrationSideEffect")
            }
            #expect(!manager.runMigrations())
            #expect(
                defaults.dictionaryRepresentation() as NSDictionary
                    == baseline as NSDictionary
            )
            #expect(plan.remainingFaults.isEmpty)
        }

        restore(defaults: defaults, snapshot: baseline)
        let postReplace = PersistenceFaultPlan([
            PersistenceFault(
                store: .preferences,
                phase: .afterAtomicReplace,
                failure: .interrupted
            ),
        ])
        var manager = MigrationManager(
            defaults: defaults,
            faultInjector: postReplace.injector
        )
        manager.registerMigration(from: 0, to: 1) { migrationDefaults in
            migrationDefaults.set("migrated", forKey: "fixtureValue")
        }
        #expect(!manager.runMigrations())
        #expect(
            defaults.integer(forKey: MigrationManager.schemaVersionKey)
                == MigrationManager.latestVersion
        )
        #expect(defaults.string(forKey: "fixtureValue") == "migrated")
        #expect(postReplace.remainingFaults.isEmpty)
    }

    @Test("recovery failures never expose torn JSON")
    func recoveryFailureMatrix() throws {
        let root = try makeProject(named: "recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = root.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(
            at: recovery,
            withIntermediateDirectories: true
        )
        var tab = EditorTab(
            url: root.appendingPathComponent("document.swift"),
            content: "known-good",
            savedContent: "disk"
        )
        RecoveryManager(
            recoveryDirectory: recovery,
            faultInjector: .none
        ).snapshotDirtyTabs([tab])
        let snapshotURL = recovery.appendingPathComponent(
            "\(tab.id.uuidString).json"
        )
        let baseline = try Data(contentsOf: snapshotURL)
        tab.content = "replacement"

        for scenario in preReplacementFailures() {
            try baseline.write(to: snapshotURL, options: .atomic)
            let plan = PersistenceFaultPlan([
                PersistenceFault(
                    store: .recovery,
                    phase: scenario.phase,
                    failure: scenario.failure
                ),
            ])
            RecoveryManager(
                recoveryDirectory: recovery,
                faultInjector: plan.injector
            ).snapshotDirtyTabs([tab])
            #expect(try Data(contentsOf: snapshotURL) == baseline)
            #expect(plan.remainingFaults.isEmpty)
        }

        let postReplace = PersistenceFaultPlan([
            PersistenceFault(
                store: .recovery,
                phase: .afterAtomicReplace,
                failure: .interrupted
            ),
        ])
        let manager = RecoveryManager(
            recoveryDirectory: recovery,
            faultInjector: postReplace.injector
        )
        manager.snapshotDirtyTabs([tab])
        #expect(manager.pendingRecoveryEntries().first?.1.content == "replacement")
        #expect(postReplace.remainingFaults.isEmpty)
    }

    @Test("agent metadata failures preserve a loadable revision")
    func agentTaskFailureMatrix() async throws {
        let fixture = try makeAgentFixture(projectNames: ["project"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let identity = agentIdentity(fixture.projects[0])
        let baselineStore = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(
            await baselineStore.save(
                tasks: [],
                project: identity,
                authorization: nil
            ) == .saved(taskCount: 0)
        )
        let metadataURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let baseline = try Data(contentsOf: metadataURL)

        for scenario in preReplacementFailures() {
            try installPrivate(baseline, at: metadataURL)
            let plan = PersistenceFaultPlan([
                PersistenceFault(
                    store: .agentTask,
                    phase: scenario.phase,
                    failure: scenario.failure
                ),
            ])
            let store = AgentTaskMetadataStore(
                storageRoot: fixture.storage,
                configuration: AgentTaskStoreConfiguration(
                    faultInjector: plan.injector
                )
            )
            let result = await store.save(
                tasks: [],
                project: identity,
                authorization: nil
            )
            #expect(!result.isDurablySaved)
            #expect(try Data(contentsOf: metadataURL) == baseline)
            #expect(plan.remainingFaults.isEmpty)
        }

        let postReplace = PersistenceFaultPlan([
            PersistenceFault(
                store: .agentTask,
                phase: .afterAtomicReplace,
                failure: .interrupted
            ),
        ])
        let uncertainStore = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                faultInjector: postReplace.injector
            )
        )
        let uncertain = await uncertainStore.save(
            tasks: [],
            project: identity,
            authorization: nil
        )
        if case .publishedButDurabilityUnknown(let count, _) = uncertain {
            #expect(count == 0)
        } else {
            Issue.record("Expected a complete publication with unknown durability")
        }
        #expect(await uncertainStore.load(project: identity).status == .loaded)
        #expect(postReplace.remainingFaults.isEmpty)
    }

    @Test("concurrent project stores cannot cross-contaminate metadata")
    func concurrentAgentProjectsRemainIsolated() async throws {
        let fixture = try makeAgentFixture(projectNames: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alpha = agentIdentity(fixture.projects[0])
        let beta = agentIdentity(fixture.projects[1])
        let firstStore = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let secondStore = AgentTaskMetadataStore(storageRoot: fixture.storage)

        async let first = firstStore.save(
            tasks: [],
            project: alpha,
            authorization: nil
        )
        async let second = secondStore.save(
            tasks: [],
            project: beta,
            authorization: nil
        )
        let (firstResult, secondResult) = await (first, second)
        if firstResult != .saved(taskCount: 0) {
            #expect([
                .rejected(.lockContention),
                .rejected(.transientIO),
            ].contains(firstResult))
            #expect(
                await firstStore.save(
                    tasks: [],
                    project: alpha,
                    authorization: nil
                ) == .saved(taskCount: 0)
            )
        }
        if secondResult != .saved(taskCount: 0) {
            #expect([
                .rejected(.lockContention),
                .rejected(.transientIO),
            ].contains(secondResult))
            #expect(
                await secondStore.save(
                    tasks: [],
                    project: beta,
                    authorization: nil
                ) == .saved(taskCount: 0)
            )
        }
        #expect(await firstStore.load(project: alpha).status == .loaded)
        #expect(await secondStore.load(project: beta).status == .loaded)
        #expect(await firstStore.load(project: beta).status == .loaded)
        #expect(await secondStore.load(project: alpha).status == .loaded)
        #expect(
            AgentTaskMetadataStore.metadataURL(
                for: alpha,
                storageRoot: fixture.storage
            ) != AgentTaskMetadataStore.metadataURL(
                for: beta,
                storageRoot: fixture.storage
            )
        )
    }

    private func preReplacementFailures() -> [(
        phase: PersistenceWritePhase,
        failure: PersistenceFailureKind
    )] {
        [
            (.beforeWrite, .permissionDenied),
            (.beforeWrite, .readOnly),
            (.beforeWrite, .noSpace),
            (.afterTemporaryWrite, .interrupted),
            (.beforeSync, .fsync),
            (.beforeAtomicReplace, .atomicRename),
            (.beforeAtomicReplace, .concurrentWriter),
        ]
    }

    private func makeProject(named name: String) throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PinePersistence-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        return project
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "PinePersistenceFaults-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func sessionRecord(
        in defaults: UserDefaults
    ) throws -> (String, Data) {
        let key = try #require(
            defaults.dictionaryRepresentation().keys.first {
                $0.hasPrefix("sessionState:")
            }
        )
        return (key, try #require(defaults.data(forKey: key)))
    }

    private func restore(
        defaults: UserDefaults,
        snapshot: [String: Any]
    ) {
        for key in defaults.dictionaryRepresentation().keys
            where snapshot[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in snapshot {
            defaults.set(value, forKey: key)
        }
    }

    private func makeAgentFixture(
        projectNames: [String]
    ) throws -> (root: URL, storage: URL, projects: [URL]) {
        let root = try makeProject(named: "agents")
        try removeExtendedACL(from: root)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let projects = try projectNames.map { name -> URL in
            let project = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: project,
                withIntermediateDirectories: true
            )
            return project.resolvingSymlinksInPath()
        }
        return (root, storage, projects)
    }

    private func agentIdentity(_ project: URL) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: project.path,
            canonicalWorktreePath: project.path
        )
    }

    private func installPrivate(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func removeExtendedACL(from url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-N", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
