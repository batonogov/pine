import CryptoKit
import Foundation
import Synchronization

nonisolated struct NegotiatedAdapterContract: Equatable, Sendable {
    fileprivate let registryID: UUID
    fileprivate let probeGeneration: UUID
    fileprivate let freshSessionGate: OneShotAuthorityGate
    let agentID: AgentID
    let adapterID: AdapterID
    let factoryID: AdapterFactoryID
    let version: PineAdapterContractVersion
    let profile: AdapterCapabilityProfile

    fileprivate init(
        registryID: UUID,
        probeGeneration: UUID,
        agentID: AgentID,
        adapterID: AdapterID,
        factoryID: AdapterFactoryID,
        version: PineAdapterContractVersion,
        profile: AdapterCapabilityProfile
    ) {
        self.registryID = registryID
        self.probeGeneration = probeGeneration
        freshSessionGate = OneShotAuthorityGate()
        self.agentID = agentID
        self.adapterID = adapterID
        self.factoryID = factoryID
        self.version = version
        self.profile = profile
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.registryID == rhs.registryID
            && lhs.probeGeneration == rhs.probeGeneration
            && lhs.agentID == rhs.agentID
            && lhs.adapterID == rhs.adapterID
            && lhs.factoryID == rhs.factoryID
            && lhs.version == rhs.version
            && lhs.profile == rhs.profile
    }
}

/// Discovery metadata and authority minted only after a registry-owned factory probe succeeds.
nonisolated struct AgentAdapterOffer: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    fileprivate let registryID: UUID
    fileprivate let agentID: AgentID
    fileprivate let adapterID: AdapterID
    fileprivate let factoryID: AdapterFactoryID
    fileprivate let probeResult: AdapterProbeResult
    fileprivate let probeGeneration: UUID
    fileprivate let gate: OneShotAuthorityGate

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
        probeGeneration = UUID()
        gate = OneShotAuthorityGate()
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
    fileprivate let gate: OneShotAuthorityGate
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
        gate = OneShotAuthorityGate()
        self.resumePosition = resumePosition
        self.lastSourceEvent = lastSourceEvent
        self.lastSourceSequence = lastSourceSequence
    }

    var description: String { "<redacted:resume-checkpoint>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

// swiftlint:disable:next private_over_fileprivate
nonisolated fileprivate final class OneShotAuthorityGate: Sendable {
    private enum State: Equatable { case available, reserved(UUID), consumed }
    private let state = Mutex(State.available)

    func consume() -> Bool {
        state.withLock {
            guard $0 == .available else { return false }
            $0 = .consumed
            return true
        }
    }

    func reserve(_ reservationID: UUID) -> Bool {
        state.withLock {
            guard $0 == .available else { return false }
            $0 = .reserved(reservationID)
            return true
        }
    }

    func commit(_ reservationID: UUID) -> Bool {
        state.withLock {
            guard $0 == .reserved(reservationID) else { return false }
            $0 = .consumed
            return true
        }
    }

    @discardableResult
    func rollback(_ reservationID: UUID) -> Bool {
        state.withLock {
            guard $0 == .reserved(reservationID) else { return false }
            $0 = .available
            return true
        }
    }
}

nonisolated private final class OneShotAuthorityReservation: Sendable {
    private let gate: OneShotAuthorityGate
    private let reservationID: UUID

    init(gate: OneShotAuthorityGate, reservationID: UUID) {
        self.gate = gate
        self.reservationID = reservationID
    }

    @discardableResult
    func commit() -> Bool {
        gate.commit(reservationID)
    }

    @discardableResult
    func rollback() -> Bool {
        gate.rollback(reservationID)
    }

    deinit {
        gate.rollback(reservationID)
    }
}

nonisolated private final class OneShotAuthorityLease: Sendable {
    private let reservation: OneShotAuthorityReservation

    init(reservation: OneShotAuthorityReservation) {
        self.reservation = reservation
    }

    deinit {
        reservation.rollback()
    }
}

nonisolated final class AsyncContinuationGate: Sendable {
    private enum State: Sendable {
        case pendingRegistration
        case registered(CheckedContinuation<Void, Never>)
        case resolved
    }

    private let state = Mutex(State.pendingRegistration)

    var isResolved: Bool {
        state.withLock {
            if case .resolved = $0 { return true }
            return false
        }
    }

    var hasRegisteredWaiter: Bool {
        state.withLock {
            if case .registered = $0 { return true }
            return false
        }
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(continuation)
            }
        } onCancel: {
            resolve()
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeImmediately = state.withLock {
            switch $0 {
            case .pendingRegistration:
                $0 = .registered(continuation)
                return false
            case .registered, .resolved:
                return true
            }
        }
        if resumeImmediately { continuation.resume() }
    }

    func resolve() {
        let continuation: CheckedContinuation<Void, Never>? = state.withLock {
            switch $0 {
            case .pendingRegistration:
                $0 = .resolved
                return nil
            case .registered(let continuation):
                $0 = .resolved
                return continuation
            case .resolved:
                return nil
            }
        }
        continuation?.resume()
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

nonisolated private enum SourceStopDirective: Sendable {
    case start(BoundedAdapterStop)
    case wait(BoundedAdapterStop)
}

private actor SourceSessionState {
    private enum Lifecycle { case ready, starting, flushing, active, closing, retired }
    private var lifecycle = Lifecycle.ready
    private var highestAdmittedSequence: UInt64
    private var latestAcceptedPosition: AdapterSourcePosition?
    private var checkpointedSequence: UInt64?
    private var pendingCheckpointPosition: AdapterSourcePosition?
    private var pendingCandidates: [AdapterCandidate] = []
    private var activationRemaining = 0
    private var inFlightCount = 0
    private var drainWaiters: [UUID: AsyncContinuationGate] = [:]
    private var stopCompletion: BoundedAdapterStop?
    private let authority: OneShotAuthorityReservation
    private let pendingLimit = AgentAdapterRegistry.startBufferLimit

    init(baseline: UInt64, authority: OneShotAuthorityReservation) {
        highestAdmittedSequence = baseline
        self.authority = authority
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
        case .ready, .closing, .retired:
            return .rejected(.revoked)
        case .flushing:
            return .rejected(.retryAfterActivation)
        case .starting:
            guard pendingCandidates.count < pendingLimit else {
                return .rejected(.retryAfterActivation)
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
            authority.rollback()
            return .cancelled
        }
        guard authority.commit() else {
            lifecycle = .retired
            pendingCandidates.removeAll(keepingCapacity: false)
            activationRemaining = 0
            return .rejected
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

    func finishActivation() -> SourceActivationResult {
        if Task.isCancelled {
            lifecycle = .retired
            pendingCandidates.removeAll(keepingCapacity: false)
            activationRemaining = 0
            return .cancelled
        }
        return lifecycle == .active ? .committed : .rejected
    }

    func complete(
        _ candidate: AdapterCandidate,
        outcome: AdapterIngestOutcome
    ) -> AdapterIngestOutcome {
        guard inFlightCount > 0 else { return .revoked }
        inFlightCount -= 1
        resumeDrainWaitersIfNeeded()
        if outcome == .revoked {
            lifecycle = .retired
            pendingCandidates.removeAll(keepingCapacity: false)
            activationRemaining = 0
            return .revoked
        }
        if outcome == .accepted, let position = candidate.sourcePosition,
           let sequence = position.sourceSequence,
           lifecycle == .active || lifecycle == .flushing || lifecycle == .closing,
           sequence > (latestAcceptedPosition?.sourceSequence ?? 0) {
            latestAcceptedPosition = position
        }
        return outcome
    }

    func checkpointPosition() -> AdapterSourcePosition? {
        if let pendingCheckpointPosition { return pendingCheckpointPosition }
        guard lifecycle == .active, inFlightCount == 0,
              pendingCandidates.isEmpty,
              let position = latestAcceptedPosition,
              let sequence = position.sourceSequence,
              sequence > (checkpointedSequence ?? 0) else { return nil }
        checkpointedSequence = sequence
        pendingCheckpointPosition = position
        lifecycle = .retired
        return position
    }

    func finalizeCheckpoint() -> Bool {
        guard pendingCheckpointPosition != nil else { return false }
        pendingCheckpointPosition = nil
        return true
    }

    func failStart() {
        if lifecycle == .ready || lifecycle == .starting {
            authority.rollback()
        }
        lifecycle = .retired
        pendingCandidates.removeAll(keepingCapacity: false)
        activationRemaining = 0
        resumeDrainWaitersIfNeeded()
    }

    func beginStop() -> SourceStopDirective {
        if let stopCompletion { return .wait(stopCompletion) }
        let completion = BoundedAdapterStop()
        stopCompletion = completion
        if lifecycle == .ready || lifecycle == .starting {
            authority.rollback()
        }
        if lifecycle != .retired { lifecycle = .closing }
        pendingCandidates.removeAll(keepingCapacity: false)
        activationRemaining = 0
        resumeDrainWaitersIfNeeded()
        return .start(completion)
    }

    func waitUntilDrained() async {
        guard inFlightCount > 0, !Task.isCancelled else { return }
        let waiterID = UUID()
        let waiter = AsyncContinuationGate()
        drainWaiters[waiterID] = waiter
        await waiter.wait()
        drainWaiters.removeValue(forKey: waiterID)
    }

    func revoke() {
        lifecycle = .retired
        pendingCandidates.removeAll(keepingCapacity: false)
        activationRemaining = 0
        resumeDrainWaitersIfNeeded()
    }

    private func resumeDrainWaitersIfNeeded() {
        guard inFlightCount == 0 else { return }
        let retained = Array(drainWaiters.values)
        drainWaiters.removeAll(keepingCapacity: false)
        retained.forEach { $0.resolve() }
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
        return await state.finishActivation()
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

private actor BoundedAdapterStop {
    private var completed = false
    private var waiters: [UUID: AsyncContinuationGate] = [:]

    var isCompleted: Bool { completed }

    func wait() async {
        guard !completed, !Task.isCancelled else { return }
        let waiterID = UUID()
        let waiter = AsyncContinuationGate()
        waiters[waiterID] = waiter
        await waiter.wait()
        waiters.removeValue(forKey: waiterID)
    }

    func complete() {
        guard !completed else { return }
        completed = true
        let retained = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        retained.forEach { $0.resolve() }
    }
}

nonisolated struct AdapterDeadlineSleeper: Sendable {
    nonisolated static let live = AdapterDeadlineSleeper { deadline in
        try? await ContinuousClock().sleep(until: deadline)
    }

    private let operation: @Sendable (ContinuousClock.Instant) async -> Void

    init(operation: @escaping @Sendable (ContinuousClock.Instant) async -> Void) {
        self.operation = operation
    }

    func sleep(until deadline: ContinuousClock.Instant) async {
        await operation(deadline)
    }
}

nonisolated private final class AsyncBooleanDecision: Sendable {
    private let value = Mutex<Bool?>(nil)
    private let completion = AsyncContinuationGate()

    func resolve(_ proposed: Bool) {
        let accepted = value.withLock {
            guard $0 == nil else { return false }
            $0 = proposed
            return true
        }
        if accepted { completion.resolve() }
    }

    func wait() async -> Bool {
        await completion.wait()
        return value.withLock { $0 ?? false }
    }
}

nonisolated private struct AdapterCleanupTicket: Sendable {
    let operationID: UUID
    let completion: BoundedAdapterStop
}

nonisolated final class AdapterCleanupCapacity: Sendable {
    nonisolated static let shared = AdapterCleanupCapacity(limit: 1_024)
    private let limit: Int
    private let reservations = Mutex(Set<UUID>())

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    fileprivate func reserve() -> AdapterCleanupPermit? {
        let reservationID = UUID()
        let accepted = reservations.withLock {
            guard $0.count < limit else { return false }
            $0.insert(reservationID)
            return true
        }
        guard accepted else { return nil }
        return AdapterCleanupPermit(
            capacity: self,
            reservationID: reservationID
        )
    }

    fileprivate func release(_ reservationID: UUID) {
        _ = reservations.withLock { $0.remove(reservationID) }
    }

    var reservedCount: Int {
        reservations.withLock { $0.count }
    }
}

nonisolated private final class AdapterCleanupPermit: Sendable {
    private enum State: Sendable {
        case reserved
        case submitted(AdapterCleanupTicket)
        case released
    }

    let reservationID: UUID
    private let capacity: AdapterCleanupCapacity
    private let state = Mutex(State.reserved)

    init(capacity: AdapterCleanupCapacity, reservationID: UUID) {
        self.capacity = capacity
        self.reservationID = reservationID
    }

    func beginSubmission(_ proposed: AdapterCleanupTicket) -> (AdapterCleanupTicket, Bool) {
        state.withLock {
            switch $0 {
            case .reserved:
                $0 = .submitted(proposed)
                return (proposed, true)
            case .submitted(let existing):
                return (existing, false)
            case .released:
                return (proposed, false)
            }
        }
    }

    func release() {
        let shouldRelease = state.withLock {
            guard case .released = $0 else {
                $0 = .released
                return true
            }
            return false
        }
        if shouldRelease { capacity.release(reservationID) }
    }

    deinit {
        let shouldRelease = state.withLock {
            guard case .reserved = $0 else { return false }
            $0 = .released
            return true
        }
        if shouldRelease { capacity.release(reservationID) }
    }
}

private actor AdapterStopCountdown {
    private var remaining: Int
    private let completion: BoundedAdapterStop

    init(remaining: Int, completion: BoundedAdapterStop) {
        self.remaining = remaining
        self.completion = completion
    }

    func arrive() async {
        guard remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 { await completion.complete() }
    }
}

private actor AdapterCleanupSupervisor {
    nonisolated static let shared = AdapterCleanupSupervisor()
    private var operations: [UUID: Task<Void, Never>] = [:]

    func submit(
        _ session: any AgentAdapterSession,
        permit: AdapterCleanupPermit,
        deadline: ContinuousClock.Instant
    ) -> AdapterCleanupTicket {
        let proposed = AdapterCleanupTicket(
            operationID: permit.reservationID,
            completion: BoundedAdapterStop()
        )
        let (ticket, isNew) = permit.beginSubmission(proposed)
        guard isNew else { return ticket }
        let supervisor = self
        let task = Task.detached {
            await session.stop(deadline: deadline)
            permit.release()
            await ticket.completion.complete()
            await supervisor.finished(ticket.operationID)
        }
        operations[ticket.operationID] = task
        return ticket
    }

    func cancel(_ ticket: AdapterCleanupTicket) {
        operations[ticket.operationID]?.cancel()
    }

    private func finished(_ operationID: UUID) {
        operations.removeValue(forKey: operationID)
    }
}

nonisolated private final class CoreBoundSessionLifetime: Sendable {
    nonisolated static let cleanupGrace = Duration.seconds(5)
    let state: SourceSessionState
    let underlying: any AgentAdapterSession
    let cleanupPermit: AdapterCleanupPermit
    private let deadlineSleeper: AdapterDeadlineSleeper
    private let confirmedCleanup = BoundedAdapterStop()

    init(
        state: SourceSessionState,
        underlying: any AgentAdapterSession,
        cleanupPermit: AdapterCleanupPermit,
        deadlineSleeper: AdapterDeadlineSleeper
    ) {
        self.state = state
        self.underlying = underlying
        self.cleanupPermit = cleanupPermit
        self.deadlineSleeper = deadlineSleeper
    }

    func requestStop(deadline: ContinuousClock.Instant) async -> BoundedAdapterStop {
        await Self.prepareStop(
            state: state,
            underlying: underlying,
            cleanupPermit: cleanupPermit,
            confirmedCleanup: confirmedCleanup,
            deadlineSleeper: deadlineSleeper,
            deadline: deadline
        )
    }

    func stop(deadline: ContinuousClock.Instant) async {
        let sharedCompletion = await requestStop(deadline: deadline)
        await Self.waitForSharedCleanup(
            sharedCompletion,
            deadlineSleeper: deadlineSleeper,
            deadline: deadline
        )
    }

    func waitForConfirmedCleanup(until deadline: ContinuousClock.Instant) async -> Bool {
        await Self.waitForConfirmation(
            confirmedCleanup,
            deadlineSleeper: deadlineSleeper,
            deadline: deadline
        )
    }

    deinit {
        let state = state
        let underlying = underlying
        let cleanupPermit = cleanupPermit
        let confirmedCleanup = confirmedCleanup
        let deadlineSleeper = deadlineSleeper
        let deadline = ContinuousClock.now.advanced(by: Self.cleanupGrace)
        Task.detached {
            await CoreBoundSessionLifetime.performStop(
                state: state,
                underlying: underlying,
                cleanupPermit: cleanupPermit,
                confirmedCleanup: confirmedCleanup,
                deadlineSleeper: deadlineSleeper,
                deadline: deadline
            )
        }
    }

    nonisolated private static func performStop(
        state: SourceSessionState,
        underlying: any AgentAdapterSession,
        cleanupPermit: AdapterCleanupPermit,
        confirmedCleanup: BoundedAdapterStop,
        deadlineSleeper: AdapterDeadlineSleeper,
        deadline: ContinuousClock.Instant
    ) async {
        let sharedCompletion = await prepareStop(
            state: state,
            underlying: underlying,
            cleanupPermit: cleanupPermit,
            confirmedCleanup: confirmedCleanup,
            deadlineSleeper: deadlineSleeper,
            deadline: deadline
        )
        await waitForSharedCleanup(
            sharedCompletion,
            deadlineSleeper: deadlineSleeper,
            deadline: deadline
        )
    }

    nonisolated private static func prepareStop(
        state: SourceSessionState,
        underlying: any AgentAdapterSession,
        cleanupPermit: AdapterCleanupPermit,
        confirmedCleanup: BoundedAdapterStop,
        deadlineSleeper: AdapterDeadlineSleeper,
        deadline: ContinuousClock.Instant
    ) async -> BoundedAdapterStop {
        let directive = await state.beginStop()
        switch directive {
        case .start(let completion):
            startSharedCleanup(
                state: state,
                underlying: underlying,
                cleanupPermit: cleanupPermit,
                confirmedCleanup: confirmedCleanup,
                deadlineSleeper: deadlineSleeper,
                completion: completion,
                deadline: deadline
            )
            return completion
        case .wait(let completion):
            return completion
        }
    }

    nonisolated private static func startSharedCleanup(
        state: SourceSessionState,
        underlying: any AgentAdapterSession,
        cleanupPermit: AdapterCleanupPermit,
        confirmedCleanup: BoundedAdapterStop,
        deadlineSleeper: AdapterDeadlineSleeper,
        completion: BoundedAdapterStop,
        deadline: ContinuousClock.Instant
    ) {
        Task.detached {
            let boundedWork = BoundedAdapterStop()
            let countdown = AdapterStopCountdown(
                remaining: 2,
                completion: confirmedCleanup
            )
            let ticket = await AdapterCleanupSupervisor.shared.submit(
                underlying,
                permit: cleanupPermit,
                deadline: deadline
            )
            let adapterWait = Task.detached {
                await ticket.completion.wait()
                await countdown.arrive()
            }
            let drainWait = Task.detached {
                await state.waitUntilDrained()
                await countdown.arrive()
            }
            let confirmedWait = Task.detached {
                await confirmedCleanup.wait()
                await boundedWork.complete()
            }
            let timeout = Task.detached {
                await deadlineSleeper.sleep(until: deadline)
                await boundedWork.complete()
            }
            await boundedWork.wait()
            await AdapterCleanupSupervisor.shared.cancel(ticket)
            confirmedWait.cancel()
            timeout.cancel()
            await state.revoke()
            await completion.complete()
            _ = (adapterWait, drainWait)
        }
    }

    nonisolated private static func waitForSharedCleanup(
        _ sharedCompletion: BoundedAdapterStop,
        deadlineSleeper: AdapterDeadlineSleeper,
        deadline: ContinuousClock.Instant
    ) async {
        let localCompletion = BoundedAdapterStop()
        let sharedWait = Task.detached {
            await sharedCompletion.wait()
            await localCompletion.complete()
        }
        let timeout = Task.detached {
            await deadlineSleeper.sleep(until: deadline)
            await localCompletion.complete()
        }
        await localCompletion.wait()
        sharedWait.cancel()
        timeout.cancel()
    }

    nonisolated private static func waitForConfirmation(
        _ confirmation: BoundedAdapterStop,
        deadlineSleeper: AdapterDeadlineSleeper,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        if await confirmation.isCompleted { return true }
        let decision = AsyncBooleanDecision()
        let confirmationWait = Task.detached {
            await confirmation.wait()
            decision.resolve(true)
        }
        let timeout = Task.detached {
            await deadlineSleeper.sleep(until: deadline)
            decision.resolve(false)
        }
        let result = await decision.wait()
        confirmationWait.cancel()
        timeout.cancel()
        return result
    }
}

nonisolated private struct CoreBoundAdapterSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    let registryID: UUID
    let namespace: SourceNamespace
    let attempt: SourceAttempt
    let sink: ValidatingAgentEventSink
    let authorityLease: OneShotAuthorityLease
    let lifetime: CoreBoundSessionLifetime

    var state: SourceSessionState { lifetime.state }

    func start() async throws {
        guard await lifetime.state.beginStart() else {
            throw AdapterSessionError.invalidLifecycle
        }
        do { try await lifetime.underlying.start() } catch {
            await lifetime.state.failStart()
            throw error
        }
        switch await sink.activate() {
        case .committed:
            return
        case .cancelled:
            throw CancellationError()
        case .rejected:
            throw AdapterSessionError.invalidLifecycle
        }
    }

    func stop(deadline: ContinuousClock.Instant) async {
        await lifetime.stop(deadline: deadline)
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
    private let cleanupCapacity: AdapterCleanupCapacity
    private let deadlineSleeper: AdapterDeadlineSleeper

    init(
        compiledPresentations: [AgentPresentationDescriptor],
        compiledAdapters: [(AdapterDescriptor, any AgentAdapterFactory)],
        cleanupCapacity: AdapterCleanupCapacity = .shared,
        deadlineSleeper: AdapterDeadlineSleeper = .live
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
        self.cleanupCapacity = cleanupCapacity
        self.deadlineSleeper = deadlineSleeper
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
        }
        guard let cleanupPermit = cleanupCapacity.reserve() else {
            throw AdapterSessionError.cleanupCapacityUnavailable
        }
        let authorityGate = checkpoint?.gate ?? contract.freshSessionGate
        let reservationID = UUID()
        guard authorityGate.reserve(reservationID) else {
            if checkpoint != nil { throw AdapterSessionError.checkpointAlreadyConsumed }
            throw AdapterSessionError.contractAlreadyConsumed
        }
        let authority = OneShotAuthorityReservation(
            gate: authorityGate,
            reservationID: reservationID
        )
        let authorityLease = OneShotAuthorityLease(reservation: authority)
        let namespace = checkpoint?.namespace ?? SourceNamespace()
        let attempt = SourceAttempt()
        let state = SourceSessionState(
            baseline: checkpoint?.lastSourceSequence ?? 0,
            authority: authority
        )
        let sink = ValidatingAgentEventSink(
            contract: contract,
            namespace: namespace,
            attempt: attempt,
            state: state,
            downstream: downstream
        )
        let request = AgentAdapterSessionRequest(contract: contract, resumeFrom: checkpoint, sink: sink)
        var guardedLifetime: CoreBoundSessionLifetime?
        do {
            try Task.checkCancellation()
            let session = try await resolved.makeSession(request)
            let lifetime = CoreBoundSessionLifetime(
                state: state,
                underlying: session,
                cleanupPermit: cleanupPermit,
                deadlineSleeper: deadlineSleeper
            )
            guardedLifetime = lifetime
            try Task.checkCancellation()
            guard session.contract == contract else {
                throw AdapterSessionError.contractMismatch
            }
            return CoreBoundAdapterSession(
                contract: contract,
                registryID: registryID,
                namespace: namespace,
                attempt: attempt,
                sink: sink,
                authorityLease: authorityLease,
                lifetime: lifetime
            )
        } catch {
            await state.failStart()
            if let guardedLifetime {
                _ = await guardedLifetime.requestStop(
                    deadline: ContinuousClock.now.advanced(by: CoreBoundSessionLifetime.cleanupGrace)
                )
            }
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
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: CoreBoundSessionLifetime.cleanupGrace)
        _ = await source.lifetime.requestStop(deadline: deadline)
        let cleanupConfirmed = await source.lifetime.waitForConfirmedCleanup(until: deadline)
        try Task.checkCancellation()
        guard cleanupConfirmed,
              await source.state.finalizeCheckpoint() else {
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
        try Task.checkCancellation()
        let result = try await pair.1.probe()
        try Task.checkCancellation()
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
    ) async throws -> NegotiatedAdapterContract {
        guard offer.registryID == registryID,
              let pair = adapters[offer.adapterID],
              pair.0.agentID == offer.agentID,
              pair.0.adapterID == offer.adapterID,
              pair.0.factoryID == offer.factoryID else {
            throw AdapterNegotiationError.offerMismatch
        }
        guard offer.gate.consume() else {
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
            registryID: registryID, probeGeneration: offer.probeGeneration,
            agentID: pair.0.agentID, adapterID: offer.adapterID, factoryID: pair.0.factoryID,
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
