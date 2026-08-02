import Foundation

nonisolated protocol AgentEventSink: Sendable {
    /// The sink is created and authority-bound by Pine; producers supply candidate data only.
    func ingest(_ candidate: AdapterCandidate) async -> AdapterIngestOutcome
}

nonisolated protocol AgentAdapterSession: Sendable {
    var contract: NegotiatedAdapterContract { get }
    /// Propagates `CancellationError` unchanged.
    func start() async throws
    /// Attempts bounded cleanup independently of caller cancellation; it does not promise forced termination.
    func stop(deadline: ContinuousClock.Instant) async
}

nonisolated protocol AgentAdapterFactory: Sendable {
    var id: AdapterFactoryID { get }
    /// Probes a factory instance already bound by a future supervised loader.
    /// This method neither searches PATH nor proves executable identity.
    /// Cancellation is reported by propagating `CancellationError`.
    func probe() async throws -> AdapterProbeResult
    /// Propagates `CancellationError` unchanged.
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession
}

nonisolated enum AdapterFailureDisposition: Equatable, Sendable { case transient, permanent }
nonisolated enum AdapterProbeError: Error, Equatable, Sendable {
    case unavailable(AdapterFailureDisposition), malformedResponse
}
nonisolated enum AdapterSessionError: Error, Equatable, Sendable {
    case launchFailed(AdapterFailureDisposition)
    case contractMismatch
    case checkpointNotSupported
    case checkpointMismatch
    case checkpointUnavailable
    case checkpointAlreadyConsumed
    case invalidLifecycle
}
nonisolated enum AdapterIngestOutcome: Equatable, Sendable {
    case accepted, bufferedUntilActivation, droppedInvalid, revoked
}
