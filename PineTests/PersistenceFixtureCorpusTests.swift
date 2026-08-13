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

    @Test("session fixtures load legacy/current and preserve future data")
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
        }

        let future = try fixtureData("session-future.json", project: project)
        defaults.set(future, forKey: "lastSessionState")
        #expect(SessionState.load(for: project, defaults: defaults) == nil)
        #expect(defaults.data(forKey: "lastSessionState") == future)
    }

    @Test("recovery fixtures load legacy/current and preserve future data")
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
            try FileManager.default.removeItem(at: url)
        }

        let id = UUID()
        let url = recovery.appendingPathComponent("\(id.uuidString).json")
        let future = try fixtureData("recovery-future.json", project: project)
        try future.write(to: url)
        #expect(manager.pendingRecoveryEntries().isEmpty)
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

        try installAgentFixture("agent-task-v2.json", at: url, project: project)
        let current = await store.load(project: identity)
        #expect(current.status == .loaded)
        #expect(!current.requiresMigration)

        try installAgentFixture("agent-task-future.json", at: url, project: project)
        let future = try Data(contentsOf: url)
        #expect(await store.load(project: identity).status == .rejected(.unknownSchema))
        #expect(try Data(contentsOf: url) == future)
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
