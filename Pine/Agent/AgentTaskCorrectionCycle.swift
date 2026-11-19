//
//  AgentTaskCorrectionCycle.swift
//  Pine
//
//  Durable review-cycle bookkeeping for bounded corrections (#1755).
//

import Foundation

/// The declared control boundary of a reviewer adapter, pinned at cycle
/// creation.
///
/// Only an enforced write-disabled control proves non-writing review. A
/// separate session, a read-only prompt, same-user cwd/worktree isolation, or
/// equal before/after fingerprints do not: a reviewer that mutates and then
/// restores leaves the content unchanged, so hash equality is a mutation
/// detector, never a substitute for an enforced boundary. Unknown future
/// values fail closed to `.unspecified`.
nonisolated enum AgentTaskReviewerControl: String, Codable, Sendable, Equatable {
    /// The adapter denies writes at its whole tool boundary: shell,
    /// filesystem tools, MCP, hooks, plugins, and children all run under a
    /// write-disabled profile.
    case writeDisabledAtAdapter
    /// The host enforces a read-only execution boundary on the reviewer
    /// process, separate from same-user cwd isolation.
    case hostEnforcedReadOnly
    /// The reviewer promises not to write in its prompt. Not enforced.
    case promptOnly
    /// Same-user cwd/worktree separation. Not a hostile-process sandbox.
    case cwdIsolation
    /// Unspecified or a future value this build cannot interpret. Never
    /// proves non-writing review.
    case unspecified

    /// Whether this control alone proves the reviewer cannot write to the
    /// candidate through any enabled route.
    var provesNonWritingReview: Bool {
        switch self {
        case .writeDisabledAtAdapter, .hostEnforcedReadOnly:
            return true
        case .promptOnly, .cwdIsolation, .unspecified:
            return false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unspecified
    }
}

/// Durable bookkeeping for one review cycle: the pinned candidate
/// generation, the round count, the in-flight operation and feedback
/// identity, and the terminal/escalation state.
///
/// Bookkeeping only — never reviewer evidence, read-only authority, or a
/// dispatch grant. The initial review is round zero; rounds 1–3 are
/// implementer revisions returned for re-review; an unresolved round 3
/// escalates to a decision BEFORE any fourth automatic correction. A
/// dispatch is reserved and persisted in this journal before the provider
/// bridge sends work, and restoration never resends what it cannot establish
/// was delivered.
nonisolated struct AgentTaskCorrectionCycle: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case awaitingFeedback
        case reserved
        case needsDecision
        case cancellationRequested
        case cancelled
        case finished
    }

    enum Blocker: String, Codable, Sendable {
        case correctionLimit
        case deliveryUnknown
        case infrastructureFailure
        case checksFailed
        case reviewerBoundaryUnavailable
    }

    struct Reservation: Codable, Equatable, Sendable {
        let operationID: UUID
        let feedback: AgentTaskFeedbackRecord
    }

    /// Accepted review verdicts, one dedupe key per review operation: the
    /// bound. (A replayed rejected verdict whose reference was already
    /// consumed reserves nothing but still records its key, so the count
    /// is NOT one-per-round — only the round count is.)
    static let maximumEventKeys = 4
    static let maximumIdentityBytes = 64

    let id: UUID
    let taskID: UUID
    let runID: UUID
    private(set) var codeState: AgentTaskCodeStateIdentity
    private(set) var environment: AgentTaskEnvironmentIdentity
    /// Bounded redacted references pinned at creation; never text.
    let requestedOutcomeReference: String
    let criteriaVersion: String
    let checkPlanIdentity: String
    let reviewerControl: AgentTaskReviewerControl
    /// The owning structured reviewer session, bound exactly once by Pine.
    private(set) var reviewerSession: AgentVendorSessionIdentity?
    private(set) var state: State = .awaitingFeedback
    private(set) var blocker: Blocker?
    /// The in-flight review dispatch; `nil` when no review is outstanding.
    private(set) var pendingReviewOperation: UUID?
    /// The in-flight correction dispatch (reserved; possibly undelivered).
    private(set) var pending: Reservation?
    /// Completed corrections in return order; its count is the round.
    private(set) var returned: [Reservation] = []
    /// Operation keys of accepted review verdicts, for duplicate fencing.
    private(set) var reviewEventKeys: [String] = []
    /// The last accepted rejected verdict's finding reference, so an
    /// escalation decision names the specific unresolved finding.
    private(set) var lastRejectedReference: String?

    /// Initial review is round zero; a reservation does not consume a round.
    var round: Int { returned.count }

    init(
        taskID: UUID,
        runID: UUID,
        codeState: AgentTaskCodeStateIdentity,
        environment: AgentTaskEnvironmentIdentity,
        requestedOutcomeReference: String,
        criteriaVersion: String,
        checkPlanIdentity: String,
        reviewerControl: AgentTaskReviewerControl
    ) {
        id = UUID()
        self.taskID = taskID
        self.runID = runID
        self.codeState = codeState
        self.environment = environment
        self.requestedOutcomeReference = requestedOutcomeReference
        self.criteriaVersion = criteriaVersion
        self.checkPlanIdentity = checkPlanIdentity
        self.reviewerControl = reviewerControl
    }

    // MARK: - Transitions

    /// Pine binds the reviewer session it created, exactly once. A
    /// reconnect with the same identity is idempotent; a different one is
    /// rejected. A terminal cycle binds nothing.
    @discardableResult
    mutating func bindReviewerSession(
        _ session: AgentVendorSessionIdentity
    ) -> Bool {
        guard state != .cancelled, state != .finished else { return false }
        if let bound = reviewerSession {
            return bound == session
        }
        reviewerSession = session
        return true
    }

    /// Reserves the in-flight review dispatch. At most one review is
    /// outstanding at a time, only while awaiting feedback, and only for a
    /// bound reviewer session.
    @discardableResult
    mutating func reserveReviewOperation() -> UUID? {
        guard state == .awaitingFeedback,
              reviewerSession != nil,
              pendingReviewOperation == nil else {
            return nil
        }
        let operation = UUID()
        pendingReviewOperation = operation
        return operation
    }

    mutating func completeReviewOperation(_ operation: UUID) {
        guard pendingReviewOperation == operation else { return }
        pendingReviewOperation = nil
    }

    /// Reserves one correction dispatch BEFORE the bridge sends work.
    /// Single-flight: one pending at a time, and a feedback reference or
    /// operation that already returned never consumes another round.
    @discardableResult
    mutating func reserve(
        operationID: UUID, feedback: AgentTaskFeedbackRecord,
        codeState: AgentTaskCodeStateIdentity, environment: AgentTaskEnvironmentIdentity
    ) -> Bool {
        guard state == .awaitingFeedback, pending == nil,
              pendingReviewOperation == nil,
              self.codeState == codeState, self.environment == environment,
              AgentTaskMetadataStore.validCodeState(codeState),
              AgentTaskMetadataStore.validEnvironment(environment),
              feedback.codeState == codeState,
              Self.validFeedback(feedback),
              !returned.contains(where: {
                  $0.feedback.reference == feedback.reference || $0.operationID == operationID
              }) else { return false }
        guard round < 3 else {
            stop(.correctionLimit)
            return false
        }
        pending = Reservation(operationID: operationID, feedback: feedback)
        state = .reserved
        return true
    }

    /// Authenticated implementer return, not successful checks or review.
    /// The revised candidate must pass fresh checks before another review
    /// result is accepted.
    @discardableResult
    mutating func recordReturn(
        operationID: UUID, codeState: AgentTaskCodeStateIdentity,
        environment: AgentTaskEnvironmentIdentity
    ) -> Bool {
        guard state == .reserved, let pending, pending.operationID == operationID,
              AgentTaskMetadataStore.validCodeState(codeState),
              AgentTaskMetadataStore.validEnvironment(environment) else { return false }
        returned.append(pending)
        self.pending = nil
        self.codeState = codeState
        self.environment = environment
        state = .awaitingFeedback
        return true
    }

    /// No infrastructure or check-only automatic retry path exists in this
    /// journal: a failure that cannot be delivered or resolved escalates to
    /// a decision instead of looping. Escalation never carries an in-flight
    /// operation.
    mutating func stop(_ reason: Blocker) {
        guard state == .awaitingFeedback || state == .reserved else { return }
        guard reason != .correctionLimit || round == 3 else { return }
        blocker = reason
        pendingReviewOperation = nil
        state = .needsDecision
    }

    /// Explicit user intent: cancel the cycle's sessions. New dispatches
    /// are fenced while requested; the request remains requested until
    /// confirmed or reconciled. The in-flight review marker is released:
    /// while cancellation is requested, every verdict is fenced by state,
    /// so the marker contributes nothing to fencing.
    mutating func requestCancellation() {
        guard state != .cancelled, state != .finished else { return }
        pendingReviewOperation = nil
        state = .cancellationRequested
    }

    /// The bridge must confirm or reconcile BOTH sessions before calling
    /// this.
    mutating func confirmCancellation() {
        guard state == .cancellationRequested else { return }
        pendingReviewOperation = nil
        state = .cancelled
    }

    /// Does not produce evidence or Ready; only closes this budget journal.
    mutating func finish() {
        guard state == .awaitingFeedback, pendingReviewOperation == nil
        else { return }
        state = .finished
    }

    @discardableResult
    mutating func recordReviewEventKey(_ key: String) -> Bool {
        guard reviewEventKeys.count < Self.maximumEventKeys,
              !reviewEventKeys.contains(key) else { return false }
        reviewEventKeys.append(key)
        return true
    }

    /// Records the finding reference of one accepted rejected verdict.
    mutating func recordRejectedReference(_ reference: String) {
        lastRejectedReference = reference
    }

    /// Restoration reconciliation. Starts nothing and resends nothing: a
    /// persisted correction reservation whose delivery and return are both
    /// unestablished becomes a decision; a lost review dispatch releases its
    /// in-flight marker so an explicit re-dispatch can be issued (a late
    /// verdict for the old operation is fenced by operation identity).
    @discardableResult
    mutating func reconcileAfterRelaunch() -> Bool {
        var changed = false
        if state == .reserved {
            stop(.deliveryUnknown)
            changed = true
        }
        if state == .awaitingFeedback, pendingReviewOperation != nil {
            pendingReviewOperation = nil
            changed = true
        }
        return changed
    }

    // MARK: - Validation

    /// Structural invariants, shared by the orchestrator and the
    /// persistence backstop. Text-shape bounds are added by the store.
    func isValid(for task: AgentTask) -> Bool {
        guard taskID == task.id,
              task.runs.contains(where: { $0.id == runID }),
              AgentTaskMetadataStore.validCodeState(codeState),
              AgentTaskMetadataStore.validEnvironment(environment),
              Self.validBoundedText(
                  requestedOutcomeReference,
                  maximum: AgentTaskFeedbackRecord.maximumReferenceBytes
              ),
              Self.validBoundedText(
                  criteriaVersion, maximum: Self.maximumIdentityBytes
              ),
              Self.validBoundedText(
                  checkPlanIdentity, maximum: Self.maximumIdentityBytes
              ),
              returned.count <= 3,
              Set(returned.map(\.operationID)).count == returned.count,
              Set(returned.map { $0.feedback.reference }).count == returned.count,
              returned.allSatisfy({ Self.validFeedback($0.feedback) }),
              reviewEventKeys.count <= Self.maximumEventKeys,
              Set(reviewEventKeys).count == reviewEventKeys.count,
              Self.validRejectedReference(lastRejectedReference),
              validBlocker
        else { return false }
        if let pending {
            guard returned.count < 3,
                  Self.validFeedback(pending.feedback),
                  pending.feedback.codeState == codeState,
                  !returned.contains(where: {
                      $0.operationID == pending.operationID
                          || $0.feedback.reference == pending.feedback.reference
                  }),
                  [.reserved, .needsDecision, .cancellationRequested,
                   .cancelled].contains(state)
            else { return false }
        } else if state == .reserved {
            return false
        }
        if pendingReviewOperation != nil, state != .awaitingFeedback {
            return false
        }
        return blocker != .correctionLimit || round == 3
    }

    private var validBlocker: Bool {
        switch state {
        case .needsDecision: return blocker != nil
        case .cancellationRequested, .cancelled: return true
        case .awaitingFeedback, .reserved, .finished: return blocker == nil
        }
    }

    private static func validRejectedReference(_ value: String?) -> Bool {
        guard let value else { return true }
        return validBoundedText(
            value,
            maximum: AgentTaskFeedbackRecord.maximumReferenceBytes
        )
    }

    private static func validFeedback(_ feedback: AgentTaskFeedbackRecord) -> Bool {
        feedback.scheme == AgentTaskFeedbackRecord.currentScheme
            && !feedback.reference.isEmpty
            && feedback.reference.utf8.count <= AgentTaskFeedbackRecord.maximumReferenceBytes
            && !feedback.reference.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && feedback.observedAt.timeIntervalSinceReferenceDate.isFinite
            && feedback.codeState.map(AgentTaskMetadataStore.validCodeState) == true
    }

    /// Bounded reference shape shared by the plan, the journal, and the
    /// orchestrator: non-empty, within the byte bound, no control
    /// characters.
    static func validBoundedText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
