//
//  AgentDockMenuRoutingTests.swift
//  PineTests
//
//  Exact per-task Dock routing for live agent runs (#1492).
//

import AppKit
import Foundation
import Testing
@testable import Pine

@Suite("Agent Dock Menu Routing Tests")
@MainActor
struct AgentDockMenuRoutingTests {
    // MARK: - Identity capture

    @Test("every live Dock entry captures its own task, run, and generation")
    func itemsCaptureExactIdentityPerLiveTask() throws {
        let older = makeTask(seed: 1, title: "Older")
        let newer = makeTask(seed: 2, title: "Newer")
        let terminated = makeTask(
            seed: 3,
            liveness: .terminated,
            lifecycle: .paused,
            title: "Ended"
        )
        let items = AgentDockMenuRouting.items(
            for: [older, newer, terminated]
        )

        // Newest-first, one entry per live task, and no entry for history.
        #expect(items.count == 2)
        #expect(items.map(\.identity.taskID) == [newer.id, older.id])
        #expect(!items.contains { $0.identity.taskID == terminated.id })

        // Distinct tasks never share a route identity — the whole point of
        // #1492 is that two Dock rows stop performing the same action.
        #expect(Set(items.map(\.identity.runID)).count == 2)
        #expect(items[0].identity.runID == newer.runs[0].id)
        #expect(items[0].identity.processGeneration == 2)
        #expect(items[1].identity.runID == older.runs[0].id)
        #expect(items[1].identity.processGeneration == 1)
        #expect(items[0].title.contains("Newer"))
        #expect(items[1].title.contains("Older"))
    }

    @Test("route identity fails closed for anything that is not a live run")
    func routeIdentityRejectsEverythingButALiveRun() {
        var noRuns = makeTask(seed: 10)
        noRuns.runs = []
        #expect(AgentDockMenuRouting.routeIdentity(for: noRuns) == nil)

        for liveness in [AgentRunLiveness.stale, .terminated] {
            let task = makeTask(seed: 11, liveness: liveness)
            #expect(AgentDockMenuRouting.routeIdentity(for: task) == nil)
        }

        for lifecycle in [
            AgentTaskLifecycle.paused, .completed, .dismissed,
        ] {
            let task = makeTask(seed: 12, lifecycle: lifecycle)
            #expect(AgentDockMenuRouting.routeIdentity(for: task) == nil)
        }

        // A run that already recorded an end time is not routable even if its
        // liveness field still says `.live`. `liveTasks` admits it; the Dock
        // must not, so the extra fence is asserted through `items` too.
        var endedButLive = makeTask(seed: 13)
        endedButLive.runs[0].endedAt = Date(timeIntervalSince1970: 5_000)
        #expect(AgentDockMenuRouting.routeIdentity(for: endedButLive) == nil)
        #expect(AgentPresenceController.liveTasks(for: [endedButLive]).count == 1)
        #expect(AgentDockMenuRouting.items(for: [endedButLive]).isEmpty)

        // The last run is authority: an old live run behind a terminated one
        // must not resurrect a route.
        var replaced = makeTask(seed: 14)
        let staleRun = replaced.runs[0]
        var successor = makeTask(seed: 15, liveness: .terminated).runs[0]
        successor.endedAt = Date(timeIntervalSince1970: 6_000)
        replaced.runs = [staleRun, successor]
        #expect(AgentDockMenuRouting.routeIdentity(for: replaced) == nil)
    }

    @Test("Dock entries stay capped and ordered like the Inbox working list")
    func itemsAreCappedAndOrderedLikeTheInbox() {
        let fleet = (1...25).map { makeTask(seed: $0) }
        let items = AgentDockMenuRouting.items(for: fleet)

        #expect(items.count == AgentDockMenuRouting.itemLimit)
        #expect(
            items.map(\.identity.taskID)
                == AgentPresenceController.liveTasks(for: fleet).map(\.id)
        )
        // Every capped entry is still individually addressable.
        #expect(Set(items.map(\.identity.runID)).count == items.count)
    }

    // MARK: - Represented value decoding

    @Test("only a full route identity is accepted as a represented value")
    func representedValueDecodingFailsClosed() {
        let task = makeTask(seed: 20)
        let identity = AgentDockMenuRouting.routeIdentity(for: task)

        let rejected: [Any?] = [
            nil,
            // The pre-#1492 represented value: a bare task UUID cannot reject
            // PID or process-generation reuse, so it must not route.
            task.id,
            task.id.uuidString,
            "/tmp/dock-demo",
            URL(fileURLWithPath: "/tmp/dock-demo"),
            NSNull(),
            NSNumber(value: 7),
            task,
        ]
        for value in rejected {
            #expect(
                AgentDockMenuRouting.routeIdentity(
                    fromRepresentedObject: value
                ) == nil
            )
        }

        // A real identity survives AppKit's `Any?` box round trip.
        let item = NSMenuItem()
        item.representedObject = identity
        #expect(
            AgentDockMenuRouting.routeIdentity(
                fromRepresentedObject: item.representedObject
            ) == identity
        )
    }

    // MARK: - Privacy

    @Test("Dock titles and represented values expose no private detail")
    func dockEntriesExposeNoPrivateDetail() throws {
        let secretRoot = "/Users/tester/Private Work"
        var task = makeTask(
            seed: 21,
            title: "Ship the release",
            project: "\(secretRoot)/dock-demo"
        )
        task.runs[0].vendorIdentity = AgentVendorSessionIdentity(
            provider: "acme",
            opaqueIdentifier: "vendor-opaque-secret",
            executableVersion: "9.9.9"
        )
        let item = try #require(AgentDockMenuRouting.items(for: [task]).first)

        // The project is identified by display name only.
        #expect(item.title.contains("dock-demo"))
        #expect(!item.title.contains(secretRoot))
        #expect(!item.title.contains("/"))
        #expect(!item.title.contains("vendor-opaque-secret"))
        #expect(!item.title.contains("acme"))

        // The represented value carries three Pine-owned identifiers and
        // nothing else — no path, no vendor identity, no PID.
        let described = String(describing: item.identity)
        #expect(described.contains(task.id.uuidString))
        #expect(!described.contains(secretRoot))
        #expect(!described.contains("vendor-opaque-secret"))
        #expect(!described.contains("acme"))
        #expect(item.identity.processGeneration == 21)
        #expect(!described.contains("processIdentifier"))
    }

    // MARK: - Revalidation against the live registry

    @Test("a captured identity rejects PID and process-generation reuse")
    func capturedIdentityRejectsProcessReuse() throws {
        let registry = AgentTaskRegistry()
        let task = makeTask(seed: 30)
        registry.setTasksForTesting([task])
        let identity = try #require(AgentDockMenuRouting.routeIdentity(for: task))
        #expect(registry.matchesNotificationRoute(identity))

        // Same task, same PID, new process generation: the shell was replaced.
        var reused = task
        reused.runs = [makeRun(
            seed: 30,
            processIdentifier: 30,
            processGeneration: 31,
            runIDSeed: 131
        )]
        registry.setTasksForTesting([reused])
        #expect(!registry.matchesNotificationRoute(identity))

        let refreshed = try #require(
            AgentDockMenuRouting.routeIdentity(for: reused)
        )
        #expect(refreshed.taskID == identity.taskID)
        #expect(refreshed.runID != identity.runID)
        #expect(registry.matchesNotificationRoute(refreshed))

        // Same run identifier, different generation — PID reuse inside one
        // run must not extend the old route either.
        var sameRunNewGeneration = task
        sameRunNewGeneration.runs = [makeRun(
            seed: 30,
            processIdentifier: 30,
            processGeneration: 99,
            runIDSeed: 130
        )]
        registry.setTasksForTesting([sameRunNewGeneration])
        #expect(sameRunNewGeneration.runs[0].id == task.runs[0].id)
        #expect(!registry.matchesNotificationRoute(identity))

        // The task disappearing entirely is also a rejection, not a crash.
        registry.setTasksForTesting([])
        #expect(!registry.matchesNotificationRoute(identity))
        #expect(!registry.matchesNotificationRoute(refreshed))
        #expect(!AgentDockMenuRouting.matchesCurrentRoute(identity, task: nil))
    }

    @Test("the current-route fence rejects what the run/generation check admits")
    func currentRouteFenceIsStricterThanTheRunComparison() throws {
        let registry = AgentTaskRegistry()
        let task = makeTask(seed: 35)
        registry.setTasksForTesting([task])
        let identity = try #require(AgentDockMenuRouting.routeIdentity(for: task))
        #expect(AgentDockMenuRouting.matchesCurrentRoute(identity, task: task))

        // Same run, same generation — `matchesNotificationRoute` still says
        // yes for each of these, but none of them may focus a terminal.
        var ended = task
        ended.runs[0].liveness = .terminated
        ended.runs[0].endedAt = Date(timeIntervalSince1970: 9_000)
        ended.lifecycle = .paused

        var stale = task
        stale.runs[0].liveness = .stale

        var dismissed = task
        dismissed.lifecycle = .dismissed

        for variant in [ended, stale, dismissed] {
            registry.setTasksForTesting([variant])
            #expect(registry.matchesNotificationRoute(identity))
            #expect(!AgentDockMenuRouting.matchesCurrentRoute(
                identity,
                task: variant
            ))
        }

        // An identity whose taskID does not belong to the inspected task is
        // never accepted, even when run and generation coincide.
        let sibling = makeTask(seed: 35)
        #expect(sibling.id != task.id)
        #expect(sibling.runs[0].id == task.runs[0].id)
        #expect(!AgentDockMenuRouting.matchesCurrentRoute(
            identity,
            task: sibling
        ))
    }

    // MARK: - Dock action

    @Test("each Dock entry routes to its own exact identity")
    func dockActionRoutesEachEntryExactly() throws {
        let delegate = makeDelegate()
        let first = makeTask(seed: 40, title: "First")
        let second = makeTask(seed: 41, title: "Second")
        delegate.registry.agentTasks.setTasksForTesting([first, second])
        let items = AgentDockMenuRouting.items(
            for: delegate.registry.agentTasks.tasks
        )
        #expect(items.count == 2)

        var inboxCount = 0
        var routed: [AgentNotificationRouteIdentity] = []
        for item in items {
            let route = delegate.routeDockMenuAgentTask(
                representedObject: item.identity,
                presentInbox: { inboxCount += 1 },
                routeExactTask: { routed.append($0) }
            )
            #expect(route == .task(item.identity))
        }

        #expect(inboxCount == 0)
        #expect(routed == items.map(\.identity))
        #expect(Set(routed.map(\.taskID)) == Set([first.id, second.id]))
    }

    @Test("stale, replaced, and unreadable Dock entries fall back to the Inbox")
    func dockActionFailsClosed() throws {
        let delegate = makeDelegate()
        let task = makeTask(seed: 50)
        delegate.registry.agentTasks.setTasksForTesting([task])
        let identity = try #require(AgentDockMenuRouting.routeIdentity(for: task))

        var inboxCount = 0
        var routed: [AgentNotificationRouteIdentity] = []
        func route(_ value: Any?) -> AgentDockMenuRoute {
            delegate.routeDockMenuAgentTask(
                representedObject: value,
                presentInbox: { inboxCount += 1 },
                routeExactTask: { routed.append($0) }
            )
        }

        // Unreadable payloads never reach navigation.
        #expect(route(nil) == .inbox)
        #expect(route(task.id) == .inbox)
        #expect(route("agent") == .inbox)
        #expect(inboxCount == 3)
        #expect(routed.isEmpty)

        // The entry is valid while the run is the current one.
        #expect(route(identity) == .task(identity))
        #expect(routed == [identity])

        // The run ends between rendering the menu and the click.
        var ended = task
        ended.runs[0].liveness = .terminated
        ended.runs[0].endedAt = Date(timeIntervalSince1970: 5_000)
        ended.lifecycle = .paused
        delegate.registry.agentTasks.setTasksForTesting([ended])
        #expect(route(identity) == .inbox)

        // A replacement run in the same task is a different session.
        var replaced = task
        replaced.runs = [makeRun(
            seed: 51,
            processIdentifier: 50,
            processGeneration: 51,
            runIDSeed: 151
        )]
        delegate.registry.agentTasks.setTasksForTesting([replaced])
        #expect(route(identity) == .inbox)

        // And the task disappearing from the registry.
        delegate.registry.agentTasks.setTasksForTesting([])
        #expect(route(identity) == .inbox)
        #expect(routed == [identity])
        #expect(inboxCount == 6)
    }

    @Test("the Dock menu binds one exact entry per live task")
    func applicationDockMenuBindsExactEntries() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let delegate = makeDelegate()
        let first = makeTask(seed: 60, title: "First")
        let second = makeTask(seed: 61, title: "Second")
        let history = makeTask(seed: 62, liveness: .terminated, lifecycle: .paused)
        delegate.registry.agentTasks.setTasksForTesting([first, second, history])
        _ = delegate.registry.projectManager(for: directory)

        let menu = try #require(delegate.applicationDockMenu(NSApplication.shared))
        #expect(menu.items.count == 4)
        #expect(menu.items[2].isSeparatorItem)

        let identities = try (0..<2).map { index -> AgentNotificationRouteIdentity in
            let item = menu.items[index]
            #expect(item.target === delegate)
            #expect(item.action == #selector(AppDelegate.dockMenuOpenAgentTask(_:)))
            return try #require(
                AgentDockMenuRouting.routeIdentity(
                    fromRepresentedObject: item.representedObject
                )
            )
        }
        #expect(identities.map(\.taskID) == [second.id, first.id])
        #expect(Set(identities.map(\.runID)).count == 2)
        #expect(!identities.contains { $0.taskID == history.id })

        // The recent-project entry keeps its own URL contract.
        #expect(
            menu.items[3].representedObject as? URL
                == directory.resolvingSymlinksInPath()
        )
    }

    @Test("an empty live fleet leaves the Dock menu without a stray separator")
    func dockMenuOmitsSeparatorWithoutLiveTasks() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let delegate = makeDelegate()
        delegate.registry.agentTasks.setTasksForTesting([
            makeTask(seed: 63, liveness: .terminated, lifecycle: .paused),
        ])
        _ = delegate.registry.projectManager(for: directory)

        let menu = try #require(delegate.applicationDockMenu(NSApplication.shared))
        #expect(menu.items.count == 1)
        #expect(!menu.items.contains { $0.isSeparatorItem })
    }

    // MARK: - Exact navigation through the shared authority

    @Test("each Dock identity focuses only its own pane and terminal tab")
    func dockIdentityFocusesItsOwnTerminal() async throws {
        let fixture = try DockProjectFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry()
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        let firstPane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let secondPane = try #require(manager.paneManager.createTerminalPane(
            relativeTo: firstPane,
            axis: .horizontal,
            workingDirectory: fixture.project
        ))
        let firstState = try #require(
            manager.paneManager.terminalState(for: firstPane)
        )
        let secondState = try #require(
            manager.paneManager.terminalState(for: secondPane)
        )
        let firstTab = try #require(firstState.terminalTabs.first)
        let secondTab = try #require(secondState.terminalTabs.first)

        let firstSession = makeSession(seed: 70)
        manager.terminal.bridgeAgentSession(firstSession, replacing: nil, in: firstTab)
        firstTab.agentSession = firstSession
        let secondSession = makeSession(seed: 71)
        manager.terminal.bridgeAgentSession(secondSession, replacing: nil, in: secondTab)
        secondTab.agentSession = secondSession

        let identities = AgentDockMenuRouting.items(for: taskRegistry.tasks)
            .map(\.identity)
        #expect(identities.count == 2)
        let firstIdentity = try #require(
            identities.first { $0.runID == firstSession.id }
        )
        let secondIdentity = try #require(
            identities.first { $0.runID == secondSession.id }
        )
        #expect(firstIdentity.processGeneration == 70)
        #expect(secondIdentity.processGeneration == 71)
        #expect(firstIdentity.taskID != secondIdentity.taskID)

        let window = makeEligibleProjectWindow()
        manager.bindDialogOwnerWindow(window)
        defer {
            manager.unbindDialogOwnerWindow(window)
            window.orderOut(nil)
        }

        manager.terminal.lastActiveTerminalPaneID = secondPane
        #expect(taskRegistry.setReviewed(false, taskID: firstIdentity.taskID))
        #expect(taskRegistry.setReviewed(false, taskID: secondIdentity.taskID))
        #expect(await navigate(projectRegistry, firstIdentity) == .focused(
            AgentTaskRoute(
                paneID: firstPane.id,
                tabID: firstTab.id,
                terminalID: firstTab.id
            )
        ))
        #expect(firstState.activeTerminalID == firstTab.id)
        #expect(manager.terminal.lastActiveTerminalPaneID == firstPane)
        #expect(taskRegistry.task(for: firstIdentity.taskID)?.isUnread == false)
        // The sibling task is untouched — the two Dock rows are not the same
        // action any more.
        #expect(taskRegistry.task(for: secondIdentity.taskID)?.isUnread == true)

        #expect(await navigate(projectRegistry, secondIdentity) == .focused(
            AgentTaskRoute(
                paneID: secondPane.id,
                tabID: secondTab.id,
                terminalID: secondTab.id
            )
        ))
        #expect(secondState.activeTerminalID == secondTab.id)
        #expect(manager.terminal.lastActiveTerminalPaneID == secondPane)

        // Crossing the identities — one task's id with the other's run — is
        // rejected before any window is touched.
        let crossed = AgentNotificationRouteIdentity(
            taskID: firstIdentity.taskID,
            runID: secondIdentity.runID,
            processGeneration: secondIdentity.processGeneration
        )
        #expect(!taskRegistry.matchesNotificationRoute(crossed))
        #expect(await navigate(projectRegistry, crossed) == .routeStale)
    }

    @Test("a replaced process makes the captured Dock identity stale")
    func dockIdentityRejectsProcessReplacement() async throws {
        let fixture = try DockProjectFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry()
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(manager.paneManager.terminalState(for: pane))
        let tab = try #require(state.terminalTabs.first)
        let session = makeSession(seed: 80)
        manager.terminal.bridgeAgentSession(session, replacing: nil, in: tab)
        tab.agentSession = session

        let identity = try #require(
            AgentDockMenuRouting.items(for: taskRegistry.tasks).first?.identity
        )
        let window = makeEligibleProjectWindow()
        manager.bindDialogOwnerWindow(window)
        defer {
            manager.unbindDialogOwnerWindow(window)
            window.orderOut(nil)
        }

        // The Dock menu was rendered, then the shell was replaced.
        session.applyLiveness(.terminated)
        let replacement = makeSession(seed: 81)
        manager.terminal.bridgeAgentSession(
            replacement,
            replacing: session,
            in: tab
        )
        tab.agentSession = replacement

        // The run identifier and generation alone still compare equal, so the
        // Dock's own current-route fence is what rejects the stale entry.
        #expect(!AgentDockMenuRouting.matchesCurrentRoute(
            identity,
            task: taskRegistry.task(for: identity.taskID)
        ))
        let unreadBefore = taskRegistry.task(for: identity.taskID)?.isUnread
        #expect(await navigate(projectRegistry, identity) == .routeStale)
        // A rejected route never silently marks the task reviewed.
        #expect(taskRegistry.task(for: identity.taskID)?.isUnread == unreadBefore)

        // A freshly rendered Dock menu routes the replacement exactly.
        let refreshed = try #require(
            AgentDockMenuRouting.items(for: taskRegistry.tasks).first?.identity
        )
        #expect(refreshed.runID == replacement.id)
        #expect(await navigate(projectRegistry, refreshed) == .focused(
            AgentTaskRoute(paneID: pane.id, tabID: tab.id, terminalID: tab.id)
        ))
    }

    @Test("a Dock identity reopens only its own backgrounded project window")
    func dockIdentityReopensOwningProject() async throws {
        let fixture = try DockProjectFixture()
        let other = try DockProjectFixture()
        defer {
            fixture.cleanup()
            other.cleanup()
        }
        let taskRegistry = AgentTaskRegistry()
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        _ = try #require(projectRegistry.projectManager(for: other.project))
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(manager.paneManager.terminalState(for: pane))
        let tab = try #require(state.terminalTabs.first)
        let session = makeSession(seed: 90)
        manager.terminal.bridgeAgentSession(session, replacing: nil, in: tab)
        tab.agentSession = session
        let identity = try #require(
            AgentDockMenuRouting.items(for: taskRegistry.tasks).first?.identity
        )

        let canonical = projectRegistry.canonicalProjectURL(fixture.project)
        projectRegistry.closeProjectWindow(fixture.project)
        #expect(projectRegistry.backgroundProjects.contains(canonical))

        var openedURLs: [URL] = []
        var activated: [ObjectIdentifier] = []
        var presentationWindow: NSWindow?
        defer {
            if let presentationWindow {
                manager.unbindDialogOwnerWindow(presentationWindow)
                presentationWindow.orderOut(nil)
            }
        }

        let result = await projectRegistry.navigateToAgentTaskFromInbox(
            identity.taskID,
            openProjectWindow: { openedURLs.append($0) },
            waitUntilPresented: { reopened in
                #expect(reopened === manager)
                let window = self.makeEligibleProjectWindow()
                presentationWindow = window
                reopened.bindDialogOwnerWindow(window)
                return true
            },
            activateApplication: { activated.append(ObjectIdentifier($0)) },
            expectedNotificationRoute: identity
        )

        #expect(result == .focused(
            AgentTaskRoute(paneID: pane.id, tabID: tab.id, terminalID: tab.id)
        ))
        // Only the owning project was asked to reopen.
        #expect(openedURLs == [canonical])
        #expect(activated == [ObjectIdentifier(manager)])
        #expect(state.activeTerminalID == tab.id)
    }

    // MARK: - Helpers

    private func navigate(
        _ projectRegistry: ProjectRegistry,
        _ identity: AgentNotificationRouteIdentity
    ) async -> AgentInboxNavigationResult {
        await projectRegistry.navigateToAgentTaskFromInbox(
            identity.taskID,
            openProjectWindow: { _ in },
            waitUntilPresented: { _ in true },
            activateApplication: { _ in },
            expectedNotificationRoute: identity
        )
    }

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        let registry = ProjectRegistry(agentTasks: AgentTaskRegistry())
        registry.recentProjects = []
        delegate.registry = registry
        return delegate
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineDockRouting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeEligibleProjectWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        return window
    }

    private func makeSession(seed: Int) -> AgentSession {
        let session = AgentSession(
            agentType: .codex,
            state: .executing,
            startedAt: Date(timeIntervalSince1970: TimeInterval(seed))
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: Int32(1_000 + seed),
            processGeneration: UInt64(seed),
            startIdentifier: "dock-session-\(seed)",
            observedStartedAt: Date(timeIntervalSince1970: TimeInterval(seed)),
            startIsAuthoritative: true
        ))
        return session
    }

    private func makeRun(
        seed: Int,
        processIdentifier: Int32,
        processGeneration: UInt64,
        runIDSeed: Int,
        liveness: AgentRunLiveness = .live
    ) -> AgentTaskRun {
        let started = Date(timeIntervalSince1970: TimeInterval(1_000 + seed))
        return AgentTaskRun(AgentTaskRunInput(
            id: uuid(runIDSeed),
            terminalID: uuid(seed + 1),
            process: AgentProcessEvidence(
                processIdentifier: processIdentifier,
                processGeneration: processGeneration,
                startIdentifier: "dock-\(seed)-\(processGeneration)",
                observedStartedAt: started,
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: .executing,
                liveness: liveness,
                observedAt: started
            )
        ))
    }

    private func makeTask(
        seed: Int,
        liveness: AgentRunLiveness = .live,
        lifecycle: AgentTaskLifecycle = .active,
        title: String? = "Review tests",
        project: String = "/tmp/dock-demo"
    ) -> AgentTask {
        let route = AgentTaskRoute(
            paneID: uuid(seed),
            tabID: uuid(seed + 1),
            terminalID: uuid(seed + 1)
        )
        let started = Date(timeIntervalSince1970: TimeInterval(1_000 + seed))
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: AgentTaskBridgeContext(
                project: AgentTaskProjectIdentity(
                    canonicalProjectPath: project,
                    canonicalWorktreePath: project
                ),
                route: route,
                origin: .discoveredInTerminal,
                observedAt: started
            ),
            title: title
        )
        task.lifecycle = lifecycle
        task.runs = [makeRun(
            seed: seed,
            processIdentifier: Int32(seed),
            processGeneration: UInt64(seed),
            runIDSeed: seed + 100,
            liveness: liveness
        )]
        return task
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }
}

private final class DockProjectFixture {
    let root: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PineDock-\(UUID().uuidString)")
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
