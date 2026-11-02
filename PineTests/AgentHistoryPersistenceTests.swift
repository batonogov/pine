import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("Agent History persistence integrity")
nonisolated struct AgentHistoryPersistenceTests {
    private func project() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-history-1681-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ index: Int, id: UUID = UUID(), sessionID: UUID = UUID()) -> AgentHistoryEntry {
        AgentHistoryEntry(
            id: id, sessionID: sessionID, agentTypeRaw: "codex",
            startedAt: Date(timeIntervalSince1970: 1_000 + Double(index) + 0.75),
            affectedFiles: ["a.swift"], summary: "entry \(index)"
        )
    }

    private func read(_ root: URL) throws -> [AgentHistoryEntry] {
        try AgentHistoryStore.makeDecoder().decode(
            [AgentHistoryEntry].self,
            from: Data(contentsOf: root.appendingPathComponent(".pine/agent-log.json"))
        )
    }

    private func persist(_ snapshot: [AgentHistoryEntry], root: URL) {
        let writer = AgentHistoryLogWriter()
        writer.persist(snapshot: snapshot, root: root)
        writer.flush()
    }

    @Test func symlinkedPineCannotEscape() throws {
        let root = try project()
        let outside = try project()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".pine"), withDestinationURL: outside
        )
        persist([entry(1)], root: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test(arguments: ["agent-log.json", ".agent-log.lock", ".agent-log.json.tmp"])
    func symlinkedFilesCannotChangeOutsideTarget(name: String) throws {
        let root = try project()
        let outside = try project()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let pine = root.appendingPathComponent(".pine")
        try FileManager.default.createDirectory(at: pine, withIntermediateDirectories: false)
        let target = outside.appendingPathComponent("target")
        let sentinel = Data("outside sentinel".utf8)
        try sentinel.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: pine.appendingPathComponent(name), withDestinationURL: target
        )
        persist([entry(1)], root: root)
        #expect(try Data(contentsOf: target) == sentinel)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["target"])
        if name != ".agent-log.json.tmp" {
            // Unsafe log/lock inputs fail closed, rather than replacing the
            // symlink with a newly trusted history projection.
            if name == "agent-log.json" {
                #expect(try FileManager.default.destinationOfSymbolicLink(
                    atPath: pine.appendingPathComponent(name).path
                ) == target.path)
            } else {
                #expect(!FileManager.default.fileExists(atPath: pine.appendingPathComponent("agent-log.json").path))
            }
        }
    }

    @Test @MainActor func sequentialIndependentStoresMerge() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AgentHistoryStore(projectRoot: root)
        let second = AgentHistoryStore(projectRoot: root)
        let a = entry(1)
        let b = entry(2)
        first.append(a)
        first.flush()
        second.append(b)
        second.flush()
        #expect(Set(try read(root).map(\.id)) == [a.id, b.id])
    }

    @Test(arguments: 0..<20)
    func concurrentIndependentWritersMerge(iteration: Int) throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = (0..<24).map { entry($0) }
        let writers = rows.map { _ in AgentHistoryLogWriter() }
        for (writer, row) in zip(writers, rows) {
            writer.persist(snapshot: [row], root: root)
        }
        for writer in writers { writer.flush() }
        #expect(Set(try read(root).map(\.id)) == Set(rows.map(\.id)), "iteration \(iteration)")
    }

    @Test(arguments: [1, 8])
    func competingLockHolderCannotHangFlushOrChangeDisk(pendingWrites: Int) throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        persist([entry(1)], root: root)
        let log = root.appendingPathComponent(".pine/agent-log.json")
        let before = try Data(contentsOf: log)
        let lock = open(root.appendingPathComponent(".pine/.agent-log.lock").path, O_RDWR | O_NOFOLLOW)
        try #require(lock >= 0)
        defer { close(lock) }
        try #require(flock(lock, LOCK_EX | LOCK_NB) == 0)
        defer { flock(lock, LOCK_UN) }
        let writer = AgentHistoryLogWriter()
        for index in 0..<pendingWrites {
            writer.persist(snapshot: [entry(2 + index)], root: root)
        }
        let flushed = DispatchSemaphore(value: 0)
        let work = DispatchWorkItem {
            writer.flush()
            flushed.signal()
        }
        DispatchQueue.global().async(execute: work)
        let returnedWithinBound = flushed.wait(timeout: .now() + .seconds(4)) == .success
        // Always release the competing holder, even when run against a blocking
        // implementation, so this regression can fail without hanging the suite.
        flock(lock, LOCK_UN)
        if !returnedWithinBound {
            #expect(flushed.wait(timeout: .now() + .seconds(4)) == .success)
        }
        #expect(returnedWithinBound)
        #expect(try Data(contentsOf: log) == before)
    }

    @Test func lockReleasedBeforeDeadlineAllowsMerge() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = entry(1)
        let second = entry(2)
        persist([first], root: root)
        let lock = open(root.appendingPathComponent(".pine/.agent-log.lock").path, O_RDWR | O_NOFOLLOW)
        try #require(lock >= 0)
        defer { close(lock) }
        try #require(flock(lock, LOCK_EX | LOCK_NB) == 0)
        defer { flock(lock, LOCK_UN) }
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            flock(lock, LOCK_UN)
            released.signal()
        }
        persist([second], root: root)
        #expect(released.wait(timeout: .now() + .seconds(4)) == .success)
        #expect(Set(try read(root).map(\.id)) == [first.id, second.id])
    }

    @Test func staleSnapshotCannotResurrectRevertedEntry() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = entry(1)
        var reverted = original
        reverted.reverted = true
        persist([reverted], root: root)
        persist([original, entry(2)], root: root)
        #expect(try read(root).first(where: { $0.id == original.id })?.reverted == true)
        #expect(try read(root).count == 2)
    }

    @Test func fractionalDatesHaveStableCapacityEviction() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = (0..<502).map { entry($0) }
        persist(Array(rows.prefix(500)), root: root)
        // A stale store retains the evicted row and subsecond in-memory dates.
        persist([rows[0], rows[500]], root: root)
        persist([rows[0], rows[501]], root: root)
        let retained = try read(root)
        #expect(retained.count == 500)
        #expect(Set(retained.map(\.id)) == Set(rows.dropFirst(2).map(\.id)))
        let before = try Data(contentsOf: root.appendingPathComponent(".pine/agent-log.json"))
        persist([rows[0], rows[501]], root: root)
        #expect(try Data(contentsOf: root.appendingPathComponent(".pine/agent-log.json")) == before)
    }

    @Test func sameSecondEvictionDoesNotResurrectFractionalDates() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = try (0..<501).map { index in
            AgentHistoryEntry(
                id: try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))),
                sessionID: UUID(), agentTypeRaw: "codex",
                startedAt: Date(timeIntervalSince1970: 1_000 + Double(index) / 1_000),
                affectedFiles: [], summary: "entry \(index)"
            )
        }
        persist(Array(rows.prefix(500)), root: root)
        persist([rows[0], rows[500]], root: root)
        persist(rows, root: root)
        #expect(Set(try read(root).map(\.id)) == Set(rows.dropFirst().map(\.id)))
        let before = try Data(contentsOf: root.appendingPathComponent(".pine/agent-log.json"))
        persist(rows, root: root)
        #expect(try Data(contentsOf: root.appendingPathComponent(".pine/agent-log.json")) == before)
    }

    @Test(arguments: ["malformed", "duplicate"])
    func corruptDiskRemainsUntouched(kind: String) throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let pine = root.appendingPathComponent(".pine")
        try FileManager.default.createDirectory(at: pine, withIntermediateDirectories: false)
        let row = entry(1)
        let data = try kind == "malformed" ? Data("{broken".utf8)
            : AgentHistoryStore.makeEncoder().encode([row, row])
        let log = pine.appendingPathComponent("agent-log.json")
        try data.write(to: log)
        persist([entry(2)], root: root)
        #expect(try Data(contentsOf: log) == data)
    }

    @Test(arguments: ["entry", "session", "changeSet", "authority", "payload"])
    @MainActor func independentIdentityConflictsDoNotReplaceDisk(kind: String) throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AgentHistoryChangeSetFixtures.entry()
        let contract = try #require(first.verifiedChangeSet)
        let conflicting = AgentHistoryChangeSetFixtures.entry(
            id: kind == "entry" ? first.id : UUID(),
            sessionID: kind == "session" ? first.sessionID : UUID(),
            changeSetID: kind == "changeSet" ? contract.id : UUID(),
            authorityRecordID: kind == "authority" ? contract.authority.recordID : UUID(),
            payloadBlobID: kind == "payload" ? contract.inversePayload.blobID : UUID()
        )
        persist([first], root: root)
        let before = try Data(contentsOf: root.appendingPathComponent(".pine/agent-log.json"))
        persist([conflicting], root: root)
        #expect(try Data(contentsOf: root.appendingPathComponent(".pine/agent-log.json")) == before)
    }
}
