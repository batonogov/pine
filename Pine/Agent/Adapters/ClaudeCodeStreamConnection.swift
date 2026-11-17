import Foundation

/// Connection-local protocol bookkeeping for one owned Claude CLI child. This
/// is not registry authority, account authentication, or task readiness. A
/// new process always creates a new instance; session binding and fencing
/// keep nested, foreign, and stale events out.
nonisolated struct ClaudeCodeStreamConnection {
    enum Phase: Equatable, Sendable { case fresh, initializing, ready, closed }
    enum Delivery: Equatable, Sendable {
        case controlResponseSuccess(
            requestID: ClaudeCodeControlRequestID,
            claudeCodeVersion: String?,
            account: ClaudeCodeStreamAccountState?,
            redelivered: [ClaudeCodePermissionRequest],
            userDialogRequestCount: Int,
            interruptReceipt: ClaudeCodeInterruptReceipt?
        )
        case controlResponseError(requestID: ClaudeCodeControlRequestID, message: String)
        case serverRequest(ClaudeCodePermissionRequest)
        case unsupportedControlRequest(id: ClaudeCodeControlRequestID, subtype: String)
        case message(ClaudeCodeStreamMessage)
        case duplicateRequest
        case replayedResponse
        case ignoredForeignSession
    }

    struct PreparedResponse: Sendable {
        let bytes: Data
        fileprivate let requestID: ClaudeCodeControlRequestID
        fileprivate let token: UUID
        fileprivate let request: ClaudeCodePermissionRequest
        fileprivate let response: Data
    }

    static let maximumPendingControlRequests = 32
    static let maximumServerRequests = 32
    static let maximumRememberedResponses = 64

    let identity: UUID
    private(set) var phase: Phase = .fresh
    private(set) var sessionID: String?
    private var pendingControl: [ClaudeCodeControlRequestID: String] = [:]
    private var serverRequests: [ClaudeCodeControlRequestID: ClaudeCodePermissionRequest] = [:]
    private var preparingResponses: [ClaudeCodeControlRequestID: UUID] = [:]
    private var resolvedRequests: Set<ClaudeCodeControlRequestID> = []
    private var remembered: [ClaudeCodeControlRequestID: (request: ClaudeCodePermissionRequest, response: Data)] = [:]

    init(identity: UUID = UUID()) { self.identity = identity }

    /// Sends the minimal `initialize` control request. Successful handshake is
    /// the response, not this write: a failed write can have reached the CLI,
    /// so no automatic retry is possible.
    @discardableResult
    mutating func initialize(write: (Data) throws -> Void) throws -> ClaudeCodeControlRequestID {
        guard phase == .fresh else { throw ClaudeCodeWireError.invalidState }
        phase = .initializing
        return try sendControl("initialize", write: write) {
            try ClaudeCodeStreamMessage.initializeRequest(id: $0)
        }
    }

    @discardableResult
    mutating func sendInterrupt(
        cancelQueued: Bool,
        write: (Data) throws -> Void
    ) throws -> ClaudeCodeControlRequestID {
        guard phase != .closed else { throw ClaudeCodeWireError.closed }
        guard phase == .ready else { throw ClaudeCodeWireError.invalidState }
        return try sendControl("interrupt", write: write) {
            try ClaudeCodeStreamMessage.interruptRequest(id: $0, cancelQueued: cancelQueued)
        }
    }

    private mutating func sendControl(
        _ method: String,
        write: (Data) throws -> Void,
        encode: (ClaudeCodeControlRequestID) throws -> Data
    ) throws -> ClaudeCodeControlRequestID {
        do {
            guard phase != .closed else { throw ClaudeCodeWireError.closed }
            guard pendingControl.count < Self.maximumPendingControlRequests else {
                throw ClaudeCodeWireError.capacityExceeded
            }
            let id = ClaudeCodeControlRequestID()
            let bytes = try encode(id)
            guard bytes.count <= ClaudeCodeStreamFramer.maximumFrameBytes + 1 else {
                throw ClaudeCodeWireError.frameTooLarge
            }
            pendingControl[id] = method
            try write(bytes)
            return id
        } catch {
            close()
            throw error
        }
    }

    mutating func receive(
        _ message: ClaudeCodeStreamMessage,
        write: (Data) throws -> Void
    ) throws -> Delivery {
        guard phase != .closed else { throw ClaudeCodeWireError.closed }
        do {
            // Session fencing: the first observed session identity binds this
            // connection; anything else is foreign (nested/foreign/stale).
            if let observed = Self.sessionID(of: message) {
                if let bound = sessionID {
                    guard bound == observed else { return .ignoredForeignSession }
                } else {
                    sessionID = observed
                }
            }

            switch message {
            case let .controlResponseSuccess(id, version, account, redelivered, dialogCount, receipt):
                guard let method = pendingControl.removeValue(forKey: id) else {
                    throw ClaudeCodeWireError.invalidEnvelope
                }
                if method == "initialize" {
                    guard phase == .initializing else { throw ClaudeCodeWireError.invalidState }
                    phase = .ready
                } else {
                    guard phase == .ready else { throw ClaudeCodeWireError.invalidState }
                }
                return .controlResponseSuccess(
                    requestID: id, claudeCodeVersion: version, account: account,
                    redelivered: redelivered, userDialogRequestCount: dialogCount,
                    interruptReceipt: receipt
                )
            case let .controlResponseError(id, msg):
                guard pendingControl.removeValue(forKey: id) != nil else {
                    throw ClaudeCodeWireError.invalidEnvelope
                }
                if phase == .initializing { close() }
                return .controlResponseError(requestID: id, message: msg)
            case let .permissionRequest(request):
                guard phase == .ready else { throw ClaudeCodeWireError.invalidState }
                return try incomingPermission(request, write: write)
            case let .unsupportedControlRequest(id, subtype):
                guard phase == .ready else { throw ClaudeCodeWireError.invalidState }
                // Unknown control traffic is rejected, never answered
                // permissively; the payload is not retained.
                return .unsupportedControlRequest(id: id, subtype: subtype)
            case .systemInit, .assistant, .userToolResults, .result,
                 .permissionDenied, .dataOnly:
                guard phase == .ready else { throw ClaudeCodeWireError.invalidState }
                return .message(message)
            }
        } catch {
            close()
            throw error
        }
    }

    /// The adapter owner must validate task/attempt/session ownership before
    /// invoking this method. Responses are one-shot.
    mutating func answer(
        _ requestID: ClaudeCodeControlRequestID,
        allow: Bool,
        write: (Data) throws -> Void
    ) throws {
        do {
            let prepared = try prepareAnswer(requestID, allow: allow)
            try write(prepared.bytes)
            try confirmResponseWritten(prepared)
        } catch {
            close()
            throw error
        }
    }

    /// Handles one `pending_permission_requests` entry from an `initialize`
    /// response. These entries redeliver requests the process issued and has
    /// not resolved; a request Pine already answered replays the remembered
    /// response without a second user prompt.
    mutating func noteRedelivered(
        _ request: ClaudeCodePermissionRequest,
        write: (Data) throws -> Void
    ) throws -> Delivery {
        do {
            guard phase == .ready else { throw ClaudeCodeWireError.invalidState }
            return try incomingPermission(request, write: write)
        } catch {
            close()
            throw error
        }
    }

    /// Rejects a control request we will not answer (unsupported subtype,
    /// cancelled turn, lost ownership). Fixed Pine text only.
    mutating func reject(_ requestID: ClaudeCodeControlRequestID, write: (Data) throws -> Void) throws {
        guard phase == .ready else { throw ClaudeCodeWireError.invalidState }
        do {
            let bytes = try ClaudeCodeStreamMessage.controlErrorResponse(
                id: requestID, reason: "Request not supported by Pine."
            )
            if serverRequests[requestID] != nil, preparingResponses[requestID] == nil {
                let prepared = try prepare(requestID, bytes: bytes)
                try write(prepared.bytes)
                try confirmResponseWritten(prepared)
                return
            }
            // A response for an unknown or resolved request cannot be cached
            // against ownership; write once, remember nothing.
            try write(bytes)
        } catch {
            close()
            throw error
        }
    }

    /// Async transports prepare bytes first, then confirm only after a
    /// successful physical pipe write. Redelivery during the write remains a
    /// duplicate pending request and cannot create another user prompt.
    mutating func prepareAnswer(
        _ requestID: ClaudeCodeControlRequestID,
        allow: Bool
    ) throws -> PreparedResponse {
        let bytes = try permissionResponseBytes(requestID, allow: allow)
        return try prepare(requestID, bytes: bytes)
    }

    private func permissionResponseBytes(
        _ requestID: ClaudeCodeControlRequestID,
        allow: Bool
    ) throws -> Data {
        guard phase == .ready, let request = serverRequests[requestID] else {
            throw ClaudeCodeWireError.invalidState
        }
        return allow
            ? try ClaudeCodeStreamMessage.permissionAllowResponse(id: requestID, toolUseID: request.toolUseID)
            : try ClaudeCodeStreamMessage.permissionDenyResponse(id: requestID, toolUseID: request.toolUseID)
    }

    mutating func confirmResponseWritten(_ prepared: PreparedResponse) throws {
        guard phase == .ready,
              preparingResponses[prepared.requestID] == prepared.token,
              serverRequests[prepared.requestID] == prepared.request else {
            throw ClaudeCodeWireError.invalidState
        }
        preparingResponses.removeValue(forKey: prepared.requestID)
        serverRequests.removeValue(forKey: prepared.requestID)
        remembered[prepared.requestID] = (prepared.request, prepared.response)
    }

    /// Called only after the owner validated that the CLI resolved the
    /// request itself (tool result or permission denial). An answer still
    /// being written may race the resolution; its confirmed write is cached
    /// for replay, while an unanswered resolved request stays non-actionable.
    mutating func resolveRequest(_ requestID: ClaudeCodeControlRequestID) throws {
        guard phase == .ready else { throw ClaudeCodeWireError.invalidState }
        guard serverRequests[requestID] != nil else { return }
        if preparingResponses[requestID] != nil { return }
        guard remembered.count + resolvedRequests.count + preparingResponses.count
                < Self.maximumRememberedResponses else {
            close()
            throw ClaudeCodeWireError.capacityExceeded
        }
        serverRequests.removeValue(forKey: requestID)
        resolvedRequests.insert(requestID)
    }

    mutating func close() {
        phase = .closed
        sessionID = nil
        pendingControl.removeAll()
        serverRequests.removeAll()
        preparingResponses.removeAll()
        remembered.removeAll()
        resolvedRequests.removeAll()
    }

    private mutating func incomingPermission(
        _ request: ClaudeCodePermissionRequest,
        write: (Data) throws -> Void
    ) throws -> Delivery {
        if let rememberedResponse = remembered[request.id] {
            guard rememberedResponse.request == request else {
                throw ClaudeCodeWireError.invalidEnvelope
            }
            try write(rememberedResponse.response)
            // Duplicate delivery must not prompt the user again.
            return .replayedResponse
        }
        guard !resolvedRequests.contains(request.id) else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        if let prior = serverRequests[request.id] {
            guard prior == request else { throw ClaudeCodeWireError.invalidEnvelope }
            return .duplicateRequest
        } else {
            guard serverRequests.count < Self.maximumServerRequests else {
                throw ClaudeCodeWireError.capacityExceeded
            }
            serverRequests[request.id] = request
        }
        return .serverRequest(request)
    }

    private mutating func prepare(
        _ requestID: ClaudeCodeControlRequestID,
        bytes: Data
    ) throws -> PreparedResponse {
        guard phase == .ready, let request = serverRequests[requestID],
              preparingResponses[requestID] == nil else {
            throw ClaudeCodeWireError.invalidState
        }
        guard remembered.count + preparingResponses.count + resolvedRequests.count
                < Self.maximumRememberedResponses else {
            close()
            throw ClaudeCodeWireError.capacityExceeded
        }
        guard bytes.count <= ClaudeCodeStreamFramer.maximumFrameBytes + 1 else {
            close()
            throw ClaudeCodeWireError.frameTooLarge
        }
        let token = UUID()
        preparingResponses[requestID] = token
        return PreparedResponse(
            bytes: bytes, requestID: requestID, token: token,
            request: request, response: bytes
        )
    }

    private static func sessionID(of message: ClaudeCodeStreamMessage) -> String? {
        switch message {
        case let .systemInit(sessionID: value, _, _, _, _, _): return value
        case let .assistant(sessionID: value, _, _): return value
        case let .userToolResults(sessionID: value, _): return value
        case let .result(sessionID: value, _): return value
        case .permissionRequest, .unsupportedControlRequest,
             .controlResponseSuccess, .controlResponseError,
             .permissionDenied, .dataOnly:
            return nil
        }
    }
}
