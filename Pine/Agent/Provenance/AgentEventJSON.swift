import Foundation

/// Untyped future evidence. Numbers are never routed through binary floating point.
nonisolated indirect enum AgentEventJSON: Sendable, Equatable, Codable {
    case object([String: AgentEventJSON])
    case array([AgentEventJSON])
    case string(String)
    case bool(Bool)
    case signed(Int64)
    case unsigned(UInt64)
    case decimal(Decimal)
    /// Exact validated spelling, including exponent/decimal notation used by
    /// the original writer's envelope digest (Double and Decimal differ).
    case number(String)
    case null

    enum Failure: Error {
        case unsupportedNumber
        case invalidJSON
        case requiresRawJSON
        case ambiguousObjectKeys
    }

    private static let treeKey = userInfoKey("pine.provenance.exactJSON")

    private static func userInfoKey(_ raw: String) -> CodingUserInfoKey {
        guard let key = CodingUserInfoKey(rawValue: raw) else { preconditionFailure("Invalid coding key") }
        return key
    }

    /// Foundation's Decimal decoder can silently round a JSON token. Capture
    /// tokens *before* Foundation sees them, then supply the exact tree to the
    /// payload decoder. All ordinary model/date decoding still uses Foundation.
    static func decode<T: Decodable>(
        _ type: T.Type, from data: Data, using decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        var parser = AgentEventJSONParser(data: data)
        let tree = try parser.parse()
        let previous = decoder.userInfo[treeKey]
        decoder.userInfo[treeKey] = tree
        defer { decoder.userInfo[treeKey] = previous }
        return try decoder.decode(type, from: data)
    }

    init(from decoder: Decoder) throws {
        if let root = decoder.userInfo[Self.treeKey] as? Self {
            var value = root
            for key in decoder.codingPath {
                switch value {
                case .object(let object):
                    guard let child = object[key.stringValue] else { throw Failure.invalidJSON }
                    value = child
                case .array(let array):
                    guard let index = key.intValue, array.indices.contains(index) else { throw Failure.invalidJSON }
                    value = array[index]
                default: throw Failure.invalidJSON
                }
            }
            self = value
            return
        }
        // Foundation can round numbers and collapse Unicode-equivalent object
        // keys before exposing a Decoder. Only a raw-validated tree is safe.
        throw Failure.requiresRawJSON
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .signed(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .decimal(let value):
            guard !value.isNaN else { throw Failure.unsupportedNumber }
            try container.encode(value)
        case .number(let raw): try Self.exactNumber(raw).encode(to: encoder)
        case .null: try container.encodeNil()
        }
    }

    var isFuturePayload: Bool {
        guard case .object(let object) = self,
              case .string(let kind) = object["kind"] else { return false }
        return !["none", "commandResult", "fileChange"].contains(kind)
    }

    static func numberToken(_ raw: String) throws -> Self {
        guard raw.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,
                        options: .regularExpression) != nil else { throw Failure.invalidJSON }
        return .number(raw)
    }

    /// Run only after the entire document passes JSON syntax validation, so
    /// unsupported evidence is distinguished from malformed/corrupt data.
    func validateRepresentation() throws {
        switch self {
        case .number(let raw): _ = try Self.exactNumber(raw)
        case .object(let values):
            for value in values.values { try value.validateRepresentation() }
        case .array(let values):
            for value in values { try value.validateRepresentation() }
        default: break
        }
    }

    /// Sorted object keys and exact numeric lexemes. Journal encoding uses
    /// this fragment instead of JSONEncoder's lossy numeric reformatting.
    func canonicalData() throws -> Data {
        switch self {
        case .object(let values):
            var members: [Data] = []
            // JSONEncoder.sortedKeys orders the original UTF-8, not Swift's
            // canonically-normalizing String comparison.
            for key in values.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                guard let value = values[key] else { throw Failure.invalidJSON }
                var member = try JSONEncoder().encode(key)
                member.append(58)
                member.append(try value.canonicalData())
                members.append(member)
            }
            return Self.join(members, open: 123, close: 125)
        case .array(let values):
            return try Self.join(values.map { try $0.canonicalData() }, open: 91, close: 93)
        case .number(let raw):
            _ = try Self.exactNumber(raw)
            return Data(raw.utf8)
        default:
            return try JSONEncoder().encode(self)
        }
    }

    private static func join(_ values: [Data], open: UInt8, close: UInt8) -> Data {
        var data = Data([open])
        for (index, value) in values.enumerated() {
            if index > 0 { data.append(44) }
            data.append(value)
        }
        data.append(close)
        return data
    }

    private static func exactNumber(_ raw: String) throws -> Self {
        guard raw.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,
                        options: .regularExpression) != nil else { throw Failure.invalidJSON }
        if let value = Int64(raw) { return .signed(value) }
        if let value = UInt64(raw) { return .unsigned(value) }
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN,
              try normalized(raw) == normalized(NSDecimalNumber(decimal: value).stringValue) else {
            throw Failure.unsupportedNumber
        }
        let canonical = NSDecimalNumber(decimal: value).stringValue
        if let integer = Int64(canonical) { return .signed(integer) }
        if let integer = UInt64(canonical) { return .unsigned(integer) }
        return .decimal(value)
    }

    /// Compare exact base-ten coefficient/exponent pairs, including values
    /// written with exponent notation. No Double conversion, even for bounds.
    private static func normalized(_ raw: String) throws -> String {
        var text = raw.lowercased()
        let negative = text.hasPrefix("-")
        if negative { text.removeFirst() }
        let parts = text.split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let exponent = parts.count == 2 ? Int(parts[1]) : 0,
              (-10_000...10_000).contains(exponent) else { throw Failure.unsupportedNumber }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let digits = mantissa.joined().drop(while: { $0 == "0" })
        if digits.isEmpty { return "0" }
        let significant = digits.reversed().drop(while: { $0 == "0" }).reversed()
        let scale = exponent - (mantissa.count == 2 ? mantissa[1].count : 0) + digits.count - significant.count
        return (negative ? "-" : "") + String(significant) + "e" + String(scale)
    }
}
