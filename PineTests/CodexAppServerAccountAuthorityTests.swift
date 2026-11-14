import Foundation
import Synchronization
import Testing
@testable import Pine

struct CodexAppServerAccountAuthorityTests {
    @Test func freshMetadataReadCanRecoverBootstrapButOldResponseCannot() throws {
        let authority = CodexAppServerAccountAuthority()
        let stale = try authority.beginRead()
        #expect(!authority.observeChange())
        #expect(try authority.verify("fixture-account", read: stale) == false)
        #expect(throws: CodexAppServerTaskError.accountChanged) { try authority.beginInput() }
        let fresh = try authority.beginRead()
        #expect(try authority.verify("fixture-account", read: fresh))
        try authority.beginInput()
        #expect(authority.observeChange())
        #expect(throws: CodexAppServerTaskError.accountChanged) { try authority.beginRead() }
        #expect(throws: CodexAppServerTaskError.accountChanged) { try authority.validate() }
    }

    @Test func differentAccountIdentityCannotKeepPreviousCachedAuthority() throws {
        let authority = CodexAppServerAccountAuthority()
        #expect(try authority.verify("fixture-account-a", read: authority.beginRead()))
        let read = try authority.beginRead()
        #expect(throws: CodexAppServerTaskError.accountChanged) { try authority.verify("fixture-account-b", read: read) }
        #expect(throws: CodexAppServerTaskError.accountChanged) { try authority.beginInput() }
    }

    @Test func accountChangeBeforeStaleReadResponseCannotAuthorizeFirstModelInput() async throws {
        let authority = CodexAppServerAccountAuthority()
        #expect(try authority.verify("fixture-account", read: authority.beginRead()))
        let fixture = try AccountAuthorityFixture(authority: authority)
        defer { fixture.peer.close() }
        try await fixture.client.start()
        await #expect(throws: CodexAppServerTaskError.accountChanged) {
            let read = try authority.beginRead()
            _ = try await fixture.client.call(method: "account/read", params: .object(["refreshToken": .bool(false)]))
            // The old read response arrives after account/updated. It cannot
            // bless input with the account identity captured before that event.
            guard try authority.verify("fixture-account", read: read) else { throw CodexAppServerTaskError.accountChanged }
            _ = try await fixture.client.call(method: "fixture/modelInput", params: .object([:]), beforeDispatch: {
                try authority.beginInput()
            })
        }
        await fixture.client.stop(deadline: .now.advanced(by: .seconds(2)))
        await fixture.server.value
        #expect(fixture.inputs.receivedInputs == 0)
    }
}

nonisolated private struct AccountAuthorityFixture: Sendable {
    let client: CodexAppServerClient
    let peer: CodexAppServerStdioChannel
    let server: Task<Void, Never>
    let inputs: AccountInputCounter
    private let error: Pipe
    private let peerError: Pipe

    init(authority: CodexAppServerAccountAuthority) throws {
        let input = Pipe()
        let output = Pipe()
        error = Pipe()
        peerError = Pipe()
        let inputs = AccountInputCounter()
        self.inputs = inputs
        let channel = try CodexAppServerStdioChannel(standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading, standardError: error.fileHandleForReading)
        let peer = try CodexAppServerStdioChannel(standardInput: output.fileHandleForWriting,
            standardOutput: input.fileHandleForReading, standardError: peerError.fileHandleForReading)
        self.peer = peer
        client = CodexAppServerClient(sessionDeadline: .now.advanced(by: .seconds(15)),
            accountChanged: { authority.observeChange() }, launch: { _ in
                CodexAppServerOwnedChild(channel: channel, stop: { _ in peer.close() })
            })
        server = Task {
            defer { peer.close() }
            do {
                while let message = try await peer.readNext(deadline: .now.advanced(by: .seconds(10))) {
                    switch message {
                    case .request(let id, "initialize", _):
                        try await Self.write(.response(id, result: .object(["userAgent": .string("fixture")])), to: peer)
                    case .notification("initialized", _): break
                    case .request(let id, "account/read", _):
                        try await Self.write(.notification(method: "account/updated", params: .object([:])), to: peer)
                        try await Self.write(.response(id, result: .object([:])), to: peer)
                    case .request(let id, "fixture/modelInput", _):
                        inputs.record()
                        try await Self.write(.response(id, result: .object([:])), to: peer)
                    default: Issue.record("Unexpected account fixture traffic"); return
                    }
                }
            } catch { /* Explicit owner shutdown closes the peer. */ }
        }
    }

    private static func write(_ message: CodexAppServerMessage, to peer: CodexAppServerStdioChannel) async throws {
        try await peer.write(message.encoded(), deadline: .now.advanced(by: .seconds(5)))
    }
}

nonisolated private final class AccountInputCounter: Sendable {
    private let value = Mutex(0)
    var receivedInputs: Int { value.withLock { $0 } }
    func record() { value.withLock { $0 += 1 } }
}
