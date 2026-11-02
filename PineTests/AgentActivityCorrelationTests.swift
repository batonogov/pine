import Foundation
import Testing
@testable import Pine

@Suite("Agent activity content correlation", .timeLimit(.minutes(1)))
@MainActor
struct AgentActivityCorrelationTests {
    @Test("Same-size writes with restored mtime produce separate actions; refreshes stay silent")
    func repeatedDirtyFileChanges() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("dirty.txt")
        try Data("aaaa".utf8).write(to: file)
        let mtime = try #require(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let store = AgentActivityStore()
        let session = AgentSession(agentType: .codex, state: .executing)
        let correlation = AgentActivityCorrelation(store: store, currentSessionIDs: { [session.id] })
        await correlation.submit(rootURL: root, paths: ["dirty.txt"], sessions: [session])?.value
        #expect(store.actions.isEmpty) // pre-existing dirty file is only a seed
        for text in ["bbbb", "cccc"] {
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
            await correlation.submit(rootURL: root, paths: ["dirty.txt"], sessions: [session])?.value
        }
        #expect(store.actions.count == 2) // no time-window loss of real edits
        #expect(store.actions.allSatisfy { $0.sessionID == session.id })
        await correlation.submit(rootURL: root, paths: ["dirty.txt"], sessions: [session])?.value
        #expect(store.actions.count == 2)
    }

    @Test("New files, removal from dirty set, and re-addition preserve content semantics")
    func dirtySetPruningAndNewPaths() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = AgentSession(agentType: .codex)
        let store = AgentActivityStore()
        let correlation = AgentActivityCorrelation(store: store, currentSessionIDs: { [session.id] })
        await correlation.submit(rootURL: root, paths: [], sessions: [session])?.value
        try Data("new".utf8).write(to: root.appendingPathComponent("new.txt"))
        await correlation.submit(rootURL: root, paths: ["new.txt"], sessions: [session])?.value
        #expect(store.actions.count == 1)
        await correlation.submit(rootURL: root, paths: [], sessions: [session])?.value
        await correlation.submit(rootURL: root, paths: ["new.txt"], sessions: [session])?.value
        #expect(store.actions.count == 2)
    }

    @Test("Production hashing is off-main, streaming across chunks, and skips non-regular files")
    func productionFingerprint() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large")
        var bytes = Data(repeating: 0x61, count: 200_000)
        try bytes.write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: file)
        // Called from MainActor; production precondition proves the I/O closure isn't on it.
        let first = await AgentActivityFingerprint.snapshot(rootURL: root, paths: ["large", "link", "missing", "."])
        #expect(Set(first.keys) == ["large"])
        bytes[199_999] = 0x62
        try bytes.write(to: file)
        let second = await AgentActivityFingerprint.snapshot(rootURL: root, paths: ["large"])
        #expect(first["large"] != second["large"])
    }

    @Test("Superseded requests coalesce to the newest and a stale seed cannot become authoritative")
    func latestSequenceWins() async throws {
        let fixture = ControlledCorrelation()
        let a = AgentSession(agentType: .codex)
        fixture.live = [a.id]
        let task = fixture.submit(a)
        try await fixture.waitForRequest(1)
        fixture.submit(a)
        fixture.submit(a)
        fixture.complete(0, "obsolete")
        try await fixture.waitForRequest(2)
        #expect(fixture.requests.count == 2)
        fixture.complete(1, "latest")
        await task?.value
        #expect(fixture.store.actions.isEmpty)
        let next = fixture.submit(a)
        try await fixture.waitForRequest(3)
        fixture.complete(2, "latest")
        await next?.value
        #expect(fixture.store.actions.isEmpty)
    }

    @Test("Late A result cannot be attributed to B, whose pending request seeds cleanly")
    func staleWorkerAndPendingSessionSwitch() async throws {
        let fixture = ControlledCorrelation()
        let a = AgentSession(agentType: .codex)
        let b = AgentSession(agentType: .claudeCode)
        try await fixture.acceptSeed(a, value: "a-seed")
        let task = fixture.submit(a)
        try await fixture.waitForRequest(2)
        fixture.live = [b.id]
        fixture.submit(b)
        fixture.complete(1, "a-edit")
        try await fixture.waitForRequest(3)
        fixture.complete(2, "b-seed")
        await task?.value
        #expect(fixture.store.actions.isEmpty)
        let next = fixture.submit(b)
        try await fixture.waitForRequest(4)
        fixture.complete(3, "b-edit")
        await next?.value
        #expect(fixture.store.actions.count == 1)
        #expect(fixture.store.actions.first?.sessionID == b.id)
    }

    @Test("Changed ownership without a new refresh rejects a late worker and invalidates its baseline")
    func ownershipRevalidationWithoutSubmit() async throws {
        let fixture = ControlledCorrelation()
        let a = AgentSession(agentType: .codex)
        let b = AgentSession(agentType: .claudeCode)
        try await fixture.acceptSeed(a, value: "seed")
        let task = fixture.submit(a)
        try await fixture.waitForRequest(2)
        fixture.live = [b.id]
        fixture.complete(1, "old-edit")
        await task?.value
        #expect(fixture.store.actions.isEmpty)
        // A comes back before another watcher refresh: the stale baseline must not survive.
        fixture.live = [a.id]
        let next = fixture.submit(a)
        try await fixture.waitForRequest(3)
        fixture.complete(2, "fresh-seed")
        await next?.value
        #expect(fixture.store.actions.isEmpty)
    }

    @Test("No-agent transition fences pending work and requires a fresh seed on return")
    func noAgentTransitionWithPendingRequest() async throws {
        let fixture = ControlledCorrelation()
        let a = AgentSession(agentType: .codex)
        try await fixture.acceptSeed(a, value: "seed")
        let task = fixture.submit(a)
        try await fixture.waitForRequest(2)
        fixture.submit(a) // a pending old-generation request
        fixture.live = []
        fixture.correlation.submit(rootURL: fixture.root, paths: [], sessions: [])
        fixture.live = [a.id]
        fixture.submit(a) // same UUID, but a new clean-seed epoch
        fixture.complete(1, "stale-edit")
        try await fixture.waitForRequest(3)
        fixture.complete(2, "fresh-seed")
        await task?.value
        #expect(fixture.store.actions.isEmpty)
        #expect(fixture.requests.count == 3)
    }

    @Test("An expanded or reduced exact session set reseeds, never inherits another set's baseline")
    func exactSessionSetChanges() async throws {
        let fixture = ControlledCorrelation()
        let a = AgentSession(agentType: .codex)
        let b = AgentSession(agentType: .claudeCode)
        try await fixture.acceptSeed(a, value: "seed")
        fixture.live = [a.id, b.id]
        let task = fixture.correlation.submit(rootURL: fixture.root, paths: ["dirty"], sessions: [b, a])
        try await fixture.waitForRequest(2)
        fixture.complete(1, "different")
        await task?.value
        #expect(fixture.store.actions.isEmpty)
        fixture.live = [a.id]
        let next = fixture.submit(a)
        try await fixture.waitForRequest(3)
        fixture.complete(2, "another-seed")
        await next?.value
        #expect(fixture.store.actions.isEmpty)
    }

    @Test("A transient failed fingerprint preserves known content; an unavailable seed stays silent")
    func unavailableFingerprintDoesNotInventWork() async throws {
        let fixture = ControlledCorrelation()
        let a = AgentSession(agentType: .codex)
        try await fixture.acceptSeed(a, value: "same")
        let failed = fixture.submit(a)
        try await fixture.waitForRequest(2)
        fixture.continuations.removeValue(forKey: 1)?.resume(returning: [:])
        await failed?.value
        let recovered = fixture.submit(a)
        try await fixture.waitForRequest(3)
        fixture.complete(2, "same")
        await recovered?.value
        #expect(fixture.store.actions.isEmpty)

        let unavailable = ControlledCorrelation()
        unavailable.live = [a.id]
        let seed = unavailable.submit(a)
        try await unavailable.waitForRequest(1)
        unavailable.continuations.removeValue(forKey: 0)?.resume(returning: [:])
        await seed?.value
        let firstReadable = unavailable.submit(a)
        try await unavailable.waitForRequest(2)
        unavailable.complete(1, "previously unreadable")
        await firstReadable?.value
        #expect(unavailable.store.actions.isEmpty)
    }

    @Test("Recovery compares against the last known digest and pruning forgets unavailable paths")
    func failedFingerprintRecoveryAndPruning() async throws {
        let fixture = ControlledCorrelation()
        let session = AgentSession(agentType: .codex)
        try await fixture.acceptSeed(session, value: "before")
        for index in 1...2 {
            let task = fixture.submit(session)
            try await fixture.waitForRequest(index + 1)
            fixture.continuations.removeValue(forKey: index)?.resume(returning: [:])
            await task?.value
        }
        let changed = fixture.submit(session)
        try await fixture.waitForRequest(4)
        fixture.complete(3, "after")
        await changed?.value
        #expect(fixture.store.actions.count == 1)
        let pruned = fixture.correlation.submit(rootURL: fixture.root, paths: [], sessions: [session])
        try await fixture.waitForRequest(5)
        fixture.continuations.removeValue(forKey: 4)?.resume(returning: [:])
        await pruned?.value
        let readded = fixture.submit(session)
        try await fixture.waitForRequest(6)
        fixture.complete(5, "after")
        await readded?.value
        #expect(fixture.store.actions.count == 2)
    }

    @Test("A newly requested unavailable path records once on recovery, unlike an unavailable seed")
    func newlyRequestedUnavailablePath() async throws {
        let fixture = ControlledCorrelation()
        let session = AgentSession(agentType: .codex)
        fixture.live = [session.id]
        let empty = fixture.correlation.submit(rootURL: fixture.root, paths: [], sessions: [session])
        try await fixture.waitForRequest(1)
        fixture.continuations.removeValue(forKey: 0)?.resume(returning: [:])
        await empty?.value
        let failed = fixture.submit(session)
        try await fixture.waitForRequest(2)
        fixture.continuations.removeValue(forKey: 1)?.resume(returning: [:])
        await failed?.value
        let recovered = fixture.submit(session)
        try await fixture.waitForRequest(3)
        fixture.complete(2, "first known")
        await recovered?.value
        #expect(fixture.store.actions.count == 1)
        let changed = fixture.submit(session)
        try await fixture.waitForRequest(4)
        fixture.complete(3, "changed")
        await changed?.value
        #expect(fixture.store.actions.count == 2)
    }

    @Test("Accepted content-only workspace refreshes fingerprint without publishing shallow trees")
    func acceptedWorkspaceRefreshes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialized = await GitStatusProvider.runGitAsync(["init"], at: root)
        try #require(initialized.succeeded)
        let file = root.appendingPathComponent("dirty.txt")
        try Data("aaaa".utf8).write(to: file)
        let mtime = try #require(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let workspace = WorkspaceManager(fileWatcherFactory: { _ in CorrelationNoopWatcher() })
        workspace.rootURL = root
        let session = AgentSession(agentType: .codex)
        let store = AgentActivityStore()
        let correlation = AgentActivityCorrelation(store: store, currentSessionIDs: { [session.id] })
        var accepted = 0
        workspace.setOnRefreshAccepted { url in
            #expect(url == root)
            #expect(workspace.gitProvider.fileStatuses["dirty.txt"] == .untracked)
            correlation.submit(rootURL: url, paths: Array(workspace.gitProvider.fileStatuses.keys), sessions: [session])
            accepted += 1
        }
        workspace.refreshFileTreeAsync()
        try #require(await waitUntilMainActor { accepted == 1 })
        await correlation.waitUntilIdle()
        #expect(store.actions.isEmpty)
        let revision = workspace.rootNodesRevision
        for (index, text) in ["bbbb", "cccc"].enumerated() {
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
            workspace.refreshFileTreeAsync()
            try #require(await waitUntilMainActor { accepted == index + 2 })
            await correlation.waitUntilIdle()
            #expect(store.actions.count == index + 1)
            #expect(workspace.rootNodesRevision == revision)
        }
        workspace.refreshFileTreeAsync()
        try #require(await waitUntilMainActor { accepted == 4 })
        await correlation.waitUntilIdle()
        #expect(store.actions.count == 2)
        #expect(workspace.rootNodesRevision == revision)
        workspace.suspend()
        workspace.refreshFileTreeAsync()
        #expect(accepted == 4)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pine-1688-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

@MainActor
private final class CorrelationNoopWatcher: WorkspaceFileWatching {
    func watch(directory: URL) {}
    func stop() {}
}

@MainActor
private final class ControlledCorrelation {
    let root = URL(fileURLWithPath: "/controlled")
    let store = AgentActivityStore()
    var live: Set<UUID> = []
    var requests: [[String]] = []
    var continuations: [Int: CheckedContinuation<[String: Data], Never>] = [:]
    lazy var correlation = AgentActivityCorrelation(
        store: store,
        currentSessionIDs: { [unowned self] in live },
        fingerprint: { [unowned self] _, paths in await self.capture(paths) }
    )

    @discardableResult
    func submit(_ session: AgentSession) -> Task<Void, Never>? {
        correlation.submit(rootURL: root, paths: ["dirty"], sessions: [session])
    }

    func capture(_ paths: [String]) async -> [String: Data] {
        let index = requests.count
        requests.append(paths)
        return await withCheckedContinuation { continuations[index] = $0 }
    }

    func waitForRequest(_ count: Int) async throws {
        try #require(await waitUntilMainActor { self.requests.count >= count })
    }

    func complete(_ index: Int, _ value: String) {
        continuations.removeValue(forKey: index)?.resume(returning: ["dirty": Data(value.utf8)])
    }

    func acceptSeed(_ session: AgentSession, value: String) async throws {
        live = [session.id]
        let task = submit(session)
        try await waitForRequest(1)
        complete(0, value)
        await task?.value
    }
}
