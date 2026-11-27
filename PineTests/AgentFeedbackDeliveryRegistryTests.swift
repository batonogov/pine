//
//  AgentFeedbackDeliveryRegistryTests.swift
//  PineTests
//
//  The registry-level feedback API (#1758): the durable record and the
//  new-attempt transition come before the one dispatch; the same feedback
//  cannot make two revisions; a definite failure gets one explicit retry;
//  delivery-unknown is never retried; restoration never re-sends.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Revision-bound feedback delivery through the registry", .serialized)
struct AgentFeedbackDeliveryRegistryTests {
    private var code: AgentTaskCodeStateIdentity { AgentFeedbackTestSupport.code }
    private var environment: AgentTaskEnvironmentIdentity { AgentFeedbackTestSupport.environment }

    @Test("Recording persists the submission and the new-attempt transition before any dispatch")
    func recordIsDurableBeforeDispatch() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)

        let record = try await harness.registry.recordFeedbackSubmission(submission).get()

        #expect(record.id == submission.id)
        #expect(record.state == .queued)
        // A fresh reader of the same store sees record and transition.
        let stored = try #require(await harness.storedTasks().first)
        let storedRecord = try #require(stored.feedbackSubmissions.first)
        #expect(storedRecord.id == submission.id)
        #expect(storedRecord.fingerprint == submission.fingerprint)
        #expect(storedRecord.candidate.runID == submission.reference.candidate.runID)
        #expect(storedRecord.state == .queued)
        #expect(stored.revisions.map(\.feedbackReference) == [submission.fingerprint])
        #expect(stored.candidateGeneration == 1)
        #expect(AgentTaskContinuation.phase(for: stored) == .revisionPending)
        #expect(stored.verificationState == .stale)
        #expect(stored.acceptanceState == .notAccepted)
        // The commented result is no longer presented as current Ready.
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: stored, codeState: code, environment: environment
        ).isReady)
        // History stays attached to the exact commented revision: the run,
        // code-state, and environment identities survive the store round
        // trip (the store may re-derive the recorded timestamp itself).
        if let expected = harness.task.reviewedSnapshot {
            #expect(stored.reviewedSnapshot?.runID == expected.runID)
            #expect(stored.reviewedSnapshot?.codeState == expected.codeState)
            #expect(stored.reviewedSnapshot?.environment == expected.environment)
        }
    }

    @Test("One dispatch delivers once; repeated and re-entrant dispatches are fenced")
    func dispatchDeliversOnce() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)
        let route = AgentFeedbackRecordingRoute()
        _ = try await harness.registry.recordFeedbackSubmission(submission).get()
        route.answer = { request in
            try? await Task.sleep(for: .milliseconds(80))
            return AgentFeedbackDeliveryReceipt(submissionID: request.submissionID)
        }
        let dispatch = route.route.dispatch

        async let first = harness.registry.dispatchFeedbackSubmission(submission, dispatch: dispatch)
        async let second = harness.registry.dispatchFeedbackSubmission(submission, dispatch: dispatch)
        let (a, b) = await (first, second)

        #expect((a == nil) != (b == nil), "exactly one caller may dispatch")
        guard case .delivered(let outcome)? = a ?? b else {
            Issue.record("the single dispatch should deliver: \(a ?? b ?? nil)")
            return
        }
        #expect(outcome.isComplete)
        #expect(route.requests.map(\.submissionID) == [submission.id])
        #expect(route.requests.first?.instruction == "Make the greeting shorter SECRET")
        // The delivered state is durable too.
        #expect(await harness.registry.flushPersistence() == .saved)
        guard case .delivered? = await harness.storedTasks().first?.feedbackSubmissions.first?.state else {
            Issue.record("the delivered state should be stored")
            return
        }
    }

    @Test("The same feedback twice cannot create two revisions or two dispatches")
    func duplicateIsFenced() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)
        let route = AgentFeedbackRecordingRoute()
        _ = try await harness.registry.recordFeedbackSubmission(submission).get()
        _ = await harness.registry.dispatchFeedbackSubmission(submission, dispatch: route.route.dispatch)

        // A duplicate click, event, or second surface replays the same submission.
        let again = await harness.registry.recordFeedbackSubmission(submission)

        #expect(again == .failure(.duplicate(submission.id)))
        #expect(route.requests.count == 1)
        let task = try #require(harness.registry.task(for: harness.task.id))
        #expect(task.feedbackSubmissions.count == 1)
        #expect(task.revisions.count == 1)
        #expect(task.candidateGeneration == 1)
    }

    @Test("A definite failure allows one explicit retry under the same idempotency key")
    func explicitRetryAfterDefiniteFailure() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)
        let route = AgentFeedbackRecordingRoute()
        _ = try await harness.registry.recordFeedbackSubmission(submission).get()
        var attempts = 0
        route.answer = { request in
            attempts += 1
            if attempts == 1 { throw AgentFeedbackDeliveryFailure.transportUnavailable }
            return AgentFeedbackDeliveryReceipt(submissionID: request.submissionID)
        }

        #expect(await harness.registry.dispatchFeedbackSubmission(
            submission, dispatch: route.route.dispatch
        ) == .failed(.transportUnavailable))
        // Nothing is resent on its own.
        #expect(route.requests.count == 1)
        #expect(await harness.registry.dispatchFeedbackSubmission(
            submission, dispatch: route.route.dispatch
        ) == nil)
        #expect(route.requests.count == 1)

        let retried = await harness.registry.retryFeedbackSubmission(
            submission, dispatch: route.route.dispatch
        )
        guard case .delivered? = retried else {
            Issue.record("the explicit retry should deliver: \(String(describing: retried))")
            return
        }
        #expect(route.requests.count == 2)
        #expect(Set(route.requests.map(\.submissionID)) == [submission.id])
        // The transition was recorded once, for both attempts.
        let task = try #require(harness.registry.task(for: harness.task.id))
        #expect(task.revisions.count == 1)
        #expect(task.candidateGeneration == 1)
    }

    @Test("Delivery-unknown is terminal and is never retried blindly")
    func deliveryUnknownIsNeverRetried() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)
        let route = AgentFeedbackRecordingRoute()
        _ = try await harness.registry.recordFeedbackSubmission(submission).get()
        let dispatch = route.route.dispatch

        // No acknowledgment arrived.
        route.answer = { _ in nil }
        #expect(await harness.registry.dispatchFeedbackSubmission(submission, dispatch: dispatch)
            == .deliveryUnknown)
        // An acknowledgment for another submission is never applied.
        // (It needs a fresh queued record, so it is checked on its own below.)
        #expect(await harness.registry.retryFeedbackSubmission(submission, dispatch: dispatch) == nil)
        #expect(await harness.registry.dispatchFeedbackSubmission(submission, dispatch: dispatch) == nil)
        #expect(route.requests.count == 1)
    }

    @Test("An acknowledgment for another submission is delivery-unknown, never delivered")
    func foreignReceiptIsNeverApplied() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)
        let route = AgentFeedbackRecordingRoute()
        _ = try await harness.registry.recordFeedbackSubmission(submission).get()
        route.answer = { _ in AgentFeedbackDeliveryReceipt(submissionID: UUID()) }

        #expect(await harness.registry.dispatchFeedbackSubmission(
            submission, dispatch: route.route.dispatch
        ) == .deliveryUnknown)
        #expect(route.requests.count == 1)
    }

    @Test("Cancelling before the dispatch sends nothing and stays cancelled")
    func cancelBeforeDispatch() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)
        let route = AgentFeedbackRecordingRoute()
        _ = try await harness.registry.recordFeedbackSubmission(submission).get()

        #expect(harness.registry.cancelFeedbackSubmission(
            taskID: harness.task.id, submissionID: submission.id
        ))
        // A cancelled record cannot be dispatched, cancelled again, or retried.
        #expect(await harness.registry.dispatchFeedbackSubmission(
            submission, dispatch: route.route.dispatch
        ) == nil)
        #expect(!harness.registry.cancelFeedbackSubmission(
            taskID: harness.task.id, submissionID: submission.id
        ))
        #expect(await harness.registry.retryFeedbackSubmission(
            submission, dispatch: route.route.dispatch
        ) == nil)
        #expect(route.requests.isEmpty)
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).first?.state == .cancelled)
    }

    @Test("A dispatch in flight at quit restores as delivery-unknown and is never re-sent")
    func queuedRestoresAsDeliveryUnknown() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)
        let route = AgentFeedbackRecordingRoute()
        _ = try await harness.registry.recordFeedbackSubmission(submission).get()
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).first?.state == .queued)

        // A fresh registry on the same store, as after relaunch.
        let restored = AgentTaskRegistry(persistence: AgentTaskMetadataStore(
            storageRoot: harness.fixture.storage
        ))
        restored.registerProject(harness.identity)
        #expect(await restored.flushPersistence() == .saved)

        let record = try #require(restored.task(for: harness.task.id)?.feedbackSubmissions.first)
        #expect(record.id == submission.id)
        #expect(record.state == .deliveryUnknown)
        // The reference to the commented revision survived relaunch exactly.
        #expect(record.candidate.runID == submission.reference.candidate.runID)
        #expect(record.candidate.codeState == submission.reference.candidate.codeState)
        // The words did not: they lived only in the closed session.
        #expect(restored.liveFeedbackSubmissions(for: harness.task.id).isEmpty)
        // Restoration re-sends nothing.
        #expect(await restored.dispatchFeedbackSubmission(submission, dispatch: route.route.dispatch) == nil)
        #expect(await restored.retryFeedbackSubmission(submission, dispatch: route.route.dispatch) == nil)
        #expect(route.requests.isEmpty)
        // And the reconciled state is persisted in its turn.
        #expect(await restored.flushPersistence() == .saved)
        let reloaded = AgentTaskRegistry(persistence: AgentTaskMetadataStore(
            storageRoot: harness.fixture.storage
        ))
        reloaded.registerProject(harness.identity)
        #expect(await reloaded.flushPersistence() == .saved)
        #expect(reloaded.task(for: harness.task.id)?.feedbackSubmissions.first?.state == .deliveryUnknown)
    }

    @Test("Feedback on a result that is not currently Ready is refused before anything is recorded")
    func notReadyIsRefused() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        var stale = harness.task
        stale.verificationState = .stale
        harness.registry.setTasksForTesting([stale])
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)
        let route = AgentFeedbackRecordingRoute()

        let result = await harness.registry.recordFeedbackSubmission(submission)

        #expect(result == .failure(.continuationRejected(.notReady)))
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).isEmpty)
        #expect(harness.registry.task(for: harness.task.id)?.revisions.isEmpty == true)
        #expect(await harness.registry.dispatchFeedbackSubmission(submission, dispatch: route.route.dispatch) == nil)
        #expect(route.requests.isEmpty)
    }

    @Test("The bounded per-task record limit refuses a further submission")
    func recordLimitIsBounded() async throws {
        let harness = try await AgentFeedbackTestSupport.readyRegistry()
        defer { harness.fixture.cleanup() }
        var full = harness.task
        full.feedbackSubmissions = try (0..<AgentTaskPersistenceLimits().maxFeedbackRecordsPerTask).map { _ in
            AgentFeedbackSubmissionRecord(try AgentFeedbackTestSupport.submission(for: harness.task))
        }
        harness.registry.setTasksForTesting([full])
        let submission = try AgentFeedbackTestSupport.submission(for: harness.task)

        #expect(await harness.registry.recordFeedbackSubmission(submission)
            == .failure(.limitReached))
        #expect(harness.registry.feedbackSubmissions(for: harness.task.id).count
            == AgentTaskPersistenceLimits().maxFeedbackRecordsPerTask)
    }
}
