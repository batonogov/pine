import Foundation
import Synchronization

nonisolated struct AgentTaskReviewStart: Sendable {
    let task: AgentTask
    let cycleID: UUID
    let request: AgentTaskVerificationReviewRequest
    let checks: AgentTaskCheckObservation
    let binding: AgentTaskEnvironmentBinding
    let bindings: AgentTaskEnvironmentBindings
}

/// Production reviewer seam. A driver owns a distinct provider session; the
/// durable cycle admits verdicts only from the identity returned here.
nonisolated protocol AgentTaskReviewDriving: Sendable {
    var reviewerControl: AgentTaskReviewerControl { get }
    func startReviewer(
        _ start: AgentTaskReviewStart
    ) async throws -> AgentVendorSessionIdentity
    func reviewerIdentity(cycleID: UUID) async throws -> AgentVendorSessionIdentity
    func rebindReviewer(_ start: AgentTaskReviewStart) async throws
    func review(
        dispatch: AgentTaskReviewDispatch, criteria: String,
        beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterReviewResult
    func disposeReviewer(cycleID: UUID) async
}

nonisolated enum AgentTaskVerificationServiceError: Error, Sendable {
    case unavailable
    case invalidReview
}

/// Runtime-only negative fence checked by the physical reviewer write. The
/// registry revokes it synchronously when its pass/run/candidate scope moves.
nonisolated final class AgentTaskReviewAuthority: Sendable {
    struct State: Sendable {
        var active = true
        var admitting = false
    }
    let id = UUID()
    private let state = Mutex(State())
    func check() throws {
        try state.withLock {
            if !$0.active { throw AgentTaskVerificationServiceError.unavailable }
        }
    }
    func revoke() { state.withLock { $0.active = false } }
    func beginAdmission() { state.withLock { $0.admitting = true } }
    var isAdmitting: Bool { state.withLock { $0.admitting } }
}

nonisolated struct AgentTaskReviewScope: Sendable {
    let passID: UUID
    let taskID: UUID
    let runID: UUID
    let processGeneration: UInt64
    let cycleID: UUID
    let operationID: UUID
}

/// One automatic correction within the explicit Verify action. The returned
/// identity is an implementer observation, not check or reviewer evidence.
typealias AgentTaskCorrectionHandler = @Sendable (
    AgentTaskCorrectionDispatch, String
) async throws -> AgentVerificationIdentitySnapshot

/// Explicit-only task verification action. Construction, task settlement and
/// restoration do not call `verify`; #1725 can invoke this method from its
/// future user action without adding another evidence or Ready path.
@MainActor
final class AgentTaskVerificationService {
    private let registry: AgentTaskRegistry
    private let bindings: AgentTaskEnvironmentBindings
    private let executor: AgentTaskCheckExecutor
    private let reviewer: any AgentTaskReviewDriving
    private let correction: AgentTaskCorrectionHandler
    private let editor: @MainActor () -> AgentVerificationEditorPreflight
    private var activeTasks: Set<UUID> = []
    private var probes: [UUID: AgentVerificationIdentitySnapshot] = [:]
    private var checks: [UUID: AgentTaskCheckObservation] = [:]
    private var findings: [UUID: [String: String]] = [:]
    private var reviewCycles: [UUID: UUID] = [:]
    private var liveReviewCycles: Set<UUID> = []

    init(
        registry: AgentTaskRegistry,
        bindings: AgentTaskEnvironmentBindings,
        executor: AgentTaskCheckExecutor? = nil,
        reviewer: any AgentTaskReviewDriving,
        correction: @escaping AgentTaskCorrectionHandler,
        editor: @escaping @MainActor () -> AgentVerificationEditorPreflight = {
            .unavailable
        }
    ) {
        self.registry = registry
        self.bindings = bindings
        self.executor = executor ?? AgentTaskCheckExecutor(registry: registry, bindings: bindings)
        self.reviewer = reviewer
        self.correction = correction
        self.editor = editor
    }

    /// Runs required checks and independent review, then routes findings to
    /// the implementer for at most three persisted correction rounds. A still
    /// valid persisted grant is reused; this action has no approval side path.
    func verify(
        taskID: UUID, criteria: String, plan: AgentTaskCheckPlan,
        binding: AgentTaskEnvironmentBinding
    ) async -> AgentTaskVerificationResult {
        guard !activeTasks.contains(taskID) else {
            return unavailableResult(taskID: taskID, status: .notReady)
        }
        activeTasks.insert(taskID)
        let result = await performVerify(
            taskID: taskID, criteria: criteria, plan: plan, binding: binding
        )
        if result.status == .cancelled {
            await requestReviewCancellation(taskID: taskID)
        }
        if let cycleID = reviewCycles[taskID] {
            await reviewer.disposeReviewer(cycleID: cycleID)
        }
        await confirmReviewCancellation(taskID: taskID)
        activeTasks.remove(taskID)
        probes.removeValue(forKey: taskID)
        checks.removeValue(forKey: taskID)
        findings.removeValue(forKey: taskID)
        reviewCycles.removeValue(forKey: taskID)
        return result
    }

    private func performVerify(
        taskID: UUID, criteria: String, plan: AgentTaskCheckPlan,
        binding: AgentTaskEnvironmentBinding
    ) async -> AgentTaskVerificationResult {
        findings[taskID] = [:]
        let coordinator = AgentTaskVerificationCoordinator(
            probeIdentity: { [weak self] task in
                await self?.probe(task, plan: plan, binding: binding)
            },
            grantIsCurrent: { [weak self] task in
                await self?.grantIsCurrent(task, plan: plan) ?? false
            },
            runRequiredChecks: { [weak self] request in
                guard let self, let observation = await self.executor.run(
                    request: request, plan: plan, binding: binding, editor: self.editor()
                ) else { throw AgentTaskVerificationServiceError.unavailable }
                await self.noteChecks(observation)
                return observation
            },
            startReview: { [weak self] request in
                guard let self else { throw AgentTaskVerificationServiceError.unavailable }
                return try await self.review(request, plan: plan, binding: binding)
            }
        )

        // Four reviews are the initial review plus the three returned
        // corrections. The durable cycle, not this loop, owns the round count.
        for _ in 0...3 {
            if Task.isCancelled {
                return unavailableResult(taskID: taskID, status: .cancelled)
            }
            let result = await coordinator.runVerificationPass(
                taskID: taskID, criteria: criteria, registry: registry
            )
            let reviewOutcome = [.reviewRequestedChanges, .reviewFailed, .reviewNotObserved]
                .contains(result.reason)
                || (result.reason == nil && result.readiness.gaps.contains(.failedAttempt))
            if reviewOutcome, let decision = reviewDecision(for: taskID) {
                return decisionResult(decision, fallback: result)
            }
            // A decision from an older cycle never masks a current pre-review
            // failure such as a revoked grant or stale candidate identity.
            guard result.reason == .reviewRequestedChanges,
                  let current = registry.task(for: taskID),
                  let cycle = current.reviewCycle,
                  let pending = cycle.pending,
                  let run = current.runs.last,
                  let terminalID = run.terminalID,
                  let finding = findings[taskID]?[pending.feedback.reference] else {
                return result
            }
            let dispatch = AgentTaskCorrectionDispatch(
                operationID: pending.operationID, taskID: current.id,
                runID: run.id, terminalID: terminalID, cycleID: cycle.id,
                feedbackReference: pending.feedback.reference,
                baselineCodeState: cycle.codeState
            )
            do {
                let returned = try await correction(dispatch, finding)
                guard let current = registry.task(for: taskID),
                      await registry.persistReviewTransition(expected: current, mutate: { task in
                          guard AgentTaskReviewOrchestrator.recordImplementerReturn(
                              task: &task, operationID: dispatch.operationID,
                              codeState: returned.code, environment: returned.environment
                          ), let index = task.runs.indices.last else { return false }
                          // A returned correction is a new unverified candidate
                          // in the SAME run/cycle, not a new user attempt.
                          task.runs[index].outcome = .unverified
                          task.lifecycle = .paused
                          task.completedAt = nil
                          task.attention = .none
                          task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
                          return true
                      }) == true,
                      let run = registry.task(for: taskID)?.runs.last else {
                    return unavailableResult(taskID: taskID, status: .notReady)
                }
                _ = registry.recordEvidence(AgentTaskEvidenceFact(
                    kind: .agentReportedCompletion, runID: run.id,
                    processGeneration: run.process.processGeneration,
                    trust: .verified, result: .reported, observedAt: Date(),
                    codeState: returned.code, environment: returned.environment
                ), taskID: taskID, deferSettlement: true)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    await requestReviewCancellation(taskID: taskID)
                    return unavailableResult(taskID: taskID, status: .cancelled)
                }
                await escalate(taskID: taskID, blocker: .infrastructureFailure)
                if let decision = reviewDecision(for: taskID) {
                    return decisionResult(decision, fallback: result)
                }
                return unavailableResult(taskID: taskID, status: .needsDecision)
            }
        }
        await escalate(taskID: taskID, blocker: .correctionLimit)
        if let decision = reviewDecision(for: taskID) {
            return decisionResult(decision, fallback: unavailableResult(taskID: taskID, status: .needsDecision))
        }
        return unavailableResult(taskID: taskID, status: .needsDecision)
    }

    func reviewDecision(for taskID: UUID) -> AgentTaskReviewDecision? {
        registry.task(for: taskID).flatMap(AgentTaskReviewOrchestrator.decisionRequest(for:))
    }

    // MARK: - Real identity and executor ports

    private func noteChecks(_ observation: AgentTaskCheckObservation) {
        checks[observation.taskID] = observation
    }

    private func grantIsCurrent(
        _ task: AgentTask, plan: AgentTaskCheckPlan
    ) async -> Bool {
        guard let snapshot = probes[task.id] else { return false }
        return await registry.persistedCheckGrantIsCurrent(
            taskID: task.id, plan: plan, environment: snapshot.environment
        )
    }

    private func probe(
        _ task: AgentTask, plan: AgentTaskCheckPlan,
        binding: AgentTaskEnvironmentBinding
    ) async -> AgentVerificationIdentitySnapshot? {
        guard binding.taskID == task.id, binding.identity == task.project else {
            probes.removeValue(forKey: task.id)
            return nil
        }
        do {
            let lease = try await bindings.revalidate(binding)
            let capture = AgentVerificationIdentityCapture(
                inputs: AgentVerificationIdentityCapture.Inputs(
                    lease: lease, policy: plan.capturePolicy, editor: editor(),
                    tools: Array(Set(plan.commands.map(\.executable))),
                    configurationFiles: plan.configurationFiles.sorted().map {
                        lease.canonicalWorktree.appending(path: $0)
                    }
                ),
                cancellation: GitCommandCancellationToken()
            )
            guard case .current(let snapshot) = await capture.capture() else {
                probes.removeValue(forKey: task.id)
                return nil
            }
            probes[task.id] = snapshot
            return snapshot
        } catch {
            probes.removeValue(forKey: task.id)
            return nil
        }
    }

    // MARK: - Durable review dispatch

    private func review(
        _ request: AgentTaskVerificationReviewRequest, plan: AgentTaskCheckPlan,
        binding: AgentTaskEnvironmentBinding
    ) async throws -> AgentTaskReviewObservation {
        guard let original = registry.task(for: request.taskID),
              let run = original.runs.last, run.id == request.runID else {
            throw AgentTaskVerificationServiceError.unavailable
        }
        var current = original
        if let cycle = current.reviewCycle {
            reviewCycles[request.taskID] = cycle.id
            if !liveReviewCycles.contains(cycle.id),
               cycle.pendingReviewOperation != nil || cycle.state == .reserved {
                guard let updated = registry.task(for: request.taskID),
                      await registry.persistReviewTransition(
                        expected: updated,
                        mutate: { task -> Bool in
                            _ = AgentTaskReviewOrchestrator.reconcileRestoredCycle(task: &task)
                            return true
                        }
                      ) == true,
                      let reconciled = registry.task(for: request.taskID) else {
                    throw AgentTaskVerificationServiceError.unavailable
                }
                current = reconciled
            }
            liveReviewCycles.insert(cycle.id)
        }
        if current.reviewCycle?.state == .needsDecision {
            // Verify never buys another correction budget. A new budget belongs
            // to a separately defined user continuation/new attempt.
            throw AgentTaskVerificationServiceError.invalidReview
        }
        if current.reviewCycle == nil
            || [.finished, .cancelled].contains(current.reviewCycle?.state) {
            let reviewPlan = AgentTaskReviewPlan(
                requestedOutcomeReference: AgentHistoryContentHash.sha256Hex(
                    Data((current.objective ?? current.title ?? "Task result").utf8)
                ),
                criteriaVersion: request.criteriaDigest,
                checkPlanIdentity: plan.fingerprint,
                reviewerControl: reviewer.reviewerControl
            )
            let cycleID: UUID? = await registry.persistReviewTransition(
                expected: current,
                mutate: { task -> UUID? in
                    guard AgentTaskReviewOrchestrator.beginCycle(
                        task: &task, plan: reviewPlan,
                        codeState: request.expected.code, environment: request.expected.environment
                    ) else { return nil }
                    return task.reviewCycle?.id
                }
            )
            guard let cycleID, let updated = registry.task(for: request.taskID) else {
                throw AgentTaskVerificationServiceError.unavailable
            }
            current = updated
            reviewCycles[request.taskID] = cycleID
            liveReviewCycles.insert(cycleID)
        }
        guard let cycle = current.reviewCycle,
              cycle.runID == request.runID, cycle.codeState == request.expected.code,
              cycle.environment == request.expected.environment,
              cycle.criteriaVersion == request.criteriaDigest,
              cycle.checkPlanIdentity == plan.fingerprint,
              cycle.state == .awaitingFeedback else {
            throw AgentTaskVerificationServiceError.invalidReview
        }
        guard let observedChecks = checks[request.taskID],
              observedChecks.passID == request.passID,
              observedChecks.isJudgment, observedChecks.requiredSucceeded,
              observedChecks.preCodeState == request.expected.code,
              observedChecks.postCodeState == request.expected.code,
              observedChecks.environment == request.expected.environment else {
            throw AgentTaskVerificationServiceError.invalidReview
        }
        let reviewStart = AgentTaskReviewStart(
            task: current, cycleID: cycle.id, request: request,
            checks: observedChecks, binding: binding, bindings: bindings
        )
        // An existing driver session is reused; after restoration this explicit
        // action must re-establish the exact persisted reviewer identity.
        let identity = try await reviewer.startReviewer(reviewStart)
        guard identity != run.vendorIdentity else {
            throw AgentTaskVerificationServiceError.invalidReview
        }
        if let boundIdentity = cycle.reviewerSession, boundIdentity != identity {
            await escalate(taskID: request.taskID, blocker: .deliveryUnknown)
            throw AgentTaskVerificationServiceError.invalidReview
        }
        guard let updated = registry.task(for: request.taskID),
              await registry.persistReviewTransition(expected: updated, mutate: { task in
                  AgentTaskReviewOrchestrator.bindReviewerSession(task: &task, identity)
              }) == true,
              let bound = registry.task(for: request.taskID) else {
            throw AgentTaskVerificationServiceError.unavailable
        }
        current = bound
        guard let dispatch = await registry.persistReviewTransition(expected: current, mutate: { task in
            AgentTaskReviewOrchestrator.issueReviewDispatch(task: &task)
        }) else {
            throw AgentTaskVerificationServiceError.unavailable
        }
        let authority = AgentTaskReviewAuthority()
        guard registry.registerReviewAuthority(authority, scope: AgentTaskReviewScope(
            passID: request.passID, taskID: request.taskID,
            runID: request.runID, processGeneration: run.process.processGeneration,
            cycleID: dispatch.cycleID, operationID: dispatch.operationID
        )) else {
            throw AgentTaskVerificationServiceError.unavailable
        }
        defer { registry.unregisterReviewAuthority(authority) }
        let reviewed: AgentAdapterReviewResult
        do {
            reviewed = try await withTaskCancellationHandler {
                try await reviewer.rebindReviewer(reviewStart)
                try authority.check()
                return try await reviewer.review(
                    dispatch: dispatch, criteria: request.criteria,
                    beforeDispatch: { try authority.check() }
                )
            } onCancel: {
                authority.revoke()
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                await requestReviewCancellation(taskID: request.taskID)
            } else {
                // The request may have reached the provider. Never clear this
                // reservation and silently resend it on the next Verify.
                await escalate(taskID: request.taskID, blocker: .deliveryUnknown)
            }
            throw error
        }
        let findingReference = reviewed.finding.map { finding in
            var hash = AgentVerificationCanonicalHasher(domain: "pine.ade.review-feedback.v1")
            hash.append("finding", finding)
            let code = request.expected.code
            hash.append("head", code.headCommit ?? "")
            hash.append("tracked", code.trackedFingerprint)
            hash.append("untracked", code.untrackedFingerprint)
            hash.append("ignored", code.ignoredRelevantFingerprint)
            return hash.finish()
        }
        if let finding = reviewed.finding, let findingReference {
            findings[request.taskID, default: [:]][findingReference] = finding
        }
        let post = await probe(current, plan: plan, binding: binding)
        guard let reviewerSession = current.reviewCycle?.reviewerSession else {
            throw AgentTaskVerificationServiceError.invalidReview
        }
        let answeringIdentity: AgentVendorSessionIdentity
        do {
            answeringIdentity = try await reviewer.reviewerIdentity(cycleID: dispatch.cycleID)
        } catch {
            if Task.isCancelled || error is CancellationError {
                await requestReviewCancellation(taskID: request.taskID)
            } else {
                await escalate(taskID: request.taskID, blocker: .infrastructureFailure)
            }
            throw error
        }
        guard answeringIdentity == reviewerSession else {
            if Task.isCancelled {
                await requestReviewCancellation(taskID: request.taskID)
            } else {
                await escalate(taskID: request.taskID, blocker: .infrastructureFailure)
            }
            throw AgentTaskVerificationServiceError.invalidReview
        }
        let event = AgentTaskReviewOutcomeEvent(
            operationID: dispatch.operationID, reviewerSession: reviewerSession,
            passed: reviewed.outcome == .passed, feedbackReference: findingReference,
            codeState: request.expected.code, preCodeState: request.expected.code,
            postCodeState: post?.code, environment: request.expected.environment,
            observedAt: Date()
        )
        do {
            try authority.check()
        } catch {
            if Task.isCancelled {
                await requestReviewCancellation(taskID: request.taskID)
            } else {
                await escalate(taskID: request.taskID, blocker: .deliveryUnknown)
            }
            throw error
        }
        guard let afterReview = registry.task(for: request.taskID),
              let admission = await registry.persistReviewTransition(
                  expected: afterReview, authority: authority, mutate: { task in
                      AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task, event)
                  }
              ) else {
            await escalate(taskID: request.taskID, blocker: .infrastructureFailure)
            throw AgentTaskVerificationServiceError.unavailable
        }
        switch admission {
        case .accepted:
            return AgentTaskReviewObservation(
                taskID: request.taskID, runID: request.runID, passID: request.passID,
                reviewerSession: event.reviewerSession, criteriaDigest: request.criteriaDigest,
                outcome: reviewed.outcome == .passed ? .passed : .requestedChanges,
                preCodeState: event.preCodeState, postCodeState: event.postCodeState,
                environment: event.environment
            )
        case .fenced, .blocked:
            await escalate(taskID: request.taskID, blocker: .infrastructureFailure)
            throw AgentTaskVerificationServiceError.invalidReview
        }
    }

    private func requestReviewCancellation(taskID: UUID) async {
        guard let current = registry.task(for: taskID) else { return }
        _ = await registry.persistReviewTransition(
            expected: current, allowsCancellation: true, mutate: { task in
                AgentTaskReviewOrchestrator.requestCancellation(task: &task)
            }
        )
    }

    private func confirmReviewCancellation(taskID: UUID) async {
        guard let current = registry.task(for: taskID),
              current.reviewCycle?.state == .cancellationRequested else { return }
        _ = await registry.persistReviewTransition(
            expected: current, allowsCancellation: true, mutate: { task in
                AgentTaskReviewOrchestrator.confirmCancellation(task: &task)
            }
        )
    }

    private func escalate(taskID: UUID, blocker: AgentTaskCorrectionCycle.Blocker) async {
        guard let current = registry.task(for: taskID) else { return }
        _ = await registry.persistReviewTransition(expected: current, mutate: { task in
            guard var cycle = task.reviewCycle else { return false }
            cycle.stop(blocker)
            task.reviewCycle = cycle
            return true
        })
    }

    private func decisionResult(
        _ decision: AgentTaskReviewDecision, fallback: AgentTaskVerificationResult
    ) -> AgentTaskVerificationResult {
        AgentTaskVerificationResult(
            status: .needsDecision,
            readiness: registry.readiness(
                for: decision.taskID, codeState: decision.candidateCodeState,
                environment: decision.candidateEnvironment
            ),
            reason: fallback.reason ?? .reviewFailed,
            requiredAction: .resolveReviewFindings
        )
    }

    private func unavailableResult(
        taskID: UUID, status: AgentTaskVerificationResult.Status
    ) -> AgentTaskVerificationResult {
        AgentTaskVerificationResult(
            status: status, readiness: registry.readiness(
                for: taskID, codeState: nil, environment: nil
            ), reason: nil, requiredAction: nil
        )
    }
}
