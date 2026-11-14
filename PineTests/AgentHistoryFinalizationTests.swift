import Foundation
import Testing

@testable import Pine

nonisolated final class BlockingHistoryPathResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private let gate = DispatchSemaphore(value: 0)
    var hasEntered: Bool { lock.withLock { entered } }
    func release() { gate.signal() }
    func resolve(root: URL, files: [URL]) -> [String] {
        lock.withLock { entered = true }
        gate.wait()
        return AgentHistoryPathResolution.relativePaths(root: root, files: files)
    }
}

@MainActor
@Suite("Completed history path resolution")
struct AgentHistoryFinalizationTests {
    @Test func blockedResolutionRetainsCompletionAndLeavesMainActorResponsive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pine-history-paths-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "PineTests.HistoryPaths.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let blocked = BlockingHistoryPathResolution()
        defer { blocked.release() }
        var manager: ProjectManager? = ProjectManager(
            sessionDefaults: defaults,
            agentHistoryPrivateStore: AgentHistoryPrivateStore(baseDirectory: root.appendingPathComponent("private")),
            agentHistoryPathResolver: { blocked.resolve(root: $0, files: $1) }
        )
        manager?.loadDirectory(url: root)
        manager?.workspace.suspend()
        let pane = try #require(manager?.paneManager.createTerminalPaneAtBottom(workingDirectory: root))
        let tab = try #require(manager?.paneManager.terminalState(for: pane)?.activeTab)
        let session = AgentSession(agentType: .codex, state: .executing)
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 1770, processGeneration: 1, startIdentifier: "history-path-resolution",
            observedStartedAt: Date(timeIntervalSince1970: 1770), startIsAuthoritative: true
        ))
        session.filesModified = [root.appendingPathComponent("Changed.swift")]
        tab.agentSession = session
        manager?.terminal.captureProjectAgentOwnership(of: session, in: tab)
        session.recordLifecycleState(.done, accuracy: .processTerminationOnly)
        session.applyLiveness(.terminated)
        manager?.finalizeAgentSessionsForHistory()
        // This main-actor poll must remain runnable while the resolver is
        // stalled. A synchronous filesystem path would deadlock here.
        try #require(await waitUntilMainActor { blocked.hasEntered })
        #expect(manager?.hasPendingAgentHistory == true)
        #expect(manager?.requiresBackgroundRetention == true)
        #expect(manager?.agentHistory.entries.isEmpty == true)
        weak var retained = manager
        manager = nil
        #expect(retained != nil)
        let retainedManager = try #require(retained)
        let barrier = Task { @MainActor in await retainedManager.flushAgentHistoryPersistence() }
        barrier.cancel()
        // Cancellation/timeout must leave the captured completion owned.
        #expect(retained?.hasPendingAgentHistory == true)
        blocked.release()
        #expect(await barrier.value == false)
        #expect(await retainedManager.flushAgentHistoryPersistence())
        #expect(retainedManager.agentHistory.entries.map(\.sessionID) == [session.id])
        #expect(retainedManager.agentHistory.entries.first?.affectedFiles == ["Changed.swift"])
    }

    @Test func resolvedPathsStayInsideCanonicalProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pine-history-links-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("changed".utf8).write(to: root.appendingPathComponent("Changed.swift"))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let paths = await AgentHistoryPathResolution.resolve(
            root: root, files: [link.appendingPathComponent("Changed.swift"), URL(fileURLWithPath: "/outside.swift")],
            using: AgentHistoryPathResolution.relativePaths
        )
        #expect(paths == ["Changed.swift"])
    }
}
