import Foundation

/// Bounded raw JSON parsing for identity-sensitive unknown evidence. Foundation
/// is used only for string unescaping, never for numbers or object-key storage.
nonisolated struct AgentEventJSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var hasAmbiguousKeys = false

    init(data: Data) { bytes = Array(data) }

    mutating func parse() throws -> AgentEventJSON {
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw AgentEventJSON.Failure.invalidJSON }
        if hasAmbiguousKeys { throw AgentEventJSON.Failure.ambiguousObjectKeys }
        try value.validateRepresentation()
        return value
    }

    private mutating func parseValue(depth: Int) throws -> AgentEventJSON {
        skipWhitespace()
        guard depth < 512, index < bytes.count else { throw AgentEventJSON.Failure.invalidJSON }
        switch bytes[index] {
        case 123: return try parseObject(depth: depth + 1)
        case 91: return try parseArray(depth: depth + 1)
        case 34: return .string(try parseString())
        case 116: try consume("true"); return .bool(true)
        case 102: try consume("false"); return .bool(false)
        case 110: try consume("null"); return .null
        case 45, 48...57:
            let start = index
            while index < bytes.count, ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[index]) {
                index += 1
            }
            guard let raw = String(bytes: bytes[start..<index], encoding: .utf8) else {
                throw AgentEventJSON.Failure.invalidJSON
            }
            return try AgentEventJSON.numberToken(raw)
        default: throw AgentEventJSON.Failure.invalidJSON
        }
    }

    private mutating func parseObject(depth: Int) throws -> AgentEventJSON {
        index += 1
        skipWhitespace()
        var values: [String: AgentEventJSON] = [:]
        if take(125) { return .object(values) }
        while true {
            skipWhitespace()
            let key = try parseString()
            // String equality deliberately catches both exact duplicates and
            // distinct UTF-8 keys that Swift would canonically alias. Never
            // silently overwrite one identity-sensitive member with another.
            let duplicate = values[key] != nil
            hasAmbiguousKeys = hasAmbiguousKeys || duplicate
            skipWhitespace()
            guard take(58) else { throw AgentEventJSON.Failure.invalidJSON }
            let value = try parseValue(depth: depth)
            if !duplicate { values[key] = value }
            skipWhitespace()
            if take(125) { return .object(values) }
            guard take(44) else { throw AgentEventJSON.Failure.invalidJSON }
        }
    }

    private mutating func parseArray(depth: Int) throws -> AgentEventJSON {
        index += 1
        skipWhitespace()
        var values: [AgentEventJSON] = []
        if take(93) { return .array(values) }
        while true {
            values.append(try parseValue(depth: depth))
            skipWhitespace()
            if take(93) { return .array(values) }
            guard take(44) else { throw AgentEventJSON.Failure.invalidJSON }
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard take(34) else { throw AgentEventJSON.Failure.invalidJSON }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
        }
        throw AgentEventJSON.Failure.invalidJSON
    }

    private mutating func consume(_ text: String) throws {
        for byte in text.utf8 {
            guard take(byte) else { throw AgentEventJSON.Failure.invalidJSON }
        }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
    }
}
