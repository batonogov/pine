import Foundation

/// Wire data remains untrusted until a registry-owned session validates its
/// thread, turn, process incarnation, and task environment. Never log payloads.
nonisolated enum CodexAppServerWireError: Error, Equatable {
    case invalidEnvelope, invalidIdentifier, frameTooLarge, nestingTooDeep
    case truncatedFrame, closed, capacityExceeded, invalidState, foreignResponse
}

nonisolated enum CodexAppServerRequestID: Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case integer(Int64)
    case string(String)

    var description: String { "<redacted:codex-request-id>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    init(_ value: AgentEventJSON) throws {
        switch value {
        case .number(let token):
            guard let integer = Int64(token), String(integer) == token else {
                throw CodexAppServerWireError.invalidIdentifier
            }
            self = .integer(integer)
        case .string(let string):
            guard !string.isEmpty, string.utf8.count <= 256,
                  !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CodexAppServerWireError.invalidIdentifier
            }
            self = .string(string)
        default: throw CodexAppServerWireError.invalidIdentifier
        }
    }

    var json: AgentEventJSON {
        switch self {
        case .integer(let value): .number(String(value))
        case .string(let value): .string(value)
        }
    }
}

nonisolated enum CodexAppServerMessage: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case request(CodexAppServerRequestID, method: String, params: AgentEventJSON)
    case notification(method: String, params: AgentEventJSON)
    case response(CodexAppServerRequestID, result: AgentEventJSON)
    case failure(CodexAppServerRequestID, code: Int64)

    var description: String { "<redacted:codex-wire-message>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    init(data: Data) throws {
        var parser = AgentEventJSONParser(data: data)
        guard case .object(let fields) = try parser.parse(),
              fields["jsonrpc"] == nil || fields["jsonrpc"] == .string("2.0") else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        if let methodValue = fields["method"] {
            guard case .string(let method) = methodValue,
                  !method.isEmpty, method.utf8.count <= 256,
                  method.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  fields["result"] == nil, fields["error"] == nil else {
                throw CodexAppServerWireError.invalidEnvelope
            }
            let params = fields["params"] ?? .object([:])
            guard case .object = params else { throw CodexAppServerWireError.invalidEnvelope }
            if let identifier = fields["id"] {
                self = .request(try CodexAppServerRequestID(identifier), method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
        } else {
            guard let identifier = fields["id"],
                  (fields["result"] != nil) != (fields["error"] != nil) else {
                throw CodexAppServerWireError.invalidEnvelope
            }
            let requestID = try CodexAppServerRequestID(identifier)
            if let result = fields["result"] {
                self = .response(requestID, result: result)
            } else {
                guard case .object(let error) = fields["error"],
                      case .number(let code) = error["code"], let integer = Int64(code),
                      case .string = error["message"] else {
                    throw CodexAppServerWireError.invalidEnvelope
                }
                self = .failure(requestID, code: integer)
            }
        }
    }

    func encoded() throws -> Data {
        let fields: [String: AgentEventJSON]
        switch self {
        case .request(let identifier, let method, let params):
            fields = ["id": identifier.json, "method": .string(method), "params": params]
        case .notification(let method, let params):
            fields = ["method": .string(method), "params": params]
        case .response(let identifier, let result):
            fields = ["id": identifier.json, "result": result]
        case .failure(let identifier, let code):
            fields = ["id": identifier.json, "error": .object([
                "code": .number(String(code)), "message": .string("Unsupported request")
            ])]
        }
        var data = try AgentEventJSON.object(fields).canonicalData()
        data.append(10)
        return data
    }
}

/// Incremental bounded JSONL ingress. Delivery is synchronous to avoid an
/// unbounded array of decoded messages. Any failure permanently fences ingress.
nonisolated struct CodexAppServerFramer {
    static let maximumFrameBytes = 1_048_576
    static let maximumDepth = 64
    private var frame = Data()
    private(set) var isClosed = false

    mutating func receive(
        _ bytes: Data,
        deliver: (CodexAppServerMessage) throws -> Void
    ) throws {
        guard !isClosed else { throw CodexAppServerWireError.closed }
        do {
            for byte in bytes {
                if byte == 10 {
                    guard !frame.isEmpty else { throw CodexAppServerWireError.invalidEnvelope }
                    try validateDepth()
                    let message = try CodexAppServerMessage(data: frame)
                    frame.removeAll(keepingCapacity: true)
                    try deliver(message)
                } else {
                    guard frame.count < Self.maximumFrameBytes else {
                        throw CodexAppServerWireError.frameTooLarge
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
        if truncated { throw CodexAppServerWireError.truncatedFrame }
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
                guard depth <= Self.maximumDepth else { throw CodexAppServerWireError.nestingTooDeep }
            } else if byte == 125 || byte == 93 {
                depth -= 1
            }
        }
    }
}
