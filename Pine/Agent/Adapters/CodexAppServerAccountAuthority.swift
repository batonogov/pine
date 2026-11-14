import Foundation
import Synchronization

nonisolated final class CodexAppServerAccountAuthority: Sendable {
    struct ReadToken: Sendable { fileprivate let generation: UInt64 }
    private struct State: Sendable {
        var generation: UInt64 = 0
        var digest: String?
        var verified = false
        var hasInput = false
        var closed = false
    }
    private let state = Mutex(State())
    var hasInput: Bool { state.withLock { $0.hasInput } }
    func beginRead() throws -> ReadToken {
        try state.withLock { value in
            guard !value.closed else { throw CodexAppServerTaskError.accountChanged }
            value.verified = false
            return ReadToken(generation: value.generation)
        }
    }
    /// False requires a fresh metadata read; it never authorizes input or an
    /// automatic resend. Each response must carry its own pre-read generation.
    func verify(_ digest: String, read: ReadToken) throws -> Bool {
        try state.withLock { value in
            guard !value.closed else { throw CodexAppServerTaskError.accountChanged }
            guard read.generation == value.generation else { return false }
            guard value.digest == nil || value.digest == digest else {
                value.verified = false
                value.closed = true
                throw CodexAppServerTaskError.accountChanged
            }
            value.digest = digest
            value.verified = true
            return true
        }
    }
    func observeChange() -> Bool {
        state.withLock { value in
            value.verified = false
            if value.hasInput { value.closed = true }
            if value.generation == .max { value.closed = true } else { value.generation += 1 }
            return value.hasInput || value.closed
        }
    }
    func validate() throws {
        try state.withLock { guard !$0.closed, $0.verified else { throw CodexAppServerTaskError.accountChanged } }
    }
    func beginInput() throws {
        try state.withLock { value in
            guard !value.closed, value.verified else { throw CodexAppServerTaskError.accountChanged }
            value.hasInput = true
        }
    }
    func close() { state.withLock { $0.closed = true; $0.verified = false } }
}
