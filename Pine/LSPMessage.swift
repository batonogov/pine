//
//  LSPMessage.swift
//  Pine
//

import Foundation

// MARK: - Type-safe JSON Value

/// A type-safe, Sendable replacement for type-erased JSON values in LSP communication.
///
/// Unlike a type-erased `Any` wrapper, `JSONValue` is a proper enum that:
/// - Is fully `Sendable` without `@unchecked` — safe to pass across concurrency domains
/// - Provides exhaustive pattern matching — the compiler catches unhandled cases
/// - Preserves value semantics — no hidden reference types or `Any` boxing
///
/// Trade-off: callers must pattern-match to extract values (e.g., `case .string(let s)`)
/// instead of casting from `Any`. This is intentional — it makes JSON handling explicit
/// and prevents runtime type mismatches.
enum JSONValue: Codable, Equatable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let dict = try? container.decode([String: JSONValue].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let val):
            try container.encode(val)
        case .int(let val):
            try container.encode(val)
        case .double(let val):
            try container.encode(val)
        case .string(let val):
            try container.encode(val)
        case .array(let val):
            try container.encode(val)
        case .object(let val):
            try container.encode(val)
        }
    }

    // MARK: - Convenience Initializers

    /// Creates a JSONValue from an untyped `Any` value (e.g., from JSONSerialization).
    /// Returns `.null` for unsupported types.
    init(_ value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let double as Double where !(value is Bool):
            self = .double(double)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue($0) })
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue($0) })
        default:
            self = .null
        }
    }

    /// Converts to untyped `Any` for interop (e.g., building JSON-RPC params from dictionaries).
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let val): return val
        case .int(let val): return val
        case .double(let val): return val
        case .string(let val): return val
        case .array(let val): return val.map(\.anyValue)
        case .object(let val): return val.mapValues(\.anyValue)
        }
    }

    // MARK: - Subscript Access

    /// Dictionary subscript for `.object` values.
    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self {
            return dict[key]
        }
        return nil
    }

    /// Array subscript for `.array` values.
    subscript(index: Int) -> JSONValue? {
        if case .array(let arr) = self, arr.indices.contains(index) {
            return arr[index]
        }
        return nil
    }

    // MARK: - ExpressibleBy Literals

    /// String value extraction.
    var stringValue: String? {
        if case .string(let val) = self { return val }
        return nil
    }

    /// Int value extraction.
    var intValue: Int? {
        if case .int(let val) = self { return val }
        return nil
    }

    /// Bool value extraction.
    var boolValue: Bool? {
        if case .bool(let val) = self { return val }
        return nil
    }

    /// Array value extraction.
    var arrayValue: [JSONValue]? {
        if case .array(let val) = self { return val }
        return nil
    }

    /// Dictionary value extraction.
    var objectValue: [String: JSONValue]? {
        if case .object(let val) = self { return val }
        return nil
    }
}

// MARK: - JSONValue Literal Conformances

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - JSON-RPC Base Types

/// JSON-RPC 2.0 request message for LSP communication.
struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: JSONValue?

    init(id: Int, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// JSON-RPC 2.0 notification (no id, no response expected).
struct JSONRPCNotification: Codable {
    let jsonrpc: String
    let method: String
    let params: JSONValue?

    init(method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// JSON-RPC 2.0 response message.
struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: Int?
    let result: JSONValue?
    let error: JSONRPCError?
}

/// JSON-RPC error object.
struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: JSONValue?
}

// MARK: - Unified JSON-RPC Message

/// A unified JSON-RPC message type that can represent requests, responses, and notifications.
/// Used for decoding incoming messages where the type is not known in advance.
struct JSONRPCMessage: Codable {
    let jsonrpc: String
    let id: Int?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: JSONRPCError?

    /// Whether this message is a server-initiated notification (has method, no id).
    var isNotification: Bool {
        method != nil && id == nil
    }

    /// Whether this message is a response to a request (has id, no method).
    var isResponse: Bool {
        id != nil
    }
}

// MARK: - LSP Message Encoding/Decoding

/// Handles LSP message framing (Content-Length header + JSON body).
enum LSPMessageCodec {

    /// Encodes a JSON-RPC request into LSP wire format with Content-Length header.
    static func encode(_ request: JSONRPCRequest) throws -> Data {
        let body = try JSONEncoder().encode(request)
        return frame(body)
    }

    /// Encodes a JSON-RPC notification into LSP wire format.
    static func encode(_ notification: JSONRPCNotification) throws -> Data {
        let body = try JSONEncoder().encode(notification)
        return frame(body)
    }

    /// Wraps JSON body with Content-Length header per LSP spec.
    static func frame(_ body: Data) -> Data {
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var result = Data(header.utf8)
        result.append(body)
        return result
    }

    /// Parses one LSP message from a data buffer using the unified message type.
    /// Returns (message, bytesConsumed) or nil if buffer is incomplete.
    static func decodeMessage(from buffer: Data) -> (JSONRPCMessage, Int)? {
        guard let headerEnd = findHeaderEnd(in: buffer) else { return nil }

        let headerData = buffer[buffer.startIndex..<headerEnd]
        guard let headerString = String(data: headerData, encoding: .utf8),
              let contentLength = parseContentLength(from: headerString) else {
            return nil
        }

        let bodyStart = headerEnd + 4 // skip \r\n\r\n
        let bodyEnd = bodyStart + contentLength

        guard buffer.count >= bodyEnd else { return nil }

        let bodyData = buffer[bodyStart..<bodyEnd]
        guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: bodyData) else {
            return nil
        }

        return (message, bodyEnd)
    }

    /// Parses one LSP message from a data buffer as a response.
    /// Returns (response, bytesConsumed) or nil if buffer is incomplete.
    static func decode(from buffer: Data) -> (JSONRPCResponse, Int)? {
        guard let headerEnd = findHeaderEnd(in: buffer) else { return nil }

        let headerData = buffer[buffer.startIndex..<headerEnd]
        guard let headerString = String(data: headerData, encoding: .utf8),
              let contentLength = parseContentLength(from: headerString) else {
            return nil
        }

        let bodyStart = headerEnd + 4 // skip \r\n\r\n
        let bodyEnd = bodyStart + contentLength

        guard buffer.count >= bodyEnd else { return nil }

        let bodyData = buffer[bodyStart..<bodyEnd]
        guard let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: bodyData) else {
            return nil
        }

        return (response, bodyEnd)
    }

    /// Finds the end of HTTP headers (position of first \r\n in \r\n\r\n).
    private static func findHeaderEnd(in data: Data) -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        guard data.count >= 4 else { return nil }
        for idx in data.startIndex...(data.count - 4) {
            if data[idx] == separator[0] && data[idx + 1] == separator[1]
                && data[idx + 2] == separator[2] && data[idx + 3] == separator[3] {
                return idx
            }
        }
        return nil
    }

    /// Extracts Content-Length value from header string.
    static func parseContentLength(from header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
               let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return length
            }
        }
        return nil
    }
}

// MARK: - LSP Initialize Types

/// Client capabilities sent during initialize handshake.
struct LSPClientCapabilities: Codable {
    let textDocument: TextDocumentClientCapabilities?

    init(textDocument: TextDocumentClientCapabilities? = TextDocumentClientCapabilities()) {
        self.textDocument = textDocument
    }
}

struct TextDocumentClientCapabilities: Codable {
    let completion: CompletionClientCapabilities?
    let synchronization: TextDocumentSyncClientCapabilities?

    init(
        completion: CompletionClientCapabilities? = CompletionClientCapabilities(),
        synchronization: TextDocumentSyncClientCapabilities? = TextDocumentSyncClientCapabilities()
    ) {
        self.completion = completion
        self.synchronization = synchronization
    }
}

struct CompletionClientCapabilities: Codable {
    let completionItem: CompletionItemCapabilities?

    init(completionItem: CompletionItemCapabilities? = CompletionItemCapabilities()) {
        self.completionItem = completionItem
    }
}

struct CompletionItemCapabilities: Codable {
    let snippetSupport: Bool

    init(snippetSupport: Bool = false) {
        self.snippetSupport = snippetSupport
    }
}

struct TextDocumentSyncClientCapabilities: Codable {
    let didSave: Bool
    let willSave: Bool

    init(didSave: Bool = true, willSave: Bool = false) {
        self.didSave = didSave
        self.willSave = willSave
    }
}

/// Parameters for the initialize request.
struct InitializeParams: Codable {
    let processId: Int
    let rootUri: String?
    let capabilities: LSPClientCapabilities

    init(rootUri: String?, capabilities: LSPClientCapabilities = LSPClientCapabilities()) {
        self.processId = Int(ProcessInfo.processInfo.processIdentifier)
        self.rootUri = rootUri
        self.capabilities = capabilities
    }
}

// MARK: - LSP TextDocument Types

/// Identifies a text document by its URI.
struct TextDocumentIdentifier: Codable {
    let uri: String
}

/// Full document info sent on didOpen.
struct TextDocumentItem: Codable {
    let uri: String
    let languageId: String
    let version: Int
    let text: String
}

/// Versioned document identifier for didChange.
struct VersionedTextDocumentIdentifier: Codable {
    let uri: String
    let version: Int
}

/// A content change event (full document sync).
struct TextDocumentContentChangeEvent: Codable {
    let text: String
}

/// Position in a text document (0-based line and character).
struct LSPPosition: Codable, Equatable {
    let line: Int
    let character: Int
}

/// A range in a text document.
struct LSPRange: Codable, Equatable {
    let start: LSPPosition
    let end: LSPPosition
}

// MARK: - Completion Types

/// Parameters for textDocument/completion.
struct CompletionParams: Codable {
    let textDocument: TextDocumentIdentifier
    let position: LSPPosition
}

/// A single completion item returned by the server.
struct CompletionItem: Codable, Equatable {
    let label: String
    let kind: Int?
    let detail: String?
    let insertText: String?

    init(label: String, kind: Int? = nil, detail: String? = nil, insertText: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.insertText = insertText
    }
}

/// Completion result — either an array or a CompletionList.
struct CompletionList: Codable {
    let isIncomplete: Bool
    let items: [CompletionItem]
}

/// Standard CompletionItemKind values from LSP spec.
enum CompletionItemKind: Int, Codable, Sendable {
    case text = 1
    case method = 2
    case function = 3
    case constructor = 4
    case field = 5
    case variable = 6
    case classKind = 7
    case interface = 8
    case module = 9
    case property = 10
    case unit = 11
    case value = 12
    case enumKind = 13
    case keyword = 14
    case snippet = 15
    case color = 16
    case file = 17
    case reference = 18
    case folder = 19
    case enumMember = 20
    case constant = 21
    case structKind = 22
    case event = 23
    case `operator` = 24
    case typeParameter = 25
}

// MARK: - LSP Diagnostic Types

/// A diagnostic message from the language server (e.g., errors, warnings).
struct LSPDiagnostic: Codable, Equatable {
    let range: LSPRange
    let severity: Int?
    let code: JSONValue?
    let source: String?
    let message: String

    /// Standard severity values from LSP spec.
    enum Severity: Int {
        case error = 1
        case warning = 2
        case information = 3
        case hint = 4
    }
}

/// Parameters for textDocument/publishDiagnostics notification.
struct PublishDiagnosticsParams: Codable, Equatable {
    let uri: String
    let diagnostics: [LSPDiagnostic]
}

/// Parameters for window/logMessage and window/showMessage notifications.
struct LogMessageParams: Codable, Equatable {
    let type: Int
    let message: String

    /// Standard message types from LSP spec.
    enum MessageType: Int {
        case error = 1
        case warning = 2
        case info = 3
        case log = 4
    }
}
