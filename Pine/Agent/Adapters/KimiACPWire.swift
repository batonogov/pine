import Foundation

/// ACP v1 envelope discipline for the Kimi Code CLI (`kimi acp`, JSON-RPC over
/// stdio). Wire data is untrusted until the session and account gates validate
/// its conversation, capability, and request ownership. Never log payloads.
///
/// The shared owned-stdio ingress supplies bounded JSONL framing and pipe
/// supervision. This codec is Kimi-specific: every egress frame carries
/// `jsonrpc: "2.0"`, and all Kimi capability/agent validation is fail-closed.
nonisolated enum KimiACPWireError: Error, Equatable, Sendable {
    case invalidEnvelope
    case invalidProtocol
    case invalidSessionID
    case invalidAnswer
    case unsupportedCapability
    case capacity
    case invalidState
    case closed
    case foreignResponse
    case unavailable
    case authenticationRequired
    case providerFailure(Int64)
}

nonisolated enum KimiACPWire {
    static let maximumFrameBytes = CodexAppServerFramer.maximumFrameBytes

    /// Kimi egress always carries `jsonrpc: "2.0"`. The shared framer keeps the
    /// field optional for legacy Codex app-server traffic, so Kimi frames are
    /// re-serialized here to make the field mandatory.
    static func encode(_ message: CodexAppServerMessage) throws -> Data {
        let encoded = try message.encoded()
        var parser = AgentEventJSONParser(data: encoded)
        guard case .object(var fields) = try parser.parse() else {
            throw KimiACPWireError.invalidProtocol
        }
        fields["jsonrpc"] = .string("2.0")
        var bytes = try AgentEventJSON.object(fields).canonicalData()
        guard bytes.count <= Self.maximumFrameBytes else { throw KimiACPWireError.capacity }
        bytes.append(10)
        return bytes
    }

    static func object(_ value: AgentEventJSON) throws -> [String: AgentEventJSON] {
        guard case .object(let fields) = value else { throw KimiACPWireError.invalidProtocol }
        return fields
    }

    static func string(_ value: AgentEventJSON?) throws -> String {
        guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 4_096 else {
            throw KimiACPWireError.invalidProtocol
        }
        return text
    }

    static func boundedString(_ value: AgentEventJSON?, maximum: Int) throws -> String {
        guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= maximum,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw KimiACPWireError.invalidProtocol
        }
        return text
    }

    static func matches(_ value: AgentEventJSON?, string: String?) -> Bool {
        guard case .string(let value) = value, let string else { return false }
        return value.utf8.elementsEqual(string.utf8)
    }

    /// ACP `SessionId` is opaque; Kimi documents ULID-style IDs. Accept the
    /// conservative alphanumeric/dash/underscore subset without trusting it.
    static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// Parsed and validated `initialize` result. This proves transport capability
/// negotiation only: it is not account authentication, task readiness, or an
/// execution grant. No model, provider, token, or path detail is retained.
nonisolated struct KimiACPAgentIdentity: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Capabilities: Equatable, Sendable {
        let loadSession: Bool
        let image: Bool
        let embeddedContext: Bool
        let sessionResume: Bool
        let sessionFork: Bool
        let additionalDirectories: Bool
        let audio: Bool
    }
    let agentVersion: String
    let capabilities: Capabilities
    /// Non-empty `authMethods` means the agent manages an account; a
    /// separately observed terminal-auth result is required before sessions.
    let requiresAuthentication: Bool
    let authMethodCount: Int

    var description: String { "<redacted:kimi-agent-identity>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    /// `pinnedVersion` is the exact version the adapter admits: the gate is
    /// equality, not a floor (house norm: Codex pins its CLI exactly).
    init(response: AgentEventJSON, agentName: String, pinnedVersion: String) throws {
        let fields = try KimiACPWire.object(response)
        guard fields["protocolVersion"] == .number("1") else {
            throw KimiACPWireError.invalidProtocol
        }
        let agent = try KimiACPWire.object(fields["agentInfo"] ?? .null)
        guard agent["name"] == .string(agentName) else {
            throw KimiACPWireError.invalidProtocol
        }
        let version = try KimiACPWire.boundedString(agent["version"], maximum: 256)
        guard version == pinnedVersion else {
            throw KimiACPWireError.invalidProtocol
        }
        let caps = try KimiACPWire.object(fields["agentCapabilities"] ?? .null)
        let prompt = try KimiACPWire.object(caps["promptCapabilities"] ?? .null)
        let sessions = try KimiACPWire.object(caps["sessionCapabilities"] ?? .null)
        var authMethodCount = 0
        if let methods = fields["authMethods"], case .array(let values) = methods {
            guard values.count <= 16 else { throw KimiACPWireError.capacity }
            for value in values {
                let method = try KimiACPWire.object(value)
                _ = try KimiACPWire.boundedString(method["id"] ?? method["name"], maximum: 128)
                authMethodCount += 1
            }
        }
        capabilities = Capabilities(
            loadSession: caps["loadSession"] == .bool(true),
            image: prompt["image"] == .bool(true),
            embeddedContext: prompt["embeddedContext"] == .bool(true),
            sessionResume: sessions["resume"] != nil && sessions["resume"] != .null,
            sessionFork: sessions["fork"] != nil && sessions["fork"] != .null,
            additionalDirectories: sessions["additionalDirectories"] != nil
                && sessions["additionalDirectories"] != .null,
            // Audio is documented unsupported; retain the observed value so a
            // future matrix change is explicit instead of silent.
            audio: prompt["audio"] == .bool(true)
        )
        agentVersion = version
        requiresAuthentication = authMethodCount > 0
        self.authMethodCount = authMethodCount
    }
}

/// Bounded, dynamic `configOptions` from `session/new`|`load`|`resume`|`fork`
/// and `config_option_update`. ACP v1 option objects carry `id`, `name`, and
/// `type`. Unknown types are retained as opaque unknowns and never applied;
/// `boolean` is recorded but unsupported because Pine does not advertise
/// `session.configOptions.boolean`. These options grant nothing and Pine
/// never calls `session/set_config_option` in this slice.
nonisolated struct KimiACPConfigOption: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Kind: Equatable, Sendable { case select, boolean, unknown }
    let optionID: String
    let kind: Kind

    var description: String { "<redacted:kimi-config-option>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    init(option: [String: AgentEventJSON]) throws {
        optionID = try KimiACPWire.boundedString(option["id"], maximum: 256)
        let type = try KimiACPWire.boundedString(option["type"], maximum: 64)
        switch type {
        case "select": kind = .select
        case "boolean": kind = .boolean
        default: kind = .unknown
        }
    }
}

nonisolated enum KimiACPConfigOptions {
    static let maximumOptions = 32

    /// Absent or null is a valid empty set; a malformed array fails closed.
    static func parse(_ value: AgentEventJSON?) throws -> [KimiACPConfigOption] {
        guard let value, value != .null else { return [] }
        guard case .array(let options) = value else { throw KimiACPWireError.invalidProtocol }
        guard options.count <= maximumOptions else { throw KimiACPWireError.capacity }
        return try options.map { try KimiACPConfigOption(option: KimiACPWire.object($0)) }
    }
}
