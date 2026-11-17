import Foundation

/// Wire data remains untrusted until a registry-owned session validates its
/// source namespace, attempt, and task environment. Never log payloads:
/// assistant text, tool input, prompts, and transcripts are secret-bearing
/// and are not retained by any decoded value in this file. The bounded
/// (256 bytes or less) control_response error string is the only retained
/// text; it is an in-memory diagnostic category, never persisted or logged.
nonisolated enum ClaudeCodeWireError: Error, Equatable, Sendable {
    case invalidEnvelope, invalidIdentifier, invalidKind
    case frameTooLarge, nestingTooDeep, truncatedFrame
    case closed, capacityExceeded, invalidState, foreignSession
}

nonisolated struct ClaudeCodeControlRequestID: Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ClaudeCodeWireError.invalidIdentifier
        }
        self.value = value
    }

    init() { self.value = UUID().uuidString }

    var description: String { "<redacted:claude-request-id>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

/// Allowlisted tool-call metadata. Tool input and output content are never
/// retained; the shared model only needs the call identity and name.
nonisolated struct ClaudeCodeToolCall: Equatable, Sendable {
    let id: String
    let name: String
}

nonisolated struct ClaudeCodeToolResult: Equatable, Sendable {
    let toolUseID: String
    let isError: Bool
}

/// One allowlisted permission request. The provider-supplied `input` object,
/// `permission_suggestions`, and free-text reasons are not retained.
nonisolated struct ClaudeCodePermissionRequest: Equatable, Sendable {
    let id: ClaudeCodeControlRequestID
    let toolName: String
    let toolUseID: String
    let agentID: String?
}

nonisolated enum ClaudeCodeResultSubtype: String, Equatable, Sendable {
    case success
    case errorMaxTurns = "error_max_turns"
    case errorDuringExecution = "error_during_execution"
}

/// Interrupt receipt: the queue snapshot at interrupt time. The lists are
/// observations for the owner; nothing in Pine is resent automatically.
nonisolated struct ClaudeCodeInterruptReceipt: Equatable, Sendable {
    let stillQueued: [String]
    let cancelled: [String]
}

nonisolated enum ClaudeCodeStreamMessage: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case systemInit(
        sessionID: String,
        claudeCodeVersion: String?,
        permissionMode: String?,
        model: String?,
        capabilities: [String]?,
        account: ClaudeCodeStreamAccountState?
    )
    case assistant(sessionID: String, userMessageUUID: String?, toolCalls: [ClaudeCodeToolCall])
    case userToolResults(sessionID: String, results: [ClaudeCodeToolResult])
    case result(sessionID: String, subtype: ClaudeCodeResultSubtype)
    case permissionRequest(ClaudeCodePermissionRequest)
    case unsupportedControlRequest(id: ClaudeCodeControlRequestID, subtype: String)
    case controlResponseSuccess(
        requestID: ClaudeCodeControlRequestID,
        claudeCodeVersion: String?,
        account: ClaudeCodeStreamAccountState?,
        redeliveredPermissionRequests: [ClaudeCodePermissionRequest],
        userDialogRequestCount: Int,
        interruptReceipt: ClaudeCodeInterruptReceipt?
    )
    case controlResponseError(requestID: ClaudeCodeControlRequestID, message: String)
    case permissionDenied(toolUseID: String)
    case dataOnly(kind: String)

    var description: String { "<redacted:claude-stream-message>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    // MARK: Ingress parsing

    static func parse(data: Data) throws -> ClaudeCodeStreamMessage {
        var parser = AgentEventJSONParser(data: data)
        let tree: AgentEventJSON
        do {
            tree = try parser.parse()
        } catch {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        guard case .object(let fields) = tree,
              case .string(let type) = fields["type"] else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        switch type {
        case "system": return try parseSystem(fields)
        case "assistant": return try parseAssistant(fields)
        case "user": return try parseUser(fields)
        case "result": return try parseResult(fields)
        case "control_request": return try parseControlRequest(fields)
        case "control_response": return try parseControlResponse(fields)
        default:
            return .dataOnly(kind: try Self.boundedKind(type, maximum: 64))
        }
    }

    private static func parseSystem(_ fields: [String: AgentEventJSON]) throws -> ClaudeCodeStreamMessage {
        guard case .string(let subtype) = fields["subtype"] else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        switch subtype {
        case "init":
            let sessionID = try requiredString(fields["session_id"], maximum: 128)
            let capabilities: [String]?
            if let raw = fields["capabilities"] {
                guard case .array(let entries) = raw, entries.count <= 32 else {
                    throw ClaudeCodeWireError.invalidEnvelope
                }
                capabilities = try entries.map { entry in
                    guard case .string(let value) = entry, value.utf8.count <= 64,
                          !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    else {
                        throw ClaudeCodeWireError.invalidEnvelope
                    }
                    return value
                }
            } else {
                capabilities = nil
            }
            return .systemInit(
                sessionID: sessionID,
                claudeCodeVersion: try optionalString(fields["claude_code_version"], maximum: 32),
                permissionMode: try optionalString(fields["current_permission_mode"], maximum: 32),
                model: try optionalString(fields["model"], maximum: 128),
                capabilities: capabilities,
                account: ClaudeCodeStreamAccountState.observe(fields["account"])
            )
        case "permission_denied":
            // A denial without a recognizable tool identity reconciles
            // nothing; it stays data-only rather than fencing the stream.
            if let toolUseID = try optionalString(fields["tool_use_id"], maximum: 256) {
                return .permissionDenied(toolUseID: toolUseID)
            }
            return .dataOnly(kind: "permission_denied")
        default:
            return .dataOnly(kind: try boundedKind(subtype, maximum: 64))
        }
    }

    private static func parseAssistant(_ fields: [String: AgentEventJSON]) throws -> ClaudeCodeStreamMessage {
        let sessionID = try requiredString(fields["session_id"], maximum: 128)
        var toolCalls: [ClaudeCodeToolCall] = []
        if let message = fields["message"], case .object(let messageFields) = message,
           let content = messageFields["content"], case .array(let blocks) = content {
            guard blocks.count <= 128 else { throw ClaudeCodeWireError.capacityExceeded }
            for block in blocks {
                guard case .object(let blockFields) = block,
                      case .string(let blockType) = blockFields["type"] else { continue }
                guard blockType == "tool_use" else { continue } // Text is never retained.
                let id = try requiredString(blockFields["id"], maximum: 256)
                let name = try requiredString(blockFields["name"], maximum: 128)
                guard toolCalls.count < 64 else { throw ClaudeCodeWireError.capacityExceeded }
                toolCalls.append(ClaudeCodeToolCall(id: id, name: name))
            }
        }
        return .assistant(
            sessionID: sessionID,
            userMessageUUID: try optionalString(fields["user_message_uuid"], maximum: 256),
            toolCalls: toolCalls
        )
    }

    private static func parseUser(_ fields: [String: AgentEventJSON]) throws -> ClaudeCodeStreamMessage {
        let sessionID = try requiredString(fields["session_id"], maximum: 128)
        var results: [ClaudeCodeToolResult] = []
        if let message = fields["message"], case .object(let messageFields) = message,
           let content = messageFields["content"], case .array(let blocks) = content {
            guard blocks.count <= 128 else { throw ClaudeCodeWireError.capacityExceeded }
            for block in blocks {
                guard case .object(let blockFields) = block,
                      blockFields["type"] == .string("tool_result"),
                      let toolUseID = try optionalString(blockFields["tool_use_id"], maximum: 256) else {
                    continue
                }
                guard case .bool(let isError) = blockFields["is_error"] ?? .bool(false),
                      results.count < 64 else { throw ClaudeCodeWireError.invalidEnvelope }
                results.append(ClaudeCodeToolResult(toolUseID: toolUseID, isError: isError))
            }
        }
        return results.isEmpty ? .dataOnly(kind: "user") : .userToolResults(sessionID: sessionID, results: results)
    }

    private static func parseResult(_ fields: [String: AgentEventJSON]) throws -> ClaudeCodeStreamMessage {
        let sessionID = try requiredString(fields["session_id"], maximum: 128)
        guard case .string(let subtype) = fields["subtype"],
              let parsed = ClaudeCodeResultSubtype(rawValue: subtype) else {
            // An unclassified terminal frame fences the stream: the run ended
            // in a state Pine cannot map, and guessing would fabricate state.
            throw ClaudeCodeWireError.invalidEnvelope
        }
        return .result(sessionID: sessionID, subtype: parsed)
    }

    private static func parseControlRequest(_ fields: [String: AgentEventJSON]) throws -> ClaudeCodeStreamMessage {
        let id = try stringToID(fields["request_id"])
        guard case .object(let request) = fields["request"],
              case .string(let subtype) = request["subtype"] else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        guard subtype.utf8.count <= 64 else { throw ClaudeCodeWireError.invalidEnvelope }
        if subtype == "can_use_tool" {
            let toolName = try requiredString(request["tool_name"], maximum: 128)
            let toolUseID = try requiredString(request["tool_use_id"], maximum: 256)
            let agentID = try optionalString(request["agent_id"], maximum: 128)
            return .permissionRequest(ClaudeCodePermissionRequest(
                id: id, toolName: toolName, toolUseID: toolUseID, agentID: agentID
            ))
        }
        return .unsupportedControlRequest(id: id, subtype: try boundedKind(subtype, maximum: 64))
    }

    private static func parseControlResponse(_ fields: [String: AgentEventJSON]) throws -> ClaudeCodeStreamMessage {
        guard case .object(let response) = fields["response"],
              case .string(let subtype) = response["subtype"] else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        let id = try stringToID(response["request_id"])
        guard subtype == "success" || subtype == "error" else { throw ClaudeCodeWireError.invalidEnvelope }
        if subtype == "error" {
            let message = try requiredString(response["error"], maximum: 256)
            return .controlResponseError(requestID: id, message: message)
        }
        guard case .object(let payload) = response["response"] else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        var redelivered: [ClaudeCodePermissionRequest] = []
        if let pending = response["pending_permission_requests"] {
            guard case .array(let entries) = pending, entries.count <= 32 else {
                throw ClaudeCodeWireError.capacityExceeded
            }
            for entry in entries {
                guard case .object(let entryFields) = entry else { throw ClaudeCodeWireError.invalidEnvelope }
                redelivered.append(try Self.parseRedeliveredPermission(entryFields))
            }
        }
        let dialogCount: Int
        if let dialogs = response["pending_user_dialog_requests"] {
            guard case .array(let entries) = dialogs, entries.count <= 32 else {
                throw ClaudeCodeWireError.capacityExceeded
            }
            dialogCount = entries.count
            // Entries are user-dialog requests whose shape is not exercised in
            // this slice; they stay data-only and grant no state.
        } else {
            dialogCount = 0
        }
        let receipt: ClaudeCodeInterruptReceipt?
        if let queued = payload["still_queued"] {
            guard case .array(let queuedEntries) = queued, queuedEntries.count <= 32 else {
                throw ClaudeCodeWireError.capacityExceeded
            }
            let stillQueued = try Self.boundedStringArray(queuedEntries, maximum: 256)
            let cancelled: [String]
            if let rawCancelled = payload["cancelled"] {
                guard case .array(let cancelledEntries) = rawCancelled, cancelledEntries.count <= 32 else {
                    throw ClaudeCodeWireError.capacityExceeded
                }
                cancelled = try Self.boundedStringArray(cancelledEntries, maximum: 256)
            } else {
                cancelled = []
            }
            receipt = ClaudeCodeInterruptReceipt(stillQueued: stillQueued, cancelled: cancelled)
        } else {
            receipt = nil
        }
        return .controlResponseSuccess(
            requestID: id,
            claudeCodeVersion: try optionalString(payload["claude_code_version"], maximum: 32),
            account: ClaudeCodeStreamAccountState.observe(payload["account"]),
            redeliveredPermissionRequests: redelivered,
            userDialogRequestCount: dialogCount,
            interruptReceipt: receipt
        )
    }

    private static func boundedStringArray(_ entries: [AgentEventJSON], maximum: Int) throws -> [String] {
        try entries.map { entry in
            guard case .string(let value) = entry, value.utf8.count <= maximum,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ClaudeCodeWireError.invalidEnvelope
            }
            return value
        }
    }

    /// A redelivered request of an unrecognized subtype is a wrapper Pine
    /// cannot audit; the envelope is rejected, not skipped.
    private static func parseRedeliveredPermission(
        _ entryFields: [String: AgentEventJSON]
    ) throws -> ClaudeCodePermissionRequest {
        let message = try parseControlRequest(entryFields)
        guard case .permissionRequest(let permission) = message else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        return permission
    }

    // MARK: Egress encoding

    static func userMessage(text: String, messageUUID: String?, sessionID: String?) throws -> Data {
        var fields: [String: AgentEventJSON] = [
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])])
            ])
        ]
        if let messageUUID { fields["uuid"] = .string(messageUUID) }
        if let sessionID { fields["session_id"] = .string(sessionID) }
        fields["parent_tool_use_id"] = .null
        return try encode(fields)
    }

    static func initializeRequest(id: ClaudeCodeControlRequestID) throws -> Data {
        try encode([
            "type": .string("control_request"),
            "request_id": .string(id.value),
            "request": .object(["subtype": .string("initialize")])
        ])
    }

    static func interruptRequest(id: ClaudeCodeControlRequestID, cancelQueued: Bool) throws -> Data {
        var request: [String: AgentEventJSON] = ["subtype": .string("interrupt")]
        if cancelQueued { request["cancel_queued"] = .bool(true) }
        return try encode([
            "type": .string("control_request"),
            "request_id": .string(id.value),
            "request": .object(request)
        ])
    }

    /// One-shot allow. `updated_input` is not generated in this slice; the
    /// call runs exactly as requested.
    static func permissionAllowResponse(id: ClaudeCodeControlRequestID, toolUseID: String) throws -> Data {
        try encode([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(id.value),
                "response": .object([
                    "behavior": .string("allow"),
                    "tool_use_id": .string(toolUseID)
                ])
            ])
        ])
    }

    /// One-shot deny. The message is fixed Pine text, never provider text.
    static func permissionDenyResponse(id: ClaudeCodeControlRequestID, toolUseID: String) throws -> Data {
        try encode([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(id.value),
                "response": .object([
                    "behavior": .string("deny"),
                    "message": .string("Denied in Pine."),
                    "tool_use_id": .string(toolUseID)
                ])
            ])
        ])
    }

    static func controlErrorResponse(id: ClaudeCodeControlRequestID, reason: String) throws -> Data {
        try encode([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("error"),
                "request_id": .string(id.value),
                "error": .string(reason)
            ])
        ])
    }

    private static func encode(_ fields: [String: AgentEventJSON]) throws -> Data {
        var data = try AgentEventJSON.object(fields).canonicalData()
        data.append(10)
        return data
    }

    // MARK: Validation helpers

    private static func boundedKind(_ value: String, maximum: Int) throws -> String {
        try requiredString(.string(value), maximum: maximum)
    }

    private static func requiredString(_ value: AgentEventJSON?, maximum: Int) throws -> String {
        guard case .string(let string) = value,
              !string.isEmpty, string.utf8.count <= maximum,
              !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        return string
    }

    private static func optionalString(_ value: AgentEventJSON?, maximum: Int) throws -> String? {
        guard let value else { return nil }
        guard value == .null else { return try requiredString(value, maximum: maximum) }
        return nil
    }

    private static func stringToID(_ value: AgentEventJSON?) throws -> ClaudeCodeControlRequestID {
        guard case .string(let string) = value else { throw ClaudeCodeWireError.invalidIdentifier }
        return try ClaudeCodeControlRequestID(string)
    }
}

/// Incremental bounded JSONL ingress. Delivery is synchronous so a slow
/// consumer bounds the provider via pipe backpressure instead of building an
/// unbounded decoded-message queue. Any failure permanently fences ingress.
nonisolated struct ClaudeCodeStreamFramer {
    static let maximumFrameBytes = 1_048_576
    static let maximumDepth = 64
    private var frame = Data()
    private(set) var isClosed = false

    mutating func receive(
        _ bytes: Data,
        deliver: (ClaudeCodeStreamMessage) throws -> Void
    ) throws {
        guard !isClosed else { throw ClaudeCodeWireError.closed }
        do {
            for byte in bytes {
                if byte == 10 {
                    guard !frame.isEmpty else { throw ClaudeCodeWireError.invalidEnvelope }
                    try validateDepth()
                    let message = try ClaudeCodeStreamMessage.parse(data: frame)
                    frame.removeAll(keepingCapacity: true)
                    try deliver(message)
                } else {
                    guard frame.count < Self.maximumFrameBytes else {
                        throw ClaudeCodeWireError.frameTooLarge
                    }
                    frame.append(byte)
                }
            }
        } catch {
            close()
            throw error
        }
    }

    mutating func finish() throws {
        let truncated = !frame.isEmpty
        close()
        if truncated { throw ClaudeCodeWireError.truncatedFrame }
    }

    mutating func close() {
        isClosed = true
        frame.removeAll(keepingCapacity: false)
    }

    private func validateDepth() throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in frame {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                }
            } else if byte == 34 {
                inString = true
            } else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= Self.maximumDepth else { throw ClaudeCodeWireError.nestingTooDeep }
            } else if byte == 125 || byte == 93 {
                depth -= 1
            }
        }
    }
}
