//
//  AgentTaskContinuationTests.swift
//  PineTests
//
//  ADE same-task continuation contract (issue #1756): the transition table,
//  the revision transition, candidate generations, idempotent submission,
//  old-attempt event fencing, relaunch/crash recovery, and the #1755
//  automatic-correction boundary.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("ADE same-task continuation", .serialized)
struct AgentTaskContinuationTests {
    // MARK: - Fixtures

    private enum FixtureError: Error {
        case reservationRejected
    }

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

    private func environment(_ osBuild: String, _ fingerprint: Character)
        -> AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(
            osBuild: osBuild,
            toolchain: "Xcode 27.0",
            configurationFingerprint: hex(fingerprint)
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

    private func makeRunInput(
        seed: Int,
        state: AgentRunState = .done,
        liveness: AgentRunLiveness = .terminated,
        now: Date
    ) -> AgentTaskRunInput {
        AgentTaskRunInput(
            id: uuid(seed + 200),
            terminalID: uuid(seed + 100),
            process: AgentProcessEvidence(
                processIdentifier: Int32(5_000 + seed),
                processGeneration: UInt64(seed),
                startIdentifier: "continuation-\(seed)",
                observedStartedAt: now.addingTimeInterval(-300),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: liveness,
                observedAt: now
            ),
            lifecycleAccuracy: .processTerminationOnly
        )
    }

    private func makeTask(
        seed: Int,
        state: AgentRunState = .done,
        liveness: AgentRunLiveness = .terminated,
        outcome: AgentTaskOutcome? = nil,
        now: Date = Date(),
        projectPath: String? = nil
    ) -> AgentTask {
        let context = AgentTaskBridgeContext(
            project: project(projectPath ?? "/tmp/pine-continuation-\(seed)"),
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: uuid(seed + 100),
                terminalID: uuid(seed + 100),
                availability: liveness == .live ? .available : .missing
            ),
            origin: .discoveredInTerminal,
            observedAt: now
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context,
            title: "Draft the release notes",
            objective: "Write the release notes draft"
        )
        var run = AgentTaskRun(makeRunInput(
            seed: seed,
            state: state,
            liveness: liveness,
            now: now
        ))
        run.outcome = outcome
        task.runs = [run]
        task.lifecycle = liveness == .terminated ? .paused : .active
        task.updatedAt = now
        task.lastActivityAt = now
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        return task
    }

    private func fact(
        _ kind: AgentTaskEvidenceKind,
        runID: UUID,
        generation: UInt64,
        result: AgentTaskEvidenceResult,
        at: Date,
        trust: TrustLevel = .verified,
        codeState: AgentTaskCodeStateIdentity? = nil,
        environment: AgentTaskEnvironmentIdentity? = nil,
        sequence: UInt64? = nil,
        pre: AgentTaskCodeStateIdentity? = nil,
        post: AgentTaskCodeStateIdentity? = nil
    ) -> AgentTaskEvidenceFact {
        AgentTaskEvidenceFact(
            kind: kind,
            runID: runID,
            processGeneration: generation,
            trust: trust,
            result: result,
            observedAt: at,
            codeState: codeState,
            environment: environment,
            sourceSequence: sequence,
            preOperationCodeState: pre,
            postOperationCodeState: post
        )
    }

    /// A settled (terminated, outcome recorded, process-completion fact
    /// bound) task, as production settlement produces it.
    private func settledTask(
        seed: Int,
        now: Date = Date(),
        projectPath: String? = nil
    ) -> AgentTask {
        var task = makeTask(
            seed: seed,
            now: now,
            projectPath: projectPath
        )
        AgentTaskLifecycleReducer.settleTerminated(task: &task, runIndex: 0)
        return task
    }

    /// A verified-success (Ready) task: claim plus passing check and review
    /// bound to one shared code-state identity and environment.
    private func verifiedSuccessTask(
        seed: Int,
        codeState cs: AgentTaskCodeStateIdentity,
        environment env: AgentTaskEnvironmentIdentity,
        now: Date = Date(),
        projectPath: String? = nil
    ) throws -> AgentTask {
        var task = settledTask(seed: seed, now: now, projectPath: projectPath)
        let run = try #require(task.runs.first)
        let t = now
        task.evidence.append(fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: UInt64(seed),
            result: .reported,
            at: t,
            codeState: cs,
            environment: env,
            sequence: 1
        ))
        task.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: UInt64(seed),
            result: .succeeded,
            at: t.addingTimeInterval(1),
            codeState: cs,
            environment: env,
            sequence: 2,
            pre: cs,
            post: cs
        ))
        task.evidence.append(fact(
            .reviewerOutcome,
            runID: run.id,
            generation: UInt64(seed),
            result: .succeeded,
            at: t.addingTimeInterval(2),
            codeState: cs,
            environment: env,
            sequence: 3,
            pre: cs,
            post: cs
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        return task
    }

    /// A Ready task with current user acceptance.
    private func acceptedTask(
        seed: Int,
        codeState cs: AgentTaskCodeStateIdentity,
        environment env: AgentTaskEnvironmentIdentity,
        now: Date = Date()
    ) throws -> AgentTask {
        var task = try verifiedSuccessTask(
            seed: seed,
            codeState: cs,
            environment: env,
            now: now
        )
        let run = try #require(task.runs.first)
        task.evidence.append(fact(
            .userAcceptance,
            runID: run.id,
            generation: UInt64(seed),
            result: .accepted,
            at: now.addingTimeInterval(3),
            codeState: cs,
            environment: env
        ))
        task.acceptedSnapshot = AgentTaskResultSnapshot(
            runID: run.id,
            outcome: .success,
            codeState: cs,
            environment: env,
            recordedAt: now.addingTimeInterval(3)
        )
        task.acceptanceState = .accepted
        return task
    }

    /// One detector-owned session with explicit honest timestamps.
    private func session(
        pid: Int32,
        generation: UInt64,
        startedAt: Date,
        observedAt: Date,
        agentType: AgentType = .claudeCode
    ) -> AgentSession {
        let session = AgentSession(
            agentType: agentType,
            state: .idle,
            lifecycleAccuracy: .processTerminationOnly,
            startedAt: startedAt,
            lastObservedAt: observedAt
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: pid,
            processGeneration: generation,
            startIdentifier: "cont-\(pid)",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        ))
        return session
    }

    private static let launchBoundary = AgentTaskLaunchBoundary(
        generationFloor: 0,
        capturedAt: .distantPast
    )

    /// Rebuilds one record with a single corrupted field (records are
    /// immutable values).
    private func variant(
        _ record: AgentTaskRevisionRecord,
        origin: AgentTaskRevisionOrigin? = nil,
        reference: String? = nil,
        generation: UInt64? = nil
    ) -> AgentTaskRevisionRecord {
        AgentTaskRevisionRecord(
            origin: origin ?? record.origin,
            feedbackReference: reference ?? record.feedbackReference,
            candidateGeneration: generation ?? record.candidateGeneration,
            observedAt: record.observedAt,
            codeState: record.codeState
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func makeReadyRegistryTask(
        registry: AgentTaskRegistry,
        seed: Int,
        codeState cs: AgentTaskCodeStateIdentity,
        environment env: AgentTaskEnvironmentIdentity,
        projectPath: String,
        now: Date
    ) throws -> (
        taskID: UUID,
        firstSession: AgentSession,
        route: AgentTaskRoute,
        identity: AgentTaskProjectIdentity
    ) {
        let identity = project(projectPath)
        let route = AgentTaskRoute(
            paneID: uuid(seed),
            tabID: uuid(seed + 100),
            terminalID: uuid(seed + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now.addingTimeInterval(-400)
        )
        guard case .reserved(let launch) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: .claudeCode,
                launchExecutable: "claude"
            ),
            context: context,
            title: "Draft the release notes",
            objective: "Write the release notes draft",
            boundary: Self.launchBoundary
        ) else {
            throw FixtureError.reservationRejected
        }
        #expect(registry.armLaunch(launch))
        let s1 = session(
            pid: Int32(6_000 + seed),
            generation: 1,
            startedAt: now.addingTimeInterval(-300),
            observedAt: now.addingTimeInterval(-200)
        )
        registry.bridge(s1, replacing: nil, context: context, reservation: launch)
        s1.applyLiveness(.terminated)
        s1.recordLifecycleState(.done, accuracy: .processTerminationOnly)
        registry.refresh(sessions: [s1])
        let taskID = try #require(
            registry.historicalTask(forSessionID: s1.id)?.id
        )
        let t = now.addingTimeInterval(-100)
        #expect(registry.recordEvidence(fact(
            .agentReportedCompletion,
            runID: s1.id,
            generation: 1,
            result: .reported,
            at: t,
            codeState: cs,
            environment: env,
            sequence: 1
        ), taskID: taskID) == .accepted)
        #expect(registry.recordEvidence(fact(
            .independentCheck,
            runID: s1.id,
            generation: 1,
            result: .succeeded,
            at: t.addingTimeInterval(1),
            codeState: cs,
            environment: env,
            sequence: 2,
            pre: cs,
            post: cs
        ), taskID: taskID) == .accepted)
        #expect(registry.recordEvidence(fact(
            .reviewerOutcome,
            runID: s1.id,
            generation: 1,
            result: .succeeded,
            at: t.addingTimeInterval(2),
            codeState: cs,
            environment: env,
            sequence: 3,
            pre: cs,
            post: cs
        ), taskID: taskID) == .accepted)
        #expect(registry.markVerificationCurrent(taskID: taskID, codeState: cs, environment: env))
        #expect(registry.readiness(for: taskID, codeState: cs, environment: env).isReady)
        return (taskID, s1, route, identity)
    }

    // MARK: - Transition table

    @Test("transition table covers every continuation state")
    func transitionTableCoversEveryContinuationState() throws {
        let cs = codeState("a")
        let env = environment

        // No run yet (launch intent only).
        var empty = makeTask(seed: 1)
        empty.runs = []
        empty.lifecycle = .paused
        #expect(AgentTaskContinuation.phase(for: empty) == .none)

        // Live provider process with an active turn.
        #expect(AgentTaskContinuation.phase(
            for: makeTask(seed: 2, liveness: .live)
        ) == .working)

        // Restored/stale state after relaunch.
        #expect(AgentTaskContinuation.phase(
            for: makeTask(seed: 3, liveness: .stale)
        ) == .restoredStale)

        // Settled turn awaiting verification.
        #expect(AgentTaskContinuation.phase(
            for: settledTask(seed: 4)
        ) == .settledAwaitingVerification)

        // Current Ready result.
        let ready = try verifiedSuccessTask(seed: 5, codeState: cs, environment: env)
        #expect(AgentTaskContinuation.phase(for: ready) == .ready)

        // Accepted result.
        #expect(AgentTaskContinuation.phase(
            for: try acceptedTask(seed: 6, codeState: cs, environment: env)
        ) == .accepted)

        // Failed and cancelled settlements keep distinct honest phases.
        var failed = settledTask(seed: 7)
        let failedRun = try #require(failed.runs.first)
        failed.evidence.append(fact(
            .agentReportedCompletion,
            runID: failedRun.id,
            generation: 7,
            result: .reported,
            at: Date(),
            codeState: cs
        ))
        failed.evidence.append(fact(
            .independentCheck,
            runID: failedRun.id,
            generation: 7,
            result: .failed,
            at: Date().addingTimeInterval(1),
            codeState: cs,
            pre: cs,
            post: cs
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &failed, runIndex: 0)
        #expect(AgentTaskContinuation.phase(for: failed) == .failed)

        var cancelled = settledTask(seed: 8)
        let cancelledRun = try #require(cancelled.runs.first)
        cancelled.evidence.append(fact(
            .userCancellation,
            runID: cancelledRun.id,
            generation: 8,
            result: .cancelled,
            at: Date()
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &cancelled, runIndex: 0)
        #expect(AgentTaskContinuation.phase(for: cancelled) == .cancelled)

        // A superseded tail is unknown, never a positive state.
        #expect(AgentTaskContinuation.phase(
            for: makeTask(seed: 9, outcome: .superseded)
        ) == .unknown)

        // New user revision: the pending-dispatch state.
        var revised = ready
        _ = AgentTaskContinuation.submitRevision(
            &revised,
            feedbackReference: "ref-1",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: Date()
        )
        #expect(AgentTaskContinuation.phase(for: revised) == .revisionPending)
    }

    @Test("settled turn on a live provider process keys on the outcome (#1795 seam)")
    func liveSettledTurnKeysOnOutcome() throws {
        let cs = codeState("a")
        let env = environment
        var task = try verifiedSuccessTask(seed: 10, codeState: cs, environment: env)
        // #1795 shape: logical settlement on a still-live provider process.
        // The outcome is the logical fact; the process stays live.
        task.runs[0].liveness = .live
        task.runs[0].endedAt = nil
        #expect(!AgentTaskContinuation.hasActiveTurn(task.runs[0]))
        #expect(AgentTaskContinuation.phase(for: task) == .ready)
        // On this base the physical settlement contract still governs the
        // Ready precondition (#1795's logical-settlement metadata is not on
        // this branch), so the transition is refused — and it must refuse
        // without fabricating process termination. Once #1795's metadata is
        // present, isSettled/readiness become outcome-keyed and this same
        // call is admitted at the model layer unchanged; the registry
        // guards named in AgentTaskContinuation's file header remain the
        // #1811/#1723 integration seam.
        let decision = AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-live",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: Date()
        )
        #expect(decision == .rejected(.notReady))
        #expect(task.runs[0].liveness == .live)
        #expect(task.runs[0].endedAt == nil)
        #expect(task.revisions.isEmpty)
    }

    // MARK: - Revision transition (pure)

    @Test("revision from Ready keeps durable identity and history")
    func revisionFromReadyKeepsIdentityAndHistory() throws {
        let cs = codeState("a")
        let env = environment
        var task = try verifiedSuccessTask(seed: 11, codeState: cs, environment: env)
        task.environment = env
        task.feedback.append(AgentTaskFeedbackRecord(
            reference: "fb-1",
            observedAt: Date(),
            codeState: cs
        ))
        let taskID = task.id
        let objective = task.objective
        let title = task.title
        let feedback = task.feedback
        let environmentBinding = task.environment
        let reviewed = try #require(task.reviewedSnapshot)
        let evidence = task.evidence
        let runs = task.runs

        #expect(AgentTaskContinuation.phase(for: task) == .ready)
        let decision = AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-1",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: Date()
        )
        #expect(decision == .recorded(candidateGeneration: 1))
        // Durable identity and the whole result/feedback history preserved.
        #expect(task.id == taskID)
        #expect(task.objective == objective)
        #expect(task.title == title)
        #expect(task.environment == environmentBinding)
        #expect(task.feedback == feedback)
        #expect(task.reviewedSnapshot == reviewed)
        #expect(task.evidence == evidence)
        #expect(task.runs == runs)
        // The new candidate starts without current verification or
        // acceptance; the completed state is unwound to paused.
        #expect(task.candidateGeneration == 1)
        #expect(task.revisions.count == 1)
        #expect(task.revisions[0].origin == .explicitUser)
        #expect(task.revisions[0].feedbackReference == "ref-1")
        #expect(task.revisions[0].candidateGeneration == 1)
        #expect(task.revisions[0].codeState == cs)
        #expect(task.verificationState == .stale)
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.lifecycle == .paused)
        #expect(task.completedAt == nil)
        #expect(task.attention == .none)
        #expect(AgentTaskContinuation.phase(for: task) == .revisionPending)
        // The old Ready is never silently restored.
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: cs,
            environment: env
        ).isReady)
    }

    @Test("revision from an accepted result keeps historical acceptance on its exact snapshot")
    func revisionFromAcceptedKeepsHistoricalAcceptance() throws {
        let cs = codeState("a")
        let env = environment
        var task = try acceptedTask(seed: 12, codeState: cs, environment: env)
        let snapshot = try #require(task.acceptedSnapshot)
        let acceptanceFact = try #require(
            task.evidence.last(where: { $0.kind == .userAcceptance })
        )
        let reviewed = try #require(task.reviewedSnapshot)

        let decision = AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-acc",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: Date()
        )
        #expect(decision == .recorded(candidateGeneration: 1))
        // Historical acceptance stays attached to its exact snapshot.
        #expect(task.acceptedSnapshot == snapshot)
        #expect(task.evidence.contains(where: { $0 == acceptanceFact }))
        #expect(task.reviewedSnapshot == reviewed)
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.verificationState == .stale)
        #expect(task.lifecycle == .paused)
        #expect(task.completedAt == nil)
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: cs,
            environment: env
        ).isReady)
    }

    @Test("revision admission refuses non-Ready states and malformed references")
    func revisionAdmissionRefusesNonReadyStates() throws {
        let cs = codeState("a")
        let env = environment
        let at = Date()

        // Unverified settled result.
        var unverified = settledTask(seed: 20)
        #expect(AgentTaskContinuation.submitRevision(
            &unverified,
            feedbackReference: "r",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: at
        ) == .rejected(.notReady))

        // Failed settlement.
        var failed = settledTask(seed: 21)
        let failedRun = try #require(failed.runs.first)
        failed.evidence.append(fact(
            .agentReportedCompletion,
            runID: failedRun.id,
            generation: 21,
            result: .reported,
            at: at,
            codeState: cs
        ))
        failed.evidence.append(fact(
            .independentCheck,
            runID: failedRun.id,
            generation: 21,
            result: .failed,
            at: at.addingTimeInterval(1),
            codeState: cs,
            pre: cs,
            post: cs
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &failed, runIndex: 0)
        #expect(AgentTaskContinuation.submitRevision(
            &failed,
            feedbackReference: "r",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: at
        ) == .rejected(.notReady))

        // Active turn.
        var working = makeTask(seed: 22, liveness: .live)
        #expect(AgentTaskContinuation.submitRevision(
            &working,
            feedbackReference: "r",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: at
        ) == .rejected(.activeTurn))

        // Dismissed tasks stay governed by their existing policy.
        var dismissed = try verifiedSuccessTask(seed: 23, codeState: cs, environment: env)
        dismissed.lifecycle = .dismissed
        #expect(AgentTaskContinuation.submitRevision(
            &dismissed,
            feedbackReference: "r",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: at
        ) == .rejected(.dismissed))

        // No runs.
        var empty = makeTask(seed: 24)
        empty.runs = []
        #expect(AgentTaskContinuation.submitRevision(
            &empty,
            feedbackReference: "r",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: at
        ) == .rejected(.notReady))

        // Reference shape: bounded, content-free.
        let ready = try verifiedSuccessTask(seed: 25, codeState: cs, environment: env)
        for reference in ["", String(repeating: "x", count: 257), "bad\0ref"] {
            var copy = ready
            #expect(AgentTaskContinuation.submitRevision(
                &copy,
                feedbackReference: reference,
                codeState: cs,
                environment: env,
                origin: .explicitUser,
                at: at
            ) == .rejected(.invalidReference))
            #expect(copy.revisions.isEmpty)
        }

        // Bound: a full revision history fences the next record.
        var full = ready
        for index in 0 ..< AgentTaskContinuation.maxRevisionRecords {
            full.revisions.append(AgentTaskRevisionRecord(
                origin: .automaticReviewer,
                feedbackReference: "auto-\(index)",
                candidateGeneration: 0,
                observedAt: at.addingTimeInterval(TimeInterval(index))
            ))
        }
        #expect(AgentTaskContinuation.submitRevision(
            &full,
            feedbackReference: "r",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: at.addingTimeInterval(99)
        ) == .rejected(.limitReached))
    }

    @Test("duplicate submission is idempotent until dispatched")
    func duplicateSubmissionIsIdempotentUntilDispatched() throws {
        let cs = codeState("a")
        let env = environment
        var task = try verifiedSuccessTask(seed: 30, codeState: cs, environment: env)
        let t = Date()
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-a",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: t
        ) == .recorded(candidateGeneration: 1))

        // Duplicate click on the pending revision: no second transition.
        let revisions = task.revisions
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-a",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: t.addingTimeInterval(1)
        ) == .alreadyRecorded(candidateGeneration: 1))
        #expect(task.revisions == revisions)

        // A different explicit revision is a deliberate new candidate.
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-b",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: t.addingTimeInterval(2)
        ) == .recorded(candidateGeneration: 2))

        // Same text with a different origin is a different submission.
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-b",
            codeState: cs,
            environment: env,
            origin: .automaticReviewer,
            at: t.addingTimeInterval(3)
        ) == .recorded(candidateGeneration: 2))

        // Once a dispatch appended a live run, the same reference can no
        // longer ride the pending-revision path; an active turn fences it.
        task.runs.append(AgentTaskRun(makeRunInput(
            seed: 31,
            state: .idle,
            liveness: .live,
            now: t.addingTimeInterval(10)
        )))
        task.lifecycle = .active
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-b",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: t.addingTimeInterval(11)
        ) == .rejected(.activeTurn))
    }

    @Test("automatic corrections do not advance the candidate cycle (#1755 boundary)")
    func automaticCorrectionsDoNotAdvanceTheCycle() throws {
        let cs = codeState("a")
        let env = environment
        var task = try verifiedSuccessTask(seed: 40, codeState: cs, environment: env)
        let t = Date()
        for index in 0 ..< 3 {
            #expect(AgentTaskContinuation.submitRevision(
                &task,
                feedbackReference: "auto-\(index)",
                codeState: cs,
                environment: env,
                origin: .automaticReviewer,
                at: t.addingTimeInterval(TimeInterval(index))
            ) == .recorded(candidateGeneration: 0))
        }
        #expect(task.candidateGeneration == 0)
        #expect(task.revisions.count == 3)
        #expect(task.revisions.allSatisfy {
            $0.origin == .automaticReviewer && $0.candidateGeneration == 0
        })
        // An explicit user revision starts the new cycle.
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "user-1",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: t.addingTimeInterval(10)
        ) == .recorded(candidateGeneration: 1))
        #expect(task.candidateGeneration == 1)
        // Automatic corrections inside the cycle keep the generation.
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "auto-3",
            codeState: cs,
            environment: env,
            origin: .automaticReviewer,
            at: t.addingTimeInterval(11)
        ) == .recorded(candidateGeneration: 1))
        #expect(task.candidateGeneration == 1)
        #expect(task.revisions.count == 5)
    }

    @Test("failed dispatch leaves a resubmittable pending revision")
    func failedDispatchLeavesResubmittableRevision() throws {
        let cs = codeState("a")
        let env = environment
        var task = try verifiedSuccessTask(seed: 50, codeState: cs, environment: env)
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-a",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: Date()
        ) == .recorded(candidateGeneration: 1))
        // The invalidated result is not Ready: the old result is not
        // silently restored, and the pending revision is re-armable.
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: cs,
            environment: env
        ).isReady)
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-a",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: Date()
        ) == .alreadyRecorded(candidateGeneration: 1))
        // A deliberate new revision is a new candidate: an explicit
        // resubmission, never an automatic resend.
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "ref-b",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: Date()
        ) == .recorded(candidateGeneration: 2))
        #expect(task.revisions.count == 2)
        #expect(task.candidateGeneration == 2)
    }

    @Test("changed identities produce truthful gaps before continuation")
    func changedIdentitiesProduceTruthfulGaps() throws {
        let cs = codeState("a")
        let env = environment
        var task = try verifiedSuccessTask(seed: 60, codeState: cs, environment: env)
        let otherCS = codeState("d")
        let otherEnv = environment("26A5388h", "e")
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: otherCS,
            environment: otherEnv
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.staleEvidence(.independentCheck)))
        #expect(readiness.gaps.contains(.staleEvidence(.reviewerOutcome)))
        // The old result is not continuable under identities it was not
        // verified against.
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "r",
            codeState: otherCS,
            environment: otherEnv,
            origin: .explicitUser,
            at: Date()
        ) == .rejected(.notReady))
        // Under the unchanged identities the same submission is admitted.
        #expect(AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "r",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: Date()
        ) == .recorded(candidateGeneration: 1))
    }

    // MARK: - Registry flow

    @Test("continuation from Ready produces a new attempt under the same task ID")
    func continuationFromReadyProducesNewAttempt() throws {
        let cs = codeState("a")
        let env = environment
        let now = Date()
        let registry = AgentTaskRegistry()
        let (taskID, s1, route, identity) = try makeReadyRegistryTask(
            registry: registry,
            seed: 70,
            codeState: cs,
            environment: env,
            projectPath: "/tmp/pine-continuation-flow-70",
            now: now
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now
        )
        guard case .reserved(let reservation) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "ref-70",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("continuation reservation was rejected")
            return
        }
        // The transition is recorded before dispatch: no attempt yet.
        var task = try #require(registry.task(for: taskID))
        #expect(task.candidateGeneration == 1)
        #expect(task.revisions.count == 1)
        #expect(task.verificationState == .stale)
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.lifecycle == .paused)
        #expect(task.completedAt == nil)
        #expect(task.objective == "Write the release notes draft")
        #expect(task.reviewedSnapshot != nil)
        #expect(task.runs.count == 1)
        #expect(AgentTaskContinuation.phase(for: task) == .revisionPending)
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: cs,
            environment: env
        ).isReady)

        #expect(registry.armLaunch(reservation))
        let s2 = session(
            pid: Int32(6_000 + 70 + 1),
            generation: 2,
            startedAt: now.addingTimeInterval(1),
            observedAt: now.addingTimeInterval(2)
        )
        registry.bridge(s2, replacing: s1, context: context, reservation: reservation)
        task = try #require(registry.task(for: taskID))
        #expect(task.id == taskID)
        #expect(task.runs.count == 2)
        #expect(task.runs[1].id == s2.id)
        #expect(!AgentTaskContinuation.hasPendingRevision(task))
        #expect(task.verificationState == .none)
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.reviewedSnapshot != nil)
        #expect(task.candidateGeneration == 1)
        #expect(AgentTaskContinuation.phase(for: task) == .working)

        // The new candidate settles on its own evidence, under new
        // identities — the same durable task ID.
        s2.applyLiveness(.terminated)
        s2.recordLifecycleState(.done, accuracy: .processTerminationOnly)
        registry.refresh(sessions: [s2])
        let cs2 = codeState("d")
        let env2 = environment("26A5388h", "e")
        let t2 = now.addingTimeInterval(10)
        #expect(registry.recordEvidence(fact(
            .agentReportedCompletion,
            runID: s2.id,
            generation: 2,
            result: .reported,
            at: t2,
            codeState: cs2,
            environment: env2,
            sequence: 1
        ), taskID: taskID) == .accepted)
        #expect(registry.recordEvidence(fact(
            .independentCheck,
            runID: s2.id,
            generation: 2,
            result: .succeeded,
            at: t2.addingTimeInterval(1),
            codeState: cs2,
            environment: env2,
            sequence: 2,
            pre: cs2,
            post: cs2
        ), taskID: taskID) == .accepted)
        #expect(registry.recordEvidence(fact(
            .reviewerOutcome,
            runID: s2.id,
            generation: 2,
            result: .succeeded,
            at: t2.addingTimeInterval(2),
            codeState: cs2,
            environment: env2,
            sequence: 3,
            pre: cs2,
            post: cs2
        ), taskID: taskID) == .accepted)
        #expect(registry.markVerificationCurrent(taskID: taskID, codeState: cs2, environment: env2))
        #expect(registry.readiness(for: taskID, codeState: cs2, environment: env2).isReady)
        // The old candidate is not restored under the old identities.
        #expect(!registry.readiness(for: taskID, codeState: cs, environment: env).isReady)
        task = try #require(registry.task(for: taskID))
        #expect(AgentTaskContinuation.phase(for: task) == .ready)
    }

    @Test("late old-attempt events cannot touch the new candidate")
    func lateOldAttemptEventsCannotTouchNewCandidate() throws {
        let cs = codeState("a")
        let env = environment
        let now = Date()
        let registry = AgentTaskRegistry()
        let (taskID, s1, route, identity) = try makeReadyRegistryTask(
            registry: registry,
            seed: 80,
            codeState: cs,
            environment: env,
            projectPath: "/tmp/pine-continuation-flow-80",
            now: now
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now
        )
        guard case .reserved(let reservation) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "ref-80",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("continuation reservation was rejected")
            return
        }
        #expect(registry.armLaunch(reservation))
        let s2 = session(
            pid: Int32(6_000 + 80 + 1),
            generation: 2,
            startedAt: now.addingTimeInterval(1),
            observedAt: now.addingTimeInterval(2)
        )
        registry.bridge(s2, replacing: s1, context: context, reservation: reservation)

        // Late success/approval events for the OLD attempt, arriving after
        // the new attempt exists: admitted as history, never as current.
        let lateClaim = fact(
            .agentReportedCompletion,
            runID: s1.id,
            generation: 1,
            result: .reported,
            at: now.addingTimeInterval(50),
            codeState: cs,
            environment: env,
            sequence: 4
        )
        #expect(registry.recordEvidence(lateClaim, taskID: taskID) == .accepted)
        let lateReview = fact(
            .reviewerOutcome,
            runID: s1.id,
            generation: 1,
            result: .succeeded,
            at: now.addingTimeInterval(51),
            codeState: cs,
            environment: env,
            sequence: 5,
            pre: cs,
            post: cs
        )
        #expect(registry.recordEvidence(lateReview, taskID: taskID) == .accepted)
        // Replayed duplicates are fenced.
        #expect(registry.recordEvidence(lateClaim, taskID: taskID)
            == .fencedOut(.duplicate))
        // A foreign-incarnation fact for the new attempt is fenced.
        let foreign = fact(
            .agentReportedCompletion,
            runID: s2.id,
            generation: 1,
            result: .reported,
            at: now.addingTimeInterval(52),
            codeState: cs,
            environment: env
        )
        #expect(registry.recordEvidence(foreign, taskID: taskID)
            == .fencedOut(.foreignProcess))
        var task = try #require(registry.task(for: taskID))
        #expect(task.runs[1].outcome == nil)
        #expect(task.evidence.contains(where: { $0 == lateClaim }))
        #expect(task.evidence.contains(where: { $0 == lateReview }))
        // Live-session ordering is untouched: a sequenced fact for the
        // live attempt still admits in provider order.
        let cs2 = codeState("d")
        let env2 = environment("26A5388h", "e")
        let liveFact = fact(
            .agentReportedCompletion,
            runID: s2.id,
            generation: 2,
            result: .reported,
            at: now.addingTimeInterval(53),
            codeState: cs2,
            environment: env2,
            sequence: 1
        )
        #expect(registry.recordEvidence(liveFact, taskID: taskID) == .accepted)
        task = try #require(registry.task(for: taskID))
        #expect(task.evidence.contains(where: { $0 == liveFact }))
    }

    @Test("continuation from an accepted result keeps historical acceptance on the old snapshot")
    func continuationFromAcceptedKeepsHistoricalAcceptance() throws {
        let cs = codeState("a")
        let env = environment
        let now = Date()
        let registry = AgentTaskRegistry()
        let (taskID, s1, route, identity) = try makeReadyRegistryTask(
            registry: registry,
            seed: 160,
            codeState: cs,
            environment: env,
            projectPath: "/tmp/pine-continuation-flow-160",
            now: now
        )
        // Accept the Ready result.
        #expect(registry.recordUserAcceptance(
            taskID: taskID,
            codeState: cs,
            environment: env,
            at: now
        ))
        var task = try #require(registry.task(for: taskID))
        #expect(AgentTaskContinuation.phase(for: task) == .accepted)
        let acceptedSnapshot = try #require(task.acceptedSnapshot)
        let acceptanceFact = try #require(
            task.evidence.last(where: { $0.kind == .userAcceptance })
        )

        // Continue from the accepted result: the same supported flow.
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now
        )
        guard case .reserved(let reservation) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "acc-ref",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("continuation from an accepted result was rejected")
            return
        }
        // Historical acceptance stays on its exact snapshot; the current
        // acceptance dimension is unwound.
        task = try #require(registry.task(for: taskID))
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.acceptedSnapshot == acceptedSnapshot)
        #expect(task.evidence.contains(where: { $0 == acceptanceFact }))
        #expect(task.reviewedSnapshot != nil)
        #expect(task.candidateGeneration == 1)

        // The new attempt starts without inheriting the acceptance.
        #expect(registry.armLaunch(reservation))
        let s2 = session(
            pid: Int32(6_000 + 160 + 1),
            generation: 2,
            startedAt: now.addingTimeInterval(1),
            observedAt: now.addingTimeInterval(2)
        )
        registry.bridge(s2, replacing: s1, context: context, reservation: reservation)
        task = try #require(registry.task(for: taskID))
        #expect(task.id == taskID)
        #expect(task.runs.count == 2)
        #expect(task.runs[1].id == s2.id)
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.acceptedSnapshot?.runID == s1.id)
        #expect(task.verificationState == .none)
    }

    @Test("a settled cancellation is not revisable; explicit resume stays the sanctioned recovery")
    func settledCancellationIsNotRevisable() throws {
        // Open note (#1725 product decision): a first-class "new feedback
        // from a failed or cancelled attempt" transition is out of scope for
        // this contract. Until it lands, the sanctioned recovery for a
        // settled cancellation is explicit resume (prepareResume) or the
        // next Ready result — pinned below.
        let cs = codeState("a")
        let env = environment
        let now = Date()
        let registry = AgentTaskRegistry()
        let (taskID, s1, route, identity) = try makeReadyRegistryTask(
            registry: registry,
            seed: 150,
            codeState: cs,
            environment: env,
            projectPath: "/tmp/pine-continuation-flow-150",
            now: now
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now
        )
        guard case .reserved(let reservation) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "cancel-ref",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("continuation reservation was rejected")
            return
        }
        // The attempt starts, then the user cancels it: the process ends and
        // the cancellation fact settles the attempt.
        #expect(registry.armLaunch(reservation))
        let s2 = session(
            pid: Int32(6_000 + 150 + 1),
            generation: 2,
            startedAt: now.addingTimeInterval(1),
            observedAt: now.addingTimeInterval(2)
        )
        registry.bridge(s2, replacing: s1, context: context, reservation: reservation)
        s2.applyLiveness(.terminated)
        s2.recordLifecycleState(.done, accuracy: .processTerminationOnly)
        registry.refresh(sessions: [s2])
        #expect(registry.recordEvidence(fact(
            .userCancellation,
            runID: s2.id,
            generation: 2,
            result: .cancelled,
            at: now.addingTimeInterval(3)
        ), taskID: taskID) == .accepted)
        var task = try #require(registry.task(for: taskID))
        #expect(task.runs[1].outcome == .cancellation)
        #expect(AgentTaskContinuation.phase(for: task) == .cancelled)
        // A new user revision from the settled cancellation is refused.
        #expect(registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "cancel-ref-2",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) == .rejected)
        task = try #require(registry.task(for: taskID))
        #expect(task.revisions.count == 1)
        #expect(task.candidateGeneration == 1)
        // Explicit resume remains the sanctioned, admitted recovery.
        guard case .reserved = registry.prepareResume(
            taskID: taskID,
            context: context,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("explicit resume was rejected")
            return
        }
        task = try #require(registry.task(for: taskID))
        #expect(task.runs.count == 2)
        #expect(task.lifecycle == .paused)
    }

    @Test("duplicate submission creates at most one attempt")
    func duplicateSubmissionCreatesAtMostOneAttempt() throws {
        let cs = codeState("a")
        let env = environment
        let now = Date()
        let registry = AgentTaskRegistry()
        let (taskID, s1, route, identity) = try makeReadyRegistryTask(
            registry: registry,
            seed: 90,
            codeState: cs,
            environment: env,
            projectPath: "/tmp/pine-continuation-flow-90",
            now: now
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now
        )
        guard case .reserved(let reservation) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "dup-1",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("continuation reservation was rejected")
            return
        }
        // Duplicate click while the claim is pending: rejected, one
        // transition stays recorded.
        #expect(registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "dup-1",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) == .rejected)
        #expect(registry.task(for: taskID)?.revisions.count == 1)
        #expect(registry.task(for: taskID)?.candidateGeneration == 1)

        #expect(registry.armLaunch(reservation))
        let s2 = session(
            pid: Int32(6_000 + 90 + 1),
            generation: 2,
            startedAt: now.addingTimeInterval(1),
            observedAt: now.addingTimeInterval(2)
        )
        registry.bridge(s2, replacing: s1, context: context, reservation: reservation)
        #expect(registry.task(for: taskID)?.runs.count == 2)
        // A re-polled session never appends a second run.
        registry.refresh(sessions: [s2])
        #expect(registry.task(for: taskID)?.runs.count == 2)
    }

    @Test("cancellation during dispatch leaves an honest pending state")
    func cancellationDuringDispatchLeavesPendingState() throws {
        let cs = codeState("a")
        let env = environment
        let now = Date()
        let registry = AgentTaskRegistry()
        let (taskID, _, route, identity) = try makeReadyRegistryTask(
            registry: registry,
            seed: 91,
            codeState: cs,
            environment: env,
            projectPath: "/tmp/pine-continuation-flow-91",
            now: now
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now
        )
        guard case .reserved(let reservation) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "dup-2",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("continuation reservation was rejected")
            return
        }
        // The user cancels before the dispatch settles.
        registry.cancelLaunch(reservation)
        var task = try #require(registry.task(for: taskID))
        #expect(task.runs.count == 1)
        #expect(task.revisions.count == 1)
        #expect(task.candidateGeneration == 1)
        #expect(task.verificationState == .stale)
        #expect(task.lifecycle == .paused)
        #expect(AgentTaskContinuation.phase(for: task) == .revisionPending)
        #expect(!registry.isLaunchPending(reservation))
        // No automatic resend: an explicit resubmission re-arms the exact
        // pending revision as one dispatch.
        guard case .reserved(let rearm) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "dup-2",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("explicit resubmission was rejected")
            return
        }
        #expect(registry.task(for: taskID)?.revisions.count == 1)
        #expect(registry.task(for: taskID)?.candidateGeneration == 1)
        #expect(registry.armLaunch(rearm))
        let s2 = session(
            pid: Int32(6_000 + 91 + 1),
            generation: 2,
            startedAt: now.addingTimeInterval(1),
            observedAt: now.addingTimeInterval(2)
        )
        registry.bridge(s2, replacing: nil, context: context, reservation: rearm)
        task = try #require(registry.task(for: taskID))
        #expect(task.runs.count == 2)
        #expect(task.runs[1].id == s2.id)
    }

    @Test("a failed provider resume keeps the claim honest")
    func failedProviderResumeKeepsClaimHonest() throws {
        let cs = codeState("a")
        let env = environment
        let now = Date()
        let box = ClockBox()
        let registry = AgentTaskRegistry(
            monotonicNow: box.now,
            claimTTL: .seconds(30)
        )
        let (taskID, s1, route, identity) = try makeReadyRegistryTask(
            registry: registry,
            seed: 100,
            codeState: cs,
            environment: env,
            projectPath: "/tmp/pine-continuation-flow-100",
            now: now
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now
        )
        guard case .reserved(let reservation) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "ref-100",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("continuation reservation was rejected")
            return
        }
        #expect(registry.armLaunch(reservation))
        // The resume produced no new process: a detector poll of the same
        // generation cannot consume the claim, and no replacement
        // conversation is fabricated.
        let stale = session(
            pid: Int32(6_000 + 100),
            generation: 1,
            startedAt: now.addingTimeInterval(-250),
            observedAt: now.addingTimeInterval(3)
        )
        registry.bridge(stale, replacing: nil, context: context, reservation: reservation)
        var task = try #require(registry.task(for: taskID))
        #expect(task.runs.count == 1)
        #expect(registry.isLaunchPending(reservation))
        // The claim expires to the honest pending state; an explicit
        // resubmission re-arms it.
        box.advance(.seconds(31))
        registry.refresh(sessions: [stale])
        #expect(!registry.isLaunchPending(reservation))
        task = try #require(registry.task(for: taskID))
        #expect(task.runs.count == 1)
        #expect(AgentTaskContinuation.phase(for: task) == .revisionPending)
        guard case .reserved(let rearm) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "ref-100",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("explicit resubmission was rejected")
            return
        }
        #expect(registry.task(for: taskID)?.revisions.count == 1)
    }

    // MARK: - Durability: relaunch and crash

    @Test("relaunch preserves continuation state and requires explicit action")
    func relaunchPreservesContinuationState() async throws {
        let fixture = try ContinuationPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let cs = codeState("a")
        let env = environment
        let now = Date()
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        let (taskID, _, route, _) = try makeReadyRegistryTask(
            registry: registry,
            seed: 110,
            codeState: cs,
            environment: env,
            projectPath: fixture.project.path,
            now: now
        )
        #expect(await registry.flushPersistence() == .saved)
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now
        )
        guard case .reserved(let reservation) = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "relaunch-ref",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("continuation was rejected")
            return
        }
        #expect(registry.task(for: taskID)?.runs.count == 1)
        // The transition is durable before any dispatch.
        #expect(await registry.flushPersistence() == .saved)
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let root = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: file)
            ) as? [String: Any]
        )
        let tasksJSON = try #require(root["tasks"] as? [[String: Any]])
        #expect(tasksJSON[0]["candidateGeneration"] as? UInt64 == 1)
        #expect((tasksJSON[0]["revisions"] as? [[String: Any]])?.count == 1)

        // Relaunch: a new registry over the same store. Loading never
        // restarts anything and never restores the old Ready.
        let reloaded = AgentTaskRegistry(persistence: store)
        reloaded.registerProject(identity)
        #expect(await reloaded.flushPersistence() == .saved)
        var task = try #require(reloaded.task(for: taskID))
        #expect(task.runs.count == 1)
        #expect(task.candidateGeneration == 1)
        #expect(task.revisions.count == 1)
        #expect(task.revisions[0].feedbackReference == "relaunch-ref")
        #expect(task.revisions[0].origin == .explicitUser)
        #expect(task.verificationState == .stale)
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.lifecycle == .paused)
        #expect(task.completedAt == nil)
        #expect(task.reviewedSnapshot != nil)
        #expect(task.objective == "Write the release notes draft")
        #expect(AgentTaskContinuation.phase(for: task) == .revisionPending)
        #expect(!reloaded.readiness(for: taskID, codeState: cs, environment: env).isReady)

        // Explicit action re-arms the exact pending revision (idempotent:
        // no second transition, no second generation).
        guard case .reserved(let rearm) = reloaded.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "relaunch-ref",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("explicit re-arm was rejected")
            return
        }
        task = try #require(reloaded.task(for: taskID))
        #expect(task.candidateGeneration == 1)
        #expect(task.revisions.count == 1)
        #expect(reloaded.armLaunch(rearm))
        let s2 = session(
            pid: Int32(6_000 + 110 + 1),
            generation: 2,
            startedAt: now.addingTimeInterval(1),
            observedAt: now.addingTimeInterval(2)
        )
        reloaded.bridge(s2, replacing: nil, context: context, reservation: rearm)
        #expect(reloaded.task(for: taskID)?.runs.count == 2)
        #expect(await reloaded.flushPersistence() == .saved)
    }

    @Test("crash before the transition flush leaves the old result intact")
    func crashBeforeTransitionFlushKeepsOldResult() async throws {
        let fixture = try ContinuationPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let cs = codeState("a")
        let env = environment
        let now = Date()
        let gate = GatedFault()
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                faultInjector: PersistenceFaultInjector { storeKind, phase in
                    try gate.checkpoint(store: storeKind, phase: phase)
                }
            )
        )
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        let (taskID, _, route, _) = try makeReadyRegistryTask(
            registry: registry,
            seed: 130,
            codeState: cs,
            environment: env,
            projectPath: fixture.project.path,
            now: now
        )
        #expect(await registry.flushPersistence() == .saved)
        // Crash during the dispatch: the save of the new-attempt transition
        // never commits.
        gate.arm()
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .pineLaunched,
            observedAt: now
        )
        guard case .reserved = registry.prepareContinuation(
            taskID: taskID,
            context: context,
            feedbackReference: "crash-ref",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            boundary: Self.launchBoundary
        ) else {
            Issue.record("continuation was rejected")
            return
        }
        #expect(await registry.flushPersistence() == .failed)
        // The transition is in memory only: a relaunch sees the settled
        // result intact with no torn or half-recorded state. (The load
        // itself downgrades `.verified` to `.stale` — the documented #1722
        // relaunch normalization covered by the dedicated relaunch test —
        // so the honest post-crash state is the completed result awaiting
        // re-verification, never a partially recorded revision.)
        let reloaded = AgentTaskRegistry(
            persistence: AgentTaskMetadataStore(storageRoot: fixture.storage)
        )
        reloaded.registerProject(identity)
        #expect(await reloaded.flushPersistence() == .saved)
        let task = try #require(reloaded.task(for: taskID))
        #expect(task.revisions.isEmpty)
        #expect(task.candidateGeneration == 0)
        #expect(task.runs.count == 1)
        #expect(task.lifecycle == .completed)
        #expect(task.verificationState == .stale)
        #expect(task.completedAt != nil)
        #expect(!reloaded.readiness(for: taskID, codeState: cs, environment: env).isReady)
    }

    @Test("revision metadata persists and validates fail-closed")
    func revisionMetadataPersistsAndValidates() async throws {
        let fixture = try ContinuationPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let cs = codeState("a")
        let env = environment
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)

        // Integer-second base: the store encodes dates at millisecond
        // precision, so recent round numbers round-trip exactly while the
        // seven-day retention sweep never fires.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var task = try verifiedSuccessTask(
            seed: 120,
            codeState: cs,
            environment: env,
            now: now,
            projectPath: fixture.project.path
        )
        task.environment = env
        _ = AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "rt-1",
            codeState: cs,
            environment: env,
            origin: .explicitUser,
            at: now.addingTimeInterval(10)
        )
        _ = AgentTaskContinuation.submitRevision(
            &task,
            feedbackReference: "rt-2",
            codeState: nil,
            environment: nil,
            origin: .automaticReviewer,
            at: now.addingTimeInterval(11)
        )
        #expect(task.candidateGeneration == 1)
        #expect(task.revisions.count == 2)
        #expect(await store.save(tasks: [task], project: identity)
            == .saved(taskCount: 1))
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.first == task)

        func expectRejected(_ mutate: (inout AgentTask) -> Void) async {
            var copy = task
            mutate(&copy)
            #expect(await store.save(tasks: [copy], project: identity)
                == .rejected(.invalidMetadata))
        }
        // Generation contract violations fail closed.
        await expectRejected { $0.candidateGeneration = 2 }
        await expectRejected { $0.candidateGeneration = 0 }
        await expectRejected {
            $0.revisions[1] = variant($0.revisions[1], generation: 0)
        }
        await expectRejected {
            $0.revisions[0] = variant($0.revisions[0], generation: 0)
        }
        // Reference shape violations fail closed.
        await expectRejected {
            $0.revisions[0] = variant($0.revisions[0], reference: "")
        }
        await expectRejected {
            $0.revisions[0] = variant(
                $0.revisions[0],
                reference: String(repeating: "x", count: 257)
            )
        }
        // Scheme corruption (via the durable encoding) fails closed. Only
        // the revision records carry scheme 1 in this document.
        let taskJSON = try JSONEncoder().encode(task)
        let taskJSONText = try #require(String(data: taskJSON, encoding: .utf8))
        let schemeCorrupted = taskJSONText
            .replacingOccurrences(of: "\"scheme\":1", with: "\"scheme\":2")
        #expect(schemeCorrupted != taskJSONText)
        let corruptedTask = try JSONDecoder().decode(
            AgentTask.self,
            from: Data(schemeCorrupted.utf8)
        )
        #expect(await store.save(tasks: [corruptedTask], project: identity)
            == .rejected(.invalidMetadata))
        // The per-task count bound fails closed.
        let boundedStore = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: AgentTaskPersistenceLimits(maxRevisionRecordsPerTask: 2)
        )
        #expect(await boundedStore.save(tasks: [task], project: identity)
            == .saved(taskCount: 1))
        var overLimit = task
        overLimit.revisions.append(AgentTaskRevisionRecord(
            origin: .automaticReviewer,
            feedbackReference: "rt-3",
            candidateGeneration: 1,
            observedAt: Date().addingTimeInterval(2)
        ))
        #expect(await boundedStore.save(tasks: [overLimit], project: identity)
            == .rejected(.invalidMetadata))

        // Unknown origin raw values decode fail-closed to the origin that
        // grants no cycle-advancing authority.
        let record = AgentTaskRevisionRecord(
            origin: .explicitUser,
            feedbackReference: "rt-decode",
            candidateGeneration: 0,
            observedAt: Date()
        )
        let encoded = try #require(
            String(data: JSONEncoder().encode(record), encoding: .utf8)
        )
        let corrupted = encoded.replacingOccurrences(
            of: "\"explicitUser\"",
            with: "\"explicitUserFuture\""
        )
        #expect(
            (try? JSONDecoder().decode(
                AgentTaskRevisionRecord.self,
                from: Data(corrupted.utf8)
            ))?.origin == .automaticReviewer
        )
    }

    @Test("pre-continuation metadata decodes additively")
    func preContinuationMetadataDecodesAdditively() throws {
        let cs = codeState("a")
        var task = try verifiedSuccessTask(seed: 140, codeState: cs, environment: environment)
        task.environment = environment
        var data = try JSONEncoder().encode(task)
        // Remove the additive keys: older metadata without them decodes to
        // the fail-closed defaults.
        let jsonObject = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var mutable = jsonObject
        mutable.removeValue(forKey: "candidateGeneration")
        mutable.removeValue(forKey: "revisions")
        data = try JSONSerialization.data(withJSONObject: mutable)
        let decoded = try JSONDecoder().decode(AgentTask.self, from: data)
        #expect(decoded.candidateGeneration == 0)
        #expect(decoded.revisions.isEmpty)
        #expect(decoded.id == task.id)
    }
}

// MARK: - Helpers

/// Deterministic monotonic clock for claim-expiry tests.
nonisolated private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousClock.Instant

    init() {
        value = ContinuousClock().now
    }

    func now() -> ContinuousClock.Instant {
        lock.withLock { value }
    }

    func advance(_ duration: Duration) {
        lock.withLock { value = value.advanced(by: duration) }
    }
}

/// Sticky-once-armed persistence fault at the exact write checkpoint (no
/// disarm — unlike the house ArmedSettlementFault): the armed store is
/// abandoned after the fault, so re-arming is not a concern.
nonisolated private final class GatedFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func checkpoint(
        store: PersistenceStoreKind,
        phase: PersistenceWritePhase
    ) throws {
        guard store == .agentTask,
              phase == .beforeWrite,
              lock.withLock({ armed }) else {
            return
        }
        throw PersistenceFailureKind.noSpace
    }
}

private final class ContinuationPersistenceFixture {
    let root: URL
    let project: URL
    let storage: URL

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PineContinuation-\(UUID().uuidString)")
        project = root.appendingPathComponent("project", isDirectory: true)
        // The store creates and owns the private storage directory itself
        // (mode 0700, no inherited ACL); only the clean user-owned parent
        // root is the fixture's responsibility.
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
