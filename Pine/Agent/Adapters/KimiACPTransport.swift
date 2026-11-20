import Foundation

/// Supplied only by the task's admitted, supervised child owner. This seam
/// launches nothing and grants no filesystem, provider, or billing authority.
/// The shared owned-stdio channel provides pipe supervision, one-message
/// backpressure, bounded framing, and secret-free stderr draining.
nonisolated protocol KimiACPTransport: Sendable {
    func read(deadline: ContinuousClock.Instant) async throws -> CodexAppServerMessage?
    func write(_ bytes: Data, deadline: ContinuousClock.Instant,
               beforeWrite: @escaping @Sendable () throws -> Void) async throws
    func validate() throws
    func close()
    func stop(deadline: ContinuousClock.Instant) async
}

/// Reuses the reviewed bounded JSONL pipe supervision of the shared owned-stdio ingress.
/// Egress strictness (`jsonrpc: "2.0"` on every frame) is enforced by
/// `KimiACPWire.encode`; the shared framer's optional-jsonrpc tolerance for
/// legacy Codex traffic tightens once the ACP `requireJSONRPCVersion` channel
/// seam from #1811 is linearized.
nonisolated struct KimiACPStdioTransport: KimiACPTransport, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var description: String { "<redacted:kimi-stdio>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    let channel: CodexAppServerStdioChannel
    let stopChild: @Sendable (ContinuousClock.Instant) async -> Void

    init(channel: CodexAppServerStdioChannel, authority: AgentAdapterControlAuthority,
         revokeOwnership: @escaping @Sendable () -> Void,
         stopChild: @escaping @Sendable (ContinuousClock.Instant) async -> Void) throws {
        self.channel = channel
        self.stopChild = stopChild
        try channel.installCloseObserver {
            authority.revoke()
            revokeOwnership()
        }
    }

    func read(deadline: ContinuousClock.Instant) async throws -> CodexAppServerMessage? {
        try await channel.readNext(deadline: deadline)
    }

    func write(_ bytes: Data, deadline: ContinuousClock.Instant,
               beforeWrite: @escaping @Sendable () throws -> Void) async throws {
        try await channel.write(bytes, deadline: deadline, beforeWrite: beforeWrite)
    }

    func validate() throws { try channel.validateOpen() }
    func close() { channel.close() }

    func stop(deadline: ContinuousClock.Instant) async {
        channel.close()
        await stopChild(deadline)
    }
}

/// The validated argument vector for `kimi acp`: the bare subcommand, never
/// permission-mode, hook, web, or auth-bypass flags.
enum KimiACPLaunchArguments {
    static let subcommand: [String] = ["acp"]
}
