//
//  AgentTaskVerificationContractTests.swift
//  PineTests
//
//  ADE verification orchestration contract (issue #1724): deterministic
//  integration scenarios over the durable task model and the registry's
//  persistence seams. Provider capabilities run as fake ports on the
//  coordinator's seam types; the real #1753/#1754/#1755 adapters plug into
//  the same ports, so these scenarios hold when the seams are wired.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("ADE verification orchestration contract", .serialized)
struct AgentTaskVerificationContractTests {
    // MARK: - Fixtures

    private func hex(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    private func codeState(_ tag: Character) -> AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "a", count: 40),
            trackedFingerprint: hex(tag),
            untrackedFingerprint: hex(tag),
            ignoredRelevantFingerprint: hex(tag)
        )
    }

    private var environment: AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(
            osBuild: "26B131",
            toolchain: "Xcode 26.2",
            configurationFingerprint: hex("e")
        )
    }

    private func snapshot(
        _ state: AgentTaskCodeStateIdentity
    ) -> AgentVerificationIdentitySnapshot {
        AgentVerificationIdentitySnapshot(code: state, environment: environment)
    }

    private func criteriaDigest(
        _ criteria: String = "Candidate meets the issue acceptance"
    ) -> String {
        AgentHistoryContentHash.sha256Hex(Data(criteria.utf8))
    }

    private func authorSession(_ seed: Int) -> AgentVendorSessionIdentity {
        AgentVendorSessionIdentity(
            provider: "claude", opaqueIdentifier: "author-\(seed)"
        )
    }

    private var reviewerSession: AgentVendorSessionIdentity {
        AgentVendorSessionIdentity(provider: "claude", opaqueIdentifier: "reviewer")
    }

    private func checkObservation(
        _ state: AgentTaskCodeStateIdentity,
        requiredStatus: AgentTaskCheckObservation.Status,
        pre: AgentTaskCodeStateIdentity? = nil,
        post: AgentTaskCodeStateIdentity? = nil,
        observedEnvironment: AgentTaskEnvironmentIdentity? = nil,
        taskID: UUID = UUID(),
        runID: UUID = UUID(),
        passID: UUID = UUID()
    ) -> AgentTaskCheckObservation {
        AgentTaskCheckObservation(
            taskID: taskID,
            runID: runID,
            passID: passID,
            executionID: UUID(),
            planFingerprint: hex("f"),
            processGeneration: 1,
            journalCompleted: true,
            results: [
                .init(operationID: UUID(), fingerprint: hex("1"), required: true, status: requiredStatus),
                .init(operationID: UUID(), fingerprint: hex("2"), required: false, status: .succeeded)
            ],
            preCodeState: pre ?? state,
            postCodeState: post ?? state,
            environment: observedEnvironment ?? environment
        )
    }

    @MainActor
    private static func installCheckJournal(
        _ observation: AgentTaskCheckObservation,
        request: AgentTaskVerificationCheckRequest,
        registry: AgentTaskRegistry
    ) {
        guard observation.hasCompleteRequiredJudgment,
              observation.taskID == request.taskID, observation.runID == request.runID,
              observation.passID == request.passID,
              observation.processGeneration == request.processGeneration,
              var task = registry.task(for: request.taskID),
              let run = task.runs.first(where: { $0.id == request.runID }) else { return }
        let grantID = UUID()
        let operations = observation.results.compactMap { result -> AgentTaskCheckExecution.Operation? in
            guard let status = AgentTaskCheckExecution.Status(rawValue: result.status.rawValue) else { return nil }
            return AgentTaskCheckExecution.Operation(
                id: result.operationID, commandFingerprint: result.fingerprint, required: result.required,
                startedAt: run.startedAt, finishedAt: run.startedAt,
                status: status, exitCode: status == .succeeded ? 0 : 1, identitiesMatched: true
            )
        }
        guard operations.count == observation.results.count else { return }
        task.checkGrant = AgentTaskCheckGrant(
            scheme: AgentTaskCheckGrant.currentScheme, id: grantID, taskID: task.id,
            planFingerprint: observation.planFingerprint, environment: request.expected.environment,
            approvedAt: run.startedAt, revokedAt: nil
        )
        task.checkExecution = AgentTaskCheckExecution(
            id: observation.executionID, runID: request.runID,
            processGeneration: request.processGeneration, passID: request.passID,
            attempt: request.attempt, grantID: grantID, planFingerprint: observation.planFingerprint,
            requiredCommands: Set(observation.results.filter(\.required).map(\.fingerprint)),
            code: request.expected.code, environment: request.expected.environment,
            operations: operations, completed: true
        )
        registry.setTasksForTesting(registry.tasks.map { $0.id == task.id ? task : $0 })
    }

    private var otherEnvironment: AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(
            osBuild: "26B131",
            toolchain: "Xcode 26.2",
            configurationFingerprint: hex("f")
        )
    }

    private func reviewObservation(
        _ outcome: AgentTaskReviewObservation.Outcome,
        _ state: AgentTaskCodeStateIdentity,
        pre: AgentTaskCodeStateIdentity? = nil,
        post: AgentTaskCodeStateIdentity? = nil,
        observedEnvironment: AgentTaskEnvironmentIdentity? = nil,
        taskID: UUID = UUID(),
        runID: UUID = UUID(),
        passID: UUID = UUID(),
        reviewerSession: AgentVendorSessionIdentity? = nil,
        criteriaDigest: String? = nil
    ) -> AgentTaskReviewObservation {
        AgentTaskReviewObservation(
            taskID: taskID,
            runID: runID,
            passID: passID,
            reviewerSession: reviewerSession ?? self.reviewerSession,
            criteriaDigest: criteriaDigest ?? self.criteriaDigest(),
            outcome: outcome,
            preCodeState: pre ?? state,
            postCodeState: post ?? state,
            environment: observedEnvironment ?? environment
        )
    }

    /// One settled, terminated run with a completion claim bound to `state`,
    /// bridged into a real registry the way the detector delivers it.
    private func settledClaimedTask(
        in registry: AgentTaskRegistry,
        fixture: CoordinatorFixture,
        state: AgentTaskCodeStateIdentity,
        seed: Int
    ) throws -> AgentTask {
        let now = Date()
        let terminalID = UUID()
        let route = AgentTaskRoute(paneID: UUID(), tabID: terminalID, terminalID: terminalID)
        let context = AgentTaskBridgeContext(
            project: fixture.project,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: now
        )
        let session = AgentSession(
            agentType: .claudeCode,
            state: .done,
            startedAt: now.addingTimeInterval(-300)
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: Int32(5_000 + seed),
            processGeneration: UInt64(seed),
            startIdentifier: "ade-contract-\(seed)",
            observedStartedAt: now.addingTimeInterval(-300),
            startIsAuthoritative: true
        ))
        registry.bridge(session, replacing: nil, context: context)
        session.applyLiveness(.terminated)
        registry.refresh(sessions: [session])
        var task = try #require(registry.historicalTask(forSessionID: session.id))
        let run = try #require(task.runs.last)
        #expect(AgentTaskLifecycleReducer.isSettled(run))
        let claim = AgentTaskEvidenceFact(
            kind: .agentReportedCompletion,
            runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified,
            result: .reported,
            observedAt: now.addingTimeInterval(1),
            codeState: state,
            environment: environment
        )
        #expect(registry.recordEvidence(claim, taskID: task.id) == .accepted)
        task = try #require(registry.task(for: task.id))
        #expect(task.runs.last?.outcome == .unverified)
        let runIndex = try #require(task.runs.indices.last)
        task.runs[runIndex].vendorIdentity = authorSession(seed)
        registry.setTasksForTesting(registry.tasks.map {
            $0.id == task.id ? task : $0
        })
        return task
    }

    // MARK: - Scenario: checks pass + review pass -> Ready publishable

    @Test("checks pass and review pass publish Ready")
    func checksPassAndReviewPassPublishesReady() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 1
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let check = checkObservation(state, requiredStatus: .succeeded)
        let probe = PortProbe(
            check: check,
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let coordinator = probe.coordinator(registry)

        let result = await coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .ready)
        #expect(result.readiness.isReady)
        #expect(result.readiness.gaps.isEmpty)

        let settled = try #require(registry.task(for: task.id))
        #expect(settled.runs.last?.outcome == .success)
        #expect(settled.verificationState == .verified)
        for kind in AgentTaskLifecycleReducer.requiredEvidenceForSuccess {
            let fact = try #require(settled.evidence.first { $0.kind == kind })
            #expect(fact.codeState == state)
            #expect(fact.environment == environment)
            #expect(fact.preOperationCodeState == state)
            #expect(fact.postOperationCodeState == state)
        }
        #expect(settled.evidence.first { $0.kind == .independentCheck }?.checkExecutionID == check.executionID)
        let reviewFact = try #require(settled.evidence.first {
            $0.kind == .reviewerOutcome
        })
        #expect(reviewFact.reviewerSession == reviewerSession)
        #expect(reviewFact.criteriaDigest == criteriaDigest())
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
    }

    // MARK: - Scenario: checks stale after edit -> refused, names repeat work

    @Test("checks stale after edit refuse Ready and re-verification re-grant-gates")
    func staleChecksAfterEditAreRefusedAndReverified() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let stateA = codeState("a")
        let stateB = codeState("b")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: stateA, seed: 2
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(stateA, requiredStatus: .succeeded),
            review: reviewObservation(.passed, stateA)
        )
        probe.anchor = snapshot(stateA)
        let coordinator = probe.coordinator(registry)
        #expect((await coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )).status == .ready)

        // A relevant edit: the recorded evidence no longer matches.
        let gaps = registry.invalidateEvidence(
            taskID: task.id, codeState: stateB, environment: environment
        )
        #expect(gaps.contains(.staleEvidence(.independentCheck)))
        #expect(gaps.contains(.staleEvidence(.reviewerOutcome)))
        let refused = registry.readiness(
            for: task.id, codeState: stateB, environment: environment
        )
        #expect(!refused.isReady)
        #expect(refused.gaps.contains(.staleEvidence(.independentCheck)))
        #expect(refused.gaps.contains(.staleEvidence(.reviewerOutcome)))

        // Re-verification revalidates the grant immediately before execution.
        let grantCallsBefore = probe.grantCalls
        probe.anchor = snapshot(stateB)
        probe.checkObservation = checkObservation(stateB, requiredStatus: .succeeded)
        probe.reviewObservation = reviewObservation(.passed, stateB)
        let result = await coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .ready)
        #expect(probe.grantCalls > grantCallsBefore)

        let reverified = try #require(registry.task(for: task.id))
        #expect(reverified.evidence.contains {
            $0.kind == .independentCheck && $0.codeState == stateB
                && $0.result == .succeeded
        })
        #expect(reverified.evidence.contains {
            $0.kind == .reviewerOutcome && $0.codeState == stateB
                && $0.result == .succeeded
        })
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
    }

    // MARK: - Scenario: review unresolved -> Needs decision, no Ready

    @Test("unresolved review escalates to Needs decision without Ready")
    func unresolvedReviewEscalatesWithoutReady() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 3
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.requestedChanges, state)
        )
        probe.anchor = snapshot(state)
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .needsDecision)
        #expect(result.reason == .reviewRequestedChanges)
        #expect(result.requiredAction == .resolveReviewFindings)
        #expect(!result.readiness.isReady)
        #expect(result.readiness.gaps.contains(.failedAttempt))

        let settled = try #require(registry.task(for: task.id))
        #expect(settled.runs.last?.outcome == .failure)
        // The failed pass still recorded a reviewerOutcome fact, so the
        // pass-death clear must leave the non-promotable `.stale` state
        // (a bare `.none` would expose the legacy promotion path).
        #expect(settled.verificationState == .stale)
        #expect(settled.evidence.contains {
            $0.kind == .reviewerOutcome && $0.result == .requestedChanges
        })
    }

    // MARK: - Scenario: cancelled run -> no Ready, no review

    @Test("a cancelled required check records no judgment and starts no review")
    func cancelledCheckProducesNoReadyAndNoReview() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 4
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .cancelled),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .cancelled)
        #expect(!result.readiness.isReady)
        #expect(probe.reviewCalls == 0)

        let settled = try #require(registry.task(for: task.id))
        #expect(!settled.evidence.contains {
            $0.kind == .independentCheck || $0.kind == .reviewerOutcome
        })
        #expect(settled.runs.last?.outcome == .unverified)
        #expect(settled.verificationState != .pending)
    }

    // MARK: - Scenario: missing grant -> explicit action, no execution

    @Test("a missing current grant offers the explicit grant action without executing")
    func missingGrantOffersExplicitActionWithoutExecution() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 5
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        probe.grantIsCurrent = false
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .notReady)
        #expect(result.reason == .checkGrantNotCurrent)
        #expect(result.requiredAction == .approveCheckGrant)
        #expect(!result.readiness.isReady)
        #expect(probe.checkCalls == 0)
        #expect(probe.reviewCalls == 0)

        let settled = try #require(registry.task(for: task.id))
        #expect(!settled.evidence.contains {
            $0.kind == .independentCheck || $0.kind == .reviewerOutcome
        })
        #expect(settled.verificationState != .pending)
    }

    // MARK: - Scenario: crash between check and review evidence -> fail closed

    @Test("a crash between check evidence and review evidence fails closed")
    func crashBetweenCheckAndReviewEvidenceFailsClosed() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let fault = ArmedWriteFault()
        let registry = AgentTaskRegistry(
            persistence: fixture.store(injector: fault.injector)
        )
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 6
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        probe.onReview = { fault.arm() }
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .notReady)
        #expect(result.reason == .persistenceUnavailable)
        #expect(!result.readiness.isReady)
        #expect(!registry.readiness(
            for: task.id, codeState: state, environment: environment
        ).isReady)

        // Relaunch: the process died before the review evidence was durable.
        let revived = AgentTaskRegistry(persistence: fixture.store())
        revived.registerProject(fixture.project)
        #expect(await revived.flushPersistence() == .saved)
        let revivedTask = try #require(revived.task(for: task.id))
        #expect(revivedTask.evidence.contains {
            $0.kind == .independentCheck && $0.result == .succeeded
                && $0.codeState == state
        })
        #expect(!revivedTask.evidence.contains { $0.kind == .reviewerOutcome })
        #expect(revivedTask.runs.last?.outcome == .unverified)
        let readiness = revived.readiness(
            for: task.id, codeState: state, environment: environment
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.unverifiedOutcome))
        #expect(readiness.gaps.contains(.missingEvidence(.reviewerOutcome)))
    }

    // MARK: - Scenario: restore and reads never execute verification

    @Test("restoring the app and reading readiness never execute checks or review")
    func restoreAndReadsNeverExecuteVerification() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 7
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        #expect((await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )).status == .ready)
        let probesAfterPass = probe.totalCalls
        let grantsAfterPass = probe.grantCalls
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        // A fresh process restores from the same storage and reads readiness.
        // Relaunch is a fail-closed boundary (#1722): the restored task's
        // verification is normalized to .stale, so the durable evidence alone
        // cannot publish Ready without an explicit re-verification pass.
        let revived = AgentTaskRegistry(persistence: fixture.store())
        revived.registerProject(fixture.project)
        #expect(await revived.flushPersistence() == .saved)
        let revivedReadiness = revived.readiness(
            for: task.id, codeState: state, environment: environment
        )
        #expect(!revivedReadiness.isReady)
        #expect(revivedReadiness.gaps.contains(.verificationNotCurrent))

        // Opening/restoring/reading executed nothing: no port was touched.
        #expect(probe.totalCalls == probesAfterPass)
        #expect(probe.grantCalls == grantsAfterPass)
    }

    // MARK: - Scenario: reviewer-caused mutation is not an independent pass

    @Test("a review that observed a moving candidate is not an independent pass")
    func reviewOverAMovedCandidateRecordsNoJudgment() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let stateA = codeState("a")
        let stateB = codeState("b")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: stateA, seed: 8
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(stateA, requiredStatus: .succeeded),
            review: reviewObservation(.passed, stateA, post: stateB)
        )
        probe.anchor = snapshot(stateA)
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .notReady)
        #expect(result.reason == .identityNotCurrent)
        #expect(result.requiredAction == nil)
        #expect(!result.readiness.isReady)

        let settled = try #require(registry.task(for: task.id))
        #expect(!settled.evidence.contains { $0.kind == .reviewerOutcome })
        #expect(settled.runs.last?.outcome == .unverified)
        #expect(settled.verificationState != .pending)
    }

    // MARK: - Scenario: infrastructure retries are bounded and re-grant-gated

    @Test("a transient check failure retries once, revalidated under the grant")
    func transientCheckFailureRetriesOnce() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 9
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        probe.checkFailsBelowAttempt = 1
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .ready)
        #expect(probe.checkCalls == 2)
        #expect(probe.grantCalls == 3)
        #expect(probe.reviewCalls == 1)
    }

    @Test("repeatedly unobservable checks escalate after the retry bound")
    func unobservableChecksEscalateAfterBound() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 10
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .timedOut),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .needsDecision)
        #expect(result.reason == .checksNotObserved)
        #expect(result.requiredAction == .rerunRequiredChecks)
        #expect(!result.readiness.isReady)
        #expect(probe.checkCalls == 2)
        #expect(probe.reviewCalls == 0)

        let settled = try #require(registry.task(for: task.id))
        #expect(!settled.evidence.contains { $0.kind == .independentCheck })
        #expect(settled.verificationState != .pending)
    }

    // MARK: - Pass fencing, atomic publication, and acceptance

    @Test("an older pass cannot publish after a newer pass terminates")
    func olderPassCannotPublishAfterNewerPassTerminates() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 19
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)

        let olderProbe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        olderProbe.anchor = snapshot(state)
        let gate = SuspensionGate()
        olderProbe.suspensionPoint = .initialProbe
        olderProbe.suspensionGate = gate
        let olderCoordinator = olderProbe.coordinator(registry)
        let olderPass = Task { @MainActor in
            await olderCoordinator.runVerificationPass(
                taskID: task.id, criteria: "Candidate meets the issue acceptance",
                registry: registry
            )
        }
        await gate.waitUntilEntered()

        let newerProbe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        newerProbe.anchor = snapshot(state)
        newerProbe.grantIsCurrent = false
        let newerResult = await newerProbe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(newerResult.status == .notReady)
        #expect(newerResult.reason == .checkGrantNotCurrent)
        #expect(registry.task(for: task.id)?.verificationState != .pending)

        gate.release()
        let olderResult = await olderPass.value
        #expect(olderResult.status == .cancelled)
        #expect(!olderResult.readiness.isReady)
        let terminal = try #require(registry.task(for: task.id))
        #expect(terminal.verificationState != .pending)
        #expect(terminal.verificationState != .verified)
        #expect(terminal.runs.last?.outcome == .unverified)
        #expect(!terminal.evidence.contains {
            $0.kind == .independentCheck || $0.kind == .reviewerOutcome
        })
    }

    @Test(
        "an interrupted pass cannot mutate or publish a replacement",
        arguments: PassInterruptionPoint.allCases, PassInterruption.allCases
    )
    func interruptedPassFailsClosedWithoutTouchingReplacement(
        point: PassInterruptionPoint, interruption: PassInterruption
    ) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let fault = ArmedWriteFault()
        let persistence = GatedAgentTaskPersistence(
            base: fixture.store(injector: fault.injector)
        )
        let registry = AgentTaskRegistry(persistence: persistence)
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 20
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        let replacement = try replacementTask(from: task)
        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let gate = SuspensionGate()
        if let saveNumber = point.flushSaveNumber {
            persistence.suspendOnSave(saveNumber, gate: gate)
        } else {
            probe.suspensionPoint = point
            probe.suspensionGate = gate
        }
        let coordinator = probe.coordinator(registry)
        let running = Task { @MainActor in
            await coordinator.runVerificationPass(
                taskID: task.id, criteria: "Candidate meets the issue acceptance",
                registry: registry
            )
        }
        await gate.waitUntilEntered()
        let callsAtSuspension = probe.totalCalls

        switch interruption {
        case .dismissal:
            #expect(registry.dismissTask(task.id))
        case .registryCancellation:
            try recordCancellation(in: registry, taskID: task.id)
        case .taskCancellation:
            running.cancel()
        case .replacement:
            registry.setTasksForTesting([replacement])
        }
        if point.flushSaveNumber != nil { fault.arm() }
        gate.release()
        let result = await running.value

        #expect(result.status == .cancelled)
        #expect(!result.readiness.isReady)
        #expect(probe.totalCalls == callsAtSuspension)
        #expect(registry.task(for: task.id)?.verificationState != .pending)
        if interruption == .replacement {
            #expect(result.readiness.gaps == [.supersededAttempt])
            #expect(registry.task(for: task.id) == replacement)
        }
    }

    @Test("a process-generation replacement fences an otherwise identical run")
    func processGenerationReplacementFencesPass() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 21
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        let replacement = try replacementTask(from: task, sameRunID: true)
        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let gate = SuspensionGate()
        probe.suspensionPoint = .initialProbe
        probe.suspensionGate = gate
        let coordinator = probe.coordinator(registry)
        let running = Task { @MainActor in
            await coordinator.runVerificationPass(
                taskID: task.id, criteria: "Candidate meets the issue acceptance",
                registry: registry
            )
        }
        await gate.waitUntilEntered()
        registry.setTasksForTesting([replacement])
        gate.release()
        let result = await running.value
        #expect(result.status == .cancelled)
        #expect(result.readiness.gaps == [.supersededAttempt])
        #expect(registry.task(for: task.id) == replacement)
    }

    @Test("run-scoped registry backstops leave a replacement unchanged")
    func runScopedRegistryBackstopsRejectAnOldRun() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 22
        )
        let replacement = try replacementTask(from: task)
        registry.setTasksForTesting([replacement])
        let oldRunID = try #require(task.runs.last?.id)
        #expect(registry.invalidateEvidence(
            taskID: task.id, codeState: state, environment: environment, runID: oldRunID
        ).isEmpty)
        #expect(!registry.markVerificationPending(
            taskID: task.id, expectedRunID: oldRunID
        ))
        #expect(registry.settleVerificationPass(
            taskID: task.id, runID: oldRunID,
            codeState: state, environment: environment, makeCurrent: true
        ) == nil)
        #expect(!registry.failVerificationPass(
            taskID: task.id, runID: oldRunID,
            codeState: state, environment: environment
        ))
        #expect(registry.task(for: task.id) == replacement)
    }

    @Test(
        "an observer replacement is not mutated through a captured index",
        arguments: ReentrantRegistryOperation.allCases
    )
    func observerReplacementIsNotMutatedThroughCapturedIndex(
        operation: ReentrantRegistryOperation
    ) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 30
        )
        let other = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 31
        )
        let run = try #require(task.runs.last)
        let fact = AgentTaskEvidenceFact(
            kind: .independentCheck,
            runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified,
            result: .succeeded,
            observedAt: Date().addingTimeInterval(60),
            codeState: state,
            environment: environment,
            preOperationCodeState: state,
            postOperationCodeState: state
        )
        var replaced = false
        let token = registry.addTaskChangeObserver { _, _ in
            guard !replaced else { return }
            replaced = true
            registry.setTasksForTesting([other])
        }
        defer { registry.removeTaskChangeObserver(token) }

        switch operation {
        case .recordEvidence:
            #expect(registry.recordEvidence(
                fact, taskID: task.id, deferSettlement: true
            ) != .accepted)
        case .markPending:
            #expect(!registry.markVerificationPending(
                taskID: task.id, expectedRunID: run.id
            ))
        }
        #expect(replaced)
        #expect(registry.task(for: task.id) == nil)
        #expect(registry.task(for: other.id) == other)
    }

    @Test(
        "passing evidence never publishes an intermediate Ready",
        arguments: ReadyObservationPoint.allCases
    )
    func passingEvidenceHasNoIntermediateReadyObserver(
        point: ReadyObservationPoint
    ) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let persistence = GatedAgentTaskPersistence(base: fixture.store())
        let registry = AgentTaskRegistry(persistence: persistence)
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 23
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let gate = SuspensionGate()
        switch point {
        case .reviewFlush:
            persistence.suspendOnSave(3, gate: gate)
        case .finalProbe:
            probe.suspensionPoint = .finalProbe
            probe.suspensionGate = gate
        }
        var observed: [AgentTask] = []
        let token = registry.addTaskChangeObserver { _, tasks in
            if let changed = tasks.first(where: { $0.id == task.id }) {
                observed.append(changed)
            }
        }
        defer { registry.removeTaskChangeObserver(token) }
        let coordinator = probe.coordinator(registry)
        let running = Task { @MainActor in
            await coordinator.runVerificationPass(
                taskID: task.id, criteria: "Candidate meets the issue acceptance",
                registry: registry
            )
        }
        await gate.waitUntilEntered()
        #expect(!registry.readiness(
            for: task.id, codeState: state, environment: environment
        ).isReady)
        #expect(registry.task(for: task.id)?.runs.last?.outcome == .unverified)
        #expect(observed.allSatisfy {
            $0.runs.last?.outcome != .success && $0.attention != .completed
        })
        gate.release()
        let result = await running.value
        #expect(result.status == .ready)
        #expect(observed.filter {
            $0.runs.last?.outcome == .success && $0.verificationState == .verified
        }.count == 1)
    }

    @Test(
        "CancellationError is terminal and never retried",
        arguments: CancellationPort.allCases
    )
    func cancellationErrorNeverRetries(port: CancellationPort) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 24
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        probe.checkCancellation = port == .checks
        probe.reviewCancellation = port == .review
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .cancelled)
        #expect(!result.readiness.isReady)
        #expect(probe.checkCalls == 1)
        #expect(probe.reviewCalls == (port == .review ? 1 : 0))
        #expect(registry.task(for: task.id)?.verificationState != .pending)
    }

    @Test("a review infrastructure error clears the pending marker")
    func reviewInfrastructureErrorClearsPending() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 32
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        let anchor = snapshot(state)
        let check = checkObservation(state, requiredStatus: .succeeded)
        let coordinator = AgentTaskVerificationCoordinator(
            probeIdentity: { _ in anchor },
            grantIsCurrent: { _ in true },
            runRequiredChecks: { request in
                let observation = AgentTaskCheckObservation(
                    taskID: request.taskID, runID: request.runID, passID: request.passID,
                    executionID: check.executionID, planFingerprint: check.planFingerprint,
                    processGeneration: request.processGeneration, journalCompleted: check.journalCompleted,
                    results: check.results,
                    preCodeState: check.preCodeState,
                    postCodeState: check.postCodeState,
                    environment: check.environment
                )
                await Self.installCheckJournal(observation, request: request, registry: registry)
                return observation
            },
            startReview: { _ in throw PortFailure() }
        )
        let result = await coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .notReady)
        #expect(result.reason == .reviewNotObserved)
        #expect(result.requiredAction == .rerunReview)
        #expect(registry.task(for: task.id)?.verificationState != .pending)
    }

    @Test(
        "an already-Ready result is revoked by every failed re-verification",
        arguments: ReadyRevocation.allCases
    )
    func alreadyReadyRevokedByFailedReverification(
        scenario: ReadyRevocation
    ) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let fault = ArmedWriteFault()
        let registry = AgentTaskRegistry(
            persistence: fixture.store(injector: fault.injector)
        )
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 25
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        #expect((await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )).status == .ready)
        switch scenario {
        case .missingGrant:
            probe.grantIsCurrent = false
        case .cancellation:
            probe.checkObservation = checkObservation(state, requiredStatus: .cancelled)
        case .exhaustion:
            probe.checkObservation = checkObservation(state, requiredStatus: .timedOut)
        case .persistence:
            fault.arm()
        }
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status != .ready)
        #expect(!result.readiness.isReady)
        #expect(!registry.readiness(
            for: task.id, codeState: state, environment: environment
        ).isReady)
        #expect(registry.task(for: task.id)?.verificationState != .verified)
        #expect(registry.task(for: task.id)?.verificationState != .pending)
    }

    @Test(
        "persistence failure preserves only same-identity acceptance",
        arguments: [false, true]
    )
    func persistenceFailureAcceptanceRelevance(changedIdentity: Bool) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let stateA = codeState("a")
        let stateB = codeState("b")
        let fault = ArmedWriteFault()
        let registry = AgentTaskRegistry(
            persistence: fixture.store(injector: fault.injector)
        )
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: stateA, seed: 26
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        let probe = PortProbe(
            check: checkObservation(stateA, requiredStatus: .succeeded),
            review: reviewObservation(.passed, stateA)
        )
        probe.anchor = snapshot(stateA)
        #expect((await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )).status == .ready)
        #expect(registry.recordUserAcceptance(
            taskID: task.id, codeState: stateA, environment: environment
        ))
        let accepted = try #require(registry.task(for: task.id))
        probe.anchor = snapshot(changedIdentity ? stateB : stateA)
        fault.arm()
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.reason == .persistenceUnavailable)
        #expect(!result.readiness.isReady)
        let failed = try #require(registry.task(for: task.id))
        #expect(failed.verificationState == .stale)
        #expect(failed.acceptanceState == (changedIdentity ? .notAccepted : .accepted))
        #expect(failed.acceptedSnapshot == accepted.acceptedSnapshot)
        #expect(failed.reviewedSnapshot == accepted.reviewedSnapshot)
        #expect(failed.evidence == accepted.evidence)
    }

    @Test(
        "check observations must match the exact anchor",
        arguments: ObservationMismatch.allCases
    )
    func checkIdentityMismatchRecordsNothing(
        mismatch: ObservationMismatch
    ) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 27
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        var observation = checkObservation(state, requiredStatus: .succeeded)
        switch mismatch {
        case .preCode:
            observation = checkObservation(
                state, requiredStatus: .succeeded, pre: codeState("b")
            )
        case .postCode:
            observation = checkObservation(
                state, requiredStatus: .succeeded, post: codeState("b")
            )
        case .environment:
            observation = checkObservation(
                state, requiredStatus: .succeeded, observedEnvironment: otherEnvironment
            )
        case .task:
            observation = checkObservation(
                state, requiredStatus: .succeeded, taskID: UUID()
            )
        case .run:
            observation = checkObservation(
                state, requiredStatus: .succeeded, runID: UUID()
            )
        case .pass:
            observation = checkObservation(
                state, requiredStatus: .succeeded, passID: UUID()
            )
        }
        let probe = PortProbe(
            check: observation, review: reviewObservation(.passed, state)
        )
        switch mismatch {
        case .task, .run, .pass: probe.echoCheckRequest = false
        default: break
        }
        probe.anchor = snapshot(state)
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.reason == .identityNotCurrent)
        #expect(!result.readiness.isReady)
        #expect(probe.reviewCalls == 0)
        #expect(registry.task(for: task.id)?.evidence.contains {
            $0.kind == .independentCheck
        } == false)
        #expect(registry.task(for: task.id)?.verificationState != .pending)
    }

    @Test(
        "review observations must match the exact anchor",
        arguments: ObservationMismatch.allCases
    )
    func reviewIdentityMismatchRecordsNothing(
        mismatch: ObservationMismatch
    ) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 28
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        var observation = reviewObservation(.passed, state)
        switch mismatch {
        case .preCode:
            observation = reviewObservation(.passed, state, pre: codeState("b"))
        case .postCode:
            observation = reviewObservation(.passed, state, post: codeState("b"))
        case .environment:
            observation = reviewObservation(
                .passed, state, observedEnvironment: otherEnvironment
            )
        case .task:
            observation = reviewObservation(.passed, state, taskID: UUID())
        case .run:
            observation = reviewObservation(.passed, state, runID: UUID())
        case .pass:
            observation = reviewObservation(.passed, state, passID: UUID())
        }
        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: observation
        )
        switch mismatch {
        case .task, .run, .pass: probe.echoReviewRequest = false
        default: break
        }
        probe.anchor = snapshot(state)
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.reason == .identityNotCurrent)
        #expect(!result.readiness.isReady)
        #expect(registry.task(for: task.id)?.evidence.contains {
            $0.kind == .reviewerOutcome
        } == false)
        #expect(registry.task(for: task.id)?.verificationState != .pending)
    }

    @Test(
        "reviewer session and criteria provenance are enforced",
        arguments: ReviewProvenanceMismatch.allCases
    )
    func reviewProvenanceMismatchRecordsNothing(
        mismatch: ReviewProvenanceMismatch
    ) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 33
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        var review = reviewObservation(.passed, state)
        var wrongCriteriaDigest: String?
        switch mismatch {
        case .sameSession:
            review = reviewObservation(
                .passed, state, reviewerSession: authorSession(33)
            )
        case .criteria:
            wrongCriteriaDigest = criteriaDigest("Different criteria")
        }
        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: review
        )
        probe.reviewCriteriaDigest = wrongCriteriaDigest
        probe.anchor = snapshot(state)
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance",
            registry: registry
        )
        #expect(result.status == .notReady)
        #expect(result.reason == .identityNotCurrent)
        #expect(!result.readiness.isReady)
        let terminal = try #require(registry.task(for: task.id))
        #expect(terminal.evidence.contains { $0.kind == .independentCheck })
        #expect(!terminal.evidence.contains { $0.kind == .reviewerOutcome })
        #expect(terminal.verificationState != .pending)
    }

    @Test("criteria reject blank input and preserve the original request")
    func criteriaValidationAndOriginalRequest() async throws {
        #expect(!AgentTaskVerificationCoordinator.validCriteria("   "))
        #expect(!AgentTaskVerificationCoordinator.validCriteria(" \n\t "))
        #expect(AgentTaskVerificationCoordinator.validCriteria(
            String(repeating: "a", count: 2_048)
        ))
        #expect(!AgentTaskVerificationCoordinator.validCriteria(
            String(repeating: "a", count: 2_049)
        ))
        #expect(!AgentTaskVerificationCoordinator.validCriteria("bad\u{1}"))
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let state = codeState("a")
        let registry = AgentTaskRegistry(persistence: fixture.store())
        registry.registerProject(fixture.project)
        #expect(await registry.flushPersistence() == .saved)
        let task = try settledClaimedTask(
            in: registry, fixture: fixture, state: state, seed: 29
        )
        #expect(await registry.flushPersistence(project: fixture.project) == .saved)
        let probe = PortProbe(
            check: checkObservation(state, requiredStatus: .succeeded),
            review: reviewObservation(.passed, state)
        )
        probe.anchor = snapshot(state)
        let criteria = "  Candidate meets the issue acceptance  "
        let result = await probe.coordinator(registry).runVerificationPass(
            taskID: task.id, criteria: criteria, registry: registry
        )
        #expect(result.status == .ready)
        #expect(probe.lastReviewCriteria == criteria)
    }

    private func replacementTask(
        from task: AgentTask, sameRunID: Bool = false
    ) throws -> AgentTask {
        let previous = try #require(task.runs.last)
        let state = codeState("b")
        let startedAt = previous.endedAt?.addingTimeInterval(1) ?? Date()
        let endedAt = startedAt.addingTimeInterval(1)
        let process = AgentProcessEvidence(
            processIdentifier: 9_999,
            processGeneration: previous.process.processGeneration + 100,
            startIdentifier: "replacement-\(UUID().uuidString)",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        )
        var run = AgentTaskRun(AgentTaskRunInput(
            id: sameRunID ? previous.id : UUID(),
            terminalID: previous.terminalID,
            process: process,
            status: AgentTaskRunStatus(
                state: .done, liveness: .terminated, observedAt: endedAt
            )
        ))
        run.outcome = .success
        let claim = AgentTaskEvidenceFact(
            kind: .agentReportedCompletion, runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified, result: .reported,
            observedAt: endedAt.addingTimeInterval(1),
            codeState: state, environment: environment, sourceSequence: 101
        )
        let check = AgentTaskEvidenceFact(
            kind: .independentCheck, runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified, result: .succeeded,
            observedAt: endedAt.addingTimeInterval(2),
            codeState: state, environment: environment, sourceSequence: 102,
            preOperationCodeState: state, postOperationCodeState: state
        )
        let review = AgentTaskEvidenceFact(
            kind: .reviewerOutcome, runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified, result: .succeeded,
            observedAt: endedAt.addingTimeInterval(3),
            codeState: state, environment: environment, sourceSequence: 103,
            preOperationCodeState: state, postOperationCodeState: state
        )
        let acceptance = AgentTaskEvidenceFact(
            kind: .userAcceptance, runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified, result: .accepted,
            observedAt: endedAt.addingTimeInterval(4),
            codeState: state, environment: environment, sourceSequence: 104
        )
        var replacement = task
        replacement.runs = [run]
        replacement.evidence = [claim, check, review, acceptance]
        replacement.lifecycle = .completed
        replacement.attention = .completed
        replacement.completedAt = endedAt
        replacement.verificationState = .verified
        replacement.acceptanceState = .accepted
        replacement.reviewedSnapshot = AgentTaskResultSnapshot(
            runID: run.id, outcome: .success, codeState: state,
            environment: environment, recordedAt: review.observedAt
        )
        replacement.acceptedSnapshot = AgentTaskResultSnapshot(
            runID: run.id, outcome: .success, codeState: state,
            environment: environment, recordedAt: acceptance.observedAt
        )
        replacement.updatedAt = acceptance.observedAt
        replacement.lastActivityAt = acceptance.observedAt
        return replacement
    }

    private func recordCancellation(
        in registry: AgentTaskRegistry, taskID: UUID
    ) throws {
        let run = try #require(registry.task(for: taskID)?.runs.last)
        let fact = AgentTaskEvidenceFact(
            kind: .userCancellation, runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified, result: .cancelled,
            observedAt: Date().addingTimeInterval(10)
        )
        #expect(registry.recordEvidence(fact, taskID: taskID) == .accepted)
    }

    // MARK: - Fakes

    nonisolated enum PassInterruptionPoint: CaseIterable, Sendable {
        case initialProbe
        case grant
        case checks
        case review
        case initialFlush
        case checkFlush
        case reviewFlush
        case finalProbe

        var flushSaveNumber: Int? {
            switch self {
            case .initialFlush: return 1
            case .checkFlush: return 2
            case .reviewFlush: return 3
            default: return nil
            }
        }
    }

    nonisolated enum PassInterruption: CaseIterable, Sendable {
        case dismissal
        case registryCancellation
        case taskCancellation
        case replacement
    }

    nonisolated enum ReadyObservationPoint: CaseIterable, Sendable {
        case reviewFlush
        case finalProbe
    }

    nonisolated enum ReentrantRegistryOperation: CaseIterable, Sendable {
        case recordEvidence
        case markPending
    }

    nonisolated enum CancellationPort: CaseIterable, Sendable {
        case checks
        case review
    }

    nonisolated enum ReadyRevocation: CaseIterable, Sendable {
        case missingGrant
        case cancellation
        case exhaustion
        case persistence
    }

    nonisolated enum ReviewProvenanceMismatch: CaseIterable, Sendable {
        case sameSession
        case criteria
    }

    nonisolated enum ObservationMismatch: CaseIterable, Sendable {
        case preCode
        case postCode
        case environment
        case task
        case run
        case pass
    }

    nonisolated private final class SuspensionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var released = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func suspend() async {
            let waiters = lock.withLock {
                entered = true
                let waiters = enteredWaiters
                enteredWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    releaseWaiter = continuation
                    lock.unlock()
                }
            }
        }

        func waitUntilEntered() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if entered {
                    lock.unlock()
                    continuation.resume()
                } else {
                    enteredWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func release() {
            let waiter = lock.withLock {
                released = true
                let waiter = releaseWaiter
                releaseWaiter = nil
                return waiter
            }
            waiter?.resume()
        }
    }

    nonisolated private final class GatedAgentTaskPersistence:
        AgentTaskPersisting, @unchecked Sendable {
        private let base: AgentTaskMetadataStore
        private let lock = NSLock()
        private var saveCount = 0
        private var targetSave: Int?
        private var gate: SuspensionGate?

        init(base: AgentTaskMetadataStore) {
            self.base = base
        }

        func suspendOnSave(_ number: Int, gate: SuspensionGate) {
            lock.withLock {
                saveCount = 0
                targetSave = number
                self.gate = gate
            }
        }

        private func suspendIfNeeded() async {
            let gate = lock.withLock { () -> SuspensionGate? in
                saveCount += 1
                return saveCount == targetSave ? self.gate : nil
            }
            await gate?.suspend()
        }

        func save(
            tasks: [AgentTask], project: AgentTaskProjectIdentity,
            authorization: AgentTaskPublicationAuthorization?
        ) async -> AgentTaskMetadataSaveResult {
            await suspendIfNeeded()
            return await base.save(
                tasks: tasks, project: project, authorization: authorization
            )
        }

        func save(
            tasks: [AgentTask], envelope: AgentTaskEnvelopeState,
            project: AgentTaskProjectIdentity,
            authorization: AgentTaskPublicationAuthorization?
        ) async -> AgentTaskMetadataSaveResult {
            await suspendIfNeeded()
            return await base.save(
                tasks: tasks, envelope: envelope, project: project,
                authorization: authorization
            )
        }

        func load(
            project: AgentTaskProjectIdentity
        ) async -> AgentTaskMetadataLoadResult {
            await base.load(project: project)
        }
    }

    private struct PortFailure: Error {}

    nonisolated private final class PortProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _anchor: AgentVerificationIdentitySnapshot?
        private var _grantIsCurrent = true
        private var _checkObservation: AgentTaskCheckObservation
        private var _reviewObservation: AgentTaskReviewObservation
        private var _checkFailsBelowAttempt = 0
        private var _onReview: (@Sendable () -> Void)?
        private var _suspensionPoint: PassInterruptionPoint?
        private var _suspensionGate: SuspensionGate?
        private var _checkCancellation = false
        private var _reviewCancellation = false
        private var _echoCheckRequest = true
        private var _echoReviewRequest = true
        private var _reviewCriteriaDigest: String?
        private var _lastReviewCriteria: String?
        private var _clock = Date()
        private var _probeCalls = 0
        private var _grantCalls = 0
        private var _checkCalls = 0
        private var _reviewCalls = 0

        init(
            check: AgentTaskCheckObservation,
            review: AgentTaskReviewObservation
        ) {
            _checkObservation = check
            _reviewObservation = review
        }

        var anchor: AgentVerificationIdentitySnapshot? {
            get { lock.withLock { _anchor } }
            set { lock.withLock { _anchor = newValue } }
        }
        var grantIsCurrent: Bool {
            get { lock.withLock { _grantIsCurrent } }
            set { lock.withLock { _grantIsCurrent = newValue } }
        }
        var checkObservation: AgentTaskCheckObservation {
            get { lock.withLock { _checkObservation } }
            set { lock.withLock { _checkObservation = newValue } }
        }
        var reviewObservation: AgentTaskReviewObservation {
            get { lock.withLock { _reviewObservation } }
            set { lock.withLock { _reviewObservation = newValue } }
        }
        var checkFailsBelowAttempt: Int {
            get { lock.withLock { _checkFailsBelowAttempt } }
            set { lock.withLock { _checkFailsBelowAttempt = newValue } }
        }
        var onReview: (@Sendable () -> Void)? {
            get { lock.withLock { _onReview } }
            set { lock.withLock { _onReview = newValue } }
        }
        var suspensionPoint: PassInterruptionPoint? {
            get { lock.withLock { _suspensionPoint } }
            set { lock.withLock { _suspensionPoint = newValue } }
        }
        var suspensionGate: SuspensionGate? {
            get { lock.withLock { _suspensionGate } }
            set { lock.withLock { _suspensionGate = newValue } }
        }
        var checkCancellation: Bool {
            get { lock.withLock { _checkCancellation } }
            set { lock.withLock { _checkCancellation = newValue } }
        }
        var reviewCancellation: Bool {
            get { lock.withLock { _reviewCancellation } }
            set { lock.withLock { _reviewCancellation = newValue } }
        }
        var echoCheckRequest: Bool {
            get { lock.withLock { _echoCheckRequest } }
            set { lock.withLock { _echoCheckRequest = newValue } }
        }
        var echoReviewRequest: Bool {
            get { lock.withLock { _echoReviewRequest } }
            set { lock.withLock { _echoReviewRequest = newValue } }
        }
        var reviewCriteriaDigest: String? {
            get { lock.withLock { _reviewCriteriaDigest } }
            set { lock.withLock { _reviewCriteriaDigest = newValue } }
        }
        var lastReviewCriteria: String? { lock.withLock { _lastReviewCriteria } }
        var probeCalls: Int { lock.withLock { _probeCalls } }
        var grantCalls: Int { lock.withLock { _grantCalls } }
        var checkCalls: Int { lock.withLock { _checkCalls } }
        var reviewCalls: Int { lock.withLock { _reviewCalls } }
        var totalCalls: Int {
            lock.withLock { _probeCalls + _grantCalls + _checkCalls + _reviewCalls }
        }

        func nextTimestamp() -> Date {
            lock.withLock {
                defer { _clock += 0.02 }
                return _clock
            }
        }

        private func suspendIfNeeded(_ point: PassInterruptionPoint) async {
            guard suspensionPoint == point else { return }
            await suspensionGate?.suspend()
        }

        private func checkResult(
            for request: AgentTaskVerificationCheckRequest
        ) -> AgentTaskCheckObservation {
            let observation = checkObservation
            guard echoCheckRequest else { return observation }
            return AgentTaskCheckObservation(
                taskID: request.taskID, runID: request.runID, passID: request.passID,
                executionID: observation.executionID, planFingerprint: observation.planFingerprint,
                processGeneration: request.processGeneration, journalCompleted: observation.journalCompleted,
                results: observation.results,
                preCodeState: observation.preCodeState,
                postCodeState: observation.postCodeState,
                environment: observation.environment
            )
        }

        private func reviewResult(
            for request: AgentTaskVerificationReviewRequest
        ) -> AgentTaskReviewObservation {
            let observation = reviewObservation
            guard echoReviewRequest else { return observation }
            return AgentTaskReviewObservation(
                taskID: request.taskID, runID: request.runID, passID: request.passID,
                reviewerSession: observation.reviewerSession,
                criteriaDigest: reviewCriteriaDigest ?? request.criteriaDigest,
                outcome: observation.outcome,
                preCodeState: observation.preCodeState,
                postCodeState: observation.postCodeState,
                environment: observation.environment
            )
        }

        func coordinator(_ registry: AgentTaskRegistry) -> AgentTaskVerificationCoordinator {
            AgentTaskVerificationCoordinator(
                probeIdentity: { [weak self] _ in
                    guard let self else { return nil }
                    let call = self.lock.withLock {
                        self._probeCalls += 1
                        return self._probeCalls
                    }
                    if call == 1 {
                        await self.suspendIfNeeded(.initialProbe)
                    } else if call >= 3 {
                        await self.suspendIfNeeded(.finalProbe)
                    }
                    return self.anchor
                },
                grantIsCurrent: { [weak self] _ in
                    guard let self else { return false }
                    self.lock.withLock { self._grantCalls += 1 }
                    await self.suspendIfNeeded(.grant)
                    return self.grantIsCurrent
                },
                runRequiredChecks: { [weak self] request in
                    guard let self else { throw PortFailure() }
                    self.lock.withLock { self._checkCalls += 1 }
                    await self.suspendIfNeeded(.checks)
                    if self.checkCancellation { throw CancellationError() }
                    if request.attempt <= self.checkFailsBelowAttempt {
                        throw PortFailure()
                    }
                    let observation = self.checkResult(for: request)
                    await AgentTaskVerificationContractTests.installCheckJournal(
                        observation, request: request, registry: registry
                    )
                    return observation
                },
                startReview: { [weak self] request in
                    guard let self else { throw PortFailure() }
                    self.lock.withLock {
                        self._reviewCalls += 1
                        self._lastReviewCriteria = request.criteria
                    }
                    await self.suspendIfNeeded(.review)
                    if self.reviewCancellation { throw CancellationError() }
                    self.onReview?()
                    return self.reviewResult(for: request)
                },
                now: { [weak self] in
                    self?.nextTimestamp() ?? Date()
                }
            )
        }
    }

    /// A write fault that fires on every agent-task atomic replace while
    /// armed: the deterministic stand-in for a process dying mid-write.
    nonisolated private final class ArmedWriteFault: @unchecked Sendable {
        private let lock = NSLock()
        private var _armed = false

        func arm() {
            lock.withLock { _armed = true }
        }

        var injector: PersistenceFaultInjector {
            PersistenceFaultInjector { [weak self] store, phase in
                guard let self else { return }
                if self.lock.withLock({ self._armed }),
                   store == .agentTask,
                   phase == .beforeAtomicReplace {
                    throw PersistenceFailureKind.interrupted
                }
            }
        }
    }

    /// The minimal real-storage fixture: a clean 0700 root with a user-owned
    /// project directory and the store-owned private storage directory.
    private final class CoordinatorFixture {
        let root: URL
        let project: AgentTaskProjectIdentity
        let storage: URL

        init() throws {
            let fileManager = FileManager.default
            root = fileManager.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent("PineVerificationContract-\(UUID().uuidString)")
            let projectURL = root.appendingPathComponent("project", isDirectory: true)
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
                    chmod, commandDescription: "chmod -N verification fixture root"
                )
                guard output.terminationStatus == 0 else {
                    try? fileManager.removeItem(at: root)
                    throw CocoaError(.fileWriteNoPermission)
                }
                try fileManager.createDirectory(
                    at: projectURL, withIntermediateDirectories: false
                )
            } catch {
                try? fileManager.removeItem(at: root)
                throw error
            }
            project = AgentTaskProjectIdentity(
                canonicalProjectPath: projectURL.standardizedFileURL.path,
                canonicalWorktreePath: projectURL.standardizedFileURL.path
            )
        }

        func store(
            injector: PersistenceFaultInjector = .none
        ) -> AgentTaskMetadataStore {
            AgentTaskMetadataStore(
                storageRoot: storage,
                configuration: AgentTaskStoreConfiguration(faultInjector: injector)
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
