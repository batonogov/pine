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

        let snapshot = AgentInboxSnapshot(tasks: [
            olderWorking, completed, newerWorking, waiting,
        ])

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

    @Test("render projection never marks unread tasks reviewed")
    func projectionHasNoReviewSideEffect() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/inbox-unread")
        let session = makeSession(seed: 20, state: .waitingInput)
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
        let session = makeSession(seed: 40, state: .waitingInput)
        manager.terminal.bridgeAgentSession(
            session,
            replacing: nil,
            in: tab
        )
        tab.agentSession = session
        let taskID = try #require(taskRegistry.taskID(forSessionID: session.id))

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
            )
        ))]
        task.attention = attention
        task.isUnread = unread
        task.lastActivityAt = observedAt
        task.updatedAt = observedAt
        task.route.availability = liveness == .live ? .available : .missing
        task.lifecycle = liveness == .live ? .active : .paused
        return task
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

    private func makeSession(seed: Int, state: AgentState) -> AgentSession {
        let session = AgentSession(
            agentType: .codex,
            state: state,
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
