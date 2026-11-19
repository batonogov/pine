//
//  AgentTaskReviewOrchestrator.swift
//  Pine
//
//  Independent reviewer orchestration and the bounded correction state
//  machine (#1755).
//
//  This is a pure, deterministic state machine over the durable task value.
//  The provider bridge (the #1723 owned-session slice) persists the updated
//  task through the existing registry save path BEFORE it sends any work a
//  transition granted. The orchestrator never launches, resends, or retries
//  on its own: a dispatch is a grant, and restoration starts nothing.
//
//  Independence contract (what the controls actually enforce):
//  - The reviewer is a distinct session Pine creates and binds exactly once
//    (``AgentTaskCorrectionCycle/bindReviewerSession(_:)``). A reviewer
//    verdict is accepted only from that owning structured session; an
//    implementer cannot submit its own message as reviewer evidence.
//  - The reviewer's declared control boundary is pinned at cycle creation.
//    Only an enforced write-disabled boundary
//    (``AgentTaskReviewerControl/provesNonWritingReview``) admits a verdict.
//    Prompt-only promises and same-user cwd/worktree isolation are NOT a
//    hostile-process sandbox and never prove non-writing review.
//  - Fingerprints taken before and after the review must both equal the
//    pinned candidate. That is a mutation detector, not the guarantee: a
//    reviewer that mutates then restores is undetectable by hash equality,
//    which is why the enforced control is required and a failed boundary
//    blocks the review claim with a required decision instead of
//    silently downgrading to prompt-only review.
//  - When #1723's owned-session transport lands, the reviewer session is
//    still the only source of admissible verdicts; the produced
//    ``AgentTaskEvidenceFact`` records `vendorSession: nil` because the
//    implementer run's vendor identity is the implementer's, and Pine's
//    structured-session ownership — not a second transcript — is the
//    attribution guarantee.
//

import Foundation

/// Reviewer plan pinned at cycle creation.
///
/// Every component is a bounded redacted reference — never criteria or
/// outcome text, paths, or secrets. The candidate identity is pinned
/// separately from the caller-proven current code state and environment at
/// begin time, so the plan alone cannot move the candidate boundary.
nonisolated struct AgentTaskReviewPlan: Codable, Equatable, Sendable {
    static let maximumReferenceBytes = AgentTaskFeedbackRecord.maximumReferenceBytes
    static let maximumIdentityBytes = AgentTaskCorrectionCycle.maximumIdentityBytes

    let requestedOutcomeReference: String
    let criteriaVersion: String
    let checkPlanIdentity: String
    let reviewerControl: AgentTaskReviewerControl

    init(
        requestedOutcomeReference: String,
        criteriaVersion: String,
        checkPlanIdentity: String,
        reviewerControl: AgentTaskReviewerControl
    ) {
        self.requestedOutcomeReference = requestedOutcomeReference
        self.criteriaVersion = criteriaVersion
        self.checkPlanIdentity = checkPlanIdentity
        self.reviewerControl = reviewerControl
    }

    var isValid: Bool {
        AgentTaskCorrectionCycle.validBoundedText(
            requestedOutcomeReference,
            maximum: Self.maximumReferenceBytes
        ) && AgentTaskCorrectionCycle.validBoundedText(
            criteriaVersion,
            maximum: Self.maximumIdentityBytes
        ) && AgentTaskCorrectionCycle.validBoundedText(
            checkPlanIdentity,
            maximum: Self.maximumIdentityBytes
        )
    }
}

/// One review dispatch: the full pinned review context the bridge sends to
/// a NEW reviewer session. It is a dispatch instruction, never evidence:
/// the verdict must come back from the session Pine bound, with the
/// candidate unchanged.
nonisolated struct AgentTaskReviewDispatch: Equatable, Sendable {
    let operationID: UUID
    let taskID: UUID
    let runID: UUID
    let cycleID: UUID
    let codeState: AgentTaskCodeStateIdentity
    let environment: AgentTaskEnvironmentIdentity
    let requestedOutcomeReference: String
    let criteriaVersion: String
    let checkPlanIdentity: String
    let reviewerControl: AgentTaskReviewerControl
}

/// One correction dispatch to the correct implementer: the run that
/// produced the pinned candidate. The bridge must verify the run is still
/// the task's current run when it sends, persist the reservation before
/// sending, and never resend on its own.
nonisolated struct AgentTaskCorrectionDispatch: Equatable, Sendable {
    let operationID: UUID
    let taskID: UUID
    let runID: UUID
    let terminalID: UUID
    let cycleID: UUID
    let feedbackReference: String
    let baselineCodeState: AgentTaskCodeStateIdentity
}

/// A reviewer verdict reported from the owning structured session.
///
/// The session identity, operation identity, and fingerprints are supplied
/// by the bridge from the session Pine owns; the implementer's terminal
/// cannot fabricate them. `preCodeState`/`postCodeState` are the candidate
/// fingerprints observed at review start and end.
nonisolated struct AgentTaskReviewOutcomeEvent: Equatable, Sendable {
    let operationID: UUID
    let reviewerSession: AgentVendorSessionIdentity
    let passed: Bool
    /// Bounded redacted finding reference; required when `passed` is false.
    let feedbackReference: String?
    let codeState: AgentTaskCodeStateIdentity
    let preCodeState: AgentTaskCodeStateIdentity?
    let postCodeState: AgentTaskCodeStateIdentity?
    let environment: AgentTaskEnvironmentIdentity
    let observedAt: Date
    let sourceSequence: UInt64?

    init(
        operationID: UUID,
        reviewerSession: AgentVendorSessionIdentity,
        passed: Bool,
        feedbackReference: String?,
        codeState: AgentTaskCodeStateIdentity,
        preCodeState: AgentTaskCodeStateIdentity?,
        postCodeState: AgentTaskCodeStateIdentity?,
        environment: AgentTaskEnvironmentIdentity,
        observedAt: Date,
        sourceSequence: UInt64? = nil
    ) {
        self.operationID = operationID
        self.reviewerSession = reviewerSession
        self.passed = passed
        self.feedbackReference = feedbackReference
        self.codeState = codeState
        self.preCodeState = preCodeState
        self.postCodeState = postCodeState
        self.environment = environment
        self.observedAt = observedAt
        self.sourceSequence = sourceSequence
    }
}

/// Why a reviewer verdict was fenced out.
nonisolated enum AgentTaskReviewFence: String, Equatable, Sendable {
    /// The task carries no review cycle.
    case noCycle
    /// The cycle belongs to another task or names a run the task lacks.
    case wrongTask
    /// The cycle is not awaiting feedback (in flight, escalated, or
    /// cancelled).
    case wrongState
    /// No reviewer session is bound to the cycle.
    case unboundReviewerSession
    /// The event's session is not the bound reviewer session.
    case foreignReviewerSession
    /// The event's session is the implementer's: an implementer cannot
    /// submit its own message as reviewer evidence.
    case implementerSession
    /// The event names a review operation that is not the in-flight one.
    case staleReviewOperation
    /// The verdict is bound to a different candidate or environment than
    /// the cycle's pinned generation.
    case staleCandidate
    /// A verdict with no usable finding reference.
    case invalidFeedback
    /// A re-review pass (round > 0) without a current passing required
    /// check bound to the revised candidate.
    case checksNotCurrent
    /// The same review verdict was already accepted.
    case duplicate
}

/// The outcome of accepting one reviewer verdict.
nonisolated enum AgentTaskReviewAdmission: Equatable, Sendable {
    /// The verdict is accepted. `evidence` is the reviewer-outcome fact the
    /// bridge records through the registry's existing evidence path;
    /// `dispatch` (a requested-changes verdict with budget left) is the
    /// correction to route to the implementer; `decision` (an escalated
    /// cycle) is the actionable attention.
    case accepted(
        evidence: AgentTaskEvidenceFact,
        dispatch: AgentTaskCorrectionDispatch?,
        decision: AgentTaskReviewDecision?
    )
    case fenced(AgentTaskReviewFence)
    /// The declared control boundary is not enforced, or the candidate was
    /// mutated during review: the review claim is blocked with a required
    /// decision, never silently downgraded.
    case blocked(AgentTaskCorrectionCycle.Blocker)
}

/// An actionable escalation: the specific unresolved blocker, the round it
/// was reached at, the finding it names when one exists, and the preserved
/// candidate.
nonisolated struct AgentTaskReviewDecision: Equatable, Sendable {
    let cycleID: UUID
    let taskID: UUID
    let runID: UUID
    let blocker: AgentTaskCorrectionCycle.Blocker
    let round: Int
    let unresolvedFindingReference: String?
    let candidateCodeState: AgentTaskCodeStateIdentity
    let candidateEnvironment: AgentTaskEnvironmentIdentity
}

/// Pure state machine for independent review and bounded correction
/// (#1755). See the file header for the independence contract.
nonisolated enum AgentTaskReviewOrchestrator {
    // MARK: - Explicit user intent

    /// Explicit user intent: create (or, after escalation, replace) the
    /// task's review cycle.
    ///
    /// This is the ONLY API that creates a cycle, so automatic feedback,
    /// replay, reconnect, and restoration cannot reset the correction
    /// budget. A plan whose declared control cannot prove non-writing
    /// review escalates to a required decision instead of downgrading to
    /// prompt-only review. A re-begin is refused while the outgoing cycle
    /// carries in-flight work (a reserved correction that may already be
    /// delivered, or an outstanding review dispatch): that journal is
    /// reconciled or cancelled first, never silently discarded.
    @discardableResult
    static func beginCycle(
        task: inout AgentTask,
        plan: AgentTaskReviewPlan,
        codeState: AgentTaskCodeStateIdentity,
        environment: AgentTaskEnvironmentIdentity
    ) -> Bool {
        guard plan.isValid,
              let run = task.runs.last,
              task.reviewCycle.map({
                  $0.pending == nil && $0.pendingReviewOperation == nil
              }) ?? true,
              AgentTaskMetadataStore.validCodeState(codeState),
              AgentTaskMetadataStore.validEnvironment(environment) else {
            return false
        }
        var cycle = AgentTaskCorrectionCycle(
            taskID: task.id,
            runID: run.id,
            codeState: codeState,
            environment: environment,
            requestedOutcomeReference: plan.requestedOutcomeReference,
            criteriaVersion: plan.criteriaVersion,
            checkPlanIdentity: plan.checkPlanIdentity,
            reviewerControl: plan.reviewerControl
        )
        if !plan.reviewerControl.provesNonWritingReview {
            cycle.stop(.reviewerBoundaryUnavailable)
        }
        task.reviewCycle = cycle
        return true
    }

    // MARK: - Reviewer session

    /// Binds the reviewer session Pine created, exactly once. A reconnect
    /// with the same identity is idempotent; a different identity is
    /// rejected.
    @discardableResult
    static func bindReviewerSession(
        task: inout AgentTask,
        _ session: AgentVendorSessionIdentity
    ) -> Bool {
        guard var cycle = task.reviewCycle else { return false }
        let bound = cycle.bindReviewerSession(session)
        if bound {
            task.reviewCycle = cycle
        }
        return bound
    }

    // MARK: - Review dispatch

    /// Issues one in-flight review dispatch, granting the full pinned review
    /// context. The bridge creates the reviewer session, binds it
    /// (``bindReviewerSession(task:_:)``), and sends the context; the
    /// verdict must return from that session, never from the implementer.
    static func issueReviewDispatch(
        task: inout AgentTask
    ) -> AgentTaskReviewDispatch? {
        guard var cycle = task.reviewCycle,
              let operation = cycle.reserveReviewOperation() else {
            return nil
        }
        task.reviewCycle = cycle
        return AgentTaskReviewDispatch(
            operationID: operation,
            taskID: cycle.taskID,
            runID: cycle.runID,
            cycleID: cycle.id,
            codeState: cycle.codeState,
            environment: cycle.environment,
            requestedOutcomeReference: cycle.requestedOutcomeReference,
            criteriaVersion: cycle.criteriaVersion,
            checkPlanIdentity: cycle.checkPlanIdentity,
            reviewerControl: cycle.reviewerControl
        )
    }

    // MARK: - Reviewer verdict

    /// Accepts one reviewer verdict, fenced on task, run, cycle state,
    /// session identity, review operation, candidate identity, the
    /// mutation boundary, duplicate delivery, and (for a corrected
    /// candidate) current passing checks.
    static func acceptReviewerOutcome(
        task: inout AgentTask,
        _ event: AgentTaskReviewOutcomeEvent
    ) -> AgentTaskReviewAdmission {
        guard var cycle = task.reviewCycle else {
            return .fenced(.noCycle)
        }
        guard cycle.taskID == task.id,
              let run = task.runs.first(where: { $0.id == cycle.runID })
        else {
            return .fenced(.wrongTask)
        }
        guard cycle.state == .awaitingFeedback else {
            return .fenced(.wrongState)
        }
        guard let boundSession = cycle.reviewerSession else {
            return .fenced(.unboundReviewerSession)
        }
        guard event.reviewerSession == boundSession else {
            return .fenced(.foreignReviewerSession)
        }
        if let implementer = run.vendorIdentity,
           event.reviewerSession == implementer {
            return .fenced(.implementerSession)
        }
        guard cycle.reviewerControl.provesNonWritingReview else {
            // Backstop: an unenforceable control never admits a verdict,
            // even one with perfect fingerprints.
            cycle.stop(.reviewerBoundaryUnavailable)
            task.reviewCycle = cycle
            return .blocked(.reviewerBoundaryUnavailable)
        }
        guard event.operationID == cycle.pendingReviewOperation else {
            return .fenced(.staleReviewOperation)
        }
        guard event.codeState == cycle.codeState,
              event.environment == cycle.environment else {
            return .fenced(.staleCandidate)
        }
        // Mutation boundary: the fingerprints at review start and end must
        // both equal the pinned candidate. A successful write through any
        // enabled route (shell, filesystem tool, MCP, hook, plugin, or
        // child) is a control failure: block the review claim.
        guard let pre = event.preCodeState,
              let post = event.postCodeState,
              pre == post,
              pre == cycle.codeState else {
            cycle.stop(.reviewerBoundaryUnavailable)
            task.reviewCycle = cycle
            return .blocked(.reviewerBoundaryUnavailable)
        }
        let key = event.operationID.uuidString
        guard !cycle.reviewEventKeys.contains(key) else {
            return .fenced(.duplicate)
        }
        var findingReference: String?
        if !event.passed {
            guard let reference = event.feedbackReference,
                  AgentTaskCorrectionCycle.validBoundedText(
                      reference,
                      maximum: AgentTaskReviewPlan.maximumReferenceBytes
                  ) else {
                return .fenced(.invalidFeedback)
            }
            findingReference = reference
        }
        // A re-review of a corrected candidate (round > 0) is not accepted
        // until a current passing required check is bound to the revised
        // candidate. The identity is the freshness proof: a check cannot be
        // bound to a state that did not yet exist.
        if event.passed, cycle.round > 0 {
            guard task.evidence.contains(where: { fact in
                fact.kind == .independentCheck
                    && fact.kind.isPassing(fact.result)
                    && fact.codeState == cycle.codeState
                    && fact.environment == cycle.environment
            }) else {
                return .fenced(.checksNotCurrent)
            }
        }
        // Every fence passed: record the verdict and advance the journal.
        _ = cycle.recordReviewEventKey(key)
        cycle.completeReviewOperation(event.operationID)
        let fact = AgentTaskEvidenceFact(
            kind: .reviewerOutcome,
            runID: cycle.runID,
            processGeneration: run.process.processGeneration,
            trust: .verified,
            result: event.passed ? .succeeded : .requestedChanges,
            observedAt: event.observedAt,
            codeState: cycle.codeState,
            environment: cycle.environment,
            vendorSession: nil,
            sourceSequence: event.sourceSequence,
            preOperationCodeState: pre,
            postOperationCodeState: post
        )
        var dispatch: AgentTaskCorrectionDispatch?
        var decision: AgentTaskReviewDecision?
        if event.passed {
            cycle.finish()
        } else {
            guard let reference = findingReference else {
                return .fenced(.invalidFeedback)
            }
            cycle.recordRejectedReference(reference)
            let feedback = AgentTaskFeedbackRecord(
                reference: reference,
                observedAt: event.observedAt,
                codeState: cycle.codeState
            )
            let operation = UUID()
            if cycle.reserve(
                operationID: operation,
                feedback: feedback,
                codeState: cycle.codeState,
                environment: cycle.environment
            ) {
                dispatch = AgentTaskCorrectionDispatch(
                    operationID: operation,
                    taskID: cycle.taskID,
                    runID: cycle.runID,
                    terminalID: run.terminalID,
                    cycleID: cycle.id,
                    feedbackReference: reference,
                    baselineCodeState: cycle.codeState
                )
            } else if cycle.state == .needsDecision {
                decision = Self.decisionRequest(for: cycle)
            }
        }
        task.reviewCycle = cycle
        return .accepted(evidence: fact, dispatch: dispatch, decision: decision)
    }

    // MARK: - Implementer return

    /// Authenticated implementer return for a reserved correction: the
    /// revised candidate identity. A return is not evidence of passing
    /// checks or review; the required checks must pass against the revised
    /// candidate before its review result is accepted.
    @discardableResult
    static func recordImplementerReturn(
        task: inout AgentTask,
        operationID: UUID,
        codeState: AgentTaskCodeStateIdentity,
        environment: AgentTaskEnvironmentIdentity
    ) -> Bool {
        guard var cycle = task.reviewCycle else { return false }
        let returned = cycle.recordReturn(
            operationID: operationID,
            codeState: codeState,
            environment: environment
        )
        if returned {
            task.reviewCycle = cycle
        }
        return returned
    }

    // MARK: - Failed required checks

    /// Routes a failed required check for the current candidate back to the
    /// implementer through the SAME bounded correction budget as review
    /// findings: one reservation, one round, no separate check-repair loop.
    /// A passing check records no dispatch here; its fact belongs to the
    /// check executor's existing evidence path.
    static func routeFailedCheck(
        task: inout AgentTask,
        reference: String,
        codeState: AgentTaskCodeStateIdentity,
        environment: AgentTaskEnvironmentIdentity,
        at observedAt: Date = Date()
    ) -> AgentTaskCorrectionDispatch? {
        guard var cycle = task.reviewCycle,
              let run = task.runs.first(where: { $0.id == cycle.runID }),
              cycle.state == .awaitingFeedback,
              cycle.codeState == codeState,
              cycle.environment == environment,
              AgentTaskCorrectionCycle.validBoundedText(
                  reference,
                  maximum: AgentTaskReviewPlan.maximumReferenceBytes
              ) else {
            return nil
        }
        let feedback = AgentTaskFeedbackRecord(
            reference: reference,
            observedAt: observedAt,
            codeState: codeState
        )
        let operation = UUID()
        guard cycle.reserve(
            operationID: operation,
            feedback: feedback,
            codeState: codeState,
            environment: environment
        ) else {
            // The reservation may have escalated the limit: persist it.
            task.reviewCycle = cycle
            return nil
        }
        task.reviewCycle = cycle
        return AgentTaskCorrectionDispatch(
            operationID: operation,
            taskID: cycle.taskID,
            runID: cycle.runID,
            terminalID: run.terminalID,
            cycleID: cycle.id,
            feedbackReference: reference,
            baselineCodeState: codeState
        )
    }

    // MARK: - Cancellation

    /// Explicit user intent: request cancellation of the cycle's sessions.
    /// New dispatches are fenced while requested; the request remains
    /// requested until the bridge confirms or reconciles it per the
    /// provider contract. Returns whether THIS call transitioned the cycle:
    /// a repeated request on an already-requested (or terminal) cycle is a
    /// no-op that returns false.
    @discardableResult
    static func requestCancellation(task: inout AgentTask) -> Bool {
        guard var cycle = task.reviewCycle else { return false }
        let wasRequested = cycle.state == .cancellationRequested
        cycle.requestCancellation()
        let didTransition = cycle.state == .cancellationRequested && !wasRequested
        if didTransition {
            task.reviewCycle = cycle
        }
        return didTransition
    }

    /// The bridge has confirmed or reconciled BOTH sessions.
    ///
    /// Returns whether THIS call transitioned the cycle: a confirm on a
    /// non-requested state (already cancelled, finished, or never
    /// requested) is a no-op that returns false.
    @discardableResult
    static func confirmCancellation(task: inout AgentTask) -> Bool {
        guard var cycle = task.reviewCycle else { return false }
        let wasRequested = cycle.state == .cancellationRequested
        cycle.confirmCancellation()
        let didTransition = wasRequested && cycle.state == .cancelled
        if didTransition {
            task.reviewCycle = cycle
        }
        return didTransition
    }

    // MARK: - Restoration

    /// Reconciles a restored cycle. Starts nothing and resends nothing: a
    /// persisted correction reservation whose delivery is unestablished
    /// escalates to a `.deliveryUnknown` decision; a lost review dispatch
    /// releases its in-flight marker so an explicit re-dispatch can be
    /// issued, and a late verdict for the old operation is fenced.
    static func reconcileRestoredCycle(
        task: inout AgentTask
    ) -> AgentTaskReviewDecision? {
        guard var cycle = task.reviewCycle,
              cycle.reconcileAfterRelaunch() else {
            return nil
        }
        task.reviewCycle = cycle
        return cycle.state == .needsDecision
            ? Self.decisionRequest(for: cycle)
            : nil
    }

    // MARK: - Projection

    /// The actionable decision when the cycle is escalated, else nil.
    /// Intermediate review, check, and correction activity never produces
    /// one.
    static func decisionRequest(for task: AgentTask) -> AgentTaskReviewDecision? {
        guard let cycle = task.reviewCycle else { return nil }
        return decisionRequest(for: cycle)
    }

    static func decisionRequest(
        for cycle: AgentTaskCorrectionCycle
    ) -> AgentTaskReviewDecision? {
        guard cycle.state == .needsDecision, let blocker = cycle.blocker
        else { return nil }
        // The in-flight reservation (possibly undelivered) names the
        // newest actionable feedback; otherwise the last rejected verdict's
        // finding; otherwise the last returned correction.
        let finding = cycle.pending?.feedback.reference
            ?? cycle.lastRejectedReference
            ?? cycle.returned.last?.feedback.reference
        return AgentTaskReviewDecision(
            cycleID: cycle.id,
            taskID: cycle.taskID,
            runID: cycle.runID,
            blocker: blocker,
            round: cycle.round,
            unresolvedFindingReference: finding,
            candidateCodeState: cycle.codeState,
            candidateEnvironment: cycle.environment
        )
    }

    /// Attention projection: only an actionable needs-decision becomes
    /// waiting input. A valid Ready keeps the existing settlement's
    /// attention, and all intermediate activity produces none.
    static func reviewAttention(for task: AgentTask) -> AgentTaskAttention? {
        task.reviewCycle.map { $0.state } == .needsDecision ? .waitingInput : nil
    }
}
