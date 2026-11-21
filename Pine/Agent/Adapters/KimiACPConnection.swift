import Foundation

/// Connection-local ACP protocol bookkeeping for one Kimi `kimi acp` child.
/// This is not registry authority, account authentication, or task readiness.
/// A new process always creates a new instance; nothing here reattaches to an
/// old live channel. Server responses are one-shot: a written answer is
/// replayed byte-for-byte on redelivery, and a resolved or cancelled request
/// can never be answered twice.
nonisolated struct KimiACPConnection {
    enum Phase: Equatable, Sendable { case fresh, initializing, ready, closed }
    enum Delivery: Equatable, Sendable {
        case initialized(AgentEventJSON)
        case response(CodexAppServerRequestID, method: String, result: AgentEventJSON)
        case failure(CodexAppServerRequestID, method: String, code: Int64)
        case serverRequest(CodexAppServerRequestID, method: String, params: AgentEventJSON)
        case notification(method: String, params: AgentEventJSON)
        case ignoredForeignConnection, duplicateRequest, replayedResponse
    }

    struct PreparedResponse: Sendable {
        let bytes: Data
        fileprivate let identifier: CodexAppServerRequestID
        fileprivate let token: UUID
        fileprivate let request: CodexAppServerMessage
    }

    static let maximumPendingRequests = 32
    static let maximumServerRequests = 32
    /// Connection-lifetime remembered answers/resolutions. Memory hygiene for
    /// replay, not a protocol limit: a chatty long task exceeds the old 64.
    static let maximumRememberedResponses = 512
    let identity: UUID
    private(set) var phase: Phase = .fresh
    private var nextID: Int64 = 0
    private var pending: [CodexAppServerRequestID: String] = [:]
    private var serverRequests: [CodexAppServerRequestID: CodexAppServerMessage] = [:]
    private var preparingResponses: [CodexAppServerRequestID: UUID] = [:]
    private var resolvedRequests: Set<CodexAppServerRequestID> = []
    /// The exact ACP-encoded bytes of an already written answer, so redelivery
    /// replays byte-for-byte (including the mandatory `jsonrpc: "2.0"`).
    private var responses: [CodexAppServerRequestID: (request: CodexAppServerMessage, bytes: Data)] = [:]

    init(identity: UUID = UUID()) { self.identity = identity }

    /// ACP client capabilities are the reverse-RPC surface Pine actually owns.
    /// Only `elicitation.form` is implemented in this slice; `fs`, `terminal`,
    /// and terminal-auth flows are deliberately absent so the agent acts on its
    /// own owned process instead of delegating authority to Pine.
    mutating func initialize(write: (Data) throws -> Void) throws {
        guard phase == .fresh else { throw KimiACPWireError.invalidState }
        phase = .initializing
        let params: [String: AgentEventJSON] = [
            "protocolVersion": .number("1"),
            "clientCapabilities": .object([
                "elicitation": .object(["form": .object([:])])
            ]),
            "clientInfo": .object([
                "name": .string("pine"), "title": .string("Pine"), "version": .string("3.0")
            ])
        ]
        _ = try send(method: "initialize", params: .object(params), write: write)
    }

    /// No automatic retry: a failed write can have reached the provider.
    /// Closing fences all state until the owner starts a new connection.
    @discardableResult
    mutating func request(
        method: String,
        params: AgentEventJSON,
        write: (Data) throws -> Void
    ) throws -> CodexAppServerRequestID {
        guard phase == .ready, method != "initialize" else {
            throw KimiACPWireError.invalidState
        }
        return try send(method: method, params: params, write: write)
    }

    mutating func receive(
        _ message: CodexAppServerMessage,
        connection: UUID,
        write: (Data) throws -> Void
    ) throws -> Delivery {
        guard connection == identity else { return .ignoredForeignConnection }
        guard phase != .closed, phase != .fresh else { throw KimiACPWireError.closed }
        do {
            switch message {
            case .response(let identifier, let result):
                guard let method = pending.removeValue(forKey: identifier) else {
                    throw KimiACPWireError.foreignResponse
                }
                if method == "initialize" {
                    guard phase == .initializing,
                          case .object(let fields) = result,
                          fields["protocolVersion"] == .number("1") else {
                        throw KimiACPWireError.invalidEnvelope
                    }
                    phase = .ready
                    return .initialized(result)
                }
                return .response(identifier, method: method, result: result)
            case .failure(let identifier, let code):
                guard let method = pending.removeValue(forKey: identifier) else {
                    throw KimiACPWireError.foreignResponse
                }
                if method == "initialize" { close() }
                return .failure(identifier, method: method, code: code)
            case .notification(let method, let params):
                guard phase == .ready else { throw KimiACPWireError.invalidState }
                return .notification(method: method, params: params)
            case .request(let identifier, let method, let params):
                guard phase == .ready else { throw KimiACPWireError.invalidState }
                if let remembered = responses[identifier] {
                    guard remembered.request == message else { throw KimiACPWireError.invalidEnvelope }
                    try write(remembered.bytes)
                    // Duplicate delivery must not prompt the user again.
                    return .replayedResponse
                }
                guard !resolvedRequests.contains(identifier) else {
                    throw KimiACPWireError.invalidEnvelope
                }
                if let prior = serverRequests[identifier] {
                    guard prior == message else { throw KimiACPWireError.invalidEnvelope }
                    return .duplicateRequest
                } else {
                    guard serverRequests.count < Self.maximumServerRequests else {
                        throw KimiACPWireError.capacity
                    }
                    serverRequests[identifier] = message
                }
                return .serverRequest(identifier, method: method, params: params)
            }
        } catch {
            close()
            throw error
        }
    }

    /// Unsupported reverse-RPC methods use methodNotFound, never a
    /// permissive default answer. The caller must validate task/session
    /// ownership before answering a supported request.
    mutating func reject(
        _ identifier: CodexAppServerRequestID,
        write: (Data) throws -> Void
    ) throws {
        try respond(identifier, response: .failure(identifier, code: -32601), write: write)
    }

    /// Called only after the owning mapper validated the resolution. A
    /// resolved request becomes non-actionable; a prepared answer may still be
    /// in flight and is fenced separately.
    mutating func resolveServerRequest(_ identifier: CodexAppServerRequestID) throws {
        guard phase == .ready else { throw KimiACPWireError.invalidState }
        guard serverRequests[identifier] != nil else { return }
        if preparingResponses[identifier] != nil { return }
        guard responses.count + resolvedRequests.count + preparingResponses.count
                < Self.maximumRememberedResponses else {
            close()
            throw KimiACPWireError.capacity
        }
        serverRequests.removeValue(forKey: identifier)
        resolvedRequests.insert(identifier)
    }

    mutating func prepareAnswer(
        _ identifier: CodexAppServerRequestID,
        result: AgentEventJSON
    ) throws -> PreparedResponse {
        try prepareResponse(identifier, response: .response(identifier, result: result))
    }

    mutating func prepareRejection(_ identifier: CodexAppServerRequestID) throws -> PreparedResponse {
        try prepareResponse(identifier, response: .failure(identifier, code: -32601))
    }

    mutating func confirmResponseWritten(_ prepared: PreparedResponse) throws {
        guard phase == .ready,
              preparingResponses[prepared.identifier] == prepared.token,
              serverRequests[prepared.identifier] == prepared.request else {
            throw KimiACPWireError.invalidState
        }
        preparingResponses.removeValue(forKey: prepared.identifier)
        serverRequests.removeValue(forKey: prepared.identifier)
        responses[prepared.identifier] = (prepared.request, prepared.bytes)
    }

    mutating func close() {
        phase = .closed
        pending.removeAll()
        serverRequests.removeAll()
        responses.removeAll()
        preparingResponses.removeAll()
        resolvedRequests.removeAll()
    }

    private mutating func send(
        method: String,
        params: AgentEventJSON,
        write: (Data) throws -> Void
    ) throws -> CodexAppServerRequestID {
        do {
            guard pending.count < Self.maximumPendingRequests, nextID < Int64.max else {
                throw KimiACPWireError.capacity
            }
            let identifier = CodexAppServerRequestID.integer(nextID)
            nextID += 1
            let message = CodexAppServerMessage.request(identifier, method: method, params: params)
            let data = try KimiACPWire.encode(message)
            pending[identifier] = method
            try write(data)
            return identifier
        } catch {
            close()
            throw error
        }
    }

    private mutating func prepareResponse(
        _ identifier: CodexAppServerRequestID,
        response: CodexAppServerMessage
    ) throws -> PreparedResponse {
        guard phase == .ready, let request = serverRequests[identifier],
              preparingResponses[identifier] == nil else {
            throw KimiACPWireError.invalidState
        }
        guard responses.count + preparingResponses.count + resolvedRequests.count
                < Self.maximumRememberedResponses else {
            close()
            throw KimiACPWireError.capacity
        }
        let bytes = try KimiACPWire.encode(response)
        guard bytes.count <= KimiACPWire.maximumFrameBytes else {
            close()
            throw KimiACPWireError.capacity
        }
        let token = UUID()
        preparingResponses[identifier] = token
        return PreparedResponse(bytes: bytes, identifier: identifier, token: token, request: request)
    }

    private mutating func respond(
        _ identifier: CodexAppServerRequestID,
        response: CodexAppServerMessage,
        write: (Data) throws -> Void
    ) throws {
        guard phase == .ready, serverRequests[identifier] != nil,
              preparingResponses[identifier] == nil else {
            throw KimiACPWireError.invalidState
        }
        do {
            let prepared = try prepareResponse(identifier, response: response)
            try write(prepared.bytes)
            try confirmResponseWritten(prepared)
        } catch {
            close()
            throw error
        }
    }
}
