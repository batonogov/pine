//
//  LSPMessage.swift
//  Pine
//

import Foundation

// MARK: - JSON-RPC Base Types

/// JSON-RPC 2.0 request message for LSP communication.
struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: AnyCodable?

    init(id: Int, method: String, params: AnyCodable? = nil) {
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
    let params: AnyCodable?

    init(method: String, params: AnyCodable? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// JSON-RPC 2.0 response message.
struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: Int?
    let result: AnyCodable?
    let error: JSONRPCError?
}

/// JSON-RPC error object.
struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

// MARK: - Type-erased Codable wrapper

/// A type-erased Codable value for flexible JSON-RPC params/results.
struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Compare JSON serialized form for equality
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let lhsData = try? encoder.encode(lhs),
              let rhsData = try? encoder.encode(rhs) else {
            return false
        }
        return lhsData == rhsData
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

    /// Parses one LSP message from a data buffer.
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
        for i in data.startIndex...(data.count - 4) {
            if data[i] == separator[0] && data[i + 1] == separator[1]
                && data[i + 2] == separator[2] && data[i + 3] == separator[3] {
                return i
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
