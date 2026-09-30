//
//  AgentNotificationPresentationTests.swift
//  PineTests
//
//  Direct coverage for the route-based notification presentation predicates
//  (issue #1640): `ProjectRegistry.isAgentTaskPresented` and
//  `QuickTerminalController.isQuickTerminalAgentTaskPresented` must keep
//  suppressing the banner for the terminal the user is watching after the
//  agent process in it has exited.
//
//  A background test runner cannot make a real `NSWindow` key (macOS denies
//  key-window status without app-level foreground activation — see
//  FoldObserverReentrancyTests), so the project-window tests bind an
//  `NSWindow` subclass that supplies key/visible/occlusion state directly,
//  and the Quick Terminal decision is verified through its extracted pure
//  seam plus a real-controller negative path.
//

import AppKit
import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Agent Notification Presentation Tests", .serialized)
struct AgentNotificationPresentationTests {
    @Test("terminated task whose terminal route is focused is presented")
    func terminatedRouteFocusedIsPresented() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanup() }
        let harness = try makeHarness(fixture: fixture, seed: 1)

        // No window bound yet: nothing to call presented.
        #expect(!harness.registry.isAgentTaskPresented(harness.taskID))

        let window = PresentationWindowDouble()
        window.visibleState = true
        window.keyState = true
        harness.manager.bindDialogOwnerWindow(window)
        defer { harness.manager.unbindDialogOwnerWindow(window) }
        // The exact #1640-A regression: the run is terminated and the task
        // paused, yet the user is watching its terminal, so the
        // `.processEnded` banner must stay suppressed.
        #expect(harness.registry.isAgentTaskPresented(harness.taskID))

        // The same route stops being presented the moment the hosting
        // window loses any of key, visible, or unoccluded state.
        window.keyState = false
        #expect(!harness.registry.isAgentTaskPresented(harness.taskID))
        window.keyState = true
        window.occludedState = true
        #expect(!harness.registry.isAgentTaskPresented(harness.taskID))
        window.occludedState = false
        #expect(harness.registry.isAgentTaskPresented(harness.taskID))
        window.visibleState = false
        #expect(!harness.registry.isAgentTaskPresented(harness.taskID))
    }

    @Test("terminated task whose tab closed is not presented")
    func terminatedRouteTabClosedIsNotPresented() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanup() }
        let harness = try makeHarness(fixture: fixture, seed: 2)
        let window = PresentationWindowDouble()
        window.visibleState = true
        window.keyState = true
        harness.manager.bindDialogOwnerWindow(window)
        defer { harness.manager.unbindDialogOwnerWindow(window) }
        #expect(harness.registry.isAgentTaskPresented(harness.taskID))

        harness.manager.paneManager.terminalState(for: harness.pane)?
            .removeTab(id: harness.tab.id)
        #expect(!harness.registry.isAgentTaskPresented(harness.taskID))
    }

    @Test("terminated task in a backgrounded project is not presented")
    func terminatedRouteBackgroundedProjectIsNotPresented() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanup() }
        let harness = try makeHarness(fixture: fixture, seed: 3)
        let window = PresentationWindowDouble()
        window.visibleState = true
        window.keyState = true
        harness.manager.bindDialogOwnerWindow(window)
        #expect(harness.registry.isAgentTaskPresented(harness.taskID))

        harness.manager.unbindDialogOwnerWindow(window)
        harness.registry.closeProjectWindow(fixture.project)
        #expect(harness.registry.backgroundProjects.contains(
            harness.registry.canonicalProjectURL(fixture.project)
        ))
        #expect(!harness.registry.isAgentTaskPresented(harness.taskID))
    }

    @Test("terminated task in another pane is not presented")
    func terminatedRouteOtherPaneIsNotPresented() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanup() }
        let harness = try makeHarness(fixture: fixture, seed: 4)
        let window = PresentationWindowDouble()
        window.visibleState = true
        window.keyState = true
        harness.manager.bindDialogOwnerWindow(window)
        defer { harness.manager.unbindDialogOwnerWindow(window) }
        #expect(harness.registry.isAgentTaskPresented(harness.taskID))

        // Focusing a different pane must not suppress a notification for
        // the task's own pane.
        _ = harness.manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        #expect(!harness.registry.isAgentTaskPresented(harness.taskID))
    }

    @Test("quick terminal route presentation follows panel state and active tab")
    func quickTerminalRoutePresentation() {
        let tabID = UUID()
        let route = AgentTaskRoute(
            surface: .quickTerminalStandalone,
            paneID: UUID(),
            tabID: tabID,
            terminalID: tabID
        )
        #expect(QuickTerminalController.isQuickTerminalRoutePresented(
            route,
            panelIsVisible: true,
            panelIsKey: true,
            activeTerminalID: tabID
        ))
        #expect(!QuickTerminalController.isQuickTerminalRoutePresented(
            route,
            panelIsVisible: true,
            panelIsKey: false,
            activeTerminalID: tabID
        ))
        #expect(!QuickTerminalController.isQuickTerminalRoutePresented(
            route,
            panelIsVisible: false,
            panelIsKey: true,
            activeTerminalID: tabID
        ))
        // A route pointing at another terminal is not the watched one.
        #expect(!QuickTerminalController.isQuickTerminalRoutePresented(
            route,
            panelIsVisible: true,
            panelIsKey: true,
            activeTerminalID: UUID()
        ))
        #expect(!QuickTerminalController.isQuickTerminalRoutePresented(
            route,
            panelIsVisible: true,
            panelIsKey: true,
            activeTerminalID: nil
        ))
        // A project-window route is never a quick-terminal presentation.
        #expect(!QuickTerminalController.isQuickTerminalRoutePresented(
            AgentTaskRoute(paneID: UUID(), tabID: tabID, terminalID: tabID),
            panelIsVisible: true,
            panelIsKey: true,
            activeTerminalID: tabID
        ))
    }

    @Test("quick terminal instance is not presented before the panel is shown")
    func quickTerminalInstanceNotShownIsNotPresented() throws {
        let settingsDomain = "AgentNotificationPresentation.\(UUID().uuidString)"
        let settingsDefaults = try #require(UserDefaults(suiteName: settingsDomain))
        settingsDefaults.removePersistentDomain(forName: settingsDomain)
        defer { settingsDefaults.removePersistentDomain(forName: settingsDomain) }
        let settings = QuickTerminalSettings(
            defaults: settingsDefaults,
            notificationCenter: NotificationCenter()
        )
        settings.enabled = true
        settings.hideOnFocusLoss = false
        let controller = QuickTerminalController(settings: settings)
        defer { controller.shutdown() }

        controller.show()
        let tab = try #require(controller.paneState.activeTab)
        let presented = quickTerminalTask(tabID: tab.id)
        // The panel is visible in the test host but cannot become key
        // without foreground activation, so the instance predicate holds.
        #expect(!controller.isQuickTerminalAgentTaskPresented(presented))

        controller.hide()
        #expect(!controller.isQuickTerminalAgentTaskPresented(presented))
    }

    // MARK: - Fixtures

    private struct ProjectHarness {
        let registry: ProjectRegistry
        let tasks: AgentTaskRegistry
        let manager: ProjectManager
        let pane: PaneID
        let tab: TerminalTab
        let taskID: UUID
    }

    /// Bridges a live agent session into a real pane/tab and then terminates
    /// it, leaving a paused task whose route points at the still-open
    /// terminal — the exact state a `.processEnded` event is resolved from.
    private func makeHarness(
        fixture: ProjectFixture,
        seed: Int
    ) throws -> ProjectHarness {
        let tasks = AgentTaskRegistry()
        let registry = ProjectRegistry(agentTasks: tasks)
        let manager = try #require(registry.projectManager(for: fixture.project))
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let tab = try #require(
            manager.paneManager.terminalState(for: pane)?.activeTab
        )
        let session = makeSession(seed: seed)
        manager.terminal.bridgeAgentSession(session, replacing: nil, in: tab)
        let taskID = try #require(tasks.taskID(forSessionID: session.id))
        session.applyLiveness(.terminated)
        tasks.refresh(sessions: [session])
        let task = try #require(tasks.task(for: taskID))
        #expect(task.lifecycle == .paused)
        #expect(task.runs.last?.liveness == .terminated)
        #expect(task.route.paneID == pane.id)
        #expect(task.route.tabID == tab.id)
        return ProjectHarness(
            registry: registry,
            tasks: tasks,
            manager: manager,
            pane: pane,
            tab: tab,
            taskID: taskID
        )
    }

    private func makeSession(seed: Int) -> AgentSession {
        let session = AgentSession(
            agentType: .codex,
            state: .executing,
            startedAt: Date(timeIntervalSince1970: TimeInterval(seed))
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: Int32(seed),
            processGeneration: UInt64(seed),
            startIdentifier: "verified-session-\(seed)",
            observedStartedAt: session.startedAt,
            startIsAuthoritative: true
        ))
        return session
    }

    private func quickTerminalTask(tabID: UUID) -> AgentTask {
        AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: AgentTaskBridgeContext(
                project: AgentTaskProjectIdentity(
                    canonicalProjectPath: "/tmp/quick-presented",
                    canonicalWorktreePath: "/tmp/quick-presented"
                ),
                route: AgentTaskRoute(
                    surface: .quickTerminalStandalone,
                    paneID: UUID(),
                    tabID: tabID,
                    terminalID: tabID
                ),
                origin: .discoveredInTerminal,
                observedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }
}

/// Supplies window presentation state directly: a background test runner
/// cannot make a real window key, so the predicate under test reads these
/// overrides instead of window-server state.
private final class PresentationWindowDouble: NSWindow {
    var keyState = false
    var visibleState = false
    var occludedState = false

    override var isKeyWindow: Bool { keyState }
    override var isVisible: Bool { visibleState }
    override var occlusionState: NSWindow.OcclusionState {
        occludedState ? [] : [.visible]
    }
}

private final class ProjectFixture {
    let root: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "PineNotificationPresentation-\(UUID().uuidString)",
                isDirectory: true
            )
        project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
