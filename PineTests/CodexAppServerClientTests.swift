import Foundation
import Testing
@testable import Pine

struct CodexAppServerClientTests {
    @Test func ownedHandshakeCorrelatedCallsAndExplicitStop() async throws {
        let fixture = try ClientFixture(mode: .echo)
        defer { fixture.peer.close() }
        try await fixture.client.start()
        let value = AgentEventJSON.object(["value": .string("fixture")])
        let reply = try await fixture.client.call(method: "fixture/echo", params: value)
        #expect(reply == value)
        await #expect(throws: CodexAppServerClientError.providerFailure(-32001)) {
            try await fixture.client.call(method: "fixture/error", params: .object([:]))
        }
        await fixture.client.stop(deadline: .now.advanced(by: .seconds(2)))
        await fixture.server.value
        await #expect(throws: CodexAppServerClientError.unavailable) {
            try await fixture.client.call(method: "fixture/echo", params: value)
        }
        await #expect(throws: CodexAppServerWireError.invalidState) { try await fixture.client.start() }
    }

    @Test func unknownServerRequestReceivesExplicitMethodError() async throws {
        let fixture = try ClientFixture(mode: .unknownRequest)
        defer { fixture.peer.close() }
        try await fixture.client.start()
        await fixture.server.value
        var iterator = fixture.client.events.makeAsyncIterator()
        guard case .disconnected? = await iterator.next() else {
            Issue.record("Unknown request was exposed as actionable or teardown was missing")
            return
        }
        await fixture.client.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func ownedPipeLossNeverStartsAnotherProvider() async throws {
        let launches = ClientLaunchCounter()
        let fixture = try ClientFixture(mode: .closeAfterInitialize, launches: launches)
        defer { fixture.peer.close() }
        try await fixture.client.start()
        var iterator = fixture.client.events.makeAsyncIterator()
        guard case .disconnected? = await iterator.next() else {
            Issue.record("Pipe loss did not become disconnected")
            return
        }
        #expect(await launches.count == 1)
        await #expect(throws: CodexAppServerWireError.invalidState) { try await fixture.client.start() }
        #expect(await launches.count == 1)
        await fixture.server.value
    }

    @Test func expiredSessionCannotLaunchAProvider() async {
        let client = CodexAppServerClient(sessionDeadline: .now) { _ in
            Issue.record("Expired client launched a child")
            throw CodexAppServerClientError.unavailable
        }
        await #expect(throws: CodexAppServerWireError.closed) { try await client.start() }
        await client.stop(deadline: .now.advanced(by: .seconds(2)))
    }

    @Test func stopDuringLaunchReturnsBeforeLateChildAndRetainsCleanupOwnership() async throws {
        let barrier = ClientLaunchBarrier()
        let fixture = try ClientFixture(mode: .echo, launchBarrier: barrier)
        defer { fixture.peer.close() }
        let startup = Task { try await fixture.client.start() }
        await barrier.waitForLaunch()
        await fixture.client.stop(deadline: .now.advanced(by: .seconds(2)))
        if case .success = await startup.result { Issue.record("Stopped startup became live") }
        // Startup has returned while the injected launch is still suspended.
        await barrier.releaseLaunch()
        await barrier.waitForCleanup()
        #expect(await barrier.cleanupCount == 1)
        await fixture.server.value
    }

}

nonisolated private struct ClientFixture: Sendable {
    enum Mode: Sendable { case echo, unknownRequest, closeAfterInitialize }
    let peer: CodexAppServerStdioChannel
    let client: CodexAppServerClient
    let server: Task<Void, Never>
    // Retain both ends not handed to channels until explicit fixture teardown.
    private let error: Pipe
    private let peerError: Pipe

    init(
        mode: Mode,
        launches: ClientLaunchCounter = ClientLaunchCounter(),
        launchBarrier: ClientLaunchBarrier? = nil
    ) throws {
        let input = Pipe()
        let output = Pipe()
        error = Pipe()
        peerError = Pipe()
        let channel = try CodexAppServerStdioChannel(
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading
        )
        let peer = try CodexAppServerStdioChannel(
            standardInput: output.fileHandleForWriting,
            standardOutput: input.fileHandleForReading,
            standardError: peerError.fileHandleForReading
        )
        self.peer = peer
        client = CodexAppServerClient(sessionDeadline: .now.advanced(by: .seconds(15))) { _ in
            await launches.record()
            await launchBarrier?.suspendLaunch()
            return CodexAppServerOwnedChild(channel: channel, stop: { _ in
                peer.close()
                await launchBarrier?.recordCleanup()
            })
        }
        server = Task { await Self.serve(peer, mode: mode) }
    }

    private static func serve(_ peer: CodexAppServerStdioChannel, mode: Mode) async {
        defer { peer.close() }
        do {
            while let message = try await peer.readNext(deadline: .now.advanced(by: .seconds(10))) {
                switch message {
                case .request(let identifier, "initialize", _):
                    try await peer.write(CodexAppServerMessage.response(identifier, result: .object([
                        "userAgent": .string("fixture")
                    ])).encoded(), deadline: .now.advanced(by: .seconds(5)))
                case .notification("initialized", _):
                    if mode == .closeAfterInitialize { return }
                    if mode == .unknownRequest {
                        try await peer.write(CodexAppServerMessage.request(
                            .string("future-request"), method: "future/execute", params: .object([:])
                        ).encoded(), deadline: .now.advanced(by: .seconds(5)))
                    }
                case .request(let identifier, "fixture/echo", let params):
                    try await peer.write(CodexAppServerMessage.response(identifier, result: params).encoded(),
                                         deadline: .now.advanced(by: .seconds(5)))
                case .request(let identifier, "fixture/error", _):
                    try await peer.write(CodexAppServerMessage.failure(identifier, code: -32001).encoded(),
                                         deadline: .now.advanced(by: .seconds(5)))
                case .failure(.string("future-request"), let code):
                    #expect(code == -32601)
                    return
                default: Issue.record("Unexpected protocol fixture traffic"); return
                }
            }
        } catch { /* Explicit client shutdown closes the peer pipe. */ }
    }
}

private actor ClientLaunchCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor ClientLaunchBarrier {
    private var entered = false
    private var released = false
    private(set) var cleanupCount = 0
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var launchWaiter: CheckedContinuation<Void, Never>?
    private var cleanupWaiter: CheckedContinuation<Void, Never>?

    func suspendLaunch() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { launchWaiter = $0 }
    }

    func waitForLaunch() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func releaseLaunch() {
        released = true
        launchWaiter?.resume()
        launchWaiter = nil
    }

    func recordCleanup() {
        cleanupCount += 1
        cleanupWaiter?.resume()
        cleanupWaiter = nil
    }

    func waitForCleanup() async {
        guard cleanupCount == 0 else { return }
        await withCheckedContinuation { cleanupWaiter = $0 }
    }
}
