//
//  ProjectWindowSessionTests.swift
//  PineTests
//

import CryptoKit
import Foundation
import Testing

@testable import Pine

@Suite("Project Window Session", .serialized)
@MainActor
struct ProjectWindowSessionTests {
    fileprivate static let noOpProcessRunner: ProcessRunner = { _, _, _, _ in
        ProcessRunResult(
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }

    @Test("a fresh restored scene admits its initial project exactly once")
    func freshSceneRestoration() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )

        #expect(
            registry.projectManagerIfAdmitted(for: fixture.firstProject) == nil
        )
        #expect(
            await session.restoreIfNeeded(registry: registry) == .restored
        )
        let manager = try #require(
            registry.projectManagerIfAdmitted(for: fixture.firstProject)
        )

        session.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.firstProject)
        #expect(
            await session.restoreIfNeeded(registry: registry)
                == .alreadyRestored
        )
        #expect(
            registry.projectManagerIfAdmitted(for: fixture.firstProject)
                === manager
        )
        #expect(!registry.isWindowOpen(fixture.firstProject))
    }

    @Test("cold restoration keeps a closed anchor closed")
    func closedAnchorColdRestoration() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let firstRegistry = fixture.makeRegistry()
        _ = try #require(
            firstRegistry.projectManager(for: fixture.firstProject)
        )
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await session.openProject(
            fixture.secondProject,
            registry: firstRegistry
        )
        #expect(
            await session.closeProject(
                fixture.firstProject,
                registry: firstRegistry
            )
        )
        session.windowDidClose(registry: firstRegistry)

        let coldRegistry = fixture.makeRegistry()
        let restored = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )

        #expect(
            await restored.restoreIfNeeded(registry: coldRegistry)
                == .restored
        )
        #expect(
            restored.activeProjectURL
                == fixture.secondProject.standardizedFileURL
        )
        #expect(
            coldRegistry.projectManagerIfAdmitted(
                for: fixture.secondProject
            ) != nil
        )
        #expect(
            coldRegistry.projectManagerIfAdmitted(
                for: fixture.firstProject
            ) == nil
        )
    }

    /// #1543: a window anchored at project A that the user last switched to
    /// project B persists `activeURL = B`. Every later *explicit* open of A —
    /// Open Folder, Open Recent, the Dock menu, `PINE_OPEN_PROJECT` — created
    /// a scene keyed by A and then restored B over it, so the user got a
    /// project they never asked for and the state never healed itself.
    @Test("an explicit open shows the requested project, not the last active one")
    func explicitOpenBeatsPersistedActiveProject() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let firstRegistry = fixture.makeRegistry()
        _ = try #require(
            firstRegistry.projectManager(for: fixture.firstProject)
        )
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await session.openProject(
            fixture.secondProject,
            registry: firstRegistry
        )
        #expect(
            session.activeProjectURL
                == fixture.secondProject.standardizedFileURL
        )
        session.windowDidClose(registry: firstRegistry)

        let registry = fixture.makeRegistry()
        registry.noteExplicitProjectOpenRequest(fixture.firstProject)
        let reopened = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )

        #expect(
            await reopened.restoreIfNeeded(registry: registry) == .restored
        )
        #expect(
            reopened.activeProjectURL
                == fixture.firstProject.standardizedFileURL
        )
        #expect(
            registry.projectManagerIfAdmitted(for: fixture.firstProject) != nil
        )
        // The window keeps its membership: only the active project changed.
        #expect(reopened.projectURLs == [
            fixture.firstProject.standardizedFileURL,
            fixture.secondProject.standardizedFileURL,
        ])
    }

    /// The other half of #1543: with no explicit request in flight the scene
    /// is genuine window restoration, and restoring the project the window
    /// was last showing stays correct.
    @Test("restoration with no explicit request still restores the active project")
    func restorationWithoutRequestKeepsPersistedActiveProject() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let firstRegistry = fixture.makeRegistry()
        _ = try #require(
            firstRegistry.projectManager(for: fixture.firstProject)
        )
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await session.openProject(
            fixture.secondProject,
            registry: firstRegistry
        )
        session.windowDidClose(registry: firstRegistry)

        let registry = fixture.makeRegistry()
        let restored = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        _ = await restored.restoreIfNeeded(registry: registry)

        #expect(
            restored.activeProjectURL
                == fixture.secondProject.standardizedFileURL
        )
    }

    /// An explicit request is spent by the scene it opened. A second scene for
    /// the same anchor — a real restoration — must not inherit it.
    @Test("an explicit open request is consumed by exactly one scene")
    func explicitOpenRequestIsConsumedOnce() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let firstRegistry = fixture.makeRegistry()
        _ = try #require(
            firstRegistry.projectManager(for: fixture.firstProject)
        )
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await session.openProject(
            fixture.secondProject,
            registry: firstRegistry
        )
        session.windowDidClose(registry: firstRegistry)

        let registry = fixture.makeRegistry()
        registry.noteExplicitProjectOpenRequest(fixture.firstProject)
        #expect(
            registry.consumeExplicitProjectOpenRequest(
                for: fixture.firstProject
            )
        )
        #expect(
            !registry.consumeExplicitProjectOpenRequest(
                for: fixture.firstProject
            )
        )

        let restored = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        _ = await restored.restoreIfNeeded(registry: registry)

        #expect(
            restored.activeProjectURL
                == fixture.secondProject.standardizedFileURL
        )
    }

    /// Routing (Agent Inbox, a notification) can reach a scene before its
    /// restore task runs. A request still pending from the open that created
    /// the scene must not pull the window back off what routing placed.
    @Test("routing that placed a window first is not undone by a pending request")
    func routingBeforeRestoreOutranksPendingRequest() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let firstRegistry = fixture.makeRegistry()
        _ = try #require(
            firstRegistry.projectManager(for: fixture.firstProject)
        )
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await session.openProject(
            fixture.secondProject,
            registry: firstRegistry
        )
        session.windowDidClose(registry: firstRegistry)

        let registry = fixture.makeRegistry()
        registry.noteExplicitProjectOpenRequest(fixture.firstProject)
        let reopened = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await reopened.activate(fixture.secondProject, registry: registry)
        #expect(
            reopened.activeProjectURL
                == fixture.secondProject.standardizedFileURL
        )

        _ = await reopened.restoreIfNeeded(registry: registry)

        #expect(
            reopened.activeProjectURL
                == fixture.secondProject.standardizedFileURL
        )
    }

    /// A project explicitly reopened after the user closed it out of its own
    /// anchor window rejoins that window instead of arriving as a scene with
    /// nothing to show.
    @Test("an explicit open readmits a project closed out of its anchor window")
    func explicitOpenReadmitsClosedAnchor() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let firstRegistry = fixture.makeRegistry()
        _ = try #require(
            firstRegistry.projectManager(for: fixture.firstProject)
        )
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await session.openProject(
            fixture.secondProject,
            registry: firstRegistry
        )
        #expect(
            await session.closeProject(
                fixture.firstProject,
                registry: firstRegistry
            )
        )
        session.windowDidClose(registry: firstRegistry)

        let registry = fixture.makeRegistry()
        registry.noteExplicitProjectOpenRequest(fixture.firstProject)
        let reopened = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )

        #expect(
            await reopened.restoreIfNeeded(registry: registry) == .restored
        )
        #expect(
            reopened.activeProjectURL
                == fixture.firstProject.standardizedFileURL
        )
        #expect(
            reopened.projectURLs.contains(
                fixture.firstProject.standardizedFileURL
            )
        )
    }

    @Test("switching keeps each project alive and restores the active project")
    func switchingAndRestoration() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let firstManager = try #require(
            registry.projectManager(for: fixture.firstProject)
        )
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )

        await session.openProject(
            fixture.secondProject,
            registry: registry
        )

        let secondManager = try #require(
            registry.projectManagerIfAdmitted(for: fixture.secondProject)
        )
        #expect(session.projectURLs == [
            fixture.firstProject.standardizedFileURL,
            fixture.secondProject.standardizedFileURL,
        ])
        #expect(
            session.activeProjectURL
                == fixture.secondProject.standardizedFileURL
        )
        #expect(firstManager.presentationLifecycle == .backgroundSuspended)
        #expect(secondManager.presentationLifecycle == .visible)

        registry.runBackgroundReclamationPassForTesting()
        #expect(
            registry.projectManagerIfAdmitted(for: fixture.firstProject)
                === firstManager
        )

        session.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.secondProject)

        let restored = ProjectWindowSession(
            initialProjectURL: fixture.secondProject,
            defaults: fixture.defaults
        )
        _ = await restored.restoreIfNeeded(registry: registry)

        #expect(
            restored.sceneProjectURL
                == fixture.firstProject.standardizedFileURL
        )
        #expect(restored.projectURLs == session.projectURLs)
        #expect(
            restored.activeProjectURL
                == fixture.secondProject.standardizedFileURL
        )
        #expect(registry.isWindowOpen(fixture.secondProject))
        #expect(!registry.isWindowOpen(fixture.firstProject))
    }

    @Test("closing the window releases inactive project leases")
    func closingReleasesLeases() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        _ = try #require(registry.projectManager(for: fixture.firstProject))
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )

        await session.openProject(
            fixture.secondProject,
            registry: registry
        )
        session.windowDidClose(registry: registry)
        registry.closeProjectWindow(fixture.secondProject)
        registry.runBackgroundReclamationPassForTesting()

        #expect(registry.openProjects.isEmpty)
    }

    @Test("a project already visible in another window is not adopted")
    func visibleProjectIsNotAdopted() async throws {
        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        _ = try #require(registry.projectManager(for: fixture.firstProject))
        _ = try #require(registry.projectManager(for: fixture.secondProject))
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )

        await session.openProject(
            fixture.secondProject,
            registry: registry
        )

        #expect(
            session.activeProjectURL
                == fixture.firstProject.standardizedFileURL
        )
        #expect(session.projectURLs.count == 1)
        #expect(session.alertMessage != nil)
    }

    @Test("managed worktree identity round-trips through session persistence")
    func managedWorktreeCodableRoundTrip() throws {
        let proof = RecentAgentTaskRepositoryProof(
            commonDirectoryDevice: 1,
            commonDirectoryInode: 2,
            commonDirectoryGeneration: 3,
            commonDirectoryBirthSeconds: 4,
            commonDirectoryBirthNanoseconds: 5
        )
        let worktree = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            managedRoot: URL(fileURLWithPath: "/tmp/managed"),
            worktreeRoot: URL(fileURLWithPath: "/tmp/managed/worktree"),
            branchName: "pine/agent/codex/12345678",
            baseCommit: String(repeating: "a", count: 40),
            repositoryProof: proof
        )

        let data = try JSONEncoder().encode(worktree)
        let decoded = try JSONDecoder().decode(
            AgentManagedWorktree.self,
            from: data
        )

        #expect(decoded == worktree)
    }

    @Test("corrupt duplicate entries and foreign active URLs fail closed")
    func corruptPersistenceFailsClosed() async throws {
        struct PersistedFixture: Codable {
            let version: Int
            let projectURLs: [URL]
            let worktrees: [AgentManagedWorktree]
            let activeURL: URL
        }

        let fixture = try ProjectWindowSessionFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        _ = try #require(registry.projectManager(for: fixture.firstProject))
        let worktree = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: fixture.firstProject,
            managedRoot: fixture.root,
            worktreeRoot: fixture.root.appendingPathComponent("worktree"),
            branchName: "pine/agent/codex/12345678",
            baseCommit: String(repeating: "a", count: 40),
            repositoryProof: RecentAgentTaskRepositoryProof(
                commonDirectoryDevice: 1,
                commonDirectoryInode: 2,
                commonDirectoryGeneration: 3,
                commonDirectoryBirthSeconds: 4,
                commonDirectoryBirthNanoseconds: 5
            )
        )
        let state = PersistedFixture(
            version: 1,
            projectURLs: [fixture.firstProject],
            worktrees: [worktree, worktree],
            activeURL: fixture.root.appendingPathComponent("foreign")
        )
        let digest = SHA256.hash(data: Data(
            fixture.firstProject.standardizedFileURL.path.utf8
        ))
        let suffix = digest.prefix(16).map {
            String(format: "%02x", $0)
        }.joined()
        fixture.defaults.set(
            try JSONEncoder().encode(state),
            forKey: "projectWindowSession.\(suffix)"
        )

        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        _ = await session.restoreIfNeeded(registry: registry)

        #expect(session.managedWorktrees.count == 1)
        #expect(
            session.activeProjectURL
                == fixture.firstProject.standardizedFileURL
        )
    }
}

@MainActor
private final class ProjectWindowSessionFixture {
    let root: URL
    let firstProject: URL
    let secondProject: URL
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Pine-ProjectWindowSession-\(UUID().uuidString)",
                isDirectory: true
            )
        firstProject = root.appendingPathComponent(
            "First Project",
            isDirectory: true
        )
        secondProject = root.appendingPathComponent(
            "Second Project",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstProject,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondProject,
            withIntermediateDirectories: true
        )
        suiteName = "ProjectWindowSessionTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeRegistry() -> ProjectRegistry {
        ProjectRegistry(
            defaults: defaults,
            agentDetectionProcessRunner:
                ProjectWindowSessionTests.noOpProcessRunner,
            agentDetectionPollInterval: 3_600,
            backgroundReclamationInterval: .seconds(3_600)
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
