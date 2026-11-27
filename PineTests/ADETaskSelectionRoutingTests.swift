//
//  ADETaskSelectionRoutingTests.swift
//  PineTests
//
//  Attention routing to one exact task through the project window first
//  (#1760). `ProjectRegistry.selectAgentTask` is the authority the app
//  delegate's notification and Dock paths now call before the legacy
//  Inbox navigation; selecting is view-only.
//

import AppKit
import Foundation
import Testing
@testable import Pine

@MainActor
private final class RecordingSelectionHost: AgentTaskSelectionHosting {
    let hostedProjectURL: URL
    private(set) var selected: [UUID] = []

    init(project: URL) {
        hostedProjectURL = project
    }

    func selectTask(_ taskID: UUID) {
        selected.append(taskID)
    }
}

@Suite("ADE task selection routing", .serialized)
@MainActor
struct ADETaskSelectionRoutingTests {
    private func makeFixture() throws -> SelectionRoutingFixture {
        try SelectionRoutingFixture()
    }

    private func projectWindowTask(
        seed: Int, project: URL, lifecycle: AgentTaskLifecycle = .active,
        worktreePath: String? = nil
    ) -> AgentTask {
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: AgentTaskBridgeContext(
                project: AgentTaskProjectIdentity(
                    canonicalProjectPath: project.path,
                    canonicalWorktreePath: worktreePath ?? project.path
                ),
                route: AgentTaskRoute(
                    paneID: UUID(), tabID: UUID(), terminalID: UUID()
                ),
                origin: .discoveredInTerminal,
                observedAt: Date(timeIntervalSince1970: TimeInterval(seed))
            ),
            title: "Routing \(seed)", objective: "Routing \(seed)",
            createdAt: Date(timeIntervalSince1970: TimeInterval(seed))
        )
        task.lifecycle = lifecycle
        return task
    }

    @Test("a task the open project window lists is selected there, view-only")
    func openWindowSelectsTheTask() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.registerWindowSession(session)
        await session.openProject(fixture.projectA, registry: registry)

        let task = projectWindowTask(seed: 10, project: fixture.projectA)
        registry.agentTasks.setTasksForTesting([task])

        let host = RecordingSelectionHost(project: fixture.projectA)
        registry.registerTaskSelectionHost(host)

        var opened: [URL] = []
        var activated = false
        let outcome = await registry.selectAgentTask(
            task.id,
            openProjectWindow: { opened.append($0) },
            activateApplication: { _ in activated = true }
        )

        #expect(outcome == .selected)
        #expect(host.selected == [task.id])
        #expect(opened.isEmpty, "the owning window was already up")
        #expect(activated, "an explicit user action brings the window forward")

        session.windowDidClose(registry: registry)
    }

    @Test("a project with no window gets one; the selection waits for the task list to mount")
    func closedWindowQueuesUntilTheHostMounts() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.registerWindowSession(session)

        let task = projectWindowTask(seed: 11, project: fixture.projectB)
        registry.agentTasks.setTasksForTesting([task])

        var opened: [URL] = []
        let outcome = await registry.selectAgentTask(
            task.id,
            openProjectWindow: { opened.append($0) },
            waitUntilPresented: { fixture.present($0) },
            activateApplication: { _ in }
        )

        #expect(outcome == .queued)
        #expect(opened.count == 1, "the owning project's window is opened")
        #expect(registry.isWindowOpen(registry.canonicalProjectURL(fixture.projectB)))

        // Mounting the window's task list spends the pending selection.
        let host = RecordingSelectionHost(project: fixture.projectB)
        registry.registerTaskSelectionHost(host)
        #expect(host.selected == [task.id])

        session.windowDidClose(registry: registry)
    }

    @Test("closing the project window drops its queued selection")
    func windowCloseDropsQueuedSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.registerWindowSession(session)
        await session.openProject(fixture.projectB, registry: registry)

        let task = projectWindowTask(seed: 14, project: fixture.projectB)
        registry.agentTasks.setTasksForTesting([task])

        var opened: [URL] = []
        // The window is up but its task list has not mounted: queued.
        let outcome = await registry.selectAgentTask(
            task.id,
            openProjectWindow: { opened.append($0) },
            activateApplication: { _ in }
        )
        #expect(outcome == .queued)
        #expect(opened.isEmpty, "the owning window was already up")

        // Closing the window drops the queue: the next surface that shows
        // this project is the user's navigation, not the old attention route.
        registry.closeProjectWindow(registry.canonicalProjectURL(fixture.projectB))
        let host = RecordingSelectionHost(project: fixture.projectB)
        registry.registerTaskSelectionHost(host)
        #expect(host.selected.isEmpty, "the stale queued selection was dropped on close")

        session.windowDidClose(registry: registry)
    }

    @Test("unknown and dismissed tasks are refused so the caller can fall back to the Inbox")
    func refusedTasksNeverOpenWindows() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.registerWindowSession(session)

        let dismissed = projectWindowTask(
            seed: 12, project: fixture.projectA, lifecycle: .dismissed
        )
        registry.agentTasks.setTasksForTesting([dismissed])

        var opened: [URL] = []
        let unknown = await registry.selectAgentTask(
            UUID(), openProjectWindow: { opened.append($0) }, activateApplication: { _ in }
        )
        let gone = await registry.selectAgentTask(
            dismissed.id, openProjectWindow: { opened.append($0) }, activateApplication: { _ in }
        )

        #expect(unknown == .refused)
        #expect(gone == .refused)
        #expect(opened.isEmpty, "a refused task never presents a window")

        session.windowDidClose(registry: registry)
    }

    @Test("a task outside project windows is unsupported, not routed")
    func quickTerminalTasksAreUnsupported() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.registerWindowSession(session)

        var task = projectWindowTask(seed: 13, project: fixture.projectA)
        task.route = AgentTaskRoute(
            surface: .quickTerminalStandalone, paneID: nil, tabID: nil, terminalID: UUID()
        )
        registry.agentTasks.setTasksForTesting([task])

        var opened: [URL] = []
        let outcome = await registry.selectAgentTask(
            task.id, openProjectWindow: { opened.append($0) }, activateApplication: { _ in }
        )

        #expect(outcome == .unsupportedSurface)
        #expect(opened.isEmpty)

        session.windowDidClose(registry: registry)
    }

    @Test("a worktree task falls back to the root project's window host")
    func worktreeTaskUsesRootWindowHost() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        registry.registerWindowSession(session)

        // The task runs in a managed worktree; the Inbox presentation guard
        // keys on the worktree path, so its root-window flow cannot admit it.
        let worktree = fixture.root
            .appendingPathComponent("managed/agent/wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let task = projectWindowTask(
            seed: 15, project: fixture.projectB, worktreePath: worktree.path
        )
        registry.agentTasks.setTasksForTesting([task])

        var opened: [URL] = []
        let outcome = await registry.selectAgentTask(
            task.id,
            openProjectWindow: { opened.append($0) },
            activateApplication: { _ in }
        )

        // The root project's window is opened and the selection queues there
        // instead of degrading to the legacy worktree-window route.
        #expect(outcome == .queued)
        #expect(opened == [registry.canonicalProjectURL(fixture.projectB)])

        // Mounting the root window's task list spends the queued selection.
        let host = RecordingSelectionHost(project: fixture.projectB)
        registry.registerTaskSelectionHost(host)
        #expect(host.selected == [task.id])

        session.windowDidClose(registry: registry)
    }

    // MARK: - The app-delegate funnel

    @Test("openProjectScene records the explicit open intent and reports failure without a route")
    func projectSceneFunnel() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let delegate = AppDelegate()
        delegate.registry = registry

        let url = fixture.projectA
        // No window-action host and no test seam: opening cannot pretend success.
        #expect(!delegate.openProjectScene(url))

        // The unit-test seam stands in for the app-lifetime host.
        var opened: [URL] = []
        delegate.openProjectWindow = { opened.append($0) }
        #expect(delegate.openProjectScene(url))
        #expect(opened == [url])
        #expect(
            registry.consumeExplicitProjectOpenRequest(for: url),
            "the intent was recorded before the scene opened (#1543)"
        )
    }
}

// MARK: - Fixture

@MainActor
private final class SelectionRoutingFixture {
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
                "ADESelectionRouting-\(UUID().uuidString)", isDirectory: true
            )
        projectA = root.appendingPathComponent("projectA", isDirectory: true)
        projectB = root.appendingPathComponent("projectB", isDirectory: true)
        for url in [projectA, projectB] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        suiteName = "ADETaskSelectionRoutingTests.\(UUID().uuidString)"
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
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
            },
            agentDetectionPollInterval: 3_600,
            agentDetectionInitialPollDelay: 3_600
        )
    }

    func makeSession(initial: URL) -> ProjectWindowSession {
        ProjectWindowSession(initialProjectURL: initial, defaults: defaults)
    }

    /// Stands in for the window a presented project acquires.
    func present(_ manager: ProjectManager) -> Bool {
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
        manager.bindDialogOwnerWindow(window)
        boundWindows.append((manager, window))
        return true
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
}
