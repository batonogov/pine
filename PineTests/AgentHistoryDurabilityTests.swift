import Darwin
import Foundation
import Testing

@testable import Pine

@MainActor
@Suite("Agent history durability acknowledgements")
struct AgentHistoryDurabilityTests {
    @Test func acknowledgedSnapshotSurvivesIndependentReopen() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        let row = entry()
        store.append(row)
        #expect(store.persistenceState == .pending)
        #expect(await store.flushPersistence())
        #expect(store.persistenceState == .saved)
        let restarted = makeStore(root)
        #expect(restarted.entries.map(\.sessionID) == [row.sessionID])
        restarted.append(row)
        #expect(await restarted.flushPersistence())
        #expect(makeStore(root).entries.count == 1)
    }

    @Test(arguments: ["{broken", "[{\"futureSchema\":99}]"])
    func unreadableStoreRetainsPendingEntryAndOriginalBytes(original: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pine = root.appendingPathComponent(".pine")
        try FileManager.default.createDirectory(at: pine, withIntermediateDirectories: true)
        let log = pine.appendingPathComponent("agent-log.json")
        let bytes = Data(original.utf8)
        try bytes.write(to: log)
        let store = makeStore(root)
        let row = entry()
        store.append(row)
        #expect(!(await store.flushPersistence()))
        #expect(store.persistenceState == .failed)
        #expect(store.entries.map(\.sessionID) == [row.sessionID])
        #expect(try Data(contentsOf: log) == bytes)
        // External recovery restores a readable log; retry merges the retained
        // entry without requiring a second terminal completion notification.
        try Data("[]".utf8).write(to: log)
        #expect(await store.flushPersistence())
        #expect(makeStore(root).entries.map(\.sessionID) == [row.sessionID])
    }

    @Test(arguments: [false, true])
    func futureFieldsCannotBeSilentlyDroppedOnAppend(nullValue: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pine = root.appendingPathComponent(".pine")
        try FileManager.default.createDirectory(at: pine, withIntermediateDirectories: true)
        let log = pine.appendingPathComponent("agent-log.json")
        var rows = try #require(JSONSerialization.jsonObject(
            with: AgentHistoryStore.makeEncoder().encode([entry()])
        ) as? [[String: Any]])
        if nullValue {
            rows[0]["futureMetadata"] = NSNull()
        } else {
            rows[0]["futureMetadata"] = ["schemaVersion": 99]
        }
        let bytes = try JSONSerialization.data(withJSONObject: rows)
        try bytes.write(to: log)
        let store = makeStore(root)
        store.append(entry())
        #expect(!(await store.flushPersistence()))
        #expect(store.persistenceState == .failed)
        #expect(store.entries.count == 2)
        #expect(try Data(contentsOf: log) == bytes)
    }

    @Test func lockTimeoutAndIOFailureNeverAcknowledgeDurability() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        store.append(entry())
        try #require(await store.flushPersistence())
        let log = root.appendingPathComponent(".pine/agent-log.json")
        let before = try Data(contentsOf: log)
        let lock = open(root.appendingPathComponent(".pine/.agent-log.lock").path, O_RDWR | O_NOFOLLOW)
        try #require(lock >= 0)
        defer { close(lock) }
        try #require(flock(lock, LOCK_EX | LOCK_NB) == 0)
        defer { flock(lock, LOCK_UN) }
        let added = entry()
        store.append(added)
        #expect(!(await store.flushPersistence()))
        #expect(store.persistenceState == .failed)
        #expect(try Data(contentsOf: log) == before)
        flock(lock, LOCK_UN)
        #expect(await store.flushPersistence())
        #expect(makeStore(root).entries.count == 2)

        // A regular-file ancestor cannot become a project directory, even
        // if private-store discovery runs concurrently during initialization.
        try Data("blocked".utf8).write(to: root.appendingPathComponent("blocked"))
        let unavailable = root.appendingPathComponent("blocked/project")
        let failed = makeStore(unavailable)
        failed.append(entry())
        #expect(!(await failed.flushPersistence()))
        #expect(failed.hasPendingPersistence)
        #expect(failed.entries.count == 1)
    }

    private func makeStore(_ root: URL) -> AgentHistoryStore {
        AgentHistoryStore(
            projectRoot: root,
            privateStore: AgentHistoryPrivateStore(
                baseDirectory: root.appendingPathComponent("private-history")
            )
        )
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pine-history-durability-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry() -> AgentHistoryEntry {
        AgentHistoryEntry(
            sessionID: UUID(), agentTypeRaw: "codex", startedAt: Date(),
            affectedFiles: ["Sources/Changed.swift"], summary: "1 file"
        )
    }
}
