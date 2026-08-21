import Foundation
import Testing

@testable import Pine

@Suite("Versioned persistence fixture corpus", .serialized)
@MainActor
struct PersistenceFixtureCorpusTests {
    private struct Manifest: Decodable {
        let formatVersion: Int
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let store: String
        let file: String
        let schema: String
        let outcome: String
    }

    @Test("manifest covers every durable store and schema tier")
    func manifestCoverageAndSanitization() throws {
        let manifest: Manifest = try decode("manifest.json")
        #expect(manifest.formatVersion == 1)
        #expect(Set(manifest.fixtures.map(\.store)) == [
            "preferences", "session", "recovery", "agent-task",
        ])
        #expect(Set(manifest.fixtures.map(\.schema)).isSuperset(of: [
            "N-2", "N-1", "current", "future",
        ]))
        #expect(Set(manifest.fixtures.map(\.outcome)) == [
            "load", "migrate", "reject",
        ])

        let forbidden = [
            "/Users/", "/home/", "terminalOutput", "credentials",
            "accessToken", "refreshToken", "\"prompt\"",
        ]
        for fixture in manifest.fixtures {
            let contents = try String(
                contentsOf: fixtureURL(fixture.file),
                encoding: .utf8
            )
            for pattern in forbidden {
                #expect(!contents.localizedCaseInsensitiveContains(pattern))
            }
        }
    }

    @Test("preference fixtures migrate idempotently and future data is untouched")
    func preferenceFixtures() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let (legacy, legacyName) = try makeDefaults()
        defer { legacy.removePersistentDomain(forName: legacyName) }
        try installPreferences("preferences-v0.json", in: legacy, project: project)
        let manager = MigrationManager.withDefaultMigrations(defaults: legacy)
        manager.runMigrations()
        #expect(
            legacy.integer(forKey: MigrationManager.schemaVersionKey)
                == MigrationManager.latestVersion
        )
        #expect(legacy.stringArray(forKey: "recentProjectPaths") == [project.path])
        let migrated = legacy.dictionaryRepresentation() as NSDictionary
        manager.runMigrations()
        #expect(legacy.dictionaryRepresentation() as NSDictionary == migrated)

        let (future, futureName) = try makeDefaults()
        defer { future.removePersistentDomain(forName: futureName) }
        try installPreferences(
            "preferences-future.json",
            in: future,
            project: project
        )
        let original = future.dictionaryRepresentation() as NSDictionary
        MigrationManager.withDefaultMigrations(defaults: future).runMigrations()
        #expect(future.dictionaryRepresentation() as NSDictionary == original)
    }

    @Test("session fixtures normalize idempotently and preserve future data")
    func sessionFixtures() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let (defaults, defaultsName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let fixtures: [(String, Int?)] = [
            ("session-v0.json", nil),
            ("session-v1.json", SessionState.currentSchemaVersion),
        ]
        for (file, expectedVersion) in fixtures {
            let data = try fixtureData(file, project: project)
            defaults.set(data, forKey: "lastSessionState")
            let state = try #require(
                SessionState.load(for: project, defaults: defaults)
            )
            #expect(state.schemaVersion == expectedVersion)
            #expect(state.activeFileURL?.lastPathComponent == "App.swift")

            #expect(saveNormalizedSession(state, for: project, in: defaults))
            let normalized = try #require(
                SessionState.load(for: project, defaults: defaults)
            )
            #expect(
                normalized.schemaVersion == SessionState.currentSchemaVersion
            )
            let first = try sessionRecord(in: defaults)
            #expect(
                saveNormalizedSession(normalized, for: project, in: defaults)
            )
            #expect(try sessionRecord(in: defaults) == first)

            SessionState.clear(for: project, defaults: defaults)
            defaults.removeObject(forKey: "lastSessionState")
        }

        let future = try fixtureData("session-future.json", project: project)
        defaults.set(future, forKey: "lastSessionState")
        #expect(SessionState.load(for: project, defaults: defaults) == nil)
        #expect(defaults.data(forKey: "lastSessionState") == future)
    }

    @Test("recovery fixtures normalize idempotently and preserve future data")
    func recoveryFixtures() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let recovery = project.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(
            at: recovery,
            withIntermediateDirectories: true
        )
        let manager = RecoveryManager(recoveryDirectory: recovery)

        let fixtures: [(String, Int?)] = [
            ("recovery-v0.json", nil),
            ("recovery-v1.json", RecoveryEntry.currentSchemaVersion),
        ]
        for (file, expectedVersion) in fixtures {
            let id = UUID()
            let url = recovery.appendingPathComponent("\(id.uuidString).json")
            try fixtureData(file, project: project).write(to: url)
            let entries = manager.pendingRecoveryEntries()
            let entry = try #require(entries.first(where: { $0.0 == id })?.1)
            #expect(entry.schemaVersion == expectedVersion)

            var tab = EditorTab(
                url: URL(fileURLWithPath: entry.originalPath),
                content: entry.content,
                savedContent: ""
            )
            tab.encoding = entry.encoding
            #expect(manager.migrateRecoverySnapshot(from: id, to: tab))
            let normalized = try #require(
                manager.pendingRecoveryEntries().first {
                    $0.0 == tab.id
                }?.1
            )
            #expect(
                normalized.schemaVersion == RecoveryEntry.currentSchemaVersion
            )
            #expect(normalized.originalPath == entry.originalPath)
            #expect(normalized.content == entry.content)

            #expect(manager.migrateRecoverySnapshot(from: tab.id, to: tab))
            let repeated = try #require(
                manager.pendingRecoveryEntries().first {
                    $0.0 == tab.id
                }?.1
            )
            #expect(
                repeated.schemaVersion == RecoveryEntry.currentSchemaVersion
            )
            #expect(repeated.originalPath == normalized.originalPath)
            #expect(repeated.content == normalized.content)
            manager.deleteRecoveryFile(for: tab.id)
        }

        // A snapshot from a newer build. `schemaVersion: 999` with an extra
        // field this build has never heard of still decodes into a
        // `RecoveryEntry` with real content, so it is offered — refusing to
        // show it while the launch sweep collected it on a schedule was the
        // one path that could destroy a readable buffer the user was never
        // asked about (#1503). What must not happen is a rewrite: the
        // `futureOnlyState` this build cannot represent has to survive
        // byte-for-byte until the newer build reads it again.
        let id = UUID()
        let url = recovery.appendingPathComponent("\(id.uuidString).json")
        let future = try fixtureData("recovery-future.json", project: project)
        try future.write(to: url)
        let offered = try #require(
            manager.pendingRecoveryEntries().first { $0.0 == id }?.1
        )
        #expect(offered.schemaVersion == 999)
        #expect(offered.hasSupportedSchema == false)
        #expect(offered.content == "future unsaved buffer\n")
        #expect(try Data(contentsOf: url) == future)
    }

    @Test("agent-task fixtures enforce N-2 through future compatibility")
    func agentTaskFixtures() async throws {
        let root = try makePrivateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: project.path,
            canonicalWorktreePath: project.path
        )
        let url = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: storage
        )
        let store = AgentTaskMetadataStore(storageRoot: storage)

        try installAgentFixture("agent-task-v0.json", at: url, project: project)
        #expect(await store.load(project: identity).status == .rejected(.unknownSchema))

        try installAgentFixture("agent-task-v1.json", at: url, project: project)
        let legacy = await store.load(project: identity)
        #expect(legacy.status == .loaded)
        #expect(legacy.requiresMigration)

        let generation = UUID()
        let revision = try #require(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let fence = AgentTaskPublicationFence(generation: generation)
        let firstTicket = AgentTaskPersistenceTicket(
            generation: generation,
            sequence: 1,
            projectKey: identity.persistenceKey,
            expectedDiskRevision: legacy.revision,
            nextDiskRevision: revision
        )
        fence.authorize(firstTicket)
        #expect(
            await store.save(
                tasks: legacy.tasks,
                project: identity,
                authorization: AgentTaskPublicationAuthorization(
                    ticket: firstTicket,
                    fence: fence
                )
            ) == .saved(taskCount: legacy.tasks.count)
        )
        let normalized = await store.load(project: identity)
        #expect(normalized.status == .loaded)
        #expect(!normalized.requiresMigration)
        #expect(normalized.revision == .versioned(revision))
        let firstNormalizedData = try Data(contentsOf: url)

        let secondTicket = AgentTaskPersistenceTicket(
            generation: generation,
            sequence: 2,
            projectKey: identity.persistenceKey,
            expectedDiskRevision: .versioned(revision),
            nextDiskRevision: revision
        )
        fence.authorize(secondTicket)
        #expect(
            await store.save(
                tasks: normalized.tasks,
                project: identity,
                authorization: AgentTaskPublicationAuthorization(
                    ticket: secondTicket,
                    fence: fence
                )
            ) == .saved(taskCount: normalized.tasks.count)
        )
        #expect(try Data(contentsOf: url) == firstNormalizedData)

        try installAgentFixture("agent-task-v2.json", at: url, project: project)
        let current = await store.load(project: identity)
        #expect(current.status == .loaded)
        #expect(!current.requiresMigration)

        try installAgentFixture("agent-task-future.json", at: url, project: project)
        let future = try Data(contentsOf: url)
        #expect(await store.load(project: identity).status == .rejected(.unknownSchema))
        #expect(try Data(contentsOf: url) == future)
    }

    @Test("corrupt, oversized, and invalid inputs are rejected untouched")
    func invalidInputsFailClosed() async throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let (defaults, defaultsName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let truncatedSession = Data("{\"schemaVersion\":1".utf8)
        defaults.set(truncatedSession, forKey: "lastSessionState")
        #expect(SessionState.load(for: project, defaults: defaults) == nil)
        #expect(defaults.data(forKey: "lastSessionState") == truncatedSession)

        let recovery = project.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(
            at: recovery,
            withIntermediateDirectories: true
        )
        let recoveryURL = recovery.appendingPathComponent("\(UUID()).json")
        let truncatedRecovery = Data("{\"schemaVersion\":1".utf8)
        try truncatedRecovery.write(to: recoveryURL)
        #expect(
            RecoveryManager(recoveryDirectory: recovery)
                .pendingRecoveryEntries().isEmpty
        )
        #expect(try Data(contentsOf: recoveryURL) == truncatedRecovery)

        let storage = project.appendingPathComponent("storage")
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: project.path,
            canonicalWorktreePath: project.path
        )
        let metadataURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: storage
        )
        let store = AgentTaskMetadataStore(storageRoot: storage)

        let oversized = Data(repeating: 0x41, count: 1_048_577)
        try installPrivate(oversized, at: metadataURL)
        #expect(
            await store.load(project: identity).status
                == .rejected(.storageLimit)
        )
        #expect(try Data(contentsOf: metadataURL) == oversized)

        let invalid = Data(
            """
            {
              "schemaVersion": 2,
              "revision": "22222222-2222-4222-8222-222222222222",
              "canonicalProjectPath": "/different/project",
              "canonicalWorktreePath": "/different/project",
              "tasks": []
            }
            """.utf8
        )
        try installPrivate(invalid, at: metadataURL)
        #expect(
            await store.load(project: identity).status
                == .rejected(.invalidMetadata)
        )
        #expect(try Data(contentsOf: metadataURL) == invalid)
    }

    private func installAgentFixture(
        _ name: String,
        at url: URL,
        project: URL
    ) throws {
        try fixtureData(name, project: project).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func installPrivate(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func saveNormalizedSession(
        _ state: SessionState,
        for project: URL,
        in defaults: UserDefaults
    ) -> Bool {
        SessionState.save(
            projectURL: project,
            openFileURLs: state.existingFileURLs,
            activeFileURL: state.activeFileURL,
            previewModes: state.previewModes,
            highlightingDisabledPaths: state.highlightingDisabledPaths,
            editorStates: state.editorStates,
            pinnedPaths: state.pinnedPaths,
            terminalPaneTabCounts: state.terminalPaneTabCounts,
            terminalPaneActiveIndices: state.terminalPaneActiveIndices,
            paneLayoutData: state.paneLayoutData,
            paneTabAssignments: state.paneTabAssignments,
            activePaneID: state.activePaneID,
            paneActiveEditorPaths: state.paneActiveEditorPaths,
            panePinnedPaths: state.panePinnedPaths,
            paneTransientPreviewPaths: state.paneTransientPreviewPaths,
            globalTabSwitchOrder: state.globalTabSwitchOrder,
            defaults: defaults,
            faultInjector: .none
        )
    }

    private func sessionRecord(in defaults: UserDefaults) throws -> Data {
        let key = try #require(
            defaults.dictionaryRepresentation().keys.first {
                $0.hasPrefix("sessionState:")
            }
        )
        return try #require(defaults.data(forKey: key))
    }

    private func installPreferences(
        _ name: String,
        in defaults: UserDefaults,
        project: URL
    ) throws {
        let object = try #require(
            JSONSerialization.jsonObject(
                with: fixtureData(name, project: project)
            ) as? [String: Any]
        )
        for (key, value) in object { defaults.set(value, forKey: key) }
    }

    private func decode<Value: Decodable>(_ name: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(contentsOf: fixtureURL(name)))
    }

    private func fixtureData(_ name: String, project: URL) throws -> Data {
        let contents = try String(
            contentsOf: fixtureURL(name),
            encoding: .utf8
        ).replacingOccurrences(of: "{{PROJECT_PATH}}", with: project.path)
        return Data(contents.utf8)
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Persistence")
            .appendingPathComponent(name)
    }

    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PinePersistence-\(UUID().uuidString)")
        let sources = project.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        try Data("let fixture = true\n".utf8).write(
            to: sources.appendingPathComponent("App.swift")
        )
        return project
    }

    private func makePrivateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PinePersistencePrivate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-N", root.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return root
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "PinePersistenceCorpus-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }
}
