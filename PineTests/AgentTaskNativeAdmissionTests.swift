import Dispatch
import Foundation
import Synchronization
import Testing
@testable import Pine

@MainActor
@Suite("Native task admission without terminal or provider execution", .timeLimit(.minutes(1)))
struct AgentTaskNativeAdmissionTests {
    @Test(arguments: ["submission-unknown", "submission-cancellation", "decision-cancellation"])
    func purposeFenceDuringPhysicalValidationPreventsActualCallback(scenario: String) async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        let id = try await fixture.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: fixture.ownership)
        let receipt = try fixture.ownership.claimSubmission(id)
        let barrier = NativeAdmissionPhysicalBarrier()
        let probe = NativeAdmissionEffectProbe()
        fixture.kernel.holdEffectInspection(barrier)
        let effect: AgentTaskNativeOwnership.Effect = scenario.hasPrefix("decision") ? .decision : .submission(receipt)
        let work = Task {
            try await fixture.registry.performNativeEffect(effect, ownership: fixture.ownership) { probe.record() }
        }
        #expect(await waitUntilMainActor { barrier.entered })
        try await fixture.registry.recordNativeTransition(
            scenario == "submission-unknown" ? .submissionUnknown(submissionID: id) : .cancellationRequested,
            ownership: fixture.ownership)
        barrier.release()
        await #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try await work.value }
        #expect(probe.isEmpty)
        try fixture.ownership.validate()
        if scenario == "submission-unknown" { try fixture.ownership.validateControl() }
        #expect(fixture.stops.isEmpty)
        #expect(fixture.registry.task(for: fixture.reservation.taskID)?.runs[0].liveness == .live)
        await fixture.close()
    }

    @Test(arguments: ["launch", "submission-after-binding", "submission-physical"])
    func cancellingRealAwaitingTaskPreventsUnstartedEffect(scenario: String) async throws {
        let fixture = try await NativeAdmissionFixture.make(admit: scenario != "launch")
        let effect: AgentTaskNativeOwnership.Effect
        if scenario == "launch" {
            effect = .launch(environment: ProcessInfo.processInfo.environment)
        } else {
            try await fixture.bindSession()
            let id = try await fixture.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: fixture.ownership)
            effect = .submission(try fixture.ownership.claimSubmission(id))
        }
        let validation = NativeAdmissionSaveBarrier()
        let physical = NativeAdmissionPhysicalBarrier()
        let probe = NativeAdmissionEffectProbe()
        if scenario == "submission-physical" {
            fixture.kernel.holdEffectInspection(physical)
        } else {
            await fixture.bindings.holdAfterValidation(validation)
        }
        let work = Task {
            try await fixture.registry.performNativeEffect(effect, ownership: fixture.ownership) { probe.record() }
        }
        #expect(await waitUntilMainActor {
            scenario == "submission-physical" ? physical.entered : validation.entered
        })
        work.cancel()
        physical.release()
        validation.release()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(probe.isEmpty)
        try fixture.ownership.validate()
        #expect(fixture.stops.isEmpty)
        await fixture.close()
    }

    @Test func callerCancellationDoesNotPretendAnEnteredEffectWasRolledBack() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.beginInput()
        let entered = NativeAdmissionPhysicalBarrier()
        let probe = NativeAdmissionEffectProbe()
        let work = Task {
            try await fixture.registry.performNativeEffect(.decision, ownership: fixture.ownership) {
                let result = probe.record()
                entered.wait()
                return result
            }
        }
        #expect(await waitUntilMainActor { entered.entered })
        work.cancel()
        entered.release()
        #expect(try await work.value)
        #expect(probe.count == 1)
        try fixture.ownership.validateControl()
        #expect(fixture.registry.task(for: fixture.reservation.taskID)?.completedAt == nil)
        await fixture.close()
    }

    @Test(arguments: ["initial", "launch", "decision", "cancellation"])
    func branchDriftCannotBypassDirectNativeEntryPoints(entry: String) async throws {
        let fixture = try await NativeAdmissionFixture.make(admit: entry != "launch")
        if entry == "initial" { try await fixture.bindSession() }
        if entry == "decision" || entry == "cancellation" { try await fixture.beginInput() }
        await fixture.bindings.simulateReservedBranchChange()
        await #expect(throws: AgentTaskNativeAdmissionError.unavailable) {
            switch entry {
            case "initial":
                try await fixture.registry.recordNativeTransition(.initialInputIntent, ownership: fixture.ownership)
            case "launch":
                _ = try await fixture.registry.performNativeEffect(
                    .launch(environment: ProcessInfo.processInfo.environment), ownership: fixture.ownership) { true }
            case "decision":
                _ = try await fixture.registry.performNativeEffect(.decision, ownership: fixture.ownership) { true }
            default:
                try await fixture.registry.recordNativeTransition(.cancellationRequested, ownership: fixture.ownership)
            }
        }
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .unavailable && task.route.availability == .missing)
        #expect(task.lifecycle == .paused && task.executionState == .unknown && task.completedAt == nil)
        #expect(task.runs.allSatisfy { $0.liveness == .stale && $0.endedAt == nil && $0.outcome == nil })
        #expect(await waitUntilMainActor { fixture.stops.count == 1 })
        #expect(fixture.stops.hasBoundedDeadline)
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func retainedWorkCanBeCancelledAfterParentTerminalOutcome(parentCancelled: Bool) async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.beginInput()
        let context = try VendorReference(role: .conversation, value: "sensitive-session")
        #expect(await fixture.sink.emit(AdapterCandidate(event: .question(try CandidateAttentionEvent(
            scope: .run, phase: .waitingForQuestion, request: VendorReference(role: .request, value: "retained"),
            context: context
        )))) == .accepted)
        #expect(await fixture.sink.emit(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .run, phase: parentCancelled ? .cancelled : .failed, reference: context
        )))) == .accepted)
        #expect(fixture.registry.task(for: fixture.reservation.taskID)?.attention == .waitingInput)
        try await fixture.registry.recordNativeTransition(.cancellationRequested, ownership: fixture.ownership)
        #expect(try await fixture.registry.performNativeEffect(.cancellation, ownership: fixture.ownership) { true })
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateControl() }
        #expect(await fixture.sink.emit(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .run, phase: .cancelled, reference: context
        )))) == .accepted)
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .cancellationConfirmed && task.nativeDispatch?.cancellationRequested == true)
        #expect(task.runs.count == 1 && task.runs[0].liveness == .live && task.runs[0].endedAt == nil)
        #expect(task.runs[0].outcome == nil && task.completedAt == nil && task.evidence.isEmpty)
        #expect(task.verificationState != .verified && task.acceptanceState == .notAccepted)
        #expect(fixture.stops.isEmpty)
        await fixture.close()
    }

    @Test func realMetadataStoreRoundTripsNativeJournalAndRejectsInvalidOrDowngradedMetadata() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.beginInput()
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        let storage = fixture.root.appendingPathComponent("native-metadata")
        let store = AgentTaskMetadataStore(storageRoot: storage)
        #expect(await store.save(tasks: [task], project: fixture.project) == .saved(taskCount: 1))
        let loaded = await store.load(project: fixture.project)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.first?.nativeDispatch == task.nativeDispatch)
        #expect(loaded.tasks.first?.route.terminalID == nil && loaded.tasks.first?.runs.first?.terminalID == nil)
        var invalid = task
        let submission = try #require(task.nativeDispatch?.submissions.first)
        invalid.nativeDispatch?.submissions.append(submission)
        #expect(await store.save(tasks: [invalid], project: fixture.project) == .rejected(.invalidMetadata))
        let metadata = AgentTaskMetadataStore.metadataURL(for: fixture.project, storageRoot: storage)
        try await runOnBackground {
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            envelope["schemaVersion"] = 3
            try JSONSerialization.data(withJSONObject: envelope).write(to: metadata)
        }
        #expect(await store.load(project: fixture.project).status == .rejected(.invalidMetadata))
        await fixture.close()
    }

    @Test func launchRejectsReplacedWorktreeBeforeAnySpawnBoundary() async throws {
        let fixture = try await NativeAdmissionFixture.make(admit: false)
        let root = fixture.root
        let displaced = root.appendingPathExtension("displaced")
        let environment = ProcessInfo.processInfo.environment
        _ = try await fixture.registry.performNativeEffect(.launch(environment: environment), ownership: fixture.ownership) { true }
        try await runOnBackground {
            try FileManager.default.moveItem(at: root, to: displaced)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        let reachedSpawnBoundary = (try? await fixture.registry.performNativeEffect(
            .launch(environment: environment), ownership: fixture.ownership) { true }) ?? false
        #expect(!reachedSpawnBoundary)
        try await runOnBackground { try FileManager.default.removeItem(at: displaced) }
        await fixture.close()
    }

    @Test func branchDriftRejectsExplicitFeedbackAndDecisionAuthority() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        let id = try await fixture.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: fixture.ownership)
        let receipt = try fixture.ownership.claimSubmission(id)
        try await fixture.registry.recordNativeTransition(.submissionResponseObserved(receipt, operationID: nil),
            ownership: fixture.ownership)
        try await fixture.ownership.validateOperation()
        await fixture.bindings.simulateReservedBranchChange()
        await #expect(throws: AgentTaskNativeAdmissionError.unavailable) {
            try await fixture.registry.prepareNativeSubmission(afterResponseTo: id, ownership: fixture.ownership)
        }
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateControl() }
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateSubmission(receipt) }
        let retired = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(retired.nativeDispatch?.submissions.count == 1 && retired.nativeDispatch?.phase == .unavailable)
        #expect(retired.route.availability == .missing && retired.lifecycle == .paused)
        #expect(retired.runs[0].liveness == .stale && retired.runs[0].endedAt == nil)
        #expect(retired.runs[0].outcome == nil && retired.executionState == .unknown && retired.completedAt == nil)
        #expect(await waitUntilMainActor { fixture.stops.count == 1 })
        #expect(fixture.stops.hasBoundedDeadline)
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func resolvedQuestionReplayIsAnAcceptedPresentationNoOp(resolveBeforeQuestion: Bool) async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.beginInput()
        let context = try VendorReference(role: .conversation, value: "sensitive-session")
        let request = try VendorReference(role: .request, value: "replayed-question")
        let question = AdapterCandidate(event: .question(try CandidateAttentionEvent(
            scope: .run, phase: .waitingForQuestion, request: request, context: context
        )))
        if !resolveBeforeQuestion { #expect(await fixture.sink.emit(question) == .accepted) }
        #expect(await fixture.sink.emit(AdapterCandidate(event: .requestResolved(try CandidateRequestResolutionEvent(
            scope: .run, request: request, context: context
        )))) == .accepted)
        _ = fixture.registry.setReviewed(true, taskID: fixture.reservation.taskID)
        let before = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(await fixture.sink.emit(question) == .accepted)
        #expect(fixture.registry.task(for: before.id) == before)
        #expect(before.attention == .none && before.executionState == .unknown && !before.isUnread)
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func failedFollowupKeepsEarlierQuestionServiceable(sessionScoped: Bool) async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        let scope: AdapterLifecycleScope = sessionScoped ? .run : .turn
        let firstOperation: String? = sessionScoped ? nil : "turn-A"
        let secondOperation: String? = sessionScoped ? nil : "turn-B"
        let firstContext = try VendorReference(role: sessionScoped ? .conversation : .turn,
            value: sessionScoped ? "sensitive-session" : "turn-A")
        let failedContext = try VendorReference(role: sessionScoped ? .conversation : .turn,
            value: sessionScoped ? "sensitive-session" : "turn-B")
        let initial = try await fixture.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: fixture.ownership)
        let first = try fixture.ownership.claimSubmission(initial)
        try await fixture.registry.recordNativeTransition(.submissionAcknowledged(first, operationID: firstOperation),
            ownership: fixture.ownership)
        #expect(await fixture.sink.emit(AdapterCandidate(event: .question(try CandidateAttentionEvent(
            scope: scope, phase: .waitingForQuestion, request: VendorReference(role: .request, value: "question-A"),
            context: firstContext
        )))) == .accepted)
        try await fixture.registry.recordNativeTransition(.submissionResponseObserved(first, operationID: firstOperation),
            ownership: fixture.ownership)
        let feedback = try await fixture.registry.prepareNativeSubmission(afterResponseTo: initial, ownership: fixture.ownership)
        let second = try fixture.ownership.claimSubmission(feedback)
        try await fixture.registry.recordNativeTransition(.submissionAcknowledged(second, operationID: secondOperation),
            ownership: fixture.ownership)
        #expect(await fixture.sink.emit(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: scope, phase: .failed, reference: failedContext
        )))) == .accepted)
        var task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .operationFailed)
        #expect(task.attention == .waitingInput && task.executionState == .blocked && task.runs[0].state == .waitingInput)
        try fixture.ownership.validateControl()
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateSubmission(second) }
        #expect(await fixture.sink.emit(AdapterCandidate(event: .requestResolved(try CandidateRequestResolutionEvent(
            scope: scope, request: VendorReference(role: .request, value: "question-A"), context: firstContext
        )))) == .accepted)
        task = try #require(fixture.registry.task(for: task.id))
        #expect(task.attention == .none && task.executionState == .unknown)
        #expect(task.runs.count == 1 && task.runs[0].liveness == .live && task.runs[0].endedAt == nil)
        #expect(task.runs[0].outcome == nil && task.evidence.isEmpty && task.completedAt == nil)
        #expect(task.verificationState != .verified && task.acceptanceState == .notAccepted)
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func unknownFenceWinsWhileCheckpointSaveIsHeld(holdResponse: Bool) async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        let id = try await fixture.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: fixture.ownership)
        let receipt = try fixture.ownership.claimSubmission(id)
        let barrier = NativeAdmissionSaveBarrier()
        if holdResponse { await fixture.store.pauseResponse(barrier) } else { await fixture.store.pauseAcknowledgement(barrier) }
        let checkpoint = Task {
            do {
                try await fixture.registry.recordNativeTransition(
                    holdResponse ? .submissionResponseObserved(receipt, operationID: nil)
                        : .submissionAcknowledged(receipt, operationID: nil), ownership: fixture.ownership)
                return true
            } catch AgentTaskNativeAdmissionError.unavailable { return false }
        }
        #expect(await waitUntilMainActor { barrier.entered })
        let unknown = Task {
            try await fixture.registry.recordNativeTransition(.submissionUnknown(submissionID: id), ownership: fixture.ownership)
        }
        #expect(await waitUntilMainActor { (try? fixture.ownership.validateSubmission(receipt)) == nil })
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateSubmissionCorrelation(receipt) }
        var lateCompleted = false
        let late = Task {
            defer { lateCompleted = true }
            do {
                try await fixture.registry.recordNativeTransition(.submissionResponseObserved(receipt, operationID: nil),
                    ownership: fixture.ownership)
                return false
            } catch AgentTaskNativeAdmissionError.unavailable { return true }
        }
        #expect(await waitUntilMainActor { lateCompleted })
        barrier.release()
        #expect(try await late.value)
        #expect(try await checkpoint.value == !holdResponse)
        try await unknown.value
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .inputUnknown && task.nativeDispatch?.submissions.last?.phase == .unknown)
        #expect(task.runs[0].liveness == .live && task.runs[0].endedAt == nil && task.completedAt == nil)
        try fixture.ownership.validateControl()
        await fixture.close()
    }

    @Test func correlatedPromptResponseAllowsOnlyExplicitSameRunFeedback() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        let initial = try await fixture.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: fixture.ownership)
        let request = try fixture.ownership.claimSubmission(initial)
        #expect(try await fixture.registry.performNativeEffect(.submission(request), ownership: fixture.ownership) { true })
        try fixture.ownership.validateSubmission(request)
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.claimSubmission(initial) }
        let conversation = try VendorReference(role: .conversation, value: "sensitive-session")
        #expect(await fixture.sink.emit(AdapterCandidate(event: .question(try CandidateAttentionEvent(
            scope: .run, phase: .waitingForQuestion,
            request: VendorReference(role: .request, value: "pending-across-result"), context: conversation
        )))) == .accepted)
        try await fixture.registry.recordNativeTransition(.submissionAcknowledged(request, operationID: nil), ownership: fixture.ownership)
        #expect(await fixture.sink.emit(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .run, phase: .succeeded, reference: conversation
        )))) == .accepted)
        await #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            try await fixture.registry.prepareNativeSubmission(afterResponseTo: initial, ownership: fixture.ownership)
        }
        // Actual matching prompt response, not the lifecycle claim, opens explicit feedback.
        try await fixture.registry.recordNativeTransition(.submissionResponseObserved(request, operationID: nil), ownership: fixture.ownership)
        #expect(fixture.registry.task(for: fixture.reservation.taskID)?.nativeDispatch?.submissions.count == 1)
        await #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            try await fixture.registry.recordNativeTransition(
                .followupInputIntent(submissionID: UUID(), afterResponseTo: initial), ownership: fixture.ownership)
        }
        await #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            try await fixture.registry.prepareNativeSubmission(afterResponseTo: UUID(), ownership: fixture.ownership)
        }
        let feedback = try await fixture.registry.prepareNativeSubmission(afterResponseTo: initial, ownership: fixture.ownership)
        #expect(try await fixture.registry.prepareNativeSubmission(afterResponseTo: initial, ownership: fixture.ownership) == feedback)
        let feedbackRequest = try fixture.ownership.claimSubmission(feedback)
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.claimSubmission(feedback) }
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateSubmission(request) }
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateInitialInput() }
        try fixture.ownership.validateSubmission(feedbackRequest)
        try fixture.ownership.validateControl()
        // ACP's prompt result can be its only acknowledgement; no turn ID is invented.
        try await fixture.registry.recordNativeTransition(.submissionResponseObserved(feedbackRequest, operationID: nil),
            ownership: fixture.ownership)
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.runs.count == 1 && task.runs[0].id == fixture.reservation.runID)
        #expect(task.nativeDispatch?.submissions.map(\.phase) == [.responseObserved, .responseObserved])
        #expect(task.nativeDispatch?.operationID == nil && task.attention == .waitingInput)
        #expect(task.runs[0].liveness == .live && task.runs[0].endedAt == nil && task.runs[0].outcome == nil)
        #expect(task.evidence.isEmpty && task.completedAt == nil && task.acceptanceState == .notAccepted)
        #expect(task.verificationState != .verified && !fixture.registry.canResumeTask(task.id))
        #expect(await fixture.sink.emit(AdapterCandidate(event: .requestResolved(try CandidateRequestResolutionEvent(
            scope: .run, request: VendorReference(role: .request, value: "pending-across-result"), context: conversation
        )))) == .accepted)
        #expect(fixture.registry.task(for: task.id)?.executionState == .unknown)
        await fixture.close()
    }

    @Test func feedbackIntentMustBeDurableBeforeItsOneShotClaim() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        let initial = try await fixture.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: fixture.ownership)
        let request = try fixture.ownership.claimSubmission(initial)
        try await fixture.registry.recordNativeTransition(.submissionAcknowledged(request, operationID: "provider-turn"),
            ownership: fixture.ownership)
        #expect(await fixture.sink.emit(AdapterCandidate(event: .question(try CandidateAttentionEvent(
            scope: .turn, phase: .waitingForQuestion,
            request: VendorReference(role: .request, value: "retained-question"),
            context: VendorReference(role: .turn, value: "provider-turn")
        )))) == .accepted)
        try await fixture.registry.recordNativeTransition(.submissionResponseObserved(request, operationID: "provider-turn"),
            ownership: fixture.ownership)
        let barrier = NativeAdmissionSaveBarrier()
        await fixture.store.pauseInputIntent(barrier)
        let prepare = Task {
            try await fixture.registry.prepareNativeSubmission(afterResponseTo: initial, ownership: fixture.ownership)
        }
        #expect(await waitUntilMainActor { barrier.entered })
        let stagedID = try #require(fixture.registry.task(for: fixture.reservation.taskID)?.nativeDispatch?.submissions.last?.id)
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.claimSubmission(stagedID) }
        var duplicateStarted = false
        let duplicate = Task {
            duplicateStarted = true
            return try await fixture.registry.prepareNativeSubmission(afterResponseTo: initial, ownership: fixture.ownership)
        }
        #expect(await waitUntilMainActor { duplicateStarted })
        barrier.release()
        let feedback = try await prepare.value
        #expect(feedback == stagedID)
        #expect(try await duplicate.value == feedback)
        let receipt = try fixture.ownership.claimSubmission(feedback)
        try fixture.ownership.validateSubmission(receipt)
        #expect(fixture.registry.task(for: fixture.reservation.taskID)?.attention == .waitingInput)
        #expect(await fixture.sink.emit(AdapterCandidate(event: .requestResolved(try CandidateRequestResolutionEvent(
            scope: .turn, request: VendorReference(role: .request, value: "retained-question"),
            context: VendorReference(role: .turn, value: "provider-turn")
        )))) == .accepted)
        var diagnostic = ""
        dump(fixture.registry.task(for: fixture.reservation.taskID)?.nativeDispatch?.submissions, to: &diagnostic)
        #expect(!diagnostic.contains("provider-turn"))
        await fixture.close()
    }

    @Test func unknownSubmissionPreservesChildButLateRepliesCannotOpenFeedback() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        let initial = try await fixture.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: fixture.ownership)
        let receipt = try fixture.ownership.claimSubmission(initial)
        try await fixture.registry.recordNativeTransition(.submissionUnknown(submissionID: initial), ownership: fixture.ownership)
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateSubmission(receipt) }
        #expect(try await fixture.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: fixture.ownership) == initial)
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.claimSubmission(initial) }
        await #expect(throws: AgentTaskNativeAdmissionError.unavailable) {
            try await fixture.registry.recordNativeTransition(.submissionResponseObserved(receipt, operationID: nil), ownership: fixture.ownership)
        }
        await #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            try await fixture.registry.prepareNativeSubmission(afterResponseTo: initial, ownership: fixture.ownership)
        }
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .inputUnknown && task.runs[0].liveness == .live)
        #expect(task.runs[0].endedAt == nil && task.completedAt == nil && task.evidence.isEmpty)
        // The unknown input projects to the user-visible state: no pending
        // attention, unknown execution, idle run.
        #expect(task.attention == .none && task.executionState == .unknown)
        #expect(task.runs[0].state == .idle)
        try fixture.ownership.validateControl()
        let restored = AgentTaskRegistry(persistence: fixture.store)
        #expect(await restored.prepareDurableWork(in: fixture.project))
        #expect(restored.task(for: task.id)?.nativeDispatch?.submissions.last?.phase == .unknown)
        await #expect(throws: AgentTaskNativeAdmissionError.unavailable) {
            try await restored.prepareNativeSubmission(afterResponseTo: initial, ownership: fixture.ownership)
        }
        await fixture.close()
    }

    @Test func submissionReceiptsAreOwnerBoundAndJournalCapacityIsFinite() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        let foreign = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        try await foreign.bindSession()
        let foreignID = try await foreign.registry.prepareNativeSubmission(afterResponseTo: nil, ownership: foreign.ownership)
        let foreignReceipt = try foreign.ownership.claimSubmission(foreignID)
        var previous: UUID?
        for _ in 0..<AgentTaskNativeDispatch.maximumSubmissions {
            let id = try await fixture.registry.prepareNativeSubmission(afterResponseTo: previous, ownership: fixture.ownership)
            let receipt = try fixture.ownership.claimSubmission(id)
            await #expect(throws: AgentTaskNativeAdmissionError.unavailable) {
                try await fixture.registry.recordNativeTransition(.submissionResponseObserved(foreignReceipt, operationID: nil),
                    ownership: fixture.ownership)
            }
            try await fixture.registry.recordNativeTransition(.submissionResponseObserved(receipt, operationID: nil), ownership: fixture.ownership)
            previous = id
        }
        await #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            try await fixture.registry.prepareNativeSubmission(afterResponseTo: previous, ownership: fixture.ownership)
        }
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.submissions.count == AgentTaskNativeDispatch.maximumSubmissions)
        #expect(task.runs.count == 1 && task.runs[0].liveness == .live)
        #expect(task.nativeDispatch?.isValid(for: task) == true)
        await foreign.close()
        await fixture.close()
    }

    @Test func creationAndAdmissionUseExistingIDsAndNoTerminal() async throws {
        let fixture = try await NativeAdmissionFixture.make(admit: false)
        let reserved = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(reserved.route.surface == .ownedProcess)
        #expect(reserved.route.paneID == nil && reserved.route.tabID == nil && reserved.route.terminalID == nil)
        #expect(reserved.runs.isEmpty)
        #expect(reserved.nativeDispatch?.runID == fixture.reservation.runID)
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateInitialInput() }
        let ownership = fixture.ownership
        await #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            try await runOnBackground { try ownership.validateLaunch(environment: ["PATH": "/different"]) }
        }
        let wrongBinding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: fixture.reservation.taskID, runID: UUID()
        )
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: fixture.ownership.policy.agentID, selectedExecutable: URL(fileURLWithPath: "/selected/opencode")
        )
        guard case .eligible(let wrongPolicy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: fixture.reservation.taskID, runID: fixture.reservation.runID, bindingID: wrongBinding.id, selection: selection
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            try AgentTaskNativeOwnership(policy: wrongPolicy, binding: wrongBinding,
                filesystem: fixture.ownership.filesystem, bindings: fixture.bindings, environment: ProcessInfo.processInfo.environment)
        }
        try await fixture.registry.admitNativeProcess(fixture.ownership, receipt: fixture.receipt)
        let admitted = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(admitted.runs.count == 1)
        #expect(admitted.runs[0].id == fixture.reservation.runID && admitted.runs[0].terminalID == nil)
        #expect(admitted.runs[0].process.processIdentifier == fixture.kernel.identity.processID)
        #expect(admitted.runs[0].liveness == .live && admitted.runs[0].endedAt == nil)
        #expect(admitted.evidence.isEmpty && admitted.runs[0].outcome == nil)
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateInitialInput() }
        await fixture.close()
    }

    @Test func initialInputGateOpensOnlyAfterDurabilityAndCannotBeReused() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        let barrier = NativeAdmissionSaveBarrier()
        await fixture.store.pauseInputIntent(barrier)
        let operation = Task {
            try await fixture.registry.recordNativeTransition(.initialInputIntent, ownership: fixture.ownership)
        }
        #expect(await waitUntilMainActor { barrier.entered })
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateInitialInput() }
        barrier.release()
        try await operation.value
        try fixture.ownership.validateInitialInput()
        try await fixture.registry.recordNativeTransition(.initialInputAcknowledged(operationID: nil), ownership: fixture.ownership)
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateInitialInput() }
        try fixture.ownership.validateControl()
        await #expect(throws: AgentTaskNativeAdmissionError.invalidTransition) {
            try await fixture.registry.recordNativeTransition(.initialInputIntent, ownership: fixture.ownership)
        }
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.operationID == nil) // ACP need not invent a provider turn ID.
        await fixture.close()
    }

    @Test func unknownPublicationRevokesInputAndNeverRetries() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        await fixture.store.failInputIntent()
        await #expect(throws: AgentTaskNativeAdmissionError.persistenceUnavailable) {
            try await fixture.registry.recordNativeTransition(.initialInputIntent, ownership: fixture.ownership)
        }
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateInitialInput() }
        await #expect(throws: AgentTaskNativeAdmissionError.staleOwner) {
            try await fixture.registry.recordNativeTransition(.initialInputIntent, ownership: fixture.ownership)
        }
        #expect(await fixture.store.inputIntentPublications == 1)
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .unavailable)
        #expect(task.executionState == .unknown && task.runs[0].liveness == .stale)
        await fixture.close()
    }

    @Test func parentEventCannotOvertakeDurableInputAcknowledgement() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        try await fixture.registry.recordNativeTransition(.initialInputIntent, ownership: fixture.ownership)
        let barrier = NativeAdmissionSaveBarrier()
        await fixture.store.pauseAcknowledgement(barrier)
        let acknowledgement = Task {
            try await fixture.registry.recordNativeTransition(.initialInputAcknowledged(operationID: nil), ownership: fixture.ownership)
        }
        #expect(await waitUntilMainActor { barrier.entered })
        let boundary = Task {
            await fixture.sink.emit(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
                scope: .run, phase: .succeeded, reference: VendorReference(role: .conversation, value: "sensitive-session")
            ))))
        }
        #expect(await waitUntilMainActor { fixture.ingress.arrivals > 0 })
        barrier.release()
        try await acknowledgement.value
        #expect(try await boundary.value == .accepted)
        #expect(fixture.registry.task(for: fixture.reservation.taskID)?.nativeDispatch?.phase == .parentSettlementUnknown)
        try fixture.ownership.validateControl()
        await fixture.close()
    }

    @Test func parentBoundaryPreservesQuestionsAndNeverCreatesSettlement() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.beginInput()
        let conversation = try VendorReference(role: .conversation, value: "sensitive-session")
        let request = try VendorReference(role: .request, value: "question")
        #expect(await fixture.sink.emit(AdapterCandidate(event: .question(try CandidateAttentionEvent(
            scope: .run, phase: .waitingForQuestion, request: request, context: conversation
        )))) == .accepted)
        #expect(await fixture.sink.emit(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .run, phase: .succeeded, reference: conversation
        )))) == .accepted)
        var task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .parentSettlementUnknown)
        #expect(task.attention == .waitingInput && task.executionState == .blocked)
        #expect(task.runs[0].liveness == .live && task.runs[0].endedAt == nil && task.runs[0].outcome == nil)
        #expect(task.evidence.isEmpty && task.verificationState != .verified && task.completedAt == nil)
        #expect(await fixture.sink.emit(AdapterCandidate(event: .requestResolved(try CandidateRequestResolutionEvent(
            scope: .run, request: request, context: conversation
        )))) == .accepted)
        task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.attention == .none && task.executionState == .unknown)
        #expect(!AgentTaskLifecycleReducer.isSettled(task.runs[0]))
        await fixture.close()
    }

    @Test func cancellationNeedsScopedConfirmationAndDoesNotInventPhysicalExit() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.beginInput()
        try await fixture.registry.recordNativeTransition(.cancellationRequested, ownership: fixture.ownership)
        try fixture.ownership.validateCancellation()
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateControl() }
        var task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .inputAcknowledged && task.nativeDispatch?.cancellationRequested == true)
        let conversation = try VendorReference(role: .conversation, value: "sensitive-session")
        #expect(await fixture.sink.emit(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .run, phase: .cancelled, reference: conversation
        )))) == .accepted)
        task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .cancellationConfirmed)
        #expect(task.runs[0].liveness == .live && task.runs[0].endedAt == nil)
        #expect(task.runs[0].outcome == nil && task.evidence.isEmpty && task.completedAt == nil)
        #expect(throws: AgentTaskNativeAdmissionError.unavailable) { try fixture.ownership.validateCancellation() }
        await fixture.close()
    }

    @Test func wrongContextAndProviderExitClaimsCannotSettleOrReplaceOwnership() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.beginInput()
        #expect(await fixture.sink.emit(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .run, phase: .working, reference: VendorReference(role: .conversation, value: "foreign-session")
        )))) == .droppedInvalid)
        #expect(await fixture.sink.emit(AdapterCandidate(event: .processExited(status: 0))) == .droppedInvalid)
        #expect(fixture.registry.task(for: fixture.reservation.taskID)?.runs[0].liveness == .live)
        fixture.kernel.loseProcess()
        #expect(await fixture.sink.emit(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .run, phase: .working, reference: VendorReference(role: .conversation, value: "sensitive-session")
        )))) == .revoked)
        let task = try #require(fixture.registry.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .unavailable && task.runs[0].liveness == .stale)
        #expect(task.runs[0].endedAt == nil && task.evidence.isEmpty && task.completedAt == nil)
        await fixture.close()
    }

    @Test func restorationKeepsExactSessionButRecreatesNoOwnerOrInputGrant() async throws {
        let fixture = try await NativeAdmissionFixture.make()
        try await fixture.bindSession()
        try await fixture.registry.recordNativeTransition(.initialInputIntent, ownership: fixture.ownership)
        let restored = AgentTaskRegistry(persistence: fixture.store)
        #expect(await restored.prepareDurableWork(in: fixture.project))
        let task = try #require(restored.task(for: fixture.reservation.taskID))
        #expect(task.nativeDispatch?.phase == .inputIntent)
        #expect(task.nativeDispatch?.conversation?.opaqueIdentifier == "sensitive-session")
        #expect(task.runs[0].liveness == .stale && task.runs[0].process.processIdentifier == nil)
        #expect(task.route.terminalID == nil && task.executionState == .unknown)
        #expect(!restored.canResumeTask(task.id))
        await #expect(throws: AgentTaskNativeAdmissionError.staleOwner) {
            try await restored.recordNativeTransition(.initialInputAcknowledged(operationID: nil), ownership: fixture.ownership)
        }
        var diagnostic = ""
        dump(task.nativeDispatch, to: &diagnostic)
        #expect(!diagnostic.contains("sensitive-session"))
        await fixture.close()
    }

    /// Simulates relaunch by reusing the same runtime binding value: it
    /// exercises the same-binding fence logic, not the post-process-crash
    /// path (binding identity is not persisted; that recovery is a follow-up).
    @Test func prepareNativeLaunchIsOneShotAndRepreparesOnlyTheSameBinding() async throws {
        let fixture = try await NativeAdmissionFixture.make(admit: false)
        let ownership = fixture.ownership
        // The live registry already holds the owner: a duplicate prepare is
        // refused.
        await #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            try await fixture.registry.prepareNativeLaunch(
                policy: ownership.policy, binding: ownership.binding, bindings: fixture.bindings)
        }
        // A restored registry (relaunch) re-prepares the same binding
        // idempotently: the persisted intent is the same, the validation is
        // fresh.
        let restored = AgentTaskRegistry(persistence: fixture.store)
        #expect(await restored.prepareDurableWork(in: fixture.project))
        try await restored.prepareNativeLaunch(
            policy: ownership.policy, binding: ownership.binding, bindings: fixture.bindings)
        let task = try #require(restored.task(for: ownership.policy.taskID))
        #expect(task.nativeDispatch?.phase == .launchIntent)
        #expect(task.nativeDispatch?.bindingID == ownership.binding.id)
        #expect(task.nativeDispatch?.runID == ownership.policy.runID)
        // A different binding is never re-prepared against the old intent.
        let otherBinding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: ownership.policy.taskID, runID: ownership.policy.runID
        )
        guard case .eligible(let otherPolicy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: ownership.policy.taskID, runID: ownership.policy.runID, bindingID: otherBinding.id,
            selection: .init(agentID: ownership.policy.agentID,
                             selectedExecutable: URL(fileURLWithPath: "/selected/opencode"))
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        await #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            try await restored.prepareNativeLaunch(
                policy: otherPolicy, binding: otherBinding, bindings: fixture.bindings)
        }
        await fixture.close()
    }

    @Test func armedFaultBeforeAtomicReplacePreservesPriorFileAndFailsClosed() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineNativeArmedFault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: storage) }
        let fault = ArmedCheckpointFault()
        let store = AgentTaskMetadataStore(
            storageRoot: storage,
            configuration: AgentTaskStoreConfiguration(
                faultInjector: PersistenceFaultInjector(injection: { storeKind, phase in
                    try fault.throwWhileArmed(store: storeKind, phase: phase)
                })
            )
        )
        let project = AgentTaskProjectIdentity(canonicalProjectPath: storage.path, canonicalWorktreePath: storage.path)
        let registry = AgentTaskRegistry(persistence: store)
        let reservation = try #require(await registry.createNativeTask(
            project: project, descriptor: AgentDescriptor(agentType: .openCode, launchExecutable: "opencode"),
            title: "Native task", objective: "Explicit request"
        ))
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(taskID: reservation.taskID, runID: reservation.runID)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "openCode"),
            selectedExecutable: URL(fileURLWithPath: "/selected/opencode")
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID, bindingID: binding.id, selection: selection
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        let filesystem = try await runOnBackground {
            try #require(RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil))
        }
        let validator = NativeAdmissionBindingValidator(binding: binding, filesystem: filesystem)
        let ownership = try await registry.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        let sink = NativeAdmissionSink()
        let stops = NativeAdmissionStops()
        let factoryID = try AdapterFactoryID(validating: "test.native.fault")
        let profile = try AdapterCapabilityProfile(transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: [
                .init(scope: .turn, phase: .started),
            ], evidence: []),
            delivery: AdapterDeliverySemantics(ordering: .unordered, minimumAuthentication: .ownedChildPipe))
        let version = PineAdapterContractVersion(major: 1, minor: 1)
        let versions = PineAdapterContractVersionRange(minimum: version, maximum: version)
        let descriptor = AdapterDescriptor(adapterID: try AdapterID(validating: "test:native-fault"), agentID: selection.agentID,
            factoryID: factoryID, contractVersions: versions, maximumProfiles: [profile])
        let adapters = try AgentAdapterRegistry(
            compiledPresentations: [try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "openCode"))],
            compiledAdapters: [(descriptor, NativeAdmissionFactory(id: factoryID, result: try AdapterProbeResult(
                detectedVendorVersion: DetectedVendorVersion("fixture"), detectedSchema: nil,
                offeredProfiles: [profile], offeredContractVersions: versions), sink: sink, stops: stops))]
        )
        let offer = try await adapters.probe(adapterID: descriptor.adapterID)
        let contract = try await adapters.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
            allowedVersions: versions, transportPreference: [.ownedStandardIO], acceptedAuthentication: [.ownedChildPipe]
        ))
        let session = try await adapters.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
        try registry.bindNativeSource(ownership, registry: adapters, session: session)
        try await session.start()
        let kernel = NativeAdmissionKernel()
        let receipt = AgentTaskOwnedProcessReceipt.nativeReceiptForTesting(identity: kernel.identity, ownership: ownership,
            inspectIdentity: { kernel.inspect($0) })
        try await registry.admitNativeProcess(ownership, receipt: receipt)
        try await registry.recordNativeTransition(.sessionBound(.init(provider: "openCode", opaqueIdentifier: "sensitive-session")),
            ownership: ownership)
        let submissionID = try await registry.prepareNativeSubmission(afterResponseTo: nil, ownership: ownership)
        let subReceipt = try ownership.claimSubmission(submissionID)
        let file = AgentTaskMetadataStore.metadataURL(for: project, storageRoot: storage)
        let before = try Data(contentsOf: file)
        // Force the acknowledgement save to fail before durability.
        fault.arm()
        defer { fault.disarm() }
        await #expect(throws: AgentTaskNativeAdmissionError.persistenceUnavailable) {
            try await registry.recordNativeTransition(.submissionAcknowledged(subReceipt, operationID: nil), ownership: ownership)
        }
        // The prior file is byte-identical: a failed acknowledgement never
        // partially advances the journal.
        #expect(try Data(contentsOf: file) == before)
        // The ownership is retired: the gates stay closed...
        #expect((try? ownership.validateSelection()) == nil)
        // ...and a relaunch from the restored registry is fail-closed.
        let restored = AgentTaskRegistry(persistence: store)
        #expect(await restored.prepareDurableWork(in: project))
        let restoredTask = try #require(restored.task(for: reservation.taskID))
        #expect(restoredTask.nativeDispatch?.phase == .inputIntent)
        #expect(restoredTask.nativeDispatch?.submissions.last?.phase == .intent)
        await #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            try await restored.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        }
        await session.stop(deadline: .now.advanced(by: .seconds(1)))
    }
}

@MainActor
private struct NativeAdmissionFixture {
    let root: URL
    let project: AgentTaskProjectIdentity
    let store: NativeAdmissionStore
    let registry: AgentTaskRegistry
    let reservation: AgentTaskNativeReservation
    let ownership: AgentTaskNativeOwnership
    let bindings: NativeAdmissionBindingValidator
    let receipt: AgentTaskOwnedProcessReceipt
    let kernel: NativeAdmissionKernel
    let sink: NativeAdmissionSink
    let ingress: NativeAdmissionIngress
    let stops: NativeAdmissionStops
    let session: any AgentAdapterSession

    static func make(admit: Bool = true) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PineNativeAdmission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let project = AgentTaskProjectIdentity(canonicalProjectPath: root.path, canonicalWorktreePath: root.path)
        let store = NativeAdmissionStore()
        let registry = AgentTaskRegistry(persistence: store)
        let reservation = try #require(await registry.createNativeTask(
            project: project, descriptor: AgentDescriptor(agentType: .openCode, launchExecutable: "opencode"),
            title: "Native task", objective: "Explicit request"
        ))
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(taskID: reservation.taskID, runID: reservation.runID)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "openCode"),
            selectedExecutable: URL(fileURLWithPath: "/selected/opencode", isDirectory: false)
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID, bindingID: binding.id, selection: selection
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        let filesystem = try await runOnBackground {
            try #require(RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil))
        }
        let bindings = NativeAdmissionBindingValidator(binding: binding, filesystem: filesystem)
        let ownership = try await registry.prepareNativeLaunch(policy: policy, binding: binding, bindings: bindings)
        let sink = NativeAdmissionSink()
        let stops = NativeAdmissionStops()
        let factoryID = try AdapterFactoryID(validating: "test.native.factory")
        let profile = try AdapterCapabilityProfile(transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: [
                .init(scope: .run, phase: .started), .init(scope: .run, phase: .working),
                .init(scope: .run, phase: .failed), .init(scope: .run, phase: .cancelled),
                .init(scope: .run, phase: .waitingForQuestion), .init(scope: .run, phase: .waitingForApproval),
                .init(scope: .turn, phase: .waitingForQuestion), .init(scope: .turn, phase: .settled),
                .init(scope: .turn, phase: .failed),
                .init(scope: .run, phase: .succeeded), .init(scope: .run, phase: .settled),
            ], evidence: []),
            delivery: AdapterDeliverySemantics(ordering: .unordered, minimumAuthentication: .ownedChildPipe))
        let version = PineAdapterContractVersion(major: 1, minor: 1)
        let versions = PineAdapterContractVersionRange(minimum: version, maximum: version)
        let descriptor = AdapterDescriptor(adapterID: try AdapterID(validating: "test:native"), agentID: selection.agentID,
            factoryID: factoryID, contractVersions: versions, maximumProfiles: [profile])
        let adapters = try AgentAdapterRegistry(
            compiledPresentations: [try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "openCode"))],
            compiledAdapters: [(descriptor, NativeAdmissionFactory(id: factoryID, result: try AdapterProbeResult(
                detectedVendorVersion: DetectedVendorVersion("fixture"), detectedSchema: nil,
                offeredProfiles: [profile], offeredContractVersions: versions), sink: sink, stops: stops))]
        )
        let offer = try await adapters.probe(adapterID: descriptor.adapterID)
        let contract = try await adapters.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
            allowedVersions: versions, transportPreference: [.ownedStandardIO], acceptedAuthentication: [.ownedChildPipe]
        ))
        let ingress = NativeAdmissionIngress(registry: registry, ownership: ownership)
        let session = try await adapters.makeSession(contract: contract, resumeFrom: nil) { event in
            await ingress.receive(event)
        }
        try registry.bindNativeSource(ownership, registry: adapters, session: session)
        try await session.start()
        let kernel = NativeAdmissionKernel()
        let receipt = AgentTaskOwnedProcessReceipt.nativeReceiptForTesting(identity: kernel.identity, ownership: ownership,
            inspectIdentity: { kernel.inspect($0) })
        if admit { try await registry.admitNativeProcess(ownership, receipt: receipt) }
        return Self(root: root, project: project, store: store, registry: registry, reservation: reservation,
            ownership: ownership, bindings: bindings, receipt: receipt, kernel: kernel,
            sink: sink, ingress: ingress, stops: stops, session: session)
    }

    func bindSession() async throws {
        try await registry.recordNativeTransition(.sessionBound(.init(provider: "openCode", opaqueIdentifier: "sensitive-session")),
            ownership: ownership)
    }
    func beginInput() async throws {
        try await bindSession()
        try await registry.recordNativeTransition(.initialInputIntent, ownership: ownership)
        try await registry.recordNativeTransition(.initialInputAcknowledged(operationID: nil), ownership: ownership)
    }
    func close() async {
        registry.invalidateNativeOwnership(ownership)
        await session.stop(deadline: .now.advanced(by: .seconds(1)))
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class NativeAdmissionIngress {
    let registry: AgentTaskRegistry
    let ownership: AgentTaskNativeOwnership
    private(set) var arrivals = 0
    init(registry: AgentTaskRegistry, ownership: AgentTaskNativeOwnership) {
        self.registry = registry
        self.ownership = ownership
    }
    func receive(_ event: ValidatedAgentEvent) async -> AdapterIngestOutcome {
        arrivals += 1
        return await registry.ingestNativeEvent(event, ownership: ownership)
    }
}

private actor NativeAdmissionBindingValidator: AgentTaskNativeBindingValidator {
    let binding: AgentTaskEnvironmentBinding
    let filesystem: RecentAgentTaskFilesystemValidationLease
    private var branchMatches = true
    private var validationBarrier: NativeAdmissionSaveBarrier?
    init(binding: AgentTaskEnvironmentBinding, filesystem: RecentAgentTaskFilesystemValidationLease) {
        self.binding = binding
        self.filesystem = filesystem
    }
    func simulateReservedBranchChange() { branchMatches = false }
    func holdAfterValidation(_ barrier: NativeAdmissionSaveBarrier) { validationBarrier = barrier }
    func revalidate(_ requested: AgentTaskEnvironmentBinding) async throws -> RecentAgentTaskFilesystemValidationLease {
        guard requested == binding, branchMatches else { throw AgentTaskEnvironmentBindingError.staleBinding }
        try binding.validateAuthority()
        let barrier = validationBarrier
        validationBarrier = nil
        await barrier?.wait()
        return filesystem
    }
}

nonisolated private final class NativeAdmissionKernel: Sendable {
    private struct State: Sendable {
        var live = true
        var skippedInspections = 0
        var barrier: NativeAdmissionPhysicalBarrier?
    }
    let identity = UserTaskProcessIdentity(processID: 42_000, startSeconds: 1_700_000_000, startMicroseconds: 0)
    private let state = Mutex(State())
    func loseProcess() { state.withLock { $0.live = false } }
    func holdEffectInspection(_ barrier: NativeAdmissionPhysicalBarrier) {
        state.withLock { $0.skippedInspections = 1; $0.barrier = barrier }
    }
    func inspect(_ pid: Int32) -> UserTaskProcessIdentity? {
        let barrier = state.withLock { value -> NativeAdmissionPhysicalBarrier? in
            if value.skippedInspections > 0 { value.skippedInspections -= 1; return nil }
            let barrier = value.barrier
            value.barrier = nil
            return barrier
        }
        barrier?.wait()
        return state.withLock { $0.live && pid == identity.processID ? identity : nil }
    }
}

nonisolated private final class NativeAdmissionPhysicalBarrier: Sendable {
    private let started = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { started.withLock { $0 } }
    func wait() {
        precondition(!Thread.isMainThread)
        started.withLock { $0 = true }
        if semaphore.wait(timeout: .now() + .seconds(30)) == .timedOut {
            Issue.record("Native physical effect barrier timed out")
        }
    }
    func release() { semaphore.signal() }
}

nonisolated private final class NativeAdmissionEffectProbe: Sendable {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    var isEmpty: Bool { calls.withLock { $0 == 0 } }
    func record() -> Bool { calls.withLock { $0 += 1 }; return true }
}

nonisolated private final class NativeAdmissionSaveBarrier: Sendable {
    private let started = Mutex(false)
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    var entered: Bool { started.withLock { $0 } }
    init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1)) }
    func wait() async {
        started.withLock { $0 = true }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func release() { continuation.yield(()); continuation.finish() }
}

private actor NativeAdmissionStore: AgentTaskPersisting {
    private var data = Data("[]".utf8)
    private var barrier: NativeAdmissionSaveBarrier?
    private var pausePhase: AgentTaskNativeDispatch.Phase?
    private var failInput = false
    private(set) var inputIntentPublications = 0
    func pauseInputIntent(_ value: NativeAdmissionSaveBarrier) { barrier = value; pausePhase = .inputIntent }
    func pauseAcknowledgement(_ value: NativeAdmissionSaveBarrier) { barrier = value; pausePhase = .inputAcknowledged }
    func pauseResponse(_ value: NativeAdmissionSaveBarrier) { barrier = value; pausePhase = .parentSettlementUnknown }
    func failInputIntent() { failInput = true }
    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: .loaded, tasks: (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? [])
    }
    func save(tasks: [AgentTask], project: AgentTaskProjectIdentity,
              authorization: AgentTaskPublicationAuthorization?) async -> AgentTaskMetadataSaveResult {
        guard tasks.allSatisfy({ $0.nativeDispatch?.isValid(for: $0) ?? true }),
              let encoded = try? JSONEncoder().encode(tasks) else { return .rejected(.invalidMetadata) }
        if let pausePhase, tasks.contains(where: { $0.nativeDispatch?.phase == pausePhase }) {
            let paused = barrier
            barrier = nil
            await paused?.wait()
        }
        if tasks.contains(where: { $0.nativeDispatch?.phase == .inputIntent }) {
            inputIntentPublications += 1
            data = encoded
            if failInput { return .publishedButDurabilityUnknown(taskCount: tasks.count, revision: UUID()) }
        }
        data = encoded
        return .saved(taskCount: tasks.count)
    }
}

private actor NativeAdmissionSink {
    private var value: (any AgentEventSink)?
    func install(_ sink: any AgentEventSink) { value = sink }
    func emit(_ candidate: AdapterCandidate) async -> AdapterIngestOutcome { await value?.ingest(candidate) ?? .revoked }
}

nonisolated private struct NativeAdmissionFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let result: AdapterProbeResult
    let sink: NativeAdmissionSink
    let stops: NativeAdmissionStops
    func probe() async throws -> AdapterProbeResult { result }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        await sink.install(request.sink)
        return NativeAdmissionSession(contract: request.contract, stops: stops)
    }
}

nonisolated private struct NativeAdmissionSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    let stops: NativeAdmissionStops
    func start() async throws {}
    func stop(deadline: ContinuousClock.Instant) async { stops.record(deadline: deadline) }
}

nonisolated private final class NativeAdmissionStops: Sendable {
    private let values = Mutex<[ContinuousClock.Instant]>([])
    var count: Int { values.withLock { $0.count } }
    var isEmpty: Bool { values.withLock { $0.isEmpty } }
    var hasBoundedDeadline: Bool {
        values.withLock { $0.allSatisfy { $0 <= ContinuousClock.now.advanced(by: .seconds(2)) } }
    }
    func record(deadline: ContinuousClock.Instant) { values.withLock { $0.append(deadline) } }
}

/// One-shot armed fault for the real metadata store: fires exactly at the
/// named write phase of the agent-task store while armed.
nonisolated private final class ArmedCheckpointFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    nonisolated func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    nonisolated func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
    }

    nonisolated func throwWhileArmed(
        store: PersistenceStoreKind,
        phase: PersistenceWritePhase
    ) throws {
        lock.lock()
        let shouldFire = armed
        lock.unlock()
        guard shouldFire, store == .agentTask, phase == .beforeAtomicReplace else { return }
        throw PersistenceFailureKind.atomicRename
    }
}
