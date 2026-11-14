//
//  AgentTaskLifecycleEvidenceTests.swift
//  PineTests
//
//  ADE task lifecycle and evidence contract (issue #1722): execution states,
//  outcomes, evidence facts, fencing, invalidation, Ready projection, and the
//  schema v3 persistence write path for outcome states.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("ADE lifecycle and evidence contract", .serialized)
struct AgentTaskLifecycleEvidenceTests {
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

    /// One attempt with honest chronology. `now` pins timestamps so
    /// registry loads do not trip the seven-day retention sweep.
    private func makeAttempt(
        seed: Int,
        state: AgentRunState = .done,
        liveness: AgentRunLiveness = .terminated,
        accuracy: FirstPartyAgentNotificationAccuracy = .processTerminationOnly,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AgentTaskRunInput {
        AgentTaskRunInput(
            id: uuid(seed + 200),
            terminalID: uuid(seed + 100),
            process: AgentProcessEvidence(
                processIdentifier: Int32(5_000 + seed),
                processGeneration: UInt64(seed),
                startIdentifier: "ade-\(seed)",
                observedStartedAt: now.addingTimeInterval(-300),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: liveness,
                observedAt: now
            ),
            lifecycleAccuracy: accuracy
        )
    }

    private func makeTask(
        seed: Int,
        state: AgentRunState = .done,
        liveness: AgentRunLiveness = .terminated,
        accuracy: FirstPartyAgentNotificationAccuracy = .processTerminationOnly,
        outcome: AgentTaskOutcome? = nil,
        now: Date = Date(timeIntervalSince1970: 1_000),
        projectPath: String? = nil
    ) -> AgentTask {
        let context = AgentTaskBridgeContext(
            project: project(projectPath ?? "/tmp/pine-ade-\(seed)"),
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
            context: context
        )
        var run = AgentTaskRun(makeAttempt(
            seed: seed,
            state: state,
            liveness: liveness,
            accuracy: accuracy,
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
        vendorSession: AgentVendorSessionIdentity? = nil,
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
            vendorSession: vendorSession,
            sourceSequence: sequence,
            preOperationCodeState: pre,
            postOperationCodeState: post
        )
    }

    /// A settled (terminated, outcome recorded, process-completion fact
    /// bound) task, as production settlement produces it.
    private func settledTask(
        seed: Int,
        accuracy: FirstPartyAgentNotificationAccuracy = .processTerminationOnly,
        now: Date = Date(),
        projectPath: String? = nil
    ) -> AgentTask {
        var task = makeTask(
            seed: seed,
            accuracy: accuracy,
            now: now,
            projectPath: projectPath ?? "/tmp/pine-ade-\(seed)"
        )
        AgentTaskLifecycleReducer.settleTerminated(task: &task, runIndex: 0)
        return task
    }

    /// A verified-success task: claim plus passing check and review bound
    /// to one shared code-state identity.
    private func verifiedSuccessTask(
        seed: Int,
        codeState: AgentTaskCodeStateIdentity,
        environment: AgentTaskEnvironmentIdentity,
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
            codeState: codeState,
            environment: environment,
            sequence: 1
        ))
        task.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: UInt64(seed),
            result: .succeeded,
            at: t.addingTimeInterval(1),
            codeState: codeState,
            environment: environment,
            sequence: 2,
            pre: codeState,
            post: codeState
        ))
        task.evidence.append(fact(
            .reviewerOutcome,
            runID: run.id,
            generation: UInt64(seed),
            result: .succeeded,
            at: t.addingTimeInterval(2),
            codeState: codeState,
            environment: environment,
            sequence: 3,
            pre: codeState,
            post: codeState
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        return task
    }

    @Test("Ready refuses checks or review without current environment binding")
    func readyRequiresEnvironmentBinding() throws {
        let cs = codeState("a")
        for kind in AgentTaskLifecycleReducer.requiredEvidenceForSuccess {
            var task = try verifiedSuccessTask(seed: 180, codeState: cs, environment: environment)
            task.evidence = task.evidence.map { existing in
                guard existing.kind == kind else { return existing }
                return fact(kind, runID: existing.runID, generation: existing.processGeneration,
                            result: .succeeded, at: existing.observedAt, codeState: cs,
                            sequence: existing.sourceSequence, pre: cs, post: cs)
            }
            #expect(!AgentTaskLifecycleReducer.readiness(
                for: task, codeState: cs, environment: environment
            ).isReady)
        }
    }

    @Test("Ready and re-verification refuse legacy facts without operation fingerprints")
    func readyRequiresOperationFingerprints() throws {
        let cs = codeState("a")
        for kind in AgentTaskLifecycleReducer.requiredEvidenceForSuccess {
            var task = try verifiedSuccessTask(seed: 181, codeState: cs, environment: environment)
            task.evidence = task.evidence.map { existing in
                guard existing.kind == kind else { return existing }
                return fact(kind, runID: existing.runID, generation: existing.processGeneration,
                            result: .succeeded, at: existing.observedAt, codeState: cs,
                            environment: environment, sequence: existing.sourceSequence)
            }
            #expect(!AgentTaskLifecycleReducer.readiness(
                for: task, codeState: cs, environment: environment
            ).isReady)
            task.verificationState = .stale
            AgentTaskLifecycleReducer.reverify(&task, codeState: cs, environment: environment)
            #expect(task.verificationState == .stale)
        }
    }

    @Test("Current operations remain usable alongside incomplete historical evidence")
    func incompleteHistoryDoesNotMaskCurrentOperations() throws {
        let cs = codeState("a")
        for kind in AgentTaskLifecycleReducer.requiredEvidenceForSuccess {
            for missingEnvironment in [true, false] {
                var task = try verifiedSuccessTask(seed: 182, codeState: cs, environment: environment)
                let run = try #require(task.runs.last)
                let historical = fact(
                    kind, runID: run.id, generation: 182,
                    result: .succeeded, at: task.lastActivityAt, codeState: cs,
                    environment: missingEnvironment ? nil : environment,
                    pre: missingEnvironment ? cs : nil, post: missingEnvironment ? cs : nil
                )
                #expect(AgentTaskLifecycleReducer.isValid(historical))
                task.evidence.insert(historical, at: 0)
                #expect(AgentTaskLifecycleReducer.readiness(
                    for: task, codeState: cs, environment: environment
                ).isReady)
                task.verificationState = .stale
                AgentTaskLifecycleReducer.reverify(&task, codeState: cs, environment: environment)
                #expect(task.verificationState == .verified)
            }
        }
    }

    // MARK: - Execution state

    @Test("a live active turn projects working at every accuracy")
    func workingState() throws {
        for accuracy in [
            FirstPartyAgentNotificationAccuracy.processTerminationOnly,
            FirstPartyAgentNotificationAccuracy.verifiedLifecycleTransitions
        ] {
            let task = makeTask(
                seed: 11,
                state: .executing,
                liveness: .live,
                accuracy: accuracy
            )
            #expect(
                AgentTaskLifecycleReducer.executionState(for: task) == .working
            )
            let thinking = makeTask(
                seed: 12,
                state: .thinking,
                liveness: .live,
                accuracy: accuracy
            )
            #expect(
                AgentTaskLifecycleReducer.executionState(for: thinking) == .working
            )
        }
    }

    @Test("blocked requires a live verified waiting request")
    func blockedState() throws {
        let verified = makeTask(
            seed: 13,
            state: .waitingInput,
            liveness: .live,
            accuracy: .verifiedLifecycleTransitions
        )
        #expect(
            AgentTaskLifecycleReducer.executionState(for: verified) == .blocked
        )
        let processOnly = makeTask(
            seed: 14,
            state: .waitingInput,
            liveness: .live,
            accuracy: .processTerminationOnly
        )
        #expect(
            AgentTaskLifecycleReducer.executionState(for: processOnly)
                == .unknown
        )
    }

    @Test("positive idle evidence is required before idle is presented")
    func idleRequiresPositiveEvidence() throws {
        let verified = makeTask(
            seed: 15,
            state: .idle,
            liveness: .live,
            accuracy: .verifiedLifecycleTransitions
        )
        #expect(
            AgentTaskLifecycleReducer.executionState(for: verified) == .idle
        )
        // Terminal silence at process-only accuracy is unknown, never idle
        // and never completion.
        let silent = makeTask(
            seed: 16,
            state: .idle,
            liveness: .live,
            accuracy: .processTerminationOnly
        )
        #expect(
            AgentTaskLifecycleReducer.executionState(for: silent) == .unknown
        )
        let doneSilent = makeTask(
            seed: 17,
            state: .done,
            liveness: .live,
            accuracy: .processTerminationOnly
        )
        #expect(
            AgentTaskLifecycleReducer.executionState(for: doneSilent) == .unknown
        )
        let doneVerified = makeTask(
            seed: 18,
            state: .done,
            liveness: .live,
            accuracy: .verifiedLifecycleTransitions
        )
        #expect(
            AgentTaskLifecycleReducer.executionState(for: doneVerified) == .idle
        )
    }

    @Test("stale, terminated, and evidence-free runs are unknown")
    func unknownStates() throws {
        #expect(
            AgentTaskLifecycleReducer.executionState(for: settledTask(seed: 19))
                == .unknown
        )
        let stale = makeTask(
            seed: 20,
            state: .executing,
            liveness: .stale
        )
        #expect(
            AgentTaskLifecycleReducer.executionState(for: stale) == .unknown
        )
        var noRuns = makeTask(seed: 21)
        noRuns.runs = []
        #expect(AgentTaskLifecycleReducer.executionState(for: noRuns) == .unknown)
    }

    // MARK: - Settlement invariants

    @Test("process exit settles unverified and never Ready")
    func processExitSettlesUnverified() throws {
        let task = settledTask(seed: 31)
        let run = try #require(task.runs.first)
        #expect(run.outcome == .unverified)
        #expect(task.evidence.map(\.kind) == [.processCompletion])
        #expect(task.lifecycle == .paused)
        #expect(task.attention == .none)
        #expect(task.completedAt == nil)
        #expect(task.verificationState == .none)
        #expect(task.executionState == .unknown)
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState("a"),
            environment: environment
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.unverifiedOutcome))
        #expect(readiness.gaps.contains(.missingEvidence(.independentCheck)))
        #expect(readiness.gaps.contains(.missingEvidence(.reviewerOutcome)))
    }

    @Test("an agent claim alone settles unverified")
    func claimAloneSettlesUnverified() throws {
        var task = settledTask(seed: 32)
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        task.evidence.append(fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: UInt64(32),
            result: .reported,
            at: now,
            codeState: codeState("a"),
            environment: environment,
            sequence: 1
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .unverified)
        #expect(task.lifecycle == .paused)
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState("a"),
            environment: environment
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.unverifiedOutcome))
        #expect(readiness.gaps.contains(.missingEvidence(.independentCheck)))
        #expect(readiness.gaps.contains(.missingEvidence(.reviewerOutcome)))
    }

    @Test("verified evidence settles success and Ready")
    func verifiedEvidenceSettlesSuccess() throws {
        let task = try verifiedSuccessTask(
            seed: 33,
            codeState: codeState("a"),
            environment: environment
        )
        #expect(task.runs.last?.outcome == .success)
        #expect(task.lifecycle == .completed)
        #expect(task.attention == .completed)
        #expect(task.completedAt != nil)
        #expect(task.verificationState == .verified)
        #expect(task.isUnread)
        #expect(task.reviewedSnapshot != nil)
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState("a"),
            environment: environment
        )
        #expect(readiness.isReady)
        #expect(readiness.gaps.isEmpty)
    }

    @Test("success requires one shared code-state identity")
    func successRequiresSharedCodeState() throws {
        var task = settledTask(seed: 34)
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        task.evidence.append(fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: UInt64(34),
            result: .reported,
            at: now,
            codeState: codeState("a"),
            environment: environment,
            sequence: 1
        ))
        // The check ran against a different code state than the claim.
        task.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: UInt64(34),
            result: .succeeded,
            at: now.addingTimeInterval(1),
            codeState: codeState("b"),
            environment: environment,
            sequence: 2
        ))
        task.evidence.append(fact(
            .reviewerOutcome,
            runID: run.id,
            generation: UInt64(34),
            result: .succeeded,
            at: now.addingTimeInterval(2),
            codeState: codeState("a"),
            environment: environment,
            sequence: 3
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .unverified)
    }

    @Test("failing independent evidence settles failure")
    func failingEvidenceSettlesFailure() throws {
        var task = settledTask(seed: 35)
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        task.evidence.append(fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: UInt64(35),
            result: .reported,
            at: now,
            codeState: codeState("a"),
            environment: environment,
            sequence: 1
        ))
        task.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: UInt64(35),
            result: .failed,
            at: now.addingTimeInterval(1),
            codeState: codeState("a"),
            environment: environment,
            sequence: 2
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .failure)
        #expect(task.lifecycle == .completed)
        #expect(task.attention == .failed)
        #expect(task.isUnread)
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState("a"),
            environment: environment
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.failedAttempt))
    }

    @Test("a failing check from an older code state does not veto the claim")
    func staleStateFailureDoesNotVetoCurrentClaim() throws {
        let run = AgentTaskRun(makeAttempt(
            seed: 121,
            liveness: .terminated,
            now: Date(timeIntervalSince1970: 7_000_000)
        ))
        let t = Date(timeIntervalSince1970: 7_000_000)
        // The check failed against an older code state (B)...
        let staleFailure = fact(
            .independentCheck,
            runID: run.id,
            generation: 121,
            result: .failed,
            at: t,
            codeState: codeState("b"),
            environment: environment,
            sequence: 1
        )
        // ...then the agent claimed completion at the current state (A) and
        // the required evidence passed at A.
        let claim = fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: 121,
            result: .reported,
            at: t.addingTimeInterval(1),
            codeState: codeState("a"),
            environment: environment,
            sequence: 2
        )
        let check = fact(
            .independentCheck,
            runID: run.id,
            generation: 121,
            result: .succeeded,
            at: t.addingTimeInterval(2),
            codeState: codeState("a"),
            environment: environment,
            sequence: 3
        )
        let review = fact(
            .reviewerOutcome,
            runID: run.id,
            generation: 121,
            result: .succeeded,
            at: t.addingTimeInterval(3),
            codeState: codeState("a"),
            environment: environment,
            sequence: 4
        )
        // The stale failure is recorded history, not a rejection of the
        // current claim: the attempt settles success in any admission
        // order.
        #expect(
            AgentTaskLifecycleReducer.settleOutcome(
                for: run,
                evidence: [staleFailure, claim, check, review]
            ) == .success
        )
        #expect(
            AgentTaskLifecycleReducer.settleOutcome(
                for: run,
                evidence: [review, check, claim, staleFailure]
            ) == .success
        )
    }

    @Test("a failing check without a completion claim settles unverified")
    func failingCheckWithoutClaimSettlesUnverified() throws {
        var task = settledTask(seed: 122)
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        task.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: UInt64(122),
            result: .failed,
            at: now,
            codeState: codeState("a"),
            environment: environment,
            sequence: 1
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        // A failing check without a claim is recorded evidence, never a
        // rejected result.
        #expect(task.runs.last?.outcome == .unverified)
        #expect(task.lifecycle == .paused)
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState("a"),
            environment: environment
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.unverifiedOutcome))
        #expect(readiness.gaps.contains(.failingEvidence(.independentCheck)))
        #expect(readiness.gaps.contains(.missingEvidence(.reviewerOutcome)))
        #expect(
            readiness.gaps.contains(.missingEvidence(.agentReportedCompletion))
        )
    }

    @Test("an unbound late failure cannot flip a settled success")
    func unboundLateFailureCannotFlipSuccess() throws {
        var task = try verifiedSuccessTask(
            seed: 123,
            codeState: codeState("a"),
            environment: environment
        )
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        // A late failing review with no code-state binding: it cannot prove
        // relevance, so it cannot veto the bound passing review.
        task.evidence.append(fact(
            .reviewerOutcome,
            runID: run.id,
            generation: 123,
            result: .failed,
            at: now.addingTimeInterval(60),
            sequence: 9
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .success)
        #expect(task.verificationState == .verified)
    }

    @Test("readiness names failing evidence bound to the current state")
    func readinessNamesFailingEvidenceForCurrentState() throws {
        // The attempt succeeded at A. A failing check bound to the CURRENT
        // state B does not re-settle the attempt (the claim's state is A),
        // but readiness at B must name the failing evidence.
        var task = try verifiedSuccessTask(
            seed: 124,
            codeState: codeState("a"),
            environment: environment
        )
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        task.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: 124,
            result: .failed,
            at: now.addingTimeInterval(60),
            codeState: codeState("b"),
            environment: environment,
            sequence: 9
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .success)
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState("b"),
            environment: environment
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.failingEvidence(.independentCheck)))
        #expect(readiness.gaps.contains(.staleEvidence(.reviewerOutcome)))
    }

    @Test("readiness names an environment change on a verified success")
    func readinessNamesEnvironmentChangeExactly() throws {
        let task = try verifiedSuccessTask(
            seed: 125,
            codeState: codeState("a"),
            environment: environment
        )
        let otherEnvironment = AgentTaskEnvironmentIdentity(
            osBuild: "26A5388g",
            toolchain: "Xcode 27.0",
            configurationFingerprint: hex("d")
        )
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState("a"),
            environment: otherEnvironment
        )
        #expect(!readiness.isReady)
        #expect(Set(readiness.gaps) == [.environmentChanged])
    }

    @Test("cancellation settles cancellation")
    func cancellationSettlesCancellation() throws {
        var task = settledTask(seed: 36)
        let run = try #require(task.runs.first)
        task.evidence.append(fact(
            .userCancellation,
            runID: run.id,
            generation: UInt64(36),
            result: .cancelled,
            at: task.lastActivityAt,
            trust: .verified
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .cancellation)
        #expect(task.lifecycle == .paused)
        #expect(task.attention == .none)
        #expect(task.completedAt == nil)
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState("a"),
            environment: environment
        )
        #expect(readiness.gaps.contains(.cancelledAttempt))
    }

    // MARK: - Fencing

    @Test("facts fence on attempt, incarnation, chronology, trust, and duplicates")
    func evidenceFencing() throws {
        let registry = AgentTaskRegistry()
        let task = settledTask(seed: 41)
        registry.setTasksForTesting([task])
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt

        #expect(
            registry.recordEvidence(fact(
                .agentReportedCompletion,
                runID: uuid(999),
                generation: UInt64(41),
                result: .reported,
                at: now
            ), taskID: task.id) == .fencedOut(.unknownRun)
        )
        #expect(
            registry.recordEvidence(fact(
                .processCompletion,
                runID: run.id,
                generation: 999,
                result: .exited(status: nil),
                at: now,
                trust: .observed
            ), taskID: task.id) == .fencedOut(.foreignProcess)
        )
        #expect(
            registry.recordEvidence(fact(
                .agentReportedCompletion,
                runID: run.id,
                generation: UInt64(41),
                result: .reported,
                at: run.startedAt.addingTimeInterval(-1)
            ), taskID: task.id) == .fencedOut(.lateEvent)
        )
        #expect(
            registry.recordEvidence(fact(
                .processCompletion,
                runID: run.id,
                generation: UInt64(41),
                result: .exited(status: nil),
                at: now,
                trust: .verified
            ), taskID: task.id) == .fencedOut(.invalidFact)
        )
        #expect(
            registry.recordEvidence(fact(
                .independentCheck,
                runID: run.id,
                generation: UInt64(41),
                result: .exited(status: 0),
                at: now
            ), taskID: task.id) == .fencedOut(.invalidFact)
        )

        let claim = fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: UInt64(41),
            result: .reported,
            at: now,
            sequence: 1
        )
        #expect(registry.recordEvidence(claim, taskID: task.id) == .accepted)
        #expect(
            registry.recordEvidence(claim, taskID: task.id)
                == .fencedOut(.duplicate)
        )

        // A fenced-out batch leaves the task exactly unchanged.
        let before = registry.task(for: task.id)
        let fencedBatch: [AgentTaskEvidenceFact] = [
            fact(
                .independentCheck,
                runID: uuid(1_000_001),
                generation: 1,
                result: .succeeded,
                at: now
            ),
            fact(
                .processCompletion,
                runID: run.id,
                generation: 42,
                result: .exited(status: nil),
                at: now,
                trust: .observed
            ),
            fact(
                .agentReportedCompletion,
                runID: run.id,
                generation: UInt64(41),
                result: .reported,
                at: run.startedAt.addingTimeInterval(-5),
                sequence: 7
            ),
        ]
        for candidate in fencedBatch {
            #expect(
                registry.recordEvidence(candidate, taskID: task.id)
                    != .accepted
            )
        }
        #expect(before == registry.task(for: task.id))
    }

    @Test("foreign and nested provider sessions fence on the session reference")
    func vendorSessionFencing() throws {
        let registry = AgentTaskRegistry()
        var task = settledTask(seed: 42)
        task.runs[0].vendorIdentity = AgentVendorSessionIdentity(
            provider: "codex",
            opaqueIdentifier: "session-1"
        )
        registry.setTasksForTesting([task])
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt

        #expect(
            registry.recordEvidence(fact(
                .agentReportedCompletion,
                runID: run.id,
                generation: UInt64(42),
                result: .reported,
                at: now,
                vendorSession: AgentVendorSessionIdentity(
                    provider: "codex",
                    opaqueIdentifier: "session-2"
                )
            ), taskID: task.id) == .fencedOut(.foreignVendorSession)
        )
        // A nested session with its own opaque identifier is foreign.
        #expect(
            registry.recordEvidence(fact(
                .agentReportedCompletion,
                runID: run.id,
                generation: UInt64(42),
                result: .reported,
                at: now,
                vendorSession: AgentVendorSessionIdentity(
                    provider: "codex",
                    opaqueIdentifier: "session-1/nested"
                )
            ), taskID: task.id) == .fencedOut(.foreignVendorSession)
        )
        // A matching reference is admitted.
        #expect(
            registry.recordEvidence(fact(
                .agentReportedCompletion,
                runID: run.id,
                generation: UInt64(42),
                result: .reported,
                at: now,
                vendorSession: AgentVendorSessionIdentity(
                    provider: "codex",
                    opaqueIdentifier: "session-1"
                )
            ), taskID: task.id) == .accepted
        )
    }

    @Test("late events for a replaced run never settle the newer attempt")
    func lateForeignEventCannotSettleNewerAttempt() throws {
        let registry = AgentTaskRegistry()
        var task = makeTask(seed: 43)
        // A newer attempt replaced the first one on the same terminal.
        let newAttempt = makeAttempt(
            seed: 44,
            state: .executing,
            liveness: .live,
            now: task.lastActivityAt.addingTimeInterval(120)
        )
        task.runs[0].liveness = .terminated
        task.runs[0].endedAt = task.lastActivityAt
        task.runs[0].outcome = .superseded
        let oldRun = task.runs[0]
        task.runs.append(AgentTaskRun(newAttempt))
        task.lifecycle = .active
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        registry.setTasksForTesting([task])
        let newRun = try #require(task.runs.last)

        // A late exit from the old process, misattributed to the new run:
        // fenced by the process incarnation.
        #expect(
            registry.recordEvidence(fact(
                .processCompletion,
                runID: newRun.id,
                generation: UInt64(43),
                result: .exited(status: nil),
                at: task.lastActivityAt.addingTimeInterval(300),
                trust: .observed
            ), taskID: task.id) == .fencedOut(.foreignProcess)
        )
        #expect(registry.task(for: task.id)?.runs.last?.liveness == .live)

        // The same late exit, correctly attributed to the replaced run, is
        // admitted as history and leaves the current attempt untouched.
        #expect(
            registry.recordEvidence(fact(
                .processCompletion,
                runID: oldRun.id,
                generation: UInt64(43),
                result: .exited(status: nil),
                at: task.lastActivityAt.addingTimeInterval(300),
                trust: .observed
            ), taskID: task.id) == .accepted
        )
        let updated = try #require(registry.task(for: task.id))
        #expect(updated.runs.last?.outcome == nil)
        #expect(updated.runs.last?.liveness == .live)
        #expect(updated.runs.first?.outcome == .superseded)
    }

    @Test("replayed and reordered events converge to one settlement")
    func eventReorderingConverges() throws {
        let base = settledTask(seed: 45, now: Date(timeIntervalSince1970: 4_000))
        let run = try #require(base.runs.first)
        let now = Date(timeIntervalSince1970: 5_000)
        let claim = fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: UInt64(45),
            result: .reported,
            at: now,
            codeState: codeState("a"),
            environment: environment,
            sequence: 1
        )
        let check = fact(
            .independentCheck,
            runID: run.id,
            generation: UInt64(45),
            result: .succeeded,
            at: now.addingTimeInterval(1),
            codeState: codeState("a"),
            environment: environment,
            sequence: 2
        )
        let review = fact(
            .reviewerOutcome,
            runID: run.id,
            generation: UInt64(45),
            result: .succeeded,
            at: now.addingTimeInterval(2),
            codeState: codeState("a"),
            environment: environment,
            sequence: 3
        )

        func settle(_ order: [AgentTaskEvidenceFact]) -> AgentTask {
            var task = base
            for fact in order {
                if case .accepted = AgentTaskLifecycleReducer.admit(
                    fact,
                    into: task
                ) {
                    task.evidence.append(fact)
                }
                AgentTaskLifecycleReducer.settleLatestRun(
                    of: &task,
                    runIndex: task.runs.count - 1
                )
            }
            return task
        }

        let first = settle([claim, check, review])
        let reordered = settle([review, claim, check])
        let replayed = settle([claim, check, review, claim, check, review])
        #expect(first.runs.last?.outcome == .success)
        #expect(first.lifecycle == .completed)
        #expect(first.attention == .completed)
        #expect(first.verificationState == .verified)
        for other in [reordered, replayed] {
            #expect(other.runs == first.runs)
            #expect(other.lifecycle == first.lifecycle)
            #expect(other.attention == first.attention)
            #expect(other.completedAt == first.completedAt)
            #expect(other.isUnread == first.isUnread)
            #expect(other.verificationState == first.verificationState)
            #expect(
                Set(other.evidence.map(\.eventIdentity))
                    == Set(first.evidence.map(\.eventIdentity))
            )
        }
    }

    // MARK: - Invalidation and Ready

    @Test("a relevant edit invalidates Ready and names the repeat work")
    func relevantEditInvalidatesReady() throws {
        let registry = AgentTaskRegistry()
        let task = try verifiedSuccessTask(
            seed: 51,
            codeState: codeState("a"),
            environment: environment
        )
        registry.setTasksForTesting([task])
        let before = registry.readiness(
            for: task.id,
            codeState: codeState("a"),
            environment: environment
        )
        #expect(before.isReady)

        let gaps = registry.invalidateEvidence(
            taskID: task.id,
            codeState: codeState("b"),
            environment: environment
        )
        #expect(gaps.contains(.staleEvidence(.independentCheck)))
        #expect(gaps.contains(.staleEvidence(.reviewerOutcome)))

        let updated = try #require(registry.task(for: task.id))
        #expect(updated.verificationState == .stale)
        #expect(updated.lifecycle == .completed)
        // The reviewed history stays identifiable.
        #expect(updated.reviewedSnapshot != nil)

        let readiness = registry.readiness(
            for: task.id,
            codeState: codeState("b"),
            environment: environment
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.verificationNotCurrent))
        #expect(readiness.gaps.contains(.staleEvidence(.independentCheck)))
        #expect(readiness.gaps.contains(.staleEvidence(.reviewerOutcome)))

        // New verification against the edited state cannot re-upgrade a
        // stale verification on its own.
        let run = try #require(updated.runs.first)
        #expect(
            registry.recordEvidence(fact(
                .independentCheck,
                runID: run.id,
                generation: UInt64(51),
                result: .succeeded,
                at: updated.lastActivityAt.addingTimeInterval(1),
                codeState: codeState("b"),
                environment: environment,
                sequence: 4
            ), taskID: task.id) == .accepted
        )
        let after = try #require(registry.task(for: task.id))
        #expect(after.verificationState == .stale)
        #expect(
            !registry.readiness(
                for: task.id,
                codeState: codeState("b"),
                environment: environment
            ).isReady
        )
    }

    @Test("Readiness refuses without a re-proved current state")
    func readinessRefusesWithoutCurrentState() throws {
        let task = try verifiedSuccessTask(
            seed: 52,
            codeState: codeState("a"),
            environment: environment
        )
        let noCodeState = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: nil,
            environment: environment
        )
        #expect(!noCodeState.isReady)
        #expect(noCodeState.gaps.contains(.codeStateUnknown))
        let noEnvironment = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState("a"),
            environment: nil
        )
        #expect(!noEnvironment.isReady)
        #expect(noEnvironment.gaps.contains(.environmentUnknown))
    }

    @Test("user acceptance is a separate fact, never inherited by later edits")
    func acceptanceNeverInherited() throws {
        let registry = AgentTaskRegistry()
        let task = try verifiedSuccessTask(
            seed: 53,
            codeState: codeState("a"),
            environment: environment
        )
        registry.setTasksForTesting([task])
        #expect(
            registry.recordUserAcceptance(
                taskID: task.id,
                codeState: codeState("a"),
                environment: environment
            ) == true
        )
        let accepted = try #require(registry.task(for: task.id))
        #expect(accepted.acceptanceState == .accepted)
        #expect(accepted.acceptedSnapshot?.codeState == codeState("a"))
        #expect(accepted.acceptedSnapshot?.outcome == .success)
        #expect(accepted.lifecycle == .completed)
        #expect(accepted.attention == .completed)

        // A relevant edit: acceptance is dropped, the snapshot preserved.
        _ = registry.invalidateEvidence(
            taskID: task.id,
            codeState: codeState("b"),
            environment: environment
        )
        let afterEdit = try #require(registry.task(for: task.id))
        #expect(afterEdit.acceptanceState == .notAccepted)
        #expect(afterEdit.acceptedSnapshot != nil)
        #expect(afterEdit.verificationState == .stale)

        // Acceptance refuses a failed attempt.
        var failed = settledTask(seed: 54)
        failed.runs[0].outcome = .failure
        failed.lifecycle = .completed
        failed.attention = .failed
        failed.completedAt = failed.runs.last?.endedAt
        registry.setTasksForTesting([failed])
        #expect(
            registry.recordUserAcceptance(
                taskID: failed.id,
                codeState: codeState("a"),
                environment: environment
            ) == false
        )

        // Acceptance refuses a dismissed task: dismissal is an Inbox
        // decision, not an invitation to re-open the work.
        var dismissed = settledTask(seed: 126)
        dismissed.lifecycle = .dismissed
        dismissed.route.availability = .missing
        registry.setTasksForTesting([dismissed])
        let beforeDismissed = try #require(registry.task(for: dismissed.id))
        #expect(
            registry.recordUserAcceptance(
                taskID: dismissed.id,
                codeState: codeState("a"),
                environment: environment
            ) == false
        )
        #expect(beforeDismissed == registry.task(for: dismissed.id))

        // Acceptance may also be recorded against an `unverified` outcome:
        // it closes the work and snapshots the identity, but never upgrades
        // the outcome or the verification state.
        let unverified = settledTask(seed: 127)
        registry.setTasksForTesting([unverified])
        #expect(unverified.runs.last?.outcome == .unverified)
        #expect(
            registry.recordUserAcceptance(
                taskID: unverified.id,
                codeState: codeState("a"),
                environment: environment
            ) == true
        )
        let acceptedUnverified = try #require(
            registry.task(for: unverified.id)
        )
        #expect(acceptedUnverified.acceptanceState == .accepted)
        #expect(acceptedUnverified.runs.last?.outcome == .unverified)
        #expect(acceptedUnverified.verificationState == .none)
        #expect(acceptedUnverified.acceptedSnapshot?.outcome == .unverified)
        #expect(acceptedUnverified.acceptedSnapshot?.codeState == codeState("a"))
        #expect(acceptedUnverified.lifecycle == .completed)
    }

    // MARK: - Registry settlement and persistence (schema v3)

    @Test("a terminated run persists an unverified outcome in schema v3")
    func terminatedRunPersistsUnverifiedOutcome() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        let route = AgentTaskRoute(
            paneID: uuid(61),
            tabID: uuid(61 + 100),
            terminalID: uuid(61 + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: Date()
        )
        let session = ADESessionFixture.make(
            pid: 6_101,
            generation: 1,
            observedAt: Date()
        )
        registry.bridge(session, replacing: nil, context: context)
        session.applyLiveness(.terminated)
        registry.refresh(sessions: [session])

        // A terminated run leaves live ownership; it is still resolvable
        // through the historical index.
        let task = try #require(registry.historicalTask(forSessionID: session.id))
        #expect(task.runs.last?.outcome == .unverified)
        #expect(task.evidence.map(\.kind) == [.processCompletion])
        #expect(task.lifecycle == .paused)
        #expect(task.completedAt == nil)

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
        #expect(root["schemaVersion"] as? Int == 3)
        let tasksJSON = try #require(root["tasks"] as? [[String: Any]])
        let runsJSON = try #require(tasksJSON[0]["runs"] as? [[String: Any]])
        #expect(runsJSON[0]["outcome"] as? String == "unverified")
        #expect((tasksJSON[0]["evidence"] as? [[String: Any]])?.count == 1)
        #expect(tasksJSON[0]["executionState"] as? String == "unknown")

        let reloaded = await store.load(project: identity)
        #expect(reloaded.status == .loaded)
        #expect(!reloaded.requiresMigration)
        #expect(reloaded.tasks.first?.runs.last?.outcome == .unverified)
        #expect(reloaded.tasks.first?.evidence.count == 1)
    }

    @Test("outcome states without an evidence basis are rejected")
    func outcomeStateWithoutEvidenceBasisIsRejected() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let projectPath = fixture.project.path

        // Completed triple, but the settled run carries no outcome and no
        // evidence fact: the legacy guard's purpose, now evidence-based.
        var unbacked = settledTask(
            seed: 62,
            now: Date(),
            projectPath: projectPath
        )
        unbacked.lifecycle = .completed
        unbacked.attention = .completed
        unbacked.completedAt = unbacked.runs.last?.endedAt
        unbacked.runs[0].outcome = nil
        unbacked.evidence = []
        #expect(
            await store.save(tasks: [unbacked], project: identity)
                == .rejected(.invalidMetadata)
        )

        // Outcome without a bound evidence fact.
        var factless = settledTask(
            seed: 63,
            now: Date(),
            projectPath: projectPath
        )
        factless.lifecycle = .completed
        factless.attention = .completed
        factless.completedAt = factless.runs.last?.endedAt
        factless.evidence = []
        #expect(
            await store.save(tasks: [factless], project: identity)
                == .rejected(.invalidMetadata)
        )

        // completedAt without the completed lifecycle.
        var dateless = settledTask(
            seed: 64,
            now: Date(),
            projectPath: projectPath
        )
        dateless.completedAt = dateless.runs.last?.endedAt
        #expect(
            await store.save(tasks: [dateless], project: identity)
                == .rejected(.invalidMetadata)
        )

        // The honest production state persists: paused + unverified +
        // observed process completion.
        let honest = settledTask(
            seed: 65,
            now: Date(),
            projectPath: projectPath
        )
        #expect(
            await store.save(tasks: [honest], project: identity)
                == .saved(taskCount: 1)
        )
    }

    @Test("evidence facts persist with their fencing keys and bounds")
    func evidenceFactsPersistenceValidation() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let projectPath = fixture.project.path

        // A fact bound to the wrong process incarnation is invalid.
        var foreign = settledTask(seed: 66, now: Date(), projectPath: projectPath)
        let run = try #require(foreign.runs.first)
        foreign.evidence.append(fact(
            .independentCheck,
            runID: run.id,
            generation: 999,
            result: .succeeded,
            at: foreign.lastActivityAt
        ))
        #expect(
            await store.save(tasks: [foreign], project: identity)
                == .rejected(.invalidMetadata)
        )

        // A duplicated event identity is invalid.
        var duplicated = settledTask(seed: 67, now: Date(), projectPath: projectPath)
        duplicated.evidence.append(duplicated.evidence[0])
        #expect(
            await store.save(tasks: [duplicated], project: identity)
                == .rejected(.invalidMetadata)
        )

        // A fact predating its run is invalid.
        var late = settledTask(seed: 68, now: Date(), projectPath: projectPath)
        late.evidence.append(fact(
            .agentReportedCompletion,
            runID: late.runs[0].id,
            generation: UInt64(68),
            result: .reported,
            at: late.runs[0].startedAt.addingTimeInterval(-1)
        ))
        #expect(
            await store.save(tasks: [late], project: identity)
                == .rejected(.invalidMetadata)
        )

        // Process observations never carry verified trust.
        var overTrusted = settledTask(seed: 69, now: Date(), projectPath: projectPath)
        overTrusted.evidence = [fact(
            .processCompletion,
            runID: overTrusted.runs[0].id,
            generation: UInt64(69),
            result: .exited(status: nil),
            at: overTrusted.lastActivityAt,
            trust: .verified
        )]
        #expect(
            await store.save(tasks: [overTrusted], project: identity)
                == .rejected(.invalidMetadata)
        )

        // The per-task evidence bound is enforced.
        let boundedStore = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: AgentTaskPersistenceLimits(maxEvidenceFactsPerTask: 1)
        )
        var tooMany = settledTask(seed: 70, now: Date(), projectPath: projectPath)
        tooMany.evidence.append(fact(
            .agentReportedCompletion,
            runID: tooMany.runs[0].id,
            generation: UInt64(70),
            result: .reported,
            at: tooMany.lastActivityAt,
            sequence: 1
        ))
        #expect(
            await boundedStore.save(tasks: [tooMany], project: identity)
                == .rejected(.invalidMetadata)
        )

        // A coherent verified-success task round-trips through v3.
        let verified = try verifiedSuccessTask(
            seed: 71,
            codeState: codeState("a"),
            environment: environment,
            now: Date(),
            projectPath: projectPath
        )
        #expect(
            await store.save(tasks: [verified], project: identity)
                == .saved(taskCount: 1)
        )
        let reloaded = await store.load(project: identity)
        #expect(reloaded.status == .loaded)
        let task = try #require(reloaded.tasks.first)
        #expect(task.runs.last?.outcome == .success)
        #expect(task.verificationState == .verified)
        #expect(task.reviewedSnapshot?.codeState == codeState("a"))
        #expect(task.evidence.count == 4)
    }

    @Test("verified success projects to the Inbox and a legacy completion event")
    func verifiedSuccessProjectsToInboxAndNotifications() throws {
        let registry = AgentTaskRegistry()
        let live = makeTask(
            seed: 72,
            state: .executing,
            liveness: .live,
            accuracy: .verifiedLifecycleTransitions,
            now: Date()
        )
        var settled = live
        settled.runs[0].liveness = .terminated
        settled.runs[0].endedAt = live.runs[0].lastObservedAt
        settled.lifecycle = .paused
        settled.route.availability = .missing
        AgentTaskLifecycleReducer.settleTerminated(task: &settled, runIndex: 0)
        registry.setTasksForTesting([settled])

        let run = try #require(settled.runs.first)
        let now = settled.lastActivityAt
        let cs = codeState("a")
        #expect(
            registry.recordEvidence(fact(
                .agentReportedCompletion,
                runID: run.id,
                generation: UInt64(72),
                result: .reported,
                at: now,
                codeState: cs,
                environment: environment,
                sequence: 1
            ), taskID: settled.id) == .accepted
        )
        #expect(
            registry.recordEvidence(fact(
                .independentCheck,
                runID: run.id,
                generation: UInt64(72),
                result: .succeeded,
                at: now.addingTimeInterval(1),
                codeState: cs,
                environment: environment,
                sequence: 2
            ), taskID: settled.id) == .accepted
        )
        #expect(
            registry.recordEvidence(fact(
                .reviewerOutcome,
                runID: run.id,
                generation: UInt64(72),
                result: .succeeded,
                at: now.addingTimeInterval(2),
                codeState: cs,
                environment: environment,
                sequence: 3
            ), taskID: settled.id) == .accepted
        )
        let after = try #require(registry.task(for: settled.id))
        #expect(after.runs.last?.outcome == .success)

        let snapshot = AgentInboxSnapshot(tasks: [after])
        let row = try #require(snapshot.rows.first)
        #expect(row.section == .completedUnread)
        #expect(row.outcome == .success)
        #expect(row.executionState == .unknown)

        // The legacy completion event means "reported or appeared to
        // finish" — it must not be read as a verified-result or Ready
        // notification.
        let events = AgentNotificationTransitionResolver.events(
            from: [live],
            to: [after],
            accuracy: { _ in .verifiedLifecycleTransitions }
        )
        #expect(events.map(\.kind) == [.completed])
        #expect(events.map(\.taskID) == [settled.id])
    }

    @Test("process-only accuracy never emits a completion event")
    func processOnlyAccuracyStaysProcessEnded() throws {
        let registry = AgentTaskRegistry()
        let live = makeTask(
            seed: 73,
            state: .executing,
            liveness: .live,
            now: Date()
        )
        var settled = live
        settled.runs[0].liveness = .terminated
        settled.runs[0].endedAt = live.runs[0].lastObservedAt
        settled.lifecycle = .paused
        settled.route.availability = .missing
        AgentTaskLifecycleReducer.settleTerminated(task: &settled, runIndex: 0)
        registry.setTasksForTesting([settled])
        let after = try #require(registry.task(for: live.id))
        #expect(after.runs.last?.outcome == .unverified)

        let events = AgentNotificationTransitionResolver.events(
            from: [live],
            to: [after],
            accuracy: { _ in .processTerminationOnly }
        )
        #expect(events.map(\.kind) == [.processEnded])
    }

    @Test("relaunch invalidates verified evidence but preserves history")
    func relaunchInvalidatesVerifiedEvidence() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let verified = try verifiedSuccessTask(
            seed: 74,
            codeState: codeState("a"),
            environment: environment,
            now: Date(),
            projectPath: fixture.project.path
        )
        let accepted = AgentTaskRegistry(persistence: store)
        accepted.registerProject(identity)
        #expect(await accepted.flushPersistence() == .saved)
        accepted.setTasksForTesting([verified])
        _ = accepted.recordUserAcceptance(
            taskID: verified.id,
            codeState: codeState("a"),
            environment: environment
        )
        #expect(await accepted.flushPersistence() == .saved)

        // A relaunch is a fresh registry over the same durable store.
        let reloaded = AgentTaskRegistry(persistence: store)
        reloaded.registerProject(identity)
        #expect(await reloaded.flushPersistence() == .saved)
        let task = try #require(reloaded.tasks.first)
        #expect(task.runs.last?.outcome == .success)
        #expect(task.lifecycle == .completed)
        #expect(task.verificationState == .stale)
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.acceptedSnapshot?.codeState == codeState("a"))
        #expect(task.reviewedSnapshot != nil)
        #expect(task.executionState == .unknown)
    }

    @Test("a failed settlement persists with failed attention")
    func failedSettlementPersists() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let live = makeTask(
            seed: 75,
            state: .executing,
            liveness: .live,
            accuracy: .verifiedLifecycleTransitions,
            now: Date(),
            projectPath: fixture.project.path
        )
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        var task = live
        task.runs[0].liveness = .terminated
        task.runs[0].endedAt = live.runs[0].lastObservedAt
        task.lifecycle = .paused
        task.route.availability = .missing
        AgentTaskLifecycleReducer.settleTerminated(task: &task, runIndex: 0)
        registry.setTasksForTesting([task])
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        #expect(
            registry.recordEvidence(fact(
                .agentReportedCompletion,
                runID: run.id,
                generation: UInt64(75),
                result: .reported,
                at: now,
                codeState: codeState("a"),
                environment: environment,
                sequence: 1
            ), taskID: task.id) == .accepted
        )
        #expect(
            registry.recordEvidence(fact(
                .reviewerOutcome,
                runID: run.id,
                generation: UInt64(75),
                result: .requestedChanges,
                at: now.addingTimeInterval(1),
                codeState: codeState("a"),
                environment: environment,
                sequence: 2
            ), taskID: task.id) == .accepted
        )
        let after = try #require(registry.task(for: task.id))
        #expect(after.runs.last?.outcome == .failure)
        #expect(after.attention == .failed)
        #expect(after.lifecycle == .completed)
        #expect(await registry.registerProjectAndFlush(identity) == .saved)

        let snapshot = AgentInboxSnapshot(tasks: [after])
        #expect(snapshot.rows.first?.section == .failed)

        let events = AgentNotificationTransitionResolver.events(
            from: [live],
            to: [after],
            accuracy: { _ in .verifiedLifecycleTransitions }
        )
        #expect(events.map(\.kind) == [.failed])
    }

    @Test("PID replacement supersedes the replaced run")
    func pidReplacementSupersedes() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-ade-supersede")
        let context = AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(
                paneID: uuid(76),
                tabID: uuid(76 + 100),
                terminalID: uuid(76 + 100)
            ),
            origin: .discoveredInTerminal,
            observedAt: Date()
        )
        let first = ADESessionFixture.make(
            pid: 7_601,
            generation: 1,
            start: "Mon Aug 3 10:00:00 2026",
            observedAt: Date()
        )
        registry.bridge(first, replacing: nil, context: context)
        let replacement = ADESessionFixture.make(
            pid: 7_602,
            generation: 2,
            start: "Mon Aug 3 10:05:00 2026",
            observedAt: Date().addingTimeInterval(300)
        )
        registry.bridge(replacement, replacing: first, context: context)

        let oldTask = try #require(registry.historicalTask(forSessionID: first.id))
        let newTask = try #require(registry.task(forSessionID: replacement.id))
        #expect(oldTask.id != newTask.id)
        #expect(oldTask.runs.last?.outcome == .superseded)
        #expect(oldTask.runs.last?.liveness == .terminated)
        #expect(newTask.runs.last?.outcome == nil)
        #expect(newTask.lifecycle == .active)
    }

    @Test("a failed settlement write never leaves partial outcome state")
    func failedSettlementWriteFailsClosed() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let fault = ArmedSettlementFault()
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                faultInjector: PersistenceFaultInjector(injection: { storeKind, phase in
                    try fault.throwWhileArmed(store: storeKind, phase: phase)
                })
            )
        )
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        let context = AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(
                paneID: uuid(77),
                tabID: uuid(77 + 100),
                terminalID: uuid(77 + 100)
            ),
            origin: .discoveredInTerminal,
            observedAt: Date()
        )
        let session = ADESessionFixture.make(
            pid: 7_701,
            generation: 1,
            observedAt: Date()
        )
        registry.bridge(session, replacing: nil, context: context)
        #expect(await registry.flushPersistence() == .saved)
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let liveData = try Data(contentsOf: file)

        // Settle and force every save to fail before durability.
        fault.arm()
        session.applyLiveness(.terminated)
        registry.refresh(sessions: [session])
        let task = try #require(registry.historicalTask(forSessionID: session.id))
        #expect(task.runs.last?.outcome == .unverified)
        #expect(await registry.flushPersistence() == .failed)

        // The file still holds the pre-settlement state, byte for byte: the
        // outcome, its evidence fact, and the completion state are one
        // atomic write, so a crash between them cannot leave a partial
        // state behind.
        #expect(try Data(contentsOf: file) == liveData)
        let liveRoot = try #require(
            JSONSerialization.jsonObject(with: liveData) as? [String: Any]
        )
        let liveTasks = try #require(liveRoot["tasks"] as? [[String: Any]])
        let liveRuns = try #require(liveTasks[0]["runs"] as? [[String: Any]])
        #expect(liveRuns[0]["outcome"] == nil)
        #expect((liveTasks[0]["evidence"] as? [Any])?.isEmpty == true)

        // A crash before the durable save recovers the consistent
        // pre-settlement state.
        let crashed = await store.load(project: identity)
        #expect(crashed.status == .loaded)
        #expect(crashed.tasks.first?.runs.last?.outcome == nil)
        #expect(crashed.tasks.first?.evidence.isEmpty == true)

        // With the fault gone the settlement publishes atomically.
        fault.disarm()
        #expect(await registry.flushPersistence() == .saved)
        let settledRoot = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: file)
            ) as? [String: Any]
        )
        let settledTasks = try #require(
            settledRoot["tasks"] as? [[String: Any]]
        )
        let settledRuns = try #require(
            settledTasks[0]["runs"] as? [[String: Any]]
        )
        #expect(settledRuns[0]["outcome"] as? String == "unverified")
        #expect((settledTasks[0]["evidence"] as? [[String: Any]])?.count == 1)

        // And a fresh store reads the settled state back consistently.
        let recovered = await store.load(project: identity)
        #expect(recovered.status == .loaded)
        #expect(recovered.tasks.first?.runs.last?.outcome == .unverified)
        #expect(recovered.tasks.first?.evidence.count == 1)
    }

    @Test("the sanitized lifecycle evidence fixture decodes and settles verified")
    func lifecycleEvidenceFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AgentAdapters/lifecycle-evidence-v1.json")
        struct EvidenceFixture: Decodable {
            let schemaVersion: Int
            let facts: [AgentTaskEvidenceFact]
        }
        let fixture = try JSONDecoder().decode(
            EvidenceFixture.self,
            from: Data(contentsOf: url)
        )
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.facts.map(\.kind) == [
            .processCompletion,
            .agentReportedCompletion,
            .independentCheck,
            .reviewerOutcome,
            .userAcceptance,
        ])
        #expect(Set(fixture.facts.map(\.runID)).count == 1)
        #expect(Set(fixture.facts.map(\.processGeneration)).count == 1)
        #expect(fixture.facts[0].trust == .observed)
        #expect(fixture.facts.dropFirst().allSatisfy { $0.trust == .verified })

        // The facts describe one terminated attempt: exit alone settles
        // unverified; the full independent set settles success.
        let startedAt = Date(timeIntervalSince1970: 1_759_999_990)
        let endedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let context = AgentTaskBridgeContext(
            project: project("/tmp/pine-ade-79"),
            route: AgentTaskRoute(
                paneID: uuid(79),
                tabID: uuid(79 + 100),
                terminalID: uuid(79 + 100),
                availability: .missing
            ),
            origin: .discoveredInTerminal,
            observedAt: endedAt
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            terminalID: uuid(79 + 100),
            process: AgentProcessEvidence(
                processIdentifier: 79,
                processGeneration: 1,
                startIdentifier: "fixture-79",
                observedStartedAt: startedAt,
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: .done,
                liveness: .terminated,
                observedAt: endedAt
            )
        ))]
        task.lifecycle = .paused
        task.updatedAt = endedAt
        task.lastActivityAt = endedAt

        task.evidence = [fixture.facts[0]]
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .unverified)

        task.evidence = Array(fixture.facts.prefix(4))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .success)
        #expect(task.verificationState == .verified)
        #expect(task.lifecycle == .completed)
        let readiness = AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: fixture.facts[1].codeState,
            environment: fixture.facts[1].environment
        )
        #expect(readiness.isReady)
    }

    @Test("trimmed run history with settled evidence stays loadable")
    func trimmedHistoryWithSettledRunsLoads() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: AgentTaskPersistenceLimits(maxRunsPerTask: 2)
        )
        let registry = AgentTaskRegistry(persistence: store)
        let sharedRoute = AgentTaskRoute(
            paneID: uuid(81),
            tabID: uuid(81 + 100),
            terminalID: uuid(81 + 100)
        )
        let baseContext = AgentTaskBridgeContext(
            project: identity,
            route: sharedRoute,
            origin: .pineLaunched,
            observedAt: Date()
        )
        var previous = ADESessionFixture.make(
            pid: 8_101,
            generation: 1,
            observedAt: Date()
        )
        guard case .reserved(let initial) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: .claudeCode,
                launchExecutable: "claude"
            ),
            context: baseContext,
            title: nil,
            objective: nil,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 0,
                capturedAt: .distantPast
            )
        ) else {
            Issue.record("initial reservation was rejected")
            return
        }
        #expect(registry.armLaunch(initial))
        registry.bridge(
            previous,
            replacing: nil,
            context: baseContext,
            reservation: initial
        )
        let retainedTaskID = try #require(
            registry.taskID(forSessionID: previous.id)
        )
        for sequence in 2...4 {
            previous.applyLiveness(.terminated)
            previous.recordLifecycleState(
                .done,
                accuracy: .processTerminationOnly
            )
            registry.refresh(sessions: [previous])
            let nextStartedAt = Date().addingTimeInterval(
                TimeInterval(sequence)
            )
            let next = ADESessionFixture.make(
                pid: 8_100 + Int32(sequence),
                generation: UInt64(sequence),
                observedAt: nextStartedAt
            )
            let resumeContext = AgentTaskBridgeContext(
                project: identity,
                route: sharedRoute,
                origin: .pineLaunched,
                observedAt: nextStartedAt
            )
            guard case .reserved(let reservation) = registry.prepareResume(
                taskID: retainedTaskID,
                context: resumeContext,
                boundary: AgentTaskLaunchBoundary(
                    generationFloor: 0,
                    capturedAt: .distantPast
                )
            ) else {
                Issue.record("resume reservation was rejected")
                return
            }
            #expect(registry.armLaunch(reservation))
            registry.bridge(
                next,
                replacing: previous,
                context: resumeContext,
                reservation: reservation
            )
            previous = next
        }
        let save = await store.save(
            tasks: registry.tasks,
            project: identity
        )
        let loaded = await store.load(project: identity)
        if save != .saved(taskCount: 1) || loaded.status != .loaded {
            let diagnostic = "save: \(save), load: \(loaded.status)"
            Issue.record("trimmed settled history failed to round-trip: \(diagnostic)")
        }
        #expect(save == .saved(taskCount: 1))
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.count == 1)
    }

    @Test("future raw values decode fail-closed")
    func futureRawValuesDecodeFailClosed() throws {
        let task = try verifiedSuccessTask(
            seed: 78,
            codeState: codeState("a"),
            environment: environment
        )
        let data = try JSONEncoder().encode(task)
        var root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        root["executionState"] = "future-execution"
        root["verificationState"] = "future-verification"
        root["acceptanceState"] = "future-acceptance"
        var runs = try #require(root["runs"] as? [[String: Any]])
        runs[0]["outcome"] = "future-outcome"
        root["runs"] = runs
        let tampered = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(AgentTask.self, from: tampered)
        #expect(decoded.executionState == .unknown)
        #expect(decoded.verificationState == .stale)
        #expect(decoded.acceptanceState == .notAccepted)
        #expect(decoded.runs.last?.outcome == .unverified)
    }

    // MARK: - Review fix round

    @Test("registry run trim with equal limits keeps saves loadable")
    func registryTrimWithEqualLimitsKeepsSavesLoadable() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let limits = AgentTaskPersistenceLimits(maxRunsPerTask: 2)
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: limits
        )
        // The registry trims with the SAME limit as the store, so the
        // store-side trim (and its evidence filter) never fires: the
        // registry trim must shed the facts of the runs it removes.
        let registry = AgentTaskRegistry(persistence: store, limits: limits)
        let sharedRoute = AgentTaskRoute(
            paneID: uuid(91),
            tabID: uuid(91 + 100),
            terminalID: uuid(91 + 100)
        )
        let baseContext = AgentTaskBridgeContext(
            project: identity,
            route: sharedRoute,
            origin: .pineLaunched,
            observedAt: Date()
        )
        var previous = ADESessionFixture.make(
            pid: 9_101,
            generation: 1,
            observedAt: Date()
        )
        guard case .reserved(let initial) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: .claudeCode,
                launchExecutable: "claude"
            ),
            context: baseContext,
            title: nil,
            objective: nil,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 0,
                capturedAt: .distantPast
            )
        ) else {
            Issue.record("initial reservation was rejected")
            return
        }
        #expect(registry.armLaunch(initial))
        registry.bridge(
            previous,
            replacing: nil,
            context: baseContext,
            reservation: initial
        )
        let retainedTaskID = try #require(
            registry.taskID(forSessionID: previous.id)
        )
        for sequence in 2...5 {
            previous.applyLiveness(.terminated)
            previous.recordLifecycleState(
                .done,
                accuracy: .processTerminationOnly
            )
            registry.refresh(sessions: [previous])
            let nextStartedAt = Date().addingTimeInterval(
                TimeInterval(sequence)
            )
            let next = ADESessionFixture.make(
                pid: 9_100 + Int32(sequence),
                generation: UInt64(sequence),
                observedAt: nextStartedAt
            )
            let resumeContext = AgentTaskBridgeContext(
                project: identity,
                route: sharedRoute,
                origin: .pineLaunched,
                observedAt: nextStartedAt
            )
            guard case .reserved(let reservation) = registry.prepareResume(
                taskID: retainedTaskID,
                context: resumeContext,
                boundary: AgentTaskLaunchBoundary(
                    generationFloor: 0,
                    capturedAt: .distantPast
                )
            ) else {
                Issue.record("resume reservation was rejected")
                return
            }
            #expect(registry.armLaunch(reservation))
            registry.bridge(
                next,
                replacing: previous,
                context: resumeContext,
                reservation: reservation
            )
            previous = next
        }
        // Five attempts, equal limits: the first three runs were trimmed
        // away, and each of them carries a settled processCompletion fact.
        let task = try #require(registry.task(for: retainedTaskID))
        #expect(task.runs.count == 2)
        let save = await store.save(
            tasks: registry.tasks,
            project: identity
        )
        #expect(save == .saved(taskCount: 1))
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.count == 1)
    }

    @Test("dismissing a completed outcome stays saveable")
    func dismissAfterSuccessStaysSaveable() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        let cs = codeState("d")

        func settleSuccess(terminalSeed: Int, pid: Int32) throws -> UUID {
            let route = AgentTaskRoute(
                paneID: uuid(terminalSeed),
                tabID: uuid(terminalSeed + 100),
                terminalID: uuid(terminalSeed + 100)
            )
            let context = AgentTaskBridgeContext(
                project: identity,
                route: route,
                origin: .discoveredInTerminal,
                observedAt: Date()
            )
            let session = ADESessionFixture.make(
                pid: pid,
                generation: 1,
                observedAt: Date()
            )
            registry.bridge(session, replacing: nil, context: context)
            let taskID = try #require(
                registry.taskID(forSessionID: session.id)
            )
            session.applyLiveness(.terminated)
            registry.refresh(sessions: [session])
            let run = try #require(
                registry.task(for: taskID)?.runs.last
            )
            let base = try #require(run.endedAt)
            for (offset, kind, result, sequence) in [
                (0, AgentTaskEvidenceKind.agentReportedCompletion,
                 AgentTaskEvidenceResult.reported, 1),
                (1, AgentTaskEvidenceKind.independentCheck,
                 AgentTaskEvidenceResult.succeeded, 2),
                (2, AgentTaskEvidenceKind.reviewerOutcome,
                 AgentTaskEvidenceResult.succeeded, 3),
            ] {
                #expect(
                    registry.recordEvidence(fact(
                        kind,
                        runID: run.id,
                        generation: 1,
                        result: result,
                        at: base.addingTimeInterval(TimeInterval(offset)),
                        codeState: cs,
                        environment: environment,
                        sequence: UInt64(sequence)
                    ), taskID: taskID) == .accepted
                )
            }
            #expect(
                registry.task(for: taskID)?.runs.last?.outcome == .success
            )
            #expect(registry.task(for: taskID)?.lifecycle == .completed)
            return taskID
        }

        // Dismissal path: .completed carries completedAt; dismissing must
        // clear it, or every subsequent save of the project is rejected.
        let firstID = try settleSuccess(terminalSeed: 93, pid: 9_301)
        #expect(await registry.flushPersistence() == .saved)
        #expect(registry.dismissTask(firstID))
        #expect(await registry.flushPersistence() == .saved)

        // Retention-sweep path: an old completed task is dismissed by the
        // sweep and the project must stay saveable.
        let secondID = try settleSuccess(terminalSeed: 94, pid: 9_401)
        let swept = registry.reconcileTerminalRetention(
            at: Date().addingTimeInterval(8 * 86_400)
        )
        #expect(swept == 1)
        #expect(registry.task(for: secondID)?.lifecycle == .dismissed)
        #expect(await registry.flushPersistence() == .saved)
    }

    @Test("settlement at the fact cap fences and stays saveable")
    func settlementAtFactCapFencesAndSaves() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let t1 = Date(timeIntervalSince1970: 2_000_000)
        let t2 = t1.addingTimeInterval(1_000)
        var task = makeTask(
            seed: 95,
            liveness: .terminated,
            now: t1,
            projectPath: fixture.project.path
        )
        task.runs.append(AgentTaskRun(makeAttempt(
            seed: 96,
            liveness: .terminated,
            now: t2
        )))
        // Task routing and chronology follow the newest attempt, the same
        // invariants a production resume maintains.
        let secondRun = try #require(task.runs.last)
        let secondRunEnd = try #require(secondRun.endedAt)
        task.route = AgentTaskRoute(
            paneID: task.route.paneID,
            tabID: secondRun.terminalID,
            terminalID: secondRun.terminalID,
            availability: .missing
        )
        task.updatedAt = max(task.updatedAt, secondRunEnd)
        task.lastActivityAt = max(task.lastActivityAt, secondRunEnd)
        let firstRun = try #require(task.runs.first)
        task.evidence = [
            fact(
                .processCompletion,
                runID: firstRun.id,
                generation: 95,
                result: .exited(status: nil),
                at: try #require(firstRun.endedAt),
                trust: .observed
            )
        ]
        for sequence in 1..<64 {
            task.evidence.append(fact(
                .independentCheck,
                runID: firstRun.id,
                generation: 95,
                result: .succeeded,
                at: firstRun.startedAt.addingTimeInterval(
                    TimeInterval(sequence)
                ),
                sequence: UInt64(sequence)
            ))
        }
        #expect(task.evidence.count == 64)

        // The cap is reached; settling the second run must fence the
        // observation (no 65th fact) yet still settle the attempt.
        AgentTaskLifecycleReducer.settleTerminated(task: &task, runIndex: 1)
        #expect(task.runs.last?.outcome == .unverified)
        #expect(task.evidence.count == 64)
        #expect(
            await store.save(tasks: [task], project: identity)
                == .saved(taskCount: 1)
        )
    }

    @Test("a stale refresh presents unknown execution state")
    func staleRefreshPresentsUnknownExecution() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        let route = AgentTaskRoute(
            paneID: uuid(97),
            tabID: uuid(97 + 100),
            terminalID: uuid(97 + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: Date()
        )
        let session = ADESessionFixture.make(
            pid: 9_701,
            generation: 1,
            observedAt: Date()
        )
        session.recordLifecycleState(
            .executing,
            accuracy: .verifiedLifecycleTransitions
        )
        registry.bridge(session, replacing: nil, context: context)
        registry.refresh(sessions: [session])
        let taskID = try #require(registry.taskID(forSessionID: session.id))
        #expect(registry.task(for: taskID)?.executionState == .working)

        // The detector loses positive liveness: the stored execution state
        // must follow to unknown, not stay working.
        session.applyLiveness(.stale)
        registry.refresh(sessions: [session])
        #expect(registry.task(for: taskID)?.executionState == .unknown)
    }

    @Test("evidence sheds toward the file budget before rejecting")
    func evidenceShedsTowardFileBudget() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let limits = AgentTaskPersistenceLimits(maxFileBytes: 16_384)
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: limits
        )
        let t = Date(timeIntervalSince1970: 3_000_000)

        func factBound(
            _ run: AgentTaskRun,
            offset: Int,
            sequence: UInt64?
        ) -> AgentTaskEvidenceFact {
            fact(
                .independentCheck,
                runID: run.id,
                generation: run.process.processGeneration,
                result: .succeeded,
                at: run.startedAt.addingTimeInterval(
                    TimeInterval(offset)
                ),
                sequence: sequence
            )
        }

        func twoRunTask(seed: Int) throws -> AgentTask {
            var task = makeTask(
                seed: seed,
                liveness: .terminated,
                now: t,
                projectPath: fixture.project.path
            )
            let older = try #require(task.runs.first)
            task.runs.append(AgentTaskRun(makeAttempt(
                seed: seed + 1,
                liveness: .terminated,
                now: t.addingTimeInterval(500)
            )))
            let newest = try #require(task.runs.last)
            let newestEnd = try #require(newest.endedAt)
            task.route = AgentTaskRoute(
                paneID: task.route.paneID,
                tabID: newest.terminalID,
                terminalID: newest.terminalID,
                availability: .missing
            )
            task.updatedAt = max(task.updatedAt, newestEnd)
            task.lastActivityAt = max(task.lastActivityAt, newestEnd)
            task.evidence = (0..<40).map {
                factBound(older, offset: $0 + 1, sequence: UInt64($0 + 1))
            } + (0..<10).map {
                factBound(newest, offset: $0 + 1, sequence: nil)
            }
            task.lifecycle = .paused
            return task
        }

        // Two tasks far over the budget: the oldest runs' facts are shed,
        // the latest runs' facts survive, and the save succeeds.
        let first = try twoRunTask(seed: 101)
        let second = try twoRunTask(seed: 110)
        let save = await store.save(
            tasks: [first, second],
            project: identity
        )
        #expect(save == .saved(taskCount: 2))
        let loaded = try #require(await store.load(project: identity))
        #expect(loaded.status == .loaded)
        for task in loaded.tasks {
            let latestRun = try #require(task.runs.last)
            #expect(
                task.evidence.allSatisfy { $0.runID == latestRun.id }
            )
            #expect(task.evidence.count == 10)
        }

        // A settled .completed task whose facts all bind its latest run
        // cannot shed toward the budget: the save fails closed.
        var completed = makeTask(
            seed: 103,
            liveness: .terminated,
            now: t,
            projectPath: fixture.project.path
        )
        let run = try #require(completed.runs.first)
        let endedAt = try #require(run.endedAt)
        var evidence = [
            fact(
                .agentReportedCompletion,
                runID: run.id,
                generation: run.process.processGeneration,
                result: .reported,
                at: endedAt.addingTimeInterval(1),
                codeState: codeState("e"),
                environment: environment,
                sequence: 1
            ),
            fact(
                .independentCheck,
                runID: run.id,
                generation: run.process.processGeneration,
                result: .succeeded,
                at: endedAt.addingTimeInterval(2),
                codeState: codeState("e"),
                environment: environment,
                sequence: 2
            ),
            fact(
                .reviewerOutcome,
                runID: run.id,
                generation: run.process.processGeneration,
                result: .succeeded,
                at: endedAt.addingTimeInterval(3),
                codeState: codeState("e"),
                environment: environment,
                sequence: 3
            ),
        ]
        for offset in 0..<61 {
            evidence.append(factBound(run, offset: offset + 10, sequence: nil))
        }
        completed.evidence = evidence
        completed.runs[0].outcome = .success
        completed.lifecycle = .completed
        completed.attention = .completed
        completed.completedAt = endedAt
        let tightStore = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: AgentTaskPersistenceLimits(maxFileBytes: 4_096)
        )
        #expect(
            await tightStore.save(tasks: [completed], project: identity)
                == .rejected(.storageLimit)
        )
        // The rejection must not tear the durable file.
        let intact = await store.load(project: identity)
        #expect(intact.status == .loaded)
        #expect(intact.tasks.count == 2)
    }

    @Test("a replayed sequence with a skewed timestamp cannot flip a settled outcome")
    func replayWithSkewedTimestampCannotFlipOutcome() throws {
        var task = try verifiedSuccessTask(
            seed: 104,
            codeState: codeState("f"),
            environment: environment
        )
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt

        // A reconnect re-emits the reviewer outcome: same source sequence,
        // different (skewed) observed timestamp, failing result. Ordered
        // delivery deduplicates by sequence alone, so this is a duplicate,
        // never a new event.
        let replay = fact(
            .reviewerOutcome,
            runID: run.id,
            generation: 104,
            result: .failed,
            at: now.addingTimeInterval(3_600),
            sequence: 3
        )
        #expect(
            AgentTaskLifecycleReducer.admit(replay, into: task)
                == .fencedOut(.duplicate)
        )
        // And re-settling from the admitted facts cannot flip the outcome.
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .success)
    }

    @Test("sub-millisecond unordered facts survive the save/load round trip")
    func subMillisecondFactsSurviveRoundTrip() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        var task = settledTask(
            seed: 105,
            now: Date(timeIntervalSince1970: 4_000_001.379),
            projectPath: fixture.project.path
        )
        let run = try #require(task.runs.first)
        let base = try #require(run.endedAt).timeIntervalSince1970
        let first = Date(timeIntervalSince1970: base + 0.000_2)
        let second = Date(timeIntervalSince1970: base + 0.001_1)
        let firstFact = fact(
            .independentCheck,
            runID: run.id,
            generation: 105,
            result: .succeeded,
            at: first
        )
        let secondFact = fact(
            .independentCheck,
            runID: run.id,
            generation: 105,
            result: .succeeded,
            at: second
        )
        #expect(
            AgentTaskLifecycleReducer.admit(firstFact, into: task)
                == .accepted
        )
        task.evidence.append(firstFact)
        #expect(
            AgentTaskLifecycleReducer.admit(secondFact, into: task)
                == .accepted
        )
        task.evidence.append(secondFact)

        #expect(
            await store.save(tasks: [task], project: identity)
                == .saved(taskCount: 1)
        )
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.first?.evidence.count == task.evidence.count)
    }

    @Test("a settled outcome survives a replacement endRun")
    func settledOutcomeSurvivesReplacementEndRun() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        let route = AgentTaskRoute(
            paneID: uuid(106),
            tabID: uuid(106 + 100),
            terminalID: uuid(106 + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: Date()
        )
        let previous = ADESessionFixture.make(
            pid: 1_060_001,
            generation: 1,
            observedAt: Date()
        )
        registry.bridge(previous, replacing: nil, context: context)
        let taskID = try #require(
            registry.taskID(forSessionID: previous.id)
        )

        // Detector pass: the replaced session arrives ALREADY terminated
        // in the same bridge call that hands the terminal over. The
        // registry settles the finished run from its evidence, then the
        // replacement detach calls endRun — which must not overwrite the
        // settled outcome.
        previous.applyLiveness(.terminated)
        previous.recordLifecycleState(
            .done,
            accuracy: .processTerminationOnly
        )
        let replacement = ADESessionFixture.make(
            pid: 1_060_002,
            generation: 2,
            observedAt: Date().addingTimeInterval(1)
        )
        registry.bridge(
            replacement,
            replacing: previous,
            context: context
        )
        let settled = registry.task(for: taskID)
        #expect(settled?.runs.first?.outcome == .unverified)
        #expect(
            settled?.evidence.map(\.kind) == [.processCompletion]
        )
    }

    @Test("endRun refreshes the stored execution state")
    func endRunRefreshesExecutionState() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        let route = AgentTaskRoute(
            paneID: uuid(107),
            tabID: uuid(107 + 100),
            terminalID: uuid(107 + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: Date()
        )
        let previous = ADESessionFixture.make(
            pid: 1_070_001,
            generation: 1,
            observedAt: Date()
        )
        previous.recordLifecycleState(
            .executing,
            accuracy: .verifiedLifecycleTransitions
        )
        registry.bridge(previous, replacing: nil, context: context)
        registry.refresh(sessions: [previous])
        let taskID = try #require(
            registry.taskID(forSessionID: previous.id)
        )
        #expect(registry.task(for: taskID)?.executionState == .working)

        // Discovery of a different process in the same terminal detaches
        // the owner through endRun without appending to that task: its
        // stored execution state must follow the terminated run.
        let intruder = ADESessionFixture.make(
            pid: 1_070_002,
            generation: 2,
            observedAt: Date().addingTimeInterval(1)
        )
        registry.bridge(intruder, replacing: nil, context: context)
        let detached = registry.task(for: taskID)
        #expect(detached?.executionState == .unknown)
        #expect(detached?.runs.last?.outcome == .superseded)
    }

    @Test("success is impossible without each required factor")
    func successRequiresEachRequiredFactor() throws {
        let run = AgentTaskRun(makeAttempt(
            seed: 108,
            liveness: .terminated,
            now: Date(timeIntervalSince1970: 5_000_000)
        ))
        let cs = codeState("g")
        let t = Date(timeIntervalSince1970: 5_000_000)
        let claim = fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: 108,
            result: .reported,
            at: t,
            codeState: cs,
            environment: environment,
            sequence: 1
        )
        let check = fact(
            .independentCheck,
            runID: run.id,
            generation: 108,
            result: .succeeded,
            at: t.addingTimeInterval(1),
            codeState: cs,
            environment: environment,
            sequence: 2
        )
        let review = fact(
            .reviewerOutcome,
            runID: run.id,
            generation: 108,
            result: .succeeded,
            at: t.addingTimeInterval(2),
            codeState: cs,
            environment: environment,
            sequence: 3
        )
        #expect(
            AgentTaskLifecycleReducer.settleOutcome(
                for: run,
                evidence: [claim, check]
            ) == .unverified
        )
        #expect(
            AgentTaskLifecycleReducer.settleOutcome(
                for: run,
                evidence: [claim, review]
            ) == .unverified
        )
        #expect(
            AgentTaskLifecycleReducer.settleOutcome(
                for: run,
                evidence: [check, review]
            ) == .unverified
        )
        #expect(
            AgentTaskLifecycleReducer.settleOutcome(
                for: run,
                evidence: [claim, check, review]
            ) == .success
        )
    }

    @Test("re-settling away from a verified success resets verification and acceptance")
    func reSettleAwayFromAcceptanceResetsState() throws {
        let cs = codeState("h")
        var task = try verifiedSuccessTask(
            seed: 109,
            codeState: cs,
            environment: environment
        )
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        task.acceptanceState = .accepted
        task.acceptedSnapshot = AgentTaskResultSnapshot(
            runID: run.id,
            outcome: .success,
            codeState: cs,
            environment: environment,
            recordedAt: now
        )
        // A late failing review bound to the claim's code state re-settles
        // the attempt to failure.
        task.evidence.append(fact(
            .reviewerOutcome,
            runID: run.id,
            generation: 109,
            result: .failed,
            at: now.addingTimeInterval(60),
            codeState: cs,
            sequence: 9
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        #expect(task.runs.last?.outcome == .failure)
        // A failed result cannot stay verified: the verification dimension
        // resets, while the reviewed and accepted snapshots stay
        // identifiable.
        #expect(task.verificationState == .none)
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.acceptedSnapshot?.runID == run.id)
        #expect(task.reviewedSnapshot?.runID == run.id)
    }

    @Test("the latest agent claim wins when claims disagree")
    func latestAgentClaimWins() throws {
        let run = AgentTaskRun(makeAttempt(
            seed: 110,
            liveness: .terminated,
            now: Date(timeIntervalSince1970: 6_000_000)
        ))
        let t = Date(timeIntervalSince1970: 6_000_000)
        let oldClaim = fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: 110,
            result: .reported,
            at: t,
            codeState: codeState("i"),
            environment: environment,
            sequence: 1
        )
        let newClaim = fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: 110,
            result: .reported,
            at: t.addingTimeInterval(60),
            codeState: codeState("j"),
            environment: environment,
            sequence: 2
        )
        let check = fact(
            .independentCheck,
            runID: run.id,
            generation: 110,
            result: .succeeded,
            at: t.addingTimeInterval(61),
            codeState: codeState("j"),
            environment: environment,
            sequence: 3
        )
        let review = fact(
            .reviewerOutcome,
            runID: run.id,
            generation: 110,
            result: .succeeded,
            at: t.addingTimeInterval(62),
            codeState: codeState("j"),
            environment: environment,
            sequence: 4
        )
        // The latest observed claim wins deterministically, regardless of
        // array order.
        #expect(
            AgentTaskLifecycleReducer.settleOutcome(
                for: run,
                evidence: [oldClaim, newClaim, check, review]
            ) == .success
        )
        #expect(
            AgentTaskLifecycleReducer.settleOutcome(
                for: run,
                evidence: [review, check, newClaim, oldClaim]
            ) == .success
        )
    }

    @Test("re-verification restores Ready after an invalidating edit")
    func reverificationRestoresReady() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        // Hex-digit tags: persisted code-state fingerprints are validated
        // as lowercase hex.
        let csOld = codeState("b")
        let csNew = codeState("9")
        let env = environment

        let route = AgentTaskRoute(
            paneID: uuid(112),
            tabID: uuid(112 + 100),
            terminalID: uuid(112 + 100)
        )
        let context = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: Date()
        )
        let session = ADESessionFixture.make(
            pid: 1_120_001,
            generation: 1,
            observedAt: Date()
        )
        registry.bridge(session, replacing: nil, context: context)
        let taskID = try #require(registry.taskID(forSessionID: session.id))
        session.applyLiveness(.terminated)
        registry.refresh(sessions: [session])
        let run = try #require(registry.task(for: taskID)?.runs.last)
        let endedAt = try #require(run.endedAt)
        for (offset, kind, result, sequence) in [
            (0, AgentTaskEvidenceKind.agentReportedCompletion,
             AgentTaskEvidenceResult.reported, 1),
            (1, AgentTaskEvidenceKind.independentCheck,
             AgentTaskEvidenceResult.succeeded, 2),
            (2, AgentTaskEvidenceKind.reviewerOutcome,
             AgentTaskEvidenceResult.succeeded, 3),
        ] {
            #expect(
                registry.recordEvidence(fact(
                    kind,
                    runID: run.id,
                    generation: 1,
                    result: result,
                    at: endedAt.addingTimeInterval(TimeInterval(offset)),
                    codeState: csOld,
                    environment: env,
                    sequence: UInt64(sequence),
                    pre: kind == .agentReportedCompletion ? nil : csOld,
                    post: kind == .agentReportedCompletion ? nil : csOld
                ), taskID: taskID) == .accepted
            )
        }
        #expect(
            registry.readiness(
                for: taskID,
                codeState: csOld,
                environment: env
            ).isReady
        )

        // A relevant edit: the current code state is proven by the caller.
        let gaps = registry.invalidateEvidence(
            taskID: taskID,
            codeState: csNew,
            environment: env
        )
        #expect(registry.task(for: taskID)?.verificationState == .stale)
        #expect(
            gaps.contains(.staleEvidence(.independentCheck))
                && gaps.contains(.staleEvidence(.reviewerOutcome))
        )
        #expect(
            !registry.readiness(
                for: taskID,
                codeState: csNew,
                environment: env
            ).isReady
        )

        // The verification layer marks in-flight verification...
        #expect(registry.markVerificationPending(taskID: taskID))
        #expect(registry.task(for: taskID)?.verificationState == .pending)
        // ...re-records the required evidence bound to the NEW identity...
        for (offset, kind, result, sequence) in [
            (0, AgentTaskEvidenceKind.independentCheck,
             AgentTaskEvidenceResult.succeeded, 4),
            (1, AgentTaskEvidenceKind.reviewerOutcome,
             AgentTaskEvidenceResult.succeeded, 5),
        ] {
            #expect(
                registry.recordEvidence(fact(
                    kind,
                    runID: run.id,
                    generation: 1,
                    result: result,
                    at: endedAt.addingTimeInterval(
                        TimeInterval(10 + offset)
                    ),
                    codeState: csNew,
                    environment: env,
                    sequence: UInt64(sequence),
                    pre: csNew,
                    post: csNew
                ), taskID: taskID) == .accepted
            )
        }
        // ...and grants current verification: Ready against the new state.
        #expect(
            registry.markVerificationCurrent(
                taskID: taskID,
                codeState: csNew,
                environment: env
            )
        )
        #expect(
            registry.task(for: taskID)?.verificationState == .verified
        )
        #expect(
            registry.readiness(
                for: taskID,
                codeState: csNew,
                environment: env
            ).isReady
        )
        #expect(await registry.flushPersistence() == .saved)
    }

    @Test("duplicate run IDs in a v3 file reject without trapping")
    func duplicateRunIDsRejectFailClosed() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let honest = settledTask(
            seed: 113,
            now: Date(),
            projectPath: fixture.project.path
        )
        #expect(
            await store.save(tasks: [honest], project: identity)
                == .saved(taskCount: 1)
        )
        // Corrupt the durable file (user-editable 0600): duplicate the
        // run ID. This must reject fail-closed, never trap the process.
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        var root = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fileURL)
            ) as? [String: Any]
        )
        var tasks = try #require(root["tasks"] as? [[String: Any]])
        var runs = try #require(tasks[0]["runs"] as? [[String: Any]])
        runs.append(runs[0])
        tasks[0]["runs"] = runs
        root["tasks"] = tasks
        let corrupted = try JSONSerialization.data(withJSONObject: root)
        try corrupted.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )

        let loaded = await store.load(project: identity)
        #expect(loaded.status == .rejected(.invalidMetadata))
    }

    // MARK: - Durable ADE relationship (#1722 C1/C2/D4)

    @Test("the task environment binding persists and validates")
    func environmentBindingPersistsAndValidates() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let writer = AgentTaskRegistry(persistence: store)
        writer.registerProject(identity)
        #expect(await writer.flushPersistence() == .saved)
        let context = AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(
                paneID: uuid(133),
                tabID: uuid(133 + 100),
                terminalID: uuid(133 + 100)
            ),
            origin: .discoveredInTerminal,
            observedAt: Date()
        )
        let session = ADESessionFixture.make(
            pid: 1_330_001,
            generation: 1,
            observedAt: Date()
        )
        writer.bridge(session, replacing: nil, context: context)
        let taskID = try #require(writer.taskID(forSessionID: session.id))

        // A valid binding is stamped and durable.
        let env = AgentTaskEnvironmentIdentity(
            osBuild: "26A5388g",
            toolchain: "Xcode 27.0",
            configurationFingerprint: hex("e")
        )
        #expect(writer.bindEnvironment(env, to: taskID))
        #expect(writer.task(for: taskID)?.environment == env)
        #expect(await writer.flushPersistence() == .saved)
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.first?.environment == env)

        // A v3 file without the key decodes to nil.
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        var root = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fileURL)
            ) as? [String: Any]
        )
        var tasks = try #require(root["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "environment")
        root["tasks"] = tasks
        let stripped = try JSONSerialization.data(withJSONObject: root)
        try stripped.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        let strippedLoaded = await store.load(project: identity)
        #expect(strippedLoaded.status == .loaded)
        #expect(strippedLoaded.tasks.first?.environment == nil)

        // Invalid environments are rejected; the task is unchanged.
        let before = try #require(writer.task(for: taskID))
        #expect(
            !writer.bindEnvironment(
                AgentTaskEnvironmentIdentity(
                    scheme: 99,
                    osBuild: nil,
                    toolchain: nil,
                    configurationFingerprint: nil
                ),
                to: taskID
            )
        )
        #expect(
            !writer.bindEnvironment(
                AgentTaskEnvironmentIdentity(
                    osBuild: String(repeating: "x", count: 65),
                    toolchain: nil,
                    configurationFingerprint: nil
                ),
                to: taskID
            )
        )
        #expect(
            !writer.bindEnvironment(
                AgentTaskEnvironmentIdentity(
                    osBuild: nil,
                    toolchain: nil,
                    configurationFingerprint: "nothex"
                ),
                to: taskID
            )
        )
        #expect(before == writer.task(for: taskID))
    }

    @Test("feedback records are bounded, content-free, and durable")
    func feedbackRecordsAreBoundedAndDurable() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let writer = AgentTaskRegistry(persistence: store)
        writer.registerProject(identity)
        #expect(await writer.flushPersistence() == .saved)
        let context = AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(
                paneID: uuid(134),
                tabID: uuid(134 + 100),
                terminalID: uuid(134 + 100)
            ),
            origin: .discoveredInTerminal,
            observedAt: Date()
        )
        let session = ADESessionFixture.make(
            pid: 1_340_001,
            generation: 1,
            observedAt: Date()
        )
        writer.bridge(session, replacing: nil, context: context)
        let taskID = try #require(writer.taskID(forSessionID: session.id))
        let stateA = codeState("a")
        let longReference = String(repeating: "x", count: 256)

        // The reference is bounded at admission: empty and over-long
        // references reject, the 256-byte boundary is accepted.
        #expect(!writer.recordFeedback("", codeState: nil, for: taskID))
        #expect(
            !writer.recordFeedback(
                String(repeating: "x", count: 257),
                codeState: nil,
                for: taskID
            )
        )
        #expect(
            writer.recordFeedback(longReference, codeState: nil, for: taskID)
        )

        // Append + durable round-trip, with the code-state binding.
        #expect(writer.recordFeedback("ref-1", codeState: stateA, for: taskID))
        #expect(writer.recordFeedback("ref-2", codeState: nil, for: taskID))
        #expect(await writer.flushPersistence() == .saved)
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(
            loaded.tasks.first?.feedback.map(\.reference)
                == [longReference, "ref-1", "ref-2"]
        )
        #expect(
            loaded.tasks.first?.feedback[1].codeState == stateA
        )
        #expect(loaded.tasks.first?.feedback[0].codeState == nil)

        // A v3 file without the key decodes to [].
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        var root = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fileURL)
            ) as? [String: Any]
        )
        var tasks = try #require(root["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "feedback")
        root["tasks"] = tasks
        let stripped = try JSONSerialization.data(withJSONObject: root)
        try stripped.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        let strippedLoaded = await store.load(project: identity)
        #expect(strippedLoaded.status == .loaded)
        #expect(strippedLoaded.tasks.first?.feedback.isEmpty == true)

        // Admission is bounded at one point: fill to the per-task limit,
        // then the next record is fenced and the count stays put.
        for index in 4...32 {
            #expect(
                writer.recordFeedback("ref-\(index)", codeState: nil, for: taskID)
            )
        }
        #expect(writer.task(for: taskID)?.feedback.count == 32)
        #expect(
            !writer.recordFeedback("ref-33", codeState: nil, for: taskID)
        )
        #expect(writer.task(for: taskID)?.feedback.count == 32)
        #expect(await writer.flushPersistence() == .saved)
    }

    @Test("legacy retired defaults preserve the project envelope but are not launch defaults")
    func retiredRememberedAgentPreservesEnvelope() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let descriptor = try JSONDecoder().decode(
            AgentDescriptor.self,
            from: Data(#"{"typeIdentifier":"empryo","launchExecutable":"empryo"}"#.utf8)
        )
        let honest = settledTask(seed: 131, now: Date(), projectPath: fixture.project.path)
        var legacyTaskObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(
                settledTask(seed: 132, now: Date(), projectPath: fixture.project.path)
            )) as? [String: Any]
        )
        legacyTaskObject["descriptor"] = ["typeIdentifier": "empryo", "launchExecutable": "empryo"]
        let legacyTask = try JSONDecoder().decode(
            AgentTask.self, from: JSONSerialization.data(withJSONObject: legacyTaskObject)
        )
        let envelope = AgentTaskEnvelopeState(
            rememberedAgent: descriptor, rememberedAgentUpdatedAt: Date()
        )
        #expect(await store.save(tasks: [honest, legacyTask], envelope: envelope, project: identity) == .saved(taskCount: 2))
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.first { $0.id == legacyTask.id }?.descriptor == descriptor)
        #expect(loaded.tasks.count == 2)
        #expect(loaded.envelope.rememberedAgent == descriptor)
        #expect(loaded.envelope.rememberedAgent?.agentType == .generic(name: "Empry⊙"))
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        #expect(registry.rememberedAgentDescriptor(for: identity) == nil)
        #expect(registry.tasks.count == 2)
        let restored = try #require(registry.tasks.first { $0.id == legacyTask.id })
        #expect(restored.descriptor.agentType == .generic(name: "Empry⊙"))
        #expect(restored.route.availability == .missing)
        #expect(restored.verificationState != .verified)
    }

    @Test("the remembered default agent persists per project")
    func rememberedAgentPersistsPerProject() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)

        // Store-level envelope round-trip.
        let descriptorD1 = AgentDescriptor(
            agentType: .claudeCode,
            launchExecutable: "claude"
        )
        let updatedAt = Date(timeIntervalSince1970: 1_760_000_000.0)
        let envelope = AgentTaskEnvelopeState(
            rememberedAgent: descriptorD1,
            rememberedAgentUpdatedAt: updatedAt
        )
        let honest = settledTask(
            seed: 131,
            now: Date(),
            projectPath: fixture.project.path
        )
        #expect(
            await store.save(
                tasks: [honest],
                envelope: envelope,
                project: identity
            ) == .saved(taskCount: 1)
        )
        let loadedEnvelope = await store.load(project: identity)
        #expect(loadedEnvelope.status == .loaded)
        #expect(loadedEnvelope.envelope.rememberedAgent == descriptorD1)
        #expect(
            loadedEnvelope.envelope.rememberedAgentUpdatedAt
                == updatedAt
        )

        // A file without the fields decodes to the empty envelope.
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        var root = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fileURL)
            ) as? [String: Any]
        )
        root.removeValue(forKey: "rememberedAgent")
        root.removeValue(forKey: "rememberedAgentUpdatedAt")
        let stripped = try JSONSerialization.data(withJSONObject: root)
        try stripped.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        let strippedLoaded = await store.load(project: identity)
        #expect(strippedLoaded.status == .loaded)
        #expect(strippedLoaded.envelope == .empty)

        // A file with an unbounded remembered agent rejects fail-closed.
        var invalid = root
        invalid["rememberedAgent"] = [
            "typeIdentifier": String(repeating: "x", count: 256),
        ]
        invalid["rememberedAgentUpdatedAt"] =
            updatedAt.timeIntervalSince1970
        let invalidData = try JSONSerialization.data(withJSONObject: invalid)
        try invalidData.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        #expect(
            (await store.load(project: identity)).status
                == .rejected(.invalidMetadata)
        )
    }

    @Test("preparePineLaunch remembers the explicit agent choice per project")
    func preparePineLaunchRemembersAgentChoice() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let writer = AgentTaskRegistry(persistence: store)
        writer.registerProject(identity)
        #expect(await writer.flushPersistence() == .saved)
        #expect(writer.rememberedAgentDescriptor(for: identity) == nil)

        func launch(
            routeSeed: Int,
            descriptor: AgentDescriptor
        ) throws -> AgentTaskLaunchReservation {
            let route = AgentTaskRoute(
                paneID: uuid(routeSeed),
                tabID: uuid(routeSeed + 100),
                terminalID: uuid(routeSeed + 100)
            )
            let context = AgentTaskBridgeContext(
                project: identity,
                route: route,
                origin: .pineLaunched,
                observedAt: Date()
            )
            guard case .reserved(let reservation) = writer.preparePineLaunch(
                descriptor: descriptor,
                context: context,
                title: nil,
                objective: nil,
                boundary: AgentTaskLaunchBoundary(
                    generationFloor: 0,
                    capturedAt: .distantPast
                )
            ) else {
                throw CocoaError(.coderInvalidValue)
            }
            return reservation
        }

        // The first launch records the explicit choice...
        let d1 = AgentDescriptor(
            agentType: .claudeCode,
            launchExecutable: "claude"
        )
        let first = try launch(routeSeed: 141, descriptor: d1)
        #expect(writer.rememberedAgentDescriptor(for: identity) == d1)
        #expect(await writer.flushPersistence() == .saved)

        // ...an explicit second launch with a DIFFERENT descriptor updates
        // it: the explicit choice always wins.
        let d2 = AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        )
        let second = try launch(routeSeed: 142, descriptor: d2)
        #expect(writer.rememberedAgentDescriptor(for: identity) == d2)
        #expect(await writer.flushPersistence() == .saved)

        // A resume of the first task does not change it.
        #expect(writer.armLaunch(first))
        #expect(writer.isLaunchPending(first))
        let session = ADESessionFixture.make(
            pid: 1_410_001,
            generation: 1,
            observedAt: Date()
        )
        let route1 = AgentTaskRoute(
            paneID: uuid(141),
            tabID: uuid(141 + 100),
            terminalID: uuid(141 + 100)
        )
        let context1 = AgentTaskBridgeContext(
            project: identity,
            route: route1,
            origin: .pineLaunched,
            observedAt: Date()
        )
        writer.bridge(
            session,
            replacing: nil,
            context: context1,
            reservation: first
        )
        let firstTaskID = try #require(
            writer.taskID(forSessionID: session.id)
        )
        session.applyLiveness(.terminated)
        writer.refresh(sessions: [session])
        #expect(await writer.flushPersistence() == .saved)
        let resumeResult = writer.prepareResume(
            taskID: firstTaskID,
            context: context1,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 0,
                capturedAt: .distantPast
            )
        )
        #expect(resumeResult != .rejected)
        if case .reserved(let resumeReservation) = resumeResult {
            writer.cancelLaunch(resumeReservation)
        }
        #expect(writer.rememberedAgentDescriptor(for: identity) == d2)
        _ = second

        // The remembered agent is envelope-level: it survives the retention
        // sweep dismissing every task in the project.
        #expect(
            writer.reconcileTerminalRetention(
                at: Date().addingTimeInterval(8 * 86_400)
            ) >= 1
        )
        #expect(await writer.flushPersistence() == .saved)
        let reloaded = AgentTaskRegistry(persistence: store)
        reloaded.registerProject(identity)
        #expect(await reloaded.flushPersistence() == .saved)
        #expect(
            reloaded.rememberedAgentDescriptor(for: identity) == d2
        )
    }

    @Test("operation fingerprints must be consistent with the fact code state")
    func operationFingerprintsMustBeConsistent() throws {
        let registry = AgentTaskRegistry()
        let task = settledTask(seed: 135)
        registry.setTasksForTesting([task])
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        let csA = codeState("a")
        let csB = codeState("b")

        // pre == post == the fact's code state: admitted.
        #expect(
            registry.recordEvidence(fact(
                .independentCheck,
                runID: run.id,
                generation: UInt64(135),
                result: .succeeded,
                at: now,
                codeState: csA,
                sequence: 1,
                pre: csA,
                post: csA,
            ), taskID: task.id) == .accepted
        )
        // pre != post: fenced.
        #expect(
            registry.recordEvidence(fact(
                .reviewerOutcome,
                runID: run.id,
                generation: UInt64(135),
                result: .succeeded,
                at: now.addingTimeInterval(1),
                codeState: csA,
                sequence: 2,
                pre: csA,
                post: csB,
            ), taskID: task.id) == .fencedOut(.invalidFact)
        )
        // Only pre present: fenced.
        #expect(
            registry.recordEvidence(fact(
                .independentCheck,
                runID: run.id,
                generation: UInt64(135),
                result: .succeeded,
                at: now.addingTimeInterval(2),
                codeState: csA,
                sequence: 3,
                pre: csA,
            ), taskID: task.id) == .fencedOut(.invalidFact)
        )
        // Fingerprints that differ from the fact's own code state: fenced.
        #expect(
            registry.recordEvidence(fact(
                .independentCheck,
                runID: run.id,
                generation: UInt64(135),
                result: .succeeded,
                at: now.addingTimeInterval(3),
                codeState: csA,
                sequence: 4,
                pre: csB,
                post: csB,
            ), taskID: task.id) == .fencedOut(.invalidFact)
        )
        // Fingerprints on a non-check fact: fenced.
        #expect(
            registry.recordEvidence(fact(
                .processCompletion,
                runID: run.id,
                generation: UInt64(135),
                result: .exited(status: nil),
                at: now.addingTimeInterval(4),
                trust: .observed,
                sequence: 5,
                pre: csA,
                post: csA,
            ), taskID: task.id) == .fencedOut(.invalidFact)
        )
        // Legacy facts without fingerprints remain valid.
        #expect(
            registry.recordEvidence(fact(
                .independentCheck,
                runID: run.id,
                generation: UInt64(135),
                result: .succeeded,
                at: now.addingTimeInterval(5),
                codeState: csA,
                sequence: 6
            ), taskID: task.id) == .accepted
        )
    }

    @Test("operation fingerprints persist and reject fail-closed")
    func operationFingerprintsPersistAndRejectFailClosed() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let projectPath = fixture.project.path
        let csA = codeState("a")
        let csB = codeState("b")

        // Valid fingerprints persist and round-trip through v3.
        var valid = settledTask(seed: 136, now: Date(), projectPath: projectPath)
        valid.evidence.append(fact(
            .independentCheck,
            runID: valid.runs[0].id,
            generation: UInt64(136),
            result: .succeeded,
            at: valid.lastActivityAt,
            codeState: csA,
            sequence: 1,
            pre: csA,
            post: csA,
        ))
        #expect(
            await store.save(tasks: [valid], project: identity)
                == .saved(taskCount: 1)
        )
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.first?.evidence.last?.preOperationCodeState == csA)
        #expect(loaded.tasks.first?.evidence.last?.postOperationCodeState == csA)

        // A file with pre != post rejects fail-closed.
        var mismatched = settledTask(
            seed: 137,
            now: Date(),
            projectPath: projectPath
        )
        mismatched.evidence.append(fact(
            .independentCheck,
            runID: mismatched.runs[0].id,
            generation: UInt64(137),
            result: .succeeded,
            at: mismatched.lastActivityAt,
            codeState: csA,
            sequence: 1,
            pre: csA,
            post: csB,
        ))
        #expect(
            await store.save(tasks: [mismatched], project: identity)
                == .rejected(.invalidMetadata)
        )

        // A file with fingerprints on a non-check fact rejects fail-closed.
        var misplaced = settledTask(
            seed: 138,
            now: Date(),
            projectPath: projectPath
        )
        misplaced.evidence.append(fact(
            .agentReportedCompletion,
            runID: misplaced.runs[0].id,
            generation: UInt64(138),
            result: .reported,
            at: misplaced.lastActivityAt,
            sequence: 1,
            pre: csA,
            post: csA,
        ))
        #expect(
            await store.save(tasks: [misplaced], project: identity)
                == .rejected(.invalidMetadata)
        )
    }

    @Test("code-state and environment shape validation rejects malformed identities")
    func codeStateAndEnvironmentShapeValidation() throws {
        let valid = codeState("a")
        #expect(AgentTaskMetadataStore.validCodeState(valid))

        // Uppercase hex is rejected: fingerprints are lowercase only.
        #expect(
            !AgentTaskMetadataStore.validCodeState(
                AgentTaskCodeStateIdentity(
                    headCommit: valid.headCommit,
                    trackedFingerprint: valid.trackedFingerprint.uppercased(),
                    untrackedFingerprint: valid.untrackedFingerprint,
                    ignoredRelevantFingerprint: valid.ignoredRelevantFingerprint
                )
            )
        )
        // A non-hex digit is rejected.
        #expect(
            !AgentTaskMetadataStore.validCodeState(
                AgentTaskCodeStateIdentity(
                    headCommit: valid.headCommit,
                    trackedFingerprint: valid.trackedFingerprint,
                    untrackedFingerprint: String(repeating: "g", count: 64),
                    ignoredRelevantFingerprint: valid.ignoredRelevantFingerprint
                )
            )
        )
        // Fingerprints must be exactly 64 bytes.
        #expect(
            !AgentTaskMetadataStore.validCodeState(
                AgentTaskCodeStateIdentity(
                    headCommit: valid.headCommit,
                    trackedFingerprint: String(valid.trackedFingerprint.dropLast()),
                    untrackedFingerprint: valid.untrackedFingerprint,
                    ignoredRelevantFingerprint: valid.ignoredRelevantFingerprint
                )
            )
        )
        #expect(
            !AgentTaskMetadataStore.validCodeState(
                AgentTaskCodeStateIdentity(
                    headCommit: valid.headCommit,
                    trackedFingerprint: valid.trackedFingerprint + "a",
                    untrackedFingerprint: valid.untrackedFingerprint,
                    ignoredRelevantFingerprint: valid.ignoredRelevantFingerprint
                )
            )
        )
        // A future (or zero) scheme is rejected fail-closed.
        #expect(
            !AgentTaskMetadataStore.validCodeState(
                AgentTaskCodeStateIdentity(
                    scheme: 2,
                    headCommit: valid.headCommit,
                    trackedFingerprint: valid.trackedFingerprint,
                    untrackedFingerprint: valid.untrackedFingerprint,
                    ignoredRelevantFingerprint: valid.ignoredRelevantFingerprint
                )
            )
        )
        // The head commit must be exactly 40 lowercase hex bytes, or absent.
        #expect(
            !AgentTaskMetadataStore.validCodeState(
                AgentTaskCodeStateIdentity(
                    headCommit: String(repeating: "b", count: 41),
                    trackedFingerprint: valid.trackedFingerprint,
                    untrackedFingerprint: valid.untrackedFingerprint,
                    ignoredRelevantFingerprint: valid.ignoredRelevantFingerprint
                )
            )
        )
        #expect(
            AgentTaskCodeStateIdentity(
                headCommit: nil,
                trackedFingerprint: valid.trackedFingerprint,
                untrackedFingerprint: valid.untrackedFingerprint,
                ignoredRelevantFingerprint: valid.ignoredRelevantFingerprint
            )
                .headCommit == nil
        )
        #expect(
            AgentTaskMetadataStore.validCodeState(
                AgentTaskCodeStateIdentity(
                    headCommit: nil,
                    trackedFingerprint: valid.trackedFingerprint,
                    untrackedFingerprint: valid.untrackedFingerprint,
                    ignoredRelevantFingerprint: valid.ignoredRelevantFingerprint
                )
            )
        )

        // Environment identities: bounded components, lowercase config
        // fingerprint, current scheme only.
        let validEnvironment = environment
        #expect(AgentTaskMetadataStore.validEnvironment(validEnvironment))
        #expect(
            !AgentTaskMetadataStore.validEnvironment(
                AgentTaskEnvironmentIdentity(
                    scheme: 99,
                    osBuild: validEnvironment.osBuild,
                    toolchain: validEnvironment.toolchain,
                    configurationFingerprint: validEnvironment
                        .configurationFingerprint
                )
            )
        )
        #expect(
            !AgentTaskMetadataStore.validEnvironment(
                AgentTaskEnvironmentIdentity(
                    osBuild: String(repeating: "x", count: 65),
                    toolchain: nil,
                    configurationFingerprint: nil
                )
            )
        )
        #expect(
            !AgentTaskMetadataStore.validEnvironment(
                AgentTaskEnvironmentIdentity(
                    osBuild: nil,
                    toolchain: nil,
                    configurationFingerprint: hex("d").uppercased()
                )
            )
        )
    }

    @Test("relaunch preserves the complete durable ADE relationship")
    func relaunchPreservesCompleteDurableRelationship() async throws {
        let fixture = try ADEPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let stateA = codeState("a")
        let env = environment
        let descriptorD1 = AgentDescriptor(
            agentType: .claudeCode,
            launchExecutable: "claude"
        )

        // Task A: a verified, accepted success. Task B: an unverified
        // paused attempt. Both carry the task-level durable relationship.
        let writer = AgentTaskRegistry(persistence: store)
        writer.registerProject(identity)
        #expect(await writer.flushPersistence() == .saved)

        func launchTask(
            routeSeed: Int,
            pid: Int32,
            reference: String
        ) throws -> UUID {
            let route = AgentTaskRoute(
                paneID: uuid(routeSeed),
                tabID: uuid(routeSeed + 100),
                terminalID: uuid(routeSeed + 100)
            )
            let context = AgentTaskBridgeContext(
                project: identity,
                route: route,
                origin: .pineLaunched,
                observedAt: Date()
            )
            guard case .reserved(let reservation) = writer.preparePineLaunch(
                descriptor: descriptorD1,
                context: context,
                title: "E1 task \(routeSeed)",
                objective: nil,
                boundary: AgentTaskLaunchBoundary(
                    generationFloor: 0,
                    capturedAt: .distantPast
                )
            ) else {
                throw CocoaError(.coderInvalidValue)
            }
            #expect(writer.bindEnvironment(env, to: reservation.taskID))
            #expect(
                writer.recordFeedback(
                    reference,
                    codeState: stateA,
                    for: reservation.taskID
                )
            )
            #expect(writer.armLaunch(reservation))
            let session = ADESessionFixture.make(
                pid: pid,
                generation: 1,
                observedAt: Date()
            )
            writer.bridge(
                session,
                replacing: nil,
                context: context,
                reservation: reservation
            )
            session.applyLiveness(.terminated)
            writer.refresh(sessions: [session])
            return reservation.taskID
        }

        let settledTaskID = try launchTask(
            routeSeed: 151,
            pid: 1_510_001,
            reference: "e1-feedback-a"
        )
        // The required evidence at state A settles the attempt to success.
        let runA = try #require(
            writer.task(for: settledTaskID)?.runs.last
        )
        let endedAtA = try #require(runA.endedAt)
        for (offset, kind, result, sequence) in [
            (0, AgentTaskEvidenceKind.agentReportedCompletion,
             AgentTaskEvidenceResult.reported, 1),
            (1, AgentTaskEvidenceKind.independentCheck,
             AgentTaskEvidenceResult.succeeded, 2),
            (2, AgentTaskEvidenceKind.reviewerOutcome,
             AgentTaskEvidenceResult.succeeded, 3),
        ] {
            #expect(
                writer.recordEvidence(fact(
                    kind,
                    runID: runA.id,
                    generation: 1,
                    result: result,
                    at: endedAtA.addingTimeInterval(TimeInterval(offset)),
                    codeState: stateA,
                    environment: env,
                    sequence: UInt64(sequence)
                ), taskID: settledTaskID) == .accepted
            )
        }
        #expect(writer.task(for: settledTaskID)?.runs.last?.outcome == .success)
        #expect(
            writer.recordUserAcceptance(
                taskID: settledTaskID,
                codeState: stateA,
                environment: env
            )
        )

        #expect(await writer.flushPersistence() == .saved)
        let resumableTaskID = try launchTask(
            routeSeed: 152,
            pid: 1_520_001,
            reference: "e1-feedback-b"
        )
        #expect(writer.task(for: resumableTaskID)?.runs.last?.outcome == .unverified)
        #expect(await writer.flushPersistence() == .saved)

        // A relaunch is a fresh registry over the same durable store.
        let reloaded = AgentTaskRegistry(persistence: store)
        reloaded.registerProject(identity)
        #expect(await reloaded.flushPersistence() == .saved)
        let taskA = try #require(reloaded.task(for: settledTaskID))
        // The complete durable relationship survives the relaunch:
        #expect(taskA.runs.last?.outcome == .success)
        #expect(taskA.verificationState == .stale)
        #expect(taskA.acceptanceState == .notAccepted)
        #expect(taskA.reviewedSnapshot != nil)
        #expect(taskA.acceptedSnapshot != nil)
        #expect(taskA.executionState == .unknown)
        #expect(taskA.environment == env)
        #expect(taskA.feedback.map(\.reference) == ["e1-feedback-a"])
        #expect(
            reloaded.rememberedAgentDescriptor(for: identity) == descriptorD1
        )

        // Continue without rebuilding context. Task A is terminal
        // (.completed); the current lifecycle rules resume paused tasks, so
        // the continuation is demonstrated on task B through the production
        // resume path: a new run on the SAME durable task.
        #expect(!reloaded.canResumeTask(settledTaskID))
        #expect(reloaded.canResumeTask(resumableTaskID))
        let routeB = AgentTaskRoute(
            paneID: uuid(152),
            tabID: uuid(152 + 100),
            terminalID: uuid(152 + 100)
        )
        let resumeContext = AgentTaskBridgeContext(
            project: identity,
            route: routeB,
            origin: .pineLaunched,
            observedAt: Date()
        )
        guard case .reserved(let resume) = reloaded.prepareResume(
            taskID: resumableTaskID,
            context: resumeContext,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 0,
                capturedAt: .distantPast
            )
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        #expect(reloaded.armLaunch(resume))
        let followUp = ADESessionFixture.make(
            pid: 1_520_002,
            generation: 2,
            observedAt: Date()
        )
        reloaded.bridge(
            followUp,
            replacing: nil,
            context: resumeContext,
            reservation: resume
        )
        let continued = try #require(reloaded.task(for: resumableTaskID))
        #expect(continued.runs.count == 2)
        #expect(continued.runs.last?.liveness == .live)
        #expect(continued.runs.first?.outcome == .unverified)
        #expect(continued.lifecycle == .active)
        // The context was not rebuilt: the task-level relationship is
        // intact on the continued task.
        #expect(continued.environment == env)
        #expect(continued.feedback.map(\.reference) == ["e1-feedback-b"])
        #expect(continued.descriptor == descriptorD1)
        #expect(
            reloaded.rememberedAgentDescriptor(for: identity) == descriptorD1
        )
        #expect(await reloaded.flushPersistence() == .saved)
    }
}

// MARK: - Session fixture

@MainActor
enum ADESessionFixture {
    static func make(
        pid: Int32,
        generation: UInt64,
        start: String = "Mon Aug 3 10:00:00 2026",
        observedAt: Date? = nil
    ) -> AgentSession {
        let session = AgentSession(
            agentType: .claudeCode,
            state: .idle,
            lifecycleAccuracy: .processTerminationOnly,
            startedAt: observedAt ?? Date(timeIntervalSince1970: TimeInterval(generation)),
            lastObservedAt: observedAt
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: pid,
            processGeneration: generation,
            startIdentifier: start,
            observedStartedAt: observedAt ?? Date(timeIntervalSince1970: 0),
            startIsAuthoritative: true
        ))
        return session
    }
}

// MARK: - Registry test helper

@MainActor
private extension AgentTaskRegistry {
    func registerProjectAndFlush(
        _ identity: AgentTaskProjectIdentity
    ) async -> AgentTaskPersistenceFlushResult {
        registerProject(identity)
        return await flushPersistence()
    }
}

// MARK: - Persistence fixture

private final class ADEPersistenceFixture {
    let root: URL
    let project: URL
    let storage: URL

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PineADE-\(UUID().uuidString)")
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

// MARK: - Armed fault

nonisolated private final class ArmedSettlementFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    nonisolated func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    nonisolated func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
    }

    nonisolated func throwWhileArmed(
        store: PersistenceStoreKind,
        phase: PersistenceWritePhase
    ) throws {
        lock.lock()
        let shouldFire = armed
        lock.unlock()
        guard shouldFire,
              store == .agentTask,
              phase == .beforeSync else {
            return
        }
        throw PersistenceFailureKind.noSpace
    }
}
