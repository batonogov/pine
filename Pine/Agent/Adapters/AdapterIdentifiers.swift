import Foundation

nonisolated enum AdapterValueError: Error, Equatable, Sendable {
    case empty(String)
    case tooLong(String, maximum: Int)
    case invalidCharacters(String)
    case invalidDisplayText
}

nonisolated protocol CanonicalAdapterIdentifier: Hashable, Sendable {
    var value: String { get }
    init(validating value: String) throws
}

nonisolated enum AdapterIdentifierValidation {
    static let maximumBytes = 96

    static func canonical(_ value: String, field: String) throws -> String {
        guard !value.isEmpty else { throw AdapterValueError.empty(field) }
        guard value.utf8.count <= maximumBytes else {
            throw AdapterValueError.tooLong(field, maximum: maximumBytes)
        }
        let bytes = Array(value.utf8)
        guard bytes.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 58
        }), bytes.first.map({ (97...122).contains($0) || (48...57).contains($0) }) == true,
           bytes.last.map({ (97...122).contains($0) || (48...57).contains($0) }) == true else {
            throw AdapterValueError.invalidCharacters(field)
        }
        return value
    }

    static func displayText(_ value: String) throws -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty, normalized.utf8.count <= 128,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && ![0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                           0x2066, 0x2067, 0x2068, 0x2069].contains(scalar.value)
                      && !scalar.properties.isDefaultIgnorableCodePoint
              }) else { throw AdapterValueError.invalidDisplayText }
        return normalized
    }
}

nonisolated struct AgentID: CanonicalAdapterIdentifier {
    let value: String
    init(validating value: String) throws {
        self.value = try AdapterIdentifierValidation.canonical(value, field: "agentID")
    }

    init(migratingLegacyStableIdentifier value: String) throws {
        guard ["claudeCode", "codex", "aider", "copilot", "pi"].contains(value) else {
            throw AdapterValueError.invalidCharacters("legacyAgentID")
        }
        self.value = value
    }
}

nonisolated struct AdapterID: CanonicalAdapterIdentifier {
    let value: String
    init(validating value: String) throws {
        self.value = try AdapterIdentifierValidation.canonical(value, field: "adapterID")
    }
}

nonisolated struct AdapterFactoryID: CanonicalAdapterIdentifier {
    let value: String
    init(validating value: String) throws {
        self.value = try AdapterIdentifierValidation.canonical(value, field: "factoryID")
    }
}

nonisolated struct ExecutableAlias: CanonicalAdapterIdentifier {
    let value: String
    init(validating value: String) throws {
        self.value = try AdapterIdentifierValidation.canonical(value, field: "executableAlias")
        guard !value.contains(":"), !value.contains(".") else {
            throw AdapterValueError.invalidCharacters("executableAlias")
        }
    }
}

nonisolated struct VendorReference: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    enum Role: String, Sendable { case conversation, turn, item, toolCall, request, event }
    let role: Role
    private(set) var rawValue: String

    init(role: Role, value: String) throws {
        guard !value.isEmpty else { throw AdapterValueError.empty("vendorReference") }
        guard value.utf8.count <= 256 else {
            throw AdapterValueError.tooLong("vendorReference", maximum: 256)
        }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw AdapterValueError.invalidCharacters("vendorReference")
        }
        self.role = role
        rawValue = value
    }

    var description: String { "<redacted:\(role.rawValue)>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

nonisolated struct AdapterResumePosition: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private(set) var rawValue: String
    init(_ value: String) throws {
        guard !value.isEmpty else { throw AdapterValueError.empty("resumePosition") }
        guard value.utf8.count <= 256 else {
            throw AdapterValueError.tooLong("resumePosition", maximum: 256)
        }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw AdapterValueError.invalidCharacters("resumePosition")
        }
        rawValue = value
    }
    var description: String { "<redacted:resume-position>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}
