//
//  AgentInboxWindowRoutingTests.swift
//  PineTests
//
//  Routing an Inbox task into the window that already holds its project.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Window session registry", .serialized)
@MainActor
struct WindowSessionRegistryTests {
    @Test("a window is found by any project it holds")
    func findsOwningWindow() throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)

        registry.registerWindowSession(session)

        #expect(registry.windowSession(owning: fixture.projectA) === session)
        #expect(registry.windowSession(owning: fixture.projectB) == nil)
    }

    @Test("registration is idempotent and reversible")
    func registrationLifecycle() throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)

        registry.registerWindowSession(session)
        registry.registerWindowSession(session)
        #expect(registry.windowSession(owning: fixture.projectA) === session)

        registry.unregisterWindowSession(session)
        #expect(registry.windowSession(owning: fixture.projectA) == nil)
        #expect(registry.keyWindowSession() == nil)
    }

    @Test("a released window stops answering for its projects")
    func releasedWindowDisappears() throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()

        do {
            let session = fixture.makeSession(initial: fixture.projectA)
            registry.noteKeyWindowSession(session)
            #expect(registry.keyWindowSession() === session)
        }

        // The registry holds windows weakly: a closed window that never
        // unregistered must not keep claiming projects, or routing would send
        // a task to a window nobody can see.
        #expect(registry.windowSession(owning: fixture.projectA) == nil)
        #expect(registry.keyWindowSession() == nil)
    }

    @Test("the key window is the one that most recently became key")
    func keyWindowTracksActivation() throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let first = fixture.makeSession(initial: fixture.projectA)
        let second = fixture.makeSession(initial: fixture.projectB)

        registry.registerWindowSession(first)
        registry.registerWindowSession(second)
        // Nothing has been key yet, so the newest window is the best guess.
        #expect(registry.keyWindowSession() === second)

        registry.noteKeyWindowSession(first)
        #expect(registry.keyWindowSession() === first)

        registry.unregisterWindowSession(first)
        #expect(registry.keyWindowSession() === second)
    }

    @Test("an agent worktree is found through the window that hosts it")
    func findsWorktreeOwner() throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        let worktreeRoot = fixture.root
            .appendingPathComponent("managed/agent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeRoot,
            withIntermediateDirectories: true
        )
        session.adoptWorktreeForTesting(fixture.makeWorktree(
            repositoryRoot: fixture.projectA,
            worktreeRoot: worktreeRoot
        ))
        registry.registerWindowSession(session)

        // An Inbox task points at the worktree it runs in, never at the
        // repository root, so membership has to cover both.
        #expect(registry.windowSession(owning: worktreeRoot) === session)
    }

    @Test("a path is matched through symlinks, not by spelling")
    func matchesCanonicalPaths() throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.registerWindowSession(session)

        let messy = fixture.root
            .appendingPathComponent("projectB", isDirectory: true)
            .appendingPathComponent("../projectA", isDirectory: true)

        #expect(registry.windowSession(owning: messy) === session)
    }
}

@Suite("Agent inbox window routing", .serialized)
@MainActor
struct AgentInboxWindowRoutingTests {
    @Test("a project sitting behind its neighbour reuses its own window")
    func backgroundProjectReusesItsWindow() async throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.registerWindowSession(session)

        // Window holds A and B, and ends up showing A — so B is suspended,
        // which is exactly the state that used to read as "this project has
        // no window" and opened a second one. The task is staged while B is
        // still active, because looking a project up reopens it.
        await session.openProject(fixture.projectB, registry: registry)
        let task = try fixture.stageAgentTask(
            in: fixture.projectB,
            registry: registry,
            seed: 70
        )
        await session.activate(fixture.projectA, registry: registry)
        let canonicalB = registry.canonicalProjectURL(fixture.projectB)
        #expect(registry.backgroundProjects.contains(canonicalB))

        var opened: [URL] = []
        let result = await registry.navigateToAgentTaskFromInbox(
            task.taskID,
            openProjectWindow: { opened.append($0) },
            waitUntilPresented: { fixture.present($0) },
            activateApplication: { _ in }
        )

        #expect(result == .focused(task.route))
        // The window was raised by its scene identity, and no window was
        // asked for the project itself.
        #expect(opened == [session.sceneProjectURL])
        #expect(session.activeProjectURL == canonicalB)
        #expect(!registry.backgroundProjects.contains(canonicalB))
    }

    @Test("a project no window holds lands in the key window")
    func unheldProjectJoinsKeyWindow() async throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.noteKeyWindowSession(session)

        let task = try fixture.stageAgentTask(
            in: fixture.projectB,
            registry: registry,
            seed: 71
        )
        let canonicalB = registry.canonicalProjectURL(fixture.projectB)
        registry.closeProjectWindow(canonicalB)
        #expect(session.contains(canonicalB) == false)

        var opened: [URL] = []
        let result = await registry.navigateToAgentTaskFromInbox(
            task.taskID,
            openProjectWindow: { opened.append($0) },
            waitUntilPresented: { fixture.present($0) },
            activateApplication: { _ in }
        )

        #expect(result == .focused(task.route))
        #expect(opened == [session.sceneProjectURL])
        #expect(session.contains(canonicalB))
        #expect(session.activeProjectURL == canonicalB)
    }

    @Test("with no window at all, the project still gets one")
    func noWindowsFallsBackToOpening() async throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()

        let task = try fixture.stageAgentTask(
            in: fixture.projectB,
            registry: registry,
            seed: 72
        )
        let canonicalB = registry.canonicalProjectURL(fixture.projectB)
        registry.closeProjectWindow(canonicalB)

        var opened: [URL] = []
        let result = await registry.navigateToAgentTaskFromInbox(
            task.taskID,
            openProjectWindow: { opened.append($0) },
            waitUntilPresented: { fixture.present($0) },
            activateApplication: { _ in }
        )

        #expect(
            result == .focused(task.route),
            "actual: \(String(describing: result)) route: \(task.route)"
        )
        // Nothing to route into, so this is the pre-existing behaviour: a
        // window for the project itself.
        #expect(opened == [canonicalB])
    }

    @Test("a released window does not capture the routing")
    func releasedWindowIsNotUsed() async throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        do {
            let session = fixture.makeSession(initial: fixture.projectA)
            registry.noteKeyWindowSession(session)
        }

        let task = try fixture.stageAgentTask(
            in: fixture.projectB,
            registry: registry,
            seed: 73
        )
        let canonicalB = registry.canonicalProjectURL(fixture.projectB)
        registry.closeProjectWindow(canonicalB)

        var opened: [URL] = []
        let result = await registry.navigateToAgentTaskFromInbox(
            task.taskID,
            openProjectWindow: { opened.append($0) },
            waitUntilPresented: { fixture.present($0) },
            activateApplication: { _ in }
        )

        #expect(result == .focused(task.route))
        #expect(opened == [canonicalB])
    }

    @Test("a task that dies during presentation is not focused")
    func staleTaskDuringPresentationIsRejected() async throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.registerWindowSession(session)
        await session.openProject(fixture.projectB, registry: registry)
        let task = try fixture.stageAgentTask(
            in: fixture.projectB,
            registry: registry,
            seed: 74
        )
        await session.activate(fixture.projectA, registry: registry)

        let result = await registry.navigateToAgentTaskFromInbox(
            task.taskID,
            openProjectWindow: { _ in },
            waitUntilPresented: { manager in
                // The run ends while the window is being presented. Routing
                // must not focus a terminal whose agent is already gone —
                // even though the window itself came up fine.
                task.session.applyLiveness(.terminated)
                return fixture.present(manager)
            },
            activateApplication: { _ in }
        )

        #expect(result == .routeStale)
    }
}

// MARK: - Fixture

@MainActor
private final class RoutingFixture {
    let root: URL
    let projectA: URL
    let projectB: URL
    private let suiteName: String
    private let defaults: UserDefaults
    private var windows: [NSWindow] = []
    private var boundWindows: [(ProjectManager, NSWindow)] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "PineInboxRouting-\(UUID().uuidString)",
                isDirectory: true
            )
        projectA = root.appendingPathComponent("projectA", isDirectory: true)
        projectB = root.appendingPathComponent("projectB", isDirectory: true)
        for url in [projectA, projectB] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        suiteName = "AgentInboxWindowRoutingTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeRegistry() -> ProjectRegistry {
        ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                accuracyPolicy: AgentLifecycleAccuracyPolicy { _ in
                    .verifiedLifecycleTransitions
                }
            ),
            // No `ps` polling: these tests are about routing, and the real
            // detector would fork on every pass for nothing.
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            },
            agentDetectionPollInterval: 3_600,
            agentDetectionInitialPollDelay: 3_600
        )
    }

    func makeSession(initial: URL) -> ProjectWindowSession {
        ProjectWindowSession(
            initialProjectURL: initial,
            defaults: defaults
        )
    }

    func makeWorktree(
        repositoryRoot: URL,
        worktreeRoot: URL
    ) -> AgentManagedWorktree {
        AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repositoryRoot.standardizedFileURL,
            managedRoot: worktreeRoot.deletingLastPathComponent(),
            worktreeRoot: worktreeRoot.standardizedFileURL,
            branchName: "pine/agent/codex/routing",
            baseCommit: String(repeating: "a", count: 40),
            repositoryProof: RecentAgentTaskRepositoryProof(
                commonDirectoryDevice: 1,
                commonDirectoryInode: 2,
                commonDirectoryGeneration: 3,
                commonDirectoryBirthSeconds: 4,
                commonDirectoryBirthNanoseconds: 5
            )
        )
    }

    /// Puts a live, unread agent task in `project` and binds an eligible
    /// window to its manager, which is what the presentation path requires
    /// before it will hand back a route.
    func stageAgentTask(
        in project: URL,
        registry: ProjectRegistry,
        seed: Int
    ) throws -> StagedTask {
        let manager = try #require(registry.projectManager(for: project))
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: project
        )
        let state = try #require(manager.paneManager.terminalState(for: pane))
        let tab = try #require(state.terminalTabs.first)
        let session = AgentSession(
            agentType: .codex,
            state: .waitingInput,
            lifecycleAccuracy: .verifiedLifecycleTransitions,
            startedAt: Date(timeIntervalSince1970: TimeInterval(seed))
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: Int32(1_000 + seed),
            processGeneration: UInt64(seed),
            startIdentifier: "routing-session-\(seed)",
            observedStartedAt: Date(timeIntervalSince1970: TimeInterval(seed)),
            startIsAuthoritative: true
        ))
        manager.terminal.bridgeAgentSession(session, replacing: nil, in: tab)
        tab.agentSession = session
        let taskID = try #require(
            registry.agentTasks.taskID(forSessionID: session.id)
        )
        return StagedTask(
            taskID: taskID,
            session: session,
            route: AgentTaskRoute(
                paneID: pane.id,
                tabID: tab.id,
                terminalID: tab.id
            )
        )
    }

    /// Stands in for the window a presented project acquires. Binding has to
    /// happen here rather than up front: suspending a project drops its dialog
    /// owner, so a window bound before the project went to the background is
    /// gone by the time presentation is checked.
    func present(_ manager: ProjectManager) -> Bool {
        let window = makeEligibleWindow()
        manager.bindDialogOwnerWindow(window)
        boundWindows.append((manager, window))
        return true
    }

    private func makeEligibleWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(
            frame: window.contentRect(forFrameRect: window.frame)
        )
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        return window
    }

    func cleanup() {
        for (manager, window) in boundWindows {
            manager.unbindDialogOwnerWindow(window)
        }
        boundWindows.removeAll()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    struct StagedTask {
        let taskID: UUID
        let session: AgentSession
        let route: AgentTaskRoute
    }
}
