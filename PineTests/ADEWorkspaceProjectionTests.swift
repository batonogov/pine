//
//  ADEWorkspaceProjectionTests.swift
//  PineTests
//
//  The project window's task list is a pure projection of the existing
//  Inbox rows (#1760): every indicator is derived from the durable task
//  lifecycle, and the projection stores nothing of its own.
//

import Foundation
import Testing
@testable import Pine

@Suite("ADE workspace projection", .serialized)
@MainActor
struct ADEWorkspaceProjectionTests {
    private let projectPath = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("ADEProjection-\(UUID().uuidString)")
        .path

    private var accuracyPolicy: AgentLifecycleAccuracyPolicy {
        AgentLifecycleAccuracyPolicy { _ in .verifiedLifecycleTransitions }
    }

    // MARK: - Fixtures

    private func identity(_ path: String) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: path, canonicalWorktreePath: path
        )
    }

    private func context(
        identity taskIdentity: AgentTaskProjectIdentity, seed: Int,
        surface: AgentTaskTerminalSurface = .projectWindow
    ) -> AgentTaskBridgeContext {
        AgentTaskBridgeContext(
            project: taskIdentity,
            route: AgentTaskRoute(
                surface: surface,
                paneID: uuid(seed), tabID: uuid(seed + 1_000), terminalID: uuid(seed + 1_000)
            ),
            origin: .discoveredInTerminal,
            observedAt: Date(timeIntervalSince1970: TimeInterval(seed))
        )
    }

    private func uuid(_ seed: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", seed)) ?? UUID()
    }

    private func makeTask(
        _ seed: Int,
        project taskProject: String? = nil,
        surface: AgentTaskTerminalSurface = .projectWindow,
        title: String? = nil,
        mutate: (inout AgentTask) -> Void = { _ in }
    ) -> AgentTask {
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: context(
                identity: identity(taskProject ?? projectPath), seed: seed, surface: surface
            ),
            title: title,
            objective: title,
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + seed))
        )
        mutate(&task)
        return task
    }

    private func settledTask(
        _ seed: Int, outcome: AgentTaskOutcome,
        verificationState: AgentTaskVerificationState = .none
    ) -> AgentTask {
        makeTask(seed) { task in
            task.runs = [AgentTaskRun(AgentTaskRunInput(
                id: uuid(seed + 3_000),
                terminalID: task.route.terminalID,
                process: AgentProcessEvidence(
                    processIdentifier: Int32(seed),
                    processGeneration: UInt64(seed),
                    startIdentifier: "projection-\(seed)",
                    observedStartedAt: task.createdAt,
                    startIsAuthoritative: true
                ),
                status: AgentTaskRunStatus(
                    state: .done, liveness: .terminated,
                    observedAt: task.createdAt.addingTimeInterval(60)
                )
            ))]
            task.runs[0].outcome = outcome
            task.verificationState = verificationState
            task.lifecycle = .paused
        }
    }

    private func rows(from tasks: [AgentTask]) -> [ADETaskRow] {
        ADEWorkspaceProjection.rows(
            from: tasks, projectPath: projectPath, accuracyPolicy: accuracyPolicy
        )
    }

    // MARK: - Indicators

    @Test("a live unsettled turn projects Running")
    func liveTurnIsRunning() throws {
        let task = makeTask(1) { task in
            task.runs = [AgentTaskRun(AgentTaskRunInput(
                id: uuid(3_001),
                terminalID: task.route.terminalID,
                process: AgentProcessEvidence(
                    processIdentifier: 1, processGeneration: 1,
                    startIdentifier: "projection-live",
                    observedStartedAt: task.createdAt, startIsAuthoritative: true
                ),
                status: AgentTaskRunStatus(
                    state: .executing, liveness: .live,
                    observedAt: task.createdAt.addingTimeInterval(60)
                )
            ))]
            task.lifecycle = .active
        }
        let row = try #require(rows(from: [task]).first)
        #expect(row.indicator == .running)
        #expect(!row.neverStarted)
    }

    @Test("a settled attempt without verification is Unverified; no run at all is Not started")
    func settledTurnsProjectHonestStates() throws {
        let unverified = settledTask(2, outcome: .unverified)
        let row = try #require(rows(from: [unverified]).first)
        #expect(row.indicator == .unverified)
        #expect(!row.neverStarted)

        let neverStarted = makeTask(3) { task in
            task.lifecycle = .paused
        }
        let unstartedRow = try #require(rows(from: [neverStarted]).first)
        #expect(unstartedRow.indicator == .unverified)
        #expect(unstartedRow.neverStarted)
    }

    @Test("recorded failure and cancellation keep their distinct honest indicators")
    func failedAndCancelledKeepDistinctStates() throws {
        let failed = settledTask(4, outcome: .failure)
        let cancelled = settledTask(5, outcome: .cancellation)
        let projected = rows(from: [failed, cancelled])
        #expect(projected.map(\.indicator).contains(.failed))
        #expect(projected.map(\.indicator).contains(.cancelled))
    }

    @Test("a verified success projects Ready")
    func verifiedSuccessIsReady() throws {
        let task = settledTask(6, outcome: .success, verificationState: .verified)
        let row = try #require(rows(from: [task]).first)
        #expect(row.indicator == .ready)
        #expect(row.indicator.warrantsAttention)
    }

    @Test("a task waiting for the user's decision outranks its lifecycle")
    func waitingInputIsNeedsDecision() throws {
        let task = makeTask(7) { task in
            task.runs = [AgentTaskRun(AgentTaskRunInput(
                id: uuid(3_007),
                terminalID: task.route.terminalID,
                process: AgentProcessEvidence(
                    processIdentifier: 7, processGeneration: 7,
                    startIdentifier: "projection-decision",
                    observedStartedAt: task.createdAt, startIsAuthoritative: true
                ),
                status: AgentTaskRunStatus(
                    state: .waitingInput, liveness: .live,
                    observedAt: task.createdAt.addingTimeInterval(60)
                )
            ))]
            task.lifecycle = .active
            task.attention = .waitingInput
            task.isUnread = true
        }
        let row = try #require(rows(from: [task]).first)
        #expect(row.indicator == .needsDecision)
        #expect(row.indicator.warrantsAttention)
    }

    @Test("dismissed tasks are not listed at all")
    func dismissedTasksVanish() {
        var dismissed = settledTask(8, outcome: .unverified)
        dismissed.lifecycle = .dismissed
        #expect(rows(from: [dismissed]).isEmpty)
    }

    // MARK: - Project ownership

    @Test("only this project's project-backed rows are listed")
    func filtersByProjectOwnership() throws {
        let mine = settledTask(10, outcome: .unverified)
        let theirs = makeTask(11, project: projectPath.appending("/other")) { task in
            task.lifecycle = .paused
        }
        let quick = makeTask(12, project: projectPath.appending("/other")) { task in
            task.route = AgentTaskRoute(
                surface: .quickTerminalStandalone, paneID: nil, tabID: nil, terminalID: nil
            )
            task.lifecycle = .paused
        }

        let projected = rows(from: [mine, theirs, quick])
        #expect(projected.map(\.id) == [mine.id])
    }

    // MARK: - Order and goals

    @Test("needs-decision rows come first, then ready, then the Inbox order")
    func attentionRanksFirst() throws {
        let plain = settledTask(21, outcome: .unverified)
        let ready = settledTask(22, outcome: .success, verificationState: .verified)
        let decision = makeTask(23) { task in
            task.runs = [AgentTaskRun(AgentTaskRunInput(
                id: uuid(3_023),
                terminalID: task.route.terminalID,
                process: AgentProcessEvidence(
                    processIdentifier: 23, processGeneration: 23,
                    startIdentifier: "projection-rank",
                    observedStartedAt: task.createdAt, startIsAuthoritative: true
                ),
                status: AgentTaskRunStatus(
                    state: .waitingInput, liveness: .live,
                    observedAt: task.createdAt.addingTimeInterval(60)
                )
            ))]
            task.lifecycle = .active
            task.attention = .waitingInput
            task.isUnread = true
        }

        let projected = rows(from: [plain, ready, decision])
        #expect(projected.first?.indicator == .needsDecision)
        #expect(projected.dropFirst().first?.indicator == .ready)
    }

    @Test("a row is titled by its goal, falling back to the agent name")
    func goalFallsBackToAgentName() throws {
        let named = try #require(rows(from: [settledTask(24, outcome: .unverified)]).first)
        #expect(named.goal == AgentType.codex.displayName)

        let titled = settledTask(25, outcome: .unverified)
        var titledTask = titled
        titledTask.title = "Fix the boundary"
        titledTask.objective = "Fix the boundary"
        let titledRow = try #require(rows(from: [titledTask]).first)
        #expect(titledRow.goal == "Fix the boundary")

        let unnamed = try #require(rows(from: [makeTask(26) { task in
            task.title = nil
            task.objective = nil
            task.lifecycle = .paused
        }]).first)
        #expect(unnamed.goal == AgentType.codex.displayName)
    }

    @Test("the projection is deterministic across recomputation (no new stored state)")
    func projectionIsStable() {
        let tasks = (30..<38).map { seed in
            settledTask(seed, outcome: .unverified)
        }
        let first = rows(from: tasks)
        let second = rows(from: tasks)
        #expect(first == second)
        // Recomputing from a reordered snapshot is a re-derivation, not new state.
        let changed = rows(from: Array(tasks.reversed()))
        #expect(changed.map(\.id) == first.map(\.id))
    }
}
