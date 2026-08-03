import CryptoKit
import Foundation

nonisolated struct NegotiatedAdapterContract: Equatable, Sendable {
    fileprivate let registryID: UUID
    let agentID: AgentID
    let adapterID: AdapterID
    let factoryID: AdapterFactoryID
    let version: PineAdapterContractVersion
    let profile: AdapterCapabilityProfile
}

/// Discovery metadata and authority minted only after a registry-owned factory probe succeeds.
nonisolated struct AgentAdapterOffer: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    fileprivate let registryID: UUID
    fileprivate let agentID: AgentID
    fileprivate let adapterID: AdapterID
    fileprivate let factoryID: AdapterFactoryID
    fileprivate let probeResult: AdapterProbeResult

    var detectedVendorVersion: DetectedVendorVersion { probeResult.detectedVendorVersion }
    var detectedSchema: DetectedVendorVersion? { probeResult.detectedSchema }

    fileprivate init(
        registryID: UUID,
        agentID: AgentID,
        adapterID: AdapterID,
        factoryID: AdapterFactoryID,
        probeResult: AdapterProbeResult
    ) {
        self.registryID = registryID
        self.agentID = agentID
        self.adapterID = adapterID
        self.factoryID = factoryID
        self.probeResult = probeResult
    }

    var description: String { "<redacted:agent-adapter-offer>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: [
            "detectedVendorVersion": detectedVendorVersion.description,
            "detectedSchema": detectedSchema?.description as Any
        ])
    }
}

/// A registry-minted request. Factories can consume, but cannot construct, session authority.
nonisolated struct AgentAdapterSessionRequest: Sendable {
    let contract: NegotiatedAdapterContract
    let resumeFrom: AdapterResumeCheckpoint?
    let sink: any AgentEventSink

    fileprivate init(
        contract: NegotiatedAdapterContract,
        resumeFrom: AdapterResumeCheckpoint?,
        sink: any AgentEventSink
    ) {
        self.contract = contract
        self.resumeFrom = resumeFrom
        self.sink = sink
    }
}

// swiftlint:disable:next private_over_fileprivate
nonisolated fileprivate struct SourceNamespace: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let value = UUID()
    var description: String { "<redacted:source-namespace>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

// swiftlint:disable:next private_over_fileprivate
nonisolated fileprivate struct SourceAttempt: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let value = UUID()
    var description: String { "<redacted:source-attempt>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

/// A core-wrapped event whose source authority cannot be supplied by a producer.
nonisolated struct ValidatedAgentEvent: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    let candidate: AdapterCandidate
    fileprivate let namespace: SourceNamespace
    fileprivate let attempt: SourceAttempt

    func hasSameLogicalSource(as other: Self) -> Bool { namespace == other.namespace }
    func hasSameAttempt(as other: Self) -> Bool { attempt == other.attempt }
    func hasSameLogicalSource(as session: any AgentAdapterSession) -> Bool {
        (session as? CoreBoundAdapterSession)?.namespace == namespace
    }
    func hasSameAttempt(as session: any AgentAdapterSession) -> Bool {
        (session as? CoreBoundAdapterSession)?.attempt == attempt
    }

    var description: String { "<redacted:validated-agent-event>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

nonisolated struct AdapterResumeCheckpoint: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    fileprivate let registryID: UUID
    fileprivate let namespace: SourceNamespace
    fileprivate let sourceContract: NegotiatedAdapterContract
    fileprivate let gate: CheckpointConsumptionGate
    let resumePosition: AdapterResumePosition
    let lastSourceEvent: VendorReference
    let lastSourceSequence: UInt64

    fileprivate init(
        registryID: UUID,
        namespace: SourceNamespace,
        sourceContract: NegotiatedAdapterContract,
        resumePosition: AdapterResumePosition,
        lastSourceEvent: VendorReference,
        lastSourceSequence: UInt64
    ) {
        self.registryID = registryID
        self.namespace = namespace
        self.sourceContract = sourceContract
        gate = CheckpointConsumptionGate()
        self.resumePosition = resumePosition
        self.lastSourceEvent = lastSourceEvent
        self.lastSourceSequence = lastSourceSequence
    }

    var description: String { "<redacted:resume-checkpoint>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

// swiftlint:disable:next private_over_fileprivate
fileprivate actor CheckpointConsumptionGate {
    private var consumed = false
    func consume() -> Bool {
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

nonisolated private enum SourceAdmission: Sendable {
    case buffered
    case deliver
    case rejected(AdapterIngestOutcome)
}

nonisolated private enum SourceActivationResult: Equatable, Sendable {
    case committed, cancelled, rejected
}

private actor SourceSessionState {
    private enum Lifecycle { case ready, starting, flushing, active, retired }
    private var lifecycle = Lifecycle.ready
    private var highestAdmittedSequence: UInt64
    private var latestAcceptedPosition: AdapterSourcePosition?
    private var checkpointedSequence: UInt64?
    private var pendingCandidates: [AdapterCandidate] = []
    private var activationRemaining = 0
    private var inFlightCount = 0
    private let pendingLimit = AgentAdapterRegistry.startBufferLimit

    init(baseline: UInt64) {
        highestAdmittedSequence = baseline
    }

    func beginStart() -> Bool {
        guard lifecycle == .ready else { return false }
        lifecycle = .starting
        return true
    }

    func canAcceptPayload() -> Bool {
        lifecycle == .starting || lifecycle == .flushing || lifecycle == .active
    }

    func admit(_ candidate: AdapterCandidate) -> SourceAdmission {
        switch lifecycle {
        case .ready, .retired:
            return .rejected(.revoked)
        case .flushing:
            return .rejected(.droppedInvalid)
        case .starting:
            guard pendingCandidates.count < pendingLimit else {
                return .rejected(.droppedInvalid)
            }
        case .active:
            break
        }
        if let sequence = candidate.sourcePosition?.sourceSequence {
            guard sequence > highestAdmittedSequence else {
                return .rejected(.droppedInvalid)
            }
            highestAdmittedSequence = sequence
        }
        if lifecycle == .starting {
            pendingCandidates.append(candidate)
            return .buffered
        }
        inFlightCount += 1
        return .deliver
    }

    func commitActivation() -> SourceActivationResult {
        guard lifecycle == .starting else { return .rejected }
        guard !Task.isCancelled else {
            lifecycle = .retired
            pendingCandidates.removeAll(keepingCapacity: false)
            activationRemaining = 0
            return .cancelled
        }
        activationRemaining = pendingCandidates.count
        lifecycle = .flushing
        return .committed
    }

    func nextBuffered() -> AdapterCandidate? {
        guard lifecycle == .flushing else { return nil }
        guard activationRemaining > 0 else {
            lifecycle = .active
            return nil
        }
        guard !pendingCandidates.isEmpty else {
            activationRemaining = 0
            lifecycle = .retired
            return nil
        }
        activationRemaining -= 1
        inFlightCount += 1
        return pendingCandidates.removeFirst()
    }

    func complete(
        _ candidate: AdapterCandidate,
        outcome: AdapterIngestOutcome
    ) -> AdapterIngestOutcome {
        guard inFlightCount > 0 else { return .revoked }
        inFlightCount -= 1
        guard lifecycle == .active || lifecycle == .flushing else { return .revoked }
        if outcome == .revoked {
            lifecycle = .retired
            pendingCandidates.removeAll(keepingCapacity: false)
            activationRemaining = 0
            return .revoked
        }
        if outcome == .accepted, let position = candidate.sourcePosition,
           let sequence = position.sourceSequence,
           sequence > (latestAcceptedPosition?.sourceSequence ?? 0) {
            latestAcceptedPosition = position
        }
        return outcome
    }

    func checkpointPosition() -> AdapterSourcePosition? {
        guard lifecycle == .active, inFlightCount == 0,
              pendingCandidates.isEmpty,
              let position = latestAcceptedPosition,
              let sequence = position.sourceSequence,
              sequence > (checkpointedSequence ?? 0) else { return nil }
        checkpointedSequence = sequence
        lifecycle = .retired
        return position
    }

    func revoke() {
        lifecycle = .retired
        pendingCandidates.removeAll(keepingCapacity: false)
        activationRemaining = 0
    }
}

private actor ValidatingAgentEventSink: AgentEventSink {
    typealias Downstream = @Sendable (ValidatedAgentEvent) async -> AdapterIngestOutcome
    private let contract: NegotiatedAdapterContract
    private let namespace: SourceNamespace
    private let attempt: SourceAttempt
    private let state: SourceSessionState
    private let downstream: Downstream

    init(
        contract: NegotiatedAdapterContract,
        namespace: SourceNamespace,
        attempt: SourceAttempt,
        state: SourceSessionState,
        downstream: @escaping Downstream
    ) {
        self.contract = contract
        self.namespace = namespace
        self.attempt = attempt
        self.state = state
        self.downstream = downstream
    }

    func ingest(_ candidate: AdapterCandidate) async -> AdapterIngestOutcome {
        guard !Task.isCancelled else { return .revoked }
        guard await state.canAcceptPayload() else { return .revoked }
        do { try candidate.validate(against: contract) } catch { return .droppedInvalid }
        switch await state.admit(candidate) {
        case .buffered:
            return .bufferedUntilActivation
        case .rejected(let outcome):
            return outcome
        case .deliver:
            return await deliver(candidate)
        }
    }

    func activate() async -> SourceActivationResult {
        let commit = await state.commitActivation()
        guard commit == .committed else { return commit }
        while let candidate = await state.nextBuffered() {
            if Task.isCancelled {
                await state.revoke()
                break
            }
            if await deliver(candidate) == .revoked { break }
            if Task.isCancelled {
                await state.revoke()
                break
            }
        }
        if Task.isCancelled { await state.revoke() }
        return .committed
    }

    private func deliver(_ candidate: AdapterCandidate) async -> AdapterIngestOutcome {
        let outcome = await downstream(ValidatedAgentEvent(
            candidate: candidate,
            namespace: namespace,
            attempt: attempt
        ))
        let resolved = outcome == .bufferedUntilActivation ? .revoked : outcome
        return await state.complete(candidate, outcome: resolved)
    }
}

nonisolated private struct CoreBoundAdapterSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    let registryID: UUID
    let namespace: SourceNamespace
    let attempt: SourceAttempt
    let state: SourceSessionState
    let sink: ValidatingAgentEventSink
    let underlying: any AgentAdapterSession

    func start() async throws {
        guard await state.beginStart() else {
            throw AdapterSessionError.invalidLifecycle
        }
        do { try await underlying.start() } catch {
            await state.revoke()
            throw error
        }
        switch await sink.activate() {
        case .committed:
            break
        case .cancelled:
            throw CancellationError()
        case .rejected:
            throw AdapterSessionError.invalidLifecycle
        }
    }

    func stop(deadline: ContinuousClock.Instant) async {
        await state.revoke()
        await underlying.stop(deadline: deadline)
    }
}

nonisolated enum AdapterRegistrationError: Error, Equatable, Sendable {
    case duplicateAgent, duplicateAdapter, duplicateFactory, duplicateAlias, aliasCollision
    case invalidVersionRange, emptyProfiles, duplicateProfile, descriptorMismatch, unknownFactory, tooManyEntries
    case invalidBuiltInPresentation
}

nonisolated enum AdapterNegotiationError: Error, Equatable, Sendable {
    case offerMismatch, invalidPolicyRange, noCommonVersion, noCommonProfile, offeredProfileExceedsMaximum
}

nonisolated struct AdapterNegotiationPolicy: Sendable {
    let allowedVersions: PineAdapterContractVersionRange
    let transportPreference: [AdapterTransport]
    let acceptedAuthentication: Set<CoreAuthenticationRequirement>
}

nonisolated struct AgentAdapterRegistry: Sendable {
    static let startBufferLimit = 64
    typealias Downstream = @Sendable (ValidatedAgentEvent) async -> AdapterIngestOutcome
    private struct Key: Hashable { let agent: AgentID; let adapter: AdapterID; let factory: AdapterFactoryID }
    private let presentations: [AgentID: AgentPresentationDescriptor]
    private let adapters: [AdapterID: (AdapterDescriptor, any AgentAdapterFactory)]
    private let registryID: UUID

    init(
        compiledPresentations: [AgentPresentationDescriptor],
        compiledAdapters: [(AdapterDescriptor, any AgentAdapterFactory)]
    ) throws {
        guard compiledPresentations.count <= 128, compiledAdapters.count <= 128 else {
            throw AdapterRegistrationError.tooManyEntries
        }
        var presentationMap: [AgentID: AgentPresentationDescriptor] = [:]
        var aliases = Set<ExecutableAlias>()
        for presentation in compiledPresentations {
            try AgentPresentationCatalog.validateBuiltIn(presentation)
            try AgentPresentationCatalog.validateReservedNames(presentation)
            guard presentationMap.updateValue(presentation, forKey: presentation.agentID) == nil else {
                throw AdapterRegistrationError.duplicateAgent
            }
            guard aliases.isDisjoint(with: presentation.executableAliases) else {
                throw AdapterRegistrationError.aliasCollision
            }
            aliases.formUnion(presentation.executableAliases)
        }
        var adapterMap: [AdapterID: (AdapterDescriptor, any AgentAdapterFactory)] = [:]
        var keys = Set<Key>(), factories = Set<AdapterFactoryID>()
        for (descriptor, factory) in compiledAdapters {
            guard presentationMap[descriptor.agentID] != nil else { throw AdapterRegistrationError.descriptorMismatch }
            guard descriptor.factoryID == factory.id else { throw AdapterRegistrationError.descriptorMismatch }
            guard descriptor.contractVersions.isValid else { throw AdapterRegistrationError.invalidVersionRange }
            guard !descriptor.maximumProfiles.isEmpty else { throw AdapterRegistrationError.emptyProfiles }
            guard descriptor.maximumProfiles.count <= 16 else { throw AdapterRegistrationError.tooManyEntries }
            guard Set(descriptor.maximumProfiles).count == descriptor.maximumProfiles.count else {
                throw AdapterRegistrationError.duplicateProfile
            }
            let key = Key(agent: descriptor.agentID, adapter: descriptor.adapterID, factory: descriptor.factoryID)
            guard keys.insert(key).inserted else { throw AdapterRegistrationError.descriptorMismatch }
            guard factories.insert(descriptor.factoryID).inserted else { throw AdapterRegistrationError.duplicateFactory }
            guard adapterMap.updateValue((descriptor, factory), forKey: descriptor.adapterID) == nil else {
                throw AdapterRegistrationError.duplicateAdapter
            }
        }
        presentations = presentationMap
        adapters = adapterMap
        registryID = UUID()
    }

    private func factory(for contract: NegotiatedAdapterContract) throws -> any AgentAdapterFactory {
        guard contract.registryID == registryID, let pair = adapters[contract.adapterID],
              pair.0.agentID == contract.agentID, pair.0.factoryID == contract.factoryID,
              pair.0.contractVersions.contains(contract.version),
              pair.0.maximumProfiles.contains(where: { contract.profile.isSubset(of: $0) }) else {
            throw AdapterSessionError.contractMismatch
        }
        return pair.1
    }

    func makeSession(
        contract: NegotiatedAdapterContract,
        resumeFrom checkpoint: AdapterResumeCheckpoint?,
        downstream: @escaping Downstream
    ) async throws -> any AgentAdapterSession {
        let resolved = try factory(for: contract)
        guard checkpoint == nil || contract.profile.replay == .sourceCursor else {
            throw AdapterSessionError.checkpointNotSupported
        }
        if let checkpoint {
            guard checkpoint.registryID == registryID,
                  checkpoint.sourceContract == contract else {
                throw AdapterSessionError.checkpointMismatch
            }
            guard await checkpoint.gate.consume() else {
                throw AdapterSessionError.checkpointAlreadyConsumed
            }
        }
        let namespace = checkpoint?.namespace ?? SourceNamespace()
        let attempt = SourceAttempt()
        let state = SourceSessionState(baseline: checkpoint?.lastSourceSequence ?? 0)
        let sink = ValidatingAgentEventSink(
            contract: contract,
            namespace: namespace,
            attempt: attempt,
            state: state,
            downstream: downstream
        )
        let request = AgentAdapterSessionRequest(contract: contract, resumeFrom: checkpoint, sink: sink)
        do {
            let session = try await resolved.makeSession(request)
            guard session.contract == contract else {
                await state.revoke()
                throw AdapterSessionError.contractMismatch
            }
            return CoreBoundAdapterSession(
                contract: contract,
                registryID: registryID,
                namespace: namespace,
                attempt: attempt,
                state: state,
                sink: sink,
                underlying: session
            )
        } catch {
            await state.revoke()
            throw error
        }
    }

    func makeCheckpoint(for sourceSession: any AgentAdapterSession) async throws -> AdapterResumeCheckpoint {
        guard let source = sourceSession as? CoreBoundAdapterSession,
              source.registryID == registryID else { throw AdapterSessionError.checkpointMismatch }
        guard source.contract.profile.replay == .sourceCursor else {
            throw AdapterSessionError.checkpointNotSupported
        }
        guard let position = await source.state.checkpointPosition(),
              let resumePosition = position.resumePosition,
              let lastSourceEvent = position.sourceEvent,
              let lastSourceSequence = position.sourceSequence else {
            throw AdapterSessionError.checkpointUnavailable
        }
        return AdapterResumeCheckpoint(
            registryID: registryID,
            namespace: source.namespace,
            sourceContract: source.contract,
            resumePosition: resumePosition,
            lastSourceEvent: lastSourceEvent,
            lastSourceSequence: lastSourceSequence
        )
    }

    func probe(adapterID: AdapterID) async throws -> AgentAdapterOffer {
        guard let pair = adapters[adapterID] else { throw AdapterProbeError.unknownAdapter }
        let result = try await pair.1.probe()
        return AgentAdapterOffer(
            registryID: registryID,
            agentID: pair.0.agentID,
            adapterID: pair.0.adapterID,
            factoryID: pair.0.factoryID,
            probeResult: result
        )
    }

    func negotiate(
        offer: AgentAdapterOffer,
        policy: AdapterNegotiationPolicy
    ) throws -> NegotiatedAdapterContract {
        guard offer.registryID == registryID,
              let pair = adapters[offer.adapterID],
              pair.0.agentID == offer.agentID,
              pair.0.adapterID == offer.adapterID,
              pair.0.factoryID == offer.factoryID else {
            throw AdapterNegotiationError.offerMismatch
        }
        guard policy.allowedVersions.isValid else { throw AdapterNegotiationError.invalidPolicyRange }
        guard !policy.transportPreference.isEmpty,
              Set(policy.transportPreference).count == policy.transportPreference.count else {
            throw AdapterNegotiationError.invalidPolicyRange
        }
        let offeredProfiles = offer.probeResult.offeredProfiles
        let offeredVersions = offer.probeResult.offeredContractVersions
        let lower = max(max(pair.0.contractVersions.minimum, offeredVersions.minimum), policy.allowedVersions.minimum)
        let upper = min(min(pair.0.contractVersions.maximum, offeredVersions.maximum), policy.allowedVersions.maximum)
        guard lower <= upper else { throw AdapterNegotiationError.noCommonVersion }
        guard offeredProfiles.allSatisfy({ offered in
            pair.0.maximumProfiles.contains(where: { offered.isSubset(of: $0) })
        }) else { throw AdapterNegotiationError.offeredProfileExceedsMaximum }
        let eligible = offeredProfiles.filter { policy.acceptedAuthentication.contains($0.minimumAuthentication) }
        let selected = policy.transportPreference.lazy.compactMap { transport in
            eligible.filter { $0.transport == transport }
                .sorted { $0.deterministicWireValues.lexicographicallyPrecedes($1.deterministicWireValues) }.first
        }.first
        guard let selected else { throw AdapterNegotiationError.noCommonProfile }
        return NegotiatedAdapterContract(
            registryID: registryID, agentID: pair.0.agentID, adapterID: offer.adapterID, factoryID: pair.0.factoryID,
            version: upper, profile: selected
        )
    }

    func presentation(for id: AgentID) -> AgentPresentationDescriptor? { presentations[id] }

    func validatedUserPresentations(
        _ registrations: [UserAgentPresentationRegistration]
    ) throws -> [AgentPresentationDescriptor] {
        guard registrations.count <= 128 else { throw AdapterRegistrationError.tooManyEntries }
        var ids = Set(presentations.keys)
        var aliases = Set<ExecutableAlias>()
        for presentation in presentations.values { aliases.formUnion(presentation.executableAliases) }
        return try registrations.map { registration in
            let presentation = try registration.normalized()
            try AgentPresentationCatalog.validateReservedNames(presentation)
            guard ids.insert(presentation.agentID).inserted else { throw AdapterRegistrationError.duplicateAgent }
            guard aliases.isDisjoint(with: presentation.executableAliases) else {
                throw AdapterRegistrationError.aliasCollision
            }
            aliases.formUnion(presentation.executableAliases)
            return presentation
        }
    }
}

nonisolated enum AgentPresentationCatalog {
    private static let builtIns: [String: (String, AgentPresentationStyle, Set<String>)] = [
        "claudeCode": ("Claude Code", .claude, ["claude"]),
        "codex": ("Codex", .codex, ["codex"]),
        "aider": ("Aider", .aider, ["aider"]),
        "copilot": ("Copilot", .copilot, ["github-copilot-cli", "copilot"]),
        "pi": ("Pi", .pi, ["pi"])
    ]

    static func validateBuiltIn(_ descriptor: AgentPresentationDescriptor) throws {
        guard let expected = builtIns[descriptor.agentID.value] else { return }
        let aliases = Set(descriptor.executableAliases.map(\.value))
        guard descriptor.displayName == expected.0, descriptor.style == expected.1,
              aliases == expected.2 else { throw AdapterRegistrationError.invalidBuiltInPresentation }
    }

    static func validateReservedNames(_ descriptor: AgentPresentationDescriptor) throws {
        let reservedAliases = Set(builtIns.values.flatMap { $0.2 })
        guard builtIns[descriptor.agentID.value] != nil
                || Set(descriptor.executableAliases.map(\.value)).isDisjoint(with: reservedAliases) else {
            throw AdapterRegistrationError.aliasCollision
        }
    }

    static func builtIn(stableIdentifier: String) throws -> AgentPresentationDescriptor? {
        guard let record = builtIns[stableIdentifier] else { return nil }
        return try AgentPresentationDescriptor(
            agentID: AgentID(migratingLegacyStableIdentifier: stableIdentifier),
            displayName: record.0,
            executableAliases: Set(try record.2.map(ExecutableAlias.init(validating:))),
            style: record.1
        )
    }
}

nonisolated struct LegacyAgentMigration: Sendable {
    let originalStableIdentifier: String
    let canonicalAgentID: AgentID
    let presentation: AgentPresentationDescriptor
}

nonisolated enum LegacyMigrationError: Error, Equatable, Sendable {
    case malformedIdentifier
    case duplicateOriginalIdentifier
    case canonicalCollision
}

nonisolated struct LegacyAgentMigrationCatalog: Sendable {
    private let byOriginal: [String: LegacyAgentMigration]
    private let byCanonical: [AgentID: LegacyAgentMigration]

    init(stableIdentifiers: [String]) throws {
        guard stableIdentifiers.count <= 128 else { throw LegacyMigrationError.malformedIdentifier }
        var originals: [String: LegacyAgentMigration] = [:]
        var migrations: [LegacyAgentMigration] = []
        for stableIdentifier in stableIdentifiers {
            guard originals[stableIdentifier] == nil else { throw LegacyMigrationError.duplicateOriginalIdentifier }
            let migration = try Self.migration(for: stableIdentifier)
            originals[stableIdentifier] = migration
            migrations.append(migration)
        }
        try Self.validateCanonicalUniqueness(migrations.map(\.canonicalAgentID))
        var canonicals: [AgentID: LegacyAgentMigration] = [:]
        for migration in migrations { canonicals[migration.canonicalAgentID] = migration }
        byOriginal = originals
        byCanonical = canonicals
    }

    static func validateCanonicalUniqueness(_ identifiers: [AgentID]) throws {
        guard Set(identifiers).count == identifiers.count else { throw LegacyMigrationError.canonicalCollision }
    }

    func lookup(stableIdentifier: String) -> LegacyAgentMigration? { byOriginal[stableIdentifier] }
    func lookup(agentID: AgentID) -> LegacyAgentMigration? { byCanonical[agentID] }

    private static func migration(for stableIdentifier: String) throws -> LegacyAgentMigration {
        guard !stableIdentifier.isEmpty, stableIdentifier.utf8.count <= 256,
              stableIdentifier == stableIdentifier.precomposedStringWithCanonicalMapping,
              stableIdentifier.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LegacyMigrationError.malformedIdentifier
        }
        if let presentation = try AgentPresentationCatalog.builtIn(stableIdentifier: stableIdentifier) {
            return LegacyAgentMigration(
                originalStableIdentifier: stableIdentifier,
                canonicalAgentID: presentation.agentID,
                presentation: presentation
            )
        }
        guard stableIdentifier.hasPrefix("generic:") else { throw LegacyMigrationError.malformedIdentifier }
        let display = String(stableIdentifier.dropFirst("generic:".count))
        let safeDisplay: String
        do { safeDisplay = try AdapterIdentifierValidation.displayText(display) } catch {
            throw LegacyMigrationError.malformedIdentifier
        }
        let digest = sha256(stableIdentifier)
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw LegacyMigrationError.malformedIdentifier
        }
        do {
            let agentID = try AgentID(validating: "generic:\(digest)")
            let presentation = try AgentPresentationDescriptor(
                agentID: agentID, displayName: safeDisplay, executableAliases: [], style: .generic
            )
            return LegacyAgentMigration(
                originalStableIdentifier: stableIdentifier,
                canonicalAgentID: agentID,
                presentation: presentation
            )
        } catch { throw LegacyMigrationError.malformedIdentifier }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
