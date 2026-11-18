import Foundation
import Synchronization
import Testing
@testable import Pine

extension CodexAppServerMessage {
    var params: AgentEventJSON {
        switch self {
        case let .request(_, _, params), let .notification(_, params):
            return params
        case .response, .failure:
            preconditionFailure("Only requests and notifications carry params")
        }
    }
}

// MARK: - Scripted transport

/// Message-level scripted Kimi ACP provider. It auto-answers bootstrap
/// requests with sanitized fixture envelopes and records every physical
/// write for assertion. It is not a real process and grants no authority.
nonisolated final class KimiFakeTransport: KimiACPTransport, Sendable {
    private struct State {
        var queue: [CodexAppServerMessage] = []
        var waiter: CheckedContinuation<CodexAppServerMessage?, any Error>?
        var writes: [Data] = []
        var closed = false
    }
    private let state = Mutex(State())
    let sessionID: String
    let forkedSessionID: String
    let rejectLoad: Bool
    let withAuthMethods: Bool
    let imageCapability: Bool
    let embeddedContextCapability: Bool
    let replayOnResume: Bool
    let foreignReplay: Bool

    init(sessionID: String = "kimi_fixture_new", rejectLoad: Bool = false,
         withAuthMethods: Bool = true, imageCapability: Bool = true,
         embeddedContextCapability: Bool = true, replayOnResume: Bool = false,
         foreignReplay: Bool = false) {
        self.sessionID = sessionID
        forkedSessionID = sessionID + "_forked"
        self.rejectLoad = rejectLoad
        self.withAuthMethods = withAuthMethods
        self.imageCapability = imageCapability
        self.embeddedContextCapability = embeddedContextCapability
        self.replayOnResume = replayOnResume
        self.foreignReplay = foreignReplay
    }

    var promptRequestIDs: [CodexAppServerRequestID] {
        state.withLock {
            $0.writes.compactMap { bytes in
                guard let message = try? CodexAppServerMessage(data: bytes),
                      case .request(let id, let method, _) = message,
                      method == "session/prompt" else { return nil }
                return id
            }
        }
    }

    func validate() throws {
        try state.withLock { if $0.closed { throw KimiACPWireError.unavailable } }
    }

    func read(deadline: ContinuousClock.Instant) async throws -> CodexAppServerMessage? {
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
                        continuation.resume(throwing: KimiACPWireError.invalidState)
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
        // Kimi egress must always carry jsonrpc 2.0.
        var parser = AgentEventJSONParser(data: bytes)
        guard case .object(let fields) = try parser.parse(),
              fields["jsonrpc"] == .string("2.0") else {
            throw KimiACPWireError.invalidProtocol
        }
        let message = try CodexAppServerMessage(data: bytes)
        try state.withLock { if $0.closed { throw KimiACPWireError.unavailable } }
        state.withLock { $0.writes.append(bytes) }
        if case .request(let id, let method, let params) = message {
            switch method {
            case "initialize":
                push(.response(id, result: .object([
                    "protocolVersion": .number("1"),
                    "agentInfo": .object([
                        "name": .string("Kimi Code CLI"),
                        "version": .string(KimiACPCapabilities.pinnedCLIVersion)
                    ]),
                    "agentCapabilities": .object([
                        "loadSession": .bool(true),
                        "promptCapabilities": .object([
                            "image": .bool(imageCapability), "audio": .bool(false),
                            "embeddedContext": .bool(embeddedContextCapability)
                        ]),
                        "sessionCapabilities": .object([
                            "resume": .object([:]), "fork": .object([:]),
                            "additionalDirectories": .object([:])
                        ]),
                        "auth": .object(["logout": .object([:])])
                    ]),
                    "authMethods": withAuthMethods ? .array([
                        .object(["id": .string("login"), "name": .string("Kimi login")])
                    ]) : .array([])
                ])))
            case "session/new":
                push(.response(id, result: .object([
                    "sessionId": .string(sessionID),
                    "configOptions": .array([
                        .object([
                            "id": .string("mode"), "name": .string("Session Mode"),
                            "type": .string("select"), "currentValue": .string("ask")
                        ]),
                        .object([
                            "id": .string("future"), "name": .string("Future"),
                            "type": .string("pine_future_type"), "currentValue": .string("x")
                        ])
                    ])
                ])))
            case "session/load":
                if rejectLoad {
                    push(.failure(id, code: -32602))
                } else {
                    let source = try Self.sourceSessionID(params) ?? sessionID
                    let replayID = foreignReplay ? sessionID : source
                    push(notification(sessionID: replayID, text: "fixture-history-one"))
                    push(notification(sessionID: replayID, text: "fixture-history-two"))
                    push(.response(id, result: .object([:])))
                }
            case "session/resume":
                if replayOnResume {
                    // Protocol violation probe: resume must never replay.
                    let source = try Self.sourceSessionID(params) ?? sessionID
                    push(notification(sessionID: source, text: "fixture-history"))
                }
                push(.response(id, result: .object([:])))
            case "session/fork":
                push(.response(id, result: .object(["sessionId": .string(forkedSessionID)])))
            default:
                break // Prompts settle when the test pushes the stop reason.
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
        try state.withLock { try $0.writes.map { try CodexAppServerMessage(data: $0) } }
    }

    func lastWrite(matching predicate: (CodexAppServerMessage) throws -> Bool) throws
        -> CodexAppServerMessage? {
        try writes().reversed().first(where: predicate)
    }

    func close() {
        let waiter = state.withLock { state in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    func stop(deadline: ContinuousClock.Instant) async { close() }

    private static func sourceSessionID(_ params: AgentEventJSON) throws -> String? {
        guard case .object(let fields) = params, let value = fields["sessionId"] else { return nil }
        return try KimiACPWire.string(value)
    }

    private func notification(sessionID: String, text: String) -> CodexAppServerMessage {
        .notification(method: "session/update", params: .object([
            "sessionId": .string(sessionID),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string(text)])
            ])
        ]))
    }
}

// MARK: - Fixture factory

nonisolated struct KimiFixtureOptions: Sendable {
    var action: KimiACPSessionAction = .new()
    var fenceResponses = false
    var accountGate: @Sendable () throws -> Bool = { true }
    var rejectLoad = false
    var withAuthMethods = true
    var replayOnResume = false
    var foreignReplay = false
    var imageCapability = true
    var embeddedContextCapability = true
}

nonisolated final class KimiSessionRecorder: Sendable {
    private let session = Mutex<KimiACPSession?>(nil)
    var value: KimiACPSession? { session.withLock { $0 } }
    func set(_ value: KimiACPSession) { session.withLock { $0 = value } }
}

nonisolated final class KimiSinkCollector: Sendable {
    private let events = Mutex<[ValidatedAgentEvent]>([])
    var value: [ValidatedAgentEvent] { events.withLock { $0 } }
    func ingest(_ event: ValidatedAgentEvent) async -> AdapterIngestOutcome {
        events.withLock { $0.append(event) }
        return .accepted
    }
}

nonisolated struct KimiFixtureFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let transport: KimiFakeTransport
    let recorder: KimiSessionRecorder
    let options: KimiFixtureOptions

    func probe() async throws -> AdapterProbeResult {
        try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion(KimiACPCapabilities.pinnedCLIVersion),
            detectedSchema: nil,
            offeredProfiles: [try KimiACPSession.profile()],
            offeredContractVersions: PineAdapterContractVersionRange(
                minimum: PineAdapterContractVersion(major: 1, minor: 1),
                maximum: PineAdapterContractVersion(major: 1, minor: 1)
            )
        )
    }

    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        let factory = KimiACPFactory(id: id, observation: try await probe()) { _ in
            KimiACPAdmission(
                launch: { _ in self.transport },
                cwd: "/fixture/task",
                deadline: ContinuousClock.now.advanced(by: .seconds(300)),
                action: self.options.action,
                beforeStartWrite: {},
                revokeOwnership: {},
                sessionBound: { _ in },
                promptResponded: { _ in self.options.fenceResponses ? .fenced : .recorded },
                accountGate: self.options.accountGate
            )
        }
        let session = try await factory.makeSession(request)
        recorder.set(try #require(session as? KimiACPSession))
        return session
    }
}

nonisolated struct KimiTestFixture: Sendable {
    let registry: AgentAdapterRegistry
    let session: any AgentAdapterSession
    let concrete: KimiACPSession
    let transport: KimiFakeTransport

    static func make(
        options: KimiFixtureOptions = .init(),
        sessionID: String = "kimi_fixture_new",
        ingest: @escaping @Sendable (ValidatedAgentEvent) async -> AdapterIngestOutcome
    ) async throws -> KimiTestFixture {
        let transport = KimiFakeTransport(
            sessionID: sessionID,
            rejectLoad: options.rejectLoad,
            withAuthMethods: options.withAuthMethods,
            imageCapability: options.imageCapability,
            embeddedContextCapability: options.embeddedContextCapability,
            replayOnResume: options.replayOnResume,
            foreignReplay: options.foreignReplay
        )
        let recorder = KimiSessionRecorder()
        let factory = KimiFixtureFactory(
            id: try AdapterFactoryID(validating: "kimi-acp-fixture"),
            transport: transport, recorder: recorder, options: options
        )
        let version = PineAdapterContractVersion(major: 1, minor: 1)
        let range = PineAdapterContractVersionRange(minimum: version, maximum: version)
        let presentation = try #require(try AgentPresentationCatalog.builtIn(stableIdentifier: "kimiCode"))
        let descriptor = try AdapterDescriptor(
            adapterID: AdapterID(validating: "kimi-acp"),
            agentID: presentation.agentID,
            factoryID: factory.id,
            contractVersions: range,
            maximumProfiles: [try KimiACPSession.profile()]
        )
        let registry = try AgentAdapterRegistry(
            compiledPresentations: [presentation], compiledAdapters: [(descriptor, factory)]
        )
        let offer = try await registry.probe(adapterID: descriptor.adapterID)
        let contract = try await registry.negotiate(
            offer: offer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: range,
                transportPreference: [.ownedStandardIO],
                acceptedAuthentication: [.ownedChildPipe]
            )
        )
        let session = try await registry.makeSession(
            contract: contract, resumeFrom: nil, downstream: ingest
        )
        return KimiTestFixture(
            registry: registry, session: session,
            concrete: try #require(recorder.value), transport: transport
        )
    }
}
