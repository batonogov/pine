import Foundation
import Synchronization
import Testing
@testable import Pine

@Suite("Registry-owned adapter controls")
struct AgentAdapterControlTests {
    @Test func controlDiagnosticsDoNotExposeInstructionOrAnswers() throws {
        let commands: [AgentAdapterControl] = [
            .submitInstruction("secret-instruction"),
            .answerQuestion(
                request: try VendorReference(role: .request, value: "secret-request"),
                context: try VendorReference(role: .turn, value: "secret-turn"),
                answers: ["secret-question": ["secret-answer"]]
            ),
        ]
        for command in commands {
            var diagnostic = ""
            dump(command, to: &diagnostic)
            #expect(!diagnostic.contains("secret"))
            #expect(!String(reflecting: command).contains("secret"))
            #expect(!String(describing: command).contains("secret"))
        }
    }

    @Test func sourceAccessorMatchesValidatedIngressAndRejectsForeignRegistry() async throws {
        let fixture = try await fixture()
        let source = try fixture.registry.sourceIdentity(for: fixture.session)
        try await fixture.session.start()
        let candidate = AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .turn, phase: .started, reference: VendorReference(role: .turn, value: "turn")
        )))
        #expect(await fixture.recorder.emit(candidate) == .accepted)
        #expect(fixture.observedSource.value == source)
        let foreign = try AgentAdapterRegistry(compiledPresentations: [], compiledAdapters: [])
        #expect(throws: AdapterSessionError.contractMismatch) {
            _ = try foreign.sourceIdentity(for: fixture.session)
        }
        #expect(throws: AdapterSessionError.contractMismatch) {
            _ = try foreign.controls(for: fixture.session)
        }
        let impersonator = LegacySession(contract: fixture.session.contract)
        #expect(throws: AdapterSessionError.contractMismatch) {
            _ = try fixture.registry.sourceIdentity(for: impersonator)
        }
        #expect(throws: AdapterSessionError.contractMismatch) {
            _ = try fixture.registry.controls(for: impersonator)
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func controlsRequireActivationAndRemainFencedAfterStop() async throws {
        let fixture = try await fixture()
        let controls = try fixture.registry.controls(for: fixture.session)
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            _ = try await controls.dispatch(.submitInstruction("instruction"), beforeDispatch: {})
        }
        #expect(await fixture.recorder.dispatches == 0)
        try await fixture.session.start()
        #expect(try await controls.dispatch(.submitInstruction("instruction"), beforeDispatch: {}) == .acknowledged)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            _ = try await controls.dispatch(.submitInstruction("instruction"), beforeDispatch: {})
        }
        #expect(await fixture.recorder.dispatches == 1)
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            try await fixture.recorder.validateDeferredWrite()
        }
    }

    @Test func physicalOwnerRevocationFencesRetainedGuard() async throws {
        let fixture = try await fixture()
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        _ = try await controls.dispatch(.submitInstruction("instruction"), beforeDispatch: {})
        await fixture.recorder.revoke()
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            try await fixture.recorder.validateDeferredWrite()
        }
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            _ = try await controls.dispatch(.submitInstruction("instruction"), beforeDispatch: {})
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func deferredWriteRevalidatesTaskGate() async throws {
        let fixture = try await fixture()
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        let gate = ControlTaskGate()
        _ = try await controls.dispatch(.submitInstruction("instruction"), beforeDispatch: { try gate.validate() })
        gate.revoke()
        await #expect(throws: GateError.rejected) {
            try await fixture.recorder.validateDeferredWrite()
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func taskGateRejectionAndRevocationInsideGatePreventDispatch() async throws {
        let fixture = try await fixture()
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        await #expect(throws: GateError.rejected) {
            _ = try await controls.dispatch(.submitInstruction("instruction"), beforeDispatch: { throw GateError.rejected })
        }
        let authority = try #require(await fixture.recorder.authority)
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            _ = try await controls.dispatch(.submitInstruction("instruction"), beforeDispatch: { authority.revoke() })
        }
        #expect(await fixture.recorder.dispatches == 0)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func forwardsSemanticControlsWithoutConvertingUncertaintyToSuccess() async throws {
        let fixture = try await fixture()
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        let commands: [AgentAdapterControl] = [
            .submitInstruction("instruction"),
            .answerQuestion(
                request: try VendorReference(role: .request, value: "question-request"),
                context: try VendorReference(role: .turn, value: "question-turn"), answers: ["question": ["answer"]]
            ),
            .answerPermission(
                request: try VendorReference(role: .request, value: "deny-request"),
                context: try VendorReference(role: .turn, value: "deny-turn"), decision: .deny
            ),
            .answerPermission(
                request: try VendorReference(role: .request, value: "allow-request"),
                context: try VendorReference(role: .turn, value: "allow-turn"), decision: .allowOnce
            ),
            .requestCancellation(context: try VendorReference(role: .turn, value: "cancel-turn")),
        ]
        await fixture.recorder.setUncertain()
        for command in commands {
            #expect(try await controls.dispatch(command, beforeDispatch: {}) == .uncertain)
        }
        let received = await fixture.recorder.controls
        try #require(received.count == commands.count)
        for (expected, actual) in zip(commands, received) {
            switch (expected, actual) {
            case let (.submitInstruction(expectedText), .submitInstruction(actualText)):
                #expect(actualText == expectedText)
            case let (.answerQuestion(expectedRequest, expectedContext, expectedAnswers),
                      .answerQuestion(actualRequest, actualContext, actualAnswers)):
                #expect(actualRequest == expectedRequest)
                #expect(actualContext == expectedContext)
                #expect(actualAnswers == expectedAnswers)
            case let (.answerPermission(expectedRequest, expectedContext, .deny),
                      .answerPermission(actualRequest, actualContext, .deny)),
                 let (.answerPermission(expectedRequest, expectedContext, .allowOnce),
                      .answerPermission(actualRequest, actualContext, .allowOnce)):
                #expect(actualRequest == expectedRequest)
                #expect(actualContext == expectedContext)
            case let (.requestCancellation(expectedContext), .requestCancellation(actualContext)):
                #expect(actualContext == expectedContext)
            default:
                Issue.record("Control kind or permission decision changed")
            }
        }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    @Test func legacyStartStopSessionDoesNotAcquireControls() async throws {
        let fixture = try await fixture(controlled: false)
        try await fixture.session.start()
        let controls = try fixture.registry.controls(for: fixture.session)
        await #expect(throws: AgentAdapterControlError.unsupported) {
            _ = try await controls.dispatch(.submitInstruction("instruction"), beforeDispatch: {})
        }
        #expect(await fixture.recorder.dispatches == 0)
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

    fileprivate enum GateError: Error, Equatable { case rejected }

    private func fixture(controlled: Bool = true) async throws -> ControlFixture {
        let agentID = try AgentID(validating: "codex")
        let factoryID = try AdapterFactoryID(validating: "test.control.factory")
        let profile = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: [.init(scope: .turn, phase: .started)], evidence: []),
            delivery: AdapterDeliverySemantics(ordering: .unordered, minimumAuthentication: .ownedChildPipe)
        )
        let versions = PineAdapterContractVersionRange(
            minimum: .init(major: 1, minor: 0), maximum: .init(major: 1, minor: 0)
        )
        let descriptor = AdapterDescriptor(
            adapterID: try AdapterID(validating: "test:control"), agentID: agentID, factoryID: factoryID,
            contractVersions: versions, maximumProfiles: [profile]
        )
        let recorder = ControlRecorder()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [AgentPresentationDescriptor(
                agentID: agentID, displayName: "Codex", executableAliases: [ExecutableAlias(validating: "codex")], style: .codex
            )],
            compiledAdapters: [(descriptor, ControlFactory(
                id: factoryID,
                result: try AdapterProbeResult(
                    detectedVendorVersion: DetectedVendorVersion("fixture"), detectedSchema: nil,
                    offeredProfiles: [profile], offeredContractVersions: versions
                ), recorder: recorder, controlled: controlled
            ))]
        )
        let offer = try await registry.probe(adapterID: descriptor.adapterID)
        let contract = try await registry.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
            allowedVersions: versions, transportPreference: [.ownedStandardIO], acceptedAuthentication: [.ownedChildPipe]
        ))
        let observedSource = ControlSourceRecorder()
        let session = try await registry.makeSession(contract: contract, resumeFrom: nil) { event in
            observedSource.record(event.sourceIdentity)
            return .accepted
        }
        return ControlFixture(registry: registry, session: session, recorder: recorder, observedSource: observedSource)
    }
}

nonisolated private struct ControlFixture: Sendable {
    let registry: AgentAdapterRegistry
    let session: any AgentAdapterSession
    let recorder: ControlRecorder
    let observedSource: ControlSourceRecorder
}

nonisolated private final class ControlSourceRecorder: Sendable {
    private let source = Mutex<ValidatedAgentSourceIdentity?>(nil)
    var value: ValidatedAgentSourceIdentity? { source.withLock { $0 } }
    func record(_ value: ValidatedAgentSourceIdentity) { source.withLock { $0 = value } }
}

nonisolated private final class ControlTaskGate: Sendable {
    private let active = Mutex(true)
    func revoke() { active.withLock { $0 = false } }
    func validate() throws {
        try active.withLock { guard $0 else { throw AgentAdapterControlTests.GateError.rejected } }
    }
}

private actor ControlRecorder {
    private(set) var authority: AgentAdapterControlAuthority?
    private var sink: (any AgentEventSink)?
    private var deferredWrite: (@Sendable () throws -> Void)?
    private var uncertain = false
    private(set) var controls: [AgentAdapterControl] = []
    var dispatches: Int { controls.count }
    func configure(_ request: AgentAdapterSessionRequest) {
        authority = request.controlAuthority
        sink = request.sink
    }
    func emit(_ candidate: AdapterCandidate) async -> AdapterIngestOutcome {
        await sink?.ingest(candidate) ?? .revoked
    }
    func revoke() { authority?.revoke() }
    func setUncertain() { uncertain = true }
    func validateDeferredWrite() throws { try deferredWrite?() }
    func dispatch(_ control: AgentAdapterControl, validate: @escaping @Sendable () throws -> Void) throws -> AgentAdapterControlDispatch {
        deferredWrite = validate
        try validate()
        controls.append(control)
        return uncertain ? .uncertain : .acknowledged
    }
}

nonisolated private struct ControlFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let result: AdapterProbeResult
    let recorder: ControlRecorder
    let controlled: Bool
    func probe() async throws -> AdapterProbeResult { result }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        await recorder.configure(request)
        if controlled { return ControlledSession(contract: request.contract, recorder: recorder) }
        return LegacySession(contract: request.contract)
    }
}

nonisolated private struct LegacySession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    func start() async throws {}
    func stop(deadline: ContinuousClock.Instant) async {}
}

nonisolated private struct ControlledSession: AgentAdapterControlledSession {
    let contract: NegotiatedAdapterContract
    let recorder: ControlRecorder
    func start() async throws {}
    func stop(deadline: ContinuousClock.Instant) async {}
    func dispatch(
        _ control: AgentAdapterControl, beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterControlDispatch {
        try await recorder.dispatch(control, validate: beforeDispatch)
    }
}
