import Foundation
import Testing
@testable import Pine

struct AgentAdapterAttentionStateTests {
    private func attention(_ id: String, turn: String = "turn-a") throws -> AdapterCandidate {
        AdapterCandidate(event: .question(try CandidateAttentionEvent(
            scope: .turn, phase: .waitingForQuestion,
            request: VendorReference(role: .request, value: id), context: VendorReference(role: .turn, value: turn)
        )))
    }

    private func resolution(_ id: String, turn: String = "turn-a") throws -> AdapterCandidate {
        AdapterCandidate(event: .requestResolved(try CandidateRequestResolutionEvent(
            scope: .turn, request: VendorReference(role: .request, value: id),
            context: VendorReference(role: .turn, value: turn)
        )))
    }

    @Test func resolvingOneOfManyNeverImpliesIdleAndRejectsWrongContext() async throws {
        let fixture = try await AttentionFixture.create()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        let first = try await fixture.send(attention("first"))
        var state = try #require(AgentAdapterAttentionState(owner: fixture.session, firstEvent: first))
        #expect(state.apply(first) == .opened)
        #expect(state.apply(try await fixture.send(attention("second"))) == .opened)
        #expect(state.apply(try await fixture.send(resolution("first", turn: "wrong-turn"))) == .mismatchedContext)
        #expect(state.pendingCount == 2)
        #expect(state.apply(try await fixture.send(resolution("first"))) == .resolved(remaining: 1))
        #expect(state.apply(try await fixture.send(resolution("first"))) == .duplicate)
        #expect(state.pendingCount == 1)
        #expect(state.isActionable(scope: .turn, request: try VendorReference(role: .request, value: "second"),
                                  context: try VendorReference(role: .turn, value: "turn-a")))
    }

    @Test func outOfOrderResolutionCannotReopenLateQuestion() async throws {
        let fixture = try await AttentionFixture.create()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        let resolved = try await fixture.send(resolution("first"))
        var state = try #require(AgentAdapterAttentionState(owner: fixture.session, firstEvent: resolved))
        #expect(state.apply(resolved) == .historicalResolution)
        #expect(state.apply(try await fixture.send(attention("first"))) == .duplicate)
        #expect(state.pendingCount == 0)
    }

    @Test func sourceAttemptsCannotResolveEachOthersRequests() async throws {
        let first = try await AttentionFixture.create()
        let other = try await AttentionFixture.create()
        defer {
            Task {
                await first.session.stop(deadline: .now.advanced(by: .seconds(1)))
                await other.session.stop(deadline: .now.advanced(by: .seconds(1)))
            }
        }
        let event = try await first.send(attention("same-id"))
        var state = try #require(AgentAdapterAttentionState(owner: first.session, firstEvent: event))
        #expect(AgentAdapterAttentionState(owner: other.session, firstEvent: event) == nil)
        #expect(state.apply(event) == .opened)
        #expect(state.apply(try await other.send(resolution("same-id"))) == .foreignSource)
        #expect(state.pendingCount == 1)
    }

    @Test func cancellationFencesLateQuestionsAndAnswersForExactTurn() async throws {
        let fixture = try await AttentionFixture.create()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        let event = try await fixture.send(attention("first"))
        var state = try #require(AgentAdapterAttentionState(owner: fixture.session, firstEvent: event))
        #expect(state.apply(event) == .opened)
        #expect(state.cancel(scope: .turn, context: try VendorReference(role: .turn, value: "turn-a")) == .expired(count: 1))
        #expect(state.apply(try await fixture.send(attention("late"))) == .duplicate)
        #expect(state.pendingCount == 0)
        #expect(!state.isActionable(scope: .turn, request: try VendorReference(role: .request, value: "first"),
                                   context: try VendorReference(role: .turn, value: "turn-a")))
    }

    @Test func legacyContractCannotEmitResolution() async throws {
        let fixture = try await AttentionFixture.create(minor: 0)
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        #expect(await fixture.capture.ingest(try resolution("first")) == .droppedInvalid)
    }

    @Test func boundedRequestHistoryFailsClosedWithoutReopeningControls() async throws {
        let fixture = try await AttentionFixture.create()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        let first = try await fixture.send(attention("request-0"))
        var state = try #require(AgentAdapterAttentionState(owner: fixture.session, firstEvent: first))
        #expect(state.apply(first) == .opened)
        for index in 1..<AgentAdapterAttentionState.maximumRetainedRequests {
            let candidate = try attention("request-\(index)")
            let event = try await fixture.send(candidate)
            #expect(state.apply(event) == .opened)
        }
        let overflow = try await fixture.send(attention("overflow"))
        #expect(state.apply(overflow) == .needsReconciliation)
        #expect(state.pendingCount == 0)
        #expect(!state.isActionable(scope: .turn, request: try VendorReference(role: .request, value: "request-0"),
                                   context: try VendorReference(role: .turn, value: "turn-a")))
    }

    @Test func resolutionRequiresExactReferenceRolesAndNegotiatedScope() async throws {
        #expect(throws: AdapterCandidateError.contradictoryEvent) {
            try CandidateRequestResolutionEvent(scope: .turn,
                request: VendorReference(role: .turn, value: "not-request"),
                context: VendorReference(role: .turn, value: "turn-a"))
        }
        let fixture = try await AttentionFixture.create()
        defer { Task { await fixture.session.stop(deadline: .now.advanced(by: .seconds(1))) } }
        let wrongScope = AdapterCandidate(event: .requestResolved(try CandidateRequestResolutionEvent(
            scope: .session, request: VendorReference(role: .request, value: "first"),
            context: VendorReference(role: .conversation, value: "session")
        )))
        #expect(await fixture.capture.ingest(wrongScope) == .droppedInvalid)
    }

    @Test func controlActivationIsRegistryOwnedAndStopRevokesIt() async throws {
        let fixture = try await AttentionFixture.create(start: false)
        let authority = try #require(await fixture.capture.controlAuthority)
        #expect(throws: AdapterSessionError.invalidLifecycle) { try authority.validate() }
        try await fixture.session.start()
        try authority.validate()
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        #expect(throws: AdapterSessionError.invalidLifecycle) { try authority.validate() }
        await #expect(throws: AdapterSessionError.invalidLifecycle) { try await fixture.session.start() }
        #expect(throws: AdapterSessionError.invalidLifecycle) { try authority.validate() }
    }

    @Test func failedStartupNeverGrantsProgrammaticControl() async throws {
        let fixture = try await AttentionFixture.create(start: false, failStart: true)
        let authority = try #require(await fixture.capture.controlAuthority)
        await #expect(throws: AdapterSessionError.launchFailed(.permanent)) { try await fixture.session.start() }
        #expect(throws: AdapterSessionError.invalidLifecycle) { try authority.validate() }
        await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
    }

}

nonisolated private struct AttentionFixture: Sendable {
    let session: any AgentAdapterSession
    let capture: AttentionCapture

    static func create(minor: UInt16 = 1, start: Bool = true, failStart: Bool = false) async throws -> Self {
        let agent = try AgentID(validating: "user:request-test")
        let factoryID = try AdapterFactoryID(validating: "request-test")
        let version = PineAdapterContractVersion(major: 1, minor: minor)
        let versions = PineAdapterContractVersionRange(minimum: version, maximum: version)
        let profile = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: [
                .init(scope: .turn, phase: .waitingForQuestion), .init(scope: .turn, phase: .settled)
            ], evidence: []),
            delivery: AdapterDeliverySemantics(ordering: .unordered, minimumAuthentication: .ownedChildPipe)
        )
        let capture = AttentionCapture()
        let factory = AttentionFactory(id: factoryID, profile: profile, versions: versions, capture: capture, failStart: failStart)
        let descriptor = AdapterDescriptor(adapterID: try AdapterID(validating: "request-test"), agentID: agent,
                                           factoryID: factoryID, contractVersions: versions, maximumProfiles: [profile])
        let registry = try AgentAdapterRegistry(compiledPresentations: [
            AgentPresentationDescriptor(agentID: agent, displayName: "Request Test", executableAliases: [], style: .generic)
        ], compiledAdapters: [(descriptor, factory)])
        let offer = try await registry.probe(adapterID: descriptor.adapterID)
        let contract = try await registry.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
            allowedVersions: versions, transportPreference: [.ownedStandardIO], acceptedAuthentication: [.ownedChildPipe]
        ))
        let session = try await registry.makeSession(contract: contract, resumeFrom: nil) { event in
            await capture.record(event)
            return .accepted
        }
        if start { try await session.start() }
        return Self(session: session, capture: capture)
    }

    func send(_ candidate: AdapterCandidate) async throws -> ValidatedAgentEvent {
        #expect(await capture.ingest(candidate) == .accepted)
        return try #require(await capture.latest)
    }
}

nonisolated private struct AttentionFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let profile: AdapterCapabilityProfile
    let versions: PineAdapterContractVersionRange
    let capture: AttentionCapture
    let failStart: Bool
    func probe() async throws -> AdapterProbeResult {
        try AdapterProbeResult(detectedVendorVersion: DetectedVendorVersion("fixture"), detectedSchema: nil,
                               offeredProfiles: [profile], offeredContractVersions: versions)
    }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        await capture.attach(request.sink, controlAuthority: request.controlAuthority)
        return AttentionSession(contract: request.contract, failStart: failStart)
    }
}

nonisolated private struct AttentionSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    let failStart: Bool
    func start() async throws {
        if failStart { throw AdapterSessionError.launchFailed(.permanent) }
    }
    func stop(deadline: ContinuousClock.Instant) async {}
}

private actor AttentionCapture {
    private var sink: (any AgentEventSink)?
    private(set) var latest: ValidatedAgentEvent?
    private(set) var controlAuthority: AgentAdapterControlAuthority?
    func attach(_ sink: any AgentEventSink, controlAuthority: AgentAdapterControlAuthority) {
        self.sink = sink
        self.controlAuthority = controlAuthority
    }
    func record(_ event: ValidatedAgentEvent) { latest = event }
    func ingest(_ candidate: AdapterCandidate) async -> AdapterIngestOutcome {
        guard let sink else { return .revoked }
        return await sink.ingest(candidate)
    }
}
