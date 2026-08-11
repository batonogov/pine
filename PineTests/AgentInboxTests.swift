//
//  AgentInboxTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@MainActor
struct AgentInboxTests {
    @Test("aggregation ranks urgency and keeps deterministic activity order")
    func aggregationAndOrdering() throws {
        let base = Date(timeIntervalSince1970: 10_000)
        let waiting = makeTask(
            seed: 1,
            project: "/tmp/inbox-a",
            state: .waitingInput,
            liveness: .live,
            attention: .waitingInput,
            unread: true,
            observedAt: base.addingTimeInterval(20)
        )
        let newerWorking = makeTask(
            seed: 2,
            project: "/tmp/inbox-b",
            state: .executing,
            liveness: .live,
            observedAt: base.addingTimeInterval(30)
        )
        let olderWorking = makeTask(
            seed: 3,
            project: "/tmp/inbox-a",
            state: .thinking,
            liveness: .live,
            observedAt: base.addingTimeInterval(10)
        )
        var completed = makeTask(
            seed: 4,
            project: "/tmp/inbox-c",
            state: .done,
            liveness: .terminated,
            attention: .completed,
            unread: true,
            observedAt: base
        )
        completed.lifecycle = .completed

        let snapshot = AgentInboxSnapshot(
            tasks: [olderWorking, completed, newerWorking, waiting],
            accuracyPolicy: verifiedAccuracyPolicy
        )

        #expect(snapshot.sections.map(\.id) == [
            .needsAttention, .completedUnread, .working,
        ])
        let working = try #require(
            snapshot.sections.first(where: { $0.id == .working })
        )
        #expect(working.rows.map(\.id) == [newerWorking.id, olderWorking.id])
        #expect(snapshot.rows.first?.projectName == "inbox-a")
        #expect(snapshot.rows.allSatisfy { !$0.agentName.isEmpty })
    }

    @Test("catalog ceiling keeps forged waiting evidence in Working")
    func catalogCeilingSuppressesForgedWaitingEvidence() throws {
        let task = makeTask(
            seed: 90,
            project: "/tmp/inbox-forged",
            state: .waitingInput,
            liveness: .live,
            attention: .waitingInput,
            unread: true,
            observedAt: Date(timeIntervalSince1970: 10_000)
        )

        let snapshot = AgentInboxSnapshot(tasks: [task])
        #expect(snapshot.sections.map(\.id) == [.working])
        #expect(snapshot.rows.first?.state == .idle)
    }

    @Test("row order stays stable when polling-driven activity timestamps flip")
    func rowOrderStableAcrossPollFlips() throws {
        // Two working tasks with write-once-stable start times.
        let startedNewer = Date(timeIntervalSince1970: 10_000)
        let startedOlder = startedNewer.addingTimeInterval(-60)
        let taskNewer = makeWorkingTask(
            seed: 1,
            project: "/tmp/sort-newer",
            runStartedAt: startedNewer,
            lastObservedAt: startedNewer
        )
        let taskOlder = makeWorkingTask(
            seed: 2,
            project: "/tmp/sort-older",
            runStartedAt: startedOlder,
            lastObservedAt: startedOlder
        )

        // Poll 1: the newer-started task also has the freshest activity
        // timestamp. Both the old and new sort agree here.
        var poll1Newer = taskNewer
        poll1Newer.runs[0].lastObservedAt = startedNewer.addingTimeInterval(100)
        var poll1Older = taskOlder
        poll1Older.runs[0].lastObservedAt = startedOlder.addingTimeInterval(10)
        let snapshot1 = AgentInboxSnapshot(tasks: [poll1Newer, poll1Older])

        // Poll 2: the activity timestamps FLIP — the older-started task now
        // has the freshest activity timestamp. Under the old
        // (polling-driven) sort the rows would swap; under the new stable
        // sort they must NOT move.
        var poll2Newer = taskNewer
        poll2Newer.runs[0].lastObservedAt = startedNewer.addingTimeInterval(10)
        var poll2Older = taskOlder
        poll2Older.runs[0].lastObservedAt = startedOlder.addingTimeInterval(100)
        let snapshot2 = AgentInboxSnapshot(tasks: [poll2Newer, poll2Older])

        let working1 = try #require(
            snapshot1.sections.first(where: { $0.id == .working })
        )
        let working2 = try #require(
            snapshot2.sections.first(where: { $0.id == .working })
        )

        // `startedAt` is stable, so the newer-started row leads in BOTH
        // snapshots even though `lastVerifiedActivityAt` flipped between polls.
        #expect(working1.rows.map(\.id) == [taskNewer.id, taskOlder.id])
        #expect(working2.rows.map(\.id) == [taskNewer.id, taskOlder.id])
    }

    @Test("unread rows lead regardless of startedAt")
    func unreadLeadsOverStartedAt() throws {
        let startedNewer = Date(timeIntervalSince1970: 10_000)
        let startedOlder = startedNewer.addingTimeInterval(-60)
        // Unread task started OLDER; read task started NEWER.
        let unread = makeWorkingTask(
            seed: 10,
            project: "/tmp/sort-unread",
            runStartedAt: startedOlder,
            lastObservedAt: startedOlder,
            unread: true
        )
        let read = makeWorkingTask(
            seed: 11,
            project: "/tmp/sort-read",
            runStartedAt: startedNewer,
            lastObservedAt: startedNewer,
            unread: false
        )

        let snapshot = AgentInboxSnapshot(tasks: [read, unread])
        let working = try #require(
            snapshot.sections.first(where: { $0.id == .working })
        )
        // Unread leads even though it started earlier than the read task.
        #expect(working.rows.map(\.id) == [unread.id, read.id])
    }

    @Test("VoiceOver row labels expose unread state without duplicate agent")
    func accessibilityLabelExposesUnreadState() {
        let row = accessibilityRow(seed: 15, title: nil, unread: true)
        let label = AgentInboxView.accessibilityLabel(
            for: row,
            locale: Locale(identifier: "en")
        )

        #expect(label.contains("Unread"))
        #expect(label.components(separatedBy: "Codex").count - 1 == 1)

        let readLabel = AgentInboxView.accessibilityLabel(
            for: accessibilityRow(seed: 16, title: nil, unread: false),
            locale: Locale(identifier: "en")
        )
        #expect(!readLabel.contains("Unread"))
    }

    @Test("VoiceOver announces only a changed keyboard selection")
    func accessibilityAnnouncementTracksSelection() {
        let first = accessibilityRow(
            seed: 17,
            title: "Review release",
            unread: true
        )
        let second = accessibilityRow(
            seed: 18,
            title: "Run checks",
            unread: false
        )
        let rows = [first, second]
        let locale = Locale(identifier: "en")

        #expect(AgentInboxView.accessibilityAnnouncement(
            from: first.id,
            to: second.id,
            rows: rows,
            locale: locale
        ) == AgentInboxView.accessibilityLabel(for: second, locale: locale))
        #expect(AgentInboxView.accessibilityAnnouncement(
            from: second.id,
            to: second.id,
            rows: rows,
            locale: locale
        ) == nil)
        #expect(AgentInboxView.accessibilityAnnouncement(
            from: second.id,
            to: nil,
            rows: rows,
            locale: locale
        ) == nil)
    }

    @Test("identical startedAt ignores polling timestamp and uses id tiebreak")
    func identicalStartedAtUsesIdTiebreak() throws {
        let started = Date(timeIntervalSince1970: 10_000)
        // Same start time; the second task has a much fresher activity
        // timestamp, which the new sort must ignore.
        let taskA = makeWorkingTask(
            seed: 21,
            project: "/tmp/sort-a",
            runStartedAt: started,
            lastObservedAt: started
        )
        let taskB = makeWorkingTask(
            seed: 22,
            project: "/tmp/sort-b",
            runStartedAt: started,
            lastObservedAt: started.addingTimeInterval(99)
        )

        let expected = [taskA.id, taskB.id]
            .sorted { $0.uuidString < $1.uuidString }
        let snapshot = AgentInboxSnapshot(tasks: [taskA, taskB])
        let working = try #require(
            snapshot.sections.first(where: { $0.id == .working })
        )
        #expect(working.rows.map(\.id) == expected)
    }

    @Test("render projection never marks unread tasks reviewed")
    func projectionHasNoReviewSideEffect() throws {
        let registry = AgentTaskRegistry(
            accuracyPolicy: verifiedAccuracyPolicy
        )
        let identity = project("/tmp/inbox-unread")
        let session = makeSession(
            seed: 20,
            state: .waitingInput,
            lifecycleAccuracy: .verifiedLifecycleTransitions
        )
        registry.bridge(
            session,
            replacing: nil,
            context: context(identity: identity, seed: 20)
        )
        let taskID = try #require(registry.taskID(forSessionID: session.id))
        #expect(registry.task(for: taskID)?.isUnread == true)

        _ = AgentInboxSnapshot(tasks: registry.tasks)
        _ = AgentInboxSnapshot(tasks: registry.tasks)

        #expect(registry.task(for: taskID)?.isUnread == true)
        #expect(registry.setReviewed(true, taskID: taskID))
        #expect(registry.task(for: taskID)?.isUnread == false)
        #expect(registry.setReviewed(false, taskID: taskID))
        #expect(registry.task(for: taskID)?.isUnread == true)
    }

    @Test("dismissal removes only non-live history from the Inbox")
    func safeDismissal() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/inbox-dismiss")
        let session = makeSession(seed: 30, state: .executing)
        let routeContext = context(identity: identity, seed: 30)
        registry.bridge(session, replacing: nil, context: routeContext)
        let taskID = try #require(registry.taskID(forSessionID: session.id))

        #expect(!registry.dismissTask(taskID))
        session.applyLiveness(.terminated)
        registry.bridge(session, replacing: session, context: routeContext)
        #expect(registry.dismissTask(taskID))
        #expect(registry.task(for: taskID)?.lifecycle == .dismissed)
        #expect(AgentInboxSnapshot(tasks: registry.tasks).isEmpty)
    }

    @Test("navigation focuses only the exact live generation")
    func exactNavigationAndReplacementFailure() async throws {
        let fixture = try InboxProjectFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry(
            accuracyPolicy: verifiedAccuracyPolicy
        )
        let projectRegistry = ProjectRegistry(
            agentTasks: taskRegistry
        )
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(manager.paneManager.terminalState(for: pane))
        let tab = try #require(state.terminalTabs.first)
        let session = makeSession(
            seed: 40,
            state: .waitingInput,
            lifecycleAccuracy: .verifiedLifecycleTransitions
        )
        manager.terminal.bridgeAgentSession(
            session,
            replacing: nil,
            in: tab
        )
        tab.agentSession = session
        let taskID = try #require(taskRegistry.taskID(forSessionID: session.id))
        #expect(taskRegistry.task(for: taskID)?.isUnread == true)

        let focused = await projectRegistry.navigateToAgentTaskFromInbox(
            taskID,
            openProjectWindow: { _ in },
            waitUntilPresented: { _ in true },
            activateApplication: { _ in }
        )
        #expect(focused == .focused(AgentTaskRoute(
            paneID: pane.id,
            tabID: tab.id,
            terminalID: tab.id
        )))
        #expect(state.activeTerminalID == tab.id)
        #expect(state.pendingFocusTabID == tab.id)
        #expect(taskRegistry.task(for: taskID)?.isUnread == false)

        session.applyLiveness(.terminated)
        let replacement = makeSession(seed: 41, state: .executing)
        manager.terminal.bridgeAgentSession(
            replacement,
            replacing: session,
            in: tab
        )
        tab.agentSession = replacement

        #expect(await projectRegistry.navigateToAgentTaskFromInbox(
            taskID,
            openProjectWindow: { _ in },
            waitUntilPresented: { _ in true },
            activateApplication: { _ in }
        ) == .routeStale)
    }

    @Test("notification navigation rejects a replacement during window presentation")
    func notificationNavigationRejectsReplacementRace() async throws {
        let fixture = try InboxProjectFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry(
            accuracyPolicy: verifiedAccuracyPolicy
        )
        let projectRegistry = ProjectRegistry(
            agentTasks: taskRegistry
        )
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(manager.paneManager.terminalState(for: pane))
        let tab = try #require(state.terminalTabs.first)
        let original = makeSession(
            seed: 45,
            state: .waitingInput,
            lifecycleAccuracy: .verifiedLifecycleTransitions
        )
        manager.terminal.bridgeAgentSession(original, replacing: nil, in: tab)
        tab.agentSession = original
        let taskID = try #require(taskRegistry.taskID(forSessionID: original.id))
        let identity = AgentNotificationRouteIdentity(
            taskID: taskID,
            runID: original.id,
            processGeneration: 45
        )

        let result = await projectRegistry.navigateToAgentTaskFromInbox(
            taskID,
            openProjectWindow: { _ in },
            waitUntilPresented: { _ in
                original.applyLiveness(.terminated)
                let replacement = makeSession(seed: 46, state: .executing)
                manager.terminal.bridgeAgentSession(
                    replacement,
                    replacing: original,
                    in: tab
                )
                tab.agentSession = replacement
                return true
            },
            activateApplication: { _ in },
            expectedNotificationRoute: identity
        )

        #expect(result == .routeStale)
        #expect(taskRegistry.task(for: taskID)?.isUnread == true)
    }

    @Test("background navigation reopens the exact project before resolving")
    func backgroundProjectNavigation() async throws {
        let fixture = try InboxProjectFixture()
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
        let session = makeSession(seed: 50, state: .executing)
        manager.terminal.bridgeAgentSession(
            session,
            replacing: nil,
            in: tab
        )
        tab.agentSession = session
        let taskID = try #require(taskRegistry.taskID(forSessionID: session.id))
        projectRegistry.closeProjectWindow(fixture.project)
        var openedURL: URL?

        let result = await projectRegistry.navigateToAgentTaskFromInbox(
            taskID,
            openProjectWindow: { openedURL = $0 },
            waitUntilPresented: { _ in true },
            activateApplication: { _ in }
        )

        #expect(openedURL == projectRegistry.canonicalProjectURL(fixture.project))
        #expect(result == .focused(AgentTaskRoute(
            paneID: pane.id,
            tabID: tab.id,
            terminalID: tab.id
        )))
    }

    @Test("explicit new session preserves history and routes one exact terminal")
    func explicitNewSessionRecovery() async throws {
        let fixture = try InboxProjectFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry()
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        manager.terminal.lastActiveTerminalPaneID = pane
        let state = try #require(manager.paneManager.terminalState(for: pane))
        let originalTab = try #require(state.activeTab)
        let projectIdentity = project(fixture.project.standardizedFileURL.path)
        let routeContext = AgentTaskBridgeContext(
            project: projectIdentity,
            route: AgentTaskRoute(
                paneID: pane.id,
                tabID: originalTab.id,
                terminalID: originalTab.id
            ),
            origin: .pineLaunched,
            observedAt: Date(timeIntervalSince1970: 50)
        )
        let descriptor = AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        )
        let launch = taskRegistry.preparePineLaunch(
            descriptor: descriptor,
            context: routeContext,
            title: "Recovery fixture",
            objective: "Finish the release",
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 50,
                capturedAt: routeContext.observedAt
            )
        )
        let reservation: AgentTaskLaunchReservation
        guard case .reserved(let value) = launch else {
            Issue.record("Expected Pine-owned launch reservation")
            return
        }
        reservation = value
        #expect(taskRegistry.armLaunch(reservation))
        let session = makeSession(seed: 51, state: .executing)
        taskRegistry.bridge(
            session,
            replacing: nil,
            context: routeContext,
            reservation: reservation
        )
        let taskID = try #require(taskRegistry.taskID(forSessionID: session.id))
        session.applyLiveness(.terminated)
        taskRegistry.bridge(
            session,
            replacing: session,
            context: routeContext
        )
        let historicalTask = try #require(taskRegistry.task(for: taskID))
        #expect(historicalTask.lifecycle == .paused)

        let result = await projectRegistry.recoverAgentTaskFromInbox(
            taskID,
            action: .startNewSession,
            openProjectWindow: { _ in },
            waitUntilPresented: { _ in true },
            activateApplication: { _ in }
        )
        guard case .openedNewSession(let terminalID) = result else {
            Issue.record("Expected one fresh terminal")
            return
        }
        #expect(state.terminalTabs.map(\.id) == [originalTab.id, terminalID])
        #expect(state.activeTerminalID == terminalID)
        #expect(state.pendingFocusTabID == terminalID)
        #expect(taskRegistry.task(for: taskID) == historicalTask)
    }

    private func makeTask(
        seed: Int,
        project path: String,
        state: AgentRunState,
        liveness: AgentRunLiveness,
        attention: AgentTaskAttention = .none,
        unread: Bool = false,
        observedAt: Date
    ) -> AgentTask {
        let identity = project(path)
        let routeContext = context(identity: identity, seed: seed)
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: routeContext,
            title: "Task \(seed)",
            createdAt: observedAt.addingTimeInterval(-5)
        )
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: uuid(seed + 3_000),
            terminalID: routeContext.route.terminalID,
            process: AgentProcessEvidence(
                processIdentifier: Int32(seed),
                processGeneration: UInt64(seed),
                startIdentifier: "verified-\(seed)",
                observedStartedAt: observedAt.addingTimeInterval(-5),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: liveness,
                observedAt: observedAt
            ),
            lifecycleAccuracy: attention == .waitingInput
                ? .verifiedLifecycleTransitions
                : .processTerminationOnly
        ))]
        task.attention = attention
        task.isUnread = unread
        task.lastActivityAt = observedAt
        task.updatedAt = observedAt
        task.route.availability = liveness == .live ? .available : .missing
        task.lifecycle = liveness == .live ? .active : .paused
        return task
    }

    /// Builds a working-section task whose row-level sort keys can be set
    /// independently: `runStartedAt` becomes the write-once-stable
    /// `startedAt`, while `lastObservedAt` becomes the polling-driven
    /// `lastVerifiedActivityAt`.
    private func makeWorkingTask(
        seed: Int,
        project path: String,
        runStartedAt: Date,
        lastObservedAt: Date,
        unread: Bool = false
    ) -> AgentTask {
        let identity = project(path)
        let routeContext = context(identity: identity, seed: seed)
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: routeContext,
            title: "Task \(seed)",
            createdAt: runStartedAt
        )
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: uuid(seed + 3_000),
            terminalID: routeContext.route.terminalID,
            process: AgentProcessEvidence(
                processIdentifier: Int32(seed),
                processGeneration: UInt64(seed),
                startIdentifier: "verified-\(seed)",
                observedStartedAt: runStartedAt,
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: .executing,
                liveness: .live,
                observedAt: lastObservedAt
            )
        ))]
        task.isUnread = unread
        task.lastActivityAt = lastObservedAt
        task.updatedAt = lastObservedAt
        task.route.availability = .available
        task.lifecycle = .active
        return task
    }

    private func accessibilityRow(
        seed: UInt8,
        title: String?,
        unread: Bool
    ) -> AgentInboxRow {
        let id = UUID(uuid: (
            seed, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, seed
        ))
        return AgentInboxRow(
            id: id,
            section: .working,
            projectPath: "/tmp/Pine Demo",
            worktreePath: "/tmp/Pine Demo",
            title: title,
            agentName: "Codex",
            lifecycle: .active,
            state: .executing,
            liveness: .live,
            routeAvailability: .available,
            startedAt: Date(timeIntervalSince1970: 100),
            lastVerifiedActivityAt: Date(timeIntervalSince1970: 101),
            isUnread: unread
        )
    }

    private func project(_ path: String) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: path,
            canonicalWorktreePath: path
        )
    }

    private func context(
        identity: AgentTaskProjectIdentity,
        seed: Int
    ) -> AgentTaskBridgeContext {
        AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: uuid(seed + 1_000),
                terminalID: uuid(seed + 1_000)
            ),
            origin: .discoveredInTerminal,
            observedAt: Date(timeIntervalSince1970: TimeInterval(seed))
        )
    }

    private var verifiedAccuracyPolicy: AgentLifecycleAccuracyPolicy {
        AgentLifecycleAccuracyPolicy { _ in
            .verifiedLifecycleTransitions
        }
    }

    private func makeSession(
        seed: Int,
        state: AgentState,
        lifecycleAccuracy: FirstPartyAgentNotificationAccuracy = .processTerminationOnly
    ) -> AgentSession {
        let session = AgentSession(
            agentType: .codex,
            state: state,
            lifecycleAccuracy: lifecycleAccuracy,
            startedAt: Date(timeIntervalSince1970: TimeInterval(seed))
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: Int32(1_000 + seed),
            processGeneration: UInt64(seed),
            startIdentifier: "verified-session-\(seed)",
            observedStartedAt: Date(timeIntervalSince1970: TimeInterval(seed)),
            startIsAuthoritative: true
        ))
        return session
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")
            ?? UUID()
    }
}

private final class InboxProjectFixture {
    let root: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PineInbox-\(UUID().uuidString)")
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
