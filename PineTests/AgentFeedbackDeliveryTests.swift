//
//  AgentFeedbackDeliveryTests.swift
//  PineTests
//
//  Revision-bound feedback delivery contract (#1758): the pre-submission
//  capability gate, single dispatch and idempotency, distinguishable
//  delivery states, honest revision proof, and the end-to-end visual slice.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Revision-bound feedback delivery", .serialized)
struct AgentFeedbackDeliveryTests {
    // MARK: - Fixtures

    private func hex(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012X", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")
            ?? UUID()
    }

    private func codeState(_ tag: Character) -> AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "b", count: 40),
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

    private func candidate(
        run: UUID,
        outcome: AgentTaskOutcome = .success,
        code: AgentTaskCodeStateIdentity,
        recorded: Double
    ) -> AgentTaskResultSnapshot {
        AgentTaskResultSnapshot(
            runID: run,
            outcome: outcome,
            codeState: code,
            environment: environment,
            recordedAt: date(recorded)
        )
    }

    private var candidateA: AgentTaskResultSnapshot {
        candidate(run: uuid(10), code: codeState("a"), recorded: 120)
    }

    private var candidateB: AgentTaskResultSnapshot {
        candidate(run: uuid(11), code: codeState("b"), recorded: 170)
    }

    private var codeReference: AgentFeedbackReference {
        AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidateA,
            artifactKind: .code,
            anchor: .lineRange(path: "Pine/View.swift", start: 10, end: 20),
            userText: "SECRET range feedback",
            createdAt: date(150)
        )
    }

    private var visualReference: AgentFeedbackReference {
        AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidateA,
            artifactKind: .visualPreview,
            anchor: .capturedRegion(x: 4, y: 8, width: 200, height: 100),
            userText: "Make this header easier to read",
            attachments: [AgentFeedbackAttachment(
                id: uuid(50),
                kind: .image,
                captureBasis: .livePreviewObservation,
                sha256: hex("7"),
                byteCount: 123_456,
                label: "preview capture"
            )],
            createdAt: date(150)
        )
    }

    private var imageSupport: AgentFeedbackInputSupport {
        AgentFeedbackInputSupport(
            image: .init(maximumBytes: 1_048_576),
            textResource: .init(maximumBytes: nil),
            binaryBlob: .init(maximumBytes: nil)
        )
    }

    @MainActor
    private func makeTask() -> AgentTask {
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: "/tmp/pine-feedback",
                canonicalWorktreePath: "/tmp/pine-feedback"
            ),
            route: AgentTaskRoute(
                paneID: uuid(1),
                tabID: uuid(2),
                terminalID: uuid(2)
            ),
            origin: .discoveredInTerminal,
            observedAt: date(180)
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        task.runs = [
            AgentTaskRun(AgentTaskRunInput(
                id: uuid(10),
                terminalID: uuid(2),
                process: AgentProcessEvidence(
                    processIdentifier: 1_000,
                    processGeneration: 1,
                    startIdentifier: "run-0",
                    observedStartedAt: date(100),
                    startIsAuthoritative: true
                ),
                status: AgentTaskRunStatus(
                    state: .done,
                    liveness: .terminated,
                    observedAt: date(120)
                )
            )),
            AgentTaskRun(AgentTaskRunInput(
                id: uuid(11),
                terminalID: uuid(2),
                process: AgentProcessEvidence(
                    processIdentifier: 1_001,
                    processGeneration: 2,
                    startIdentifier: "run-1",
                    observedStartedAt: date(150),
                    startIsAuthoritative: true
                ),
                status: AgentTaskRunStatus(
                    state: .done,
                    liveness: .terminated,
                    observedAt: date(170)
                )
            ))
        ]
        task.evidence = [
            AgentTaskEvidenceFact(
                kind: .independentCheck,
                runID: uuid(10),
                processGeneration: 1,
                trust: .verified,
                result: .succeeded,
                observedAt: date(119),
                codeState: codeState("a"),
                environment: environment
            ),
            AgentTaskEvidenceFact(
                kind: .reviewerOutcome,
                runID: uuid(10),
                processGeneration: 1,
                trust: .verified,
                result: .succeeded,
                observedAt: date(119.5),
                codeState: codeState("a"),
                environment: environment
            ),
            AgentTaskEvidenceFact(
                kind: .independentCheck,
                runID: uuid(11),
                processGeneration: 2,
                trust: .verified,
                result: .succeeded,
                observedAt: date(169),
                codeState: codeState("b"),
                environment: environment
            ),
            AgentTaskEvidenceFact(
                kind: .reviewerOutcome,
                runID: uuid(11),
                processGeneration: 2,
                trust: .verified,
                result: .succeeded,
                observedAt: date(169.5),
                codeState: codeState("b"),
                environment: environment
            )
        ]
        task.updatedAt = date(180)
        task.lastActivityAt = date(180)
        return task
    }

    // MARK: - Acceptance 3 + audit: capability gate

    @Test("Unsupported image support preserves the draft and offers the explicit text-only path")
    func unsupportedImagePreservesDraft() {
        let draft = AgentFeedbackDraft(reference: visualReference)
        let gate = AgentFeedbackSubmissionGate.validate(visualReference, against: .none)

        #expect(!gate.isFullySupported)
        #expect(gate.rejections.first?.reason == .unsupportedKind)
        #expect(gate.textOnlyVariant != nil)

        let full = AgentFeedbackStateMachine.submit(draft: draft, support: .none, existing: [])
        #expect(full == .failure(.attachmentUnsupported(gate.rejections)))
        // The draft is preserved for the explicit text-only path.
        #expect(draft.reference.attachments.count == 1)

        let textOnly = AgentFeedbackStateMachine.submitTextOnly(
            draft: draft,
            rejections: gate.rejections,
            existing: []
        )
        guard case let .success(submission) = textOnly else {
            Issue.record("text-only submission should succeed: \(textOnly)")
            return
        }
        #expect(submission.reference.attachments.isEmpty)
        #expect(submission.reference.candidate == candidateA)
        #expect(submission.reference.anchor == .plainText)
        #expect(submission.disclosedOmissions.count == 1)
        #expect(submission.disclosedOmissions.first?.attachmentID == uuid(50))
    }

    @Test("A byte-limit overage is explained, not dropped silently")
    func byteLimitRejection() {
        let support = AgentFeedbackInputSupport(
            image: .init(maximumBytes: 1_024),
            textResource: .init(maximumBytes: nil),
            binaryBlob: .init(maximumBytes: nil)
        )
        let gate = AgentFeedbackSubmissionGate.validate(visualReference, against: support)
        #expect(gate.rejections.count == 1)
        #expect(gate.rejections.first?.reason == .exceedsByteLimit(limit: 1_024))
    }

    @Test("The gate validates images, text resources, and binary blobs against the transport")
    func gateCoversAllResourceKinds() {
        let reference = AgentFeedbackReference(
            taskID: uuid(10),
            candidate: candidateA,
            artifactKind: .plainText,
            anchor: .plainText,
            userText: "Three resources",
            attachments: [
                AgentFeedbackAttachment(id: uuid(51), kind: .image, sha256: hex("1"), byteCount: 10, label: "img"),
                AgentFeedbackAttachment(id: uuid(52), kind: .textResource, sha256: hex("2"), byteCount: 10, label: "txt"),
                AgentFeedbackAttachment(id: uuid(53), kind: .binaryBlob, sha256: hex("3"), byteCount: 10, label: "bin")
            ],
            createdAt: date(150)
        )
        #expect(reference.isValid)
        let support = AgentFeedbackInputSupport(
            image: .init(maximumBytes: 100),
            textResource: .init(maximumBytes: 100),
            binaryBlob: .init(maximumBytes: 5)
        )
        let gate = AgentFeedbackSubmissionGate.validate(reference, against: support)
        #expect(gate.rejections.map(\.attachmentID) == [uuid(53)])
        #expect(gate.rejections.first?.reason == .exceedsByteLimit(limit: 5))
    }

    // MARK: - Acceptance 4: single dispatch, duplicates, uncertain delivery

    @Test("Duplicate submission of the same feedback is fenced")
    func duplicateSubmissionFenced() {
        let draft = AgentFeedbackDraft(reference: codeReference)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft,
            support: .none,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        let again = AgentFeedbackStateMachine.submit(
            draft: draft,
            support: .none,
            existing: [submission]
        )
        #expect(again == .failure(.duplicateSubmission(submission.id)))
    }

    @Test("A definite failure allows one explicit retry under the same idempotency key")
    func failedRetryStableKey() {
        let draft = AgentFeedbackDraft(reference: codeReference)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft, support: .none,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        var failed = submission
        #expect(failed.state == .queued)
        let markFailed = failed.markFailed(.transportUnavailable)
        #expect(markFailed)
        #expect(failed.state == .failed(.transportUnavailable))
        // One explicit re-dispatch under the same idempotency key.
        let didRetry = failed.retry()
        #expect(didRetry)
        #expect(failed.state == .queued)
        #expect(failed.id == submission.id)
        let retryAgain = failed.retry()
        #expect(!retryAgain)
        // While the retry is queued, a resubmit of the same draft is fenced.
        let blocked = AgentFeedbackStateMachine.submit(
            draft: draft,
            support: .none,
            existing: [failed]
        )
        #expect(blocked == .failure(.duplicateSubmission(failed.id)))
        // A submission that only failed may be resubmitted: the provider
        // did not take it.
        var rejected = submission
        _ = rejected.markFailed(.providerRejected)
        let resubmit = AgentFeedbackStateMachine.submit(
            draft: draft,
            support: .none,
            existing: [rejected]
        )
        switch resubmit {
        case .success:
            break
        case let .failure(fence):
            Issue.record("resubmit after definite failure should succeed: \(fence)")
        }
    }

    @Test("Delivery-unknown is terminal and never retried blindly")
    func deliveryUnknownTerminal() {
        let draft = AgentFeedbackDraft(reference: codeReference)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft, support: .none,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        var unconfirmed = submission
        let unconfirmedResult = unconfirmed.cancel(dispatcherConfirmed: false)
        #expect(unconfirmedResult == .deliveryUnknown)
        #expect(unconfirmed.state.isTerminal)
        let retryAfterUnknown = unconfirmed.retry()
        #expect(!retryAfterUnknown)
        let failAfterUnknown = unconfirmed.markFailed(.transportUnavailable)
        #expect(!failAfterUnknown)
        // The same feedback cannot be re-queued while unknown.
        let again = AgentFeedbackStateMachine.submit(
            draft: draft,
            support: .none,
            existing: [unconfirmed]
        )
        #expect(again == .failure(.duplicateSubmission(unconfirmed.id)))

        var confirmed = submission
        let confirmedResult = confirmed.cancel(dispatcherConfirmed: true)
        #expect(confirmedResult == .cancelled)
        #expect(confirmed.state != unconfirmed.state)
    }

    @Test("A foreign or late receipt is fenced, never applied")
    func receiptFences() {
        let draft = AgentFeedbackDraft(reference: codeReference)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft, support: .none,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        var live = submission
        let foreign = AgentFeedbackDeliveryReceipt(submissionID: UUID())
        let foreignAdmission = live.apply(receipt: foreign)
        #expect(foreignAdmission == .fenced(.foreignReceipt))
        #expect(live.state == .queued)

        let matching = AgentFeedbackDeliveryReceipt(submissionID: submission.id)
        let matchingAdmission = live.apply(receipt: matching)
        #expect(matchingAdmission == .applied)
        #expect(live.state.isTerminal)
        let lateAdmission = live.apply(receipt: matching)
        #expect(lateAdmission == .fenced(.notQueued))
    }

    @Test("A receipt that ignored an attachment is never a complete delivery")
    func undeliveredAttachmentNeverShownSent() throws {
        let draft = AgentFeedbackDraft(reference: visualReference)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft, support: imageSupport,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        var live = submission
        let receipt = AgentFeedbackDeliveryReceipt(submissionID: submission.id, carriedAttachmentIDs: [])
        _ = live.apply(receipt: receipt)
        guard case let .delivered(outcome) = live.state else {
            Issue.record("expected delivered state")
            return
        }
        #expect(outcome.undeliveredAttachmentIDs == [uuid(50)])
        #expect(!outcome.isComplete)

        let full = AgentFeedbackDeliveryReceipt(
            submissionID: submission.id,
            carriedAttachmentIDs: [uuid(50)]
        )
        var complete = submission
        _ = complete.apply(receipt: full)
        guard case let .delivered(completeOutcome) = complete.state else {
            Issue.record("expected delivered state")
            return
        }
        #expect(completeOutcome.isComplete)
    }

    @Test("A delivered submission round-trips its state across relaunch")
    func relaunchPreservesDeliveryState() throws {
        let draft = AgentFeedbackDraft(reference: codeReference)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft, support: .none,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        var live = submission
        _ = live.apply(receipt: AgentFeedbackDeliveryReceipt(submissionID: submission.id))
        let data = try JSONEncoder().encode(live)
        let decoded = try JSONDecoder().decode(AgentFeedbackSubmission.self, from: data)
        #expect(decoded == live)
        #expect(decoded.state.isTerminal)
    }

    @Test("The dispatch request carries the stable idempotency key")
    func dispatchRequestKeys() {
        let draft = AgentFeedbackDraft(reference: codeReference)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft, support: .none,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        let request = submission.dispatchRequest
        #expect(request.submissionID == submission.id)
        #expect(request.taskID == submission.reference.taskID)
        #expect(request.reference == submission.reference)
        #expect(request.submittedAt == submission.submittedAt)
    }

    @Test("An obsolete anchor is explained at submit; the reference stays bound")
    func targetMissingAnchorStaysBound() {
        let draft = AgentFeedbackDraft(reference: codeReference)
        let result = AgentFeedbackStateMachine.submit(
            draft: draft,
            support: .none,
            anchorResolution: .targetMissing,
            existing: []
        )
        guard case let .success(submission) = result else {
            Issue.record("intentional older-result feedback must stay submittable: \(result)")
            return
        }
        #expect(submission.anchorResolutionAtSubmission == .targetMissing)
        #expect(submission.reference == codeReference)
    }

    // MARK: - Audit: revision/content identity

    @Test("Revision proof comes only from matching content identity")
    func revisionProof() throws {
        let draft = AgentFeedbackDraft(reference: visualReference)
        func delivered(
            observed: AgentFeedbackArtifactIdentity?
        ) throws -> AgentFeedbackSubmission {
            let submission = try AgentFeedbackStateMachine.submit(
                draft: draft,
                support: imageSupport,
                existing: []
            ).get()
            var live = submission
            _ = live.apply(receipt: AgentFeedbackDeliveryReceipt(
                submissionID: submission.id,
                carriedAttachmentIDs: [uuid(50)],
                observedArtifactIdentity: observed
            ))
            return live
        }

        #expect(try delivered(
            observed: AgentFeedbackArtifactIdentity(sha256: hex("7"), byteCount: 123_456)
        ).revisionProof == .contentVerified)
        #expect(try delivered(
            observed: AgentFeedbackArtifactIdentity(sha256: hex("8"), byteCount: 123_456)
        ).revisionProof == .mismatchClaimed)
        #expect(try delivered(observed: nil).revisionProof == .unproven)
        // A non-visual submission has no annotated artifact to prove.
        let codeSubmission = try AgentFeedbackStateMachine.submit(
            draft: AgentFeedbackDraft(reference: codeReference),
            support: .none,
            existing: []
        ).get()
        var codeLive = codeSubmission
        _ = codeLive.apply(receipt: AgentFeedbackDeliveryReceipt(submissionID: codeSubmission.id))
        #expect(codeLive.revisionProof == .unproven)
    }

    // MARK: - Acceptance 8: distinct outcome dimensions

    @Test("An agent 'addressed' report is neither acceptance nor verification")
    func resolutionDistinctFromAcceptanceAndVerification() {
        let draft = AgentFeedbackDraft(reference: codeReference)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft, support: .none,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        var live = submission
        let task = makeTask()
        #expect(live.isUnresolved)
        let addressed = live.noteAgentReportedAddressed()
        #expect(addressed)
        #expect(live.resolution == .agentReportedAddressed)
        #expect(live.isUnresolved)
        let repeatAddressed = live.noteAgentReportedAddressed()
        #expect(!repeatAddressed)
        let accepted = live.noteUserAcceptance()
        #expect(accepted)
        #expect(live.resolution == .acceptedByUser)
        #expect(!live.isUnresolved)
        let repeatAcceptance = live.noteUserAcceptance()
        #expect(!repeatAcceptance)
        let addressedAfterAcceptance = live.noteAgentReportedAddressed()
        #expect(!addressedAfterAcceptance)
        // The task's acceptance and verification dimensions are untouched:
        // they remain separate explicit facts.
        #expect(task.acceptanceState == .notAccepted)
        #expect(task.verificationState == .none)
    }

    @Test("The durable record is the fingerprint, never text or paths")
    func durableRecordIsContentFree() {
        let draft = AgentFeedbackDraft(reference: codeReference)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft, support: .none,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        let record = submission.durableRecord
        #expect(record.reference == submission.reference.fingerprint)
        #expect(record.reference.utf8.count == 64)
        #expect(!record.reference.contains("SECRET"))
        #expect(!record.reference.contains("Pine/View.swift"))
        #expect(record.codeState == candidateA.codeState)
        #expect(record.reference.utf8.count <= AgentTaskFeedbackRecord.maximumReferenceBytes)
    }

    // MARK: - Acceptance 1 + 6: the visual slice end to end

    @Test("Visual slice: capture, submit bound to the viewed revision, compare")
    func visualSliceEndToEnd() throws {
        let task = makeTask()
        var draft = AgentFeedbackDraft(reference: visualReference)

        // A newer candidate arrives while composing.
        draft.noteCandidateArrived(candidateB)
        #expect(draft.freshness == .superseded(latestRunID: candidateB.runID))

        // The gate passes with image support; submission stays bound to the
        // viewed revision.
        let gate = AgentFeedbackSubmissionGate.validate(visualReference, against: imageSupport)
        #expect(gate.isFullySupported)
        guard case let .success(submission) = AgentFeedbackStateMachine.submit(
            draft: draft, support: imageSupport,
            existing: []
        ) else {
            Issue.record("submit should succeed")
            return
        }
        #expect(submission.reference.candidate == candidateA)
        #expect(submission.dispatchRequest.submissionID == submission.id)

        // The receipt carries the image and proves the exact bytes.
        var live = submission
        _ = live.apply(receipt: AgentFeedbackDeliveryReceipt(
            submissionID: submission.id,
            carriedAttachmentIDs: [uuid(50)],
            observedArtifactIdentity: AgentFeedbackArtifactIdentity(
                sha256: hex("7"),
                byteCount: 123_456
            )
        ))
        #expect(live.revisionProof == .contentVerified)
        #expect(live.durableRecord.reference == visualReference.fingerprint)

        // The comparison: before is the retained capture of the viewed
        // candidate, after is the newer candidate. Both sides are checked
        // because their required evidence is bound to their own code state.
        let before = AgentRevisionComparisonSide(
            candidate: candidateA,
            evidence: .retainedCapture(sha256: hex("7"), byteCount: 123_456)
        )
        let after = AgentRevisionComparisonSide(
            candidate: candidateB,
            evidence: .retainedArtifact
        )
        #expect(before != nil)
        #expect(after != nil)
        guard let before, let after else {
            Issue.record("fixture sides should be constructible")
            return
        }
        let summary = AgentRevisionChangeSummary(
            agentSummary: "Kept the previous spacing, retained the new wording.",
            items: [AgentRevisionChangeItem(
                relativePath: "Pine/View.swift",
                kind: .modified,
                statistics: AgentCompletionDiffStatistics(
                    addedLineCount: 4,
                    removedLineCount: 2
                ),
                attribution: .agentReported
            )]
        )
        let comparison = try AgentRevisionComparisonBuilder.build(
            taskID: task.id,
            before: before,
            after: after,
            feedbackSubmissionID: submission.id,
            changesSinceFeedback: summary,
            in: task
        ).get()
        #expect(comparison.before.label(in: task).isReady)
        #expect(comparison.after.label(in: task).isReady)
        #expect(comparison.diffPaths == ["Pine/View.swift"])
        #expect(comparison.feedbackSubmissionID == submission.id)
    }
}
