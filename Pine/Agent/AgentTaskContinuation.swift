//
//  AgentTaskContinuation.swift
//  Pine
//
//  Same-task continuation contract (#1756).
//
//  An explicit user revision continues a Ready or accepted result as a NEW
//  logical attempt of the SAME durable ADE task:
//
//  - The durable task ID, original goal/objective, environment relationship,
//    feedback, and identifiable result history are preserved.
//  - Each submitted revision durably records a new-attempt transition
//    (invalidation of the previous candidate plus a candidate generation)
//    BEFORE any dependent positive evidence or work dispatch is accepted.
//  - The new candidate starts without current verification or acceptance;
//    historical acceptance stays attached to its exact snapshot.
//  - Late events from an old attempt are fenced by the existing evidence
//    fencing keys (attempt identity, process incarnation, provider session
//    reference, source sequence, chronology). A new attempt never fabricates
//    process termination or replacement: on the terminal model it carries a
//    new, truthful process incarnation; the provider-turn/session mapping is
//    the run's own identity (attempt identity ↔ run, process incarnation,
//    vendor session where the adapter states one).
//
//  Provider-process lifetime and logical-attempt lifetime are separate.
//  #1795 (merged before this contract) makes `isSettled` accept logical
//  settlement, so a settled attempt may retain a live provider process.
//  THIS MODEL CONTRACT keys its transitions on the recorded OUTCOME (the
//  logical fact), so a live-but-settled result classifies and submits
//  without fabricated termination; the Ready precondition stays on the
//  existing `AgentTaskLifecycleReducer.readiness` contract, which #1795
//  extends. The REGISTRY layer does not yet do the same:
//  `prepareContinuation` (AgentTaskRegistry.swift:1517) still requires the
//  latest run to be physically non-live and the route missing, and the
//  `.continuation` case of `canAcceptPending` (AgentTaskRegistry.swift:2608)
//  requires a physically terminated previous run with a strictly newer
//  process generation. A same-incarnation live-channel turn also needs a
//  claim shape the PTY-write/new-process model does not provide. The
//  #1811/#1723 adapter integration must revisit both guards before a real
//  provider can continue a live-settled result.
//

import Foundation

/// The origin of a submitted revision (#1756), consuming the #1755 boundary:
///
/// - `explicitUser` revisions may begin a new review cycle: they advance the
///   task's candidate generation.
/// - `automaticReviewer` feedback stays inside the existing bounded
///   correction cycle owned by #1755: it must not advance the cycle, so the
///   continuation path can never reset the correction round limit.
nonisolated enum AgentTaskRevisionOrigin: String, Codable, Sendable {
    case explicitUser
    case automaticReviewer

    /// Unknown future values fail closed to the origin that grants no
    /// cycle-advancing authority.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .automaticReviewer
    }
}

/// One durable record of a submitted revision (#1756).
///
/// The record is the new-attempt transition itself: it durably names the
/// invalidation of the previous candidate and the candidate generation the
/// revision produced, before any dependent positive evidence or work
/// dispatch is accepted. Bounded and content-free: a redacted feedback
/// reference (same policy as ``AgentTaskFeedbackRecord`` — a provider
/// message identifier or a hash, never feedback text, a path, or a secret),
/// the code state the revision pointed at when known, and the origin.
nonisolated struct AgentTaskRevisionRecord: Codable, Hashable, Sendable {
    static let currentScheme: UInt8 = 1

    let scheme: UInt8
    let origin: AgentTaskRevisionOrigin
    let feedbackReference: String
    /// Candidate generation this revision produced. Explicit user revisions
    /// advance it; automatic corrections do not (#1755).
    let candidateGeneration: UInt64
    let observedAt: Date
    /// The code state the revision referred to, or `nil` when unknown.
    let codeState: AgentTaskCodeStateIdentity?

    init(
        origin: AgentTaskRevisionOrigin,
        feedbackReference: String,
        candidateGeneration: UInt64,
        observedAt: Date,
        codeState: AgentTaskCodeStateIdentity? = nil
    ) {
        scheme = Self.currentScheme
        self.origin = origin
        self.feedbackReference = feedbackReference
        self.candidateGeneration = candidateGeneration
        self.observedAt = observedAt
        self.codeState = codeState
    }
}

/// The derived (never stored) continuation state of a task (#1756
/// transition table). Classification keys on the recorded outcome — the
/// logical fact — not physical process termination, so a settled turn on a
/// still-live provider process (#1795 shape) classifies by its outcome.
nonisolated enum AgentTaskContinuationPhase: String, Sendable, Equatable {
    /// No run yet (launch intent only).
    case none
    /// A live provider process with an active, unsettled turn.
    case working
    /// A submitted revision is recorded but its dispatch appended no run
    /// yet: launch/dispatch rejection or uncertain delivery, recoverable by
    /// explicit user action only.
    case revisionPending
    /// A settled turn or result without current verification.
    case settledAwaitingVerification
    /// A current Ready result (success plus current verification).
    case ready
    /// A Ready result with current user acceptance.
    case accepted
    /// The latest settled attempt ended in failure. A FRESH failure (no
    /// pending revision) is not continuable: `submitRevision` refuses
    /// `.notReady`; explicit resume (`prepareResume`) or the next Ready
    /// result is the sanctioned recovery.
    case failed
    /// The latest settled attempt was cancelled. Same recoverable boundary
    /// as `failed`: no new revision from a fresh cancellation; explicit
    /// resume (`prepareResume`) or the next Ready result is the sanctioned
    /// recovery.
    case cancelled
    /// Restored after relaunch with a stale latest run: no current positive
    /// evidence about that attempt.
    case restoredStale
    /// No recorded outcome, or a superseded/contradictory tail.
    case unknown
}

nonisolated enum AgentTaskContinuationRejection: Sendable, Equatable {
    /// The feedback reference is empty, over-bounded, or malformed.
    case invalidReference
    /// Dismissed tasks stay governed by their existing dismissal policy.
    case dismissed
    /// An active turn is in flight: continuation never races a live turn.
    case activeTurn
    /// No current Ready result and no pending revision to re-arm. For a
    /// settled failure or cancellation this is the documented boundary:
    /// explicit resume (`prepareResume`) or the next Ready result is the
    /// sanctioned recovery; a first-class "new feedback from a failed or
    /// cancelled attempt" transition is a #1725 product decision.
    case notReady
    /// The bounded per-task revision history is full.
    case limitReached
}

nonisolated enum AgentTaskContinuationDecision: Sendable, Equatable {
    /// The revision transition was recorded: invalidation, the candidate
    /// generation, and the revision record. The registry's persistence path
    /// makes it disk-durable; dispatch may not be accepted before it.
    case recorded(candidateGeneration: UInt64)
    /// A not-yet-dispatched revision with this exact reference and origin
    /// already exists: the submission is idempotent, no second transition
    /// is recorded, and the caller may re-arm a dispatch.
    case alreadyRecorded(candidateGeneration: UInt64)
    case rejected(AgentTaskContinuationRejection)
}

nonisolated enum AgentTaskContinuation {
    /// Bounded maximum of durable revision records per task. This is the ONE
    /// admission bound, mirrored by the metadata store's persistence
    /// backstop (same pattern as `maxEvidenceFacts`).
    static let maxRevisionRecords =
        AgentTaskPersistenceLimits().maxRevisionRecordsPerTask

    // MARK: - Transition table

    /// Projects the task's continuation phase from its durable state.
    ///
    /// The table: live process with an active turn → `working`; a submitted
    /// revision whose dispatch appended no run → `revisionPending`; a
    /// settled turn without current verification →
    /// `settledAwaitingVerification`; a current Ready result → `ready`;
    /// Ready plus current acceptance → `accepted`; settled failure or
    /// cancellation keeps its distinct honest phase; a stale latest run
    /// after relaunch → `restoredStale`; anything else → `unknown`.
    static func phase(for task: AgentTask) -> AgentTaskContinuationPhase {
        guard let latest = task.runs.last else { return .none }
        if hasActiveTurn(latest) { return .working }
        if latest.liveness == .stale { return .restoredStale }
        switch latest.outcome {
        case .failure:
            return .failed
        case .cancellation:
            return .cancelled
        case .superseded, nil:
            return .unknown
        case .unverified:
            return hasPendingRevision(task)
                ? .revisionPending
                : .settledAwaitingVerification
        case .success:
            guard task.verificationState == .verified else {
                return hasPendingRevision(task)
                    ? .revisionPending
                    : .settledAwaitingVerification
            }
            return task.acceptanceState == .accepted ? .accepted : .ready
        }
    }

    /// A turn is active only while the attempt is logically unsettled.
    ///
    /// Model-contract gate (see the file header for the registry-layer
    /// seam): with #1795's logical-settlement metadata a settled attempt
    /// may retain a live provider process, and this gate keys on the
    /// recorded outcome, so the live-settled shape classifies and submits
    /// here without fabricated termination — while the registry's
    /// physically-terminated guards keep a live-settled run out of the
    /// launch path until the #1811/#1723 integration revisits them.
    static func hasActiveTurn(_ run: AgentTaskRun) -> Bool {
        run.liveness == .live && run.outcome == nil
    }

    /// A recorded revision is pending when no run started at or after it:
    /// its dispatch appended no attempt yet. Chronology is the one the
    /// persistence layer already enforces on runs, so no new sequence is
    /// invented here.
    static func hasPendingRevision(_ task: AgentTask) -> Bool {
        guard let last = task.revisions.last else { return false }
        return !task.runs.contains { $0.startedAt >= last.observedAt }
    }

    // MARK: - Revision transition

    /// Applies a submitted revision to the task (#1756): the new-attempt
    /// transition and invalidation, durably recorded before dispatch.
    ///
    /// Admission: the reference is bounded and well-formed; the task is not
    /// dismissed; no active turn is in flight. Either the task holds a
    /// current Ready result (the `readiness` contract over caller-proven
    /// identities), or it holds a PENDING revision (dispatch rejection or
    /// uncertain delivery) — in that case an explicit resubmission is
    /// allowed so a failed dispatch is never a dead end, and a duplicate of
    /// the exact pending reference is idempotent instead of a second
    /// transition.
    ///
    /// Effects: the revision record and candidate generation are recorded;
    /// current verification and acceptance are invalidated (the new
    /// candidate starts without current verification or acceptance); a
    /// completed task returns to `.paused` with the route missing, so a new
    /// attempt requires the explicit launch claim the dispatcher installs.
    /// Historical acceptance stays attached to its exact snapshot, and the
    /// previous result's identities, evidence, and feedback are untouched.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    static func submitRevision(
        _ task: inout AgentTask,
        feedbackReference: String,
        codeState: AgentTaskCodeStateIdentity?,
        environment: AgentTaskEnvironmentIdentity?,
        origin: AgentTaskRevisionOrigin,
        at timestamp: Date
    ) -> AgentTaskContinuationDecision {
        guard validRevisionReference(feedbackReference) else {
            return .rejected(.invalidReference)
        }
        guard task.lifecycle != .dismissed else {
            return .rejected(.dismissed)
        }
        guard let latest = task.runs.last else { return .rejected(.notReady) }
        guard !hasActiveTurn(latest) else { return .rejected(.activeTurn) }
        if let last = task.revisions.last,
           last.origin == origin,
           last.feedbackReference == feedbackReference,
           hasPendingRevision(task) {
            // A duplicate click/event on a not-yet-dispatched revision:
            // idempotent. No second transition, no second candidate.
            return .alreadyRecorded(candidateGeneration: last.candidateGeneration)
        }
        let hasCurrentDecision = task.reviewCycle.map {
            $0.state == .needsDecision && $0.taskID == task.id
                && $0.runID == latest.id && $0.codeState == codeState
                && $0.environment == environment
        } ?? false
        guard hasPendingRevision(task) || hasCurrentDecision
                || AgentTaskLifecycleReducer.readiness(
                    for: task,
                    codeState: codeState,
                    environment: environment
                ).isReady
        else {
            return .rejected(.notReady)
        }
        guard task.revisions.count < Self.maxRevisionRecords else {
            return .rejected(.limitReached)
        }
        let nextGeneration: UInt64
        switch origin {
        case .explicitUser:
            nextGeneration = task.candidateGeneration + 1
        case .automaticReviewer:
            // #1755 boundary: automatic corrections stay inside the
            // existing bounded cycle; continuation must not advance (or
            // reset) it.
            nextGeneration = task.candidateGeneration
        }
        task.candidateGeneration = nextGeneration
        task.revisions.append(AgentTaskRevisionRecord(
            origin: origin,
            feedbackReference: feedbackReference,
            candidateGeneration: nextGeneration,
            observedAt: timestamp,
            codeState: codeState
        ))
        // The new candidate starts without current verification or
        // acceptance; the immutable acceptance fact and acceptedSnapshot
        // stay as history, attached to their exact snapshot.
        task.verificationState = .stale
        task.acceptanceState = .notAccepted
        if task.lifecycle == .completed {
            task.lifecycle = .paused
            task.attention = .none
            task.completedAt = nil
        }
        task.executionState = AgentTaskLifecycleReducer.executionState(
            for: task
        )
        task.updatedAt = max(task.updatedAt, timestamp)
        task.lastActivityAt = max(task.lastActivityAt, timestamp)
        return .recorded(candidateGeneration: nextGeneration)
    }

    /// Bounded, content-free reference shape: the same policy the feedback
    /// records and the registry admission seam enforce.
    private static func validRevisionReference(_ reference: String) -> Bool {
        !reference.isEmpty
            && reference.utf8.count <= AgentTaskFeedbackRecord.maximumReferenceBytes
            && !reference.contains("\0")
    }
}
