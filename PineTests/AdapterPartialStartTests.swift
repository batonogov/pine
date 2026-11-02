import Foundation
import Testing
@testable import Pine

@Suite("Adapter partial-start cleanup", .timeLimit(.minutes(1)))
struct AdapterPartialStartTests {
    @Test(arguments: [false, true], [false, true])
    func failedStartFencesFreshAndCheckpointRetries(
        resumed: Bool,
        ignoresCancellation: Bool
    ) async throws {
        let control = PartialStartControl(ignoresCancellation: ignoresCancellation)
        let deadlines = PartialStartDeadlines()
        let capacity = AdapterCleanupCapacity(limit: 2)
        let (registry, contract) = try await fixture(control, deadlines: deadlines, capacity: capacity)
        var checkpoint: AdapterResumeCheckpoint?
        if resumed {
            let source = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
            try await source.start()
            checkpoint = try await registry.makeCheckpoint(for: source)
        }
        let previousStops = await control.stopCalls
        await control.failNextStart()
        var failed: (any AgentAdapterSession)? = try await registry.makeSession(
            contract: contract, resumeFrom: checkpoint
        ) { event in
            await control.capture(event)
            return .accepted
        }
        let beforeStart = ContinuousClock.now
        await #expect(throws: AdapterSessionError.launchFailed(.transient)) {
            try await failed?.start()
        }
        let afterStart = ContinuousClock.now
        #expect(await control.liveCount == 1)
        #expect(await control.startOutcome == .bufferedUntilActivation)
        #expect(await control.emitFromFailedSink() == .revoked)
        #expect(await control.capturedCount == 0)
        #expect(await eventually { await control.stopCalls == previousStops + 1 })
        let automaticDeadline = await control.failedStopDeadline
        #expect(automaticDeadline != nil)
        if let automaticDeadline {
            #expect(automaticDeadline >= beforeStart.advanced(by: .seconds(5)))
            #expect(automaticDeadline <= afterStart.advanced(by: .seconds(5)))
        }

        // Capacity has a spare slot: only authority fencing can reject this retry.
        await expectRetryBlocked(registry, contract: contract, checkpoint: checkpoint, control: control)
        #expect(capacity.reservedCount == 1)
        #expect(await control.maximumLiveCount == 1)

        // Drive the grace deadline without a wall-clock sleep. Stop must return even
        // when the adapter ignores cancellation, but that is not proof of cleanup.
        await deadlines.expire()
        await failed?.stop(deadline: .now)
        await failed?.stop(deadline: .now)
        #expect(await control.stopCalls == previousStops + 1)
        failed = nil
        if ignoresCancellation {
            #expect(await control.liveCount == 1)
            #expect(capacity.reservedCount == 1)
            await expectRetryBlocked(registry, contract: contract, checkpoint: checkpoint, control: control)
        }
        await control.releaseStop()
        #expect(await eventually { capacity.reservedCount == 0 })
        #expect(await eventually { await control.liveCount == 0 })
        #expect(await control.emitFromFailedSink() == .revoked)
        #expect(await control.capturedCount == 0)

        let retry = try await retryAfterCleanup(registry, contract: contract, checkpoint: checkpoint)
        try await retry.start()
        #expect(await control.maximumLiveCount == 1)
        await retry.stop(deadline: .now.advanced(by: .seconds(5)))
        #expect(await eventually { capacity.reservedCount == 0 })
        #expect(await eventually { await control.stopCalls == previousStops + 2 })
    }

    @Test(arguments: [
        (false, false, false), (false, false, true),
        (false, true, false), (false, true, true),
        (true, false, false), (true, false, true),
        (true, true, false), (true, true, true)
    ])
    func stopBeforeSpawnRetainsAuthorityUntilStartSettles(
        resumed: Bool, throwsAfterSpawn: Bool, ignoresCancellation: Bool
    ) async throws {
        let control = PartialStartControl(ignoresCancellation: ignoresCancellation)
        let deadlines = PartialStartDeadlines()
        let capacity = AdapterCleanupCapacity(limit: 2)
        let (registry, contract) = try await fixture(control, deadlines: deadlines, capacity: capacity)
        var checkpoint: AdapterResumeCheckpoint?
        if resumed {
            let source = try await registry.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
            try await source.start()
            checkpoint = try await registry.makeCheckpoint(for: source)
        }
        let previousStops = await control.stopCalls
        await control.holdNextStartBeforeSpawn(throwsAfterSpawn: throwsAfterSpawn)
        var session: (any AgentAdapterSession)? = try await registry.makeSession(
            contract: contract, resumeFrom: checkpoint
        ) { _ in .accepted }
        let starting = Task { [session] in try await session?.start() }
        #expect(await eventually { await control.waitingBeforeSpawn })
        #expect(await control.liveCount == 0)

        // The caller's wait expires while start is still suspended, before any child exists.
        await deadlines.expire()
        await session?.stop(deadline: .now)
        await session?.stop(deadline: .now)
        // Give an erroneously completed cleanup every opportunity to release its permit.
        let releasedBeforeSettlement = await eventually { capacity.reservedCount == 0 }
        #expect(!releasedBeforeSettlement)
        #expect(capacity.reservedCount == 1)
        #expect(await control.stopCalls == previousStops)
        var prematureRetry: (any AgentAdapterSession)?
        do {
            prematureRetry = try await registry.makeSession(contract: contract, resumeFrom: checkpoint) { _ in .accepted }
            try await prematureRetry?.start()
            Issue.record("Retry admitted while the original start could still spawn")
        } catch {
            #expect(error as? AdapterSessionError == (resumed ? .checkpointAlreadyConsumed : .contractAlreadyConsumed))
        }

        await control.releasePreSpawn()
        let expected: AdapterSessionError = throwsAfterSpawn ? .launchFailed(.transient) : .invalidLifecycle
        await #expect(throws: expected) { try await starting.value }
        session = nil
        #expect(await eventually { await control.stopCalls == previousStops + 1 })
        #expect(await control.emitFromFailedSink() == .revoked)
        #expect(await control.maximumLiveCount == 1)
        if ignoresCancellation {
            #expect(capacity.reservedCount == 1)
            await control.releaseStop()
        }
        // Cooperative stop must exit on the already-expired deadline alone:
        // do not releaseStop(), which would mask a lost pre-registration cancel.
        #expect(await eventually { capacity.reservedCount == 0 })
        #expect(await eventually { await control.liveCount == 0 })
        #expect(await control.stopExits == previousStops + 1)
        await prematureRetry?.stop(deadline: .now)
        await control.cleanupProcesses()
        let retry = try await retryAfterCleanup(registry, contract: contract, checkpoint: checkpoint)
        try await retry.start()
        await retry.stop(deadline: .now)
        #expect(await eventually { capacity.reservedCount == 0 })
        #expect(await control.stopCalls == previousStops + (prematureRetry == nil ? 2 : 3))
    }

    @Test(arguments: [false, true])
    func cancellationFailureAlsoSchedulesCleanup(cancelAtActivation: Bool) async throws {
        let control = PartialStartControl(ignoresCancellation: false)
        let deadlines = PartialStartDeadlines()
        let capacity = AdapterCleanupCapacity(limit: 1)
        let (registry, contract) = try await fixture(control, deadlines: deadlines, capacity: capacity)
        await control.failNextStart(cancellation: true, cancelAtActivation: cancelAtActivation)
        let session = try await registry.makeSession(contract: contract, resumeFrom: nil) { event in
            await control.capture(event)
            return .accepted
        }
        let task = Task { try await session.start() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { await control.stopCalls == 1 })
        #expect(await control.stopWasCancelledOnEntry == false)
        #expect(await control.emitFromFailedSink() == .revoked)
        #expect(await control.capturedCount == 0)
        await deadlines.expire()
        await control.releaseStop()
        await session.stop(deadline: .now)
        #expect(await eventually { capacity.reservedCount == 0 })
        #expect(await control.stopCalls == 1)
    }

    private func expectRetryBlocked(
        _ registry: AgentAdapterRegistry,
        contract: NegotiatedAdapterContract,
        checkpoint: AdapterResumeCheckpoint?,
        control: PartialStartControl
    ) async {
        do {
            let duplicate = try await registry.makeSession(contract: contract, resumeFrom: checkpoint) { _ in .accepted }
            // On the base implementation this launches a second /bin/sleep process.
            try await duplicate.start()
            Issue.record("Retry launched beside an uncleaned failed start")
            await duplicate.stop(deadline: .now.advanced(by: .seconds(5)))
        } catch {
            #expect(error as? AdapterSessionError == (checkpoint == nil ? .contractAlreadyConsumed : .checkpointAlreadyConsumed))
        }
        #expect(await control.maximumLiveCount == 1)
    }

    private func retryAfterCleanup(
        _ registry: AgentAdapterRegistry,
        contract: NegotiatedAdapterContract,
        checkpoint: AdapterResumeCheckpoint?
    ) async throws -> any AgentAdapterSession {
        // Capacity release and authority confirmation are separate asynchronous hops.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            do { return try await registry.makeSession(contract: contract, resumeFrom: checkpoint) { _ in .accepted } } catch {
                guard ContinuousClock.now < deadline,
                      error as? AdapterSessionError == (checkpoint == nil ? .contractAlreadyConsumed : .checkpointAlreadyConsumed)
                else { throw error }
                await Task.yield()
            }
        }
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    private func fixture(
        _ control: PartialStartControl,
        deadlines: PartialStartDeadlines,
        capacity: AdapterCleanupCapacity
    ) async throws -> (AgentAdapterRegistry, NegotiatedAdapterContract) {
        let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "codex"))
        let profile = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: [.init(scope: .session, phase: .settled)], evidence: []),
            delivery: AdapterDeliverySemantics(replay: .sourceCursor, ordering: .ordered, minimumAuthentication: .ownedChildPipe)
        )
        let versions = PineAdapterContractVersionRange(
            minimum: PineAdapterContractVersion(major: 1, minor: 0),
            maximum: PineAdapterContractVersion(major: 1, minor: 0)
        )
        let factoryID = try AdapterFactoryID(validating: "pine.codex.partial.factory")
        let adapterID = try AdapterID(validating: "pine:codex:partial")
        let descriptor = AdapterDescriptor(
            adapterID: adapterID, agentID: presentation.agentID, factoryID: factoryID,
            contractVersions: versions, maximumProfiles: [profile]
        )
        let probe = try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion("test-1"), detectedSchema: nil,
            offeredProfiles: [profile], offeredContractVersions: versions
        )
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(descriptor, PartialStartFactory(id: factoryID, result: probe, control: control))],
            cleanupCapacity: capacity,
            deadlineSleeper: AdapterDeadlineSleeper { await deadlines.sleep(until: $0) }
        )
        let offer = try await registry.probe(adapterID: adapterID)
        let contract = try await registry.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
            allowedVersions: versions, transportPreference: [.ownedStandardIO], acceptedAuthentication: [.ownedChildPipe]
        ))
        return (registry, contract)
    }
}

nonisolated private struct PartialStartFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let result: AdapterProbeResult
    let control: PartialStartControl

    func probe() async throws -> AdapterProbeResult { result }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        PartialStartSession(contract: request.contract, request: request, control: control)
    }
}

nonisolated private struct PartialStartSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    let request: AgentAdapterSessionRequest
    let control: PartialStartControl
    private let id = UUID()

    init(contract: NegotiatedAdapterContract, request: AgentAdapterSessionRequest, control: PartialStartControl) {
        self.contract = contract
        self.request = request
        self.control = control
    }
    func start() async throws { try await control.launch(id, request: request) }
    func stop(deadline: ContinuousClock.Instant) async { await control.stop(id, deadline: deadline) }
}

private actor PartialStartControl {
    private let ignoresCancellation: Bool
    private var fail = false
    private var cancellation = false
    private var cancelAtActivation = false
    private var preSpawn = false
    private var throwsAfterSpawn = true
    private var preSpawnWaiter: CheckedContinuation<Void, Never>?
    private(set) var waitingBeforeSpawn = false
    private var failedID: UUID?
    private var failedSink: (any AgentEventSink)?
    private var live: [UUID: PartialStartProcess] = [:]
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopReleased = false
    private let cooperativeStop = AsyncContinuationGate()
    private(set) var stopCalls = 0
    private(set) var stopExits = 0
    private(set) var failedStopDeadline: ContinuousClock.Instant?
    private(set) var stopWasCancelledOnEntry: Bool?
    private(set) var maximumLiveCount = 0
    private(set) var capturedCount = 0
    private(set) var startOutcome: AdapterIngestOutcome?
    var liveCount: Int { live.count }

    init(ignoresCancellation: Bool) { self.ignoresCancellation = ignoresCancellation }
    func failNextStart(cancellation: Bool = false, cancelAtActivation: Bool = false) {
        fail = true
        self.cancellation = cancellation
        self.cancelAtActivation = cancelAtActivation
    }
    func holdNextStartBeforeSpawn(throwsAfterSpawn: Bool) {
        preSpawn = true
        self.throwsAfterSpawn = throwsAfterSpawn
    }
    func releasePreSpawn() {
        preSpawnWaiter?.resume()
        preSpawnWaiter = nil
    }
    func cleanupProcesses() async {
        let processes = Array(live.values)
        live.removeAll()
        for process in processes { await process.stop() }
    }
    func launch(_ id: UUID, request: AgentAdapterSessionRequest) async throws {
        let heldBeforeSpawn = preSpawn
        if heldBeforeSpawn {
            preSpawn = false
            failedID = id
            failedSink = request.sink
            waitingBeforeSpawn = true
            // Deliberately ignores cancellation: stop before this resumes sees no child.
            await withCheckedContinuation { preSpawnWaiter = $0 }
            waitingBeforeSpawn = false
        }
        live[id] = try PartialStartProcess()
        maximumLiveCount = max(maximumLiveCount, live.count)
        let shouldFail = fail || (heldBeforeSpawn && throwsAfterSpawn)
        fail = false
        if shouldFail {
            failedID = id
            failedSink = request.sink
        }
        let outcome = await request.sink.ingest(try candidate(sequence: (request.resumeFrom?.lastSourceSequence ?? 0) + 1))
        if shouldFail {
            startOutcome = outcome
            if cancellation {
                withUnsafeCurrentTask { $0?.cancel() }
                if cancelAtActivation { return }
                throw CancellationError()
            }
            throw AdapterSessionError.launchFailed(.transient)
        }
    }
    func stop(_ id: UUID, deadline: ContinuousClock.Instant) async {
        stopCalls += 1
        if id == failedID, live[id] != nil {
            failedStopDeadline = deadline
            stopWasCancelledOnEntry = Task.isCancelled
            if ignoresCancellation {
                if !stopReleased { await withCheckedContinuation { stopWaiters.append($0) } }
            } else {
                await cooperativeStop.wait()
            }
        }
        if let process = live.removeValue(forKey: id) { await process.stop() }
        stopExits += 1
    }
    func releaseStop() {
        stopReleased = true
        cooperativeStop.resolve()
        let retained = stopWaiters
        stopWaiters.removeAll()
        retained.forEach { $0.resume() }
    }
    func emitFromFailedSink() async -> AdapterIngestOutcome {
        guard let failedSink else { return .droppedInvalid }
        guard let lateCandidate = try? candidate(sequence: 100) else { return .droppedInvalid }
        return await failedSink.ingest(lateCandidate)
    }
    func capture(_ event: ValidatedAgentEvent) { capturedCount += 1 }
    private func candidate(sequence: UInt64) throws -> AdapterCandidate {
        AdapterCandidate(event: .processExited(status: nil), sourcePosition: try AdapterSourcePosition(
            sourceEvent: VendorReference(role: .event, value: "event-\(sequence)"),
            resumePosition: AdapterResumePosition("cursor-\(sequence)"), sourceSequence: sequence
        ))
    }
}

// Real owned child, with a deinit safety net even when a regression assertion fails.
nonisolated private final class PartialStartProcess: Sendable {
    private let process: Process
    private let exited = AsyncContinuationGate()

    init() throws {
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        let exited = exited
        process.terminationHandler = { _ in exited.resolve() }
        try process.run()
    }

    func stop() async {
        let process = process
        let exited = exited
        // The adapter's return must confirm real child exit even when the bounded
        // supervisor cancelled its task to end the cooperative hold above.
        await Task.detached {
            if process.isRunning { process.terminate() }
            await exited.wait()
        }.value
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}

private actor PartialStartDeadlines {
    private var expired = false
    private var waiters: [AsyncContinuationGate] = []
    func sleep(until deadline: ContinuousClock.Instant) async {
        guard !expired else { return }
        let gate = AsyncContinuationGate()
        waiters.append(gate)
        await gate.wait()
    }
    func expire() {
        expired = true
        waiters.forEach { $0.resolve() }
        waiters.removeAll()
    }
}
