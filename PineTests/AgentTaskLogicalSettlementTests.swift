//
//  AgentTaskLogicalSettlementTests.swift
//  PineTests
//
//  Logical settlement independent of provider process exit (#1795,
//  settlement-only model/persistence dependency of #1756): a logically
//  settled attempt may retain a live provider process. Settlement
//  admission is fenced to the exact current task/run/process/source/turn
//  authority and proven aggregate closure; no physical exit, endedAt, or
//  processCompletion fact is fabricated, and the original logical
//  timestamp survives the eventual physical exit.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Logical settlement independent of process exit", .serialized)
struct AgentTaskLogicalSettlementTests {
    // MARK: - Fixtures

    private func hex(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    private func codeState(
        _ tag: Character,
        head: String = String(repeating: "b", count: 40)
    ) -> AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: head,
            trackedFingerprint: hex(tag),
            untrackedFingerprint: hex(tag),
            ignoredRelevantFingerprint: hex(tag)
        )
    }

    private var environment: AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(
            osBuild: "26A5388g",
            toolchain: "Xcode 27.0",
            configurationFingerprint: hex("c")
        )
    }

    private func project(_ path: String) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: URL(fileURLWithPath: path)
                .standardizedFileURL.path,
            canonicalWorktreePath: URL(fileURLWithPath: path)
                .standardizedFileURL.path
        )
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")
            ?? UUID()
    }

    /// One live attempt with honest chronology. The run started 300 s
    /// before `now` and was last observed at `now`.
    private func liveRun(
        seed: Int,
        state: AgentRunState = .done,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AgentTaskRun {
        AgentTaskRun(AgentTaskRunInput(
            id: uuid(seed + 200),
            terminalID: uuid(seed + 100),
            process: AgentProcessEvidence(
                processIdentifier: Int32(5_000 + seed),
                processGeneration: UInt64(seed),
                startIdentifier: "ls-\(seed)",
                observedStartedAt: now.addingTimeInterval(-300),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: .live,
                observedAt: now
            ),
            lifecycleAccuracy: .verifiedLifecycleTransitions
        ))
    }

    private func liveTask(
        seed: Int,
        state: AgentRunState = .done,
        now: Date = Date(timeIntervalSince1970: 1_000),
        projectPath: String? = nil
    ) -> AgentTask {
        let context = AgentTaskBridgeContext(
            project: project(projectPath ?? "/tmp/pine-ls-\(seed)"),
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: uuid(seed + 100),
                terminalID: uuid(seed + 100),
                availability: .available
            ),
            origin: .discoveredInTerminal,
            observedAt: now
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        task.runs = [liveRun(seed: seed, state: state, now: now)]
        task.lifecycle = .active
        task.updatedAt = now
        task.lastActivityAt = now
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        return task
    }

    /// A legacy terminated attempt, settled from its observed exit.
    private func settledTask(
        seed: Int,
        now: Date = Date(timeIntervalSince1970: 1_000),
        projectPath: String? = nil
    ) -> AgentTask {
        let context = AgentTaskBridgeContext(
            project: project(projectPath ?? "/tmp/pine-ls-\(seed)"),
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: uuid(seed + 100),
                terminalID: uuid(seed + 100),
                availability: .missing
            ),
            origin: .discoveredInTerminal,
            observedAt: now
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        var run = AgentTaskRun(AgentTaskRunInput(
            id: uuid(seed + 200),
            terminalID: uuid(seed + 100),
            process: AgentProcessEvidence(
                processIdentifier: Int32(5_000 + seed),
                processGeneration: UInt64(seed),
                startIdentifier: "ls-\(seed)",
                observedStartedAt: now.addingTimeInterval(-300),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: .done,
                liveness: .terminated,
                observedAt: now
            ),
            lifecycleAccuracy: .processTerminationOnly
        ))
        task.runs = [run]
        task.lifecycle = .paused
        task.updatedAt = now
        task.lastActivityAt = now
        AgentTaskLifecycleReducer.settleTerminated(task: &task, runIndex: 0)
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        return task
    }

    private func fact(
        _ kind: AgentTaskEvidenceKind,
        runID: UUID,
        generation: UInt64,
        result: AgentTaskEvidenceResult,
        at: Date,
        codeState: AgentTaskCodeStateIdentity? = nil,
        environment: AgentTaskEnvironmentIdentity? = nil,
        sequence: UInt64? = nil
    ) -> AgentTaskEvidenceFact {
        let fingerprinted = kind == .independentCheck || kind == .reviewerOutcome
        return AgentTaskEvidenceFact(
            kind: kind,
            runID: runID,
            processGeneration: generation,
            trust: .verified,
            result: result,
            observedAt: at,
            codeState: codeState,
            environment: environment,
            sourceSequence: sequence,
            preOperationCodeState: fingerprinted ? codeState : nil,
            postOperationCodeState: fingerprinted ? codeState : nil
        )
    }

    /// A live run admitted to logical settlement.
    private func admitSettlement(
        _ task: inout AgentTask,
        at settledAt: Date,
        sequence: UInt64? = nil,
        turn: String = "turn-1"
    ) throws -> AgentTaskLogicalSettlementAdmission {
        let run = try #require(task.runs.last)
        return AgentTaskLifecycleReducer.admitLogicalSettlement(
            AgentTaskLogicalSettlement(
                settledAt: settledAt,
                processGeneration: run.process.processGeneration,
                sourceSequence: sequence,
                turn: turn
            ),
            task: &task,
            runID: run.id
        )
    }

    /// A live task settled with a fully evidenced verified success.
    private func verifiedLiveSettledTask(
        seed: Int,
        codeState cs: AgentTaskCodeStateIdentity,
        environment env: AgentTaskEnvironmentIdentity,
        now: Date,
        projectPath: String?
    ) throws -> AgentTask {
        var task = liveTask(seed: seed, now: now, projectPath: projectPath)
        let run = try #require(task.runs.last)
        let generation = run.process.processGeneration
        task.evidence.append(fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: generation,
            result: .reported,
            at: now.addingTimeInterval(1),
            codeState: cs,
            environment: env,
            sequence: 1
        ))
        task.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: generation,
            result: .succeeded,
            at: now.addingTimeInterval(2),
            codeState: cs,
            environment: env,
            sequence: 2
        ))
        task.evidence.append(fact(
            .reviewerOutcome,
            runID: run.id,
            generation: generation,
            result: .succeeded,
            at: now.addingTimeInterval(3),
            codeState: cs,
            environment: env,
            sequence: 3
        ))
        #expect(try admitSettlement(&task, at: now.addingTimeInterval(10), sequence: 3)
            == .accepted)
        return task
    }

    // MARK: - Live settled results

    @Test("a live run settles unverified without a completion claim and never Ready")
    func liveRunSettlesUnverified() throws {
        var task = liveTask(seed: 1)
        let run = try #require(task.runs.last)
        let t = run.lastObservedAt.addingTimeInterval(10)
        #expect(try admitSettlement(&task, at: t) == .accepted)

        let settled = try #require(task.runs.last)
        #expect(settled.logicalSettlement?.settledAt == t)
        // No fabricated physical termination: the process stays live.
        #expect(settled.liveness == .live)
        #expect(settled.endedAt == nil)
        // No fabricated process completion: the attempt has no facts.
        #expect(task.evidence.isEmpty)
        #expect(settled.outcome == .unverified)
        #expect(AgentTaskLifecycleReducer.isSettled(settled))
        #expect(task.lifecycle == .paused)
        #expect(task.attention == .none)
        #expect(task.completedAt == nil)
        #expect(task.verificationState == .none)
        #expect(task.executionState == .idle)
        #expect(!task.isUnread)

        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task, codeState: nil, environment: nil
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.unverifiedOutcome))
    }

    @Test("a live run settles verified success and is Ready while its process stays live")
    func liveRunSettlesVerifiedSuccess() throws {
        let cs = codeState("a")
        let task = try verifiedLiveSettledTask(
            seed: 2, codeState: cs, environment: environment,
            now: Date(timeIntervalSince1970: 1_000), projectPath: nil
        )
        let settled = try #require(task.runs.last)
        let logical = try #require(settled.logicalSettlement)
        #expect(logical.settledAt == Date(timeIntervalSince1970: 1_010))
        #expect(settled.liveness == .live)
        #expect(settled.endedAt == nil)
        #expect(settled.outcome == .success)
        #expect(task.evidence.map(\.kind)
            == [.agentReportedCompletion, .independentCheck, .reviewerOutcome])
        // The original logical timestamp, not the last observation, is
        // the completion time.
        #expect(task.completedAt == logical.settledAt)
        #expect(task.completedAt != settled.lastObservedAt)
        #expect(task.lifecycle == .completed)
        #expect(task.attention == .completed)
        #expect(task.isUnread)
        #expect(task.verificationState == .verified)
        #expect(task.reviewedSnapshot != nil)
        #expect(task.executionState == .idle)

        // Ready from current required evidence while the process is live.
        #expect(AgentTaskLifecycleReducer.readiness(
            for: task, codeState: cs, environment: environment
        ).isReady)
        // Without the current identities there is no Ready.
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: task, codeState: nil, environment: nil
        ).isReady)
    }

    @Test("a live unsettled run is never settled and never Ready")
    func liveUnsettledRunIsNotReady() throws {
        let task = liveTask(seed: 3)
        let run = try #require(task.runs.last)
        #expect(!AgentTaskLifecycleReducer.isSettled(run))
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task, codeState: nil, environment: nil
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps == [.attemptInProgress])
    }

    @Test("a settlement without required evidence never settles success")
    func settlementWithoutEvidenceNeverSucceeds() throws {
        let cs = codeState("a")
        var task = liveTask(seed: 4)
        let run = try #require(task.runs.last)
        let generation = run.process.processGeneration
        let now = run.lastObservedAt
        // A claim alone is a claim, not a result.
        task.evidence.append(fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: generation,
            result: .reported,
            at: now.addingTimeInterval(1),
            codeState: cs,
            environment: environment,
            sequence: 1
        ))
        #expect(try admitSettlement(&task, at: now.addingTimeInterval(10), sequence: 1)
            == .accepted)
        #expect(task.runs.last?.outcome == .unverified)
        #expect(task.lifecycle == .paused)
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: task, codeState: cs, environment: environment
        ).isReady)

        // Claim plus one passing check still lacks the review.
        var incomplete = task
        incomplete.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: generation,
            result: .succeeded,
            at: now.addingTimeInterval(2),
            codeState: cs,
            environment: environment,
            sequence: 2
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &incomplete, runIndex: 0)
        #expect(incomplete.runs.last?.outcome == .unverified)
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: incomplete, codeState: cs, environment: environment
        ).isReady)
    }

    @Test("a logically settled live run presents idle even while the detector says working")
    func settledLiveRunPresentsIdle() throws {
        var task = liveTask(seed: 5, state: .executing)
        let run = try #require(task.runs.last)
        #expect(task.executionState == .working)
        #expect(try admitSettlement(
            &task, at: run.lastObservedAt.addingTimeInterval(10)
        ) == .accepted)
        #expect(task.executionState == .idle)
    }

    // MARK: - Authority fencing

    @Test("stale and foreign settlement authority is fenced")
    func settlementAuthorityIsFenced() throws {
        var task = liveTask(seed: 6)
        let run = try #require(task.runs.last)
        let generation = run.process.processGeneration
        let t = run.lastObservedAt.addingTimeInterval(10)

        let runGeneration = generation
        func claim(
            at settledAt: Date = t,
            generation: UInt64? = nil,
            sequence: UInt64? = nil,
            turn: String = "turn-1"
        ) -> AgentTaskLogicalSettlement {
            AgentTaskLogicalSettlement(
                settledAt: settledAt,
                processGeneration: generation ?? runGeneration,
                sourceSequence: sequence,
                turn: turn
            )
        }
        func admit(
            _ settlement: AgentTaskLogicalSettlement,
            runID: UUID = run.id
        ) -> AgentTaskLogicalSettlementAdmission {
            AgentTaskLifecycleReducer.admitLogicalSettlement(
                settlement, task: &task, runID: runID
            )
        }

        // Unknown run.
        #expect(admit(claim(), runID: UUID()) == .fencedOut(.unknownRun))
        // Foreign process incarnation.
        #expect(admit(claim(generation: generation + 1))
            == .fencedOut(.foreignProcess))
        // A timestamp-shaped claim without the turn's identity or the
        // run's incarnation is invalid, never a success authority.
        #expect(admit(claim(turn: "")) == .fencedOut(.invalidClaim))
        #expect(admit(claim(turn: String(repeating: "t", count: 257)))
            == .fencedOut(.invalidClaim))
        #expect(admit(claim(turn: "turn\0")) == .fencedOut(.invalidClaim))
        #expect(admit(claim(generation: 0)) == .fencedOut(.invalidClaim))
        #expect(admit(claim(sequence: 0)) == .fencedOut(.invalidClaim))
        #expect(admit(claim(at: run.startedAt.addingTimeInterval(-1)))
            == .fencedOut(.invalidClaim))
        // Fencing leaves the task untouched.
        #expect(task.runs.last?.logicalSettlement == nil)
        #expect(task.runs.last?.outcome == nil)

        // Stale source: a newer event was already observed on the run's
        // ordered delivery, so the older closure replay is fenced.
        task.evidence.append(fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: generation,
            result: .reported,
            at: run.lastObservedAt.addingTimeInterval(1),
            sequence: 5
        ))
        #expect(admit(claim(sequence: 3)) == .fencedOut(.staleSource))
        // An unordered claim (no source position) cannot be current once
        // the run's delivery has documented an ordered source.
        #expect(admit(claim()) == .fencedOut(.staleSource))
        #expect(task.runs.last?.logicalSettlement == nil)
        // A current source position admits.
        #expect(admit(claim(sequence: 5)) == .accepted)
        #expect(task.runs.last?.logicalSettlement != nil)
        // A second settlement (any turn) is fenced: one closure per run.
        #expect(admit(claim(at: t.addingTimeInterval(1), turn: "turn-2"))
            == .fencedOut(.alreadySettled))

        // A claim against a superseded (older) attempt is fenced.
        var twoRun = liveTask(seed: 61)
        let older = try #require(twoRun.runs.last)
        twoRun.runs.append(liveRun(seed: 62, now: older.lastObservedAt.addingTimeInterval(200)))
        #expect(
            AgentTaskLifecycleReducer.admitLogicalSettlement(
                AgentTaskLogicalSettlement(
                    settledAt: t,
                    processGeneration: older.process.processGeneration,
                    sourceSequence: nil,
                    turn: "turn-1"
                ),
                task: &twoRun,
                runID: older.id
            ) == .fencedOut(.supersededRun)
        )

        // A stale (channel-lost) run can no longer prove its own closure.
        var staleTask = liveTask(seed: 63)
        staleTask.runs[0].liveness = .stale
        let staleRun = try #require(staleTask.runs.last)
        #expect(
            AgentTaskLifecycleReducer.admitLogicalSettlement(
                AgentTaskLogicalSettlement(
                    settledAt: t,
                    processGeneration: staleRun.process.processGeneration,
                    sourceSequence: nil,
                    turn: "turn-1"
                ),
                task: &staleTask,
                runID: staleRun.id
            ) == .fencedOut(.notLive)
        )

        // A terminated run is already settled by its legacy basis.
        let terminated = settledTask(seed: 64)
        let terminatedRun = try #require(terminated.runs.last)
        var terminatedTask = terminated
        #expect(
            AgentTaskLifecycleReducer.admitLogicalSettlement(
                AgentTaskLogicalSettlement(
                    settledAt: terminatedRun.lastObservedAt.addingTimeInterval(10),
                    processGeneration: terminatedRun.process.processGeneration,
                    sourceSequence: nil,
                    turn: "turn-1"
                ),
                task: &terminatedTask,
                runID: terminatedRun.id
            ) == .fencedOut(.alreadySettled)
        )
        #expect(terminatedTask.runs.last?.logicalSettlement == nil)
    }

    // MARK: - Cancellation

    @Test("cancellation dominates a late success on a live settled run")
    func cancellationDominatesLateSuccess() throws {
        let cs = codeState("a")
        var task = liveTask(seed: 7)
        let run = try #require(task.runs.last)
        let generation = run.process.processGeneration
        let now = run.lastObservedAt
        let cancellation = fact(
            .userCancellation,
            runID: run.id,
            generation: generation,
            result: .cancelled,
            at: now.addingTimeInterval(1)
        )
        #expect(AgentTaskLifecycleReducer.admit(cancellation, into: task)
            == .accepted)
        task.evidence.append(cancellation)
        #expect(try admitSettlement(&task, at: now.addingTimeInterval(10))
            == .accepted)
        #expect(task.runs.last?.outcome == .cancellation)
        #expect(task.lifecycle == .paused)
        #expect(task.attention == .none)
        #expect(task.completedAt == nil)

        // Late success evidence re-settles the attempt: cancellation stays.
        for (offset, kind, result, sequence) in [
            (2, AgentTaskEvidenceKind.agentReportedCompletion, AgentTaskEvidenceResult.reported, UInt64(2)),
            (3, .independentCheck, .succeeded, UInt64(3)),
            (4, .reviewerOutcome, .succeeded, UInt64(4))
        ] {
            let late = fact(
                kind,
                runID: run.id,
                generation: generation,
                result: result,
                at: now.addingTimeInterval(TimeInterval(offset)),
                codeState: cs,
                environment: environment,
                sequence: sequence
            )
            #expect(AgentTaskLifecycleReducer.admit(late, into: task) == .accepted)
            task.evidence.append(late)
        }
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .cancellation)
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task, codeState: cs, environment: environment
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.cancelledAttempt))
    }

    // MARK: - Registry: idle refresh and later physical exit

    @Test("idle refresh preserves live ownership and settled attention; physical exit preserves the logical timestamp")
    func idleRefreshAndPhysicalExit() async throws {
        let fixture = try LSPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        // Millisecond-exact so persistence round trips compare equal.
        let t0 = Date(
            timeIntervalSince1970:
                (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000
        )
        let route = AgentTaskRoute(
            paneID: uuid(201),
            tabID: uuid(201 + 100),
            terminalID: uuid(201 + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: t0
        )
        let session = ADESessionFixture.make(
            pid: 2_0101, generation: 7, observedAt: t0
        )
        session.recordLifecycleState(.done, accuracy: .verifiedLifecycleTransitions)
        registry.bridge(session, replacing: nil, context: context)
        let taskID = try #require(registry.taskID(forSessionID: session.id))
        let bridged = try #require(registry.task(for: taskID))
        let run = try #require(bridged.runs.last)
        let cs = codeState("a")

        for (offset, kind, result, sequence) in [
            (1, AgentTaskEvidenceKind.agentReportedCompletion, AgentTaskEvidenceResult.reported, UInt64(1)),
            (2, .independentCheck, .succeeded, UInt64(2)),
            (3, .reviewerOutcome, .succeeded, UInt64(3))
        ] {
            let evidence = fact(
                kind,
                runID: run.id,
                generation: run.process.processGeneration,
                result: result,
                at: t0.addingTimeInterval(TimeInterval(offset)),
                codeState: cs,
                environment: environment,
                sequence: sequence
            )
            #expect(registry.recordEvidence(evidence, taskID: taskID) == .accepted)
        }
        let settledAt = t0.addingTimeInterval(10)
        let settlement = AgentTaskLogicalSettlement(
            settledAt: settledAt,
            processGeneration: run.process.processGeneration,
            sourceSequence: 3,
            turn: "turn-201"
        )
        #expect(registry.recordLogicalSettlement(settlement, taskID: taskID, runID: run.id)
            == .accepted)

        let settled = try #require(registry.task(for: taskID))
        #expect(settled.runs.last?.outcome == .success)
        #expect(settled.runs.last?.liveness == .live)
        #expect(settled.runs.last?.endedAt == nil)
        #expect(settled.lifecycle == .completed)
        #expect(settled.attention == .completed)
        #expect(settled.completedAt == settledAt)
        #expect(settled.executionState == .idle)
        #expect(registry.isExactLiveOwner(
            taskID: taskID, terminalID: route.terminalID, runID: run.id
        ))

        // Idle observation: the detector sees the live process go quiet.
        // Settled attention and live ownership survive the poll.
        session.recordLifecycleState(.idle, accuracy: .verifiedLifecycleTransitions)
        registry.refresh(sessions: [session])
        let idle = try #require(registry.task(for: taskID))
        #expect(idle.attention == .completed)
        #expect(idle.runs.last?.liveness == .live)
        #expect(idle.runs.last?.outcome == .success)
        #expect(idle.runs.last?.endedAt == nil)
        #expect(idle.completedAt == settledAt)
        #expect(idle.executionState == .idle)
        #expect(registry.isExactLiveOwner(
            taskID: taskID, terminalID: route.terminalID, runID: run.id
        ))
        #expect(await registry.flushPersistence() == .saved)

        // Later physical exit: the process really terminates. The
        // observed exit is recorded honestly, but the original logical
        // timestamp stays the completion time.
        let exitAt = t0.addingTimeInterval(100)
        registry.markTerminalClosed(
            terminalID: route.terminalID, project: identity, at: exitAt
        )
        let exited = try #require(registry.historicalTask(forSessionID: session.id))
        let exitedRun = try #require(exited.runs.last)
        #expect(exitedRun.liveness == .terminated)
        #expect(exitedRun.endedAt == exitAt)
        #expect(exitedRun.outcome == .success)
        #expect(exitedRun.logicalSettlement?.settledAt == settledAt)
        #expect(exited.completedAt == settledAt)
        #expect(exited.attention == .completed)
        #expect(exited.lifecycle == .completed)
        #expect(exited.evidence.contains {
            $0.kind == .processCompletion && $0.observedAt == exitAt
        })
        #expect(!registry.isExactLiveOwner(
            taskID: taskID, terminalID: route.terminalID, runID: run.id
        ))
        #expect(await registry.flushPersistence() == .saved)
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.first?.completedAt == settledAt)
        #expect(loaded.tasks.first?.runs.last?.logicalSettlement?.turn == "turn-201")
    }

    @Test("detector unavailability preserves settled attention on a logically settled run")
    func evidenceUnavailablePreservesSettledAttention() async throws {
        let fixture = try LSPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        // Millisecond-exact so persistence round trips compare equal.
        let t0 = Date(
            timeIntervalSince1970:
                (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000
        )
        let route = AgentTaskRoute(
            paneID: uuid(202),
            tabID: uuid(202 + 100),
            terminalID: uuid(202 + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: t0
        )
        let session = ADESessionFixture.make(
            pid: 2_0202, generation: 8, observedAt: t0
        )
        session.recordLifecycleState(.done, accuracy: .verifiedLifecycleTransitions)
        registry.bridge(session, replacing: nil, context: context)
        let taskID = try #require(registry.taskID(forSessionID: session.id))
        let bridged = try #require(registry.task(for: taskID))
        let run = try #require(bridged.runs.last)
        #expect(registry.recordLogicalSettlement(
            AgentTaskLogicalSettlement(
                settledAt: t0.addingTimeInterval(10),
                processGeneration: run.process.processGeneration,
                sourceSequence: nil,
                turn: "turn-202"
            ),
            taskID: taskID,
            runID: run.id
        ) == .accepted)
        // No completion claim: an unverified settled outcome with outcome
        // attention none, but the run is settled while live.
        #expect(registry.task(for: taskID)?.runs.last?.outcome == .unverified)

        // A verified success keeps its attention through detector loss.
        let cs = codeState("a")
        for (offset, kind, result, sequence) in [
            (1, AgentTaskEvidenceKind.agentReportedCompletion, AgentTaskEvidenceResult.reported, UInt64(1)),
            (2, .independentCheck, .succeeded, UInt64(2)),
            (3, .reviewerOutcome, .succeeded, UInt64(3))
        ] {
            let evidence = fact(
                kind,
                runID: run.id,
                generation: run.process.processGeneration,
                result: result,
                at: t0.addingTimeInterval(TimeInterval(offset)),
                codeState: cs,
                environment: environment,
                sequence: sequence
            )
            #expect(registry.recordEvidence(evidence, taskID: taskID) == .accepted)
        }
        let verified = try #require(registry.task(for: taskID))
        #expect(verified.runs.last?.outcome == .success)
        #expect(verified.attention == .completed)

        registry.markEvidenceUnavailable(sessionIDs: [session.id])
        let stale = try #require(registry.task(for: taskID))
        #expect(stale.runs.last?.liveness == .stale)
        #expect(stale.runs.last?.endedAt == nil)
        #expect(stale.attention == .completed)
        #expect(stale.runs.last?.outcome == .success)
        #expect(stale.lifecycle == .completed)
        #expect(stale.executionState == .unknown)
        #expect(await registry.flushPersistence() == .saved)
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.first?.attention == .completed)
    }

    @Test("a terminal replacement after logical settlement stays saveable")
    func replacementAfterLogicalSettlementStaysSaveable() async throws {
        let fixture = try LSPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        let t0 = Date(
            timeIntervalSince1970:
                (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000
        )
        let route = AgentTaskRoute(
            paneID: uuid(204),
            tabID: uuid(204 + 100),
            terminalID: uuid(204 + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: t0
        )
        let session = ADESessionFixture.make(
            pid: 2_0401, generation: 9, observedAt: t0
        )
        session.recordLifecycleState(.done, accuracy: .verifiedLifecycleTransitions)
        registry.bridge(session, replacing: nil, context: context)
        let taskID = try #require(registry.taskID(forSessionID: session.id))
        let bridged = try #require(registry.task(for: taskID))
        let run = try #require(bridged.runs.last)
        let cs = codeState("a")

        for (offset, kind, result, sequence) in [
            (1, AgentTaskEvidenceKind.agentReportedCompletion, AgentTaskEvidenceResult.reported, UInt64(1)),
            (2, .independentCheck, .succeeded, UInt64(2)),
            (3, .reviewerOutcome, .succeeded, UInt64(3))
        ] {
            let evidence = fact(
                kind,
                runID: run.id,
                generation: run.process.processGeneration,
                result: result,
                at: t0.addingTimeInterval(TimeInterval(offset)),
                codeState: cs,
                environment: environment,
                sequence: sequence
            )
            #expect(registry.recordEvidence(evidence, taskID: taskID) == .accepted)
        }
        let settledAt = t0.addingTimeInterval(10)
        #expect(registry.recordLogicalSettlement(
            AgentTaskLogicalSettlement(
                settledAt: settledAt,
                processGeneration: run.process.processGeneration,
                sourceSequence: 3,
                turn: "turn-204"
            ),
            taskID: taskID,
            runID: run.id
        ) == .accepted)
        let settled = try #require(registry.task(for: taskID))
        #expect(settled.lifecycle == .completed)
        #expect(settled.completedAt == settledAt)
        #expect(await registry.flushPersistence() == .saved)

        // A new agent process takes over the same terminal: the bridge
        // detaches the settled run through endRun and bridges the
        // replacement as a new task.
        let replacementAt = t0.addingTimeInterval(500)
        let replacement = ADESessionFixture.make(
            pid: 2_0402, generation: 10, observedAt: replacementAt
        )
        replacement.recordLifecycleState(
            .executing, accuracy: .verifiedLifecycleTransitions
        )
        registry.bridge(
            replacement,
            replacing: session,
            context: AgentTaskBridgeContext(
                project: identity,
                route: route,
                origin: .discoveredInTerminal,
                observedAt: replacementAt
            )
        )

        // The detached task keeps the settled outcome as history, but the
        // completed triple is cleared: .paused plus a non-nil completedAt
        // is unsaveable (#1756, #1795).
        let detached = try #require(registry.task(for: taskID))
        let oldRun = try #require(detached.runs.first)
        #expect(oldRun.outcome == .success)
        #expect(oldRun.logicalSettlement?.turn == "turn-204")
        #expect(oldRun.liveness == .terminated)
        #expect(detached.completedAt == nil)
        #expect(detached.lifecycle != .completed)

        #expect(await registry.flushPersistence() == .saved)
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.first { $0.id == taskID }?.completedAt == nil)
    }

    // MARK: - Persistence

    @Test("logical settlement persists as schema v5 and round-trips")
    func logicalSettlementRoundTrip() async throws {
        let fixture = try LSPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let now = Date(timeIntervalSince1970: 3_000_000)
        let task = try verifiedLiveSettledTask(
            seed: 10,
            codeState: codeState("a"),
            environment: environment,
            now: now,
            projectPath: fixture.project.path
        )
        #expect(await store.save(tasks: [task], project: identity)
            == .saved(taskCount: 1))
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity, storageRoot: fixture.storage
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file))
                as? [String: Any]
        )
        #expect(root["schemaVersion"] as? Int == 5)
        let runs = try #require(
            (root["tasks"] as? [[String: Any]])?.first?["runs"] as? [[String: Any]]
        )
        #expect(runs.first?["logicalSettlement"] != nil)
        #expect(runs.first?["liveness"] as? String == "live")
        #expect(runs.first?["endedAt"] == nil)

        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks == [persistableCopy(task)])
    }

    @Test("a live settled unverified result persists and round-trips")
    func liveSettledUnverifiedPersists() async throws {
        let fixture = try LSPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        var task = liveTask(
            seed: 11,
            now: Date(timeIntervalSince1970: 3_000_000),
            projectPath: fixture.project.path
        )
        let run = try #require(task.runs.last)
        #expect(try admitSettlement(&task, at: run.lastObservedAt.addingTimeInterval(10))
            == .accepted)
        #expect(await store.save(tasks: [task], project: identity)
            == .saved(taskCount: 1))
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks == [persistableCopy(task)])
        #expect(loaded.tasks.first?.runs.last?.logicalSettlement != nil)
        #expect(loaded.tasks.first?.runs.last?.outcome == .unverified)
    }

    @Test("ordinary and legacy payloads without logical settlement stay schema v3")
    func ordinaryPayloadsStaySchemaV3() async throws {
        let fixture = try LSPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let task = settledTask(
            seed: 12,
            now: Date(timeIntervalSince1970: 3_000_000),
            projectPath: fixture.project.path
        )
        #expect(task.runs.last?.logicalSettlement == nil)
        #expect(await store.save(tasks: [task], project: identity)
            == .saved(taskCount: 1))
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity, storageRoot: fixture.storage
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file))
                as? [String: Any]
        )
        #expect(root["schemaVersion"] as? Int == 3)
        let runs = try #require(
            (root["tasks"] as? [[String: Any]])?.first?["runs"] as? [[String: Any]]
        )
        #expect(runs.first?["logicalSettlement"] == nil)
        // Old payloads decode additively without the field.
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks == [persistableCopy(task)])
        #expect(loaded.tasks.first?.runs.last?.logicalSettlement == nil)
    }

    @Test("invalid logical settlement metadata is rejected")
    func invalidLogicalSettlementRejected() async throws {
        let fixture = try LSPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let now = Date(timeIntervalSince1970: 3_000_000)
        let good = try verifiedLiveSettledTask(
            seed: 13,
            codeState: codeState("a"),
            environment: environment,
            now: now,
            projectPath: fixture.project.path
        )
        let run = try #require(good.runs.last)
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity, storageRoot: fixture.storage
        )

        func settleMutation(_ mutate: (inout [String: Any]) throws -> Void) async throws {
            #expect(
                await store.save(tasks: [good], project: identity)
                    == .saved(taskCount: 1)
            )
            try mutateRun(at: file) { run in
                guard var settlement = run["logicalSettlement"] as? [String: Any] else {
                    return
                }
                try mutate(&settlement)
                run["logicalSettlement"] = settlement
            }
            let loaded = await store.load(project: identity)
            #expect(loaded.status == .rejected(.invalidMetadata))
        }

        // Outcome on a live run loses its only settlement basis.
        #expect(await store.save(tasks: [good], project: identity)
            == .saved(taskCount: 1))
        try mutateRun(at: file) { run in
            run["logicalSettlement"] = nil
        }
        let basisless = await store.load(project: identity)
        #expect(basisless.status == .rejected(.invalidMetadata))

        // Authority mismatches are rejected fail-closed.
        try await settleMutation { $0["processGeneration"] = run.process.processGeneration + 1 }
        try await settleMutation { $0["scheme"] = 99 }
        try await settleMutation { $0["turn"] = "" }
        try await settleMutation { $0["turn"] = String(repeating: "t", count: 300) }
        try await settleMutation { $0["sourceSequence"] = 0 }
        try await settleMutation {
            let settledAt = try #require($0["settledAt"] as? Double)
            // 311 s: before the run's start (300 s before `now`), so this
            // is not a settlement of this attempt.
            $0["settledAt"] = settledAt - 311_000
        }

        // A logically settled run that later exits physically stays loadable.
        #expect(await store.save(tasks: [good], project: identity)
            == .saved(taskCount: 1))
        try mutateRun(at: file) { run in
            run["liveness"] = "terminated"
            run["endedAt"] = run["lastObservedAt"]
        }
        let exited = await store.load(project: identity)
        #expect(exited.status == .loaded)
        #expect(exited.tasks.first?.runs.last?.logicalSettlement != nil)
        #expect(exited.tasks.first?.runs.last?.outcome == .success)

        // A v3 file may not carry a logical settlement: the field requires
        // the current schema, so older readers reject instead of shed it.
        #expect(await store.save(tasks: [good], project: identity)
            == .saved(taskCount: 1))
        try mutateRoot(at: file) { $0["schemaVersion"] = 3 }
        let downgraded = await store.load(project: identity)
        #expect(downgraded.status == .rejected(.invalidMetadata))
    }

    // MARK: - Restore

    @Test("restore preserves settlement history, starts nothing, and invalidates current evidence")
    func restorePreservesHistoryAndInvalidatesEvidence() async throws {
        let fixture = try LSPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let writerStore = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let writer = AgentTaskRegistry(persistence: writerStore)
        writer.registerProject(identity)
        #expect(await writer.flushPersistence() == .saved)

        // Millisecond-exact so persistence round trips compare equal.
        let t0 = Date(
            timeIntervalSince1970:
                (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000
        )
        let route = AgentTaskRoute(
            paneID: uuid(203),
            tabID: uuid(203 + 100),
            terminalID: uuid(203 + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: t0
        )
        let session = ADESessionFixture.make(
            pid: 2_0303, generation: 9, observedAt: t0
        )
        session.recordLifecycleState(.done, accuracy: .verifiedLifecycleTransitions)
        writer.bridge(session, replacing: nil, context: context)
        let taskID = try #require(writer.taskID(forSessionID: session.id))
        let bridged = try #require(writer.task(for: taskID))
        let run = try #require(bridged.runs.last)
        let cs = codeState("a")

        for (offset, kind, result, sequence) in [
            (1, AgentTaskEvidenceKind.agentReportedCompletion, AgentTaskEvidenceResult.reported, UInt64(1)),
            (2, .independentCheck, .succeeded, UInt64(2)),
            (3, .reviewerOutcome, .succeeded, UInt64(3))
        ] {
            let evidence = fact(
                kind,
                runID: run.id,
                generation: run.process.processGeneration,
                result: result,
                at: t0.addingTimeInterval(TimeInterval(offset)),
                codeState: cs,
                environment: environment,
                sequence: sequence
            )
            #expect(writer.recordEvidence(evidence, taskID: taskID) == .accepted)
        }
        let settledAt = t0.addingTimeInterval(10)
        #expect(writer.recordLogicalSettlement(
            AgentTaskLogicalSettlement(
                settledAt: settledAt,
                processGeneration: run.process.processGeneration,
                sourceSequence: 3,
                turn: "turn-203"
            ),
            taskID: taskID,
            runID: run.id
        ) == .accepted)
        #expect(writer.recordUserAcceptance(
            taskID: taskID, codeState: cs, environment: environment,
            at: settledAt.addingTimeInterval(1)
        ) == true)
        #expect(await writer.flushPersistence() == .saved)

        // Relaunch: a fresh registry over the same durable storage.
        let readerStore = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let reader = AgentTaskRegistry(persistence: readerStore)
        #expect(await reader.prepareDurableWork(in: identity))
        let restored = try #require(reader.task(for: taskID))
        let restoredRun = try #require(restored.runs.last)

        // History is preserved.
        #expect(restoredRun.logicalSettlement?.turn == "turn-203")
        #expect(restoredRun.logicalSettlement?.settledAt == settledAt)
        #expect(restoredRun.outcome == .success)
        #expect(restored.lifecycle == .completed)
        #expect(restored.completedAt == settledAt)
        #expect(restored.attention == .completed)
        #expect(restored.reviewedSnapshot != nil)
        #expect(restored.evidence.count == 4) // claim, check, review, acceptance

        // Live evidence is stale, nothing starts, nothing is resumable.
        #expect(restoredRun.liveness == .stale)
        #expect(restoredRun.endedAt == nil)
        #expect(restored.executionState == .unknown)
        #expect(restored.route.availability == .missing)
        #expect(restored.runs.count == 1)
        #expect(!reader.canResumeTask(taskID))
        #expect(!reader.readiness(
            for: taskID, codeState: cs, environment: environment
        ).isReady)

        // Current evidence and acceptance are invalidated.
        #expect(restored.verificationState == .stale)
        #expect(restored.acceptanceState == .notAccepted)
    }

    /// The store deliberately does not persist the volatile PID and
    /// start-identity fields (they decode back to nil/false); normalize
    /// them before a deep round-trip equality.
    private func persistableCopy(_ task: AgentTask) -> AgentTask {
        var copy = task
        for index in copy.runs.indices {
            copy.runs[index].process = AgentProcessEvidence(
                processIdentifier: nil,
                processGeneration: copy.runs[index].process.processGeneration,
                startIdentifier: nil,
                observedStartedAt: copy.runs[index].process.observedStartedAt,
                startIsAuthoritative: false
            )
        }
        return copy
    }

    // MARK: - JSON mutation helpers

    private func mutateRun(
        at fileURL: URL,
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws {
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any]
        )
        var tasks = try #require(root["tasks"] as? [[String: Any]])
        var runs = try #require(tasks[0]["runs"] as? [[String: Any]])
        try mutate(&runs[0])
        runs[0] = runs[0]
        tasks[0]["runs"] = runs
        root["tasks"] = tasks
        try writeRoot(root, at: fileURL)
    }

    private func mutateRoot(
        at fileURL: URL,
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws {
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any]
        )
        try mutate(&root)
        try writeRoot(root, at: fileURL)
    }

    private func writeRoot(_ root: [String: Any], at fileURL: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

// MARK: - Persistence fixture

private final class LSPersistenceFixture {
    let root: URL
    let project: URL
    let storage: URL

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PineLS-\(UUID().uuidString)")
        project = root.appendingPathComponent("project", isDirectory: true)
        storage = root.appendingPathComponent("storage", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-N", root.path]
            let output = try runProcessBounded(
                chmod,
                commandDescription: "chmod -N \(root.path)"
            )
            guard output.terminationStatus == 0 else {
                try? fileManager.removeItem(at: root)
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.createDirectory(
                at: project,
                withIntermediateDirectories: false
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
