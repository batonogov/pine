//
//  AgentTaskParallelTaskStressTests.swift
//  PineTests
//
//  Parallel independent ADE tasks: stress and integration coverage (#1728).
//  Three same-repository tasks, N+1 scheduling against bound environments,
//  cross-task evidence/attention/routing independence, cancellation and
//  relaunch honesty, and crash-between-writes recovery without fresh
//  creation. Deterministic fixtures, no real providers.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Parallel independent ADE tasks (#1728)", .serialized)
struct AgentTaskParallelTaskStressTests {
    // MARK: - Fixtures

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed + 1))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    private func hex(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    private func codeState(_ tag: Character) -> AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "b", count: 40),
            trackedFingerprint: hex(tag),
            untrackedFingerprint: hex(tag),
            ignoredRelevantFingerprint: hex(tag)
        )
    }

    private func environment(_ tag: Character) -> AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(
            osBuild: "26A5388g",
            toolchain: "Xcode 27.0",
            configurationFingerprint: hex(tag)
        )
    }

    private func makeTask(
        seed: Int,
        fixture: ParallelTaskFixture,
        live: Bool = false,
        now: Date
    ) -> (task: AgentTask, run: AgentTaskRun) {
        let terminalID = uuid(seed + 100)
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: fixture.project.path,
                canonicalWorktreePath: fixture.worktreeURL(seed).path
            ),
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: terminalID,
                terminalID: terminalID,
                availability: live ? .available : .missing
            ),
            origin: .discoveredInTerminal,
            observedAt: now
        )
        let input = AgentTaskRunInput(
            id: uuid(seed + 200),
            terminalID: terminalID,
            process: AgentProcessEvidence(
                processIdentifier: Int32(5_000 + seed),
                processGeneration: UInt64(seed + 300),
                startIdentifier: "ade-1728-\(seed)",
                observedStartedAt: now.addingTimeInterval(-300),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: live ? .executing : .done,
                liveness: live ? .live : .terminated,
                observedAt: now
            ),
            lifecycleAccuracy: .processTerminationOnly
        )
        var run = AgentTaskRun(input)
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        task.runs = [run]
        task.lifecycle = live ? .active : .paused
        task.updatedAt = now
        return (task, run)
    }

    // MARK: - Environment binding across three same-repository tasks

    @Test func threeSameRepositoryTasksBindWithoutCrossTaskContamination() async throws {
        let fixture = try await runOnBackground { try ParallelTaskFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let runA = UUID(), runB = UUID(), runC = UUID()
        let a = fixture.taskID(1)
        let b = fixture.taskID(2)
        let c = fixture.taskID(3)
        _ = try await bindings.reserve(
            taskID: a, runID: runA, canonicalProject: fixture.project,
            expectedWorktree: fixture.worktreeURL(1)
        )
        _ = try await bindings.reserve(
            taskID: b, runID: runB, canonicalProject: fixture.project,
            expectedWorktree: fixture.worktreeURL(2)
        )
        _ = try await bindings.reserve(
            taskID: c, runID: runC, canonicalProject: fixture.project,
            expectedWorktree: fixture.worktreeURL(3)
        )
        try await runOnBackground {
            try fixture.createWorktree(1, runID: runA)
            try fixture.createWorktree(2, runID: runB)
            try fixture.createWorktree(3, runID: runC)
        }
        // Ambiguous adoption is rejected BEFORE binding: exactly one
        // candidate is required.
        await #expect(throws: AgentTaskEnvironmentBindingError.ambiguousEnvironment) {
            _ = try await bindings.adopt(
                taskID: b, runID: runB,
                candidates: [fixture.worktreeURL(1), fixture.worktreeURL(2)]
            )
        }
        let bindingA = try await bindings.adopt(
            taskID: a, runID: runA, candidates: [fixture.worktreeURL(1)]
        )
        let bindingB = try await bindings.adopt(
            taskID: b, runID: runB, candidates: [fixture.worktreeURL(2)]
        )
        let bindingC = try await bindings.adopt(
            taskID: c, runID: runC, candidates: [fixture.worktreeURL(3)]
        )
        // All three environments revalidate independently.
        _ = try await bindings.revalidate(bindingA)
        _ = try await bindings.revalidate(bindingB)
        _ = try await bindings.revalidate(bindingC)

        // No duplicate creation: a fresh reservation targeting an existing
        // environment fails closed.
        await #expect(throws: AgentTaskEnvironmentBindingError.self) {
            _ = try await bindings.reserve(
                taskID: fixture.taskID(4), runID: UUID(),
                canonicalProject: fixture.project,
                expectedWorktree: fixture.worktreeURL(1)
            )
        }
        // No duplicate creation: two reservations on the same expected
        // (missing) path are rejected as ambiguous.
        let e = fixture.taskID(5)
        let f = fixture.taskID(6)
        _ = try await bindings.reserve(
            taskID: e, runID: UUID(), canonicalProject: fixture.project,
            expectedWorktree: fixture.root.appending(path: "shared-missing")
        )
        await #expect(throws: AgentTaskEnvironmentBindingError.ambiguousEnvironment) {
            _ = try await bindings.reserve(
                taskID: f, runID: UUID(), canonicalProject: fixture.project,
                expectedWorktree: fixture.root.appending(path: "shared-missing")
            )
        }
        // A symlink alias of task A's active worktree cannot be adopted by
        // another task.
        let g = fixture.taskID(7)
        let runG = UUID()
        let alias = fixture.root.appending(path: "alias-\(runG.uuidString.prefix(8))")
        _ = try await bindings.reserve(
            taskID: g, runID: runG, canonicalProject: fixture.project,
            expectedWorktree: alias
        )
        try await runOnBackground {
            try FileManager.default.createSymbolicLink(
                at: alias,
                withDestinationURL: fixture.worktreeURL(1).resolvingSymlinksInPath()
            )
        }
        await #expect(throws: AgentTaskEnvironmentBindingError.self) {
            _ = try await bindings.adopt(taskID: g, runID: runG, candidates: [alias])
        }
        // Task A's environment is untouched by all of the above.
        _ = try await bindings.revalidate(bindingA)

        // Worktree removal invalidates only that task's binding.
        try await runOnBackground {
            try FileManager.default.removeItem(at: fixture.worktreeURL(2))
        }
        await #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) {
            _ = try await bindings.revalidate(bindingB)
        }
        _ = try await bindings.revalidate(bindingA)
        _ = try await bindings.revalidate(bindingC)

        // An agent-created branch change fails closed for that task only.
        _ = await runOnBackground {
            GitCommand.run(
                ["checkout", "-b", "rogue-branch"],
                at: fixture.worktreeURL(3)
            ).succeeded
        }
        await #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) {
            _ = try await bindings.revalidate(bindingC)
        }
        _ = try await bindings.revalidate(bindingA)
    }

    // MARK: - Cross-task reducer, attention, and routing independence

    @Test func crossTaskEvidenceAttentionAndRoutingStayIndependent() async throws {
        let fixture = try await runOnBackground { try ParallelTaskFixture() }
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_000)
        let metadata = fixture.root.appending(path: "metadata")
        try await runOnBackground {
            try FileManager.default.createDirectory(
                at: metadata, withIntermediateDirectories: true
            )
        }
        let store = AgentTaskMetadataStore(storageRoot: metadata)
        let registry = AgentTaskRegistry(persistence: store)
        let (taskA, runA) = makeTask(seed: 21, fixture: fixture, now: now)
        let (taskB, runB) = makeTask(seed: 22, fixture: fixture, now: now)
        let (taskC, runC) = makeTask(seed: 23, fixture: fixture, now: now)
        let (taskD, runD) = makeTask(seed: 24, fixture: fixture, live: true, now: now)
        registry.setTasksForTesting([taskA, taskB, taskC, taskD])
        let csA = codeState("a")
        let envA = environment("a")

        // A fact for A's attempt cannot settle or answer task B.
        let beforeB = try #require(registry.task(for: taskB.id))
        let crossFact = AgentTaskEvidenceFact(
            kind: .agentReportedCompletion,
            runID: runA.id,
            processGeneration: runA.process.processGeneration,
            trust: .observed,
            result: .reported,
            observedAt: now
        )
        #expect(
            registry.recordEvidence(crossFact, taskID: taskB.id)
                == .fencedOut(.unknownRun)
        )
        #expect(registry.task(for: taskB.id) == beforeB)
        #expect(
            registry.recordUserAcceptance(
                taskID: taskB.id, codeState: csA, environment: envA, at: now
            ) == false
        )

        // A completes with all required evidence bound to its own identities.
        func boundFact(
            _ kind: AgentTaskEvidenceKind,
            _ result: AgentTaskEvidenceResult,
            _ offset: TimeInterval,
            operationFingerprints: Bool
        ) -> AgentTaskEvidenceFact {
            AgentTaskEvidenceFact(
                kind: kind,
                runID: runA.id,
                processGeneration: runA.process.processGeneration,
                trust: .verified,
                result: result,
                observedAt: now.addingTimeInterval(offset),
                codeState: csA,
                environment: envA,
                preOperationCodeState: operationFingerprints ? csA : nil,
                postOperationCodeState: operationFingerprints ? csA : nil
            )
        }
        #expect(
            registry.recordEvidence(
                boundFact(.agentReportedCompletion, .reported, 0, operationFingerprints: false),
                taskID: taskA.id
            ) == .accepted
        )
        #expect(
            registry.recordEvidence(
                boundFact(.independentCheck, .succeeded, 1, operationFingerprints: true),
                taskID: taskA.id
            ) == .accepted
        )
        #expect(
            registry.recordEvidence(
                boundFact(.reviewerOutcome, .succeeded, 2, operationFingerprints: true),
                taskID: taskA.id
            ) == .accepted
        )
        let settledA = try #require(registry.task(for: taskA.id))
        #expect(settledA.runs.last?.outcome == .success)
        #expect(settledA.lifecycle == .completed)
        #expect(settledA.attention == .completed)
        #expect(settledA.isUnread)
        #expect(settledA.verificationState == .verified)

        // B and C stay untouched by A's settlement.
        for other in [taskB, taskC] {
            let snapshot = try #require(registry.task(for: other.id))
            #expect(snapshot.attention == .none)
            #expect(!snapshot.isUnread)
            #expect(snapshot.runs.last?.outcome == nil)
            #expect(snapshot.verificationState == .none)
        }
        // Readiness is per task and per identity.
        #expect(
            registry.readiness(for: taskA.id, codeState: csA, environment: envA).isReady
        )
        #expect(
            !registry.readiness(for: taskB.id, codeState: csA, environment: envA).isReady
        )
        #expect(
            !registry.readiness(for: taskA.id, codeState: codeState("b"), environment: envA).isReady
        )

        // Notification routing is exact: task + run + process generation.
        #expect(
            registry.matchesNotificationRoute(
                AgentNotificationRouteIdentity(
                    taskID: taskA.id,
                    runID: runA.id,
                    processGeneration: runA.process.processGeneration
                )
            )
        )
        #expect(
            !registry.matchesNotificationRoute(
                AgentNotificationRouteIdentity(
                    taskID: taskB.id,
                    runID: runA.id,
                    processGeneration: runA.process.processGeneration
                )
            )
        )

        // Intermediate activity is not a notification stream: a live working
        // run that reports activity keeps attention and unread unchanged
        // until its attempt settles.
        let liveD = try #require(registry.task(for: taskD.id))
        #expect(liveD.attention == .none)
        #expect(!liveD.isUnread)
        #expect(AgentTaskLifecycleReducer.executionState(for: liveD) == .working)
        #expect(
            registry.recordEvidence(
                AgentTaskEvidenceFact(
                    kind: .agentReportedCompletion,
                    runID: runD.id,
                    processGeneration: runD.process.processGeneration,
                    trust: .observed,
                    result: .reported,
                    observedAt: now.addingTimeInterval(3)
                ),
                taskID: taskD.id
            ) == .accepted
        )
        let activityD = try #require(registry.task(for: taskD.id))
        #expect(activityD.attention == .none)
        #expect(!activityD.isUnread)
        #expect(activityD.runs.last?.outcome == nil)
        // B's own run identity never matched A's route either.
        #expect(
            !registry.matchesNotificationRoute(
                AgentNotificationRouteIdentity(
                    taskID: taskA.id,
                    runID: runB.id,
                    processGeneration: runB.process.processGeneration
                )
            )
        )
        _ = runC
    }

    // MARK: - N+1 scheduling against bound environments

    @Test func nPlusOneSchedulesAgainstBoundEnvironments() async throws {
        let fixture = try await runOnBackground { try ParallelTaskFixture() }
        defer { fixture.remove() }
        let gate = AgentTaskConcurrencyAdmission()
        let boundaries = AgentTaskEventBoundaries()
        // Same repository, distinct worktrees: the realistic three-task
        // configuration sharing ONE admission bucket.
        // The launch path starts a process ONLY from a grant.
        var launched = 0
        for seed in 0..<4 {
            switch await gate.requestLaunch(
                project: fixture.identity(seed),
                taskID: fixture.taskID(seed),
                runID: UUID()
            ) {
            case .admitted(let grant):
                launched += 1
                _ = await boundaries.enqueue(
                    AgentTaskQueuedEvent(
                        taskID: grant.taskID,
                        runID: grant.runID,
                        launchGeneration: grant.launchGeneration,
                        isAuthoritative: true,
                        coalescingKey: nil,
                        payload: Data([UInt8(grant.launchGeneration)])
                    )
                )
            case .queued:
                break
            case .deferred:
                Issue.record("queue was not full; no deferral expected")
            }
        }
        #expect(
            launched == AgentTaskConcurrencyLimits.maximumConcurrentAgentTasks
        )
        // The queued task has no admitted traffic of its own.
        #expect(await boundaries.drain(taskID: fixture.taskID(3)).isEmpty)
        let promoted = await gate.release(
            project: fixture.identity(0), taskID: fixture.taskID(0)
        )
        #expect(promoted.count == 1)
        #expect(promoted.first?.taskID == fixture.taskID(3))
        #expect(promoted.first?.project == fixture.identity(3))
        #expect(promoted.first?.launchGeneration == 4)
        launched += promoted.count
        #expect(launched == 4)
        #expect(await gate.activeCount(project: fixture.identity(0)) == 3)
        #expect(await gate.queuedCount(project: fixture.identity(0)) == 0)
    }

    // MARK: - Cancellation, relaunch, and crash-between-writes

    @Test func cancellationAndRelaunchStayHonestWithoutDuplicateWork() async throws {
        let fixture = try await runOnBackground { try ParallelTaskFixture() }
        defer { fixture.remove() }
        let gate = AgentTaskConcurrencyAdmission()
        let boundaries = AgentTaskEventBoundaries()
        let p = fixture.identity(0)
        for seed in 0..<4 {
            _ = await gate.requestLaunch(
                project: fixture.identity(seed), taskID: fixture.taskID(seed), runID: UUID()
            )
        }
        #expect(await gate.queuedCount(project: p) == 1)
        _ = await boundaries.enqueue(
            AgentTaskQueuedEvent(
                taskID: fixture.taskID(0), runID: UUID(), launchGeneration: 1,
                isAuthoritative: true, coalescingKey: nil, payload: Data([1])
            )
        )
        // Cancellation frees the slot, promotes the queue, and the teardown
        // composition clears the cancelled task's bounded resources.
        await gate.cancel(project: p, taskID: fixture.taskID(0))
        await boundaries.clear(taskID: fixture.taskID(0))
        // Nothing auto-continued: the cancelled task holds no grant.
        #expect(await gate.grant(project: p, taskID: fixture.taskID(0)) == nil)
        let promoted = try #require(
            await gate.grant(project: p, taskID: fixture.taskID(3))
        )
        #expect(promoted.launchGeneration == 4)
        #expect(await gate.activeCount(project: p) == 3)
        #expect(await gate.queuedCount(project: p) == 0)
        #expect(await boundaries.drain(taskID: fixture.taskID(0)).isEmpty)
        // Double release and double cancel are no-ops: no duplicate work.
        #expect(await gate.release(project: p, taskID: fixture.taskID(0)).isEmpty)
        await gate.cancel(project: p, taskID: fixture.taskID(0))
        #expect(await gate.activeCount(project: p) == 3)
        #expect(await gate.queuedCount(project: p) == 0)
        #expect(await gate.grant(project: p, taskID: fixture.taskID(3)) == promoted)
        // Free one other slot, then relaunch with a fresh grant/generation.
        _ = await gate.release(project: p, taskID: fixture.taskID(1))
        let relaunch = await gate.requestLaunch(
            project: p, taskID: fixture.taskID(0), runID: UUID()
        )
        guard case .admitted(let grant) = relaunch else {
            Issue.record("relaunch should be admitted")
            return
        }
        #expect(grant.launchGeneration > promoted.launchGeneration)
    }

    @Test func crashBetweenWritesRecoversWithoutFreshCreation() async throws {
        let fixture = try await runOnBackground { try ParallelTaskFixture() }
        defer { fixture.remove() }
        let bindings = AgentTaskEnvironmentBindings()
        let taskID = fixture.taskID(30)
        let runID = UUID()
        let expected = fixture.worktreeURL(30)
        let lease = try await bindings.reserve(
            taskID: taskID, runID: runID,
            canonicalProject: fixture.project, expectedWorktree: expected
        )
        let snapshot = lease.snapshot
        // "Crash": all in-memory state — bindings AND admission — dies with
        // the process. The setup snapshot survives only because it is
        // durable: cross a real persistence boundary by encoding/decoding
        // the exact journal bytes before recovery.
        let journal = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            AgentTaskEnvironmentSetupSnapshot.self, from: journal
        )
        let recovered = AgentTaskEnvironmentBindings()
        let restored = try await recovered.restore(decoded)
        // Recovery may observe and reconcile the persisted intent; it can
        // never issue a fresh creation.
        #expect(restored.claimCreationAttempt() == false)
        #expect(await runOnBackground { restored.revalidateOrigin() })
        // The target is still absent, so the restored lease remains a valid
        // reconciliation (not a creation) grant.
        #expect(await runOnBackground { restored.revalidate() })
        // #1728 honesty: admission state is runtime-only and died with the
        // process. A fresh gate holds nothing and admits nothing without an
        // explicit re-request — no slot or queue entry survives the crash.
        let gate = AgentTaskConcurrencyAdmission()
        let p = fixture.identity(30)
        #expect(await gate.activeCount(project: p) == 0)
        #expect(await gate.queuedCount(project: p) == 0)
        #expect(await gate.grant(project: p, taskID: taskID) == nil)
        // The relaunch is an explicit new request with a fresh grant.
        let relaunch = await gate.requestLaunch(project: p, taskID: taskID, runID: runID)
        guard case .admitted(let grant) = relaunch else {
            Issue.record("relaunch after crash should be admitted")
            return
        }
        #expect(grant.launchGeneration == 1)
    }
}

/// One real Git repository with per-task worktree paths. No provider, no
/// network: Git only.
nonisolated private struct ParallelTaskFixture: Sendable {
    let root: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "Pine1728-\(UUID())")
            .resolvingSymlinksInPath()
        project = root.appending(path: "project")
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true
        )
        for arguments in [
            ["init", "-b", "main"],
            [
                "-c", "user.name=Pine Test",
                "-c", "user.email=pine@example.invalid",
                "commit", "--allow-empty", "-m", "fixture"
            ]
        ] {
            guard GitCommand.run(arguments, at: project).succeeded else {
                try? FileManager.default.removeItem(at: root)
                throw ParallelTaskFixtureError.gitFailed
            }
        }
    }

    func worktreeURL(_ seed: Int) -> URL {
        root.appending(path: "worktree-\(seed)")
    }

    /// Realistic task identity: one canonical project (repository) with a
    /// per-task worktree — the shape the binding contract produces.
    func identity(_ seed: Int) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: project.path,
            canonicalWorktreePath: worktreeURL(seed).path
        )
    }

    func taskID(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed + 1))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    func createWorktree(_ seed: Int, runID: UUID) throws {
        let task = taskID(seed)
        let branch = AgentTaskEnvironmentBindings.branchName(taskID: task, runID: runID)
        guard GitCommand.run(
            ["worktree", "add", "-b", branch, worktreeURL(seed).path],
            at: project
        ).succeeded else {
            throw ParallelTaskFixtureError.gitFailed
        }
    }

    /// Fire-and-forget: teardown never blocks the main actor, and a git
    /// tree (project + up to three worktrees) is expensive to remove.
    func remove() {
        let root = self.root
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private enum ParallelTaskFixtureError: Error { case gitFailed }
