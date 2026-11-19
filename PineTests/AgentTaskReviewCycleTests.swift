//
//  AgentTaskReviewCycleTests.swift
//  PineTests
//
//  Independent review and bounded correction (#1755): the reviewer
//  contract, verdict fencing, the three-round correction budget,
//  cancellation at every dispatch/settlement boundary, crash and relaunch
//  recovery, and attention projection.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Independent review and bounded correction", .serialized)
struct AgentTaskReviewCycleTests {
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

    private static let implementerSession = AgentVendorSessionIdentity(
        provider: "codex",
        opaqueIdentifier: "impl-session"
    )
    private static let reviewerSession = AgentVendorSessionIdentity(
        provider: "codex",
        opaqueIdentifier: "review-session"
    )

    private func letter(_ n: Int) -> Character {
        Character(UnicodeScalar(96 + n) ?? UnicodeScalar(97))
    }

    private func makeAttempt(
        seed: Int,
        state: AgentRunState = .executing,
        liveness: AgentRunLiveness = .live,
        now: Date
    ) -> AgentTaskRunInput {
        AgentTaskRunInput(
            id: uuid(seed + 200),
            terminalID: uuid(seed + 100),
            process: AgentProcessEvidence(
                processIdentifier: Int32(5_000 + seed),
                processGeneration: UInt64(seed),
                startIdentifier: "review-\(seed)",
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
        now: Date = Date(timeIntervalSince1970: 10_000),
        projectPath: String? = nil
    ) -> AgentTask {
        let context = AgentTaskBridgeContext(
            project: project(projectPath ?? "/tmp/pine-review-\(seed)"),
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: uuid(seed + 100),
                terminalID: uuid(seed + 100),
                availability: .available
            ),
            origin: .discoveredInTerminal,
            observedAt: now
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        var run = AgentTaskRun(makeAttempt(seed: seed, now: now))
        run.vendorIdentity = Self.implementerSession
        task.runs = [run]
        task.updatedAt = now
        task.lastActivityAt = now
        return task
    }

    private func plan(
        control: AgentTaskReviewerControl = .writeDisabledAtAdapter
    ) -> AgentTaskReviewPlan {
        AgentTaskReviewPlan(
            requestedOutcomeReference: "outcome-ref",
            criteriaVersion: "v1",
            checkPlanIdentity: "check-plan-1",
            reviewerControl: control
        )
    }

    @discardableResult
    private func begin(
        _ task: inout AgentTask,
        control: AgentTaskReviewerControl = .writeDisabledAtAdapter,
        cs: AgentTaskCodeStateIdentity
    ) -> Bool {
        AgentTaskReviewOrchestrator.beginCycle(
            task: &task,
            plan: plan(control: control),
            codeState: cs,
            environment: environment
        )
    }

    /// Binds the fixture reviewer session and issues one review dispatch.
    private func issueReview(
        _ task: inout AgentTask
    ) throws -> AgentTaskReviewDispatch {
        #expect(AgentTaskReviewOrchestrator.bindReviewerSession(task: &task, Self.reviewerSession))
        return try #require(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &task))
    }

    private func event(
        _ operation: UUID,
        passed: Bool,
        cs: AgentTaskCodeStateIdentity,
        session: AgentVendorSessionIdentity = Self.reviewerSession,
        reference: String? = nil,
        pre: AgentTaskCodeStateIdentity? = nil,
        post: AgentTaskCodeStateIdentity? = nil,
        at: Date,
        sequence: UInt64? = nil
    ) -> AgentTaskReviewOutcomeEvent {
        AgentTaskReviewOutcomeEvent(
            operationID: operation,
            reviewerSession: session,
            passed: passed,
            feedbackReference: reference,
            codeState: cs,
            preCodeState: pre ?? cs,
            postCodeState: post ?? cs,
            environment: environment,
            observedAt: at,
            sourceSequence: sequence
        )
    }

    /// The check executor's passing-check fact for the current candidate.
    private func checkPass(
        _ task: inout AgentTask,
        cs: AgentTaskCodeStateIdentity,
        at: Date,
        sequence: UInt64
    ) {
        guard let run = task.runs.last else { return }
        task.evidence.append(AgentTaskEvidenceFact(
            kind: .independentCheck,
            runID: run.id,
            processGeneration: run.process.processGeneration,
            trust: .verified,
            result: .succeeded,
            observedAt: at,
            codeState: cs,
            environment: environment,
            sourceSequence: sequence,
            preOperationCodeState: cs,
            postOperationCodeState: cs
        ))
    }

    /// Encode/decode round trip: the durable state across a relaunch.
    private func roundTrip(_ task: AgentTask) throws -> AgentTask {
        let data = try JSONEncoder().encode(task)
        return try JSONDecoder().decode(AgentTask.self, from: data)
    }

    private func isAccepted(_ admission: AgentTaskReviewAdmission) -> Bool {
        if case .accepted = admission { return true }
        return false
    }

    /// Drives a cycle to three returned corrections (round 3, awaiting
    /// feedback, no in-flight review).
    private func driveToRound3(
        _ seed: Int,
        now: Date = Date(timeIntervalSince1970: 10_000),
        projectPath: String? = nil
    ) throws -> AgentTask {
        var task = makeTask(seed: seed, now: now, projectPath: projectPath)
        var candidate = codeState("a")
        #expect(begin(&task, cs: candidate))
        var dispatch = try issueReview(&task)
        for revision in 0...2 {
            let at = now.addingTimeInterval(Double(revision) * 100)
            guard case .accepted(_, let grant, _) = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(
                    dispatch.operationID,
                    passed: false,
                    cs: candidate,
                    reference: "rev-\(seed)-\(revision)",
                    at: at,
                    sequence: UInt64(revision + 1)
                )
            ) else {
                Issue.record("drive: expected accepted at revision \(revision)")
                return task
            }
            let granted = try #require(grant)
            let next = codeState(letter(revision + 2))
            #expect(AgentTaskReviewOrchestrator.recordImplementerReturn(task: &task,
                operationID: granted.operationID,
                codeState: next,
                environment: environment
            ))
            candidate = next
            if revision < 2 {
                checkPass(&task, cs: candidate, at: at.addingTimeInterval(50), sequence: UInt64(revision + 10))
                dispatch = try issueReview(&task)
            }
        }
        return task
    }

    /// Drives a cycle to a reserved third correction (round 2, pending).
    private func driveToRound2Reserved(_ seed: Int) throws -> AgentTask {
        var task = makeTask(seed: seed)
        let now = Date(timeIntervalSince1970: 10_000)
        var candidate = codeState("a")
        #expect(begin(&task, cs: candidate))
        var dispatch = try issueReview(&task)
        for revision in 0...2 {
            let at = now.addingTimeInterval(Double(revision) * 100)
            guard case .accepted(_, let grant, _) = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(
                    dispatch.operationID,
                    passed: false,
                    cs: candidate,
                    reference: "res-\(seed)-\(revision)",
                    at: at,
                    sequence: UInt64(revision + 1)
                )
            ) else {
                Issue.record("drive: expected accepted at revision \(revision)")
                return task
            }
            if revision < 2 {
                let granted = try #require(grant)
                let next = codeState(letter(revision + 2))
                #expect(AgentTaskReviewOrchestrator.recordImplementerReturn(task: &task,
                    operationID: granted.operationID,
                    codeState: next,
                    environment: environment
                ))
                candidate = next
                checkPass(&task, cs: candidate, at: at.addingTimeInterval(50), sequence: UInt64(revision + 10))
                dispatch = try issueReview(&task)
            } else {
                // Revision 2: the third correction is reserved; stop before
                // its return persists.
                #expect(task.reviewCycle?.pending != nil)
            }
        }
        return task
    }

    // MARK: - Reviewer contract

    @Test("initial review pass produces reviewer evidence and finishes the cycle")
    func initialPass() throws {
        var task = makeTask(seed: 1)
        let cs = codeState("a")
        let run = try #require(task.runs.last)
        #expect(begin(&task, cs: cs))
        let dispatch = try issueReview(&task)
        #expect(dispatch.codeState == cs)
        #expect(dispatch.environment == environment)
        #expect(dispatch.criteriaVersion == "v1")
        #expect(dispatch.checkPlanIdentity == "check-plan-1")
        #expect(dispatch.reviewerControl == .writeDisabledAtAdapter)
        #expect(dispatch.runID == run.id)

        let at = Date(timeIntervalSince1970: 10_100)
        let admission = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
            event(dispatch.operationID, passed: true, cs: cs, at: at, sequence: 1)
        )
        #expect(admission == .accepted(
            evidence: AgentTaskEvidenceFact(
                kind: .reviewerOutcome,
                runID: run.id,
                processGeneration: run.process.processGeneration,
                trust: .verified,
                result: .succeeded,
                observedAt: at,
                codeState: cs,
                environment: environment,
                vendorSession: nil,
                sourceSequence: 1,
                preOperationCodeState: cs,
                postOperationCodeState: cs
            ),
            dispatch: nil,
            decision: nil
        ))
        let cycle = try #require(task.reviewCycle)
        #expect(cycle.state == .finished)
        #expect(cycle.round == 0)
        #expect(cycle.reviewEventKeys.count == 1)
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: task) == nil)
        #expect(cycle.isValid(for: task))
        // Evidence, not Ready: no completion claim or check exists yet.
        #expect(
            !AgentTaskLifecycleReducer.readiness(
                for: task, codeState: cs, environment: environment
            ).isReady
        )
    }

    @Test("a rejected round routes one correction to the implementer; the revision needs fresh checks")
    func rejectThenPass() throws {
        var task = makeTask(seed: 2)
        let csA = codeState("a")
        let csB = codeState("b")
        let run = try #require(task.runs.last)
        #expect(begin(&task, cs: csA))
        let d0 = try issueReview(&task)
        let t = Date(timeIntervalSince1970: 10_100)
        let admission = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
            event(d0.operationID, passed: false, cs: csA, reference: "finding-1", at: t, sequence: 1)
        )
        guard case .accepted(_, let correction0, let decision0) = admission else {
            Issue.record("expected accepted, got \(admission)")
            return
        }
        #expect(decision0 == nil)
        let grant0 = try #require(correction0)
        #expect(grant0.runID == run.id)
        #expect(grant0.terminalID == run.terminalID)
        let cycleID = try #require(task.reviewCycle).id
        #expect(grant0.cycleID == cycleID)
        #expect(grant0.feedbackReference == "finding-1")
        #expect(grant0.baselineCodeState == csA)
        // Reserved before dispatch: no second dispatch of any kind.
        #expect(task.reviewCycle?.state == .reserved)
        #expect(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &task) == nil)
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(d0.operationID, passed: false, cs: csA, reference: "finding-1", at: t, sequence: 1)
            ) == .fenced(.wrongState)
        )

        #expect(
            AgentTaskReviewOrchestrator.recordImplementerReturn(
                task: &task, operationID: grant0.operationID, codeState: csB,
                environment: environment
            )
        )
        #expect(task.reviewCycle?.round == 1)
        #expect(task.reviewCycle?.codeState == csB)

        // Re-review of the corrected candidate without a fresh passing
        // check is fenced; the in-flight review operation survives the
        // fence, so the same verdict is accepted once the check passes.
        let d1 = try issueReview(&task)
        let t1 = Date(timeIntervalSince1970: 10_200)
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(d1.operationID, passed: true, cs: csB, at: t1, sequence: 2)
            ) == .fenced(.checksNotCurrent)
        )
        checkPass(&task, cs: csB, at: t1.addingTimeInterval(1), sequence: 3)
        let secondAdmission = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
            event(d1.operationID, passed: true, cs: csB, at: t1, sequence: 2)
        )
        guard case .accepted(let fact, let correction1, let decision1) = secondAdmission else {
            Issue.record("expected accepted, got \(secondAdmission)")
            return
        }
        #expect(correction1 == nil)
        #expect(decision1 == nil)
        #expect(fact.result == .succeeded)
        #expect(fact.codeState == csB)
        #expect(task.reviewCycle?.state == .finished)
        #expect(task.reviewCycle?.round == 1)
    }

    @Test("the unresolved third revision escalates before any fourth automatic correction")
    func thirdUnresolvedEscalates() throws {
        var task = makeTask(seed: 3)
        #expect(begin(&task, cs: codeState("a")))
        var candidate = codeState("a")
        var dispatch = try issueReview(&task)
        for revision in 0...3 {
            let t = Date(timeIntervalSince1970: 10_100 + TimeInterval(revision) * 100)
            let admission = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(
                    dispatch.operationID,
                    passed: false,
                    cs: candidate,
                    reference: "finding-\(revision)",
                    at: t,
                    sequence: UInt64(revision + 1)
                )
            )
            guard case .accepted(_, let correction, let decision) = admission else {
                Issue.record("round \(revision): expected accepted, got \(admission)")
                return
            }
            if revision < 3 {
                let grant = try #require(correction)
                #expect(decision == nil)
                #expect(AgentTaskReviewOrchestrator.recordImplementerReturn(task: &task,
                    operationID: grant.operationID,
                    codeState: codeState(letter(revision + 1)),
                    environment: environment
                ))
                #expect(task.reviewCycle?.round == revision + 1)
                candidate = codeState(letter(revision + 1))
                checkPass(&task, cs: candidate, at: t.addingTimeInterval(50), sequence: UInt64(revision + 10))
                dispatch = try issueReview(&task)
            } else {
                #expect(correction == nil)
                #expect(decision?.blocker == .correctionLimit)
                #expect(decision?.round == 3)
                #expect(decision?.unresolvedFindingReference == "finding-3")
            }
        }
        #expect(task.reviewCycle?.state == .needsDecision)
        #expect(task.reviewCycle?.blocker == .correctionLimit)
        #expect(task.reviewCycle?.round == 3)
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: task) == .waitingInput)
        #expect(AgentTaskReviewOrchestrator.decisionRequest(for: task) != nil)
        // Nothing further can be dispatched from the escalated cycle.
        #expect(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &task) == nil)
        #expect(
            AgentTaskReviewOrchestrator.routeFailedCheck(task: &task, reference: "late-check",
                codeState: codeState("d"), environment: environment
            ) == nil
        )
    }

    @Test("duplicate feedback is single-flight and never double-counts a round")
    func duplicateFeedbackSingleFlight() throws {
        var task = makeTask(seed: 4)
        let csA = codeState("a")
        let csB = codeState("b")
        #expect(begin(&task, cs: csA))
        let d0 = try issueReview(&task)
        let t = Date(timeIntervalSince1970: 10_100)
        let reject = event(d0.operationID, passed: false, cs: csA, reference: "dup-ref", at: t, sequence: 1)
        let firstAdmission = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task, reject)
        guard case .accepted(_, let grant0, _) = firstAdmission else {
            Issue.record("expected accepted, got \(firstAdmission)")
            return
        }
        let firstGrant = try #require(grant0)
        // Replayed identical verdict: fenced, no second turn, no round.
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task, reject)
                == .fenced(.wrongState)
        )
        #expect(task.reviewCycle?.state == .reserved)
        #expect(task.reviewCycle?.round == 0)

        #expect(
            AgentTaskReviewOrchestrator.recordImplementerReturn(
                task: &task, operationID: firstGrant.operationID, codeState: csB,
                environment: environment
            )
        )
        #expect(task.reviewCycle?.round == 1)
        checkPass(&task, cs: csB, at: t.addingTimeInterval(50), sequence: 2)
        let d1 = try issueReview(&task)
        // The same reference replayed in a later round: accepted as a
        // verdict, but it neither reserves nor consumes another round.
        guard case .accepted(_, let second, let decision) = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
            event(d1.operationID, passed: false, cs: csB, reference: "dup-ref", at: t.addingTimeInterval(100), sequence: 3)
        ) else {
            Issue.record("expected accepted on round 1")
            return
        }
        #expect(second == nil)
        #expect(decision == nil)
        #expect(task.reviewCycle?.round == 1)
        #expect(task.reviewCycle?.state == .awaitingFeedback)

        let d2 = try issueReview(&task)
        // A stale operation from an earlier review is fenced while the new
        // review is in flight.
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(d0.operationID, passed: true, cs: csB, at: t.addingTimeInterval(150), sequence: 4)
            ) == .fenced(.staleReviewOperation)
        )
        // A new finding in the same round still reserves exactly once.
        guard case .accepted(_, let third, _) = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
            event(d2.operationID, passed: false, cs: csB, reference: "dup-ref-2", at: t.addingTimeInterval(160), sequence: 5)
        ) else {
            Issue.record("expected accepted on d2")
            return
        }
        #expect(third != nil)
        #expect(task.reviewCycle?.round == 1)
        #expect(task.reviewCycle?.state == .reserved)
    }

    @Test("wrong reviewer, task, or session fences; an implementer cannot self-review")
    func wrongIdentityFences() throws {
        let at = Date(timeIntervalSince1970: 10_100)
        let cs = codeState("a")
        var task = makeTask(seed: 5)
        // No cycle at all: no automatic path can create one.
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(uuid(1), passed: true, cs: cs, at: at)
            ) == .fenced(.noCycle)
        )
        #expect(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &task) == nil)
        #expect(
            AgentTaskReviewOrchestrator.recordImplementerReturn(task: &task, operationID: uuid(2), codeState: cs, environment: environment
            ) == false
        )
        #expect(
            AgentTaskReviewOrchestrator.routeFailedCheck(task: &task, reference: "r", codeState: cs, environment: environment
            ) == nil
        )

        #expect(begin(&task, cs: cs))
        let d = try issueReview(&task)
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(
                    d.operationID, passed: true, cs: cs,
                    session: AgentVendorSessionIdentity(
                        provider: "codex",
                        opaqueIdentifier: "someone-else"
                    ),
                    at: at
                )
            ) == .fenced(.foreignReviewerSession)
        )

        // Unbound session: no dispatch, no verdict.
        var unbound = makeTask(seed: 6)
        #expect(begin(&unbound, cs: cs))
        #expect(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &unbound) == nil)
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &unbound,
                event(uuid(9), passed: true, cs: cs, at: at)
            ) == .fenced(.unboundReviewerSession)
        )

        // An implementer submitting its own session as the reviewer. The
        // review is issued directly (not through the helper, which binds
        // the fixture reviewer session) and the verdict comes from the
        // implementer's own session identity.
        var selfReviewing = makeTask(seed: 7)
        #expect(begin(&selfReviewing, cs: cs))
        #expect(AgentTaskReviewOrchestrator.bindReviewerSession(task: &selfReviewing, Self.implementerSession))
        let ds = try #require(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &selfReviewing))
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &selfReviewing,
                event(ds.operationID, passed: true, cs: cs, session: Self.implementerSession, at: at)
            ) == .fenced(.implementerSession)
        )

        // The same journal carried by a different task value.
        var foreign = makeTask(seed: 8)
        foreign.reviewCycle = task.reviewCycle
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &foreign,
                event(d.operationID, passed: true, cs: cs, at: at)
            ) == .fenced(.wrongTask)
        )
    }

    @Test("a mutated candidate or an unenforced control blocks the review claim with a decision")
    func mutationAndControlBlock() throws {
        let at = Date(timeIntervalSince1970: 10_100)
        let cs = codeState("a")
        let csMutated = codeState("m")

        // A reviewer that wrote (pre != post): control failure, blocked.
        var task = makeTask(seed: 10)
        #expect(begin(&task, cs: cs))
        let d = try issueReview(&task)
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(d.operationID, passed: true, cs: cs, post: csMutated, at: at)
            ) == .blocked(.reviewerBoundaryUnavailable)
        )
        #expect(task.reviewCycle?.state == .needsDecision)
        #expect(task.reviewCycle?.blocker == .reviewerBoundaryUnavailable)
        #expect(task.evidence.isEmpty)
        #expect(
            AgentTaskReviewOrchestrator.decisionRequest(for: task)?.blocker
                == .reviewerBoundaryUnavailable
        )

        // Fingerprints that do not match the claimed candidate.
        var lying = makeTask(seed: 11)
        #expect(begin(&lying, cs: cs))
        let dl = try issueReview(&lying)
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &lying,
                event(dl.operationID, passed: true, cs: cs, pre: csMutated, post: csMutated, at: at)
            ) == .blocked(.reviewerBoundaryUnavailable)
        )

        // An honest review of a different candidate: fenced, not escalated.
        var stale = makeTask(seed: 12)
        #expect(begin(&stale, cs: cs))
        let dstale = try issueReview(&stale)
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &stale,
                event(dstale.operationID, passed: true, cs: csMutated, at: at)
            ) == .fenced(.staleCandidate)
        )
        #expect(stale.reviewCycle?.state == .awaitingFeedback)

        // A non-enforced control never admits a verdict, even a perfect
        // one: the claim is blocked with a required decision at begin.
        var prompt = makeTask(seed: 13)
        #expect(begin(&prompt, control: .promptOnly, cs: cs))
        #expect(prompt.reviewCycle?.state == .needsDecision)
        #expect(prompt.reviewCycle?.blocker == .reviewerBoundaryUnavailable)
        #expect(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &prompt) == nil)
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: prompt) == .waitingInput)
    }

    @Test("cancellation fences every dispatch and settlement boundary")
    func cancellationBoundaries() throws {
        let at = Date(timeIntervalSince1970: 10_100)
        let cs = codeState("a")

        // Review in flight.
        var task = makeTask(seed: 20)
        #expect(begin(&task, cs: cs))
        let d = try issueReview(&task)
        #expect(AgentTaskReviewOrchestrator.requestCancellation(task: &task))
        #expect(task.reviewCycle?.state == .cancellationRequested)
        #expect(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &task) == nil)
        #expect(
            AgentTaskReviewOrchestrator.routeFailedCheck(task: &task, reference: "c1", codeState: cs, environment: environment
            ) == nil
        )
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(d.operationID, passed: true, cs: cs, at: at)
            ) == .fenced(.wrongState)
        )
        #expect(AgentTaskReviewOrchestrator.confirmCancellation(task: &task))
        #expect(task.reviewCycle?.state == .cancelled)
        // A late success after cancellation never settles anything.
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
                event(d.operationID, passed: true, cs: cs, at: at)
            ) == .fenced(.wrongState)
        )
        #expect(task.evidence.isEmpty)
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: task) == nil)
        #expect(AgentTaskReviewOrchestrator.requestCancellation(task: &task) == false)
        #expect(AgentTaskReviewOrchestrator.confirmCancellation(task: &task) == false)

        // Cancellation while a correction is pending: the reservation stays
        // preserved history, never re-dispatched.
        var pending = makeTask(seed: 21)
        #expect(begin(&pending, cs: cs))
        let dp = try issueReview(&pending)
        guard case .accepted(_, let grant, _) = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &pending,
            event(dp.operationID, passed: false, cs: cs, reference: "find-b", at: at, sequence: 1)
        ) else {
            Issue.record("expected a correction grant")
            return
        }
        let granted = try #require(grant)
        #expect(AgentTaskReviewOrchestrator.requestCancellation(task: &pending))
        #expect(AgentTaskReviewOrchestrator.recordImplementerReturn(task: &pending,
            operationID: granted.operationID,
            codeState: codeState("b"),
            environment: environment
        ) == false)
        #expect(AgentTaskReviewOrchestrator.confirmCancellation(task: &pending))
        let cycle = try #require(pending.reviewCycle)
        #expect(cycle.state == .cancelled)
        #expect(cycle.pending != nil)
        #expect(cycle.round == 0)
        #expect(cycle.isValid(for: pending))

        // Cancellation from an escalation keeps the blocker.
        var escalated = makeTask(seed: 22)
        #expect(begin(&escalated, control: .cwdIsolation, cs: cs))
        #expect(AgentTaskReviewOrchestrator.requestCancellation(task: &escalated))
        #expect(AgentTaskReviewOrchestrator.confirmCancellation(task: &escalated))
        #expect(escalated.reviewCycle?.state == .cancelled)
        #expect(escalated.reviewCycle?.blocker == .reviewerBoundaryUnavailable)
    }

    // MARK: - Crashes and relaunch

    @Test("crashes across reservation, return, and evidence boundaries reconcile without resend")
    func crashBoundaries() throws {
        let at = Date(timeIntervalSince1970: 10_100)
        let cs = codeState("a")
        let csB = codeState("b")

        // Crash after the reservation persisted, before the dispatch was
        // delivered: delivery is unestablished → decision, no resend.
        var task = makeTask(seed: 30)
        #expect(begin(&task, cs: cs))
        let d = try issueReview(&task)
        guard case .accepted(_, let grant, _) = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
            event(d.operationID, passed: false, cs: cs, reference: "crash-ref", at: at, sequence: 1)
        ) else {
            Issue.record("expected a correction grant")
            return
        }
        let granted = try #require(grant)
        var restored = try roundTrip(task)
        let decision = AgentTaskReviewOrchestrator.reconcileRestoredCycle(task: &restored)
        #expect(decision?.blocker == .deliveryUnknown)
        #expect(restored.reviewCycle?.state == .needsDecision)
        #expect(restored.reviewCycle?.pending != nil)
        #expect(restored.reviewCycle?.round == 0)
        #expect(
            AgentTaskReviewOrchestrator.recordImplementerReturn(task: &restored,
                operationID: granted.operationID,
                codeState: csB,
                environment: environment
            ) == false
        )
        #expect(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &restored) == nil)

        // Crash after the return persisted, before check settlement: the
        // round survives and the cycle continues from the revision.
        var continued = makeTask(seed: 31)
        #expect(begin(&continued, cs: cs))
        let dc = try issueReview(&continued)
        guard case .accepted(_, let grantC, _) = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &continued,
            event(dc.operationID, passed: false, cs: cs, reference: "cont-ref", at: at, sequence: 1)
        ) else {
            Issue.record("expected a correction grant")
            return
        }
        let grantedC = try #require(grantC)
        #expect(AgentTaskReviewOrchestrator.recordImplementerReturn(task: &continued,
            operationID: grantedC.operationID,
            codeState: csB,
            environment: environment
        ))
        var midSaved = try roundTrip(continued)
        #expect(midSaved.reviewCycle?.round == 1)
        #expect(midSaved.reviewCycle?.codeState == csB)
        #expect(AgentTaskReviewOrchestrator.reconcileRestoredCycle(task: &midSaved) == nil)
        checkPass(&midSaved, cs: csB, at: at.addingTimeInterval(50), sequence: 2)
        let d2 = try issueReview(&midSaved)
        #expect(
            isAccepted(
                AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &midSaved,
                    event(d2.operationID, passed: true, cs: csB, at: at.addingTimeInterval(100), sequence: 3)
                )
            )
        )
        #expect(midSaved.reviewCycle?.state == .finished)

        // Crash before the review evidence write: the re-delivered verdict
        // is accepted again, and the produced fact carries the same event
        // identity, so the registry's admission fences any double record.
        var fresh = makeTask(seed: 32)
        #expect(begin(&fresh, cs: cs))
        let df = try issueReview(&fresh)
        let ev = event(df.operationID, passed: true, cs: cs, at: at, sequence: 1)
        var inMemory = fresh
        guard case .accepted(let firstFact, _, _) =
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &inMemory, ev)
        else {
            Issue.record("expected accepted on the in-memory copy")
            return
        }
        var replayed = try roundTrip(fresh)
        #expect(replayed.reviewCycle?.reviewEventKeys.isEmpty == true)
        guard case .accepted(let secondFact, _, _) =
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &replayed, ev)
        else {
            Issue.record("expected accepted on the replayed copy")
            return
        }
        #expect(secondFact.eventIdentity == firstFact.eventIdentity)
        #expect(replayed.reviewCycle == inMemory.reviewCycle)
    }

    @Test("the exact third-round boundary holds before and after a relaunch")
    func thirdRoundBoundarySurvivesRelaunch() throws {
        let at = Date(timeIntervalSince1970: 40_000)
        var live = try driveToRound3(40)
        #expect(live.reviewCycle?.round == 3)
        #expect(live.reviewCycle?.state == .awaitingFeedback)
        var relaunched = try roundTrip(live)
        #expect(relaunched.reviewCycle == live.reviewCycle)
        #expect(AgentTaskReviewOrchestrator.reconcileRestoredCycle(task: &relaunched) == nil)

        let dl = try issueReview(&live)
        let dr = try issueReview(&relaunched)
        let el = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &live,
            event(dl.operationID, passed: false, cs: codeState("d"), reference: "final", at: at, sequence: 9)
        )
        let er = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &relaunched,
            event(dr.operationID, passed: false, cs: codeState("d"), reference: "final", at: at, sequence: 9)
        )
        guard case .accepted(_, let cl, let dlDecision) = el,
              case .accepted(_, let cr, let drDecision) = er else {
            Issue.record("expected accepted on both sides: \(el) / \(er)")
            return
        }
        #expect(cl == nil)
        #expect(cr == nil)
        #expect(dlDecision?.blocker == .correctionLimit)
        #expect(drDecision?.blocker == .correctionLimit)
        #expect(dlDecision?.round == 3)
        #expect(drDecision?.round == 3)
        #expect(live.reviewCycle?.state == .needsDecision)
        #expect(relaunched.reviewCycle?.state == .needsDecision)
        #expect(live.reviewCycle?.id == relaunched.reviewCycle?.id)
        #expect(live.reviewCycle?.round == 3)
        #expect(relaunched.reviewCycle?.round == 3)

        // Uncertain delivery at the boundary: a persisted third reservation
        // relaunches as deliveryUnknown — never a fourth automatic
        // correction, never a resend.
        var inFlight = try driveToRound2Reserved(41)
        #expect(inFlight.reviewCycle?.pending != nil)
        #expect(inFlight.reviewCycle?.round == 2)
        var inFlightRestored = try roundTrip(inFlight)
        let decision = AgentTaskReviewOrchestrator.reconcileRestoredCycle(task: &inFlightRestored)
        #expect(decision?.blocker == .deliveryUnknown)
        #expect(inFlightRestored.reviewCycle?.state == .needsDecision)
        #expect(inFlightRestored.reviewCycle?.round == 2)
        #expect(inFlightRestored.reviewCycle?.pending != nil)
        #expect(AgentTaskReviewOrchestrator.issueReviewDispatch(task: &inFlightRestored) == nil)
    }

    @Test("only explicit user intent starts a new cycle; stale events cannot settle it")
    func explicitNewCycle() throws {
        let at = Date(timeIntervalSince1970: 50_000)
        let old = codeState("a")
        let freshCs = codeState("f")
        var escalated = makeTask(seed: 50)
        #expect(begin(&escalated, control: .promptOnly, cs: old))
        #expect(escalated.reviewCycle?.state == .needsDecision)
        let firstID = try #require(escalated.reviewCycle?.id)

        // Explicit user continuation: a new cycle on the revised candidate.
        #expect(begin(&escalated, cs: freshCs))
        let cycle = try #require(escalated.reviewCycle)
        #expect(cycle.id != firstID)
        #expect(cycle.round == 0)
        #expect(cycle.codeState == freshCs)
        let d = try issueReview(&escalated)
        // A late verdict for an old operation is fenced...
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &escalated,
                event(uuid(777), passed: true, cs: old, at: at)
            ) == .fenced(.staleReviewOperation)
        )
        // ...and so is a late verdict bound to the old candidate.
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &escalated,
                event(d.operationID, passed: true, cs: old, at: at.addingTimeInterval(1))
            ) == .fenced(.staleCandidate)
        )
        // The current review passes and settles the new candidate.
        #expect(
            isAccepted(
                AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &escalated,
                    event(d.operationID, passed: true, cs: freshCs, at: at.addingTimeInterval(2))
                )
            )
        )
        #expect(escalated.reviewCycle?.state == .finished)
        #expect(escalated.reviewCycle?.round == 0)

        // In-flight work blocks an explicit re-begin: the outgoing journal
        // is reconciled or cancelled first, never silently discarded.
        var reservedTask = makeTask(seed: 51)
        #expect(begin(&reservedTask, cs: old))
        let dr = try issueReview(&reservedTask)
        #expect(isAccepted(AgentTaskReviewOrchestrator.acceptReviewerOutcome(
            task: &reservedTask,
            event(dr.operationID, passed: false, cs: old, reference: "re-begin", at: at, sequence: 1)
        )))
        #expect(reservedTask.reviewCycle?.state == .reserved)
        #expect(begin(&reservedTask, cs: freshCs) == false)
        #expect(reservedTask.reviewCycle?.state == .reserved)
        var reviewingTask = makeTask(seed: 52)
        #expect(begin(&reviewingTask, cs: old))
        _ = try issueReview(&reviewingTask)
        #expect(reviewingTask.reviewCycle?.pendingReviewOperation != nil)
        #expect(begin(&reviewingTask, cs: freshCs) == false)
        #expect(reviewingTask.reviewCycle?.pendingReviewOperation != nil)
    }

    @Test("restoration starts nothing and releases a lost review dispatch for explicit re-issue")
    func restorationStartsNothing() throws {
        let at = Date(timeIntervalSince1970: 80_000)
        let cs = codeState("a")
        var task = makeTask(seed: 80)
        #expect(begin(&task, cs: cs))
        #expect(AgentTaskReviewOrchestrator.bindReviewerSession(task: &task, Self.reviewerSession))
        // A healthy cycle reconciles to nothing.
        #expect(AgentTaskReviewOrchestrator.reconcileRestoredCycle(task: &task) == nil)
        #expect(task.reviewCycle?.state == .awaitingFeedback)

        let lost = try issueReview(&task)
        var relaunch = try roundTrip(task)
        #expect(AgentTaskReviewOrchestrator.reconcileRestoredCycle(task: &relaunch) == nil)
        #expect(relaunch.reviewCycle?.pendingReviewOperation == nil)
        #expect(relaunch.reviewCycle?.state == .awaitingFeedback)
        let again = try issueReview(&relaunch)
        #expect(again.operationID != lost.operationID)
        #expect(
            AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &relaunch,
                event(lost.operationID, passed: true, cs: cs, at: at)
            ) == .fenced(.staleReviewOperation)
        )
        #expect(
            isAccepted(
                AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &relaunch,
                    event(again.operationID, passed: true, cs: cs, at: at.addingTimeInterval(1))
                )
            )
        )
    }

    @Test("check-only failures share the correction budget and never loop")
    func checkFailuresBounded() throws {
        var task = makeTask(seed: 70)
        var cs = codeState("a")
        #expect(begin(&task, cs: cs))
        var grant = try #require(AgentTaskReviewOrchestrator.routeFailedCheck(task: &task, reference: "chk-0", codeState: cs, environment: environment
        ))
        #expect(task.reviewCycle?.state == .reserved)
        #expect(grant.feedbackReference == "chk-0")
        // Single flight: no second dispatch while one is pending...
        #expect(
            AgentTaskReviewOrchestrator.routeFailedCheck(task: &task, reference: "chk-0b", codeState: cs, environment: environment
            ) == nil
        )
        // ...and a stale failing check for an older candidate routes nowhere.
        #expect(
            AgentTaskReviewOrchestrator.routeFailedCheck(task: &task, reference: "chk-stale",
                codeState: codeState("z"), environment: environment
            ) == nil
        )
        for revision in 0...2 {
            let next = codeState(letter(revision + 1))
            #expect(AgentTaskReviewOrchestrator.recordImplementerReturn(task: &task,
                operationID: grant.operationID,
                codeState: next,
                environment: environment
            ))
            cs = next
            #expect(task.reviewCycle?.round == revision + 1)
            if revision < 2 {
                grant = try #require(
                    AgentTaskReviewOrchestrator.routeFailedCheck(
                        task: &task, reference: "chk-\(revision + 1)",
                        codeState: cs, environment: environment
                    )
                )
            }
        }
        // Round 3, three check-driven corrections: the next failing check
        // cannot route — the limit escalates before a fourth correction.
        #expect(
            AgentTaskReviewOrchestrator.routeFailedCheck(task: &task, reference: "chk-3", codeState: cs, environment: environment
            ) == nil
        )
        #expect(task.reviewCycle?.state == .needsDecision)
        #expect(task.reviewCycle?.blocker == .correctionLimit)
        #expect(task.reviewCycle?.round == 3)
        #expect(
            AgentTaskReviewOrchestrator.decisionRequest(for: task)?
                .unresolvedFindingReference == "chk-2"
        )
    }

    @Test("intermediate review activity stays inside the task; only a decision creates attention")
    func attentionProjection() throws {
        let at = Date(timeIntervalSince1970: 60_000)
        let cs = codeState("a")
        var task = makeTask(seed: 60)
        #expect(task.attention == .none)
        #expect(begin(&task, cs: cs))
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: task) == nil)
        let d = try issueReview(&task)
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: task) == nil)
        guard case .accepted(_, let grant, _) = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &task,
            event(d.operationID, passed: false, cs: cs, reference: "att-1", at: at, sequence: 1)
        ) else {
            Issue.record("expected a correction grant")
            return
        }
        let granted = try #require(grant)
        // In-flight correction: still no attention, and the orchestrator
        // never writes task.attention itself.
        #expect(granted.feedbackReference == "att-1")
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: task) == nil)
        #expect(task.attention == .none)
        #expect(
            AgentTaskReviewOrchestrator.recordImplementerReturn(task: &task,
                operationID: granted.operationID,
                codeState: codeState("b"),
                environment: environment
            )
        )
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: task) == nil)

        // Only an actionable needs-decision projects waiting input.
        var escalated = makeTask(seed: 61)
        #expect(begin(&escalated, control: .unspecified, cs: cs))
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: escalated) == .waitingInput)
        var cancelled = makeTask(seed: 62)
        #expect(begin(&cancelled, cs: cs))
        #expect(AgentTaskReviewOrchestrator.requestCancellation(task: &cancelled))
        #expect(AgentTaskReviewOrchestrator.confirmCancellation(task: &cancelled))
        #expect(AgentTaskReviewOrchestrator.reviewAttention(for: cancelled) == nil)
    }

    @Test("the review cycle persists, survives a store reload, and a corrupt journal is rejected")
    func cyclePersistence() async throws {
        let fixture = try ReviewCyclePersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let fault = ArmedCycleFault()
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                faultInjector: PersistenceFaultInjector(injection: { storeKind, phase in
                    try fault.throwWhileArmed(store: storeKind, phase: phase)
                })
            )
        )
        let cs = codeState("a")
        let csB = codeState("b")

        // The reserved state (dispatch persistence) and the post-return
        // state both survive a store round trip.
        var reserved = makeTask(seed: 90, now: Date(), projectPath: fixture.project.path)
        #expect(begin(&reserved, cs: cs))
        let dr = try issueReview(&reserved)
        // Millisecond-aligned: the store persists dates with millisecond precision.
        let at = Date(timeIntervalSince1970: 50_000.5)
        guard case .accepted(_, let grant, _) = AgentTaskReviewOrchestrator.acceptReviewerOutcome(task: &reserved,
            event(dr.operationID, passed: false, cs: cs, reference: "res-ref", at: at, sequence: 1)
        ) else {
            Issue.record("expected a correction grant")
            return
        }
        #expect(reserved.reviewCycle?.state == .reserved)
        #expect(await store.save(tasks: [reserved], project: identity) == .saved(taskCount: 1))
        let reloadedReserved = await store.load(project: identity)
        #expect(reloadedReserved.status == .loaded)
        #expect(reloadedReserved.tasks.first?.reviewCycle == reserved.reviewCycle)

        var continued = try #require(reloadedReserved.tasks.first)
        #expect(AgentTaskReviewOrchestrator.recordImplementerReturn(task: &continued,
            operationID: try #require(grant).operationID,
            codeState: csB,
            environment: environment
        ))
        #expect(continued.reviewCycle?.round == 1)
        #expect(await store.save(tasks: [continued], project: identity) == .saved(taskCount: 1))
        let reloadedContinued = await store.load(project: identity)
        #expect(reloadedContinued.tasks.first?.reviewCycle == continued.reviewCycle)

        // A corrupted journal (a state that contradicts its reservation)
        // is rejected fail-closed.
        let tampered = try tamperCycleState(
            reloadedContinued.tasks.first ?? continued,
            to: .reserved
        )
        #expect(
            await store.save(tasks: [tampered], project: identity)
                == .rejected(.invalidMetadata)
        )

        // Cancellation with a review in flight is persistable: the
        // in-flight marker is released when the request is made, so the
        // journal stays structurally valid.
        var cancelling = makeTask(seed: 92, now: Date(), projectPath: fixture.project.path)
        #expect(begin(&cancelling, cs: cs))
        _ = try issueReview(&cancelling)
        #expect(AgentTaskReviewOrchestrator.requestCancellation(task: &cancelling))
        #expect(cancelling.reviewCycle?.state == .cancellationRequested)
        #expect(cancelling.reviewCycle?.pendingReviewOperation == nil)
        #expect(cancelling.reviewCycle?.isValid(for: cancelling) == true)
        #expect(await store.save(tasks: [cancelling], project: identity) == .saved(taskCount: 1))
        let reloadedCancelling = await store.load(project: identity)
        #expect(reloadedCancelling.status == .loaded)
        #expect(reloadedCancelling.tasks.first?.reviewCycle == cancelling.reviewCycle)

        // (a) An armed write fault at the round-3 transition: the save is
        // rejected, the file stays byte-identical to the pre-transition
        // state, and a fresh load recovers that state.
        var terminal = try driveToRound3(
            93,
            now: Date(timeIntervalSince1970: 60_000),
            projectPath: fixture.project.path
        )
        #expect(terminal.reviewCycle?.round == 3)
        #expect(terminal.reviewCycle?.state == .awaitingFeedback)
        #expect(await store.save(tasks: [terminal], project: identity) == .saved(taskCount: 1))
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let beforeTransition = try Data(contentsOf: file)
        let preCycle = try #require(terminal.reviewCycle)
        let tDispatch = try issueReview(&terminal)
        fault.arm()
        #expect(
            isAccepted(
                AgentTaskReviewOrchestrator.acceptReviewerOutcome(
                    task: &terminal,
                    event(
                        tDispatch.operationID,
                        passed: false,
                        cs: codeState("d"),
                        reference: "arm-final",
                        at: Date(timeIntervalSince1970: 60_000.5),
                        sequence: 9
                    )
                )
            )
        )
        #expect(terminal.reviewCycle?.state == .needsDecision)
        #expect(terminal.reviewCycle?.blocker == .correctionLimit)
        #expect(await store.save(tasks: [terminal], project: identity) == .rejected(.storageLimit))
        #expect(try Data(contentsOf: file) == beforeTransition)
        let crashed = await store.load(project: identity)
        #expect(crashed.status == .loaded)
        #expect(crashed.tasks.first?.reviewCycle == preCycle)
        fault.disarm()

        // (b) With the fault gone the round-3 terminal state publishes
        // atomically, and a fresh load reads it back consistently with no
        // reconciliation change.
        #expect(await store.save(tasks: [terminal], project: identity) == .saved(taskCount: 1))
        let reloadedTerminal = await store.load(project: identity)
        #expect(reloadedTerminal.status == .loaded)
        var restoredTerminal = try #require(reloadedTerminal.tasks.first)
        #expect(restoredTerminal.reviewCycle == terminal.reviewCycle)
        #expect(restoredTerminal.reviewCycle?.state == .needsDecision)
        #expect(restoredTerminal.reviewCycle?.blocker == .correctionLimit)
        #expect(AgentTaskReviewOrchestrator.reconcileRestoredCycle(task: &restoredTerminal) == nil)
    }

    /// Encodes the task, flips the journal's state, and decodes the result.
    private func tamperCycleState(
        _ task: AgentTask,
        to state: AgentTaskCorrectionCycle.State
    ) throws -> AgentTask {
        guard var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(task)
        ) as? [String: Any],
        var cycleJSON = json["reviewCycle"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFileError)
        }
        cycleJSON["state"] = state.rawValue
        json["reviewCycle"] = cycleJSON
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(AgentTask.self, from: data)
    }
}

// MARK: - Persistence fixture

/// Mirrors the lifecycle suite's fixture: a clean 0700 user-owned root so
/// the store can create its private 0600 storage without inherited ACLs.
private final class ReviewCyclePersistenceFixture {
    let project: URL

    private let root: URL
    let storage: URL

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PineReviewCycle-\(UUID().uuidString)")
        project = root.appendingPathComponent("project", isDirectory: true)
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

/// One armed/diseased write fault for the agent-task store, mirroring the
/// lifecycle suite's pattern: armed, it makes every matching checkpoint
/// throw; disarmed, it is inert.
nonisolated private final class ArmedCycleFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private let phase: PersistenceWritePhase

    init(phase: PersistenceWritePhase = .beforeAtomicReplace) {
        self.phase = phase
    }

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
    }

    func throwWhileArmed(
        store: PersistenceStoreKind,
        phase: PersistenceWritePhase
    ) throws {
        lock.lock()
        let shouldFire = armed
        lock.unlock()
        guard shouldFire, store == .agentTask, phase == self.phase else {
            return
        }
        throw PersistenceFailureKind.noSpace
    }
}
