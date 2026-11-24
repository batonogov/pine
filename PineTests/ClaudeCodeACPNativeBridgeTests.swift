import Foundation
import Synchronization
import Testing
@testable import Pine

@Suite("ClaudeCode native ACP task bridge", .serialized)
@MainActor
struct ClaudeCodeACPNativeBridgeTests {
    @Test func registeredOwnerBindsExactTaskAndContinuesAfterUnverifiedResult() async throws {
        let fixture = try await ClaudeCodeNativeFixture(mode: .loop)
        defer { fixture.teardown() }
        try await fixture.session.start()
        #expect(fixture.task()?.nativeDispatch?.phase == .sessionBound)
        #expect(fixture.task()?.nativeDispatch?.conversation?.opaqueIdentifier == "ses_native")
        #expect(fixture.task()?.runs.count == 1)

        let controls = try fixture.controls()
        #expect(try await controls.dispatch(.submitInstruction("First request"), beforeDispatch: {}) == .acknowledged)
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        })
        let first = try await waitForProviderOutcome(fixture.provider()) {
            $0.state == .unverified && $0.result == "result-1"
        }
        #expect(first.state == .unverified && first.result == "result-1")
        #expect(!first.ready && !first.settlementKnown)
        #expect(fixture.task()?.nativeDispatch?.submissions.last?.phase == .responseObserved)
        #expect(fixture.task()?.runs.last?.outcome == nil)

        #expect(try await controls.dispatch(.submitInstruction("Same-session feedback"), beforeDispatch: {}) == .acknowledged)
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.submissions.count == 2
                && fixture.task()?.nativeDispatch?.submissions.last?.phase == .responseObserved
        })
        let second = try await waitForProviderOutcome(fixture.provider()) {
            $0.result == "result-2" && $0.nativeSession?.rawValue == "ses_native"
        }
        #expect(second.result == "result-2" && second.nativeSession?.rawValue == "ses_native")
        #expect(fixture.server.promptSessionIDs == ["ses_native", "ses_native"])
        #expect(fixture.server.phaseAtPrompt == ["inputIntent", "inputIntent"])
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func questionAnswerIsOneShotAndParentEndStaysUnverified() async throws {
        let fixture = try await ClaudeCodeNativeFixture(mode: .question)
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
        await #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try await controls.dispatch(.answerQuestion(
                request: question.request, context: question.context, answers: ["color": ["amber"]]
            ), beforeDispatch: {})
        }
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        })
        #expect(fixture.server.questionAnswers == [.object(["color": .string("blue")])])
        let result = try await waitForProviderOutcome(fixture.provider()) {
            $0.state == .unverified && $0.result == "answered"
        }
        #expect(result.state == .unverified && result.result == "answered")
        #expect(result.questions.isEmpty && result.submittedQuestions.isEmpty)
        #expect(!result.ready && !result.settlementKnown)
        #expect(fixture.task()?.runs.last?.outcome == nil)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func cancellationIsDurableBeforeWriteAndConfirmedOnlyByProvider() async throws {
        let fixture = try await ClaudeCodeNativeFixture(mode: .cancel)
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
        let fixture = try await ClaudeCodeNativeFixture(mode: .lateChild)
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
        await #expect(throws: ClaudeCodeACPError.invalidState) {
            _ = try await controls.dispatch(.submitInstruction("Fenced"), beforeDispatch: {})
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func responseBeforeAcknowledgementWinsWithoutUnknownOrDoubleTransition() async throws {
        let gate = AsyncContinuationGate()
        let fixture = try await ClaudeCodeNativeFixture(mode: .loop, acknowledgementGate: gate)
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
        let fixture = try await ClaudeCodeNativeFixture(mode: .cancelRace, cancellationGate: gate)
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
        let fixture = try await ClaudeCodeNativeFixture(
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
        let fixture = try await ClaudeCodeNativeFixture(mode: .cancelLateQuestion)
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
        let snapshot = await fixture.provider().snapshot()
        #expect(snapshot.parentOutcome == .cancelled)
        // The late question is answered terminally on the wire; the session
        // keeps its cancelled turn instead of losing the connection on the
        // failed effect (which would be .unknown).
        #expect(snapshot.state == .cancelled && !snapshot.inputFenced)
        #expect(snapshot.questions.isEmpty && !snapshot.submittedQuestions.isEmpty)
        // The terminal reply is written asynchronously: wait for the fake
        // server to record it instead of racing the pipe read.
        try #require(await waitUntilMainActor { fixture.server.terminalReplyCount == 1 })
        #expect(fixture.task()?.runs.last?.outcome == nil)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func responseWinningDuringCancellationPreparationStillAnswersOwnedQuestion() async throws {
        let gate = AsyncContinuationGate()
        let fixture = try await ClaudeCodeNativeFixture(mode: .cancelRaceQuestion, cancellationGate: gate)
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

    @Test func redeliveredPermissionAfterConfirmedCancellationUsesTerminalNativeGate() async throws {
        let fixture = try await ClaudeCodeNativeFixture(mode: .cancelRedeliveredPermission)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("Approve once"), beforeDispatch: {})
        try #require(await waitUntilMainActor { fixture.task()?.attention == .waitingInput })
        let question = try #require(await fixture.provider().snapshot().questions.first)
        _ = try await controls.dispatch(.answerPermission(
            request: question.request, context: question.context, decision: .allowOnce
        ), beforeDispatch: {})
        let context = try #require(await fixture.provider().snapshot().context)
        _ = try await controls.dispatch(.requestCancellation(context: context), beforeDispatch: {})
        fixture.server.releaseCancellationConfirmation()
        try #require(await waitUntilMainActor {
            fixture.task()?.nativeDispatch?.phase == .cancellationConfirmed
                && fixture.server.permissionAnswers.count == 2
        })
        #expect(fixture.server.permissionAnswers[0] == .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string("once")])
        ]))
        #expect(fixture.server.permissionAnswers[1] == .object([
            "outcome": .object(["outcome": .string("cancelled")])
        ]))
        #expect(await fixture.provider().snapshot().state == .cancelled)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func redeliveredPermissionAfterOwnershipRevocationCannotRewriteDecision() async throws {
        let fixture = try await ClaudeCodeNativeFixture(mode: .ownershipRevocationRedelivery)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("Approve once"), beforeDispatch: {})
        try #require(await waitUntilMainActor { fixture.task()?.attention == .waitingInput })
        let question = try #require(await fixture.provider().snapshot().questions.first)
        _ = try await controls.dispatch(.answerPermission(
            request: question.request, context: question.context, decision: .allowOnce
        ), beforeDispatch: {})
        fixture.ownership.revoke()
        fixture.server.releaseRedeliveredPermission()
        _ = try await waitForProviderOutcome(fixture.provider()) {
            $0.state == .unknown || $0.state == .stopped
        }
        #expect(fixture.server.permissionAnswers.count == 1)
        #expect(await fixture.provider().snapshot().questions.isEmpty)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func replayRevokedInsidePhysicalBeforeWriteIsNotWritten() async throws {
        let owner = Mutex<AgentTaskNativeOwnership?>(nil)
        let fixture = try await ClaudeCodeNativeFixture(
            mode: .ownershipRevocationRedelivery,
            replayWriteSeam: { _ in owner.withLock { $0 }?.revoke() }
        )
        defer { fixture.teardown() }
        owner.withLock { $0 = fixture.ownership }
        try await fixture.session.start()
        let controls = try fixture.controls()
        _ = try await controls.dispatch(.submitInstruction("Approve once"), beforeDispatch: {})
        try #require(await waitUntilMainActor { fixture.task()?.attention == .waitingInput })
        let question = try #require(await fixture.provider().snapshot().questions.first)
        _ = try await controls.dispatch(.answerPermission(
            request: question.request, context: question.context, decision: .allowOnce
        ), beforeDispatch: {})
        fixture.server.releaseRedeliveredPermission()
        _ = try await waitForProviderOutcome(fixture.provider()) {
            $0.state == .unknown || $0.state == .stopped
        }
        #expect(fixture.server.permissionAnswers.count == 1)
    }

    @Test func nativeLaunchUsesCallerDeadlineForPreparationAndSpawnNotSessionLifetime() async throws {
        let fixture = try await ClaudeCodeNativeFixture(
            mode: .loop, sessionDeadline: .claudeCodeACPUnbounded
        )
        defer { fixture.teardown() }
        try await fixture.session.start()
        #expect(fixture.server.preparationDeadlines.count == 2)
        #expect(fixture.server.spawnDeadlines.count == 1)
        #expect(fixture.server.preparationDeadlines.last == fixture.server.spawnDeadlines.first)
        let spawn = try #require(fixture.server.spawnDeadlines.first)
        #expect(spawn < ContinuousClock.now.advanced(by: .seconds(60)))
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func checkpointReachesFactoryNativeFactoryAndSessionGuardsDirectly() async throws {
        let evidence = try await makeResumeCheckpointForClaudeTests()
        let launches = Mutex(0)
        let profile = try ClaudeCodeACPSession.profile()
        let versions = PineAdapterContractVersionRange(
            minimum: .init(major: 1, minor: 1), maximum: .init(major: 1, minor: 1)
        )
        let observation = try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion(ClaudeCodeACPSession.pinnedVersion),
            detectedSchema: nil, offeredProfiles: [profile], offeredContractVersions: versions
        )
        let factoryID = try AdapterFactoryID(validating: "test.claude.direct.checkpoint")
        let factory = ClaudeCodeACPFactory(id: factoryID, observation: observation) { _ in
            ClaudeCodeACPAdmission(
                launch: { _ in
                    launches.withLock { $0 += 1 }
                    throw ClaudeCodeACPError.unavailable
                },
                cwd: "/fixture/task", deadline: .now.advanced(by: .seconds(30)), loadSession: nil,
                beforeStartWrite: {}, revokeOwnership: {}, sessionBound: { _ in },
                promptResponded: { _ in .recorded }, sessionCreated: { _ in }
            )
        }
        await #expect(throws: AdapterSessionError.checkpointNotSupported) {
            _ = try await factory.makeSession(evidence.request)
        }

        let fixture = try await ClaudeCodeNativeFixture(mode: .loop)
        defer { fixture.teardown() }
        let nativeFactory = try ClaudeCodeACPNativeFactory(
            materials: fixture.materials, factoryID: ClaudeCodeACPNativeFactory.factoryID()
        )
        await #expect(throws: AdapterSessionError.checkpointNotSupported) {
            _ = try await nativeFactory.makeSession(evidence.request)
        }
        #expect(throws: AdapterSessionError.checkpointNotSupported) {
            _ = try ClaudeCodeACPSession(
                request: evidence.request,
                launch: { _ in
                    launches.withLock { $0 += 1 }
                    throw ClaudeCodeACPError.unavailable
                },
                cwd: "/fixture/task", deadline: .now.advanced(by: .seconds(30)),
                beforeStartWrite: {}, revokeOwnership: {}, sessionBound: { _ in },
                promptResponded: { _ in .recorded }
            )
        }
        #expect(launches.withLock { $0 } == 0)
        #expect(fixture.server.spawnDeadlines.isEmpty)
    }

    @Test func admissionDiagnosticsRedactWorkingDirectoryAndSessionIdentifier() async throws {
        let cwd = "/tmp/sk-cwd-SECRET-marker"
        let sessionID = "sk-session-SECRET-marker"
        let admission = ClaudeCodeACPAdmission(
            launch: { _ in throw ClaudeCodeACPError.unavailable },
            cwd: cwd, deadline: .now.advanced(by: .seconds(1)),
            loadSession: try VendorReference(role: .conversation, value: sessionID),
            beforeStartWrite: {}, revokeOwnership: {}, sessionBound: { _ in },
            promptResponded: { _ in .recorded }, sessionCreated: { _ in }
        )
        var diagnostic = ""
        dump(admission, to: &diagnostic)
        #expect(!diagnostic.contains(cwd) && !diagnostic.contains(sessionID))
        #expect(diagnostic.contains("<redacted:claude-code-acp-admission>"))
    }

    @Test func consumedNativeFactoryRejectsSecondDirectMakeSessionWithoutSpawn() async throws {
        let fixture = try await ClaudeCodeNativeFixture(mode: .loop)
        defer { fixture.teardown() }
        let request = try #require(fixture.requestRecorder.request)
        await #expect(throws: AdapterSessionError.contractAlreadyConsumed) {
            _ = try await fixture.nativeFactory.makeSession(request)
        }
        #expect(fixture.server.spawnDeadlines.isEmpty)
    }

    @Test func ownerAndSpawnDiagnosticsRedactSecretTaskMetadata() async throws {
        let secret = "sk-native-SECRET-marker"
        let fixture = try await ClaudeCodeNativeFixture(mode: .loop, objective: secret)
        defer { fixture.teardown() }
        let spawned = try fixture.materials.spawn(.now.advanced(by: .seconds(1)))
        let control = ClaudeCodeACPNativeControl(registry: fixture.tasks, ownership: fixture.ownership)
        let composition = ClaudeCodeACPNativeComposition(tasks: fixture.tasks)
        let values: [Any] = [
            fixture.materials, fixture.nativeFactory, control, composition, spawned, spawned.child
        ]
        for value in values {
            var diagnostic = ""
            dump(value, to: &diagnostic)
            #expect(!diagnostic.contains(secret))
            #expect(diagnostic.contains("<redacted:"))
        }
    }

    @Test func compositionAndFactoryRejectForeignOrMismatchedIdentityWithoutSpawn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-claude-code-gates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: root.path, canonicalWorktreePath: root.path
        )
        let tasks = AgentTaskRegistry(persistence: ClaudeCodeNativeTaskStore())
        let reservation = try #require(await tasks.createNativeTask(
            project: project,
            descriptor: AgentDescriptor(agentType: .claudeCode, launchExecutable: "claude-agent-acp"),
            title: "ClaudeCode task", objective: "Identity gates"
        ))
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let lease = try #require(await runOnBackground {
            RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
        })
        let validator = ClaudeCodeNativeBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "claudeCode"),
            selectedExecutable: URL(fileURLWithPath: "/selected/claude-agent-acp")
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID,
            bindingID: binding.id, selection: selection, provenance: testLaunchProvenance
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        let neverSpawn: @Sendable (ContinuousClock.Instant) throws -> ClaudeCodeACPNativeMaterials.Spawn = { _ in
            preconditionFailure("negative composition gates must never spawn")
        }
        let ownership = try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        let composition = ClaudeCodeACPNativeComposition(tasks: tasks)
        let first = try await composition.compose(ClaudeCodeACPNativeMaterials(
            registry: tasks, ownership: ownership, workingDirectory: root,
            sessionDeadline: .now.advanced(by: .seconds(30)), spawn: neverSpawn
        ))
        #expect(composition.runtime(for: reservation.taskID) === first)

        let foreignTasks = AgentTaskRegistry(persistence: ClaudeCodeNativeTaskStore())
        await #expect(throws: AgentTaskNativeAdmissionError.staleOwner) {
            _ = try await composition.compose(ClaudeCodeACPNativeMaterials(
                registry: foreignTasks, ownership: ownership, workingDirectory: root,
                sessionDeadline: .now.advanced(by: .seconds(30)), spawn: neverSpawn
            ))
        }

        func replacement(
            agentID: String,
            runID: UUID,
            binding: AgentTaskEnvironmentBinding,
            permissions: AgentTaskNativeSettingSelection = AgentTaskNativeSettingSelection()
        ) throws -> ClaudeCodeACPNativeMaterials {
            let selection = AgentTaskNativeLaunchPolicy.Selection(
                agentID: try AgentID(migratingLegacyStableIdentifier: agentID),
                selectedExecutable: URL(fileURLWithPath: "/selected/claude-agent-acp")
            )
            guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
                taskID: reservation.taskID, runID: runID, bindingID: binding.id,
                selection: selection, permissions: permissions,
                configurationCapabilities: try AgentTaskConfigurationCapabilities(
                    transportAdvertised: [AgentTaskConfigurationCapability(key: .permissions, state: .probed)]
                ),
                provenance: testLaunchProvenance
            ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
            let validator = ClaudeCodeNativeBindingValidator(binding: binding, lease: lease)
            let ownership = try AgentTaskNativeOwnership(
                policy: policy, binding: binding, filesystem: lease, bindings: validator,
                environment: ProcessInfo.processInfo.environment
            )
            return ClaudeCodeACPNativeMaterials(
                registry: tasks, ownership: ownership, workingDirectory: root,
                sessionDeadline: .now.advanced(by: .seconds(30)), spawn: neverSpawn
            )
        }

        let newRun = UUID()
        let newRunBinding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: newRun
        )
        let differentRun = try replacement(agentID: "claudeCode", runID: newRun, binding: newRunBinding)
        await #expect(throws: AgentTaskNativeAdmissionError.staleOwner) {
            _ = try await composition.compose(differentRun)
        }
        let newBinding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let differentBinding = try replacement(
            agentID: "claudeCode", runID: reservation.runID, binding: newBinding
        )
        await #expect(throws: AgentTaskNativeAdmissionError.staleOwner) {
            _ = try await composition.compose(differentBinding)
        }

        let wrongAgent = try replacement(agentID: "openCode", runID: reservation.runID, binding: binding)
        #expect(throws: AdapterSessionError.contractMismatch) {
            _ = try ClaudeCodeACPNativeFactory(
                materials: wrongAgent, factoryID: ClaudeCodeACPNativeFactory.factoryID()
            )
        }
        let override = try AgentTaskNativeSettingSelection.explicit(nativeValue: "acceptEdits", scope: .session)
        let overridden = try replacement(
            agentID: "claudeCode", runID: reservation.runID, binding: binding, permissions: override
        )
        #expect(throws: AdapterSessionError.contractMismatch) {
            _ = try ClaudeCodeACPNativeFactory(
                materials: overridden, factoryID: ClaudeCodeACPNativeFactory.factoryID()
            )
        }
        await first.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func stoppedProviderRuntimeIsReplacedByFreshComposition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-claude-code-compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: root.path, canonicalWorktreePath: root.path
        )
        let tasks = AgentTaskRegistry(persistence: ClaudeCodeNativeTaskStore())
        let reservation = try #require(await tasks.createNativeTask(
            project: project,
            descriptor: AgentDescriptor(agentType: .claudeCode, launchExecutable: "claude-agent-acp"),
            title: "ClaudeCode task", objective: "Explicit request"
        ))
        let taskID = reservation.taskID
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let lease = try #require(await runOnBackground {
            RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
        })
        let validator = ClaudeCodeNativeBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "claudeCode"),
            selectedExecutable: URL(fileURLWithPath: "/selected/claude-agent-acp")
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID,
            bindingID: binding.id, selection: selection, provenance: testLaunchProvenance
        ) else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        let neverSpawn: @Sendable (ContinuousClock.Instant) throws -> ClaudeCodeACPNativeMaterials.Spawn = { _ in
            preconditionFailure("composition test never launches a child")
        }

        let ownership = try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        let materials = ClaudeCodeACPNativeMaterials(
            registry: tasks, ownership: ownership, workingDirectory: root,
            sessionDeadline: .now.advanced(by: .seconds(30)),
            spawn: neverSpawn
        )
        let composition = ClaudeCodeACPNativeComposition(tasks: tasks)
        let first = try await composition.compose(materials)
        #expect(composition.runtime(for: taskID) === first)
        #expect(!(await first.isProviderStopped()))

        // An explicit stop (or a failed start) leaves the provider session
        // stopped; the retained runtime is dead and must not block the
        // documented in-session re-prepare.
        await first.stop(deadline: .now.advanced(by: .seconds(2)))
        #expect(await first.isProviderStopped())
        let replacement = try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)
        let replacementMaterials = ClaudeCodeACPNativeMaterials(
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
        let fixture = try await ClaudeCodeNativeFixture(mode: .loop, forceAdmissionFailure: true)
        defer { fixture.teardown() }
        await #expect(throws: AgentTaskNativeAdmissionError.unavailable) {
            try await fixture.session.start()
        }
        let identity = try #require(fixture.server.spawnedIdentity)
        let remaining = await runOnBackground { UserTaskProcessInspector.identity(for: identity.processID) }
        #expect(remaining == nil || remaining != identity)
    }

    private func waitForProviderOutcome(
        _ provider: ClaudeCodeACPSession,
        until predicate: @Sendable (ClaudeCodeACPSession.Snapshot) -> Bool
    ) async throws -> ClaudeCodeACPSession.Snapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let snapshot = await provider.snapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClaudeCodeACPError.unavailable
    }
}

private enum ClaudeCodeNativeMode {
    case loop, question, cancel, lateChild, cancelRace
    case ackRace, cancelLateQuestion, cancelRaceQuestion
    case cancelRedeliveredPermission, ownershipRevocationRedelivery
}

nonisolated private final class ClaudeCodeNativeServer: Sendable {
    let cancellation = AsyncContinuationGate()
    let acknowledgementRace = AsyncContinuationGate()
    let redeliveredPermission = AsyncContinuationGate()
    private let promptIDs = Mutex<[String]>([])
    private let phases = Mutex<[String]>([])
    private let answers = Mutex<[AgentEventJSON]>([])
    private let permissionResults = Mutex<[AgentEventJSON]>([])
    private let preparationInstants = Mutex<[ContinuousClock.Instant]>([])
    private let spawnInstants = Mutex<[ContinuousClock.Instant]>([])
    private let admissionIdentity = Mutex<UserTaskProcessIdentity?>(nil)
    private let cancellationWrites = Mutex(0)
    private let terminalReplies = Mutex(0)
    var promptSessionIDs: [String] { promptIDs.withLock { $0 } }
    var phaseAtPrompt: [String] { phases.withLock { $0 } }
    var questionAnswers: [AgentEventJSON] { answers.withLock { $0 } }
    var permissionAnswers: [AgentEventJSON] { permissionResults.withLock { $0 } }
    var preparationDeadlines: [ContinuousClock.Instant] { preparationInstants.withLock { $0 } }
    var spawnDeadlines: [ContinuousClock.Instant] { spawnInstants.withLock { $0 } }
    var spawnedIdentity: UserTaskProcessIdentity? { admissionIdentity.withLock { $0 } }
    var cancellationWriteCount: Int { cancellationWrites.withLock { $0 } }
    var terminalReplyCount: Int { terminalReplies.withLock { $0 } }
    func recordSpawnedIdentity(_ identity: UserTaskProcessIdentity) {
        admissionIdentity.withLock { $0 = identity }
    }
    func recordPrompt(_ id: String, phase: String) {
        promptIDs.withLock { $0.append(id) }
        phases.withLock { $0.append(phase) }
    }
    func recordAnswer(_ value: AgentEventJSON) { answers.withLock { $0.append(value) } }
    func recordPermissionAnswer(_ value: AgentEventJSON) { permissionResults.withLock { $0.append(value) } }
    func recordPreparationDeadline(_ value: ContinuousClock.Instant) { preparationInstants.withLock { $0.append(value) } }
    func recordSpawnDeadline(_ value: ContinuousClock.Instant) { spawnInstants.withLock { $0.append(value) } }
    func recordTerminalReply() { terminalReplies.withLock { $0 += 1 } }
    func recordCancellationWrite() { cancellationWrites.withLock { $0 += 1 } }
    func releaseCancellationConfirmation() { cancellation.resolve() }
    func releaseAcknowledgementRace() { acknowledgementRace.resolve() }
    func releaseRedeliveredPermission() { redeliveredPermission.resolve() }
}

nonisolated private final class ClaudeCodeNativeIngressRecorder: Sendable {
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

nonisolated private final class ClaudeCodeNativeSessionRecorder: Sendable {
    private let value = Mutex<ClaudeCodeACPSession?>(nil)
    func set(_ session: ClaudeCodeACPSession) { value.withLock { $0 = session } }
    var session: ClaudeCodeACPSession {
        guard let session = value.withLock({ $0 }) else { preconditionFailure("Session was not recorded") }
        return session
    }
}

nonisolated private final class ClaudeCodeNativeRequestRecorder: Sendable {
    private let value = Mutex<AgentAdapterSessionRequest?>(nil)
    var request: AgentAdapterSessionRequest? { value.withLock { $0 } }
    func set(_ request: AgentAdapterSessionRequest) { value.withLock { $0 = request } }
}

nonisolated private struct ClaudeCodeNativeFactoryForwarder: AgentAdapterFactory {
    let native: ClaudeCodeACPNativeFactory
    let recorder: ClaudeCodeNativeRequestRecorder
    var id: AdapterFactoryID { native.id }
    func probe() async throws -> AdapterProbeResult { try await native.probe() }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        recorder.set(request)
        return try await native.makeSession(request)
    }
}

private actor ClaudeCodeNativeTaskStore: AgentTaskPersisting {
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

private actor ClaudeCodeNativeBindingValidator: AgentTaskNativeBindingValidator {
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

nonisolated private struct ClaudeCodeNativeFixture: Sendable {
    let tasks: AgentTaskRegistry
    let adapters: AgentAdapterRegistry
    let session: any AgentAdapterSession
    let taskID: UUID
    let ownership: AgentTaskNativeOwnership
    let materials: ClaudeCodeACPNativeMaterials
    let nativeFactory: ClaudeCodeACPNativeFactory
    let requestRecorder: ClaudeCodeNativeRequestRecorder
    let server: ClaudeCodeNativeServer
    let recorder: ClaudeCodeNativeSessionRecorder
    let ingress: ClaudeCodeNativeIngressRecorder
    let peer: CodexAppServerStdioChannel
    let serverTask: Task<Void, Never>
    let root: URL
    private let peerError: Pipe
    private let error: Pipe

    @MainActor func controls() throws -> any AgentAdapterControlledSession {
        try adapters.controls(for: session)
    }
    @MainActor func task() -> AgentTask? { tasks.task(for: taskID) }
    func provider() -> ClaudeCodeACPSession { recorder.session }

    @MainActor
    init(
        mode: ClaudeCodeNativeMode,
        acknowledgementGate: AsyncContinuationGate? = nil,
        acknowledgementPersistenceGate: AsyncContinuationGate? = nil,
        cancellationGate: AsyncContinuationGate? = nil,
        forceAdmissionFailure: Bool = false,
        sessionDeadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30)),
        objective: String = "Explicit request",
        replayWriteSeam: @escaping @Sendable (AgentTaskNativeOwnership.Effect) throws -> Void = { _ in }
    ) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-claude-code-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: root.path, canonicalWorktreePath: root.path
        )
        let tasks = AgentTaskRegistry(persistence: ClaudeCodeNativeTaskStore())
        self.tasks = tasks
        let reservation = try #require(await tasks.createNativeTask(
            project: project,
            descriptor: AgentDescriptor(agentType: .claudeCode, launchExecutable: "claude-agent-acp"),
            title: "ClaudeCode task", objective: objective
        ))
        taskID = reservation.taskID
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let lease = try #require(await runOnBackground {
            RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
        })
        let validator = ClaudeCodeNativeBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(migratingLegacyStableIdentifier: "claudeCode"),
            selectedExecutable: URL(fileURLWithPath: "/selected/claude-agent-acp")
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
        let recorder = ClaudeCodeNativeSessionRecorder()
        self.recorder = recorder
        let ingress = ClaudeCodeNativeIngressRecorder()
        self.ingress = ingress
        let server = ClaudeCodeNativeServer()
        self.server = server
        let fixtureRoot = root
        let materials = ClaudeCodeACPNativeMaterials(
            registry: tasks, ownership: ownership, workingDirectory: root,
            sessionDeadline: sessionDeadline, sessionCreated: { recorder.set($0) },
            acknowledgementSeam: {
                await acknowledgementGate?.wait()
                await acknowledgementPersistenceGate?.wait()
            },
            cancellationSeam: { await cancellationGate?.wait() },
            replayWriteSeam: replayWriteSeam,
            prepareLaunch: { deadline in server.recordPreparationDeadline(deadline) },
            spawn: { deadline in
                server.recordSpawnDeadline(deadline)
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
                    return ClaudeCodeACPNativeMaterials.Spawn(
                        child: ClaudeCodeACPOwnedChild(
                            channel: realChannel, processIdentity: realReceipt.identity,
                            close: { realChannel.close() },
                            stop: { deadline in
                                realChannel.close()
                                await realChild.stop(deadline: deadline)
                            }
                        ), receipt: realReceipt
                    )
                }
                return ClaudeCodeACPNativeMaterials.Spawn(
                    child: ClaudeCodeACPOwnedChild(
                        channel: channel, processIdentity: processIdentity,
                        close: { channel.close() }, stop: { _ in peerChannel.close() }
                    ), receipt: receipt
                )
            }
        )
        self.materials = materials
        let registered = try ClaudeCodeACPNativeFactory.registered(materials: materials)
        nativeFactory = registered.factory
        let requestRecorder = ClaudeCodeNativeRequestRecorder()
        self.requestRecorder = requestRecorder
        let forwarder = ClaudeCodeNativeFactoryForwarder(native: registered.factory, recorder: requestRecorder)
        let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "claudeCode"))
        adapters = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(registered.descriptor, forwarder)]
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

    private static func serve(
        _ peer: CodexAppServerStdioChannel, mode: ClaudeCodeNativeMode,
        tasks: AgentTaskRegistry, taskID: UUID, server: ClaudeCodeNativeServer
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
                            "name": .string(ClaudeCodeACPSession.pinnedAgentName), "version": .string(ClaudeCodeACPSession.pinnedVersion)
                        ]),
                        "agentCapabilities": .object(["loadSession": .bool(true)])
                    ])), to: peer)
                case .request(let id, "session/new", _):
                    try await write(.response(id, result: .object([
                        "sessionId": .string("ses_native"), "configOptions": .array([])
                    ])), to: peer)
                case .request(let id, "session/prompt", let params):
                    promptID = id
                    promptCount += 1
                    let fields = try ClaudeCodeACPWire.object(params)
                    let sessionID = try ClaudeCodeACPWire.string(fields["sessionId"])
                    let phase = await tasks.task(for: taskID)?.nativeDispatch?.phase.rawValue ?? "missing"
                    server.recordPrompt(sessionID, phase: phase)
                    switch mode {
                    case .loop:
                        try await write(chunk("result-\(promptCount)"), to: peer)
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
                    case .cancelRedeliveredPermission, .ownershipRevocationRedelivery:
                        try await write(.request(.string("native-permission"), method: "session/request_permission",
                                                 params: permission()), to: peer)
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
                        if case .cancelRedeliveredPermission = mode {
                            try await write(.request(.string("native-permission"),
                                                     method: "session/request_permission",
                                                     params: permission()), to: peer)
                        }
                    }
                case .response(.string("native-permission"), let result):
                    server.recordPermissionAnswer(result)
                    if case .ownershipRevocationRedelivery = mode {
                        await server.redeliveredPermission.wait()
                        try await write(.request(.string("native-permission"),
                                                 method: "session/request_permission",
                                                 params: permission()), to: peer)
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
        try await peer.write(ClaudeCodeACPWire.encode(message), deadline: .now.advanced(by: .seconds(10)))
    }

    private static func chunk(_ text: String) -> CodexAppServerMessage {
        .notification(method: "session/update", params: .object([
            "sessionId": .string("ses_native"), "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string(text)])
            ])
        ]))
    }

    private static func permission() -> AgentEventJSON {
        .object([
            "sessionId": .string("ses_native"),
            "toolCall": .object([
                "toolCallId": .string("write-native"), "title": .string("Write fixture"), "kind": .string("edit")
            ]),
            "options": .array([
                .object(["optionId": .string("once"), "kind": .string("allow_once")]),
                .object(["optionId": .string("reject"), "kind": .string("reject_once")])
            ])
        ])
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
