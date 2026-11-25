import Foundation
import Synchronization
import Testing
@testable import Pine

/// Shared OpenCode ACP test fixture factory (promoted from the private
/// helper in OpenCodeACPTests so the #1846 shared contract probe drives the
/// same transport fixture instead of duplicating it).
nonisolated func makeOpenCodeACPTestFixture(
    loadSession: VendorReference? = nil, rejectLoad: Bool = false, fenceResponse: Bool = false,
    deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30)),
    ingest: @escaping AgentAdapterRegistry.Downstream = { _ in .accepted }
) async throws -> OpenCodeACPTestFixture {
    let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "openCode"))
    let agent = presentation.agentID
    let adapter = try AdapterID(validating: "opencode:acp")
    let factoryID = try AdapterFactoryID(validating: "test.opencode.acp")
    let profile = try OpenCodeACPSession.profile()
    let versions = PineAdapterContractVersionRange(minimum: .init(major: 1, minor: 1),
                                                   maximum: .init(major: 1, minor: 1))
    let transport = OpenCodeACPFakeTransport(rejectLoad: rejectLoad)
    let recorder = OpenCodeACPSessionRecorder()
    let factory = OpenCodeACPTestFixtureFactory(id: factoryID, transport: transport, recorder: recorder,
                                    profile: profile, versions: versions, loadSession: loadSession,
                                    fenceResponse: fenceResponse, deadline: deadline)
    let registry = try AgentAdapterRegistry(
        compiledPresentations: [presentation],
        compiledAdapters: [(AdapterDescriptor(
            adapterID: adapter, agentID: agent, factoryID: factoryID,
            contractVersions: versions, maximumProfiles: [profile]
        ), factory)]
    )
    let offer = try await registry.probe(adapterID: adapter)
    let contract = try await registry.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
        allowedVersions: versions, transportPreference: [.ownedStandardIO], acceptedAuthentication: [.ownedChildPipe]
    ))
    let session = try await registry.makeSession(contract: contract, resumeFrom: nil, downstream: ingest)
    let concrete = try #require(recorder.value)
    return OpenCodeACPTestFixture(registry: registry, session: session, concrete: concrete, transport: transport)
}

nonisolated struct OpenCodeACPTestFixture: Sendable {
    let registry: AgentAdapterRegistry
    let session: any AgentAdapterSession
    let concrete: OpenCodeACPSession
    let transport: OpenCodeACPFakeTransport
}

nonisolated final class OpenCodeACPSessionRecorder: Sendable {
    private let session = Mutex<OpenCodeACPSession?>(nil)
    var value: OpenCodeACPSession? { session.withLock { $0 } }
    func set(_ value: OpenCodeACPSession) { session.withLock { $0 = value } }
}

nonisolated struct OpenCodeACPTestFixtureFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let transport: OpenCodeACPFakeTransport
    let recorder: OpenCodeACPSessionRecorder
    let profile: AdapterCapabilityProfile
    let versions: PineAdapterContractVersionRange
    let loadSession: VendorReference?
    let fenceResponse: Bool
    let deadline: ContinuousClock.Instant
    func probe() async throws -> AdapterProbeResult {
        try AdapterProbeResult(detectedVendorVersion: DetectedVendorVersion(OpenCodeACPSession.pinnedVersion), detectedSchema: nil,
                               offeredProfiles: [profile], offeredContractVersions: versions)
    }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        let factory = OpenCodeACPFactory(id: id, observation: try await probe()) { _ in
            OpenCodeACPAdmission(launch: { _ in
                transport.markLaunched()
                return transport
            }, cwd: "/fixture/task",
                                 selectedExecutable: URL(fileURLWithPath: "/fixture/opencode"),
                                 environmentProvenance: .inheritedPineProcess,
                                 deadline: deadline, loadSession: loadSession,
                                 beforeStartWrite: {}, revokeOwnership: {}, sessionBound: { _ in },
                                 promptResponded: { _ in fenceResponse ? .fenced : .recorded },
                                 sessionCreated: { _ in })
        }
        let session = try await factory.makeSession(request)
        guard let concrete = session as? OpenCodeACPSession else { throw OpenCodeACPError.invalidState }
        recorder.set(concrete)
        return session
    }
}

nonisolated final class OpenCodeACPFakeTransport: OpenCodeACPTransport, Sendable {
    private struct State {
        var queue: [CodexAppServerMessage] = []
        var waiter: CheckedContinuation<CodexAppServerMessage?, any Error>?
        var writes: [Data] = []
        var closed = false
        var failWrite = false
        var launches = 0
        var lastReadDeadline: ContinuousClock.Instant?
        var lastWriteDeadline: ContinuousClock.Instant?
    }
    private let state = Mutex(State())
    private let rejectLoad: Bool
    init(rejectLoad: Bool = false) { self.rejectLoad = rejectLoad }
    var launchCount: Int { state.withLock { $0.launches } }
    var lastReadDeadline: ContinuousClock.Instant? { state.withLock { $0.lastReadDeadline } }
    var lastWriteDeadline: ContinuousClock.Instant? { state.withLock { $0.lastWriteDeadline } }
    func markLaunched() { state.withLock { $0.launches += 1 } }
    func validate() throws {
        try state.withLock { if $0.closed { throw OpenCodeACPError.unavailable } }
    }
    func read(deadline: ContinuousClock.Instant) async throws -> CodexAppServerMessage? {
        state.withLock { $0.lastReadDeadline = deadline }
        let timeout = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                self.close()
            } catch { /* The read settled before its deadline. */ }
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    if state.closed {
                        continuation.resume(returning: nil)
                    } else if !state.queue.isEmpty {
                        continuation.resume(returning: state.queue.removeFirst())
                    } else if state.waiter != nil {
                        continuation.resume(throwing: OpenCodeACPError.invalidState)
                    } else {
                        state.waiter = continuation
                    }
                }
            }
        } onCancel: { self.close() }
    }
    func write(_ bytes: Data, deadline: ContinuousClock.Instant,
               beforeWrite: @escaping @Sendable () throws -> Void) async throws {
        try beforeWrite()
        let message = try CodexAppServerMessage(data: bytes)
        try state.withLock { state in
            state.lastWriteDeadline = deadline
            guard !state.closed else { throw OpenCodeACPError.unavailable }
            state.writes.append(bytes)
            if state.failWrite { throw OpenCodeACPError.unavailable }
        }
        if case .request(let id, let method, _) = message {
            if method == "initialize" {
                push(.response(id, result: .object([
                    "protocolVersion": .number("1"),
                    "agentInfo": .object(["name": .string("OpenCode"), "version": .string(OpenCodeACPSession.pinnedVersion)]),
                    "agentCapabilities": .object([
                        "loadSession": .bool(true),
                        "_meta": .object(["opencode/child-session-updates": .bool(true)])
                    ])
                ])))
            } else if method == "session/new" {
                push(.response(id, result: .object([
                    "sessionId": .string("ses_fixture"),
                    "configOptions": .array([
                        .object([
                            "id": .string("model"), "name": .string("Model"),
                            "category": .string("model"), "type": .string("select"),
                            "currentValue": .string("fixture/model"),
                            "options": .array([
                                .object(["value": .string("fixture/model"), "name": .string("Fixture model")]),
                            ]),
                        ]),
                    ]),
                ])))
            } else if method == "session/load" {
                if rejectLoad {
                    push(.failure(id, code: -32602))
                } else {
                    push(.response(id, result: .object([:])))
                }
            }
        }
    }
    func push(_ message: CodexAppServerMessage) {
        let waiter = state.withLock { state -> CheckedContinuation<CodexAppServerMessage?, any Error>? in
            guard !state.closed else { return nil }
            if let waiter = state.waiter { state.waiter = nil; return waiter }
            state.queue.append(message)
            return nil
        }
        waiter?.resume(returning: message)
    }
    func writes() throws -> [CodexAppServerMessage] {
        try state.withLock { try $0.writes.map { try CodexAppServerMessage(data: $0, requireJSONRPCVersion: true) } }
    }
    func failNextWrite() { state.withLock { $0.failWrite = true } }
    func close() {
        let waiter = state.withLock { state in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }
    func stop(deadline: ContinuousClock.Instant) async { close() }
}
