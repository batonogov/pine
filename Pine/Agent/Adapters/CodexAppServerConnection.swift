import Foundation

/// Connection-local protocol bookkeeping. This is not registry authority, account
/// authentication, or task readiness. Owned-stdio ingress must supply the exact
/// connection identity; a new process always creates a new instance.
nonisolated struct CodexAppServerConnection {
    enum Phase: Equatable, Sendable { case fresh, initializing, ready, closed }
    enum Delivery: Equatable, Sendable {
        case initialized
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
        fileprivate let response: CodexAppServerMessage
    }

    static let maximumPendingRequests = 32
    static let maximumServerRequests = 32
    static let maximumRememberedResponses = 64
    let identity: UUID
    private(set) var phase: Phase = .fresh
    private var nextID: Int64 = 0
    private var pending: [CodexAppServerRequestID: String] = [:]
    private var serverRequests: [CodexAppServerRequestID: CodexAppServerMessage] = [:]
    private var preparingResponses: [CodexAppServerRequestID: UUID] = [:]
    private var resolvedRequests: Set<CodexAppServerRequestID> = []
    private var responses: [CodexAppServerRequestID: (request: CodexAppServerMessage, response: CodexAppServerMessage)] = [:]

    init(identity: UUID = UUID()) { self.identity = identity }

    mutating func initialize(experimentalAPI: Bool = false, write: (Data) throws -> Void) throws {
        guard phase == .fresh else { throw CodexAppServerWireError.invalidState }
        phase = .initializing
        var params: [String: AgentEventJSON] = [
            "clientInfo": .object([
                "name": .string("pine"), "title": .string("Pine"), "version": .string("3.0")
            ])
        ]
        if experimentalAPI { params["capabilities"] = .object(["experimentalApi": .bool(true)]) }
        _ = try send(method: "initialize", params: .object(params), write: write)
    }

    /// No automatic retry: a failed write can have reached the provider. Closing
    /// fences all state until the owner explicitly starts a new connection.
    @discardableResult
    mutating func request(
        method: String,
        params: AgentEventJSON,
        write: (Data) throws -> Void
    ) throws -> CodexAppServerRequestID {
        guard phase == .ready, method != "initialize" else {
            throw CodexAppServerWireError.invalidState
        }
        return try send(method: method, params: params, write: write)
    }

    mutating func receive(
        _ message: CodexAppServerMessage,
        connection: UUID,
        write: (Data) throws -> Void
    ) throws -> Delivery {
        guard connection == identity else { return .ignoredForeignConnection }
        guard phase != .closed, phase != .fresh else { throw CodexAppServerWireError.closed }
        do {
            switch message {
            case .response(let identifier, let result):
                guard let method = pending.removeValue(forKey: identifier) else {
                    throw CodexAppServerWireError.foreignResponse
                }
                if method == "initialize" {
                    guard phase == .initializing,
                          case .object(let fields) = result,
                          case .string(let userAgent) = fields["userAgent"], !userAgent.isEmpty else {
                        throw CodexAppServerWireError.invalidEnvelope
                    }
                    try write(CodexAppServerMessage.notification(method: "initialized", params: .object([:])).encoded())
                    phase = .ready
                    return .initialized
                }
                return .response(identifier, method: method, result: result)
            case .failure(let identifier, let code):
                guard let method = pending.removeValue(forKey: identifier) else {
                    throw CodexAppServerWireError.foreignResponse
                }
                if method == "initialize" { close() }
                return .failure(identifier, method: method, code: code)
            case .notification(let method, let params):
                guard phase == .ready else { throw CodexAppServerWireError.invalidState }
                return .notification(method: method, params: params)
            case .request(let identifier, let method, let params):
                guard phase == .ready else { throw CodexAppServerWireError.invalidState }
                if let remembered = responses[identifier] {
                    guard remembered.request == message else { throw CodexAppServerWireError.invalidEnvelope }
                    try write(remembered.response.encoded())
                    // Duplicate delivery must not prompt the user again.
                    return .replayedResponse
                }
                guard !resolvedRequests.contains(identifier) else { throw CodexAppServerWireError.invalidEnvelope }
                if let prior = serverRequests[identifier] {
                    guard prior == message else { throw CodexAppServerWireError.invalidEnvelope }
                    return .duplicateRequest
                } else {
                    guard serverRequests.count < Self.maximumServerRequests else {
                        throw CodexAppServerWireError.capacityExceeded
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

    /// Response IDs are scoped to this connection. Callers must additionally
    /// validate task/attempt/thread/turn ownership before invoking this method.
    /// Unsupported methods use reject, never a permissive default answer.
    mutating func answer(
        _ identifier: CodexAppServerRequestID,
        result: AgentEventJSON,
        write: (Data) throws -> Void
    ) throws {
        try respond(identifier, response: .response(identifier, result: result), write: write)
    }

    mutating func reject(
        _ identifier: CodexAppServerRequestID,
        write: (Data) throws -> Void
    ) throws {
        try respond(identifier, response: .failure(identifier, code: -32601), write: write)
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
                throw CodexAppServerWireError.capacityExceeded
            }
            let identifier = CodexAppServerRequestID.integer(nextID)
            nextID += 1
            let message = CodexAppServerMessage.request(identifier, method: method, params: params)
            let data = try message.encoded()
            guard data.count <= CodexAppServerFramer.maximumFrameBytes + 1 else {
                throw CodexAppServerWireError.frameTooLarge
            }
            pending[identifier] = method
            try write(data)
            return identifier
        } catch {
            close()
            throw error
        }
    }

    /// Called only after the task mapper has validated the resolution's
    /// connection/thread/request ownership. An answer already being written
    /// may race provider resolution; its eventual successful write can still be
    /// cached, while an unanswered resolved request becomes non-actionable.
    mutating func resolveServerRequest(_ identifier: CodexAppServerRequestID) throws {
        guard phase == .ready else { throw CodexAppServerWireError.invalidState }
        guard serverRequests[identifier] != nil else { return }
        if preparingResponses[identifier] != nil { return }
        guard responses.count + resolvedRequests.count + preparingResponses.count < Self.maximumRememberedResponses else {
            close()
            throw CodexAppServerWireError.capacityExceeded
        }
        serverRequests.removeValue(forKey: identifier)
        resolvedRequests.insert(identifier)
    }

    /// Async transports prepare bytes first, then confirm only after a
    /// successful physical pipe write. Redelivery during the write remains a
    /// duplicate pending request and cannot create another user prompt.
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
            throw CodexAppServerWireError.invalidState
        }
        preparingResponses.removeValue(forKey: prepared.identifier)
        serverRequests.removeValue(forKey: prepared.identifier)
        responses[prepared.identifier] = (prepared.request, prepared.response)
    }

    private mutating func prepareResponse(
        _ identifier: CodexAppServerRequestID,
        response: CodexAppServerMessage
    ) throws -> PreparedResponse {
        guard phase == .ready, let request = serverRequests[identifier], preparingResponses[identifier] == nil else {
            throw CodexAppServerWireError.invalidState
        }
        guard responses.count + preparingResponses.count + resolvedRequests.count < Self.maximumRememberedResponses else {
            close()
            throw CodexAppServerWireError.capacityExceeded
        }
        let bytes = try response.encoded()
        guard bytes.count <= CodexAppServerFramer.maximumFrameBytes + 1 else {
            close()
            throw CodexAppServerWireError.frameTooLarge
        }
        let token = UUID()
        preparingResponses[identifier] = token
        return PreparedResponse(bytes: bytes, identifier: identifier, token: token, request: request, response: response)
    }

    private mutating func respond(
        _ identifier: CodexAppServerRequestID,
        response: CodexAppServerMessage,
        write: (Data) throws -> Void
    ) throws {
        guard phase == .ready, serverRequests[identifier] != nil, preparingResponses[identifier] == nil else {
            throw CodexAppServerWireError.invalidState
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
