//
//  AgentTaskLifecycleReducer.swift
//  Pine
//
//  The single versioned ADE lifecycle and evidence contract (#1722).
//
//  Every invariant shared by the Inbox, notifications, recovery, and result
//  surfaces is enforced in this one pure module over the durable task model:
//
//  - Process exit, terminal silence, and an agent completion claim never map
//    to Ready; they settle an attempt as `unverified` (or `failure` when an
//    independent fact says so).
//  - A finished attempt without all required independent evidence is
//    explicitly `unverified`.
//  - Missing positive idle evidence is `unknown`, never `idle`.
//  - Late, duplicate, replayed, nested, and foreign-provider events are
//    fenced by attempt identity, process incarnation, provider session
//    reference, source sequence, and observed chronology.
//  - Relevant edits, environment changes, and relaunch invalidate
//    verification and acceptance (fail closed) while preserving identifiable
//    reviewed and accepted snapshots; later edits never silently inherit an
//    older review or acceptance.
//

import Foundation

nonisolated enum AgentTaskLifecycleReducer {
    /// Independent evidence required, in addition to an agent-reported
    /// completion, to settle an attempt as `success`. The order is the order
    /// readiness gaps are reported.
    static let requiredEvidenceForSuccess: [AgentTaskEvidenceKind] = [
        .independentCheck,
        .reviewerOutcome
    ]

    /// Bounded maximum of durable evidence facts per task. This is the ONE
    /// admission bound: every entry path (recorded facts, user acceptance,
    /// observed settlement) fences through `admit`, and the metadata store
    /// keeps an equivalent count guard as a persistence backstop.
    static let maxEvidenceFacts = 64

    // MARK: - Execution state

    /// Derives the current execution dimension from the latest run.
    ///
    /// Absent or stale evidence, a run without positive provider state, and
    /// any settled run are `unknown`. `idle` requires a live run with
    /// accurate, positive provider state — terminal silence never does.
    static func executionState(
        liveness: AgentRunLiveness,
        state: AgentRunState?,
        accuracy: FirstPartyAgentNotificationAccuracy
    ) -> AgentTaskExecutionState {
        guard liveness == .live, let state else { return .unknown }
        switch state {
        case .thinking, .executing:
            // CPU-time advance is observed activity; a live process in an
            // active state is working at every accuracy.
            return .working
        case .waitingInput:
            return accuracy.permitsUserFacingLifecycleTransitions
                ? .blocked
                : .unknown
        case .idle, .done:
            return accuracy.permitsUserFacingLifecycleTransitions
                ? .idle
                : .unknown
        }
    }

    static func executionState(for task: AgentTask) -> AgentTaskExecutionState {
        guard let run = task.runs.last else { return .unknown }
        return executionState(
            liveness: run.liveness,
            state: run.state,
            accuracy: run.lifecycleAccuracy
        )
    }

    // MARK: - Evidence validation and fencing

    /// Semantic validity of one fact. Storage-level bounds (hex shape,
    /// lengths, counts) are enforced by the metadata store.
    static func isValid(_ fact: AgentTaskEvidenceFact) -> Bool {
        guard fact.kind.allows(result: fact.result),
              fact.kind.allowsVerifiedTrust || fact.trust != .verified,
              fact.observedAt.timeIntervalSinceReferenceDate.isFinite,
              fact.processGeneration > 0,
              fact.sourceSequence.map({ $0 > 0 }) ?? true else {
            return false
        }
        if let codeState = fact.codeState {
            guard codeState.scheme == AgentTaskCodeStateIdentity.currentScheme else {
                return false
            }
        }
        if let environment = fact.environment {
            guard environment.scheme == AgentTaskEnvironmentIdentity.currentScheme else {
                return false
            }
        }
        return true
    }

    /// Fences one fact against the task's durable attempts.
    ///
    /// A fact may only ever be admitted for an attempt it actually belongs
    /// to; historical facts for a replaced run are admitted as history and
    /// can never settle the current attempt, because settlement only reads
    /// the latest run's facts.
    static func admit(
        _ fact: AgentTaskEvidenceFact,
        into task: AgentTask
    ) -> AgentTaskEvidenceAdmission {
        guard task.evidence.count < Self.maxEvidenceFacts else {
            return .fencedOut(.limitReached)
        }
        guard isValid(fact) else { return .fencedOut(.invalidFact) }
        guard let run = task.runs.first(where: { $0.id == fact.runID }) else {
            return .fencedOut(.unknownRun)
        }
        guard fact.processGeneration == run.process.processGeneration else {
            return .fencedOut(.foreignProcess)
        }
        if let vendorIdentity = run.vendorIdentity,
           let vendorSession = fact.vendorSession {
            guard vendorSession.provider == vendorIdentity.provider,
                  vendorSession.opaqueIdentifier == vendorIdentity.opaqueIdentifier
            else {
                return .fencedOut(.foreignVendorSession)
            }
        }
        guard fact.observedAt >= run.startedAt else {
            return .fencedOut(.lateEvent)
        }
        let identity = fact.eventIdentity
        guard !task.evidence.contains(where: { $0.eventIdentity == identity }) else {
            return .fencedOut(.duplicate)
        }
        return .accepted
    }

    // MARK: - Settlement

    static func isSettled(_ run: AgentTaskRun) -> Bool {
        run.liveness == .terminated && run.endedAt != nil
    }

    static func facts(
        forRun runID: UUID,
        in task: AgentTask
    ) -> [AgentTaskEvidenceFact] {
        task.evidence.filter { $0.runID == runID }
    }

    /// Settles the outcome of one terminated run from its evidence.
    ///
    /// The outcome is a pure function of the bound facts: cancellation wins
    /// over failure; any failing independent fact makes the attempt a
    /// failure; a success requires an agent-reported completion and every
    /// required independent fact passing against one shared code-state
    /// identity. Everything else — exit, silence, a claim without
    /// verification — is `unverified`.
    static func settleOutcome(
        for run: AgentTaskRun,
        evidence: [AgentTaskEvidenceFact]
    ) -> AgentTaskOutcome {
        let facts = evidence.filter { $0.runID == run.id }
        if facts.contains(where: { $0.kind == .userCancellation }) {
            return .cancellation
        }
        if facts.contains(where: { fact in
            (fact.kind == .independentCheck || fact.kind == .reviewerOutcome)
                && !fact.kind.isPassing(fact.result)
        }) {
            return .failure
        }
        // Re-emitted completion claims: the LATEST observed claim wins
        // deterministically, so an older claim bound to a different
        // code state cannot mask a newer, current one.
        if let claim = facts
            .filter({ $0.kind == .agentReportedCompletion })
            .max(by: { $0.observedAt < $1.observedAt }) {
            let requiredSatisfied = Self.requiredEvidenceForSuccess.allSatisfy { kind in
                facts.contains(where: { fact in
                    fact.kind == kind
                        && fact.kind.isPassing(fact.result)
                        && Self.sameCodeState(fact, claim)
                })
            }
            if requiredSatisfied {
                return .success
            }
        }
        return .unverified
    }

    /// Two bound facts share one code-state identity only when both recorded
    /// a non-nil identity and the identities are equal. An unbound fact can
    /// never prove relevance.
    private static func sameCodeState(
        _ lhs: AgentTaskEvidenceFact,
        _ rhs: AgentTaskEvidenceFact
    ) -> Bool {
        guard let lhs = lhs.codeState, let rhs = rhs.codeState else {
            return false
        }
        return lhs == rhs
    }

    /// Records the Pine-observed process completion for a terminated run and
    /// settles it. Idempotent: a repeated termination observation fences as
    /// a duplicate and leaves the outcome unchanged. At the fact bound the
    /// observation is fenced (`.limitReached`) and skipped, but the run
    /// still settles: a `.success`/`.failure` settlement necessarily carries
    /// at least one bound fact, so the persisted state stays valid.
    static func settleTerminated(
        task: inout AgentTask,
        runIndex: Int
    ) {
        guard task.runs.indices.contains(runIndex),
              isSettled(task.runs[runIndex]) else {
            return
        }
        let run = task.runs[runIndex]
        let completion = AgentTaskEvidenceFact(
            kind: .processCompletion,
            runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .observed,
            result: .exited(status: nil),
            observedAt: run.endedAt ?? run.lastObservedAt
        )
        if case .accepted = admit(completion, into: task) {
            task.evidence.append(completion)
        }
        settleLatestRun(of: &task, runIndex: runIndex)
    }

    /// Re-settles the latest run's outcome and the task-level completion
    /// state from the current evidence. Called whenever the latest run
    /// terminates or a new fact for it is admitted. Facts for older runs are
    /// history: they never re-settle a superseded attempt or the current one.
    static func settleLatestRun(of task: inout AgentTask, runIndex: Int) {
        guard task.runs.indices.contains(runIndex),
              runIndex == task.runs.indices.last,
              isSettled(task.runs[runIndex]) else {
            return
        }
        let outcome = settleOutcome(
            for: task.runs[runIndex],
            evidence: task.evidence
        )
        if task.runs[runIndex].outcome != outcome {
            task.runs[runIndex].outcome = outcome
        }
        applySettledOutcome(of: &task, outcome: outcome)
    }

    private static func applySettledOutcome(
        of task: inout AgentTask,
        outcome: AgentTaskOutcome
    ) {
        guard let latest = task.runs.last, isSettled(latest) else { return }
        let previousAttention = task.attention
        // Re-settling away from a previously accepted result never inherits
        // the acceptance: the immutable acceptance fact and acceptedSnapshot
        // stay as history, the state resets.
        let resetsAcceptance: Bool
        switch outcome {
        case .success: resetsAcceptance = false
        case .failure, .unverified, .cancellation, .superseded:
            resetsAcceptance = true
        }
        switch outcome {
        case .success:
            task.lifecycle = .completed
            task.attention = .completed
            task.completedAt = latest.endedAt
            // A stale verification never re-upgrades from later facts alone:
            // an invalidated result stays invalidated until an explicit
            // re-verification (the verification layer owns that action).
            if task.verificationState != .stale {
                task.verificationState = .verified
            }
            task.reviewedSnapshot = Self.latestSnapshot(
                forKind: .reviewerOutcome,
                run: latest,
                outcome: outcome,
                in: task
            )
        case .failure:
            task.lifecycle = .completed
            task.attention = .failed
            task.completedAt = latest.endedAt
            task.reviewedSnapshot = Self.latestSnapshot(
                forKind: .reviewerOutcome,
                run: latest,
                outcome: outcome,
                in: task
            )
        case .unverified:
            task.lifecycle = .paused
            task.attention = .none
            task.completedAt = nil
            task.verificationState = .none
        case .cancellation:
            task.lifecycle = .paused
            task.attention = .none
            task.completedAt = nil
        case .superseded:
            // A superseded latest run is a replacement in progress; the new
            // run's state owns the task-level fields.
            break
        }
        if resetsAcceptance {
            task.acceptanceState = .notAccepted
        }
        if task.attention != .none, task.attention != previousAttention {
            task.isUnread = true
        }
        task.executionState = executionState(for: task)
    }

    private static func latestSnapshot(
        forKind kind: AgentTaskEvidenceKind,
        run: AgentTaskRun,
        outcome: AgentTaskOutcome,
        in task: AgentTask
    ) -> AgentTaskResultSnapshot? {
        task.evidence
            .filter { $0.kind == kind && $0.runID == run.id }
            .sorted { $0.observedAt < $1.observedAt }
            .last
            .map {
                AgentTaskResultSnapshot(
                    runID: run.id,
                    outcome: outcome,
                    codeState: $0.codeState,
                    environment: $0.environment,
                    recordedAt: $0.observedAt
                )
            }
    }

    // MARK: - Invalidation

    /// Invalidates the task's current verification and acceptance after a
    /// relevant change, returning the readiness gaps that result.
    ///
    /// `codeState == nil && environment == nil` is the relaunch trigger:
    /// Pine cannot re-prove the environment, so current positive state fails
    /// closed. Otherwise the supplied identities are compared against the
    /// recorded snapshots and bound evidence; an observed mismatch, or the
    /// inability to prove relevance, invalidates.
    ///
    /// Snapshots are never erased: reviewed and accepted results stay
    /// identifiable, and a later edit is checked against them instead of
    /// inheriting them.
    @discardableResult
    static func invalidate(
        _ task: inout AgentTask,
        codeState: AgentTaskCodeStateIdentity?,
        environment: AgentTaskEnvironmentIdentity?
    ) -> [AgentTaskReadinessGap] {
        guard task.verificationState == .verified
                || task.verificationState == .pending
                || task.acceptanceState == .accepted
                || task.reviewedSnapshot != nil
                || task.acceptedSnapshot != nil else {
            return []
        }
        guard isInvalidated(
            task,
            codeState: codeState,
            environment: environment
        ) else {
            return []
        }
        task.verificationState = .stale
        task.acceptanceState = .notAccepted
        var gaps: [AgentTaskReadinessGap] = []
        if codeState == nil {
            gaps.append(.codeStateUnknown)
        }
        if environment == nil {
            gaps.append(.environmentUnknown)
        }
        for kind in Self.requiredEvidenceForSuccess {
            gaps.append(.staleEvidence(kind))
        }
        return gaps
    }

    private static func isInvalidated(
        _ task: AgentTask,
        codeState: AgentTaskCodeStateIdentity?,
        environment: AgentTaskEnvironmentIdentity?
    ) -> Bool {
        // Relaunch: no re-proved identities, so current positive state is
        // stale.
        guard let codeState, let environment else { return true }
        let latest = task.runs.last
        let boundFacts: [AgentTaskEvidenceFact] = latest.map {
            Self.facts(forRun: $0.id, in: task).filter {
                Self.requiredEvidenceForSuccess.contains($0.kind)
            }
        } ?? []
        let references: [AgentTaskResultSnapshot?] = [
            task.acceptedSnapshot,
            task.reviewedSnapshot
        ]
        for reference in references {
            if let reference,
               let recorded = reference.codeState,
               recorded != codeState {
                return true
            }
            if let reference,
               let recorded = reference.environment,
               recorded != environment {
                return true
            }
        }
        for fact in boundFacts {
            if let recorded = fact.codeState, recorded != codeState {
                return true
            }
            if let recorded = fact.environment, recorded != environment {
                return true
            }
        }
        return false
    }

    // MARK: - Re-verification

    /// Marks in-flight verification on a settled successful attempt.
    ///
    /// Produced by the verification layer while the required evidence is
    /// being re-run. Legal from `.none` and `.stale`; idempotent on
    /// `.pending`; it never demotes `.verified` (only invalidation does) and
    /// it never touches a non-successful settled attempt.
    static func recordVerificationPending(_ task: inout AgentTask) {
        guard let latest = task.runs.last,
              isSettled(latest),
              latest.outcome == .success,
              task.verificationState == .none
                  || task.verificationState == .stale
                  || task.verificationState == .pending else {
            return
        }
        task.verificationState = .pending
    }

    /// Re-establishes current verification after an invalidation.
    ///
    /// The verification layer owns this action: after re-running the
    /// required independent evidence against the current code state and
    /// environment, it records the new bound facts and then grants this.
    /// Preconditions: the latest run is settled with outcome `.success`,
    /// and every required fact (independent check + reviewer outcome)
    /// passes bound to the caller-proven current identities (both
    /// non-nil and equal — unbound facts cannot re-prove relevance).
    /// Effects: `.stale` and `.pending` become `.verified`; `.verified` is
    /// idempotent; anything else is a no-op. No later fact alone re-upgrades
    /// a stale result — this is the only way out of it.
    static func reverify(
        _ task: inout AgentTask,
        codeState: AgentTaskCodeStateIdentity,
        environment: AgentTaskEnvironmentIdentity
    ) {
        guard task.verificationState == .stale
                || task.verificationState == .pending
                || task.verificationState == .verified else {
            return
        }
        guard let latest = task.runs.last,
              isSettled(latest),
              latest.outcome == .success else {
            return
        }
        let facts = Self.facts(forRun: latest.id, in: task)
        guard Self.requiredEvidenceForSuccess.allSatisfy({ kind in
            facts.contains { fact in
                fact.kind == kind
                    && fact.kind.isPassing(fact.result)
                    && fact.codeState == codeState
                    && fact.environment == environment
            }
        }) else {
            return
        }
        task.verificationState = .verified
    }

    // MARK: - Ready projection

    /// Projects Ready from current required evidence only. Ready is derived,
    /// never stored: it exists exactly when the settled attempt succeeded,
    /// the verification state is current, and every required evidence fact
    /// is passing and bound to the current code-state and environment
    /// identities.
    static func readiness(
        for task: AgentTask,
        codeState: AgentTaskCodeStateIdentity?,
        environment: AgentTaskEnvironmentIdentity?
    ) -> AgentTaskReadiness {
        guard let latest = task.runs.last else {
            return AgentTaskReadiness(isReady: false, gaps: [.noSettledAttempt])
        }
        guard isSettled(latest) else {
            return AgentTaskReadiness(isReady: false, gaps: [.attemptInProgress])
        }
        switch latest.outcome {
        case nil:
            return AgentTaskReadiness(isReady: false, gaps: [.noSettledAttempt])
        case .unverified:
            // The attempt ended without all required independent evidence.
            // When the current code state is known, also name which evidence
            // is missing or stale so the repeat work is identified.
            var gaps: [AgentTaskReadinessGap] = [.unverifiedOutcome]
            if let codeState {
                let facts = Self.facts(forRun: latest.id, in: task)
                if !facts.contains(where: {
                    $0.kind == .agentReportedCompletion
                }) {
                    gaps.append(.missingEvidence(.agentReportedCompletion))
                }
                for kind in Self.requiredEvidenceForSuccess {
                    let kindFacts = facts.filter { $0.kind == kind }
                    // Prefer a passing fact bound to the current code state;
                    // only when none is, the kind's newest passing fact
                    // proves staleness (or the absence of any, failure).
                    guard let passing = kindFacts.first(where: {
                        kind.isPassing($0.result)
                            && $0.codeState == codeState
                    }) ?? kindFacts.first(where: {
                        kind.isPassing($0.result)
                    }) else {
                        gaps.append(
                            kindFacts.isEmpty
                                ? .missingEvidence(kind)
                                : .failingEvidence(kind)
                        )
                        continue
                    }
                    guard let bound = passing.codeState, bound == codeState else {
                        gaps.append(.staleEvidence(kind))
                        continue
                    }
                }
            }
            return AgentTaskReadiness(isReady: false, gaps: gaps)
        case .failure:
            return AgentTaskReadiness(isReady: false, gaps: [.failedAttempt])
        case .cancellation:
            return AgentTaskReadiness(isReady: false, gaps: [.cancelledAttempt])
        case .superseded:
            return AgentTaskReadiness(isReady: false, gaps: [.supersededAttempt])
        case .success:
            var gaps: [AgentTaskReadinessGap] = []
            if task.verificationState != .verified {
                gaps.append(.verificationNotCurrent)
            }
            guard let codeState else {
                gaps.append(.codeStateUnknown)
                return AgentTaskReadiness(isReady: false, gaps: gaps)
            }
            guard let environment else {
                gaps.append(.environmentUnknown)
                return AgentTaskReadiness(isReady: false, gaps: gaps)
            }
            let facts = Self.facts(forRun: latest.id, in: task)
            for kind in Self.requiredEvidenceForSuccess {
                let kindFacts = facts.filter { $0.kind == kind }
                guard !kindFacts.isEmpty else {
                    gaps.append(.missingEvidence(kind))
                    continue
                }
                // Prefer a passing fact bound to the CURRENT code state:
                // historical passing facts bound to an older state do not
                // satisfy the current one, and current-bound facts are not
                // masked by older ones earlier in the array.
                guard let passing = kindFacts.first(where: {
                    kind.isPassing($0.result)
                        && $0.codeState == codeState
                }) ?? kindFacts.first(where: {
                    kind.isPassing($0.result)
                }) else {
                    gaps.append(.failingEvidence(kind))
                    continue
                }
                guard let bound = passing.codeState, bound == codeState else {
                    gaps.append(.staleEvidence(kind))
                    continue
                }
                if let boundEnvironment = passing.environment,
                   boundEnvironment != environment {
                    gaps.append(.environmentChanged)
                }
            }
            return AgentTaskReadiness(isReady: gaps.isEmpty, gaps: gaps)
        }
    }
}
