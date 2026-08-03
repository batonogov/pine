import Testing
@testable import Pine

nonisolated private struct RegistryTestFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let failure: AdapterFailureDisposition
    let probeResult: AdapterProbeResult?
    init(
        id: AdapterFactoryID,
        failure: AdapterFailureDisposition = .permanent,
        probeResult: AdapterProbeResult? = nil
    ) {
        self.id = id
        self.failure = failure
        self.probeResult = probeResult
    }
    func probe() async throws -> AdapterProbeResult {
        guard let probeResult else { throw AdapterProbeError.unavailable(.permanent) }
        return probeResult
    }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        throw AdapterSessionError.launchFailed(failure)
    }
}

nonisolated private struct AuthorityTestFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let probeResult: AdapterProbeResult?
    let probeFailure: AdapterProbeError?
    let sessionFailure: AdapterSessionError?
    let recorder: AuthorityFactoryRecorder

    func probe() async throws -> AdapterProbeResult {
        await recorder.recordProbe()
        if let probeFailure { throw probeFailure }
        return try #require(probeResult)
    }

    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        await recorder.recordSession(contract: request.contract)
        if let sessionFailure { throw sessionFailure }
        return RegistryTestSession(contract: request.contract)
    }
}

private actor AuthorityFactoryRecorder {
    private(set) var probeCalls = 0
    private(set) var sessionCalls = 0
    private(set) var sessionContract: NegotiatedAdapterContract?

    func recordProbe() { probeCalls += 1 }
    func recordSession(contract: NegotiatedAdapterContract) {
        sessionCalls += 1
        sessionContract = contract
    }
}

private actor ProbeResultSequence {
    private var results: [AdapterProbeResult]
    private var index = 0

    init(_ results: [AdapterProbeResult]) { self.results = results }

    func next() throws -> AdapterProbeResult {
        guard results.indices.contains(index) else { throw AdapterProbeError.malformedResponse }
        defer { index += 1 }
        return results[index]
    }
}

nonisolated private struct SequencedRecordingFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let probes: ProbeResultSequence
    let sessionRecorder: FactoryRecorder?

    func probe() async throws -> AdapterProbeResult { try await probes.next() }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        await sessionRecorder?.record(request: request)
        return RegistryTestSession(contract: request.contract)
    }
}

nonisolated private struct RegistryTestSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    var startFailure: AdapterSessionError?
    var startSink: (any AgentEventSink)?
    var startRecorder: FactoryRecorder?
    var emitDuringStart = false
    var startEmissionCount = 1
    var cancelDuringStart = false
    var cancelBeforeReturning = false
    var startHold: StartHold?
    init(
        contract: NegotiatedAdapterContract,
        startFailure: AdapterSessionError? = nil,
        startSink: (any AgentEventSink)? = nil,
        startRecorder: FactoryRecorder? = nil,
        emitDuringStart: Bool = false,
        startEmissionCount: Int = 1,
        cancelDuringStart: Bool = false,
        cancelBeforeReturning: Bool = false,
        startHold: StartHold? = nil
    ) {
        self.contract = contract
        self.startFailure = startFailure
        self.startSink = startSink
        self.startRecorder = startRecorder
        self.emitDuringStart = emitDuringStart
        self.startEmissionCount = startEmissionCount
        self.cancelDuringStart = cancelDuringStart
        self.cancelBeforeReturning = cancelBeforeReturning
        self.startHold = startHold
    }
    func start() async throws {
        if emitDuringStart, startEmissionCount > 0, let startSink {
            for sequence in 1...startEmissionCount {
                let outcome = await startSink.ingest(AdapterCandidate(
                    event: .processExited(status: nil),
                    sourcePosition: try AdapterSourcePosition(
                        sourceSequence: UInt64(sequence)
                    )
                ))
                await startRecorder?.recordStartOutcome(outcome)
            }
        }
        await startHold?.wait()
        if cancelDuringStart { throw CancellationError() }
        if cancelBeforeReturning {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if let startFailure { throw startFailure }
    }
    func stop(deadline: ContinuousClock.Instant) async {}
}

@Suite("Agent adapter compiled registry", .timeLimit(.minutes(1)))
struct AgentAdapterRegistryTests {
    @Test func unavailableProbeCannotBeBypassedByEquivalentCallerResult() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let equivalentRawResult = try probeResult(
            profile: setup.profile,
            versions: descriptor.contractVersions
        )
        let recorder = AuthorityFactoryRecorder()
        let factory = AuthorityTestFactory(
            id: descriptor.factoryID,
            probeResult: nil,
            probeFailure: .unavailable(.permanent),
            sessionFailure: nil,
            recorder: recorder
        )
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, factory)]
        )

        await #expect(throws: AdapterProbeError.unavailable(.permanent)) {
            _ = try await registry.probe(adapterID: descriptor.adapterID)
        }
        #expect(equivalentRawResult.offeredProfiles == [setup.profile])
        #expect(await recorder.probeCalls == 1)
        #expect(await recorder.sessionCalls == 0)
    }

    @Test func offerBindsExactRegisteredFactoryThroughSessionCreation() async throws {
        let setup = try fixtures(twoAdapters: true)
        let firstDescriptor = setup.adapters[0].0
        let secondDescriptor = setup.adapters[1].0
        let firstRecorder = AuthorityFactoryRecorder()
        let secondRecorder = AuthorityFactoryRecorder()
        let firstFactory = AuthorityTestFactory(
            id: firstDescriptor.factoryID,
            probeResult: try probeResult(profile: setup.profile, versions: range(1, 1, 1, 3)),
            probeFailure: nil,
            sessionFailure: nil,
            recorder: firstRecorder
        )
        let secondFactory = AuthorityTestFactory(
            id: secondDescriptor.factoryID,
            probeResult: try probeResult(profile: setup.profile, versions: range(1, 0, 1, 4)),
            probeFailure: nil,
            sessionFailure: .launchFailed(.permanent),
            recorder: secondRecorder
        )
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(firstDescriptor, firstFactory), (secondDescriptor, secondFactory)]
        )

        let offer = try await registry.probe(adapterID: firstDescriptor.adapterID)
        let contract = try await registry.negotiate(offer: offer, policy: policy())
        _ = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }

        #expect(contract.adapterID == firstDescriptor.adapterID)
        #expect(contract.factoryID == firstDescriptor.factoryID)
        #expect(await firstRecorder.probeCalls == 1)
        #expect(await firstRecorder.sessionCalls == 1)
        #expect(await firstRecorder.sessionContract == contract)
        #expect(await secondRecorder.probeCalls == 0)
        #expect(await secondRecorder.sessionCalls == 0)
    }

    @Test func foreignRegistryOfferIsRejectedBeforeFactoryInvocation() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let firstRecorder = AuthorityFactoryRecorder()
        let secondRecorder = AuthorityFactoryRecorder()
        let result = try probeResult(profile: setup.profile, versions: descriptor.contractVersions)
        let firstRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, AuthorityTestFactory(
                id: descriptor.factoryID,
                probeResult: result,
                probeFailure: nil,
                sessionFailure: nil,
                recorder: firstRecorder
            ))]
        )
        let secondRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, AuthorityTestFactory(
                id: descriptor.factoryID,
                probeResult: result,
                probeFailure: nil,
                sessionFailure: nil,
                recorder: secondRecorder
            ))]
        )

        let foreignOffer = try await firstRegistry.probe(adapterID: descriptor.adapterID)
        await #expect(throws: AdapterNegotiationError.offerMismatch) {
            _ = try await secondRegistry.negotiate(offer: foreignOffer, policy: policy())
        }
        #expect(await firstRecorder.probeCalls == 1)
        #expect(await firstRecorder.sessionCalls == 0)
        #expect(await secondRecorder.probeCalls == 0)
        #expect(await secondRecorder.sessionCalls == 0)
    }

    @Test func registryOfferCanBeNegotiatedOnlyOnce() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: FactoryRecorder(),
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                )
            ))]
        )
        let offer = try await registry.probe(adapterID: descriptor.adapterID)

        _ = try await registry.negotiate(offer: offer, policy: policy())
        await #expect(throws: AdapterNegotiationError.offerMismatch) {
            _ = try await registry.negotiate(offer: offer, policy: policy())
        }
    }

    @Test func negotiatedContractAuthorizesOnlyOneFreshSession() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: FactoryRecorder(),
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                )
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let first = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }

        await #expect(throws: AdapterSessionError.contractAlreadyConsumed) {
            _ = try await registry.makeSession(
                contract: contract,
                resumeFrom: nil
            ) { _ in .accepted }
        }
        _ = first
    }

    @Test func abandonedFreshSessionRollsAuthorityBackSynchronously() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: FactoryRecorder(),
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                )
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        var abandoned: (any AgentAdapterSession)? = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }
        #expect(abandoned != nil)
        abandoned = nil

        let replacement = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }
        _ = replacement
    }

    @Test func abandonmentBeforeOrAfterStartRunsExactlyOneCleanup() async throws {
        for startsBeforeAbandonment in [false, true] {
            let setup = try fixtures()
            let descriptor = setup.adapters[0].0
            let recorder = FactoryRecorder()
            let stopHold = StopHold()
            let capacity = AdapterCleanupCapacity(limit: 1)
            let registry = try AgentAdapterRegistry(
                compiledPresentations: [setup.presentation],
                compiledAdapters: [(descriptor, StopTestFactory(
                    id: descriptor.factoryID,
                    probeResult: try probeResult(
                        profile: setup.profile,
                        versions: descriptor.contractVersions
                    ),
                    stopHold: stopHold,
                    recorder: recorder
                ))],
                cleanupCapacity: capacity
            )
            let abandonedContract = try await negotiate(
                registry,
                adapterID: descriptor.adapterID,
                profile: setup.profile
            )
            let replacementContract = try await negotiate(
                registry,
                adapterID: descriptor.adapterID,
                profile: setup.profile
            )
            var abandoned: (any AgentAdapterSession)? = try await registry.makeSession(
                contract: abandonedContract,
                resumeFrom: nil
            ) { _ in .accepted }
            if startsBeforeAbandonment, let session = abandoned {
                try await session.start()
            }
            #expect(capacity.reservedCount == 1)
            abandoned = nil

            await stopHold.waitUntilArrived()
            #expect(await stopHold.callCount == 1)
            #expect(capacity.reservedCount == 1)
            await #expect(throws: AdapterSessionError.cleanupCapacityUnavailable) {
                _ = try await registry.makeSession(
                    contract: replacementContract,
                    resumeFrom: nil
                ) { _ in .accepted }
            }

            await stopHold.release()
            await stopHold.waitUntilFinished()
            for _ in 0..<10_000 where capacity.reservedCount != 0 {
                await Task.yield()
            }
            #expect(capacity.reservedCount == 0)

            let replacement = try await registry.makeSession(
                contract: replacementContract,
                resumeFrom: nil
            ) { _ in .accepted }
            await replacement.stop(
                deadline: ContinuousClock.now.advanced(by: .seconds(1))
            )
            #expect(await stopHold.callCount == 2)
            #expect(capacity.reservedCount == 0)
        }
    }

    @Test func continuationGateResolvesEveryRegistrationCancellationOrdering() async {
        let resolvedBeforeRegistration = AsyncContinuationGate()
        resolvedBeforeRegistration.resolve()
        resolvedBeforeRegistration.resolve()
        await resolvedBeforeRegistration.wait()
        #expect(resolvedBeforeRegistration.isResolved)

        let cancelledBeforeRegistration = AsyncContinuationGate()
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await cancelledBeforeRegistration.wait()
        }
        await cancelledTask.value
        #expect(cancelledBeforeRegistration.isResolved)

        let registeredBeforeResolution = AsyncContinuationGate()
        let registeredTask = Task { await registeredBeforeResolution.wait() }
        for _ in 0..<1_000 where !registeredBeforeResolution.hasRegisteredWaiter {
            await Task.yield()
        }
        #expect(registeredBeforeResolution.hasRegisteredWaiter)
        registeredBeforeResolution.resolve()
        registeredBeforeResolution.resolve()
        await registeredTask.value
        #expect(registeredBeforeResolution.isResolved)

        let cancelledAfterRegistration = AsyncContinuationGate()
        let cancellationTask = Task { await cancelledAfterRegistration.wait() }
        for _ in 0..<1_000 where !cancelledAfterRegistration.hasRegisteredWaiter {
            await Task.yield()
        }
        #expect(cancelledAfterRegistration.hasRegisteredWaiter)
        cancellationTask.cancel()
        await cancellationTask.value
        cancelledAfterRegistration.resolve()
        cancelledAfterRegistration.resolve()
        #expect(cancelledAfterRegistration.isResolved)

        for _ in 0..<128 {
            let raced = AsyncContinuationGate()
            let task = Task { await raced.wait() }
            task.cancel()
            raced.resolve()
            raced.resolve()
            await task.value
            #expect(raced.isResolved)
        }
    }

    @Test func strictSubsetProbeOfferNegotiatesAndActivates() async throws {
        let setup = try fixtures()
        let base = setup.adapters[0].0
        let maximum = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(
                signals: lifecycleSignals().union([.init(scope: .turn, phase: .working)]),
                evidence: [.tool]
            ),
            delivery: AdapterDeliverySemantics(ordering: .ordered, minimumAuthentication: .ownedChildPipe)
        )
        let descriptor = AdapterDescriptor(
            adapterID: base.adapterID,
            agentID: base.agentID,
            factoryID: base.factoryID,
            contractVersions: range(1, 0, 1, 9),
            maximumProfiles: [maximum]
        )
        let recorder = AuthorityFactoryRecorder()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, AuthorityTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(profile: setup.profile, versions: range(1, 2, 1, 4)),
                probeFailure: nil,
                sessionFailure: nil,
                recorder: recorder
            ))]
        )

        let offer = try await registry.probe(adapterID: descriptor.adapterID)
        let contract = try await registry.negotiate(
            offer: offer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: range(1, 1, 1, 8),
                transportPreference: [.ownedStandardIO],
                acceptedAuthentication: [.ownedChildPipe]
            )
        )
        _ = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }

        #expect(contract.version == PineAdapterContractVersion(major: 1, minor: 4))
        #expect(contract.profile == setup.profile)
        #expect(await recorder.probeCalls == 1)
        #expect(await recorder.sessionCalls == 1)
    }

    @Test func unsupportedProbeVersionAndProfileOverreachFailBeforeFactoryInvocation() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let versionRecorder = AuthorityFactoryRecorder()
        let versionRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, AuthorityTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(profile: setup.profile, versions: range(2, 0, 2, 1)),
                probeFailure: nil,
                sessionFailure: nil,
                recorder: versionRecorder
            ))]
        )
        let versionOffer = try await versionRegistry.probe(adapterID: descriptor.adapterID)
        await #expect(throws: AdapterNegotiationError.noCommonVersion) {
            _ = try await versionRegistry.negotiate(offer: versionOffer, policy: policy())
        }
        #expect(await versionRecorder.probeCalls == 1)
        #expect(await versionRecorder.sessionCalls == 0)

        let excessive = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: lifecycleSignals(), evidence: [.tool]),
            delivery: AdapterDeliverySemantics(ordering: .ordered, minimumAuthentication: .ownedChildPipe)
        )
        let profileRecorder = AuthorityFactoryRecorder()
        let profileRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, AuthorityTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(profile: excessive, versions: descriptor.contractVersions),
                probeFailure: nil,
                sessionFailure: nil,
                recorder: profileRecorder
            ))]
        )
        let profileOffer = try await profileRegistry.probe(adapterID: descriptor.adapterID)
        await #expect(throws: AdapterNegotiationError.offeredProfileExceedsMaximum) {
            _ = try await profileRegistry.negotiate(offer: profileOffer, policy: policy())
        }
        #expect(await profileRecorder.probeCalls == 1)
        #expect(await profileRecorder.sessionCalls == 0)
    }

    @Test func unknownAdapterProbeFailsWithoutFactoryInvocation() async throws {
        let setup = try fixtures()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters
        )

        await #expect(throws: AdapterProbeError.unknownAdapter) {
            _ = try await registry.probe(adapterID: AdapterID(validating: "pine:unknown"))
        }
    }

    @Test func exactFactoryMembership() async throws {
        let setup = try fixtures(twoAdapters: true)
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters
        )
        let first = try await negotiate(registry, adapterID: setup.adapters[0].0.adapterID, profile: setup.profile)
        let second = try await negotiate(registry, adapterID: setup.adapters[1].0.adapterID, profile: setup.profile)
        #expect(first.agentID == second.agentID)
        await #expect(throws: AdapterSessionError.launchFailed(.permanent)) {
            _ = try await registry.makeSession(contract: first, resumeFrom: nil) { _ in .accepted }
        }
        await #expect(throws: AdapterSessionError.launchFailed(.permanent)) {
            _ = try await registry.makeSession(contract: second, resumeFrom: nil) { _ in .accepted }
        }
    }

    @Test func registryCollisionsFailClosed() throws {
        let setup = try fixtures()
        let wrong = RegistryTestFactory(id: try AdapterFactoryID(validating: "wrong.factory"))
        #expect(throws: AdapterRegistrationError.descriptorMismatch) {
            _ = try AgentAdapterRegistry(
                compiledPresentations: [setup.presentation], compiledAdapters: [(setup.adapters[0].0, wrong)]
            )
        }
        let collisionA = try AgentPresentationDescriptor(
            agentID: AgentID(validating: "custom-a"), displayName: "Custom A",
            executableAliases: [ExecutableAlias(validating: "local-agent")], style: .generic
        )
        let collisionB = try AgentPresentationDescriptor(
            agentID: AgentID(validating: "custom-b"), displayName: "Custom B",
            executableAliases: [ExecutableAlias(validating: "local-agent")], style: .generic
        )
        #expect(throws: AdapterRegistrationError.aliasCollision) {
            _ = try AgentAdapterRegistry(compiledPresentations: [collisionA, collisionB], compiledAdapters: [])
        }
        let wrongStyle = try AgentPresentationDescriptor(
            agentID: AgentID(validating: "codex"), displayName: "Codex",
            executableAliases: [ExecutableAlias(validating: "codex")], style: .pi
        )
        #expect(throws: AdapterRegistrationError.invalidBuiltInPresentation) {
            _ = try AgentAdapterRegistry(compiledPresentations: [wrongStyle], compiledAdapters: [])
        }
        let omittedBuiltInHijack = try AgentPresentationDescriptor(
            agentID: AgentID(validating: "custom-agent"), displayName: "Custom",
            executableAliases: [ExecutableAlias(validating: "pi")], style: .generic
        )
        #expect(throws: AdapterRegistrationError.aliasCollision) {
            _ = try AgentAdapterRegistry(compiledPresentations: [omittedBuiltInHijack], compiledAdapters: [])
        }
        for (index, alias) in ["claude", "codex", "aider", "github-copilot-cli", "copilot", "pi"].enumerated() {
            let hostile = try AgentPresentationDescriptor(
                agentID: AgentID(validating: "custom-\(index)"), displayName: "Custom",
                executableAliases: [ExecutableAlias(validating: alias)], style: .generic
            )
            #expect(throws: AdapterRegistrationError.aliasCollision) {
                _ = try AgentAdapterRegistry(compiledPresentations: [hostile], compiledAdapters: [])
            }
        }
        for builtInID in ["claudeCode", "codex", "aider", "copilot", "pi"] {
            let malformed = try AgentPresentationDescriptor(
                agentID: AgentID(migratingLegacyStableIdentifier: builtInID), displayName: "Impostor",
                executableAliases: [], style: .generic
            )
            #expect(throws: AdapterRegistrationError.invalidBuiltInPresentation) {
                _ = try AgentAdapterRegistry(compiledPresentations: [malformed], compiledAdapters: [])
            }
        }
        let custom = try AgentPresentationDescriptor(
            agentID: AgentID(validating: "custom-agent"), displayName: "Custom",
            executableAliases: [ExecutableAlias(validating: "custom-agent")], style: .generic
        )
        _ = try AgentAdapterRegistry(compiledPresentations: [custom], compiledAdapters: [])
        let descriptor = setup.adapters[0].0
        let duplicateProfiles = AdapterDescriptor(
            adapterID: descriptor.adapterID, agentID: descriptor.agentID, factoryID: descriptor.factoryID,
            contractVersions: descriptor.contractVersions,
            maximumProfiles: [setup.profile, setup.profile]
        )
        #expect(throws: AdapterRegistrationError.duplicateProfile) {
            _ = try AgentAdapterRegistry(
                compiledPresentations: [setup.presentation],
                compiledAdapters: [(duplicateProfiles, setup.adapters[0].1)]
            )
        }
    }

    @Test func userAliasCollisionFails() throws {
        let setup = try fixtures()
        let registry = try AgentAdapterRegistry(compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters)
        let hostile = try UserAgentPresentationRegistration(
            identifier: "codex-lookalike", displayName: "Codex", executableAliases: ["codex"]
        )
        #expect(throws: AdapterRegistrationError.aliasCollision) {
            _ = try registry.validatedUserPresentations([hostile])
        }
        let emptyRegistry = try AgentAdapterRegistry(compiledPresentations: [], compiledAdapters: [])
        #expect(throws: AdapterRegistrationError.aliasCollision) {
            _ = try emptyRegistry.validatedUserPresentations([hostile])
        }
    }

    @Test func duplicateUserAliasFails() throws {
        let setup = try fixtures()
        let registry = try AgentAdapterRegistry(compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters)
        #expect(throws: AdapterRegistrationError.duplicateAlias) {
            let input = try UserAgentPresentationRegistration(
                identifier: "local", displayName: "Local", executableAliases: ["local", "local"]
            )
            _ = try registry.validatedUserPresentations([input])
        }
    }

    @Test func negotiationEnforcesSecurity() async throws {
        let setup = try fixtures()
        let registry = try AgentAdapterRegistry(compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters)
        let contract = try await negotiate(registry, adapterID: setup.adapters[0].0.adapterID, profile: setup.profile)
        #expect(contract.version == PineAdapterContractVersion(major: 1, minor: 4))
        let forbiddenPolicy = AdapterNegotiationPolicy(
            allowedVersions: range(1, 0, 1, 4), transportPreference: [.ownedStandardIO],
            acceptedAuthentication: [.authenticatedPeer]
        )
        let offer = try await registry.probe(adapterID: setup.adapters[0].0.adapterID)
        await #expect(throws: AdapterNegotiationError.noCommonProfile) {
            _ = try await registry.negotiate(offer: offer, policy: forbiddenPolicy)
        }
    }

    @Test func negotiationRejectsInvalidPolicyAndEmptyOffers() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let probes = ProbeResultSequence([
            try probeResult(profile: setup.profile, versions: range(2, 0, 2, 1)),
            try AdapterProbeResult(
                detectedVendorVersion: DetectedVendorVersion("test-vendor-1.0"),
                detectedSchema: nil,
                offeredProfiles: [],
                offeredContractVersions: descriptor.contractVersions
            ),
            try probeResult(profile: setup.profile, versions: descriptor.contractVersions)
        ])
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, SequencedRecordingFactory(
                id: descriptor.factoryID,
                probes: probes,
                sessionRecorder: nil
            ))]
        )
        let versionOffer = try await registry.probe(adapterID: descriptor.adapterID)
        await #expect(throws: AdapterNegotiationError.noCommonVersion) {
            _ = try await registry.negotiate(offer: versionOffer, policy: policy())
        }
        let emptyOffer = try await registry.probe(adapterID: descriptor.adapterID)
        await #expect(throws: AdapterNegotiationError.noCommonProfile) {
            _ = try await registry.negotiate(offer: emptyOffer, policy: policy())
        }
        let validOffer = try await registry.probe(adapterID: descriptor.adapterID)
        await #expect(throws: AdapterNegotiationError.invalidPolicyRange) {
            _ = try await registry.negotiate(
                offer: validOffer,
                policy: AdapterNegotiationPolicy(
                    allowedVersions: range(2, 0, 1, 0),
                    transportPreference: [.ownedStandardIO],
                    acceptedAuthentication: [.ownedChildPipe]
                )
            )
        }
    }

    @Test func namespacesAreFreshAndResumePreservesLogicalSource() async throws {
        let setup = try fixtures(replay: .sourceCursor)
        let recorder = FactoryRecorder()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions)
            ))]
        )
        let firstContract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let secondContract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let first = try await registry.makeSession(contract: firstContract, resumeFrom: nil) { event in
            await recorder.capture(event); return .accepted
        }
        let second = try await registry.makeSession(contract: secondContract, resumeFrom: nil) { event in
            await recorder.capture(event); return .accepted
        }
        try await first.start()
        try await second.start()
        let firstEvent = try await recorder.emit(candidate(sequence: 1))
        let secondEvent = try await recorder.emit(candidate(sequence: 1), sinkIndex: 1)
        #expect(!firstEvent.hasSameLogicalSource(as: secondEvent))
        #expect(firstEvent.hasSameLogicalSource(as: first))
        #expect(secondEvent.hasSameLogicalSource(as: second))

        let checkpoint = try await registry.makeCheckpoint(for: first)
        for output in [String(describing: checkpoint), String(reflecting: checkpoint), dumped(checkpoint)] {
            #expect(!output.contains("cursor-1"))
            #expect(!output.contains("event-1"))
        }
        #expect(Array(Mirror(reflecting: checkpoint).children).count == 1)
        let resumed = try await registry.makeSession(contract: firstContract, resumeFrom: checkpoint) { event in
            await recorder.capture(event)
            return .accepted
        }
        try await resumed.start()
        let resumedEvent = try await recorder.emit(candidate(sequence: 2), sinkIndex: 2)
        #expect(resumedEvent.hasSameLogicalSource(as: firstEvent))
        #expect(!resumedEvent.hasSameAttempt(as: firstEvent))
        #expect(resumedEvent.hasSameLogicalSource(as: resumed))
        #expect(resumedEvent.hasSameAttempt(as: resumed))
    }

    @Test func preStartEmissionIsRevokedAndActiveSinkIsWrapped() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let factory = RecordingFactory(
            id: descriptor.factoryID,
            recorder: recorder,
            probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions),
            emitDuringMake: true,
            emitDuringStart: true
        )
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation], compiledAdapters: [(descriptor, factory)]
        )
        let contract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let session = try await registry.makeSession(contract: contract, resumeFrom: nil) { event in
            await recorder.capture(event)
            return .accepted
        }
        #expect(await recorder.lastEvent == nil)
        try await session.start()
        #expect(await recorder.startOutcome == .bufferedUntilActivation)
        #expect(await recorder.lastEvent != nil)
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            try await session.start()
        }
        let activeCandidate = AdapterCandidate(
            event: .processExited(status: nil),
            sourcePosition: try AdapterSourcePosition(sourceSequence: 2)
        )
        #expect(await recorder.ingest(activeCandidate) == .accepted)
        let emitted = try #require(await recorder.lastEvent)
        #expect(emitted.hasSameLogicalSource(as: session))
        await session.stop(deadline: .now)
        #expect(await recorder.ingest(try candidate(sequence: 3)) == .revoked)
    }

    @Test func startBufferIsBoundedAndRejectedSequenceCanRetry() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let limit = AgentAdapterRegistry.startBufferLimit
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions),
                emitDuringStart: true,
                startEmissionCount: limit + 1
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { event in
            await recorder.capture(event)
            return .accepted
        }
        try await session.start()

        let outcomes = await recorder.startOutcomes
        #expect(outcomes.count == limit + 1)
        #expect(outcomes.prefix(limit).allSatisfy { $0 == .bufferedUntilActivation })
        #expect(outcomes.last == .retryAfterActivation)
        #expect(await recorder.capturedCount == limit)
        let retry = AdapterCandidate(
            event: .processExited(status: nil),
            sourcePosition: try AdapterSourcePosition(
                sourceSequence: UInt64(limit + 1)
            )
        )
        #expect(await recorder.ingest(retry) == .accepted)
        #expect(await recorder.capturedCount == limit + 1)
    }

    @Test func postCommitIngressCannotExtendActivationWatermark() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let completions = CompletionController()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                emitDuringStart: true
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { event in
            await completions.wait(
                sequence: event.candidate.sourcePosition?.sourceSequence
            )
            await recorder.capture(event)
            return .accepted
        }

        let startTask = Task { try await session.start() }
        await completions.waitUntilArrived(1)
        let postCommit = try candidate(sequence: 2)
        #expect(await recorder.ingest(postCommit) == .retryAfterActivation)

        await completions.release(1)
        try await startTask.value
        #expect(await recorder.capturedCount == 1)
        #expect(await recorder.ingest(postCommit) == .accepted)
        #expect(await recorder.capturedCount == 2)
    }

    @Test func postCommitCancellationFailsStartWithoutReopeningAuthority() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let completions = CompletionController()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions),
                emitDuringStart: true,
                startEmissionCount: 2
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { event in
            let sequence = event.candidate.sourcePosition?.sourceSequence
            await completions.wait(sequence: sequence)
            await recorder.capture(event)
            return .accepted
        }
        await completions.release(1)
        let startTask = Task { try await session.start() }
        await completions.waitUntilArrived(2)
        startTask.cancel()
        await completions.release(2)
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        #expect(await recorder.capturedCount == 2)
        let afterRevocation = AdapterCandidate(
            event: .processExited(status: nil),
            sourcePosition: try AdapterSourcePosition(sourceSequence: 3)
        )
        #expect(await recorder.ingest(afterRevocation) == .revoked)
        await #expect(throws: AdapterSessionError.contractAlreadyConsumed) {
            _ = try await registry.makeSession(
                contract: contract,
                resumeFrom: nil
            ) { _ in .accepted }
        }
    }

    @Test func preCommitTaskCancellationDiscardsStartBuffer() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let hold = StartHold()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions),
                emitDuringStart: true,
                startHold: hold
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { event in
            await recorder.capture(event)
            return .accepted
        }
        let startTask = Task { try await session.start() }
        await hold.waitUntilArrived()
        startTask.cancel()
        await hold.release()
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        #expect(await recorder.startOutcome == .bufferedUntilActivation)
        #expect(await recorder.capturedCount == 0)
        let discarded = AdapterCandidate(
            event: .processExited(status: nil),
            sourcePosition: try AdapterSourcePosition(sourceSequence: 1)
        )
        #expect(await recorder.ingest(discarded) == .revoked)
    }

    @Test func cancellationAtActivationBoundaryLosesToNoCommit() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions),
                emitDuringStart: true,
                cancelBeforeReturning: true
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { event in
            await recorder.capture(event)
            return .accepted
        }
        let startTask = Task { try await session.start() }
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        #expect(await recorder.startOutcome == .bufferedUntilActivation)
        #expect(await recorder.capturedCount == 0)
        let discarded = AdapterCandidate(
            event: .processExited(status: nil),
            sourcePosition: try AdapterSourcePosition(sourceSequence: 1)
        )
        #expect(await recorder.ingest(discarded) == .revoked)
    }

    @Test func lifecycleRejectsRestartAndRevokesFailedStartSink() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions),
                startFailure: AdapterSessionError.launchFailed(.transient),
                emitDuringStart: true
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let failed = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .revoked)
        await #expect(throws: AdapterSessionError.launchFailed(.transient)) {
            try await failed.start()
        }
        #expect(await recorder.startOutcome == .bufferedUntilActivation)
        #expect(await recorder.lastEvent == nil)
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .revoked)
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            try await failed.start()
        }

        let cancellationRecorder = FactoryRecorder()
        let cancellationRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: cancellationRecorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions),
                emitDuringStart: true,
                cancelDuringStart: true
            ))]
        )
        let cancellationContract = try await negotiate(
            cancellationRegistry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let cancelled = try await cancellationRegistry.makeSession(
            contract: cancellationContract,
            resumeFrom: nil
        ) { event in
            await cancellationRecorder.capture(event)
            return .accepted
        }
        await #expect(throws: CancellationError.self) {
            try await cancelled.start()
        }
        #expect(await cancellationRecorder.startOutcome == .bufferedUntilActivation)
        #expect(await cancellationRecorder.lastEvent == nil)
        #expect(
            await cancellationRecorder.ingest(try candidate(sequence: 1))
                == .revoked
        )
    }

    @Test func failureAndMismatchRevokeRetainedSink() async throws {
        let setup = try fixtures(twoAdapters: true)
        let descriptor = setup.adapters[0].0
        let failedRecorder = FactoryRecorder()
        let failedRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: failedRecorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions),
                failure: AdapterSessionError.launchFailed(.permanent)
            ))]
        )
        let failedContract = try await negotiate(failedRegistry, adapterID: descriptor.adapterID, profile: setup.profile)
        await #expect(throws: AdapterSessionError.launchFailed(.permanent)) {
            _ = try await failedRegistry.makeSession(contract: failedContract, resumeFrom: nil) { _ in .accepted }
        }
        #expect(await failedRecorder.ingest(try candidate(sequence: 1)) == .revoked)

        let mismatchRecorder = FactoryRecorder()
        let mismatch = try await mismatchContract(from: setup)
        let mismatchRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: mismatchRecorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions),
                returnedContract: mismatch
            ))]
        )
        let mismatchContract = try await negotiate(mismatchRegistry, adapterID: descriptor.adapterID, profile: setup.profile)
        await #expect(throws: AdapterSessionError.contractMismatch) {
            _ = try await mismatchRegistry.makeSession(contract: mismatchContract, resumeFrom: nil) { _ in .accepted }
        }
        #expect(await mismatchRecorder.ingest(try candidate(sequence: 1)) == .revoked)
    }

    @Test func factoryCancellationPropagatesUnchanged() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, CancellingFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions)
            ))]
        )
        let contract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        await #expect(throws: CancellationError.self) {
            _ = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
        }
    }

    @Test func probeCancellationPropagatesUnchanged() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, ProbeCancellingFactory(id: descriptor.factoryID))]
        )

        await #expect(throws: CancellationError.self) {
            _ = try await registry.probe(adapterID: descriptor.adapterID)
        }
    }

    @Test func registryRejectsProbeResultAfterCallerCancellation() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let cancellation = IgnoredFactoryCancellation()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, CancellationIgnoringProbeFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                cancellation: cancellation
            ))]
        )
        let cancelledProbe = Task {
            try await registry.probe(adapterID: descriptor.adapterID)
        }
        await cancellation.waitUntilEntered()
        cancelledProbe.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledProbe.value
        }

        let offer = try await registry.probe(adapterID: descriptor.adapterID)
        _ = try await registry.negotiate(offer: offer, policy: policy())
    }

    @Test func checkpointRequiresNewAcceptedReplayPosition() async throws {
        let setup = try fixtures(replay: .sourceCursor)
        let recorder = FactoryRecorder()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions)
            ))]
        )
        let droppedContract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let dropped = try await registry.makeSession(
            contract: droppedContract,
            resumeFrom: nil
        ) { _ in .droppedInvalid }
        try await dropped.start()
        await #expect(throws: AdapterSessionError.checkpointUnavailable) {
            _ = try await registry.makeCheckpoint(for: dropped)
        }
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .droppedInvalid)
        await #expect(throws: AdapterSessionError.checkpointUnavailable) {
            _ = try await registry.makeCheckpoint(for: dropped)
        }

        let revokedContract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let revoked = try await registry.makeSession(
            contract: revokedContract,
            resumeFrom: nil
        ) { _ in .revoked }
        try await revoked.start()
        #expect(await recorder.ingest(try candidate(sequence: 2), sinkIndex: 1) == .revoked)
        await #expect(throws: AdapterSessionError.checkpointUnavailable) {
            _ = try await registry.makeCheckpoint(for: revoked)
        }

        let acceptedContract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let accepted = try await registry.makeSession(
            contract: acceptedContract,
            resumeFrom: nil
        ) { _ in .accepted }
        try await accepted.start()
        #expect(await recorder.ingest(try candidate(sequence: 7), sinkIndex: 2) == .accepted)
        _ = try await registry.makeCheckpoint(for: accepted)
        await #expect(throws: AdapterSessionError.checkpointUnavailable) {
            _ = try await registry.makeCheckpoint(for: accepted)
        }
    }

    @Test func checkpointIsUnavailableForNoReplayContract() async throws {
        let setup = try fixtures()
        let recorder = FactoryRecorder()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions)
            ))]
        )
        let contract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let session = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
        try await session.start()
        await #expect(throws: AdapterSessionError.checkpointNotSupported) {
            _ = try await registry.makeCheckpoint(for: session)
        }
    }

    @Test func monotonicAdmissionAndConcurrentCompletionDoNotRegress() async throws {
        let setup = try fixtures(replay: .sourceCursor)
        let recorder = FactoryRecorder()
        let descriptor = setup.adapters[0].0
        let completions = CompletionController()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions)
            ))]
        )
        let contract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let session = try await registry.makeSession(contract: contract, resumeFrom: nil) { event in
            await completions.wait(sequence: event.candidate.sourcePosition?.sourceSequence)
            return .accepted
        }
        try await session.start()
        let secondCandidate = try candidate(sequence: 2)
        let thirdCandidate = try candidate(sequence: 3)
        async let second = recorder.ingest(secondCandidate)
        await completions.waitUntilArrived(2)
        await #expect(throws: AdapterSessionError.checkpointUnavailable) {
            _ = try await registry.makeCheckpoint(for: session)
        }
        async let third = recorder.ingest(thirdCandidate)
        await completions.waitUntilArrived(3)
        await completions.release(3)
        #expect(await third == .accepted)
        await completions.release(2)
        #expect(await second == .accepted)
        #expect(await recorder.ingest(try candidate(sequence: 3)) == .droppedInvalid)
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .droppedInvalid)
        let checkpoint = try await registry.makeCheckpoint(for: session)
        #expect(checkpoint.lastSourceSequence == 3)
    }

    @Test func checkpointIsOneShotAndRejectedBeforeFactoryInvocation() async throws {
        let setup = try fixtures(replay: .sourceCursor)
        let recorder = FactoryRecorder()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions)
            ))]
        )
        let contract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let source = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
        try await source.start()
        #expect(await recorder.ingest(try candidate(sequence: 4)) == .accepted)
        let checkpoint = try await registry.makeCheckpoint(for: source)
        #expect(await recorder.ingest(try candidate(sequence: 5)) == .revoked)
        async let first = canResume(registry, contract: contract, checkpoint: checkpoint)
        async let second = canResume(registry, contract: contract, checkpoint: checkpoint)
        let outcomes = (await first, await second)
        #expect(outcomes.0 != outcomes.1)
        #expect(await recorder.calls == 2)
    }

    @Test func failedResumeConstructionRollsBackCheckpointReservation() async throws {
        let setup = try fixtures(replay: .sourceCursor)
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let resumeFailure = ResumeFailureController()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RetryableResumeFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                recorder: recorder,
                resumeFailure: resumeFailure
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let source = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }
        try await source.start()
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .accepted)
        let checkpoint = try await registry.makeCheckpoint(for: source)

        await #expect(throws: AdapterSessionError.launchFailed(.transient)) {
            _ = try await registry.makeSession(
                contract: contract,
                resumeFrom: checkpoint
            ) { _ in .accepted }
        }
        let failedStart = try await registry.makeSession(
            contract: contract,
            resumeFrom: checkpoint
        ) { _ in .accepted }
        await #expect(throws: AdapterSessionError.launchFailed(.transient)) {
            try await failedStart.start()
        }
        let resumed = try await registry.makeSession(
            contract: contract,
            resumeFrom: checkpoint
        ) { _ in .accepted }
        try await resumed.start()
        await #expect(throws: AdapterSessionError.checkpointAlreadyConsumed) {
            _ = try await registry.makeSession(
                contract: contract,
                resumeFrom: checkpoint
            ) { _ in .accepted }
        }
        #expect(await recorder.calls == 4)
    }

    @Test func registryRejectsFactoryResultAfterConstructionCancellation() async throws {
        let setup = try fixtures(replay: .sourceCursor)
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let cancellation = IgnoredFactoryCancellation()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, CancellationIgnoringResumeFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                cancellation: cancellation
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let source = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }
        try await source.start()
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .accepted)
        let checkpoint = try await registry.makeCheckpoint(for: source)

        let cancelledConstruction = Task {
            try await registry.makeSession(
                contract: contract,
                resumeFrom: checkpoint
            ) { _ in .accepted }
        }
        await cancellation.waitUntilEntered()
        cancelledConstruction.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledConstruction.value
        }

        let resumed = try await registry.makeSession(
            contract: contract,
            resumeFrom: checkpoint
        ) { _ in .accepted }
        try await resumed.start()
    }

    @Test func stopAfterActivationCommitCannotReopenFreshAuthority() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let completions = CompletionController()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                )
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { event in
            await completions.wait(
                sequence: event.candidate.sourcePosition?.sourceSequence
            )
            return .accepted
        }
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .bufferedUntilActivation)
        let startTask = Task { try await session.start() }
        await completions.waitUntilArrived(1)

        let stopTask = Task {
            await session.stop(
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        var closingOutcome = AdapterIngestOutcome.retryAfterActivation
        for _ in 0..<1_000 where closingOutcome != .revoked {
            closingOutcome = await recorder.ingest(try candidate(sequence: 2))
            await Task.yield()
        }
        #expect(closingOutcome == .revoked)
        await #expect(throws: AdapterSessionError.contractAlreadyConsumed) {
            _ = try await registry.makeSession(
                contract: contract,
                resumeFrom: nil
            ) { _ in .accepted }
        }

        await completions.release(1)
        await #expect(throws: AdapterSessionError.invalidLifecycle) {
            try await startTask.value
        }
        await stopTask.value
    }

    @Test func stopRunsOutsideCallerCancellation() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let stopHold = StopHold()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, StopTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                stopHold: stopHold
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }

        let stopTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await session.stop(
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        await stopHold.waitUntilArrived()
        await stopHold.release()
        await stopTask.value
        #expect(await stopHold.observedCallerCancellation == false)
    }

    @Test func stopCancelsCooperativeCleanupAtDeadlineAndReleasesCapacity() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let stopHold = StopHold()
        let capacity = AdapterCleanupCapacity(limit: 1)
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, StopTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                stopHold: stopHold
            ))],
            cleanupCapacity: capacity
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let replacementContract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(200))
        let stopTask = Task {
            await session.stop(deadline: deadline)
            return clock.now
        }
        let watchdog = Task {
            try? await clock.sleep(until: deadline.advanced(by: .seconds(2)))
            await stopHold.release()
        }

        await stopHold.waitUntilArrived()
        let returnedAt = await stopTask.value
        await stopHold.waitUntilFinished()
        watchdog.cancel()
        await stopHold.release()
        #expect(returnedAt <= deadline.advanced(by: .seconds(1)))
        #expect(await stopHold.observedCancellationAtExit == true)
        #expect(capacity.reservedCount == 0)

        let replacement = try await registry.makeSession(
            contract: replacementContract,
            resumeFrom: nil
        ) { _ in .accepted }
        #expect(capacity.reservedCount == 1)
        await replacement.stop(
            deadline: ContinuousClock.now.advanced(by: .seconds(1))
        )
        #expect(capacity.reservedCount == 0)
    }

    @Test func cancellationIgnoringCleanupRetainsCapacityUntilActualExit() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let hold = IgnoringStopHold()
        let capacity = AdapterCleanupCapacity(limit: 1)
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, IgnoringStopTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                hold: hold
            ))],
            cleanupCapacity: capacity
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let replacementContract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(200))
        let stopTask = Task {
            await session.stop(deadline: deadline)
            return clock.now
        }
        let watchdog = Task {
            try? await clock.sleep(until: deadline.advanced(by: .seconds(2)))
            await hold.release()
        }

        await hold.waitUntilArrived()
        let returnedAt = await stopTask.value
        #expect(returnedAt <= deadline.advanced(by: .seconds(1)))
        #expect(capacity.reservedCount == 1)
        await #expect(throws: AdapterSessionError.cleanupCapacityUnavailable) {
            _ = try await registry.makeSession(
                contract: replacementContract,
                resumeFrom: nil
            ) { _ in .accepted }
        }

        await hold.release()
        await hold.waitUntilFinished()
        watchdog.cancel()
        #expect(await hold.observedCancellationAtExit == true)
        for _ in 0..<10_000 where capacity.reservedCount != 0 {
            await Task.yield()
        }
        #expect(capacity.reservedCount == 0)

        let replacement = try await registry.makeSession(
            contract: replacementContract,
            resumeFrom: nil
        ) { _ in .accepted }
        await replacement.stop(
            deadline: ContinuousClock.now.advanced(by: .seconds(1))
        )
        #expect(await hold.callCount == 2)
        #expect(capacity.reservedCount == 0)
    }

    @Test func laterShortStopKeepsInitiatingLongCleanupAlive() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let hold = StopHold()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, StopTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                stopHold: hold
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }
        let clock = ContinuousClock()
        let longDeadline = clock.now.advanced(by: .seconds(2))
        let longStop = Task {
            await session.stop(deadline: longDeadline)
            return clock.now
        }
        await hold.waitUntilArrived()

        let shortDeadline = clock.now.advanced(by: .milliseconds(200))
        let shortStop = Task {
            await session.stop(deadline: shortDeadline)
            return clock.now
        }
        let shortReturnedAt = await shortStop.value
        #expect(shortReturnedAt <= shortDeadline.advanced(by: .seconds(1)))
        #expect(await hold.callCount == 1)
        #expect(await hold.observedCancellationAtExit == nil)

        await hold.release()
        let longReturnedAt = await longStop.value
        await hold.waitUntilFinished()
        #expect(longReturnedAt <= longDeadline.advanced(by: .seconds(1)))
        #expect(await hold.observedCancellationAtExit == false)
    }

    @Test func initiatingShortStopCancelsSharedCleanupForLongFollower() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let hold = StopHold()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, StopTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                stopHold: hold
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { _ in .accepted }
        let clock = ContinuousClock()
        let shortDeadline = clock.now.advanced(by: .milliseconds(200))
        let shortStop = Task {
            await session.stop(deadline: shortDeadline)
            return clock.now
        }
        await hold.waitUntilArrived()
        let longDeadline = clock.now.advanced(by: .seconds(2))
        let longStop = Task {
            await session.stop(deadline: longDeadline)
            return clock.now
        }
        let watchdog = Task {
            try? await clock.sleep(until: shortDeadline.advanced(by: .seconds(2)))
            await hold.release()
        }

        let shortReturnedAt = await shortStop.value
        let longReturnedAt = await longStop.value
        await hold.waitUntilFinished()
        watchdog.cancel()
        await hold.release()
        #expect(shortReturnedAt <= shortDeadline.advanced(by: .seconds(1)))
        #expect(longReturnedAt <= shortDeadline.advanced(by: .seconds(1)))
        #expect(await hold.callCount == 1)
        #expect(await hold.observedCancellationAtExit == true)
    }

    @Test func stopPreservesAcceptedOutcomeForAlreadyAdmittedDelivery() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let completions = CompletionController()
        let stopHold = StopHold()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, StopTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                stopHold: stopHold,
                recorder: recorder
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { event in
            await completions.wait(
                sequence: event.candidate.sourcePosition?.sourceSequence
            )
            return .accepted
        }
        try await session.start()

        let admitted = Task { await recorder.ingest(try candidate(sequence: 1)) }
        await completions.waitUntilArrived(1)
        let firstStop = Task {
            await session.stop(
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        let secondStop = Task {
            await session.stop(
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        }
        await stopHold.waitUntilArrived()
        await stopHold.release()
        #expect(await recorder.ingest(try candidate(sequence: 2)) == .revoked)
        await completions.release(1)

        #expect(try await admitted.value == .accepted)
        await firstStop.value
        await secondStop.value
        #expect(await stopHold.callCount == 1)
    }

    @Test func stopWaitsForCurrentInFlightWorkAfterAnEarlierDrain() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let completions = CompletionController()
        let stopHold = StopHold()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, StopTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(
                    profile: setup.profile,
                    versions: descriptor.contractVersions
                ),
                stopHold: stopHold,
                recorder: recorder
            ))]
        )
        let contract = try await negotiate(
            registry,
            adapterID: descriptor.adapterID,
            profile: setup.profile
        )
        let session = try await registry.makeSession(
            contract: contract,
            resumeFrom: nil
        ) { event in
            await completions.wait(
                sequence: event.candidate.sourcePosition?.sourceSequence
            )
            return .accepted
        }
        try await session.start()

        let earlier = Task { await recorder.ingest(try candidate(sequence: 1)) }
        await completions.waitUntilArrived(1)
        await completions.release(1)
        #expect(try await earlier.value == .accepted)

        let current = Task { await recorder.ingest(try candidate(sequence: 2)) }
        await completions.waitUntilArrived(2)
        let stopReturned = TestSignal()
        let stopTask = Task {
            await session.stop(
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
            await stopReturned.signal()
        }
        await stopHold.waitUntilArrived()
        await stopHold.release()
        #expect(await recorder.ingest(try candidate(sequence: 3)) == .revoked)
        #expect(await signal(stopReturned, arrivesWithin: .milliseconds(200)) == false)

        await completions.release(2)
        #expect(try await current.value == .accepted)
        await stopTask.value
    }

    @Test func checkpointBindingsAndResumeBaselineFailClosed() async throws {
        let setup = try fixtures(twoAdapters: true, replay: .sourceCursor)
        let recorder = FactoryRecorder()
        let compiled = try setup.adapters.map { descriptor, _ in
            (descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                probeResult: try probeResult(profile: setup.profile, versions: descriptor.contractVersions)
            ) as any AgentAdapterFactory)
        }
        let registry = try AgentAdapterRegistry(compiledPresentations: [setup.presentation], compiledAdapters: compiled)
        let first = try await negotiate(registry, adapterID: compiled[0].0.adapterID, profile: setup.profile)
        let second = try await negotiate(registry, adapterID: compiled[1].0.adapterID, profile: setup.profile)
        let source = try await registry.makeSession(contract: first, resumeFrom: nil) { _ in .accepted }
        try await source.start()
        #expect(await recorder.ingest(try candidate(sequence: 5)) == .accepted)
        let checkpoint = try await registry.makeCheckpoint(for: source)
        #expect(await recorder.ingest(try candidate(sequence: 6)) == .revoked)
        await #expect(throws: AdapterSessionError.checkpointMismatch) {
            _ = try await registry.makeSession(contract: second, resumeFrom: checkpoint) { _ in .accepted }
        }
        #expect(await recorder.calls == 1)

        let foreignRecorder = FactoryRecorder()
        let foreignRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(compiled[0].0, RecordingFactory(
                id: compiled[0].0.factoryID,
                recorder: foreignRecorder,
                probeResult: try probeResult(profile: setup.profile, versions: compiled[0].0.contractVersions)
            ))]
        )
        let foreign = try await negotiate(foreignRegistry, adapterID: compiled[0].0.adapterID, profile: setup.profile)
        await #expect(throws: AdapterSessionError.checkpointMismatch) {
            _ = try await foreignRegistry.makeSession(contract: foreign, resumeFrom: checkpoint) { _ in .accepted }
        }
        #expect(await foreignRecorder.calls == 0)

        let resumed = try await registry.makeSession(contract: first, resumeFrom: checkpoint) { _ in .accepted }
        try await resumed.start()
        #expect(await recorder.ingest(try candidate(sequence: 5), sinkIndex: 1) == .droppedInvalid)
        #expect(await recorder.ingest(try candidate(sequence: 6), sinkIndex: 1) == .accepted)
        #expect((try await registry.makeCheckpoint(for: resumed)).lastSourceSequence == 6)
    }

    @Test func checkpointRejectsDifferentVersionAndProfileBeforeFactory() async throws {
        let setup = try fixtures(replay: .sourceCursor)
        let descriptor = setup.adapters[0].0
        let alternate = try AdapterCapabilityProfile(
            transport: .authenticatedLocalIPC,
            lifecycle: AdapterLifecycleCapabilities(signals: lifecycleSignals(), evidence: []),
            delivery: AdapterDeliverySemantics(
                replay: .sourceCursor, ordering: .ordered, minimumAuthentication: .authenticatedPeer
            )
        )
        let expanded = AdapterDescriptor(
            adapterID: descriptor.adapterID,
            agentID: descriptor.agentID,
            factoryID: descriptor.factoryID,
            contractVersions: descriptor.contractVersions,
            maximumProfiles: [setup.profile, alternate]
        )
        let recorder = FactoryRecorder()
        let probes = ProbeResultSequence([
            try probeResult(profile: setup.profile, versions: range(1, 0, 1, 4)),
            try probeResult(profile: setup.profile, versions: range(1, 0, 1, 3)),
            try probeResult(profile: alternate, versions: range(1, 0, 1, 4))
        ])
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(expanded, SequencedRecordingFactory(
                id: descriptor.factoryID,
                probes: probes,
                sessionRecorder: recorder
            ))]
        )
        let sourceContract = try await negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let source = try await registry.makeSession(contract: sourceContract, resumeFrom: nil) { _ in .accepted }
        try await source.start()
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .accepted)
        let checkpoint = try await registry.makeCheckpoint(for: source)

        let olderOffer = try await registry.probe(adapterID: descriptor.adapterID)
        let olderVersion = try await registry.negotiate(offer: olderOffer, policy: policy())
        await #expect(throws: AdapterSessionError.checkpointMismatch) {
            _ = try await registry.makeSession(contract: olderVersion, resumeFrom: checkpoint) { _ in .accepted }
        }
        let alternateOffer = try await registry.probe(adapterID: descriptor.adapterID)
        let alternateProfile = try await registry.negotiate(
            offer: alternateOffer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: range(1, 0, 1, 4),
                transportPreference: [.authenticatedLocalIPC],
                acceptedAuthentication: [.authenticatedPeer]
            )
        )
        await #expect(throws: AdapterSessionError.checkpointMismatch) {
            _ = try await registry.makeSession(contract: alternateProfile, resumeFrom: checkpoint) { _ in .accepted }
        }
        #expect(await recorder.calls == 1)
    }

    @Test func policyIgnoresOfferOrder() async throws {
        let setup = try fixtures()
        let local = try AdapterCapabilityProfile(
            transport: .authenticatedLocalIPC,
            lifecycle: AdapterLifecycleCapabilities(signals: lifecycleSignals(), evidence: []),
            delivery: AdapterDeliverySemantics(ordering: .ordered, minimumAuthentication: .authenticatedPeer)
        )
        let descriptor = setup.adapters[0].0
        let richerLocal = try AdapterCapabilityProfile(
            transport: .authenticatedLocalIPC,
            lifecycle: AdapterLifecycleCapabilities(
                signals: lifecycleSignals().union([.init(scope: .turn, phase: .working)]), evidence: []
            ),
            delivery: AdapterDeliverySemantics(ordering: .ordered, minimumAuthentication: .authenticatedPeer)
        )
        let complete = AdapterDescriptor(
            adapterID: descriptor.adapterID, agentID: descriptor.agentID, factoryID: descriptor.factoryID,
            contractVersions: descriptor.contractVersions, maximumProfiles: [setup.profile, local, richerLocal]
        )
        let offers = [setup.profile, local, richerLocal]
        let permutations = [offers, Array(offers.reversed()), [local, setup.profile, richerLocal]]
        let probes = try permutations.map { offered in
            try AdapterProbeResult(
                detectedVendorVersion: DetectedVendorVersion("test-vendor-1.0"),
                detectedSchema: nil,
                offeredProfiles: Array(offered),
                offeredContractVersions: range(1, 0, 1, 4)
            )
        }
        let completeRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(complete, SequencedRecordingFactory(
                id: descriptor.factoryID,
                probes: ProbeResultSequence(probes),
                sessionRecorder: nil
            ))]
        )
        var selections: [NegotiatedAdapterContract] = []
        for _ in permutations {
            let offer = try await completeRegistry.probe(adapterID: descriptor.adapterID)
            selections.append(try await completeRegistry.negotiate(
                offer: offer,
                policy: AdapterNegotiationPolicy(
                    allowedVersions: range(1, 0, 1, 4),
                    transportPreference: [.authenticatedLocalIPC, .ownedStandardIO],
                    acceptedAuthentication: [.ownedChildPipe, .authenticatedPeer]
                )
            ))
        }
        #expect(selections.allSatisfy { $0 == selections[0] })
        #expect(selections[0].profile.transport == .authenticatedLocalIPC)
    }

    @Test func escalationFails() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let excessive = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: lifecycleSignals(), evidence: [.tool]),
            delivery: AdapterDeliverySemantics(ordering: .ordered, minimumAuthentication: .ownedChildPipe)
        )
        let recorder = AuthorityFactoryRecorder()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, AuthorityTestFactory(
                id: descriptor.factoryID,
                probeResult: try probeResult(profile: excessive, versions: descriptor.contractVersions),
                probeFailure: nil,
                sessionFailure: nil,
                recorder: recorder
            ))]
        )
        let offer = try await registry.probe(adapterID: descriptor.adapterID)
        await #expect(throws: AdapterNegotiationError.offeredProfileExceedsMaximum) {
            _ = try await registry.negotiate(offer: offer, policy: policy())
        }
    }

    private func dumped<T>(_ value: T) -> String {
        var output = ""
        dump(value, to: &output)
        return output
    }

    private func fixtures(twoAdapters: Bool = false, replay: AdapterReplay = .none) throws -> (
        presentation: AgentPresentationDescriptor,
        adapters: [(AdapterDescriptor, any AgentAdapterFactory)], profile: AdapterCapabilityProfile
    ) {
        let agent = try AgentID(validating: "codex")
        let presentation = try AgentPresentationDescriptor(
            agentID: agent, displayName: "Codex", executableAliases: [ExecutableAlias(validating: "codex")], style: .codex
        )
        let profile = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: lifecycleSignals(), evidence: []),
            delivery: AdapterDeliverySemantics(
                replay: replay, ordering: .ordered, minimumAuthentication: .ownedChildPipe
            )
        )
        func pair(_ suffix: String) throws -> (AdapterDescriptor, any AgentAdapterFactory) {
            let factoryID = try AdapterFactoryID(validating: "pine.codex.\(suffix).factory")
            let descriptor = AdapterDescriptor(
                adapterID: try AdapterID(validating: "pine:codex:\(suffix)"), agentID: agent, factoryID: factoryID,
                contractVersions: range(1, 0, 1, 4), maximumProfiles: [profile]
            )
            return (descriptor, RegistryTestFactory(
                id: factoryID,
                probeResult: try probeResult(profile: profile, versions: descriptor.contractVersions)
            ))
        }
        return (presentation, twoAdapters ? [try pair("stdio"), try pair("rpc")] : [try pair("stdio")], profile)
    }

    private func mismatchContract(from setup: (
        presentation: AgentPresentationDescriptor,
        adapters: [(AdapterDescriptor, any AgentAdapterFactory)], profile: AdapterCapabilityProfile
    )) async throws -> NegotiatedAdapterContract {
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters
        )
        return try await negotiate(registry, adapterID: setup.adapters[1].0.adapterID, profile: setup.profile)
    }

    private func negotiate(
        _ registry: AgentAdapterRegistry, adapterID: AdapterID, profile: AdapterCapabilityProfile
    ) async throws -> NegotiatedAdapterContract {
        let offer = try await registry.probe(adapterID: adapterID)
        return try await registry.negotiate(
            offer: offer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: range(1, 0, 1, 8), transportPreference: [profile.transport],
                acceptedAuthentication: [profile.minimumAuthentication]
            )
        )
    }

    private func range(_ minMajor: UInt16, _ minMinor: UInt16, _ maxMajor: UInt16, _ maxMinor: UInt16) -> PineAdapterContractVersionRange {
        PineAdapterContractVersionRange(
            minimum: PineAdapterContractVersion(major: minMajor, minor: minMinor),
            maximum: PineAdapterContractVersion(major: maxMajor, minor: maxMinor)
        )
    }

    private func policy() -> AdapterNegotiationPolicy {
        AdapterNegotiationPolicy(
            allowedVersions: range(1, 0, 1, 4),
            transportPreference: [.ownedStandardIO],
            acceptedAuthentication: [.ownedChildPipe]
        )
    }

    private func probeResult(
        profile: AdapterCapabilityProfile,
        versions: PineAdapterContractVersionRange
    ) throws -> AdapterProbeResult {
        try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion("test-vendor-1.0"),
            detectedSchema: nil,
            offeredProfiles: [profile],
            offeredContractVersions: versions
        )
    }

    private func lifecycleSignals() -> Set<AdapterLifecycleCapabilities.Signal> {
        [.init(scope: .session, phase: .settled), .init(scope: .turn, phase: .started)]
    }

    private func candidate(sequence: UInt64) throws -> AdapterCandidate {
        AdapterCandidate(
            event: .processExited(status: nil),
            sourcePosition: try AdapterSourcePosition(
                sourceEvent: VendorReference(role: .event, value: "event-\(sequence)"),
                resumePosition: AdapterResumePosition("cursor-\(sequence)"),
                sourceSequence: sequence
            )
        )
    }

    private func canResume(
        _ registry: AgentAdapterRegistry,
        contract: NegotiatedAdapterContract,
        checkpoint: AdapterResumeCheckpoint
    ) async -> Bool {
        do {
            _ = try await registry.makeSession(contract: contract, resumeFrom: checkpoint) { _ in .accepted }
            return true
        } catch {
            return false
        }
    }
}

nonisolated private struct RecordingFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let recorder: FactoryRecorder
    let probeResult: AdapterProbeResult
    var emitDuringMake = false
    var failure: AdapterSessionError?
    var returnedContract: NegotiatedAdapterContract?
    var startFailure: AdapterSessionError?
    var emitDuringStart = false
    var startEmissionCount = 1
    var cancelDuringStart = false
    var cancelBeforeReturning = false
    var startHold: StartHold?
    func probe() async throws -> AdapterProbeResult { probeResult }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        await recorder.record(request: request)
        if emitDuringMake {
            _ = await request.sink.ingest(AdapterCandidate(
                event: .processExited(status: nil),
                sourcePosition: try AdapterSourcePosition(sourceSequence: 1)
            ))
        }
        if let failure { throw failure }
        return RegistryTestSession(
            contract: returnedContract ?? request.contract,
            startFailure: startFailure,
            startSink: request.sink,
            startRecorder: recorder,
            emitDuringStart: emitDuringStart,
            startEmissionCount: startEmissionCount,
            cancelDuringStart: cancelDuringStart,
            cancelBeforeReturning: cancelBeforeReturning,
            startHold: startHold
        )
    }
}

private actor FactoryRecorder {
    private(set) var contract: NegotiatedAdapterContract?
    private(set) var sequence: UInt64?
    private(set) var calls = 0
    private(set) var cursor: String?
    private(set) var event: String?
    private(set) var sinks: [any AgentEventSink] = []
    private(set) var lastEvent: ValidatedAgentEvent?
    private(set) var startOutcome: AdapterIngestOutcome?
    private(set) var startOutcomes: [AdapterIngestOutcome] = []
    private(set) var capturedCount = 0

    func record(request: AgentAdapterSessionRequest) {
        calls += 1
        contract = request.contract
        sequence = request.resumeFrom?.lastSourceSequence
        cursor = request.resumeFrom?.resumePosition.rawValue
        event = request.resumeFrom?.lastSourceEvent.rawValue
        sinks.append(request.sink)
    }

    func ingest(_ candidate: AdapterCandidate, sinkIndex: Int = 0) async -> AdapterIngestOutcome {
        guard sinks.indices.contains(sinkIndex) else { return .revoked }
        return await sinks[sinkIndex].ingest(candidate)
    }

    func emit(_ candidate: AdapterCandidate, sinkIndex: Int = 0) async throws -> ValidatedAgentEvent {
        lastEvent = nil
        guard await ingest(candidate, sinkIndex: sinkIndex) == .accepted,
              let lastEvent else { throw AdapterSessionError.checkpointUnavailable }
        return lastEvent
    }

    func capture(_ event: ValidatedAgentEvent) {
        lastEvent = event
        capturedCount += 1
    }
    func recordStartOutcome(_ outcome: AdapterIngestOutcome) {
        startOutcome = outcome
        startOutcomes.append(outcome)
    }
}

nonisolated private struct MismatchingFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let returnedContract: NegotiatedAdapterContract
    func probe() async throws -> AdapterProbeResult { throw AdapterProbeError.unavailable(.permanent) }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        RegistryTestSession(contract: returnedContract)
    }
}

nonisolated private struct CancellingFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let probeResult: AdapterProbeResult
    func probe() async throws -> AdapterProbeResult { probeResult }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        throw CancellationError()
    }
}

nonisolated private struct ProbeCancellingFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    func probe() async throws -> AdapterProbeResult { throw CancellationError() }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        throw AdapterSessionError.launchFailed(.permanent)
    }
}

nonisolated private struct CancellationIgnoringProbeFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let probeResult: AdapterProbeResult
    let cancellation: IgnoredFactoryCancellation

    func probe() async throws -> AdapterProbeResult {
        await cancellation.ignoreOnce()
        return probeResult
    }

    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        RegistryTestSession(contract: request.contract)
    }
}

private actor ResumeFailureController {
    enum Behavior: Sendable { case failConstruction, failStart, succeed }
    private var attempt = 0

    func nextBehavior() -> Behavior {
        attempt += 1
        switch attempt {
        case 1: return .failConstruction
        case 2: return .failStart
        default: return .succeed
        }
    }
}

nonisolated private struct RetryableResumeFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let probeResult: AdapterProbeResult
    let recorder: FactoryRecorder
    let resumeFailure: ResumeFailureController

    func probe() async throws -> AdapterProbeResult { probeResult }

    func makeSession(
        _ request: AgentAdapterSessionRequest
    ) async throws -> any AgentAdapterSession {
        await recorder.record(request: request)
        if request.resumeFrom != nil {
            switch await resumeFailure.nextBehavior() {
            case .failConstruction:
                throw AdapterSessionError.launchFailed(.transient)
            case .failStart:
                return RegistryTestSession(
                    contract: request.contract,
                    startFailure: .launchFailed(.transient)
                )
            case .succeed:
                break
            }
        }
        return RegistryTestSession(contract: request.contract)
    }
}

private actor IgnoredFactoryCancellation {
    private let entered = TestSignal()
    private var attempts = 0

    func ignoreOnce() async {
        attempts += 1
        guard attempts == 1 else { return }
        await entered.signal()
        while !Task.isCancelled {
            await Task.yield()
        }
    }

    func waitUntilEntered() async {
        await entered.wait()
    }
}

nonisolated private struct CancellationIgnoringResumeFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let recorder: FactoryRecorder
    let probeResult: AdapterProbeResult
    let cancellation: IgnoredFactoryCancellation

    func probe() async throws -> AdapterProbeResult { probeResult }

    func makeSession(
        _ request: AgentAdapterSessionRequest
    ) async throws -> any AgentAdapterSession {
        await recorder.record(request: request)
        if request.resumeFrom != nil {
            await cancellation.ignoreOnce()
        }
        return RegistryTestSession(contract: request.contract)
    }
}

nonisolated private struct IgnoringStopTestFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let probeResult: AdapterProbeResult
    let hold: IgnoringStopHold

    func probe() async throws -> AdapterProbeResult { probeResult }

    func makeSession(
        _ request: AgentAdapterSessionRequest
    ) async throws -> any AgentAdapterSession {
        IgnoringStopTestSession(contract: request.contract, hold: hold)
    }
}

nonisolated private struct IgnoringStopTestSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    let hold: IgnoringStopHold

    func start() async throws {}
    func stop(deadline: ContinuousClock.Instant) async {
        await hold.wait()
    }
}

nonisolated private struct StopTestFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let probeResult: AdapterProbeResult
    let stopHold: StopHold
    var recorder: FactoryRecorder? = nil

    func probe() async throws -> AdapterProbeResult { probeResult }

    func makeSession(
        _ request: AgentAdapterSessionRequest
    ) async throws -> any AgentAdapterSession {
        if let recorder { await recorder.record(request: request) }
        return StopTestSession(contract: request.contract, stopHold: stopHold)
    }
}

nonisolated private struct StopTestSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    let stopHold: StopHold

    func start() async throws {}
    func stop(deadline: ContinuousClock.Instant) async {
        await stopHold.wait()
    }
}

private actor StopHold {
    private let arrival = TestSignal()
    private let releaseSignal = TestSignal()
    private let finished = TestSignal()
    private(set) var observedCallerCancellation: Bool?
    private(set) var observedCancellationAtExit: Bool?
    private(set) var callCount = 0

    func wait() async {
        callCount += 1
        if observedCallerCancellation == nil {
            observedCallerCancellation = Task.isCancelled
        }
        await arrival.signal()
        await releaseSignal.wait()
        observedCancellationAtExit = Task.isCancelled
        await finished.signal()
    }

    func waitUntilArrived() async {
        await arrival.wait()
    }

    func waitUntilFinished() async {
        await finished.wait()
    }

    func release() async {
        await releaseSignal.signal()
    }
}

private actor IgnoringStopHold {
    private let arrival = TestSignal()
    private let finished = TestSignal()
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var observedCancellationAtExit: Bool?
    private(set) var callCount = 0

    func wait() async {
        callCount += 1
        await arrival.signal()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        observedCancellationAtExit = Task.isCancelled
        await finished.signal()
    }

    func waitUntilArrived() async {
        await arrival.wait()
    }

    func waitUntilFinished() async {
        await finished.wait()
    }

    func release() {
        guard !released else { return }
        released = true
        let retained = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        retained.forEach { $0.resume() }
    }
}

nonisolated private func signal(
    _ signal: TestSignal,
    arrivesWithin duration: Duration
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await signal.wait()
            return true
        }
        group.addTask {
            try? await Task.sleep(for: duration)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

private actor TestSignal {
    private var isSignalled = false
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var cancelledBeforeRegistration = Set<UInt64>()
    private var resolvedBeforeCancellation = Set<UInt64>()

    var signalled: Bool { isSignalled }

    func wait() async {
        guard !isSignalled, !Task.isCancelled else { return }
        nextWaiterID += 1
        let waiterID = nextWaiterID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isSignalled || Task.isCancelled
                    || cancelledBeforeRegistration.remove(waiterID) != nil {
                    resolvedBeforeCancellation.insert(waiterID)
                    continuation.resume()
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let retained = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        cancelledBeforeRegistration.removeAll(keepingCapacity: false)
        resolvedBeforeCancellation.removeAll(keepingCapacity: false)
        retained.forEach { $0.resume() }
    }

    private func cancel(_ waiterID: UInt64) {
        guard !isSignalled else { return }
        if resolvedBeforeCancellation.remove(waiterID) != nil { return }
        if let waiter = waiters.removeValue(forKey: waiterID) {
            waiter.resume()
        } else {
            cancelledBeforeRegistration.insert(waiterID)
        }
    }
}

private actor StartHold {
    private let arrival = TestSignal()
    private let releaseSignal = TestSignal()

    func wait() async {
        await arrival.signal()
        await releaseSignal.wait()
    }

    func waitUntilArrived() async {
        await arrival.wait()
    }

    func release() async {
        await releaseSignal.signal()
    }
}

private actor CompletionController {
    private var arrivals: [UInt64: TestSignal] = [:]
    private var releases: [UInt64: TestSignal] = [:]

    func wait(sequence: UInt64?) async {
        guard let sequence else { return }
        let arrival = signal(for: sequence, in: &arrivals)
        let release = signal(for: sequence, in: &releases)
        await arrival.signal()
        await release.wait()
    }

    func waitUntilArrived(_ sequence: UInt64) async {
        let arrival = signal(for: sequence, in: &arrivals)
        await arrival.wait()
    }

    func release(_ sequence: UInt64) async {
        let release = signal(for: sequence, in: &releases)
        await release.signal()
    }

    private func signal(
        for sequence: UInt64,
        in signals: inout [UInt64: TestSignal]
    ) -> TestSignal {
        if let existing = signals[sequence] { return existing }
        let created = TestSignal()
        signals[sequence] = created
        return created
    }
}
