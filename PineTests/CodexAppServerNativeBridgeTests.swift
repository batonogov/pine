import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Pine

/// Deterministic owned-stdio session tests (#1723): the task registry mints
/// admission authority, the adapter registry mints the session, an in-memory
/// peer speaks the pinned protocol, and the semantic controls
/// (submit/answer/cancel) drive the full persist-before-send path.
@Suite(.serialized)
@MainActor
struct CodexAppServerNativeBridgeTests {
    enum Mode {
        case approval, followup, approvalDuplicate, question
        case interrupt, interruptQueuedInput, lateCompletion, unknownRequest, childDeath
    }

    @Test func sessionStartsBindsThreadAndRejectsDoubleStart() async throws {
        let fixture = try await NativeBridgeFixture(mode: .approval)
        defer { fixture.teardown() }
        try await fixture.session.start()
        guard await fixture.waitUntil({
            fixture.task()?.nativeDispatch?.phase == .sessionBound
        }) else {
            Issue.record("Session binding was not recorded")
            return
        }
        let task = try #require(fixture.task())
        #expect(task.runs.count == 1 && task.runs[0].terminalID == nil)
        #expect(task.runs[0].liveness == .live)
        #expect(task.nativeDispatch?.conversation?.opaqueIdentifier == "thr_fixture")
        await #expect(throws: AdapterSessionError.self) {
            try await fixture.session.start()
        }
        // Discovery from the fixture's empty catalog and empty config:
        // the documented floor holds, nothing is promoted, and the
        // login-required account state is reported truthfully.
        if let report = await fixture.sessionRecorder.value?.discoveryReport {
            #expect(report.sessionStart == .started)
            #expect(report.authentication == .loginRequired)
            #expect(report.configurationCapabilities.model.state == .researched)
            #expect(report.configurationCapabilities.reasoningEffort.state == .researched)
            #expect(report.configurationCapabilities.permissions.state == .researched)
            #expect(report.effectiveModel == .unknown)
            #expect(report.effectiveReasoningEffort == .unknown)
            #expect(report.effectivePermissions == .unknown)
        } else {
            Issue.record("The fixture observations did not produce a discovery report")
        }
        // The report belongs to the live session: stopping clears it so a
        // future view wiring cannot render a stale observation.
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
        #expect(await fixture.sessionRecorder.value?.discoveryReport == nil)
    }

    @Test func approvalRoundTripIsOneShotThenTurnCompletes() async throws {
        let fixture = try await NativeBridgeFixture(mode: .approval)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let dispatch = try fixture.controls()
        #expect(try await dispatch.dispatch(
            .submitInstruction("run the check"), beforeDispatch: {}
        ) == .acknowledged)
        guard await fixture.recorder.waitForCount(2, within: 10) else {
            Issue.record("Approval attention was not ingested: \(fixture.recorder.phases)")
            return
        }
        let events = fixture.recorder.snapshot
        guard case .approval(let attention)? = events.last?.event else {
            Issue.record("Last event was not an approval: \(fixture.recorder.phases)")
            return
        }
        let requestReference = attention.request
        let contextReference = try #require(attention.context)
        #expect(try await dispatch.dispatch(
            .answerPermission(request: requestReference, context: contextReference, decision: .allowOnce),
            beforeDispatch: {}
        ) == .acknowledged)
        // A second answer to the same exact request is no longer answerable.
        await #expect(throws: AgentAdapterControlError.unsupported) {
            try await dispatch.dispatch(
                .answerPermission(request: requestReference, context: contextReference, decision: .deny),
                beforeDispatch: {}
            )
        }
        guard await fixture.recorder.waitForCount(3, within: 10) else {
            Issue.record("Resolution or turn completion was not ingested: \(fixture.recorder.phases)")
            return
        }
        #expect(fixture.recorder.phases == [
            "lifecycle:started", "approval", "requestResolved"
        ])
        #expect(fixture.server.decision == "accept")
        // The completed turn settles the journal; the session stays ready.
        guard await fixture.waitUntil({
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        }) else {
            Issue.record("Turn completion was not recorded")
            return
        }
        let task = try #require(fixture.task())
        #expect(task.nativeDispatch?.submissions.last?.phase == .responseObserved)
        #expect(task.executionState == .unknown && task.runs[0].state == .idle)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func followupSubmitChainsOnTheObservedSubmission() async throws {
        let fixture = try await NativeBridgeFixture(mode: .followup)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let dispatch = try fixture.controls()
        #expect(try await dispatch.dispatch(
            .submitInstruction("first turn"), beforeDispatch: {}
        ) == .acknowledged)
        guard await fixture.waitUntil({
            fixture.task()?.nativeDispatch?.phase == .parentSettlementUnknown
        }) else {
            Issue.record("First turn completion was not recorded: \(fixture.recorder.phases)")
            return
        }
        let firstID = try #require(fixture.task()?.nativeDispatch?.submissions.first?.id)
        #expect(try await dispatch.dispatch(
            .submitInstruction("second turn"), beforeDispatch: {}
        ) == .acknowledged)
        guard await fixture.waitUntil({
            fixture.task()?.nativeDispatch?.phase == .inputAcknowledged
        }) else {
            Issue.record("Followup acknowledgement was not recorded: \(fixture.recorder.phases)")
            return
        }
        let submissions = try #require(fixture.task()?.nativeDispatch?.submissions)
        #expect(submissions.count == 2)
        #expect(submissions[0].phase == .responseObserved)
        #expect(submissions[1].phase == .acknowledged)
        #expect(submissions[1].afterResponseTo == firstID)
        #expect(fixture.task()?.nativeDispatch?.operationID == "turn_fixture_2")
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func duplicateApprovalRedeliveryReplaysWrittenAnswer() async throws {
        let fixture = try await NativeBridgeFixture(mode: .approvalDuplicate)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let dispatch = try fixture.controls()
        #expect(try await dispatch.dispatch(
            .submitInstruction("run the check"), beforeDispatch: {}
        ) == .acknowledged)
        guard await fixture.recorder.waitForCount(2, within: 10) else {
            Issue.record("Approval attention was not ingested")
            return
        }
        let events = fixture.recorder.snapshot
        guard case .approval(let attention)? = events.last?.event,
              let contextReference = attention.context else {
            Issue.record("Last event was not a scoped approval: \(fixture.recorder.phases)")
            return
        }
        #expect(try await dispatch.dispatch(
            .answerPermission(request: attention.request, context: contextReference, decision: .allowOnce),
            beforeDispatch: {}
        ) == .acknowledged)
        guard await fixture.recorder.waitForCount(3, within: 10) else {
            Issue.record("Resolution or turn completion was not ingested")
            return
        }
        // The server saw the written answer twice (redelivery replay) and the
        // user was prompted exactly once.
        #expect(fixture.server.answerDeliveries == 2)
        #expect(fixture.recorder.phases.filter({ $0 == "approval" }).count == 1)
        #expect(fixture.recorder.phases == [
            "lifecycle:started", "approval", "requestResolved"
        ])
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func questionAnswersUseExactRequestIdentity() async throws {
        let fixture = try await NativeBridgeFixture(mode: .question)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let dispatch = try fixture.controls()
        #expect(try await dispatch.dispatch(
            .submitInstruction("which branch?"), beforeDispatch: {}
        ) == .acknowledged)
        guard await fixture.recorder.waitForCount(2, within: 10) else {
            Issue.record("Question attention was not ingested")
            return
        }
        let events = fixture.recorder.snapshot
        guard case .question(let attention)? = events.last?.event,
              let contextReference = attention.context else {
            Issue.record("Last event was not a scoped question: \(fixture.recorder.phases)")
            return
        }
        // A foreign request identity is refused even with the right context.
        await #expect(throws: AgentAdapterControlError.unsupported) {
            try await dispatch.dispatch(
                .answerQuestion(
                    request: VendorReference(role: .request, value: "wrong-digest"),
                    context: contextReference,
                    answers: ["q1": ["main"]]
                ),
                beforeDispatch: {}
            )
        }
        #expect(try await dispatch.dispatch(
            .answerQuestion(request: attention.request, context: contextReference, answers: ["q1": ["main"]]),
            beforeDispatch: {}
        ) == .acknowledged)
        #expect(fixture.server.questionAnswer == .object([
            "q1": .object(["answers": .array([.string("main")])])
        ]))
        guard await fixture.recorder.waitForCount(3, within: 10) else {
            Issue.record("Resolution or turn completion was not ingested")
            return
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func cancellationIsRequestedUntilProviderConfirmation() async throws {
        let fixture = try await NativeBridgeFixture(mode: .interrupt)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let dispatch = try fixture.controls()
        #expect(try await dispatch.dispatch(
            .submitInstruction("long task"), beforeDispatch: {}
        ) == .acknowledged)
        guard await fixture.recorder.waitForCount(1, within: 10) else {
            Issue.record("Turn start was not ingested")
            return
        }
        let turnReference = try VendorReference(role: .turn, value: "turn_fixture_1")
        #expect(try await dispatch.dispatch(
            .requestCancellation(context: turnReference), beforeDispatch: {}
        ) == .acknowledged)
        // A second cancellation request is refused; the turn is already being
        // interrupted.
        await #expect(throws: AgentAdapterControlError.unsupported) {
            try await dispatch.dispatch(
                .requestCancellation(context: turnReference), beforeDispatch: {}
            )
        }
        fixture.server.releaseCancellationConfirmation()
        guard await fixture.recorder.waitForCount(2, within: 10) else {
            Issue.record("Confirmed cancellation was not ingested")
            return
        }
        #expect(fixture.recorder.phases == ["lifecycle:started", "lifecycle:cancelled"])
        // The confirmed cancellation is terminal: the session fences itself
        // and the run goes stale in-session.
        guard await fixture.waitUntil({
            fixture.task()?.runs.last?.liveness == .stale
        }) else {
            Issue.record("Cancelled run was not observed stale")
            return
        }
        let task = try #require(fixture.task())
        #expect(task.nativeDispatch?.cancellationRequested == true)
        #expect(task.nativeDispatch?.phase == .unavailable)
        await #expect(throws: AdapterSessionError.self) {
            try await dispatch.dispatch(
                .submitInstruction("another"), beforeDispatch: {}
            )
        }
    }

    @Test func interruptWithQueuedInputRefusesThePendingAnswer() async throws {
        let fixture = try await NativeBridgeFixture(mode: .interruptQueuedInput)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let dispatch = try fixture.controls()
        #expect(try await dispatch.dispatch(
            .submitInstruction("long task"), beforeDispatch: {}
        ) == .acknowledged)
        guard await fixture.recorder.waitForCount(2, within: 10) else {
            Issue.record("Question attention was not ingested")
            return
        }
        let events = fixture.recorder.snapshot
        guard case .question(let attention)? = events.last?.event,
              let contextReference = attention.context else {
            Issue.record("Last event was not a scoped question: \(fixture.recorder.phases)")
            return
        }
        let turnReference = try VendorReference(role: .turn, value: "turn_fixture_1")
        #expect(try await dispatch.dispatch(
            .requestCancellation(context: turnReference), beforeDispatch: {}
        ) == .acknowledged)
        // The queued question left the Needs decision with the cancellation.
        await #expect(throws: AgentAdapterControlError.unsupported) {
            try await dispatch.dispatch(
                .answerQuestion(
                    request: attention.request, context: contextReference,
                    answers: ["q1": ["main"]]
                ),
                beforeDispatch: {}
            )
        }
        fixture.server.releaseCancellationConfirmation()
        guard await fixture.recorder.waitForCount(3, within: 10) else {
            Issue.record("Confirmed cancellation was not ingested")
            return
        }
        #expect(fixture.recorder.phases == [
            "lifecycle:started", "question", "lifecycle:cancelled"
        ])
        guard await fixture.waitUntil({
            fixture.task()?.runs.last?.liveness == .stale
        }) else {
            Issue.record("Cancelled run was not observed stale")
            return
        }
    }

    @Test func lateCompletionAfterCancellationFencesTheSession() async throws {
        let fixture = try await NativeBridgeFixture(mode: .lateCompletion)
        defer { fixture.teardown() }
        try await fixture.session.start()
        let dispatch = try fixture.controls()
        #expect(try await dispatch.dispatch(
            .submitInstruction("long task"), beforeDispatch: {}
        ) == .acknowledged)
        guard await fixture.recorder.waitForCount(1, within: 10) else {
            Issue.record("Turn start was not ingested")
            return
        }
        let turnReference = try VendorReference(role: .turn, value: "turn_fixture_1")
        #expect(try await dispatch.dispatch(
            .requestCancellation(context: turnReference), beforeDispatch: {}
        ) == .acknowledged)
        // The provider completes the turn anyway: a race outcome, never
        // Ready. Poll the fence observable; no further control may dispatch.
        guard await fixture.waitUntil({
            fixture.task()?.nativeDispatch?.phase == .unavailable
        }) else {
            Issue.record("Late completion did not fence the session")
            return
        }
        await #expect(throws: AdapterSessionError.self) {
            try await dispatch.dispatch(
                .submitInstruction("another"), beforeDispatch: {}
            )
        }
    }

    @Test func childDeathIsANegativeObservationForTheRegistry() async throws {
        let fixture = try await NativeBridgeFixture(mode: .childDeath)
        defer { fixture.teardown() }
        // The peer dies on its own immediately after the thread bind, so the
        // live window can close during startup. Failing the start closed is
        // acceptable; a live run is not.
        do {
            try await fixture.session.start()
        } catch {
            // Only the peer's own post-bind death may fence the start; an
            // unrelated startup failure must still fail this test.
            #expect(fixture.server.childDeathClosed, "Start failed before the peer died: \(error)")
        }
        guard await fixture.waitUntil({
            fixture.task()?.nativeDispatch?.phase == .unavailable
        }) else {
            Issue.record("Dead child was not observed unavailable")
            return
        }
        let task = try #require(fixture.task())
        if let run = task.runs.last {
            #expect(run.liveness == .stale)
        }
        #expect(task.lifecycle == .paused)
    }

    @Test func unknownServerRequestReceivesMethodError() async throws {
        let fixture = try await NativeBridgeFixture(mode: .unknownRequest)
        defer { fixture.teardown() }
        try await fixture.session.start()
        guard await fixture.server.waitForUnknownRejection(within: 10) else {
            Issue.record("Unknown server request was not rejected with a method error")
            return
        }
        #expect(fixture.server.unknownRejectionCode == -32601)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func stopFencesControlsAndLateTraffic() async throws {
        let fixture = try await NativeBridgeFixture(mode: .approval)
        defer { fixture.teardown() }
        try await fixture.session.start()
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
        let dispatch = try fixture.controls()
        await #expect(throws: AdapterSessionError.self) {
            try await dispatch.dispatch(
                .submitInstruction("too late"), beforeDispatch: {}
            )
        }
        await #expect(throws: AdapterSessionError.self) {
            try await fixture.session.start()
        }
    }

    @Test func oneShotFactoryMintsAtMostOneSession() async throws {
        let fixture = try await NativeBridgeFixture(mode: .approval)
        defer { fixture.teardown() }
        _ = try await fixture.session.start()
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(2)))
        await #expect(throws: AdapterSessionError.contractAlreadyConsumed) {
            try await fixture.adapters.makeSession(
                contract: fixture.contract,
                resumeFrom: nil,
                downstream: { _ in .accepted }
            )
        }
    }
}

// MARK: - Fixture

nonisolated private final class BridgeServerSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var decisionValue: String?
    private var answerDeliveriesValue = 0
    private var questionAnswerValue: AgentEventJSON?
    private var unknownRejectionCodeValue: Int64?
    private var cancellationConfirmationReleasedValue = false
    private var childDeathClosedValue = false

    var decision: String? { lock.withLock { decisionValue } }
    var answerDeliveries: Int { lock.withLock { answerDeliveriesValue } }
    var questionAnswer: AgentEventJSON? { lock.withLock { questionAnswerValue } }
    var unknownRejectionCode: Int64? { lock.withLock { unknownRejectionCodeValue } }
    var childDeathClosed: Bool { lock.withLock { childDeathClosedValue } }

    func setDecision(_ value: String) { lock.withLock { decisionValue = value } }
    func markChildDeathClosed() { lock.withLock { childDeathClosedValue = true } }
    func recordAnswerDelivery() { lock.withLock { answerDeliveriesValue += 1 } }
    func setQuestionAnswer(_ value: AgentEventJSON) { lock.withLock { questionAnswerValue = value } }
    func setUnknownRejection(_ code: Int64) { lock.withLock { unknownRejectionCodeValue = code } }

    /// The tests need the "already interrupting" refusal to be observed before
    /// the provider confirms; an instant confirmation fences the session first.
    func releaseCancellationConfirmation() {
        lock.withLock { cancellationConfirmationReleasedValue = true }
    }

    func waitForCancellationRelease(within seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if lock.withLock({ cancellationConfirmationReleasedValue }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return lock.withLock { cancellationConfirmationReleasedValue }
    }

    func waitForUnknownRejection(within seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if lock.withLock { unknownRejectionCodeValue } != nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return lock.withLock { unknownRejectionCodeValue } != nil
    }
}

nonisolated private final class CandidateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AdapterCandidate] = []

    func observe(_ event: ValidatedAgentEvent) {
        lock.withLock { values.append(event.candidate) }
    }

    var snapshot: [AdapterCandidate] { lock.withLock { values } }

    var phases: [String] {
        snapshot.map { candidate in
            switch candidate.event {
            case let .lifecycle(event): "lifecycle:\(event.phase)"
            case .question: "question"
            case .approval: "approval"
            case .requestResolved: "requestResolved"
            case .tool: "tool"
            case .processExited: "processExited"
            }
        }
    }

    func waitForCount(_ count: Int, within seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if lock.withLock { values.count } >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return lock.withLock { values.count } >= count
    }
}

/// In-memory persistence for the bridge fixture: the same durable
/// round-trip contract as the real store, minus file I/O.
private actor InMemoryTaskStore: AgentTaskPersisting {
    private var data = Data("[]".utf8)
    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
            status: .loaded,
            tasks: (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? [],
            revision: nil,
            requiresMigration: false,
            envelope: .empty
        )
    }
    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        guard tasks.allSatisfy({ $0.nativeDispatch?.isValid(for: $0) ?? true }),
              let encoded = try? JSONEncoder().encode(tasks) else { return .rejected(.invalidMetadata) }
        data = encoded
        return .saved(taskCount: tasks.count)
    }
}

private actor NativeBridgeBindingValidator: AgentTaskNativeBindingValidator {
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

nonisolated final class CodexSessionRecorder: Sendable {
    private let session = Mutex<CodexAppServerNativeSession?>(nil)
    var value: CodexAppServerNativeSession? { session.withLock { $0 } }
    func set(_ value: CodexAppServerNativeSession) { session.withLock { $0 = value } }
}

/// Records the concrete session the production factory creates, because the
/// registry hands tests only its `CoreBoundAdapterSession` wrapper.
nonisolated private struct RecordingCodexNativeFactory: AgentAdapterFactory {
    let underlying: CodexAppServerNativeFactory
    let recorder: CodexSessionRecorder
    var id: AdapterFactoryID { underlying.id }
    func probe() async throws -> AdapterProbeResult {
        try await underlying.probe()
    }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        let session = try await underlying.makeSession(request)
        if let concrete = session as? CodexAppServerNativeSession {
            recorder.set(concrete)
        }
        return session
    }
}

nonisolated private struct NativeBridgeFixture: Sendable {
    let tasks: AgentTaskRegistry
    let adapters: AgentAdapterRegistry
    let contract: NegotiatedAdapterContract
    let session: any AgentAdapterSession
    let sessionRecorder: CodexSessionRecorder
    let taskID: UUID
    let recorder: CandidateRecorder
    let server: BridgeServerSignals
    let peer: CodexAppServerStdioChannel
    let serverTask: Task<Void, Never>
    let root: URL
    private let peerError: Pipe
    private let error: Pipe

    @MainActor
    func controls() throws -> any AgentAdapterControlledSession {
        try adapters.controls(for: session)
    }

    @MainActor
    func task() -> AgentTask? {
        tasks.task(for: taskID)
    }

    /// Polls a fence-observable registry state; no unconditional sleeps.
    @MainActor
    func waitUntil(_ condition: @MainActor () -> Bool, within seconds: Double = 10) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func teardown() {
        serverTask.cancel()
        peer.close()
        peerError.fileHandleForReading.closeFile()
        error.fileHandleForReading.closeFile()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    init(mode: CodexAppServerNativeBridgeTests.Mode) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-native-bridge-\(UUID().uuidString)")
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: root.path, canonicalWorktreePath: root.path
        )
        let store = InMemoryTaskStore()
        let tasks = AgentTaskRegistry(persistence: store)
        self.tasks = tasks
        let reservation = try #require(await tasks.createNativeTask(
            project: project,
            descriptor: AgentDescriptor(agentType: .codex, launchExecutable: "codex"),
            title: "Bridge task", objective: "Explicit request"
        ))
        taskID = reservation.taskID
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID
        )
        let lease = try #require(
            await runOnBackground {
                RecentAgentTaskFilesystemValidator.validationLease(for: project, expectedProof: nil)
            }
        )
        let validator = NativeBridgeBindingValidator(binding: binding, lease: lease)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(validating: "codex"),
            selectedExecutable: URL(fileURLWithPath: "/selected/codex")
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: reservation.taskID, runID: reservation.runID,
            bindingID: binding.id, selection: selection,
            provenance: AgentTaskLaunchProvenance(
                authenticationOrigin: .inheritNative,
                environmentProvenance: .inheritedPineProcess
            )
        ) else {
            throw AgentTaskNativeAdmissionError.invalidPolicy
        }
        let ownership = try await tasks.prepareNativeLaunch(policy: policy, binding: binding, bindings: validator)

        // In-memory child: pipes only, no process, no image.
        let input = Pipe()
        let output = Pipe()
        error = Pipe()
        peerError = Pipe()
        let channel = try CodexAppServerStdioChannel(
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading
        )
        peer = try CodexAppServerStdioChannel(
            standardInput: output.fileHandleForWriting,
            standardOutput: input.fileHandleForReading,
            standardError: peerError.fileHandleForReading
        )
        error.fileHandleForWriting.closeFile()
        peerError.fileHandleForWriting.closeFile()

        let processIdentity = UserTaskProcessIdentity(
            processID: 90_000, startSeconds: 1_700_000_000, startMicroseconds: 0
        )
        let receipt = AgentTaskOwnedProcessReceipt.nativeReceiptForTesting(
            identity: processIdentity, ownership: ownership,
            inspectIdentity: { pid in pid == processIdentity.processID ? processIdentity : nil }
        )
        let peerChannel = peer
        let materials = CodexAppServerNativeMaterials(
            registry: tasks,
            ownership: ownership,
            workingDirectory: root,
            sessionDeadline: .now.advanced(by: .seconds(30)),
            experimentalAPI: true,
            spawn: { _ in
                CodexAppServerNativeMaterials.Spawn(
                    child: CodexAppServerOwnedChild(
                        channel: channel,
                        processIdentity: processIdentity,
                        stop: { _ in peerChannel.close() }
                    ),
                    receipt: receipt
                )
            }
        )
        let factory = try CodexAppServerNativeFactory(
            materials: materials, factoryID: AdapterFactoryID(validating: "pine.codex.native-test")
        )
        sessionRecorder = CodexSessionRecorder()
        let wrappedFactory = RecordingCodexNativeFactory(underlying: factory, recorder: sessionRecorder)
        let adapterID = try AdapterID(validating: "pine:codex-native")
        let agentID = try AgentID(validating: "codex")
        let version = CodexAppServerNativeFactory.contractVersion
        let versions = PineAdapterContractVersionRange(minimum: version, maximum: version)
        let presentation = try AgentPresentationDescriptor(
            agentID: agentID, displayName: "Codex",
            executableAliases: [ExecutableAlias(validating: "codex")], style: .codex
        )
        adapters = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(
                AdapterDescriptor(
                    adapterID: adapterID, agentID: agentID, factoryID: factory.id,
                    contractVersions: versions, maximumProfiles: [factory.maximumProfile]
                ),
                wrappedFactory
            )]
        )
        let offer = try await adapters.probe(adapterID: adapterID)
        contract = try await adapters.negotiate(
            offer: offer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: versions,
                transportPreference: [.ownedStandardIO],
                acceptedAuthentication: [.ownedChildPipe]
            )
        )
        let recorder = CandidateRecorder()
        self.recorder = recorder
        let server = BridgeServerSignals()
        self.server = server
        session = try await adapters.makeSession(contract: contract, resumeFrom: nil) { event in
            recorder.observe(event)
            return await tasks.ingestNativeEvent(event, ownership: ownership)
        }
        try tasks.bindNativeSource(ownership, registry: adapters, session: session)
        serverTask = Task {
            await Self.serve(peerChannel, mode: mode, workingDirectory: root, signals: server)
        }
    }

    // MARK: Scripted peer

    private static func serve(
        _ peer: CodexAppServerStdioChannel,
        mode: CodexAppServerNativeBridgeTests.Mode,
        workingDirectory: URL,
        signals: BridgeServerSignals
    ) async {
        defer { peer.close() }
        var threadID: String?
        var turnID: String?
        var turnCount = 0
        var awaitingApprovalReplay = false
        do {
            while let message = try await peer.readNext(deadline: .now.advanced(by: .seconds(25))) {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                switch message {
                case .request(let id, "initialize", _):
                    try await peer.write(CodexAppServerMessage.response(id, result: .object([
                        "userAgent": .string("fixture codex \(CodexAppServerExecutableIdentity.supportedVersion)")
                    ])).encoded(), deadline: deadline)
                case .notification("initialized", _):
                    break
                case .request(let id, "account/read", _):
                    try await peer.write(CodexAppServerMessage.response(id, result: .object([
                        "account": .null, "requiresOpenaiAuth": .bool(true)
                    ])).encoded(), deadline: deadline)
                case .request(let id, "model/list", _):
                    // The fixture server lists no models: the session keeps the
                    // documented floor state, exactly like a malformed reply.
                    try await peer.write(CodexAppServerMessage.response(id, result: .object([
                        "data": .array([]), "nextCursor": .null
                    ])).encoded(), deadline: deadline)
                case .request(let id, "config/read", _):
                    try await peer.write(CodexAppServerMessage.response(id, result: .object([
                        "config": .object([:]), "origins": .object([:])
                    ])).encoded(), deadline: deadline)
                case .request(let id, "thread/start", _):
                    let thread = "thr_fixture"
                    threadID = thread
                    try await peer.write(CodexAppServerMessage.response(id, result: .object([
                        "thread": .object(["id": .string(thread)])
                    ])).encoded(), deadline: deadline)
                    if case .unknownRequest = mode {
                        try await peer.write(CodexAppServerMessage.request(
                            .string("future-request"), method: "future/execute", params: .object([:])
                        ).encoded(), deadline: deadline)
                    }
                    if case .childDeath = mode {
                        // The child dies after the thread bind: EOF on the
                        // pipes is the death event. Record it so the test can
                        // tell this fence apart from an unrelated start error.
                        signals.markChildDeathClosed()
                        peer.close()
                        return
                    }
                case .request(let id, "turn/start", _):
                    turnCount += 1
                    let turn = "turn_fixture_\(turnCount)"
                    turnID = turn
                    let turnObject: AgentEventJSON = .object([
                        "id": .string(turn), "status": .string("inProgress"), "items": .array([])
                    ])
                    try await peer.write(CodexAppServerMessage.response(id, result: .object([
                        "turn": turnObject
                    ])).encoded(), deadline: deadline)
                    try await peer.write(CodexAppServerMessage.notification(method: "turn/started", params: .object([
                        "threadId": .string(threadID ?? "thr_fixture"), "turn": turnObject
                    ])).encoded(), deadline: deadline)
                    switch mode {
                    case .followup:
                        if turnCount == 1 {
                            try await peer.write(CodexAppServerMessage.notification(method: "turn/completed", params: .object([
                                "threadId": .string(threadID ?? "thr_fixture"),
                                "turn": .object([
                                    "id": .string(turn), "status": .string("completed"), "items": .array([])
                                ])
                            ])).encoded(), deadline: deadline)
                        }
                    case .approval, .approvalDuplicate:
                        try await peer.write(CodexAppServerMessage.request(
                            .integer(50), method: "item/commandExecution/requestApproval", params: .object([
                                "threadId": .string(threadID ?? "thr_fixture"),
                                "turnId": .string(turn),
                                "itemId": .string("item_fixture"),
                                "command": .string("ls -la"),
                                "cwd": .string(workingDirectory.path),
                                "startedAtMs": .unsigned(1)
                            ])
                        ).encoded(), deadline: deadline)
                    case .question, .interruptQueuedInput:
                        try await peer.write(CodexAppServerMessage.request(
                            .integer(70), method: "item/tool/requestUserInput", params: .object([
                                "threadId": .string(threadID ?? "thr_fixture"),
                                "turnId": .string(turn),
                                "itemId": .string("item_fixture"),
                                "isBlocking": .bool(true),
                                "questions": .array([.object([
                                    "id": .string("q1"),
                                    "header": .string("Branch"),
                                    "question": .string("Which branch?")
                                ])])
                            ])
                        ).encoded(), deadline: deadline)
                    case .interrupt, .lateCompletion, .unknownRequest, .childDeath:
                        break
                    }
                case .request(let id, "turn/interrupt", _):
                    try await peer.write(CodexAppServerMessage.response(id, result: .object([:]))
                        .encoded(), deadline: deadline)
                    switch mode {
                    case .interrupt, .interruptQueuedInput:
                        // The pending-control refusal is only observable while
                        // the interruption is unconfirmed.
                        guard await signals.waitForCancellationRelease(within: 10) else { return }
                    default:
                        break
                    }
                    let status: String
                    switch mode {
                    case .lateCompletion: status = "completed"
                    default: status = "interrupted"
                    }
                    try await peer.write(CodexAppServerMessage.notification(method: "turn/completed", params: .object([
                        "threadId": .string(threadID ?? "thr_fixture"),
                        "turn": .object([
                            "id": .string(turnID ?? "turn_fixture_1"),
                            "status": .string(status),
                            "items": .array([])
                        ])
                    ])).encoded(), deadline: deadline)
                case .response(.integer(50), let result):
                    signals.recordAnswerDelivery()
                    if case .object(let fields) = result, case .string(let decision)? = fields["decision"] {
                        signals.setDecision(decision)
                    }
                    if case .approvalDuplicate = mode {
                        if !awaitingApprovalReplay {
                            // First answer: redeliver the same request before
                            // resolving it. The client must replay the written
                            // answer, not prompt the user again.
                            awaitingApprovalReplay = true
                            try await peer.write(CodexAppServerMessage.request(
                                .integer(50), method: "item/commandExecution/requestApproval", params: .object([
                                    "threadId": .string(threadID ?? "thr_fixture"),
                                    "turnId": .string(turnID ?? "turn_fixture_1"),
                                    "itemId": .string("item_fixture"),
                                    "command": .string("ls -la"),
                                    "cwd": .string(workingDirectory.path),
                                    "startedAtMs": .unsigned(1)
                                ])
                            ).encoded(), deadline: deadline)
                        } else {
                            // The replayed written answer arrived: resolve once.
                            awaitingApprovalReplay = false
                            try await peer.write(CodexAppServerMessage.notification(method: "serverRequest/resolved", params: .object([
                                "threadId": .string(threadID ?? "thr_fixture"),
                                "requestId": .number("50")
                            ])).encoded(), deadline: deadline)
                            try await peer.write(CodexAppServerMessage.notification(method: "turn/completed", params: .object([
                                "threadId": .string(threadID ?? "thr_fixture"),
                                "turn": .object([
                                    "id": .string(turnID ?? "turn_fixture_1"),
                                    "status": .string("completed"),
                                    "items": .array([])
                                ])
                            ])).encoded(), deadline: deadline)
                        }
                    } else {
                        try await peer.write(CodexAppServerMessage.notification(method: "serverRequest/resolved", params: .object([
                            "threadId": .string(threadID ?? "thr_fixture"),
                            "requestId": .number("50")
                        ])).encoded(), deadline: deadline)
                        try await peer.write(CodexAppServerMessage.notification(method: "turn/completed", params: .object([
                            "threadId": .string(threadID ?? "thr_fixture"),
                            "turn": .object([
                                "id": .string(turnID ?? "turn_fixture_1"),
                                "status": .string("completed"),
                                "items": .array([])
                            ])
                        ])).encoded(), deadline: deadline)
                    }
                case .response(.integer(70), let result):
                    if case .object(let fields) = result, let answers = fields["answers"] {
                        signals.setQuestionAnswer(answers)
                    }
                    try await peer.write(CodexAppServerMessage.notification(method: "serverRequest/resolved", params: .object([
                        "threadId": .string(threadID ?? "thr_fixture"),
                        "requestId": .number("70")
                    ])).encoded(), deadline: deadline)
                    try await peer.write(CodexAppServerMessage.notification(method: "turn/completed", params: .object([
                        "threadId": .string(threadID ?? "thr_fixture"),
                        "turn": .object([
                            "id": .string(turnID ?? "turn_fixture_1"),
                            "status": .string("completed"),
                            "items": .array([])
                        ])
                    ])).encoded(), deadline: deadline)
                case .failure(.string("future-request"), let code):
                    signals.setUnknownRejection(code)
                case .request, .notification:
                    break
                case .response, .failure:
                    break
                }
            }
        } catch {
            // Explicit session teardown closes the peer.
        }
    }
}
