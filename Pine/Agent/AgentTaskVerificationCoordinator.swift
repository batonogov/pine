//
//  AgentTaskVerificationCoordinator.swift
//  Pine
//
//  ADE verification orchestration (issue #1724, parent integration slice).
//
//  Orders how a settled attempt's required evidence is produced and
//  admitted, and gates Ready publication on that order:
//
//  - Required checks (Pine-observed execution, #1754) must pass BEFORE
//    independent review (#1755) and before Ready. Review starts only after
//    a passing check judgment is durable.
//  - Invalidation is persisted BEFORE the dependent positive evidence:
//    every durable step a later step relies on is flushed before that step
//    runs, so a crash anywhere in the pass fails closed on relaunch.
//  - Re-verification requires the persisted task/command grant revalidated
//    immediately before EVERY execution attempt; a missing or revoked grant
//    yields an explicit user action, never an execution.
//  - Reviewer- or implementer-reported test success is not a substitute:
//    `.independentCheck` facts originate only from the check-execution
//    port, `.reviewerOutcome` facts only from the reviewer port.
//  - Nothing here auto-starts an agent or executes a command. Every port
//    call sits inside one explicit user verification pass; the review
//    observation type carries no command payload, so reviewer-suggested
//    commands remain untrusted suggestions with no path to execution
//    authority; correction dispatch stays owned by #1755's durable cycle.
//  - Unresolved review findings and exhausted infrastructure bounds
//    escalate to Needs decision with a concrete, safe recommendation
//    (`requiredAction`) only; they never produce Ready or a reassuring
//    success state.
//  - Every suspension is fenced by pass lease, task, attempt, and process
//    generation. Evidence admission does not settle the attempt; one atomic registry
//    assignment publishes outcome and current verification only after the
//    final probe succeeds.
//
//  Pending integration seams (real-provider end-to-end follows #1811/#1723):
//  - `probeIdentity`    <- #1753: `AgentVerificationIdentityCapture.revalidate`
//                           + `AgentTaskEnvironmentBinding.validateAuthority`
//  - `grantIsCurrent`   <- #1753/#1754: `AgentTaskCheckGrant.matchesScope`
//                           against the current (not cached) persisted grant
//  - `runRequiredChecks` <- #1754: the bounded executor with its pre-spawn
//                           launch gate (`AgentTaskCheckLaunchValidator`)
//  - `startReview`      <- #1755: the separate read-only reviewer session;
//                           reviewer identity, criteria, and limitations
//                           bind into the durable review record there
//

import Foundation

// MARK: - Port observations

/// One Pine-observed required-check run (#1754 executor contract).
///
/// Content-free by design: bounded fingerprints and statuses, never literal
/// argv or diagnostics. Provider- or reviewer-reported success can never
/// produce this value; only the executor's bounded observation can.
nonisolated struct AgentTaskCheckObservation: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case succeeded
        case failed
        case timedOut
        case cancelled
        case launchFailed
        case outputUnavailable
        case cleanupFailed
        case authorityChanged
        case identityChanged
        case identityUnavailable
    }

    struct CommandResult: Equatable, Sendable {
        let operationID: UUID
        /// 64-hex command fingerprint; never the literal arguments.
        let fingerprint: String
        let required: Bool
        let status: Status

        /// The command actually ran to a verdict about the candidate.
        var isJudgment: Bool { status == .succeeded || status == .failed }
        var isPassing: Bool { status == .succeeded }
    }

    let taskID: UUID
    let runID: UUID
    let passID: UUID
    let executionID: UUID
    let planFingerprint: String
    let processGeneration: UInt64
    let journalCompleted: Bool
    /// Terminal cancellation of the whole execution, including after a completed journal.
    var cancelled = false
    /// Any runtime authority revocation invalidates the observation, even if its persistence raced a write.
    var authorityRevoked = false
    let results: [CommandResult]
    let preCodeState: AgentTaskCodeStateIdentity?
    let postCodeState: AgentTaskCodeStateIdentity?
    let environment: AgentTaskEnvironmentIdentity?

    /// The candidate did not move while the required set was observed.
    var identitiesAreStable: Bool {
        verificationIdentitiesAreStable(
            pre: preCodeState, post: postCodeState, environment: environment
        )
    }

    /// The required set produced a verdict against stable, fully observed
    /// identities. Anything else (timeout, cancellation, launch, identity,
    /// or authority problems) establishes no fact at all.
    var hasCompleteRequiredJudgment: Bool {
        let required = results.filter(\.required)
        return journalCompleted && processGeneration > 0 && !authorityRevoked
            && AgentTaskCheckPlan.validFingerprint(planFingerprint)
            && !required.isEmpty && required.allSatisfy(\.isJudgment)
            && Set(results.map(\.operationID)).count == results.count
            && Set(results.map(\.fingerprint)).count == results.count
            && results.allSatisfy { AgentTaskCheckPlan.validFingerprint($0.fingerprint) }
    }

    var isJudgment: Bool {
        hasCompleteRequiredJudgment && identitiesAreStable
    }

    var requiredSucceeded: Bool {
        let required = results.filter(\.required)
        return !required.isEmpty && required.allSatisfy(\.isPassing)
    }

    var requiredCancelled: Bool {
        cancelled || results.contains { $0.required && $0.status == .cancelled }
    }

    static func blocked(
        request: AgentTaskVerificationCheckRequest, planFingerprint: String,
        cancelled: Bool, authorityRevoked: Bool
    ) -> Self {
        AgentTaskCheckObservation(
            taskID: request.taskID, runID: request.runID, passID: request.passID,
            executionID: UUID(), planFingerprint: planFingerprint,
            processGeneration: request.processGeneration, journalCompleted: false,
            cancelled: cancelled, authorityRevoked: authorityRevoked,
            results: [], preCodeState: nil, postCodeState: nil,
            environment: request.expected.environment
        )
    }
}

/// One Pine-observed independent-review result (#1755 reviewer contract).
///
/// The type carries no command or executable payload: reviewer-suggested
/// commands remain untrusted suggestions and have no route from this
/// observation into execution authority.
nonisolated struct AgentTaskReviewObservation: Equatable, Sendable {
    enum Outcome: String, Equatable, Sendable {
        case passed
        case requestedChanges
        case failed
        case cancelled
        case infrastructureFailure
    }

    /// The evidence fact result a judgment maps to, or `nil` when the
    /// review produced no verdict.
    var evidenceResult: AgentTaskEvidenceResult? {
        switch outcome {
        case .passed:
            return .succeeded
        case .requestedChanges:
            return .requestedChanges
        case .failed:
            return .failed
        case .cancelled, .infrastructureFailure:
            return nil
        }
    }

    let taskID: UUID
    let runID: UUID
    let passID: UUID
    let reviewerSession: AgentVendorSessionIdentity
    let criteriaDigest: String
    let outcome: Outcome
    let preCodeState: AgentTaskCodeStateIdentity?
    let postCodeState: AgentTaskCodeStateIdentity?
    let environment: AgentTaskEnvironmentIdentity?

    var isJudgment: Bool { evidenceResult != nil }

    /// The candidate did not move while the review ran; a review that
    /// observed a changing candidate is not an independent pass.
    var identitiesAreStable: Bool {
        verificationIdentitiesAreStable(
            pre: preCodeState, post: postCodeState, environment: environment
        )
    }
}

nonisolated private func verificationIdentitiesAreStable(
    pre: AgentTaskCodeStateIdentity?,
    post: AgentTaskCodeStateIdentity?,
    environment: AgentTaskEnvironmentIdentity?
) -> Bool {
    guard let pre, let post, pre == post else { return false }
    return environment != nil
}

// MARK: - Port requests

/// The exact inputs the check executor validates before spawn: the
/// caller-proven identity the executor re-observes and compares immediately
/// before launch (#1754 pre-spawn gate).
nonisolated struct AgentTaskVerificationCheckRequest: Equatable, Sendable {
    let taskID: UUID
    let runID: UUID
    let passID: UUID
    let processGeneration: UInt64
    let expected: AgentVerificationIdentitySnapshot
    /// 1-based infrastructure attempt within this pass.
    let attempt: Int
}

/// The exact binding a separate reviewer session must review (#1755):
/// explicit criteria plus the checked candidate/environment identity.
nonisolated struct AgentTaskVerificationReviewRequest: Equatable, Sendable {
    let taskID: UUID
    let runID: UUID
    let passID: UUID
    let expected: AgentVerificationIdentitySnapshot
    let criteria: String

    var criteriaDigest: String {
        AgentHistoryContentHash.sha256Hex(Data(criteria.utf8))
    }
}

// MARK: - Result

/// The outcome of one explicit verification pass.
///
/// `needsDecision` escalates only with a concrete, safe recommendation in
/// `requiredAction`. Unresolved review findings never produce `ready` or a
/// reassuring success state.
nonisolated struct AgentTaskVerificationResult: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case ready
        case notReady
        case needsDecision
        case cancelled
    }

    enum Reason: String, Equatable, Sendable {
        case invalidCriteria
        case identityNotCurrent
        case checkGrantNotCurrent
        case checksFailed
        case checksNotObserved
        case reviewRequestedChanges
        case reviewFailed
        case reviewNotObserved
        case evidenceNotAdmitted
        case persistenceUnavailable
    }

    enum RequiredAction: String, Equatable, Sendable {
        case approveCheckGrant
        case rerunRequiredChecks
        case rerunReview
        case resolveReviewFindings
    }

    let status: Status
    let readiness: AgentTaskReadiness
    let reason: Reason?
    let requiredAction: RequiredAction?
}

// MARK: - Coordinator

/// Orders required checks, independent review, and Ready publication over
/// the durable task model (#1724).
///
/// The coordinator executes nothing itself: it drives four capability seams
/// owned by #1753 (identity capture, grant scope), #1754 (bounded check
/// execution), and #1755 (separate reviewer), and it persists only through
/// the registry's existing seams. It fails closed whenever it cannot prove
/// the current code state or environment.
nonisolated struct AgentTaskVerificationCoordinator: Sendable {
    struct Ports: Sendable {
        /// #1753 seam: re-observe the current code + environment identity
        /// immediately before an effect. `nil` fails closed.
        let probeIdentity: @Sendable (AgentTask) async -> AgentVerificationIdentitySnapshot?
        /// #1753/#1754 seam: revalidate the current persisted task/command
        /// grant immediately before each execution attempt. The result is
        /// never cached across attempts.
        let grantIsCurrent: @Sendable (AgentTask) async -> Bool
        /// #1754 seam: run the selected required-check plan in the validated
        /// environment and observe the result.
        let runRequiredChecks: @Sendable (
            AgentTaskVerificationCheckRequest
        ) async throws -> AgentTaskCheckObservation
        /// #1755 seam: start a separate, read-only reviewer session against
        /// explicit criteria and the exact candidate/environment binding.
        let startReview: @Sendable (
            AgentTaskVerificationReviewRequest
        ) async throws -> AgentTaskReviewObservation
    }

    /// A named reason for a non-Ready outcome, with the explicit, safe user
    /// action it offers when one is safe (the Needs-decision
    /// recommendation).
    struct Escalation: Equatable, Sendable {
        let reason: AgentTaskVerificationResult.Reason
        let action: AgentTaskVerificationResult.RequiredAction?
    }

    private struct VerificationPass {
        let id: UUID
        let taskID: UUID
        let runID: UUID
        let processGeneration: UInt64
        let project: AgentTaskProjectIdentity
    }

    /// Bounded infrastructure retry for check execution within one pass.
    /// This is a separate bound from the three review-correction rounds
    /// owned by #1755's durable cycle.
    static let maximumCheckRetries = 1
    static let maximumCriteriaBytes = 2_048

    let ports: Ports
    private let now: @Sendable () -> Date

    init(
        probeIdentity: @escaping @Sendable (AgentTask) async -> AgentVerificationIdentitySnapshot?,
        grantIsCurrent: @escaping @Sendable (AgentTask) async -> Bool,
        runRequiredChecks: @escaping @Sendable (
            AgentTaskVerificationCheckRequest
        ) async throws -> AgentTaskCheckObservation,
        startReview: @escaping @Sendable (
            AgentTaskVerificationReviewRequest
        ) async throws -> AgentTaskReviewObservation,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        ports = Ports(
            probeIdentity: probeIdentity,
            grantIsCurrent: grantIsCurrent,
            runRequiredChecks: runRequiredChecks,
            startReview: startReview
        )
        self.now = now
    }

    /// Runs one explicit verification pass over a settled attempt:
    /// probe -> persisted invalidation -> grant-gated required checks ->
    /// review (only after the checks pass) -> immediate re-probe -> the
    /// Ready gate.
    ///
    /// Restore and open paths never call this: opening a result or
    /// relaunching the app does not execute checks or start a reviewer, and
    /// the pass never starts an implementer.
    @MainActor
    func runVerificationPass(
        taskID: UUID, criteria: String, registry: AgentTaskRegistry
    ) async -> AgentTaskVerificationResult {
        guard let task = registry.task(for: taskID) else {
            return finish(registry, taskID: taskID, identity: nil, status: .notReady)
        }
        guard Self.validCriteria(criteria) else {
            return finish(
                registry, taskID: taskID, identity: nil,
                status: .notReady, escalation: .init(reason: .invalidCriteria, action: nil)
            )
        }
        guard let run = task.runs.last, AgentTaskLifecycleReducer.isSettled(run) else {
            return finish(registry, taskID: taskID, identity: nil, status: .notReady)
        }
        let pass = VerificationPass(
            id: UUID(),
            taskID: taskID,
            runID: run.id,
            processGeneration: run.process.processGeneration,
            project: task.project
        )
        guard !Task.isCancelled, task.lifecycle != .dismissed else {
            return obsoleteResult(registry, pass: pass)
        }
        guard registry.markVerificationPending(
            taskID: taskID, expectedRunID: run.id,
            processGeneration: pass.processGeneration,
            verificationPassID: pass.id
        ) else {
            return finish(registry, taskID: taskID, identity: nil, status: .notReady)
        }
        defer {
            registry.clearVerificationPending(
                taskID: taskID, runID: run.id,
                processGeneration: pass.processGeneration,
                verificationPassID: pass.id
            )
        }

        // Claim the pass before the first suspension so an already-Ready task
        // cannot remain publishable while re-verification is in flight.
        let initialProbe = await ports.probeIdentity(task)
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        guard let anchor = initialProbe else {
            _ = registry.invalidateEvidence(
                taskID: taskID, codeState: nil, environment: nil, runID: run.id
            )
            let saved = await durableFlush(registry, project: pass.project)
            guard passIsCurrent(registry, pass: pass) else {
                return obsoleteResult(registry, pass: pass)
            }
            if !saved {
                registry.failVerificationPass(
                    taskID: taskID, runID: run.id,
                    processGeneration: pass.processGeneration,
                    verificationPassID: pass.id, codeState: nil, environment: nil
                )
                return finish(
                    registry, taskID: taskID, identity: nil, status: .notReady,
                    escalation: .init(reason: .persistenceUnavailable, action: nil)
                )
            }
            return finish(
                registry, taskID: taskID, identity: nil, status: .notReady,
                escalation: .init(reason: .identityNotCurrent, action: nil)
            )
        }

        _ = registry.invalidateEvidence(
            taskID: taskID,
            codeState: anchor.code,
            environment: anchor.environment,
            runID: run.id
        )
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        registry.markVerificationPending(
            taskID: taskID, expectedRunID: run.id,
            processGeneration: pass.processGeneration,
            verificationPassID: pass.id
        )
        let initialSaved = await durableFlush(registry, project: pass.project)
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        guard initialSaved else {
            registry.failVerificationPass(
                taskID: taskID, runID: run.id,
                processGeneration: pass.processGeneration,
                verificationPassID: pass.id,
                codeState: anchor.code, environment: anchor.environment
            )
            return finish(
                registry, taskID: taskID, identity: anchor, status: .notReady,
                escalation: .init(reason: .persistenceUnavailable, action: nil)
            )
        }

        let checks = await runRequiredChecks(
            registry, task: task, pass: pass, anchor: anchor
        )
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        guard case let .judgment(observation) = checks else {
            guard case let .terminal(result) = checks else {
                return finish(
                    registry, taskID: taskID, identity: anchor, status: .notReady,
                    escalation: .init(reason: .evidenceNotAdmitted, action: nil)
                )
            }
            return result
        }
        // The executor returned a durable journal; revalidate authority and
        // identity again before this coordinator admits its aggregate fact.
        guard let grantTask = registry.task(for: taskID) else {
            return obsoleteResult(registry, pass: pass)
        }
        let grantBeforeEvidence = await ports.grantIsCurrent(grantTask)
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        guard grantBeforeEvidence else {
            return finish(
                registry, taskID: taskID, identity: anchor, status: .notReady,
                escalation: .init(reason: .checkGrantNotCurrent, action: .approveCheckGrant)
            )
        }
        guard let identityTask = registry.task(for: taskID) else {
            return obsoleteResult(registry, pass: pass)
        }
        let identityBeforeEvidence = await ports.probeIdentity(identityTask)
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        guard identityBeforeEvidence == anchor else {
            return finish(
                registry, taskID: taskID, identity: identityBeforeEvidence, status: .notReady,
                escalation: .init(reason: .identityNotCurrent, action: nil)
            )
        }

        let checkRecord = await record(
            registry,
            Self.checkFact(for: run, observation: observation, now: now()),
            pass: pass
        )
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        guard checkRecord == .saved else {
            let reason: AgentTaskVerificationResult.Reason =
                checkRecord == .notAdmitted ? .evidenceNotAdmitted : .persistenceUnavailable
            if checkRecord == .flushFailed {
                registry.failVerificationPass(
                    taskID: taskID, runID: run.id,
                    processGeneration: pass.processGeneration,
                    verificationPassID: pass.id,
                    codeState: anchor.code, environment: anchor.environment
                )
            }
            return finish(
                registry, taskID: taskID, identity: anchor,
                status: .notReady, escalation: .init(reason: reason, action: nil)
            )
        }
        guard observation.requiredSucceeded else {
            guard let readiness = registry.settleVerificationPass(
                taskID: taskID, runID: run.id,
                processGeneration: pass.processGeneration,
                verificationPassID: pass.id,
                codeState: anchor.code, environment: anchor.environment,
                makeCurrent: false
            ) else {
                return obsoleteResult(registry, pass: pass)
            }
            return finish(
                registry, taskID: taskID, identity: anchor, status: .notReady,
                escalation: .init(reason: .checksFailed, action: .rerunRequiredChecks),
                readiness: readiness
            )
        }

        let reviewRequest = AgentTaskVerificationReviewRequest(
            taskID: taskID, runID: run.id, passID: pass.id,
            expected: anchor, criteria: criteria
        )
        let review: AgentTaskReviewObservation
        do {
            review = try await ports.startReview(reviewRequest)
        } catch {
            guard passIsCurrent(registry, pass: pass) else {
                return obsoleteResult(registry, pass: pass)
            }
            if error is CancellationError {
                return finish(registry, taskID: taskID, identity: anchor, status: .cancelled)
            }
            return finish(
                registry, taskID: taskID, identity: anchor, status: .notReady,
                escalation: .init(reason: .reviewNotObserved, action: .rerunReview)
            )
        }
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        if review.outcome == .cancelled {
            return finish(registry, taskID: taskID, identity: anchor, status: .cancelled)
        }
        guard let reviewResult = review.evidenceResult else {
            return finish(
                registry, taskID: taskID, identity: anchor, status: .notReady,
                escalation: .init(reason: .reviewNotObserved, action: .rerunReview)
            )
        }
        guard let authorSession = run.vendorIdentity,
              authorSession.provider != review.reviewerSession.provider
                  || authorSession.opaqueIdentifier != review.reviewerSession.opaqueIdentifier,
              review.taskID == reviewRequest.taskID,
              review.runID == reviewRequest.runID,
              review.passID == reviewRequest.passID,
              review.criteriaDigest == reviewRequest.criteriaDigest,
              review.preCodeState == anchor.code,
              review.postCodeState == anchor.code,
              review.environment == anchor.environment else {
            return finish(
                registry, taskID: taskID, identity: anchor, status: .notReady,
                escalation: .init(reason: .identityNotCurrent, action: nil)
            )
        }
        let reviewRecord = await record(
            registry,
            Self.reviewFact(for: run, result: reviewResult, observation: review, now: now()),
            pass: pass
        )
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        guard reviewRecord == .saved else {
            let reason: AgentTaskVerificationResult.Reason =
                reviewRecord == .notAdmitted ? .evidenceNotAdmitted : .persistenceUnavailable
            if reviewRecord == .flushFailed {
                registry.failVerificationPass(
                    taskID: taskID, runID: run.id,
                    processGeneration: pass.processGeneration,
                    verificationPassID: pass.id,
                    codeState: anchor.code, environment: anchor.environment
                )
            }
            return finish(
                registry, taskID: taskID, identity: anchor,
                status: .notReady, escalation: .init(reason: reason, action: nil)
            )
        }
        guard reviewResult == .succeeded else {
            let escalation: Escalation
            let status: AgentTaskVerificationResult.Status
            if reviewResult == .requestedChanges {
                escalation = .init(reason: .reviewRequestedChanges, action: .resolveReviewFindings)
                status = .needsDecision
            } else {
                escalation = .init(reason: .reviewFailed, action: nil)
                status = .notReady
            }
            guard let readiness = registry.settleVerificationPass(
                taskID: taskID, runID: run.id,
                processGeneration: pass.processGeneration,
                verificationPassID: pass.id,
                codeState: anchor.code, environment: anchor.environment,
                makeCurrent: false
            ) else {
                return obsoleteResult(registry, pass: pass)
            }
            return finish(
                registry, taskID: taskID, identity: anchor,
                status: status, escalation: escalation, readiness: readiness
            )
        }

        let reprobe = await ports.probeIdentity(task)
        guard passIsCurrent(registry, pass: pass) else {
            return obsoleteResult(registry, pass: pass)
        }
        guard let reprobe, reprobe == anchor else {
            _ = registry.invalidateEvidence(
                taskID: taskID,
                codeState: reprobe?.code,
                environment: reprobe?.environment,
                runID: run.id
            )
            let saved = await durableFlush(registry, project: pass.project)
            guard passIsCurrent(registry, pass: pass) else {
                return obsoleteResult(registry, pass: pass)
            }
            if !saved {
                registry.failVerificationPass(
                    taskID: taskID, runID: run.id,
                    processGeneration: pass.processGeneration,
                    verificationPassID: pass.id,
                    codeState: reprobe?.code, environment: reprobe?.environment
                )
                return finish(
                    registry, taskID: taskID, identity: reprobe, status: .notReady,
                    escalation: .init(reason: .persistenceUnavailable, action: nil)
                )
            }
            return finish(
                registry, taskID: taskID, identity: reprobe, status: .notReady,
                escalation: .init(reason: .identityNotCurrent, action: nil)
            )
        }
        guard let readiness = registry.settleVerificationPass(
            taskID: taskID, runID: run.id,
            processGeneration: pass.processGeneration,
            verificationPassID: pass.id,
            codeState: anchor.code, environment: anchor.environment,
            makeCurrent: true
        ) else {
            return obsoleteResult(registry, pass: pass)
        }
        return finish(
            registry, taskID: taskID, identity: anchor,
            status: readiness.isReady ? .ready : .notReady,
            readiness: readiness
        )
    }

    // MARK: - Pass steps

    /// The required-check phase of the pass: a judgment observation to
    /// record, or the pass's terminal result.
    private enum CheckPhase {
        case judgment(AgentTaskCheckObservation)
        case terminal(AgentTaskVerificationResult)
    }

    @MainActor
    private func runRequiredChecks(
        _ registry: AgentTaskRegistry, task: AgentTask, pass: VerificationPass,
        anchor: AgentVerificationIdentitySnapshot
    ) async -> CheckPhase {
        for attempt in 1...(Self.maximumCheckRetries + 1) {
            guard passIsCurrent(registry, pass: pass) else {
                return .terminal(obsoleteResult(registry, pass: pass))
            }
            let grantIsCurrent = await ports.grantIsCurrent(task)
            guard passIsCurrent(registry, pass: pass) else {
                return .terminal(obsoleteResult(registry, pass: pass))
            }
            guard grantIsCurrent else {
                return .terminal(finish(
                    registry, taskID: pass.taskID, identity: anchor,
                    status: .notReady,
                    escalation: .init(reason: .checkGrantNotCurrent, action: .approveCheckGrant)
                ))
            }
            let request = AgentTaskVerificationCheckRequest(
                taskID: pass.taskID, runID: pass.runID, passID: pass.id,
                processGeneration: pass.processGeneration, expected: anchor, attempt: attempt
            )
            let observation: AgentTaskCheckObservation
            do {
                observation = try await ports.runRequiredChecks(request)
            } catch {
                guard passIsCurrent(registry, pass: pass) else {
                    return .terminal(obsoleteResult(registry, pass: pass))
                }
                if error is CancellationError {
                    return .terminal(finish(
                        registry, taskID: pass.taskID, identity: anchor, status: .cancelled
                    ))
                }
                continue
            }
            guard passIsCurrent(registry, pass: pass) else {
                return .terminal(obsoleteResult(registry, pass: pass))
            }
            if observation.requiredCancelled {
                return .terminal(finish(
                    registry, taskID: pass.taskID, identity: anchor, status: .cancelled
                ))
            }
            if observation.hasCompleteRequiredJudgment {
                guard observation.taskID == request.taskID,
                      observation.runID == request.runID,
                      observation.passID == request.passID,
                      observation.processGeneration == pass.processGeneration,
                      observation.preCodeState == anchor.code,
                      observation.postCodeState == anchor.code,
                      observation.environment == anchor.environment else {
                    return .terminal(finish(
                        registry, taskID: pass.taskID, identity: anchor, status: .notReady,
                        escalation: .init(reason: .identityNotCurrent, action: nil)
                    ))
                }
                return .judgment(observation)
            }
            // Non-judgment infrastructure results retry within the bound.
        }
        return .terminal(finish(
            registry, taskID: pass.taskID, identity: anchor,
            status: .needsDecision,
            escalation: .init(reason: .checksNotObserved, action: .rerunRequiredChecks)
        ))
    }

    private enum RecordStep: Equatable {
        case saved
        case notAdmitted
        case flushFailed
    }

    @MainActor
    private func record(
        _ registry: AgentTaskRegistry, _ fact: AgentTaskEvidenceFact,
        pass: VerificationPass
    ) async -> RecordStep {
        guard case .accepted = registry.recordEvidence(
            fact, taskID: pass.taskID, deferSettlement: true,
            verificationPassID: pass.id
        ) else {
            return .notAdmitted
        }
        return await durableFlush(registry, project: pass.project) ? .saved : .flushFailed
    }

    /// The pass may only continue for its exact current process incarnation.
    @MainActor
    private func passIsCurrent(
        _ registry: AgentTaskRegistry, pass: VerificationPass
    ) -> Bool {
        guard !Task.isCancelled,
              registry.verificationPassIsCurrent(pass.id, taskID: pass.taskID),
              let task = registry.task(for: pass.taskID),
              task.lifecycle != .dismissed,
              let latest = task.runs.last,
              latest.id == pass.runID,
              latest.process.processGeneration == pass.processGeneration else {
            return false
        }
        return !task.evidence.contains {
            $0.kind == .userCancellation && $0.runID == pass.runID
        }
    }

    @MainActor
    private func obsoleteResult(
        _ registry: AgentTaskRegistry, pass: VerificationPass
    ) -> AgentTaskVerificationResult {
        let gaps: [AgentTaskReadinessGap]
        if let task = registry.task(for: pass.taskID),
           let latest = task.runs.last,
           latest.id == pass.runID,
           latest.process.processGeneration == pass.processGeneration {
            gaps = [.cancelledAttempt]
        } else if registry.task(for: pass.taskID) == nil {
            gaps = [.noSettledAttempt]
        } else {
            gaps = [.supersededAttempt]
        }
        return AgentTaskVerificationResult(
            status: .cancelled,
            readiness: AgentTaskReadiness(isReady: false, gaps: gaps),
            reason: nil,
            requiredAction: nil
        )
    }

    @MainActor
    private func durableFlush(
        _ registry: AgentTaskRegistry, project: AgentTaskProjectIdentity
    ) async -> Bool {
        await registry.flushPersistence(project: project) == .saved
    }

    @MainActor
    private func finish(
        _ registry: AgentTaskRegistry,
        taskID: UUID,
        identity: AgentVerificationIdentitySnapshot?,
        status: AgentTaskVerificationResult.Status,
        escalation: Escalation? = nil,
        readiness: AgentTaskReadiness? = nil
    ) -> AgentTaskVerificationResult {
        var resolvedStatus = status
        var resolvedReadiness = readiness ?? registry.readiness(
            for: taskID,
            codeState: identity?.code,
            environment: identity?.environment
        )
        if resolvedStatus == .ready && !resolvedReadiness.isReady {
            resolvedStatus = .notReady
        }
        if resolvedStatus != .ready && resolvedReadiness.isReady {
            resolvedReadiness = AgentTaskReadiness(
                isReady: false, gaps: [.verificationNotCurrent]
            )
        }
        return AgentTaskVerificationResult(
            status: resolvedStatus,
            readiness: resolvedReadiness,
            reason: escalation?.reason,
            requiredAction: escalation?.action
        )
    }

    // MARK: - Fact construction

    static func validCriteria(_ criteria: String) -> Bool {
        !criteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && criteria.utf8.count <= maximumCriteriaBytes
            && !criteria.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    /// The check judgment fact: bound to the stable observed state, with the
    /// D4 operation fingerprints. Called only for `isJudgment` observations.
    private static func checkFact(
        for run: AgentTaskRun,
        observation: AgentTaskCheckObservation,
        now: Date
    ) -> AgentTaskEvidenceFact {
        AgentTaskEvidenceFact(
            kind: .independentCheck,
            runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified,
            result: observation.requiredSucceeded ? .succeeded : .failed,
            observedAt: now,
            codeState: observation.preCodeState,
            environment: observation.environment,
            preOperationCodeState: observation.preCodeState,
            postOperationCodeState: observation.postCodeState,
            checkExecutionID: observation.executionID
        )
    }

    /// The review judgment fact: bound to the stable observed state, with
    /// the D4 operation fingerprints. Called only for stable judgments.
    private static func reviewFact(
        for run: AgentTaskRun,
        result: AgentTaskEvidenceResult,
        observation: AgentTaskReviewObservation,
        now: Date
    ) -> AgentTaskEvidenceFact {
        AgentTaskEvidenceFact(
            kind: .reviewerOutcome,
            runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified,
            result: result,
            observedAt: now,
            codeState: observation.preCodeState,
            environment: observation.environment,
            reviewerSession: observation.reviewerSession,
            criteriaDigest: observation.criteriaDigest,
            preOperationCodeState: observation.preCodeState,
            postOperationCodeState: observation.postCodeState
        )
    }
}
