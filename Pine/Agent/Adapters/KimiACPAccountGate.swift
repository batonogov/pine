import Foundation
import Synchronization

/// Account state observed from the `initialize` `authMethods` list. Transport
/// ownership (a supervised `kimi acp` pipe) never proves the provider account
/// is authenticated: this state only records whether the agent manages an
/// account that a separate observation must cover. No account ID, email,
/// token, provider path, or plan detail is retained.
nonisolated enum KimiACPAccountState: Equatable, Sendable {
    /// `authMethods` is non-empty; session creation requires a verified
    /// terminal-auth observation from the separate auth UI.
    case managedAccount
    /// No managed `authMethods`; provider configuration is external to the
    /// agent and remains unverified by Pine.
    case externalProvider
}

/// Generation-fenced observation of the separately owned terminal-auth flow
/// (`kimi acp --login` / `kimi login` in a Pine terminal). The auth UI owner
/// observes the flow's verified outcome and mints a digest from that outcome
/// — never from token bytes, which stay in Kimi's private home directory.
/// Each session start must present its own pre-read generation.
nonisolated final class KimiACPAccountAuthority: Sendable {
    struct ReadToken: Sendable { fileprivate let generation: UInt64 }
    private struct State: Sendable {
        var generation: UInt64 = 0
        var digest: String?
        var verified = false
        var closed = false
    }
    private let state = Mutex(State())
    private let required: Bool

    init(managedAccount: Bool) { required = managedAccount }

    /// A digest is a bounded hex rendering of the auth-flow outcome; it is not
    /// a credential and is never persisted by the adapter.
    func beginRead() throws -> ReadToken {
        try state.withLock { value in
            guard !value.closed else { throw KimiACPWireError.unavailable }
            value.verified = false
            return ReadToken(generation: value.generation)
        }
    }

    /// False requires a fresh observation; it never authorizes input or an
    /// automatic retry.
    func verify(_ digest: String, read: ReadToken) throws -> Bool {
        try state.withLock { value in
            guard !value.closed else { throw KimiACPWireError.unavailable }
            guard read.generation == value.generation else { return false }
            guard value.digest == nil || value.digest == digest else {
                value.verified = false
                value.closed = true
                throw KimiACPWireError.authenticationRequired
            }
            value.digest = digest
            value.verified = true
            return true
        }
    }

    /// The separate auth UI records a verified outcome (login flow succeeded
    /// or token state changed). This grants nothing by itself: the next start
    /// must read and re-verify.
    func observe(_ digest: String) -> Bool {
        state.withLock { value in
            value.verified = false
            value.digest = digest
            if value.generation == .max { value.closed = true } else { value.generation += 1 }
            return value.closed
        }
    }

    /// Fails closed when the agent manages an account that has no current
    /// verified observation.
    func validate() throws {
        try state.withLock { value in
            guard !value.closed else { throw KimiACPWireError.unavailable }
            guard !required || value.verified else { throw KimiACPWireError.authenticationRequired }
        }
    }

    func close() { state.withLock { $0.closed = true; $0.verified = false } }
}
