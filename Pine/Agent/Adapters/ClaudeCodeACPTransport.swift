import Foundation

/// Supplied only by the task's admitted, supervised child owner. This seam
/// launches nothing and grants no filesystem, provider, or billing authority.
nonisolated protocol ClaudeCodeACPTransport: Sendable {
    func read(deadline: ContinuousClock.Instant) async throws -> CodexAppServerMessage?
    func write(_ bytes: Data, deadline: ContinuousClock.Instant,
               beforeWrite: @escaping @Sendable () throws -> Void) async throws
    func validate() throws
    func close()
    func stop(deadline: ContinuousClock.Instant) async
}

/// Reuses bounded JSONL framing/pipe supervision, not Codex RPC semantics.
/// Close fences the pipes synchronously; stop runs the owner's bounded cleanup.
nonisolated struct ClaudeCodeACPStdioTransport: ClaudeCodeACPTransport, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var description: String { "<redacted:claude-code-stdio>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    let channel: CodexAppServerStdioChannel
    let child: ClaudeCodeACPOwnedChild

    init(channel: CodexAppServerStdioChannel, authority: AgentAdapterControlAuthority,
         revokeOwnership: @escaping @Sendable () -> Void,
         child: ClaudeCodeACPOwnedChild) throws {
        guard channel.requiresJSONRPCVersion else { throw ClaudeCodeACPError.invalidProtocol }
        self.channel = channel
        self.child = child
        try channel.installCloseObserver {
            authority.revoke()
            revokeOwnership()
        }
    }

    /// Supervision-only seam (no registry authority): drives the real stdio
    /// stack in tests. The close observer performs no revocation.
    init(channel: CodexAppServerStdioChannel, child: ClaudeCodeACPOwnedChild) throws {
        guard channel.requiresJSONRPCVersion else { throw ClaudeCodeACPError.invalidProtocol }
        self.channel = channel
        self.child = child
        try channel.installCloseObserver { }
    }

    func read(deadline: ContinuousClock.Instant) async throws -> CodexAppServerMessage? {
        try await channel.readNext(deadline: deadline)
    }
    func write(_ bytes: Data, deadline: ContinuousClock.Instant,
               beforeWrite: @escaping @Sendable () throws -> Void) async throws {
        try await channel.write(bytes, deadline: deadline, beforeWrite: beforeWrite)
    }
    func validate() throws { try channel.validateOpen() }
    /// Fence the pipes immediately; registry invalidation schedules `stop`,
    /// which owns bounded process-group termination and reaping.
    func close() { child.close() }
    func stop(deadline: ContinuousClock.Instant) async {
        await child.stop(deadline)
    }
}

nonisolated enum ClaudeCodeACPError: Error, Equatable {
    case invalidState, invalidProtocol, unsupportedQuestion, invalidAnswer, capacity, unavailable
    case providerFailure(Int64)
}

nonisolated enum ClaudeCodeACPWire {
    static func encode(_ message: CodexAppServerMessage) throws -> Data {
        let encoded = try message.encoded()
        var parser = AgentEventJSONParser(data: encoded)
        guard case .object(var fields) = try parser.parse() else { throw ClaudeCodeACPError.invalidProtocol }
        fields["jsonrpc"] = .string("2.0")
        var bytes = try AgentEventJSON.object(fields).canonicalData()
        guard bytes.count <= CodexAppServerFramer.maximumFrameBytes else { throw ClaudeCodeACPError.capacity }
        bytes.append(10)
        return bytes
    }

    static func object(_ value: AgentEventJSON) throws -> [String: AgentEventJSON] {
        guard case .object(let fields) = value else { throw ClaudeCodeACPError.invalidProtocol }
        return fields
    }
    static func string(_ value: AgentEventJSON?) throws -> String {
        guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 4_096 else {
            throw ClaudeCodeACPError.invalidProtocol
        }
        return text
    }

    static func matches(_ value: AgentEventJSON?, string: String?) -> Bool {
        guard case .string(let value) = value, let string else { return false }
        return value.utf8.elementsEqual(string.utf8)
    }

    static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
