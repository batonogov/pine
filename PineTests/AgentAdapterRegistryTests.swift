import Testing
@testable import Pine

nonisolated private struct RegistryTestFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let failure: AdapterFailureDisposition
    init(id: AdapterFactoryID, failure: AdapterFailureDisposition = .permanent) {
        self.id = id
        self.failure = failure
    }
    func probe() async throws -> AdapterProbeResult { throw AdapterProbeError.unavailable(.permanent) }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        throw AdapterSessionError.launchFailed(failure)
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

@Suite("Agent adapter compiled registry")
struct AgentAdapterRegistryTests {
    @Test func exactFactoryMembership() async throws {
        let setup = try fixtures(twoAdapters: true)
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters
        )
        let first = try negotiate(registry, adapterID: setup.adapters[0].0.adapterID, profile: setup.profile)
        let second = try negotiate(registry, adapterID: setup.adapters[1].0.adapterID, profile: setup.profile)
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

    @Test func negotiationEnforcesSecurity() throws {
        let setup = try fixtures()
        let registry = try AgentAdapterRegistry(compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters)
        let contract = try negotiate(registry, adapterID: setup.adapters[0].0.adapterID, profile: setup.profile)
        #expect(contract.version == PineAdapterContractVersion(major: 1, minor: 4))
        let forbiddenPolicy = AdapterNegotiationPolicy(
            allowedVersions: range(1, 0, 1, 4), transportPreference: [.ownedStandardIO],
            acceptedAuthentication: [.authenticatedPeer]
        )
        #expect(throws: AdapterNegotiationError.noCommonProfile) {
            _ = try registry.negotiate(
                adapterID: setup.adapters[0].0.adapterID, offeredProfiles: [setup.profile],
                offeredVersions: range(1, 1, 1, 9), policy: forbiddenPolicy
            )
        }
    }

    @Test func negotiationRejectsInvalidAndEmptyOffers() throws {
        let setup = try fixtures()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters
        )
        let adapterID = setup.adapters[0].0.adapterID
        #expect(throws: AdapterNegotiationError.noCommonVersion) {
            _ = try registry.negotiate(
                adapterID: adapterID, offeredProfiles: [setup.profile],
                offeredVersions: range(2, 0, 2, 1), policy: policy()
            )
        }
        #expect(throws: AdapterNegotiationError.noCommonProfile) {
            _ = try registry.negotiate(
                adapterID: adapterID, offeredProfiles: [],
                offeredVersions: range(1, 0, 1, 4), policy: policy()
            )
        }
        #expect(throws: AdapterNegotiationError.invalidPolicyRange) {
            _ = try registry.negotiate(
                adapterID: adapterID, offeredProfiles: [setup.profile],
                offeredVersions: range(1, 0, 1, 4),
                policy: AdapterNegotiationPolicy(
                    allowedVersions: range(2, 0, 1, 0),
                    transportPreference: [.ownedStandardIO],
                    acceptedAuthentication: [.ownedChildPipe]
                )
            )
        }
        #expect(throws: AdapterNegotiationError.invalidPolicyRange) {
            _ = try registry.negotiate(
                adapterID: adapterID, offeredProfiles: [setup.profile, setup.profile],
                offeredVersions: range(1, 0, 1, 4), policy: policy()
            )
        }
    }

    @Test func namespacesAreFreshAndResumePreservesLogicalSource() async throws {
        let setup = try fixtures(replay: .sourceCursor)
        let recorder = FactoryRecorder()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(id: descriptor.factoryID, recorder: recorder))]
        )
        let contract = try negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let first = try await registry.makeSession(contract: contract, resumeFrom: nil) { event in
            await recorder.capture(event); return .accepted
        }
        let second = try await registry.makeSession(contract: contract, resumeFrom: nil) { event in
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
        let resumed = try await registry.makeSession(contract: contract, resumeFrom: checkpoint) { event in
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
            emitDuringMake: true,
            emitDuringStart: true
        )
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation], compiledAdapters: [(descriptor, factory)]
        )
        let contract = try negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
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
                emitDuringStart: true,
                startEmissionCount: limit + 1
            ))]
        )
        let contract = try negotiate(
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
        #expect(outcomes.last == .droppedInvalid)
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

    @Test func postCommitRevocationDoesNotFailStart() async throws {
        let setup = try fixtures()
        let descriptor = setup.adapters[0].0
        let recorder = FactoryRecorder()
        let completions = CompletionController()
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID,
                recorder: recorder,
                emitDuringStart: true,
                startEmissionCount: 2
            ))]
        )
        let contract = try negotiate(
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
        try await startTask.value
        #expect(await recorder.capturedCount == 2)
        let afterRevocation = AdapterCandidate(
            event: .processExited(status: nil),
            sourcePosition: try AdapterSourcePosition(sourceSequence: 3)
        )
        #expect(await recorder.ingest(afterRevocation) == .revoked)
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
                emitDuringStart: true,
                startHold: hold
            ))]
        )
        let contract = try negotiate(
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
                emitDuringStart: true,
                cancelBeforeReturning: true
            ))]
        )
        let contract = try negotiate(
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
                startFailure: AdapterSessionError.launchFailed(.transient),
                emitDuringStart: true
            ))]
        )
        let contract = try negotiate(
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
                emitDuringStart: true,
                cancelDuringStart: true
            ))]
        )
        let cancellationContract = try negotiate(
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
                id: descriptor.factoryID, recorder: failedRecorder, failure: AdapterSessionError.launchFailed(.permanent)
            ))]
        )
        let failedContract = try negotiate(failedRegistry, adapterID: descriptor.adapterID, profile: setup.profile)
        await #expect(throws: AdapterSessionError.launchFailed(.permanent)) {
            _ = try await failedRegistry.makeSession(contract: failedContract, resumeFrom: nil) { _ in .accepted }
        }
        #expect(await failedRecorder.ingest(try candidate(sequence: 1)) == .revoked)

        let mismatchRecorder = FactoryRecorder()
        let mismatch = try mismatchContract(from: setup)
        let mismatchRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(
                id: descriptor.factoryID, recorder: mismatchRecorder, returnedContract: mismatch
            ))]
        )
        let mismatchContract = try negotiate(mismatchRegistry, adapterID: descriptor.adapterID, profile: setup.profile)
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
            compiledAdapters: [(descriptor, CancellingFactory(id: descriptor.factoryID))]
        )
        let contract = try negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        await #expect(throws: CancellationError.self) {
            _ = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
        }
    }

    @Test func checkpointRequiresNewAcceptedReplayPosition() async throws {
        let setup = try fixtures(replay: .sourceCursor)
        let recorder = FactoryRecorder()
        let descriptor = setup.adapters[0].0
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(descriptor, RecordingFactory(id: descriptor.factoryID, recorder: recorder))]
        )
        let contract = try negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let dropped = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .droppedInvalid }
        try await dropped.start()
        await #expect(throws: AdapterSessionError.checkpointUnavailable) {
            _ = try await registry.makeCheckpoint(for: dropped)
        }
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .droppedInvalid)
        await #expect(throws: AdapterSessionError.checkpointUnavailable) {
            _ = try await registry.makeCheckpoint(for: dropped)
        }

        let revoked = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .revoked }
        try await revoked.start()
        #expect(await recorder.ingest(try candidate(sequence: 2), sinkIndex: 1) == .revoked)
        await #expect(throws: AdapterSessionError.checkpointUnavailable) {
            _ = try await registry.makeCheckpoint(for: revoked)
        }

        let accepted = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
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
            compiledAdapters: [(descriptor, RecordingFactory(id: descriptor.factoryID, recorder: recorder))]
        )
        let contract = try negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
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
            compiledAdapters: [(descriptor, RecordingFactory(id: descriptor.factoryID, recorder: recorder))]
        )
        let contract = try negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
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
            compiledAdapters: [(descriptor, RecordingFactory(id: descriptor.factoryID, recorder: recorder))]
        )
        let contract = try negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
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

    @Test func checkpointBindingsAndResumeBaselineFailClosed() async throws {
        let setup = try fixtures(twoAdapters: true, replay: .sourceCursor)
        let recorder = FactoryRecorder()
        let compiled = setup.adapters.map { ($0.0, RecordingFactory(id: $0.0.factoryID, recorder: recorder) as any AgentAdapterFactory) }
        let registry = try AgentAdapterRegistry(compiledPresentations: [setup.presentation], compiledAdapters: compiled)
        let first = try negotiate(registry, adapterID: compiled[0].0.adapterID, profile: setup.profile)
        let second = try negotiate(registry, adapterID: compiled[1].0.adapterID, profile: setup.profile)
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
            compiledAdapters: [(compiled[0].0, RecordingFactory(id: compiled[0].0.factoryID, recorder: foreignRecorder))]
        )
        let foreign = try negotiate(foreignRegistry, adapterID: compiled[0].0.adapterID, profile: setup.profile)
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
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation],
            compiledAdapters: [(expanded, RecordingFactory(id: descriptor.factoryID, recorder: recorder))]
        )
        let sourceContract = try negotiate(registry, adapterID: descriptor.adapterID, profile: setup.profile)
        let source = try await registry.makeSession(contract: sourceContract, resumeFrom: nil) { _ in .accepted }
        try await source.start()
        #expect(await recorder.ingest(try candidate(sequence: 1)) == .accepted)
        let checkpoint = try await registry.makeCheckpoint(for: source)

        let olderVersion = try registry.negotiate(
            adapterID: descriptor.adapterID,
            offeredProfiles: [setup.profile],
            offeredVersions: range(1, 0, 1, 3),
            policy: policy()
        )
        await #expect(throws: AdapterSessionError.checkpointMismatch) {
            _ = try await registry.makeSession(contract: olderVersion, resumeFrom: checkpoint) { _ in .accepted }
        }
        let alternateProfile = try registry.negotiate(
            adapterID: descriptor.adapterID,
            offeredProfiles: [alternate],
            offeredVersions: range(1, 0, 1, 4),
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

    @Test func policyIgnoresOfferOrder() throws {
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
        let completeRegistry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation], compiledAdapters: [(complete, setup.adapters[0].1)]
        )
        let offers = [setup.profile, local, richerLocal]
        let permutations = [offers, Array(offers.reversed()), [local, setup.profile, richerLocal]]
        let selections = try permutations.map { offered in
            try completeRegistry.negotiate(
                adapterID: descriptor.adapterID, offeredProfiles: Array(offered),
                offeredVersions: range(1, 0, 1, 4),
                policy: AdapterNegotiationPolicy(
                    allowedVersions: range(1, 0, 1, 4),
                    transportPreference: [.authenticatedLocalIPC, .ownedStandardIO],
                    acceptedAuthentication: [.ownedChildPipe, .authenticatedPeer]
                )
            )
        }
        #expect(selections.allSatisfy { $0 == selections[0] })
        #expect(selections[0].profile.transport == .authenticatedLocalIPC)
    }

    @Test func escalationFails() throws {
        let setup = try fixtures()
        let registry = try AgentAdapterRegistry(compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters)
        let excessive = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: lifecycleSignals(), evidence: [.tool]),
            delivery: AdapterDeliverySemantics(ordering: .ordered, minimumAuthentication: .ownedChildPipe)
        )
        #expect(throws: AdapterNegotiationError.offeredProfileExceedsMaximum) {
            _ = try negotiate(registry, adapterID: setup.adapters[0].0.adapterID, profile: excessive)
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
            return (AdapterDescriptor(
                adapterID: try AdapterID(validating: "pine:codex:\(suffix)"), agentID: agent, factoryID: factoryID,
                contractVersions: range(1, 0, 1, 4), maximumProfiles: [profile]
            ), RegistryTestFactory(id: factoryID))
        }
        return (presentation, twoAdapters ? [try pair("stdio"), try pair("rpc")] : [try pair("stdio")], profile)
    }

    private func mismatchContract(from setup: (
        presentation: AgentPresentationDescriptor,
        adapters: [(AdapterDescriptor, any AgentAdapterFactory)], profile: AdapterCapabilityProfile
    )) throws -> NegotiatedAdapterContract {
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [setup.presentation], compiledAdapters: setup.adapters
        )
        return try negotiate(registry, adapterID: setup.adapters[1].0.adapterID, profile: setup.profile)
    }

    private func negotiate(
        _ registry: AgentAdapterRegistry, adapterID: AdapterID, profile: AdapterCapabilityProfile
    ) throws -> NegotiatedAdapterContract {
        try registry.negotiate(
            adapterID: adapterID, offeredProfiles: [profile], offeredVersions: range(1, 1, 1, 9),
            policy: AdapterNegotiationPolicy(
                allowedVersions: range(1, 0, 1, 8), transportPreference: [.ownedStandardIO],
                acceptedAuthentication: [.ownedChildPipe]
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
    var emitDuringMake = false
    var failure: AdapterSessionError?
    var returnedContract: NegotiatedAdapterContract?
    var startFailure: AdapterSessionError?
    var emitDuringStart = false
    var startEmissionCount = 1
    var cancelDuringStart = false
    var cancelBeforeReturning = false
    var startHold: StartHold?
    func probe() async throws -> AdapterProbeResult { throw AdapterProbeError.unavailable(.permanent) }
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
    func probe() async throws -> AdapterProbeResult { throw CancellationError() }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        throw CancellationError()
    }
}

private actor StartHold {
    private var arrived = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrived = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilArrived() async {
        while !arrived { await Task.yield() }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll(keepingCapacity: false)
    }
}

private actor CompletionController {
    private var arrived = Set<UInt64>()
    private var released = Set<UInt64>()
    private var continuations: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    func wait(sequence: UInt64?) async {
        guard let sequence else { return }
        arrived.insert(sequence)
        guard !released.contains(sequence) else { return }
        await withCheckedContinuation { continuations[sequence, default: []].append($0) }
    }

    func waitUntilArrived(_ sequence: UInt64) async {
        while !arrived.contains(sequence) { await Task.yield() }
    }

    func release(_ sequence: UInt64) {
        released.insert(sequence)
        continuations.removeValue(forKey: sequence)?.forEach { $0.resume() }
    }
}
