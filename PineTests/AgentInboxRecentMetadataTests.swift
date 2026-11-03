import Foundation
import Testing

@testable import Pine

@Suite("Inbox recent metadata without project admission", .serialized)
@MainActor
struct AgentInboxRecentMetadataTests {
    @Test("Welcome loads a durable task once without admitting a project or terminal")
    func loadsWithoutAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        #expect(registry.agentTasks.tasks.isEmpty)
        await registry.loadRecentAgentTasksForInbox()
        #expect(registry.agentTasks.tasks.map(\.id) == [fixture.task.id])
        #expect(registry.openProjects.isEmpty)
        #expect(registry.backgroundProjects.isEmpty)
        #expect(registry.keyWindowSession() == nil)
        await registry.loadRecentAgentTasksForInbox()
        #expect(await fixture.store.loadCount == 1)
        #expect(registry.agentTasks.tasks.count == 1)
    }

    @Test("metadata traversal needs search permission, not directory-list permission")
    func searchOnlyProjectCanLoadMetadata() async throws {
        let fixture = try Fixture()
        let registry = fixture.makeRegistry()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: fixture.project.path)
            fixture.cleanup()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o111],
                                              ofItemAtPath: fixture.project.path)
        await registry.loadRecentAgentTasksForInbox()
        #expect(registry.agentTasks.tasks.map(\.id) == [fixture.task.id])
        #expect(registry.openProjects.isEmpty)
    }

    @Test("an unavailable vendor resume leaves Welcome's Inbox without admitting a project")
    func unavailableResumeDoesNotPresentProject() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        await registry.loadRecentAgentTasksForInbox()
        var presented: [URL] = []
        let result = await registry.recoverAgentTaskFromInbox(
            fixture.task.id, action: .resumeVendorSession,
            openProjectWindow: { presented.append($0) },
            waitUntilPresented: { _ in true }
        )
        #expect(result == .unavailable(.vendorIdentityMissing))
        #expect(presented.isEmpty)
        #expect(registry.openProjects.isEmpty)
    }

    enum Invalidation: CaseIterable {
        case removedRecent, cancelled, replacedDirectory
    }

    @Test("metadata cannot publish after its caller or exact recent scope changes",
          arguments: Invalidation.allCases)
    func staleLoadIsDiscarded(invalidation: Invalidation) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = Gate()
        let registry = fixture.makeRegistry(beforeCommit: { await gate.wait() })
        let load = Task { await registry.loadRecentAgentTasksForInbox() }
        #expect(await waitUntilMainActor { gate.entered })
        switch invalidation {
        case .removedRecent:
            registry.clearRecentProjects()
        case .cancelled:
            load.cancel()
        case .replacedDirectory:
            try FileManager.default.moveItem(at: fixture.project,
                                            to: fixture.root.appendingPathComponent("old-project"))
            try FileManager.default.createDirectory(at: fixture.project, withIntermediateDirectories: true)
        }
        gate.release()
        await load.value
        #expect(registry.agentTasks.tasks.isEmpty)
        #expect(registry.openProjects.isEmpty)
        #expect(registry.backgroundProjects.isEmpty)
    }

    @Test("explicit project registration overtaking an Inbox read cannot duplicate metadata")
    func explicitRegistrationWins() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = Gate()
        let registry = fixture.makeRegistry(beforeCommit: { await gate.wait() })
        let load = Task { await registry.loadRecentAgentTasksForInbox() }
        #expect(await waitUntilMainActor { gate.entered })
        registry.agentTasks.registerProject(fixture.task.project)
        #expect(await waitUntilMainActor { registry.agentTasks.tasks.count == 1 })
        gate.release()
        await load.value
        #expect(registry.agentTasks.tasks.map(\.id) == [fixture.task.id])
        #expect(registry.openProjects.isEmpty)
    }

    @Test("a linked-worktree recent record without repository proof never reads metadata")
    func missingRepositoryProofIsRejected() async throws {
        let fixture = try Fixture(linked: true)
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        await registry.loadRecentAgentTasksForInbox()
        #expect(await fixture.store.loadCount == 0)
        #expect(registry.agentTasks.tasks.isEmpty)
        #expect(registry.openProjects.isEmpty)
    }

    @Test("a legacy path-only Recent is not authority to read task metadata")
    func pathOnlyRecentIsNotLoaded() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.removeObject(forKey: "recentProjectAgentTaskIdentities")
        let registry = fixture.makeRegistry()
        await registry.loadRecentAgentTasksForInbox()
        #expect(await fixture.store.loadCount == 0)
        #expect(registry.agentTasks.tasks.isEmpty)
    }

    private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private struct Record: Encodable {
        let identity: AgentTaskProjectIdentity
    }

    private final class Fixture {
        let root: URL
        let project: URL
        let suite: String
        let defaults: UserDefaults
        let task: AgentTask
        let store: Store

        init(linked: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("InboxRecentMetadata-\(UUID())")
            project = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            suite = "InboxRecentMetadata.\(UUID())"
            defaults = try #require(UserDefaults(suiteName: suite))
            let identity = AgentTaskProjectIdentity(
                canonicalProjectPath: linked ? root.path : project.path,
                canonicalWorktreePath: project.path
            )
            let terminal = UUID()
            var task = AgentTask(
                descriptor: AgentDescriptor(agentType: .codex, launchExecutable: "codex"),
                context: AgentTaskBridgeContext(
                    project: identity,
                    route: AgentTaskRoute(paneID: UUID(), tabID: terminal, terminalID: terminal),
                    origin: .pineLaunched, observedAt: Date()
                ),
                title: "Recovery fixture"
            )
            task.lifecycle = .paused
            task.launchInterruption = .acknowledgedBeforeVerification
            self.task = task
            store = Store(task: task)
            defaults.set([project.path], forKey: "recentProjectPaths")
            defaults.set(try JSONEncoder().encode([Record(identity: identity)]),
                         forKey: "recentProjectAgentTaskIdentities")
        }

        func makeRegistry(
            beforeCommit: @escaping @Sendable () async -> Void = {}
        ) -> ProjectRegistry {
            ProjectRegistry(
                defaults: defaults, agentTasks: AgentTaskRegistry(persistence: store),
                agentTaskFilesystemValidationCommitSeam: beforeCommit,
                agentDetectionPollInterval: 3_600, agentDetectionInitialPollDelay: 3_600
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private actor Store: AgentTaskPersisting {
        let task: AgentTask
        private(set) var loadCount = 0
        init(task: AgentTask) { self.task = task }
        func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
            loadCount += 1
            return AgentTaskMetadataLoadResult(status: .loaded, tasks: [task])
        }
        func save(tasks: [AgentTask], project: AgentTaskProjectIdentity,
                  authorization: AgentTaskPublicationAuthorization?) async -> AgentTaskMetadataSaveResult {
            .saved(taskCount: tasks.count)
        }
    }
}
