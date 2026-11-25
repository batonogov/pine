import Foundation
import Synchronization
import Testing
@testable import Pine

@Suite("OpenCode native ACP task bridge", .serialized)
@MainActor
struct OpenCodeACPNativeBridgeTests {
    @Test func registeredOwnerBindsExactTaskAndContinuesAfterUnverifiedResult() async throws {
        let unverified = AsyncContinuationGate()
        let fixture = try await OpenCodeNativeFixture(mode: .loop)
        defer { fixture.teardown() }
        try await fixture.provider().observe { snapshot in
            if snapshot.state == .unverified { unverified.resolve() }
        }
        try await fixture.session.start()
        #expect(fixture.task()?.nativeDispatch?.phase == .sessionBound)
        #expect(fixture.task()?.nativeDispatch?.conversation?.opaqueIdentifier == "ses_native")
        #expect(fixture.task()?.runs.count == 1)

        let controls = try fixture.controls()
        #expect(try await controls.dispatch(.submitInstruction("First request"), beforeDispatch: {}) == .acknowledged)
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        })
        await unverified.wait()
        let first = await fixture.provider().snapshot()
        #expect(first.state == .unverified && first.result == "result-1")
        #expect(!first.ready && !first.settlementKnown)
        #expect(fixture.task()?.nativeDispatch?.submissions.last?.phase == .responseObserved)
        #expect(fixture.task()?.runs.last?.outcome == nil)

        #expect(try await controls.dispatch(.submitInstruction("Same-session feedback"), beforeDispatch: {}) == .acknowledged)
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.submissions.count == 2
                && fixture.task()?.nativeDispatch?.submissions.last?.phase == .responseObserved
        })
        let second = await fixture.provider().snapshot()
        #expect(second.result == "result-2" && second.nativeSession?.rawValue == "ses_native")
        #expect(fixture.server.promptSessionIDs == ["ses_native", "ses_native"])
        #expect(fixture.server.phaseAtPrompt == ["inputIntent", "inputIntent"])
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func questionAnswerIsOneShotAndParentEndStaysUnverified() async throws {
        let fixture = try await OpenCodeNativeFixture(mode: .question)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("Choose"), beforeDispatch: {})
        try #require(await waitUntilMainActor { fixture.task()?.attention == .waitingInput })
        let question = try #require(await fixture.provider().snapshot().questions.first)
        #expect(question.context.role == .conversation && question.context.rawValue == "ses_native")
        #expect(try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {}) == .acknowledged)
        await #expect(throws: OpenCodeACPError.invalidAnswer) {
            _ = try await controls.dispatch(.answerQuestion(
                request: question.request, context: question.context, answers: ["color": ["amber"]]
            ), beforeDispatch: {})
        }
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        })
        #expect(fixture.server.questionAnswers == [.object(["color": .string("blue")])])
        let result = await fixture.provider().snapshot()
        #expect(result.state == .unverified && result.result == "answered")
        #expect(result.questions.isEmpty && result.submittedQuestions.isEmpty)
        #expect(!result.ready && !result.settlementKnown)
        #expect(fixture.task()?.runs.last?.outcome == nil)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func cancellationIsDurableBeforeWriteAndConfirmedOnlyByProvider() async throws {
        let fixture = try await OpenCodeNativeFixture(mode: .cancel)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("Wait"), beforeDispatch: {})
        let context = try #require(await fixture.provider().snapshot().context)
        #expect(context.role == .turn)
        #expect(try await controls.dispatch(
            .requestCancellation(context: context), beforeDispatch: {}
        ) == .acknowledged)
        #expect(fixture.task()?.nativeDispatch?.cancellationRequested == true)
        #expect(await fixture.provider().snapshot().state == .cancelRequested)
        #expect(fixture.task()?.nativeDispatch?.phase != .cancellationConfirmed)
        fixture.server.releaseCancellationConfirmation()
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .cancellationConfirmed
        })
        let cancelled = await fixture.provider().snapshot()
        #expect(cancelled.state == .cancelled && !cancelled.ready && !cancelled.settlementKnown)
        #expect(fixture.task()?.runs.last?.outcome == nil)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func lateChildQuestionIsOwnedAndAnswerableThenLateOutputFencesFeedback() async throws {
        let fixture = try await OpenCodeNativeFixture(mode: .lateChild)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("Delegate"), beforeDispatch: {})
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
                && fixture.task()?.attention == .waitingInput
        })
        let snapshot = await fixture.provider().snapshot()
        let question = try #require(snapshot.questions.first)
        #expect(snapshot.parentOutcome == .unverified && snapshot.state == .waiting)
        _ = try await controls.dispatch(.answerQuestion(
            request: question.request, context: question.context, answers: ["color": ["blue"]]
        ), beforeDispatch: {})
        try #require(await waitUntilMainActor {
            fixture.ingress.outcomes.contains("resolved:accepted")
        })
        let retained = await fixture.provider().snapshot()
        #expect(retained.parentOutcome == .unverified)
        // Late root output after settlement has no turn to belong to: it must
        // not become the result, and later input stays fenced. The answered
        // question resolved with its tool completion, leaving no ask.
        #expect(retained.result == "" && retained.inputFenced)
        #expect(retained.questions.isEmpty && retained.submittedQuestions.isEmpty)
        #expect(fixture.ingress.outcomes.contains("question:accepted"))
        #expect(!retained.ready && !retained.settlementKnown)
        #expect(fixture.server.promptSessionIDs == ["ses_native"])
        await #expect(throws: OpenCodeACPError.invalidState) {
            _ = try await controls.dispatch(.submitInstruction("Fenced"), beforeDispatch: {})
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func responseBeforeAcknowledgementWinsWithoutUnknownOrDoubleTransition() async throws {
        let gate = AsyncContinuationGate()
        let fixture = try await OpenCodeNativeFixture(mode: .loop, acknowledgementGate: gate)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        let submission = Task {
            try await controls.dispatch(.submitInstruction("Race response"), beforeDispatch: {})
        }
        try #require(await waitUntilMainActor { gate.hasRegisteredWaiter })
        gate.resolve()
        #expect(try await submission.value == .acknowledged)
        #expect(fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown)
        #expect(fixture.task()?.nativeDispatch?.submissions.last?.phase == .responseObserved)
        #expect(fixture.task()?.nativeDispatch?.submissions.last?.phase != .unknown)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func responseDuringCancellationPreparationNeverSendsStaleCancel() async throws {
        let gate = AsyncContinuationGate()
        let fixture = try await OpenCodeNativeFixture(mode: .cancelRace, cancellationGate: gate)
        defer { fixture.teardown() }
        let unknown = AsyncContinuationGate()
        try await fixture.provider().observe { snapshot in
            if snapshot.parentOutcome == .unknown { unknown.resolve() }
        }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("Race cancel"), beforeDispatch: {})
        let context = try #require(await fixture.provider().snapshot().context)
        let cancellation = Task {
            try await controls.dispatch(.requestCancellation(context: context), beforeDispatch: {})
        }
        try #require(await waitUntilMainActor { gate.hasRegisteredWaiter })
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        })
        gate.resolve()
        do {
            #expect(try await cancellation.value == .acknowledged)
        } catch AdapterSessionError.invalidLifecycle {
            // Response-driven teardown may revoke the owner before return.
        }
        #expect(fixture.server.cancellationWriteCount == 0)
        try #require(await waitUntilMainActor { unknown.isResolved })
        let snapshot = await fixture.provider().snapshot()
        #expect(snapshot.parentOutcome == .unknown && snapshot.parentOutcome != .unverified)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func responseDuringAcknowledgementPersistenceStillProvesDelivery() async throws {
        let gate = AsyncContinuationGate()
        let persistenceGate = AsyncContinuationGate()
        let fixture = try await OpenCodeNativeFixture(
            mode: .ackRace, acknowledgementGate: gate, acknowledgementPersistenceGate: persistenceGate
        )
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        let submission = Task {
            try await controls.dispatch(.submitInstruction("Race ack"), beforeDispatch: {})
        }
        try #require(await waitUntilMainActor { gate.hasRegisteredWaiter })
        gate.resolve()
        try #require(await waitUntilMainActor { persistenceGate.hasRegisteredWaiter })
        fixture.server.releaseAcknowledgementRace()
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        })
        persistenceGate.resolve()
        #expect(try await submission.value == .acknowledged)
        #expect(fixture.task()?.nativeDispatch?.submissions.last?.phase == .responseObserved)
        #expect(fixture.task()?.nativeDispatch?.submissions.last?.phase != .unknown)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func lateQuestionAfterConfirmedCancellationReceivesTerminalAnswer() async throws {
        let fixture = try await OpenCodeNativeFixture(mode: .cancelLateQuestion)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("Wait"), beforeDispatch: {})
        let context = try #require(await fixture.provider().snapshot().context)
        #expect(try await controls.dispatch(
            .requestCancellation(context: context), beforeDispatch: {}
        ) == .acknowledged)
        fixture.server.releaseCancellationConfirmation()
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .cancellationConfirmed
        })
        // The late question follows the cancellation response on the wire.
        // Wait for its terminal reply before reading the provider snapshot.
        try #require(await waitUntilMainActor { fixture.server.terminalReplyCount == 1 })
        let snapshot = await fixture.provider().snapshot()
        #expect(snapshot.parentOutcome == .cancelled)
        // The late question is answered terminally on the wire; the session
        // keeps its cancelled turn instead of losing the connection on the
        // failed effect (which would be .unknown).
        #expect(snapshot.state == .cancelled && !snapshot.inputFenced)
        #expect(snapshot.questions.isEmpty && !snapshot.submittedQuestions.isEmpty)
        #expect(fixture.task()?.runs.last?.outcome == nil)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func responseWinningDuringCancellationPreparationStillAnswersOwnedQuestion() async throws {
        let gate = AsyncContinuationGate()
        let fixture = try await OpenCodeNativeFixture(mode: .cancelRaceQuestion, cancellationGate: gate)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("Race cancel"), beforeDispatch: {})
        try #require(await waitUntilMainActor {
            fixture.task()?.attention == .waitingInput
        })
        let question = try #require(await fixture.provider().snapshot().questions.first)
        let context = try #require(await fixture.provider().snapshot().context)
        let cancellation = Task {
            try await controls.dispatch(.requestCancellation(context: context), beforeDispatch: {})
        }
        try #require(await waitUntilMainActor { gate.hasRegisteredWaiter })
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        })
        gate.resolve()
        #expect(try await cancellation.value == .acknowledged)
        #expect(fixture.server.cancellationWriteCount == 0)
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .cancellationConfirmed
        })
        let snapshot = await fixture.provider().snapshot()
        #expect(snapshot.parentOutcome == .cancelled)
        #expect(snapshot.submittedQuestions.contains { $0.id == question.id })
        #expect(snapshot.questions.isEmpty)
        #expect(fixture.server.terminalReplyCount == 1)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func inboxReplyReachesExactRuntimeThroughProductionComposition() async throws {
        let fixture = try await OpenCodeNativeFixture(mode: .loop)
        defer { fixture.teardown() }
        let (projects, runtime) = try fixture.projectsWithRuntime()
        try await runtime.start()
        _ = try await runtime.submit("Initial request")
        try #require(await waitUntilMainActor { fixture.server.promptTexts == ["Initial request"] })

        var task = try #require(fixture.task())
        let run = try #require(task.runs.last)
        let settlement = AgentTaskLogicalSettlement(
            settledAt: Date(), processGeneration: run.process.processGeneration,
            sourceSequence: nil, turn: task.nativeDispatch?.operationID ?? "turn-native"
        )
        #expect(fixture.tasks.recordLogicalSettlement(
            settlement, taskID: task.id, runID: run.id
        ) == .accepted)
        task = try #require(fixture.task())
        #expect(task.lifecycle == .paused)
        #expect(task.runs.last?.outcome == .unverified)
        let code = ADEContractFixtures.codeState("a")
        let environment = ADEContractFixtures.environment
        var cycle = AgentTaskCorrectionCycle(
            taskID: task.id, runID: run.id, codeState: code, environment: environment,
            requestedOutcomeReference: "outcome", criteriaVersion: "criteria",
            checkPlanIdentity: ADEContractFixtures.hex("f"),
            reviewerControl: .writeDisabledAtAdapter
        )
        cycle.stop(.checksFailed)
        task.reviewCycle = cycle
        fixture.tasks.setTasksForTesting([task])

        let inbox = AgentInboxView(registry: projects)
        inbox.activateSelection(taskID: task.id)
        #expect(inbox.resultStore.taskID == task.id)
        let controller = try #require(inbox.resultStore.controllers[task.id])
        let reply = "Fix the build through the real Inbox"
        let onReply = try #require(AgentInboxResultSheet(
            controller: controller
        ).resultView.onReply)
        onReply(reply)

        try #require(await waitUntilMainActor {
            fixture.server.promptTexts == ["Initial request", reply]
                && fixture.tasks.task(for: task.id)?.revisions.count == 1
        })
        #expect(fixture.server.promptSessionIDs == ["ses_native", "ses_native"])
        #expect(runtime.runID == run.id)
        await runtime.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func pausedTaskWithPendingRevisionRefusesFreshSubmission() async throws {
        let fixture = try await OpenCodeNativeFixture(mode: .loop)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let task = try #require(fixture.task())
        let run = try #require(task.runs.last)
        let settlement = AgentTaskLogicalSettlement(
            settledAt: Date(), processGeneration: run.process.processGeneration,
            sourceSequence: nil, turn: "fresh-boundary"
        )
        #expect(fixture.tasks.recordLogicalSettlement(
            settlement, taskID: task.id, runID: run.id
        ) == .accepted)

        var decisionTask = try #require(fixture.task())
        #expect(decisionTask.lifecycle == .paused)
        let code = ADEContractFixtures.codeState("a")
        let environment = ADEContractFixtures.environment
        var cycle = AgentTaskCorrectionCycle(
            taskID: task.id, runID: run.id, codeState: code, environment: environment,
            requestedOutcomeReference: "outcome", criteriaVersion: "criteria",
            checkPlanIdentity: ADEContractFixtures.hex("f"),
            reviewerControl: .writeDisabledAtAdapter
        )
        cycle.stop(.checksFailed)
        decisionTask.reviewCycle = cycle
        fixture.tasks.setTasksForTesting([decisionTask])
        let decision = try #require(AgentTaskReviewOrchestrator.decisionRequest(for: decisionTask))
        let revision = await fixture.tasks.recordResultDecisionReply(
            decision, feedbackReference: "fresh-boundary"
        )
        #expect(revision != nil)
        #expect(AgentTaskContinuation.hasPendingRevision(
            try #require(fixture.tasks.task(for: task.id))
        ))

        await #expect(throws: AgentTaskNativeAdmissionError.unavailable) {
            _ = try await fixture.tasks.prepareNativeSubmission(
                afterResponseTo: nil, ownership: fixture.ownership
            )
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func stoppedProviderRuntimeIsReplacedByFreshComposition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-opencode-compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: root.path, canonicalWorktreePath: root.path
        )
        let tasks = AgentTaskRegistry(persistence: OpenCodeNativeTaskStore())
        let reservation = try #require(await tasks.createNativeTask(
            project: project,
            descriptor: AgentDescriptor(agentType: .openCode, launchExecutable: "opencode"),
            title: "OpenCode task", objective: "Explicit request"
        ))
        let taskID = reservation.taskID
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let lease = try #require(await runOnBackground {
            RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
        })
        let validator = OpenCodeNativeBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "openCode"),
            selectedExecutable: URL(fileURLWithPath: "/selected/opencode")
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID,
            bindingID: binding.id, selection: selection, provenance: testLaunchProvenance
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        let neverSpawn: @Sendable (ContinuousClock.Instant) throws -> OpenCodeACPNativeMaterials.Spawn = { _ in
            preconditionFailure("composition test never launches a child")
        }

        let ownership = try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        let materials = OpenCodeACPNativeMaterials(
            registry: tasks, ownership: ownership, workingDirectory: root,
            sessionDeadline: .now.advanced(by: .seconds(30)),
            spawn: neverSpawn
        )
        let composition = OpenCodeACPNativeComposition(tasks: tasks)
        let first = try await composition.compose(materials)
        #expect(composition.runtime(for: taskID) === first)
        #expect(!(await first.isProviderStopped()))

        // An explicit stop (or a failed start) leaves the provider session
        // stopped; the retained runtime is dead and must not block the
        // documented in-session re-prepare.
        await first.stop(deadline: .now.advanced(by: .seconds(2)))
        #expect(await first.isProviderStopped())
        let replacement = try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        let replacementMaterials = OpenCodeACPNativeMaterials(
            registry: tasks, ownership: replacement, workingDirectory: root,
            sessionDeadline: .now.advanced(by: .seconds(30)),
            spawn: neverSpawn
        )
        let second = try await composition.compose(replacementMaterials)
        #expect(second !== first)
        #expect(!(await second.isProviderStopped()))
        #expect(composition.runtime(for: taskID) === second)
        await second.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func postSpawnAdmissionFailureStopsTheExactRealChild() async throws {
        let fixture = try await OpenCodeNativeFixture(mode: .loop, forceAdmissionFailure: true)
        defer { fixture.teardown() }
        await #expect(throws: AgentTaskNativeAdmissionError.unavailable) {
            try await fixture.session.start()
        }
        let identity = try #require(fixture.server.spawnedIdentity)
        let remaining = await runOnBackground { UserTaskProcessInspector.identity(for: identity.processID) }
        #expect(remaining == nil || remaining != identity)
    }

    /// New-owner exact-session restore (#1811): owner A binds the exact
    /// session and settles one turn; a clean stop leaves the journal
    /// `.unavailable` and the run stale. A fresh composition (the new
    /// process) admits the restore under a new runtime-fresh binding and
    /// loads the exact recorded session ID — never `session/new` — then
    /// continues the same session with explicit input.
    @Test func newOwnerRestoresExactSessionThroughComposition() async throws {
        let fixture = try await OpenCodeNativeFixture(mode: .loop)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("First request"), beforeDispatch: {})
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        })
        let settled = await fixture.provider().snapshot()
        #expect(settled.state == .unverified && settled.result == "result-1")
        let exact = try #require(settled.nativeSession)
        #expect(exact.rawValue == "ses_native")
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
        #expect(fixture.task()?.nativeDispatch?.phase == .unavailable)
        #expect(fixture.task()?.runs.last?.liveness == .stale)

        let taskID = fixture.taskID
        let runID = try #require(fixture.task()?.runs.last?.id)
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: taskID, runID: runID
        )
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: fixture.root.path, canonicalWorktreePath: fixture.root.path
        )
        let lease = try #require(await runOnBackground {
            RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
        })
        let validator = OpenCodeNativeBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "openCode"),
            selectedExecutable: URL(fileURLWithPath: "/selected/opencode")
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: runID, bindingID: binding.id, selection: selection,
            provenance: testLaunchProvenance
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        let ownership = try await fixture.tasks.prepareNativeRestore(
            policy: policy, binding: binding, bindings: validator
        )
        // The composition derives the exact reference from the durable
        // identity, not from any caller guess.
        #expect(try OpenCodeACPNativeComposition.restoreReference(for: fixture.task()) == exact)

        // Owner B: new pipes, new fake server, new composition. The restore
        // owner must receive session/load with the exact ID.
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        let peerErrorPipe = Pipe()
        let channel = try CodexAppServerStdioChannel(
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: errorPipe.fileHandleForReading,
            requireJSONRPCVersion: true
        )
        let peer = try CodexAppServerStdioChannel(
            standardInput: output.fileHandleForWriting,
            standardOutput: input.fileHandleForReading,
            standardError: peerErrorPipe.fileHandleForReading,
            requireJSONRPCVersion: true
        )
        errorPipe.fileHandleForWriting.closeFile()
        peerErrorPipe.fileHandleForWriting.closeFile()
        let processIdentity = UserTaskProcessIdentity(
            processID: 91_812, startSeconds: 1_700_000_100, startMicroseconds: 0
        )
        let receipt = AgentTaskOwnedProcessReceipt.nativeReceiptForTesting(
            identity: processIdentity, ownership: ownership,
            inspectIdentity: { pid in pid == processIdentity.processID ? processIdentity : nil }
        )
        let server = OpenCodeNativeServer()
        let materials = OpenCodeACPNativeMaterials(
            registry: fixture.tasks, ownership: ownership,
            workingDirectory: fixture.root,
            sessionDeadline: .now.advanced(by: .seconds(30)), loadSession: exact,
            spawn: { _ in
                OpenCodeACPNativeMaterials.Spawn(
                    child: OpenCodeACPOwnedChild(
                        channel: channel, processIdentity: processIdentity,
                        close: { channel.close() }, stop: { _ in peer.close() }
                    ), receipt: receipt
                )
            }
        )
        let serverTask = Task.detached {
            await OpenCodeNativeFixture.serve(peer, mode: .load,
                                              tasks: fixture.tasks, taskID: taskID, server: server)
        }
        defer {
            serverTask.cancel()
            channel.close()
            peer.close()
        }
        let composition = OpenCodeACPNativeComposition(tasks: fixture.tasks)
        let restored = try await composition.compose(materials)
        try await restored.start()
        let snapshot = try #require(restored.snapshot)
        #expect(snapshot.state == .idle)
        #expect(snapshot.nativeSession?.rawValue == exact.rawValue)
        #expect(server.loadedSessionIDs == [exact.rawValue])
        #expect(fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown)
        #expect(fixture.task()?.nativeDispatch?.conversation?.opaqueIdentifier == exact.rawValue)
        #expect(fixture.task()?.runs.last?.liveness == .live)
        #expect(fixture.task()?.runs.last?.process.processGeneration == 2)

        // Explicit input continues the exact restored session.
        _ = try await restored.submit("Recall the earlier choice")
        try #require(await waitUntilMainActor {
            restored.snapshot?.state == .unverified
        })
        #expect(restored.snapshot?.result == "restored-result")
        #expect(restored.snapshot?.nativeSession?.rawValue == exact.rawValue)
        #expect(server.promptSessionIDs == [exact.rawValue])
        await restored.stop(deadline: .now.advanced(by: .seconds(2)))
        #expect(fixture.task()?.nativeDispatch?.phase == .unavailable)
        #expect(fixture.task()?.runs.last?.liveness == .stale)
    }

    /// Restore fails closed before any spawn: no observed run has no exact
    /// identity to load, at admission and at the composition reference gate.
    /// (The indeterminate last-input journal case is fenced at the pure
    /// journal level: `restoreRebindPhase` refuses `.unavailable` whose last
    /// submission is an unacknowledged intent.)
    @Test func restoreRefusesMissingIdentityBeforeAnySpawn() async throws {
        let fixture = try await OpenCodeNativeFixture(mode: .loop)
        defer { fixture.teardown() }
        let taskID = fixture.taskID
        let runID = try #require(fixture.task()?.nativeDispatch?.runID)
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: taskID, runID: runID
        )
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: fixture.root.path, canonicalWorktreePath: fixture.root.path
        )
        let lease = try #require(await runOnBackground {
            RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
        })
        let validator = OpenCodeNativeBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "openCode"),
            selectedExecutable: URL(fileURLWithPath: "/selected/opencode")
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: runID, bindingID: binding.id, selection: selection,
            provenance: testLaunchProvenance
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        await #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            _ = try await fixture.tasks.prepareNativeRestore(
                policy: policy, binding: binding, bindings: validator
            )
        }
        await #expect(throws: OpenCodeACPError.unavailable) {
            _ = try OpenCodeACPNativeComposition.restoreReference(for: fixture.task())
        }
        // No restore owner was admitted: the fresh-launch owner is still the
        // only registered owner, and no server ever saw a session/load.
        #expect(fixture.task()?.nativeDispatch?.phase == .launchIntent)
        #expect(fixture.server.loadedSessionIDs.isEmpty)
    }
}

private enum OpenCodeNativeMode {
    case loop, question, cancel, lateChild, cancelRace
    case ackRace, cancelLateQuestion, cancelRaceQuestion
    case load
}

nonisolated private final class OpenCodeNativeServer: Sendable {
    let cancellation = AsyncContinuationGate()
    let acknowledgementRace = AsyncContinuationGate()
    private let promptIDs = Mutex<[String]>([])
    private let promptText = Mutex<[String]>([])
    private let loadIDs = Mutex<[String]>([])
    private let phases = Mutex<[String]>([])
    private let answers = Mutex<[AgentEventJSON]>([])
    private let admissionIdentity = Mutex<UserTaskProcessIdentity?>(nil)
    private let cancellationWrites = Mutex(0)
    private let terminalReplies = Mutex(0)
    var promptSessionIDs: [String] { promptIDs.withLock { $0 } }
    var promptTexts: [String] { promptText.withLock { $0 } }
    var loadedSessionIDs: [String] { loadIDs.withLock { $0 } }
    var phaseAtPrompt: [String] { phases.withLock { $0 } }
    var questionAnswers: [AgentEventJSON] { answers.withLock { $0 } }
    var spawnedIdentity: UserTaskProcessIdentity? { admissionIdentity.withLock { $0 } }
    var cancellationWriteCount: Int { cancellationWrites.withLock { $0 } }
    var terminalReplyCount: Int { terminalReplies.withLock { $0 } }
    func recordSpawnedIdentity(_ identity: UserTaskProcessIdentity) {
        admissionIdentity.withLock { $0 = identity }
    }
    func recordLoad(_ id: String) {
        loadIDs.withLock { $0.append(id) }
    }
    func recordPrompt(_ id: String, text: String, phase: String) {
        promptIDs.withLock { $0.append(id) }
        promptText.withLock { $0.append(text) }
        phases.withLock { $0.append(phase) }
    }
    func recordAnswer(_ value: AgentEventJSON) { answers.withLock { $0.append(value) } }
    func recordTerminalReply() { terminalReplies.withLock { $0 += 1 } }
    func recordCancellationWrite() { cancellationWrites.withLock { $0 += 1 } }
    func releaseCancellationConfirmation() { cancellation.resolve() }
    func releaseAcknowledgementRace() { acknowledgementRace.resolve() }
}

nonisolated private final class OpenCodeNativeIngressRecorder: Sendable {
    private let values = Mutex<[String]>([])
    var outcomes: [String] { values.withLock { $0 } }
    func record(_ event: ValidatedAgentEvent, outcome: AdapterIngestOutcome) {
        let kind = switch event.candidate.event {
        case .lifecycle: "lifecycle"
        case .question: "question"
        case .approval: "approval"
        case .requestResolved: "resolved"
        case .tool: "tool"
        case .processExited: "exit"
        }
        values.withLock { $0.append("\(kind):\(outcome)") }
    }
}

nonisolated private final class OpenCodeNativeSessionRecorder: Sendable {
    private let value = Mutex<OpenCodeACPSession?>(nil)
    func set(_ session: OpenCodeACPSession) { value.withLock { $0 = session } }
    var session: OpenCodeACPSession {
        guard let session = value.withLock({ $0 }) else { preconditionFailure("Session was not recorded") }
        return session
    }
}

private actor OpenCodeNativeTaskStore: AgentTaskPersisting {
    private var data = Data("[]".utf8)
    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
            status: .loaded,
            tasks: (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? [],
            revision: nil, requiresMigration: false, envelope: .empty
        )
    }
    func save(
        tasks: [AgentTask], project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        guard tasks.allSatisfy({ $0.nativeDispatch?.isValid(for: $0) ?? true }),
              let encoded = try? JSONEncoder().encode(tasks) else { return .rejected(.invalidMetadata) }
        data = encoded
        return .saved(taskCount: tasks.count)
    }
}

private actor OpenCodeNativeBindingValidator: AgentTaskNativeBindingValidator {
    let binding: AgentTaskEnvironmentBinding
    let lease: RecentAgentTaskFilesystemValidationLease
    init(binding: AgentTaskEnvironmentBinding, lease: RecentAgentTaskFilesystemValidationLease) {
        self.binding = binding
        self.lease = lease
    }
    func revalidate(_ requested: AgentTaskEnvironmentBinding) async throws -> RecentAgentTaskFilesystemValidationLease {
        guard requested == binding else { throw AgentTaskEnvironmentBindingError.staleBinding }
        try requested.validateAuthority()
        return lease
    }
}

nonisolated private struct OpenCodeNativeFixture: Sendable {
    let tasks: AgentTaskRegistry
    let adapters: AgentAdapterRegistry
    let ownership: AgentTaskNativeOwnership
    let session: any AgentAdapterSession
    let taskID: UUID
    let server: OpenCodeNativeServer
    let recorder: OpenCodeNativeSessionRecorder
    let ingress: OpenCodeNativeIngressRecorder
    let peer: CodexAppServerStdioChannel
    let serverTask: Task<Void, Never>
    let root: URL
    private let peerError: Pipe
    private let error: Pipe

    @MainActor func controls() throws -> any AgentAdapterControlledSession {
        try adapters.controls(for: session)
    }
    @MainActor func task() -> AgentTask? { tasks.task(for: taskID) }
    func provider() -> OpenCodeACPSession { recorder.session }

    @MainActor
    func projectsWithRuntime() throws -> (ProjectRegistry, OpenCodeACPTaskRuntime) {
        let projects = ProjectRegistry(agentTasks: tasks)
        let ownership = ownership
        let runtime = try OpenCodeACPTaskRuntime(
            taskID: taskID, runID: ownership.policy.runID, bindingID: ownership.binding.id,
            registry: adapters, owner: session, provider: provider(),
            taskIsCurrent: { [tasks] in
                guard let task = tasks.task(for: taskID),
                      task.nativeDispatch?.runID == ownership.policy.runID,
                      task.nativeDispatch?.bindingID == ownership.binding.id,
                      task.nativeDispatch?.phase != .unavailable,
                      task.lifecycle != .dismissed else { return false }
                return true
            },
            prepareControl: { _ in }, beforeDispatch: { _ in try ownership.validate() }
        )
        projects.installOpenCodeRuntimeForTesting(runtime)
        return (projects, runtime)
    }

    @MainActor
    init(
        mode: OpenCodeNativeMode,
        acknowledgementGate: AsyncContinuationGate? = nil,
        acknowledgementPersistenceGate: AsyncContinuationGate? = nil,
        cancellationGate: AsyncContinuationGate? = nil,
        forceAdmissionFailure: Bool = false
    ) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-opencode-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: root.path, canonicalWorktreePath: root.path
        )
        let tasks = AgentTaskRegistry(persistence: OpenCodeNativeTaskStore())
        self.tasks = tasks
        let reservation = try #require(await tasks.createNativeTask(
            project: project,
            descriptor: AgentDescriptor(agentType: .openCode, launchExecutable: "opencode"),
            title: "OpenCode task", objective: "Explicit request"
        ))
        taskID = reservation.taskID
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let lease = try #require(await runOnBackground {
            RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
        })
        let validator = OpenCodeNativeBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "openCode"),
            selectedExecutable: URL(fileURLWithPath: "/selected/opencode")
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID,
            bindingID: binding.id, selection: selection, provenance: testLaunchProvenance
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        let ownership = try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        self.ownership = ownership

        let input = Pipe()
        let output = Pipe()
        error = Pipe()
        peerError = Pipe()
        let channel = try CodexAppServerStdioChannel(
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading,
            requireJSONRPCVersion: true
        )
        peer = try CodexAppServerStdioChannel(
            standardInput: output.fileHandleForWriting,
            standardOutput: input.fileHandleForReading,
            standardError: peerError.fileHandleForReading,
            requireJSONRPCVersion: true
        )
        error.fileHandleForWriting.closeFile()
        peerError.fileHandleForWriting.closeFile()
        let processIdentity = UserTaskProcessIdentity(
            processID: 91_811, startSeconds: 1_700_000_000, startMicroseconds: 0
        )
        let receipt = AgentTaskOwnedProcessReceipt.nativeReceiptForTesting(
            identity: processIdentity, ownership: ownership,
            inspectIdentity: { pid in pid == processIdentity.processID ? processIdentity : nil }
        )
        let peerChannel = peer
        let recorder = OpenCodeNativeSessionRecorder()
        self.recorder = recorder
        let ingress = OpenCodeNativeIngressRecorder()
        self.ingress = ingress
        let server = OpenCodeNativeServer()
        self.server = server
        let fixtureRoot = root
        let materials = OpenCodeACPNativeMaterials(
            registry: tasks, ownership: ownership, workingDirectory: root,
            sessionDeadline: .now.advanced(by: .seconds(30)), sessionCreated: { recorder.set($0) },
            acknowledgementSeam: {
                await acknowledgementGate?.wait()
                await acknowledgementPersistenceGate?.wait()
            },
            cancellationSeam: { await cancellationGate?.wait() },
            spawn: { _ in
                if forceAdmissionFailure {
                    let subprocess = try UserTaskSubprocess(
                        executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], workingDirectory: fixtureRoot
                    )
                    let realChannel = try CodexAppServerStdioChannel(
                        standardInput: subprocess.standardInput,
                        standardOutput: subprocess.standardOutput,
                        standardError: subprocess.standardError,
                        requireJSONRPCVersion: true
                    )
                    let realReceipt = try AgentTaskOwnedProcessReceipt(
                        process: subprocess, ownership: ownership, validateImage: { _ in }
                    )
                    let realChild = CodexAppServerNativeChild(
                        subprocess: subprocess, channel: realChannel, receipt: realReceipt
                    )
                    server.recordSpawnedIdentity(realReceipt.identity)
                    ownership.revoke() // Force the post-spawn admission fence.
                    return OpenCodeACPNativeMaterials.Spawn(
                        child: OpenCodeACPOwnedChild(
                            channel: realChannel, processIdentity: realReceipt.identity,
                            close: { realChannel.close() },
                            stop: { deadline in
                                realChannel.close()
                                await realChild.stop(deadline: deadline)
                            }
                        ), receipt: realReceipt
                    )
                }
                return OpenCodeACPNativeMaterials.Spawn(
                    child: OpenCodeACPOwnedChild(
                        channel: channel, processIdentity: processIdentity,
                        close: { channel.close() }, stop: { _ in peerChannel.close() }
                    ), receipt: receipt
                )
            }
        )
        let registered = try OpenCodeACPNativeFactory.registered(materials: materials)
        let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "openCode"))
        adapters = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(registered.descriptor, registered.factory)]
        )
        let offer = try await adapters.probe(adapterID: registered.descriptor.adapterID)
        let contract = try await adapters.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
            allowedVersions: registered.descriptor.contractVersions,
            transportPreference: [.ownedStandardIO], acceptedAuthentication: [.ownedChildPipe]
        ))
        session = try await adapters.makeSession(contract: contract, resumeFrom: nil) { event in
            let outcome = await tasks.ingestNativeEvent(event, ownership: ownership)
            ingress.record(event, outcome: outcome)
            return outcome
        }
        try tasks.bindNativeSource(ownership, registry: adapters, session: session)
        serverTask = Task.detached {
            await Self.serve(peerChannel, mode: mode, tasks: tasks, taskID: reservation.taskID, server: server)
        }
    }

    func teardown() {
        serverTask.cancel()
        peer.close()
        peerError.fileHandleForReading.closeFile()
        error.fileHandleForReading.closeFile()
        try? FileManager.default.removeItem(at: root)
    }

    fileprivate static func serve(
        _ peer: CodexAppServerStdioChannel, mode: OpenCodeNativeMode,
        tasks: AgentTaskRegistry, taskID: UUID, server: OpenCodeNativeServer
    ) async {
        defer { peer.close() }
        var promptID: CodexAppServerRequestID?
        var promptCount = 0
        do {
            while let message = try await peer.readNext(deadline: .now.advanced(by: .seconds(30))) {
                switch message {
                case .request(let id, "initialize", _):
                    try await write(.response(id, result: .object([
                        "protocolVersion": .number("1"),
                        "agentInfo": .object([
                            "name": .string("OpenCode"), "version": .string(OpenCodeACPSession.pinnedVersion)
                        ]),
                        "agentCapabilities": .object([
                            "loadSession": .bool(true),
                            "_meta": .object(["opencode/child-session-updates": .bool(true)])
                        ])
                    ])), to: peer)
                case .request(let id, "session/new", _):
                    try await write(.response(id, result: .object([
                        "sessionId": .string("ses_native"), "configOptions": .array([])
                    ])), to: peer)
                case .request(let id, "session/load", let params):
                    let fields = try OpenCodeACPWire.object(params)
                    let requested = try OpenCodeACPWire.string(fields["sessionId"])
                    server.recordLoad(requested)
                    guard requested == "ses_native" else {
                        try await write(.failure(id, code: -32602), to: peer)
                        continue
                    }
                    // session/load replays saved session/update messages
                    // before its reply; they are historical, not live.
                    try await write(chunk("replayed-history"), to: peer)
                    try await write(.response(id, result: .object([
                        "sessionId": .string("ses_native"), "configOptions": .array([])
                    ])), to: peer)
                case .request(let id, "session/prompt", let params):
                    promptID = id
                    promptCount += 1
                    let fields = try OpenCodeACPWire.object(params)
                    let sessionID = try OpenCodeACPWire.string(fields["sessionId"])
                    var text = ""
                    if case .array(let parts)? = fields["prompt"],
                       case .object(let part)? = parts.first,
                       case .string(let value)? = part["text"] {
                        text = value
                    }
                    let phase = await tasks.task(for: taskID)?.nativeDispatch?.phase.rawValue ?? "missing"
                    server.recordPrompt(sessionID, text: text, phase: phase)
                    switch mode {
                    case .loop:
                        try await write(chunk("result-\(promptCount)"), to: peer)
                        try await write(.response(id, result: .object(["stopReason": .string("end_turn")])), to: peer)
                    case .load:
                        try await write(chunk("restored-result"), to: peer)
                        try await write(.response(id, result: .object(["stopReason": .string("end_turn")])), to: peer)
                    case .question:
                        try await write(.request(.string("native-question"), method: "elicitation/create",
                                                 params: question()), to: peer)
                    case .cancel:
                        break
                    case .cancelRace:
                        Task.detached {
                            let observed = await waitUntilMainActor {
                                tasks.task(for: taskID)?.nativeDispatch?.cancellationRequested == true
                            }
                            if observed {
                                try? await write(.response(id, result: .object([
                                    "stopReason": .string("end_turn")
                                ])), to: peer)
                            }
                        }
                    case .lateChild:
                        try await write(.response(id, result: .object(["stopReason": .string("end_turn")])), to: peer)
                        try await write(.request(.string("late-child"), method: "elicitation/create",
                                                 params: question()), to: peer)
                    case .ackRace:
                        await server.acknowledgementRace.wait()
                        try await write(.response(id, result: .object(["stopReason": .string("end_turn")])), to: peer)
                    case .cancelLateQuestion:
                        break
                    case .cancelRaceQuestion:
                        try await write(.request(.string("race-question"), method: "elicitation/create",
                                                 params: question()), to: peer)
                        Task.detached {
                            let observed = await waitUntilMainActor {
                                tasks.task(for: taskID)?.nativeDispatch?.cancellationRequested == true
                            }
                            if observed {
                                try? await write(.response(id, result: .object([
                                    "stopReason": .string("cancelled")
                                ])), to: peer)
                            }
                        }
                    }
                case .notification("session/cancel", _):
                    server.recordCancellationWrite()
                    await server.cancellation.wait()
                    if let promptID {
                        try await write(.response(promptID, result: .object([
                            "stopReason": .string("cancelled")
                        ])), to: peer)
                        if case .cancelLateQuestion = mode {
                            try await write(.request(.string("late-after-cancel"),
                                                     method: "elicitation/create",
                                                     params: question()), to: peer)
                        }
                    }
                case .response(let id, let result)
                    where id == .string("native-question") || id == .string("late-child")
                        || id == .string("late-after-cancel") || id == .string("race-question"):
                    if case .object(let fields) = result, let content = fields["content"] {
                        server.recordAnswer(content)
                    } else {
                        server.recordTerminalReply()
                    }
                    switch mode {
                    case .lateChild:
                        try await write(.notification(method: "session/update", params: .object([
                            "sessionId": .string("ses_native"), "update": .object([
                                "sessionUpdate": .string("tool_call_update"),
                                "toolCallId": .string("question-tool"), "status": .string("completed")
                            ])
                        ])), to: peer)
                        try await write(chunk("child-response"), to: peer)
                    case .question:
                        try await write(.notification(method: "session/update", params: .object([
                            "sessionId": .string("ses_native"), "update": .object([
                                "sessionUpdate": .string("tool_call_update"),
                                "toolCallId": .string("question-tool"), "status": .string("completed")
                            ])
                        ])), to: peer)
                        if let promptID {
                            try await write(chunk("answered"), to: peer)
                            try await write(.response(promptID, result: .object([
                                "stopReason": .string("end_turn")
                            ])), to: peer)
                        }
                    default:
                        break
                    }
                default:
                    break
                }
            }
        } catch {
            // Explicit teardown closes the peer.
        }
    }

    private static func write(
        _ message: CodexAppServerMessage, to peer: CodexAppServerStdioChannel
    ) async throws {
        try await peer.write(OpenCodeACPWire.encode(message), deadline: .now.advanced(by: .seconds(10)))
    }

    private static func chunk(_ text: String) -> CodexAppServerMessage {
        .notification(method: "session/update", params: .object([
            "sessionId": .string("ses_native"), "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string(text)])
            ])
        ]))
    }

    private static func question() -> AgentEventJSON {
        .object([
            "mode": .string("form"), "sessionId": .string("ses_native"),
            "toolCallId": .string("question-tool"), "message": .string("Which color?"),
            "requestedSchema": .object([
                "type": .string("object"), "required": .array([.string("color")]),
                "properties": .object(["color": .object([
                    "type": .string("string"), "oneOf": .array([
                        .object(["const": .string("blue")]), .object(["const": .string("amber")])
                    ])
                ])])
            ])
        ])
    }
}
