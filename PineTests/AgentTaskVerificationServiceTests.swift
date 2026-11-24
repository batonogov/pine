import Foundation
import Synchronization
import Testing

@testable import Pine

@Suite("Agent Task Verification Service", .serialized)
@MainActor
struct AgentTaskVerificationServiceTests {
    @Test("Composition runs a separate adapter reviewer through the final Ready gate")
    func adapterCompositionProducesReady() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let adapter = try await ReviewAdapterFixture()
        let service = fixture.service(
            reviewer: adapter.driver,
            correction: { _, _ in throw ReviewTestFailure.unexpectedCorrection }
        )

        let result = await fixture.verify(service)

        #expect(result.status == .ready)
        #expect(result.readiness.isReady)
        #expect(await adapter.factory.reviewCount() == 1)
        #expect(await adapter.factory.startCount() == 1)
        #expect(await adapter.factory.stopCount() == 1)
        #expect(await adapter.driver.retainedContextCount == 0)
        #expect(fixture.registry.task(for: fixture.task.id)?.verificationState == .verified)
    }

    @Test("Review findings route to the implementer and re-review after fresh checks")
    func findingsProduceOneCorrectionThenReady() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(outcomes: [
            AgentAdapterReviewResult(outcome: .requestedChanges, finding: "Fix the pinned finding"),
            AgentAdapterReviewResult(outcome: .passed, finding: nil)
        ])
        let corrections = ReviewCounter()
        let service = fixture.service(reviewer: reviewer) { dispatch, finding in
            #expect(dispatch.feedbackReference == reviewFeedbackReference(
                finding, code: dispatch.baselineCodeState
            ))
            #expect(finding == "Fix the pinned finding")
            await corrections.increment()
            try await runOnBackground {
                try Data("PASS\ncorrected\n".utf8).write(
                    to: fixture.worktree.appending(path: "check.txt")
                )
            }
            return try await ReviewServiceFixture.capture(
                bindings: fixture.bindings, binding: fixture.binding, plan: fixture.plan
            )
        }

        let result = await fixture.verify(service)

        #expect(result.status == .ready)
        #expect(await reviewer.reviewCount() == 2)
        #expect(await corrections.value() == 1)
        let cycle = fixture.registry.task(for: fixture.task.id)?.reviewCycle
        #expect(cycle?.round == 1)
        #expect(cycle?.state == .finished)
        let persisted = await fixture.store.load(project: fixture.task.project)
        #expect(persisted.tasks.first?.reviewCycle?.round == cycle?.round)
        #expect(persisted.tasks.first?.reviewCycle?.state == cycle?.state)
    }

    @Test("Third unresolved corrected revision escalates without a fourth correction")
    func correctionLimitIsPersistentAndPreservesCandidate() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(outcomes: (1...4).map { _ in
            AgentAdapterReviewResult(outcome: .requestedChanges, finding: "Same unresolved finding")
        })
        let corrections = ReviewCounter()
        let service = fixture.service(reviewer: reviewer) { _, _ in
            await corrections.increment()
            let round = await corrections.value()
            try await runOnBackground {
                try Data("PASS\nrevision \(round)\n".utf8).write(
                    to: fixture.worktree.appending(path: "check.txt")
                )
            }
            let latest = try await ReviewServiceFixture.capture(
                bindings: fixture.bindings, binding: fixture.binding, plan: fixture.plan
            )
            await corrections.record(latest)
            return latest
        }

        let result = await fixture.verify(service)

        #expect(result.status == .needsDecision)
        #expect(!result.readiness.isReady)
        #expect(await reviewer.reviewCount() == 4)
        #expect(await corrections.value() == 3)
        #expect(await reviewer.disposalCount() == 1)
        let latest = await corrections.latestSnapshot()
        let decision = service.reviewDecision(for: fixture.task.id)
        #expect(decision?.blocker == .correctionLimit)
        #expect(decision?.round == 3)
        #expect(latest != nil && latest?.code != fixture.snapshot.code)
        #expect(decision?.candidateCodeState == latest?.code)
        #expect(decision?.candidateEnvironment == latest?.environment)
        #expect(decision?.unresolvedFindingReference != nil)
        let persisted = await fixture.store.load(project: fixture.task.project)
        #expect(persisted.tasks.first?.reviewCycle?.round == 3)
        #expect(persisted.tasks.first?.reviewCycle?.state == .needsDecision)
        #expect(persisted.tasks.first?.reviewCycle?.codeState == latest?.code)
    }

    @Test("Only explicit Verify starts work and the same grant is reused")
    func explicitActionAndGrantReuse() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(outcomes: [
            AgentAdapterReviewResult(outcome: .passed, finding: nil),
            AgentAdapterReviewResult(outcome: .passed, finding: nil)
        ])
        let service = fixture.service(reviewer: reviewer) { _, _ in
            throw ReviewTestFailure.unexpectedCorrection
        }
        #expect(await reviewer.reviewCount() == 0)
        let grantID = fixture.registry.task(for: fixture.task.id)?.checkGrant?.id

        let first = await fixture.verify(service)
        let second = await fixture.verify(service)

        #expect(first.status == .ready)
        #expect(second.status == .ready)
        #expect(await reviewer.reviewCount() == 2)
        #expect(fixture.registry.task(for: fixture.task.id)?.checkGrant?.id == grantID)
        #expect(fixture.registry.task(for: fixture.task.id)?.reviewCycle?.round == 0)
    }

    @Test("Revoked persisted grant blocks review instead of re-asking implicitly")
    func revokedGrantBlocksExecution() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(outcomes: [
            AgentAdapterReviewResult(outcome: .passed, finding: nil)
        ])
        let service = fixture.service(reviewer: reviewer) { _, _ in
            throw ReviewTestFailure.unexpectedCorrection
        }
        #expect(await fixture.executor.revoke(taskID: fixture.task.id))

        let result = await fixture.verify(service)

        #expect(result.status == .notReady)
        #expect(result.reason == .checkGrantNotCurrent)
        #expect(result.requiredAction == .approveCheckGrant)
        #expect(await reviewer.reviewCount() == 0)
    }

    @Test("Candidate mutation during review cannot publish Ready")
    func reviewerMutationFailsClosed() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(
            outcomes: [AgentAdapterReviewResult(outcome: .passed, finding: nil)],
            onReview: {
                try await runOnBackground {
                    try Data("CHANGED\n".utf8).write(to: fixture.worktree.appending(path: "check.txt"))
                }
            }
        )
        let service = fixture.service(reviewer: reviewer) { _, _ in
            throw ReviewTestFailure.unexpectedCorrection
        }

        let result = await fixture.verify(service)

        #expect(result.status != .ready)
        #expect(!result.readiness.isReady)
        #expect(fixture.registry.task(for: fixture.task.id)?.verificationState != .verified)
        #expect(service.reviewDecision(for: fixture.task.id)?.blocker == .reviewerBoundaryUnavailable)
    }

    @Test("Prompt-only reviewer control escalates before starting a session")
    func unenforcedReviewerBoundaryFailsClosed() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(
            outcomes: [AgentAdapterReviewResult(outcome: .passed, finding: nil)],
            control: .promptOnly
        )
        let service = fixture.service(reviewer: reviewer) { _, _ in
            throw ReviewTestFailure.unexpectedCorrection
        }

        let result = await fixture.verify(service)

        #expect(result.status == .needsDecision)
        #expect(await reviewer.startCount() == 0)
        #expect(service.reviewDecision(for: fixture.task.id)?.blocker == .reviewerBoundaryUnavailable)
        #expect(fixture.registry.task(for: fixture.task.id)?.verificationState != .verified)
    }

    @Test("Escalated budget survives repeated Verify and restoration")
    func escalatedCycleCannotResetBudget() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(outcomes: (1...4).map { _ in
            AgentAdapterReviewResult(outcome: .requestedChanges, finding: "Same finding")
        })
        let corrections = ReviewCounter()
        let service = fixture.service(reviewer: reviewer) { _, _ in
            await corrections.increment()
            let round = await corrections.value()
            try await runOnBackground {
                try Data("PASS\nrevision \(round)\n".utf8).write(
                    to: fixture.worktree.appending(path: "check.txt")
                )
            }
            return try await ReviewServiceFixture.capture(
                bindings: fixture.bindings, binding: fixture.binding, plan: fixture.plan
            )
        }
        let first = await fixture.verify(service)
        let cycleID = fixture.registry.task(for: fixture.task.id)?.reviewCycle?.id
        #expect(first.status == .needsDecision)

        let repeated = await fixture.verify(service)
        #expect(repeated.status == .needsDecision)
        #expect(await reviewer.reviewCount() == 4)
        #expect(await corrections.value() == 3)
        #expect(fixture.registry.task(for: fixture.task.id)?.reviewCycle?.id == cycleID)
        #expect(fixture.registry.task(for: fixture.task.id)?.reviewCycle?.round == 3)

        let snapshot = await fixture.store.load(project: fixture.task.project)
        let restoredStore = SnapshotTaskPersistence(snapshot: snapshot)
        let restoredRegistry = AgentTaskRegistry(persistence: restoredStore)
        #expect(await restoredRegistry.prepareDurableWork(in: fixture.task.project))
        let restoredReviewer = StubReviewDriver(outcomes: [])
        let restoredService = AgentTaskVerificationService(
            registry: restoredRegistry, bindings: fixture.bindings,
            reviewer: restoredReviewer,
            correction: { _, _ in throw ReviewTestFailure.unexpectedCorrection },
            editor: { .available([], isCurrent: { true }) }
        )
        let restored = await restoredService.verify(
            taskID: fixture.task.id, criteria: "The result satisfies the requested outcome",
            plan: fixture.plan, binding: fixture.binding
        )
        #expect(restored.status == .needsDecision)
        #expect(await restoredReviewer.reviewCount() == 0)
        #expect(restoredRegistry.task(for: fixture.task.id)?.reviewCycle?.id == cycleID)
        #expect(restoredRegistry.task(for: fixture.task.id)?.reviewCycle?.round == 3)
    }

    @Test("An older decision does not mask a current grant failure")
    func previousDecisionDoesNotMaskGrantFailure() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(outcomes: [], control: .promptOnly)
        let service = fixture.service(reviewer: reviewer) { _, _ in
            throw ReviewTestFailure.unexpectedCorrection
        }
        #expect(await fixture.verify(service).status == .needsDecision)
        #expect(await fixture.executor.revoke(taskID: fixture.task.id))

        let result = await fixture.verify(service)
        #expect(result.status == .notReady)
        #expect(result.reason == .checkGrantNotCurrent)
        #expect(result.requiredAction == .approveCheckGrant)
    }

    @Test("Review transport failure escalates and explicit retry does not resend")
    func reviewFailureDoesNotStrandCycle() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(outcomes: [], firstError: ReviewTestFailure.concurrentStart)
        let service = fixture.service(reviewer: reviewer) { _, _ in
            throw ReviewTestFailure.unexpectedCorrection
        }
        let first = await fixture.verify(service)
        let cycleID = fixture.registry.task(for: fixture.task.id)?.reviewCycle?.id
        #expect(first.status == .needsDecision)
        #expect(service.reviewDecision(for: fixture.task.id)?.blocker == .deliveryUnknown)
        #expect(await reviewer.disposalCount() == 1)

        let retry = await fixture.verify(service)
        #expect(retry.status == .needsDecision)
        #expect(await reviewer.reviewCount() == 1)
        #expect(fixture.registry.task(for: fixture.task.id)?.reviewCycle?.id == cycleID)
        #expect(fixture.registry.task(for: fixture.task.id)?.reviewCycle?.pendingReviewOperation == nil)
    }

    @Test("Cancellation disposes the reviewer and persists cancellation")
    func cancellationDisposesReviewer() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let started = AsyncContinuationGate()
        let release = AsyncContinuationGate()
        let adapter = try await ReviewAdapterFixture(
            reviewStarted: started, reviewRelease: release
        )
        let service = fixture.service(reviewer: adapter.driver) { _, _ in
            throw ReviewTestFailure.unexpectedCorrection
        }
        let running = Task { await fixture.verify(service) }
        #expect(await waitUntilMainActor({ started.isResolved }, ceiling: .seconds(15)))

        running.cancel()
        release.resolve()
        let result = await running.value

        #expect(result.status == .cancelled)
        #expect(await adapter.driver.retainedContextCount == 0)
        #expect(await adapter.factory.stopCount() == 1)
        #expect(fixture.registry.task(for: fixture.task.id)?.reviewCycle?.state == .cancelled)
        let persisted = await fixture.store.load(project: fixture.task.project)
        #expect(persisted.tasks.first?.reviewCycle?.state == .cancelled)
    }

    @Test("Adapter review uses the resolved fallback outcome")
    func adapterReviewWithoutObjectiveUsesFallback() async throws {
        let fixture = try await ReviewServiceFixture(objective: nil)
        defer { fixture.remove() }
        let adapter = try await ReviewAdapterFixture()
        let service = fixture.service(reviewer: adapter.driver) { _, _ in
            throw ReviewTestFailure.unexpectedCorrection
        }
        let result = await fixture.verify(service)
        #expect(result.status == .ready)
        #expect(await adapter.factory.reviewCount() == 1)
    }

    @Test("Reviewer startup is single-flight per cycle")
    func concurrentReviewerStartupCannotOverwriteSession() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let entered = AsyncContinuationGate()
        let release = AsyncContinuationGate()
        let adapter = try await ReviewAdapterFixture(startEntered: entered, startRelease: release)
        let cycleID = UUID()
        let request = try fixture.reviewRequest()
        let checks = try fixture.passingChecks(passID: request.passID)
        async let first = adapter.driver.startReviewer(AgentTaskReviewStart(
            task: fixture.task, cycleID: cycleID, request: request, checks: checks,
            binding: fixture.binding, bindings: fixture.bindings
        ))
        #expect(await waitUntilMainActor { entered.isResolved })
        async let second = adapter.driver.startReviewer(AgentTaskReviewStart(
            task: fixture.task, cycleID: cycleID, request: request, checks: checks,
            binding: fixture.binding, bindings: fixture.bindings
        ))
        var rejected = false
        do {
            _ = try await second
        } catch {
            rejected = true
        }
        release.resolve()
        _ = try await first
        #expect(rejected)
        #expect(await adapter.factory.startCount() == 1)
        await adapter.driver.disposeReviewer(cycleID: cycleID)
        #expect(await adapter.driver.retainedContextCount == 0)
    }

    @Test("Grant changed during persisted load is refused")
    func grantMutationDuringLoadFailsClosed() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let persistence = GatedGrantLoadStore(base: fixture.store)
        let registry = AgentTaskRegistry(persistence: persistence)
        #expect(await registry.prepareDurableWork(in: fixture.task.project))
        await persistence.armNextLoad()
        let running = Task {
            await registry.persistedCheckGrantIsCurrent(
                taskID: fixture.task.id, plan: fixture.plan,
                environment: fixture.snapshot.environment
            )
        }
        #expect(await waitUntilMainActor { persistence.didEnterLoad })
        var changed = try #require(registry.task(for: fixture.task.id))
        changed.checkGrant?.revokedAt = Date()
        registry.setTasksForTesting([changed])
        await persistence.releaseLoad()

        #expect(!(await running.value))
    }

    @Test("Pass superseded during review dispatch flush cannot write")
    func stalePassCannotDispatchReview() async throws {
        let flush = ReviewFlushGate()
        let fixture = try await ReviewServiceFixture(hooks: flush.hooks)
        defer { fixture.remove() }
        let adapter = try await ReviewAdapterFixture(onMake: { flush.armAfterNextWrite() })
        let service = fixture.service(reviewer: adapter.driver) { _, _ in
            throw ReviewTestFailure.unexpectedCorrection
        }
        let running = Task { await fixture.verify(service) }
        #expect(await waitUntilMainActor({ flush.didEnterWrite }, ceiling: .seconds(15)))
        let current = try #require(fixture.registry.task(for: fixture.task.id))
        let run = try #require(current.runs.last)
        #expect(fixture.registry.markVerificationPending(
            taskID: current.id, expectedRunID: run.id,
            processGeneration: run.process.processGeneration,
            verificationPassID: UUID()
        ))
        flush.releaseWrite()

        let result = await running.value
        #expect(result.status == .cancelled)
        #expect(await adapter.factory.reviewCount() == 0)
        #expect(await adapter.driver.retainedContextCount == 0)
    }

    @Test("Late verdict after reviewer stop is rejected")
    func lateVerdictAfterReviewerStopIsRejected() async throws {
        let candidate = try await ReviewServiceFixture()
        defer { candidate.remove() }
        let started = AsyncContinuationGate()
        let release = AsyncContinuationGate()
        let adapter = try await ReviewAdapterFixture(
            reviewStarted: started, reviewRelease: release
        )
        let offer = try await adapter.registry.probe(adapterID: adapter.adapterID)
        let contract = try await adapter.registry.negotiate(
            offer: offer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: adapter.versions, transportPreference: [.ownedStandardIO],
                acceptedAuthentication: [.ownedChildPipe]
            )
        )
        let request = try candidate.reviewRequest()
        let checks = try candidate.passingChecks(passID: request.passID)
        let lease = try await candidate.bindings.revalidate(candidate.binding)
        let binding = AgentAdapterReviewBinding(
            lease: lease, expected: candidate.snapshot, changeContext: "", checks: checks
        )
        let session = try await adapter.registry.makeSession(
            contract: contract, resumeFrom: nil, downstream: { _ in .accepted },
            reviewBinding: binding
        )
        try await session.start()
        let reviewing = Task {
            try await adapter.registry.review(
                on: session,
                request: AgentAdapterReviewRequest(
                    objective: "Review", criteria: request.criteria,
                    candidateFingerprint: candidate.snapshot.code.trackedFingerprint,
                    checkPlanIdentity: candidate.plan.fingerprint, binding: binding
                )
            )
        }
        #expect(await waitUntilMainActor { started.isResolved })
        await session.stop(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        release.resolve()
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            try await reviewing.value
        }
    }

    @Test("Real adapter driver rebinds the revised candidate for re-review")
    func adapterDriverReReviewsCorrectedCandidate() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let adapter = try await ReviewAdapterFixture(outcomes: [
            AgentAdapterReviewResult(outcome: .requestedChanges, finding: "Revise the candidate"),
            AgentAdapterReviewResult(outcome: .passed, finding: nil)
        ])
        let service = fixture.service(reviewer: adapter.driver) { _, _ in
            try await runOnBackground {
                try Data("PASS\nadapter revision\n".utf8).write(
                    to: fixture.worktree.appending(path: "check.txt")
                )
            }
            return try await ReviewServiceFixture.capture(
                bindings: fixture.bindings, binding: fixture.binding, plan: fixture.plan
            )
        }

        let result = await fixture.verify(service)

        #expect(result.status == .ready)
        #expect(await adapter.factory.reviewCount() == 2)
        let candidates = await adapter.factory.reviewedCandidates()
        #expect(candidates?.count == 2)
        #expect(candidates?.first == fixture.snapshot.code)
        #expect(candidates?.last != fixture.snapshot.code)
        #expect(await adapter.driver.retainedContextCount == 0)
    }

    @Test("Cancellation after correction reservation reaches a clean terminal state")
    func cancellationAfterCorrectionReservationDoesNotStrandCycle() async throws {
        let flush = ReviewFlushGate()
        let fixture = try await ReviewServiceFixture(hooks: flush.hooks)
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(
            outcomes: [AgentAdapterReviewResult(outcome: .requestedChanges, finding: "Correct")],
            onReview: { flush.armNextWrite() }
        )
        let corrections = ReviewCounter()
        let service = fixture.service(reviewer: reviewer) { _, _ in
            await corrections.increment()
            return fixture.snapshot
        }
        let running = Task { await fixture.verify(service) }
        flush.onWrite { running.cancel() }
        #expect(await waitUntilMainActor({ flush.didEnterWrite }, ceiling: .seconds(15)))
        flush.releaseWrite()
        let result = await running.value

        #expect(result.status == .cancelled)
        #expect(await corrections.value() == 0)
        #expect(fixture.registry.task(for: fixture.task.id)?.reviewCycle?.state == .cancelled)
        let persisted = await fixture.store.load(project: fixture.task.project)
        #expect(persisted.tasks.first?.reviewCycle?.state == .cancelled)

        let retryReviewer = StubReviewDriver(outcomes: [
            AgentAdapterReviewResult(outcome: .passed, finding: nil)
        ])
        let retry = fixture.service(reviewer: retryReviewer) { _, _ in fixture.snapshot }
        #expect(await fixture.verify(retry).status == .ready)
    }

    @Test("Restored pending review is reconciled before explicit redispatch")
    func restoredPendingReviewCanRedispatch() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        try await seedRestoredCycle(fixture, reserved: false)
        let snapshot = await fixture.store.load(project: fixture.task.project)
        let restoredRegistry = AgentTaskRegistry(
            persistence: SnapshotTaskPersistence(snapshot: snapshot)
        )
        #expect(await restoredRegistry.prepareDurableWork(in: fixture.task.project))
        let reviewer = StubReviewDriver(outcomes: [
            AgentAdapterReviewResult(outcome: .passed, finding: nil)
        ])
        let service = AgentTaskVerificationService(
            registry: restoredRegistry, bindings: fixture.bindings, reviewer: reviewer,
            correction: { _, _ in throw ReviewTestFailure.unexpectedCorrection },
            editor: { .available([], isCurrent: { true }) }
        )
        let result = await service.verify(
            taskID: fixture.task.id, criteria: "The result satisfies the requested outcome",
            plan: fixture.plan, binding: fixture.binding
        )
        #expect(result.status == .ready)
        #expect(await reviewer.reviewCount() == 1)
        #expect(restoredRegistry.task(for: fixture.task.id)?.reviewCycle?.state == .finished)
    }

    @Test("Restored reserved correction escalates as delivery unknown")
    func restoredReservedCorrectionEscalates() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        try await seedRestoredCycle(fixture, reserved: true)
        let snapshot = await fixture.store.load(project: fixture.task.project)
        let restoredRegistry = AgentTaskRegistry(
            persistence: SnapshotTaskPersistence(snapshot: snapshot)
        )
        #expect(await restoredRegistry.prepareDurableWork(in: fixture.task.project))
        let reviewer = StubReviewDriver(outcomes: [])
        let service = AgentTaskVerificationService(
            registry: restoredRegistry, bindings: fixture.bindings, reviewer: reviewer,
            correction: { _, _ in throw ReviewTestFailure.unexpectedCorrection },
            editor: { .available([], isCurrent: { true }) }
        )
        let result = await service.verify(
            taskID: fixture.task.id, criteria: "The result satisfies the requested outcome",
            plan: fixture.plan, binding: fixture.binding
        )
        #expect(result.status == .needsDecision)
        #expect(service.reviewDecision(for: fixture.task.id)?.blocker == .deliveryUnknown)
        #expect(await reviewer.reviewCount() == 0)
        #expect(restoredRegistry.task(for: fixture.task.id)?.reviewCycle?.pending != nil)
    }

    @Test("Pre-review checksNotObserved keeps its own required action")
    func oldDecisionDoesNotMaskChecksNotObserved() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let reviewer = StubReviewDriver(outcomes: [], control: .promptOnly)
        let initial = fixture.service(reviewer: reviewer) { _, _ in fixture.snapshot }
        #expect(await fixture.verify(initial).status == .needsDecision)
        let executor = AgentTaskCheckExecutor(
            registry: fixture.registry, bindings: fixture.bindings,
            captureAfterProcess: { capture in
                try? await runOnBackground {
                    let link = fixture.worktree.appending(path: "unsupported-review-input")
                    if !FileManager.default.fileExists(atPath: link.path) {
                        try FileManager.default.createSymbolicLink(
                            at: link, withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
                        )
                    }
                }
                return await capture.capture()
            }
        )
        let service = AgentTaskVerificationService(
            registry: fixture.registry, bindings: fixture.bindings, executor: executor,
            reviewer: reviewer, correction: { _, _ in fixture.snapshot },
            editor: { .available([], isCurrent: { true }) }
        )

        let result = await fixture.verify(service)
        #expect(result.status == .needsDecision)
        #expect(result.reason == .checksNotObserved)
        #expect(result.requiredAction == .rerunRequiredChecks)
    }

    @Test("Late verdict after pass supersession is not admitted")
    func lateVerdictAfterPassSupersessionIsNotAdmitted() async throws {
        let fixture = try await ReviewServiceFixture()
        defer { fixture.remove() }
        let started = AsyncContinuationGate()
        let release = AsyncContinuationGate()
        let adapter = try await ReviewAdapterFixture(
            reviewStarted: started, reviewRelease: release
        )
        let service = fixture.service(reviewer: adapter.driver) { _, _ in fixture.snapshot }
        let running = Task { await fixture.verify(service) }
        #expect(await waitUntilMainActor({ started.isResolved }, ceiling: .seconds(15)))
        let current = try #require(fixture.registry.task(for: fixture.task.id))
        let run = try #require(current.runs.last)
        #expect(fixture.registry.markVerificationPending(
            taskID: current.id, expectedRunID: run.id,
            processGeneration: run.process.processGeneration,
            verificationPassID: UUID()
        ))
        release.resolve()
        let result = await running.value

        #expect(result.status == .cancelled)
        let task = try #require(fixture.registry.task(for: fixture.task.id))
        #expect(task.reviewCycle?.state != .finished)
        #expect(task.reviewCycle?.pending == nil)
        #expect(!task.evidence.contains { $0.kind == .reviewerOutcome })
        let persisted = await fixture.store.load(project: fixture.task.project)
        #expect(persisted.tasks.first?.reviewCycle?.state != .finished)
        #expect(persisted.tasks.first?.reviewCycle?.pending == nil)
        #expect(persisted.tasks.first?.evidence.contains { $0.kind == .reviewerOutcome } == false)
    }

    private func seedRestoredCycle(
        _ fixture: ReviewServiceFixture, reserved: Bool
    ) async throws {
        let reviewer = AgentVendorSessionIdentity(
            provider: "kimiCode", opaqueIdentifier: "independent-reviewer"
        )
        let plan = AgentTaskReviewPlan(
            requestedOutcomeReference: AgentHistoryContentHash.sha256Hex(Data("Outcome".utf8)),
            criteriaVersion: AgentHistoryContentHash.sha256Hex(Data(
                "The result satisfies the requested outcome".utf8
            )),
            checkPlanIdentity: fixture.plan.fingerprint,
            reviewerControl: .writeDisabledAtAdapter
        )
        var current = try #require(fixture.registry.task(for: fixture.task.id))
        #expect(await fixture.registry.persistReviewTransition(
            expected: current,
            mutate: { task -> Bool in
                AgentTaskReviewOrchestrator.beginCycle(
                    task: &task, plan: plan, codeState: fixture.snapshot.code,
                    environment: fixture.snapshot.environment
                )
            }
        ) == true)
        current = try #require(fixture.registry.task(for: fixture.task.id))
        #expect(await fixture.registry.persistReviewTransition(
            expected: current,
            mutate: { AgentTaskReviewOrchestrator.bindReviewerSession(task: &$0, reviewer) }
        ) == true)
        current = try #require(fixture.registry.task(for: fixture.task.id))
        if reserved {
            #expect(await fixture.registry.persistReviewTransition(
                expected: current,
                mutate: { task -> AgentTaskCorrectionDispatch? in
                    AgentTaskReviewOrchestrator.routeFailedCheck(
                        task: &task, reference: "restored-correction",
                        codeState: fixture.snapshot.code, environment: fixture.snapshot.environment
                    )
                }
            ) != nil)
        } else {
            #expect(await fixture.registry.persistReviewTransition(
                expected: current,
                mutate: { AgentTaskReviewOrchestrator.issueReviewDispatch(task: &$0) }
            ) != nil)
        }
    }
}

private enum ReviewTestFailure: Error {
    case unexpectedCorrection
    case concurrentStart
}

nonisolated private func reviewFeedbackReference(
    _ finding: String, code: AgentTaskCodeStateIdentity
) -> String {
    var hash = AgentVerificationCanonicalHasher(domain: "pine.ade.review-feedback.v1")
    hash.append("finding", finding)
    hash.append("head", code.headCommit ?? "")
    hash.append("tracked", code.trackedFingerprint)
    hash.append("untracked", code.untrackedFingerprint)
    hash.append("ignored", code.ignoredRelevantFingerprint)
    return hash.finish()
}

private actor ReviewCounter {
    private var count = 0
    private var latest: AgentVerificationIdentitySnapshot?
    func increment() { count += 1 }
    func value() -> Int { count }
    func record(_ snapshot: AgentVerificationIdentitySnapshot) { latest = snapshot }
    func latestSnapshot() -> AgentVerificationIdentitySnapshot? { latest }
}

private actor StubReviewDriver: AgentTaskReviewDriving {
    nonisolated let reviewerControl: AgentTaskReviewerControl
    private var outcomes: [AgentAdapterReviewResult]
    private var starts = 0
    private var reviews = 0
    private let onReview: (@Sendable () async throws -> Void)?
    private var firstError: (any Error)?
    private var disposals = 0

    init(
        outcomes: [AgentAdapterReviewResult],
        control: AgentTaskReviewerControl = .writeDisabledAtAdapter,
        firstError: (any Error)? = nil,
        onReview: (@Sendable () async throws -> Void)? = nil
    ) {
        self.outcomes = outcomes
        reviewerControl = control
        self.firstError = firstError
        self.onReview = onReview
    }

    func startReviewer(
        _ start: AgentTaskReviewStart
    ) async throws -> AgentVendorSessionIdentity {
        starts += 1
        return AgentVendorSessionIdentity(provider: "kimiCode", opaqueIdentifier: "independent-reviewer")
    }

    func reviewerIdentity(cycleID: UUID) async throws -> AgentVendorSessionIdentity {
        AgentVendorSessionIdentity(provider: "kimiCode", opaqueIdentifier: "independent-reviewer")
    }

    func rebindReviewer(_ start: AgentTaskReviewStart) async throws {}

    func review(
        dispatch: AgentTaskReviewDispatch, criteria: String,
        beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterReviewResult {
        reviews += 1
        if let firstError {
            self.firstError = nil
            throw firstError
        }
        try beforeDispatch()
        try await onReview?()
        guard !outcomes.isEmpty else { throw ReviewTestFailure.unexpectedCorrection }
        return outcomes.removeFirst()
    }

    func disposeReviewer(cycleID: UUID) async { disposals += 1 }

    func reviewCount() -> Int { reviews }
    func startCount() -> Int { starts }
    func disposalCount() -> Int { disposals }
}

// MARK: - Real adapter registry fixture

private actor ReviewAdapterSession: AgentAdapterReviewingSession {
    nonisolated let contract: NegotiatedAdapterContract
    private var starts = 0
    private var stops = 0
    private var reviews = 0
    private var outcomes: [AgentAdapterReviewResult]
    private var reviewedCandidates: [AgentTaskCodeStateIdentity] = []
    private let reviewStarted: AsyncContinuationGate?
    private let reviewRelease: AsyncContinuationGate?
    private let startEntered: AsyncContinuationGate?
    private let startRelease: AsyncContinuationGate?

    init(
        contract: NegotiatedAdapterContract,
        outcomes: [AgentAdapterReviewResult] = [],
        reviewStarted: AsyncContinuationGate? = nil,
        reviewRelease: AsyncContinuationGate? = nil,
        startEntered: AsyncContinuationGate? = nil,
        startRelease: AsyncContinuationGate? = nil
    ) {
        self.contract = contract
        self.outcomes = outcomes
        self.reviewStarted = reviewStarted
        self.reviewRelease = reviewRelease
        self.startEntered = startEntered
        self.startRelease = startRelease
    }

    var reviewerIdentity: AgentVendorSessionIdentity {
        AgentVendorSessionIdentity(provider: "kimiCode", opaqueIdentifier: "adapter-reviewer")
    }

    func start() async throws {
        starts += 1
        startEntered?.resolve()
        if let startRelease { await startRelease.wait() }
    }
    func stop(deadline: ContinuousClock.Instant) async { stops += 1 }

    func review(
        _ request: AgentAdapterReviewRequest,
        beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterReviewResult {
        try beforeDispatch()
        reviews += 1
        reviewedCandidates.append(request.binding.expected.code)
        reviewStarted?.resolve()
        if let reviewRelease { await reviewRelease.wait() }
        return outcomes.isEmpty
            ? AgentAdapterReviewResult(outcome: .passed, finding: nil)
            : outcomes.removeFirst()
    }

    func reviewCount() -> Int { reviews }
    func candidates() -> [AgentTaskCodeStateIdentity] { reviewedCandidates }
    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

nonisolated private struct ReviewAdapterGates {
    let reviewStarted: AsyncContinuationGate?
    let reviewRelease: AsyncContinuationGate?
    let startEntered: AsyncContinuationGate?
    let startRelease: AsyncContinuationGate?

    init(
        reviewStarted: AsyncContinuationGate? = nil,
        reviewRelease: AsyncContinuationGate? = nil,
        startEntered: AsyncContinuationGate? = nil,
        startRelease: AsyncContinuationGate? = nil
    ) {
        self.reviewStarted = reviewStarted
        self.reviewRelease = reviewRelease
        self.startEntered = startEntered
        self.startRelease = startRelease
    }
}

private final class ReviewAdapterFactory: AgentAdapterReviewingFactory, @unchecked Sendable {
    let reviewerControl: AgentTaskReviewerControl = .writeDisabledAtAdapter
    let id: AdapterFactoryID
    private let lock = NSLock()
    private var current: ReviewAdapterSession?
    private let gates: ReviewAdapterGates
    private let outcomes: [AgentAdapterReviewResult]
    private let onMake: (@Sendable () -> Void)?

    init(
        id: AdapterFactoryID, gates: ReviewAdapterGates = ReviewAdapterGates(),
        outcomes: [AgentAdapterReviewResult] = [],
        onMake: (@Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.gates = gates
        self.outcomes = outcomes
        self.onMake = onMake
    }

    func probe() async throws -> AdapterProbeResult {
        let version = PineAdapterContractVersion(major: 1, minor: 1)
        return try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion("2.6.2"), detectedSchema: nil,
            offeredProfiles: [KimiACPSession.profile()],
            offeredContractVersions: PineAdapterContractVersionRange(minimum: version, maximum: version)
        )
    }

    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        let session = ReviewAdapterSession(
            contract: request.contract, outcomes: outcomes,
            reviewStarted: gates.reviewStarted, reviewRelease: gates.reviewRelease,
            startEntered: gates.startEntered, startRelease: gates.startRelease
        )
        lock.withLock { current = session }
        onMake?()
        return session
    }

    func reviewCount() async -> Int? { await lock.withLock { current }?.reviewCount() }
    func startCount() async -> Int? { await lock.withLock { current }?.startCount() }
    func stopCount() async -> Int? { await lock.withLock { current }?.stopCount() }
    func reviewedCandidates() async -> [AgentTaskCodeStateIdentity]? {
        await lock.withLock { current }?.candidates()
    }
}

private struct ReviewAdapterFixture {
    let driver: AgentTaskAdapterReviewDriver
    let factory: ReviewAdapterFactory
    let registry: AgentAdapterRegistry
    let versions: PineAdapterContractVersionRange
    let adapterID: AdapterID

    init(
        reviewStarted: AsyncContinuationGate? = nil,
        reviewRelease: AsyncContinuationGate? = nil,
        startEntered: AsyncContinuationGate? = nil,
        startRelease: AsyncContinuationGate? = nil,
        outcomes: [AgentAdapterReviewResult] = [],
        onMake: (@Sendable () -> Void)? = nil
    ) async throws {
        let version = PineAdapterContractVersion(major: 1, minor: 1)
        let versions = PineAdapterContractVersionRange(minimum: version, maximum: version)
        factory = ReviewAdapterFactory(
            id: try AdapterFactoryID(validating: "review-fixture"),
            gates: ReviewAdapterGates(
                reviewStarted: reviewStarted, reviewRelease: reviewRelease,
                startEntered: startEntered, startRelease: startRelease
            ),
            outcomes: outcomes, onMake: onMake
        )
        let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "kimiCode"))
        let adapterID = try AdapterID(validating: "review-fixture")
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(AdapterDescriptor(
                adapterID: adapterID, agentID: presentation.agentID, factoryID: factory.id,
                contractVersions: versions, maximumProfiles: [KimiACPSession.profile()]
            ), factory)]
        )
        self.registry = registry
        self.versions = versions
        self.adapterID = adapterID
        driver = AgentTaskAdapterReviewDriver(
            adapters: registry, adapterID: adapterID, versions: versions
        )
    }
}

// MARK: - Real identity/check/persistence fixture

struct ReviewServiceFixture: Sendable {
    let root: URL
    let project: URL
    let worktree: URL
    let store: AgentTaskMetadataStore
    let registry: AgentTaskRegistry
    let task: AgentTask
    let bindings: AgentTaskEnvironmentBindings
    let binding: AgentTaskEnvironmentBinding
    let plan: AgentTaskCheckPlan
    let snapshot: AgentVerificationIdentitySnapshot
    let executor: AgentTaskCheckExecutor

    @MainActor
    init(
        objective: String? = "Produce the requested result",
        hooks: AgentTaskStoreHooks = AgentTaskStoreHooks()
    ) async throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PineReviewService-\(UUID())").resolvingSymlinksInPath()
        project = root.appending(path: "project")
        worktree = root.appending(path: "worktree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Self.git(["init", "-b", "main"], at: project)
        try Data("PASS\n".utf8).write(to: project.appending(path: "check.txt"))
        try Self.git(["add", "check.txt"], at: project)
        try Self.git([
            "-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid",
            "commit", "-m", "fixture"
        ], at: project)

        let terminalID = UUID()
        let now = Date()
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: project.path, canonicalWorktreePath: worktree.path
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: AgentTaskBridgeContext(
                project: identity,
                route: AgentTaskRoute(
                    paneID: UUID(), tabID: terminalID, terminalID: terminalID, availability: .missing
                ),
                origin: .discoveredInTerminal, observedAt: now
            ),
            objective: objective
        )
        var run = AgentTaskRun(AgentTaskRunInput(
            id: UUID(), terminalID: terminalID,
            process: AgentProcessEvidence(
                processIdentifier: nil, processGeneration: 1, startIdentifier: nil,
                observedStartedAt: now.addingTimeInterval(-1), startIsAuthoritative: false
            ),
            status: AgentTaskRunStatus(state: .done, liveness: .terminated, observedAt: now)
        ))
        run.outcome = .unverified
        run.vendorIdentity = AgentVendorSessionIdentity(provider: "claude", opaqueIdentifier: "author")
        task.runs = [run]
        task.lifecycle = .paused
        self.task = task

        let bindings = AgentTaskEnvironmentBindings()
        self.bindings = bindings
        _ = try await bindings.reserve(
            taskID: task.id, runID: run.id, canonicalProject: project, expectedWorktree: worktree
        )
        let taskID = task.id
        let runID = run.id
        let worktreeURL = worktree
        let projectURL = project
        try await runOnBackground {
            try Self.git([
                "worktree", "add", "-b",
                AgentTaskEnvironmentBindings.branchName(taskID: taskID, runID: runID), worktreeURL.path
            ], at: projectURL)
        }
        binding = try await bindings.adopt(taskID: taskID, runID: runID, candidates: [worktreeURL])
        plan = AgentTaskCheckPlan(
            scheme: 1, recipeFingerprint: String(repeating: "a", count: 64),
            commands: [AgentTaskCheckCommand(
                id: "check", required: true, executable: URL(fileURLWithPath: "/usr/bin/grep"),
                arguments: ["-q", "PASS", "check.txt"], workingDirectory: "", timeout: 10
            )], capturePolicy: .conservative, configurationFiles: []
        )
        store = AgentTaskMetadataStore(
            storageRoot: root.appending(path: "metadata"),
            configuration: AgentTaskStoreConfiguration(privateComponentCount: 1, hooks: hooks)
        )
        registry = AgentTaskRegistry(persistence: store)
        #expect(await store.save(tasks: [task], project: task.project) == .saved(taskCount: 1))
        #expect(await registry.prepareDurableWork(in: task.project))
        snapshot = try await Self.capture(bindings: bindings, binding: binding, plan: plan)
        executor = AgentTaskCheckExecutor(registry: registry, bindings: bindings)
        #expect(await executor.approve(taskID: task.id, plan: plan, environment: snapshot.environment))
        #expect(registry.recordEvidence(AgentTaskEvidenceFact(
            kind: .agentReportedCompletion, runID: run.id, processGeneration: run.process.processGeneration,
            trust: .verified, result: .reported, observedAt: Date(),
            codeState: snapshot.code, environment: snapshot.environment
        ), taskID: task.id) == .accepted)
    }

    @MainActor
    func service(
        reviewer: any AgentTaskReviewDriving,
        correction: @escaping AgentTaskCorrectionHandler
    ) -> AgentTaskVerificationService {
        AgentTaskVerificationService(
            registry: registry, bindings: bindings, executor: executor,
            reviewer: reviewer, correction: correction,
            editor: { .available([], isCurrent: { true }) }
        )
    }

    @MainActor
    func verify(_ service: AgentTaskVerificationService) async -> AgentTaskVerificationResult {
        await service.verify(
            taskID: task.id, criteria: "The result satisfies the requested outcome",
            plan: plan, binding: binding
        )
    }

    nonisolated func reviewRequest(passID: UUID = UUID()) throws -> AgentTaskVerificationReviewRequest {
        let run = try #require(task.runs.last)
        return AgentTaskVerificationReviewRequest(
            taskID: task.id, runID: run.id, passID: passID, expected: snapshot,
            criteria: "The result satisfies the requested outcome"
        )
    }

    nonisolated func passingChecks(passID: UUID) throws -> AgentTaskCheckObservation {
        let run = try #require(task.runs.last)
        return AgentTaskCheckObservation(
            taskID: task.id, runID: run.id, passID: passID, executionID: UUID(),
            planFingerprint: plan.fingerprint, processGeneration: run.process.processGeneration,
            journalCompleted: true,
            results: [AgentTaskCheckObservation.CommandResult(
                operationID: UUID(), fingerprint: try #require(plan.commands.first).fingerprint,
                required: true, status: .succeeded
            )],
            preCodeState: snapshot.code, postCodeState: snapshot.code,
            environment: snapshot.environment
        )
    }

    nonisolated static func capture(
        bindings: AgentTaskEnvironmentBindings, binding: AgentTaskEnvironmentBinding,
        plan: AgentTaskCheckPlan
    ) async throws -> AgentVerificationIdentitySnapshot {
        let lease = try await bindings.revalidate(binding)
        let capture = AgentVerificationIdentityCapture(
            inputs: .init(
                lease: lease, policy: plan.capturePolicy,
                editor: .available([], isCurrent: { true }),
                tools: Array(Set(plan.commands.map(\.executable))),
                configurationFiles: []
            ), cancellation: GitCommandCancellationToken()
        )
        guard case .current(let snapshot) = await capture.capture() else {
            throw ReviewTestFailure.unexpectedCorrection
        }
        return snapshot
    }

    nonisolated func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    nonisolated private static func git(_ arguments: [String], at project: URL) throws {
        var environment = [
            "-i", "PATH=/usr/bin:/bin", "HOME=/var/empty", "LC_ALL=C",
            "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"
        ]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment.append("DEVELOPER_DIR=" + developer)
        }
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: environment + [
                "/usr/bin/git", "-c", "core.hooksPath=/dev/null",
                "-c", "commit.gpgsign=false", "-c", "init.templateDir="
            ] + arguments,
            at: project, timeout: 10
        )
        guard result.succeeded else { throw CocoaError(.fileReadUnknown) }
    }
}

private actor GatedGrantLoadStore: AgentTaskPersisting {
    private let base: AgentTaskMetadataStore
    private let entered = Mutex(false)
    private let release = AsyncContinuationGate()
    private var armed = false

    init(base: AgentTaskMetadataStore) { self.base = base }
    nonisolated var didEnterLoad: Bool { entered.withLock { $0 } }

    func armNextLoad() { armed = true }
    nonisolated func releaseLoad() { release.resolve() }

    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        let result = await base.load(project: project)
        if armed {
            armed = false
            entered.withLock { $0 = true }
            await release.wait()
        }
        return result
    }

    func save(
        tasks: [AgentTask], project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        await base.save(tasks: tasks, project: project, authorization: authorization)
    }

    func save(
        tasks: [AgentTask], envelope: AgentTaskEnvelopeState,
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        await base.save(
            tasks: tasks, envelope: envelope, project: project, authorization: authorization
        )
    }
}

private actor SnapshotTaskPersistence: AgentTaskPersisting {
    private var snapshot: AgentTaskMetadataLoadResult

    init(snapshot: AgentTaskMetadataLoadResult) { self.snapshot = snapshot }

    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        snapshot
    }

    func save(
        tasks: [AgentTask], project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        let revision = authorization.map { AgentTaskDiskRevision.versioned($0.ticket.nextDiskRevision) }
        snapshot = AgentTaskMetadataLoadResult(
            status: .loaded, tasks: tasks, revision: revision,
            envelope: snapshot.envelope
        )
        return .saved(taskCount: tasks.count)
    }

    func save(
        tasks: [AgentTask], envelope: AgentTaskEnvelopeState,
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        let revision = authorization.map { AgentTaskDiskRevision.versioned($0.ticket.nextDiskRevision) }
        snapshot = AgentTaskMetadataLoadResult(
            status: .loaded, tasks: tasks, revision: revision, envelope: envelope
        )
        return .saved(taskCount: tasks.count)
    }
}

nonisolated private final class ReviewFlushGate: @unchecked Sendable {
    private let state = Mutex((armed: false, skip: 0, entered: false))
    private let release = DispatchSemaphore(value: 0)
    private let writeAction = Mutex<(@Sendable () -> Void)?>(nil)
    var didEnterWrite: Bool { state.withLock { $0.entered } }

    var hooks: AgentTaskStoreHooks {
        AgentTaskStoreHooks(phase: { [self] phase in
            guard phase == .beforeAtomicRename else { return }
            let shouldWait = state.withLock { value in
                guard value.armed else { return false }
                if value.skip > 0 {
                    value.skip -= 1
                    return false
                }
                value.armed = false
                value.entered = true
                return true
            }
            if shouldWait {
                writeAction.withLock { $0?() }
                _ = release.wait(timeout: .now() + 5)
            }
        })
    }

    func onWrite(_ action: @escaping @Sendable () -> Void) {
        writeAction.withLock { $0 = action }
    }

    func armNextWrite() {
        state.withLock { $0.armed = true; $0.skip = 0 }
    }

    func armAfterNextWrite() {
        state.withLock { $0.armed = true; $0.skip = 1 }
    }

    func releaseWrite() { release.signal() }
}
