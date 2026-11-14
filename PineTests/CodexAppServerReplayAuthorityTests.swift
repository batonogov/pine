import Foundation
import Synchronization
import Testing
@testable import Pine

struct CodexAppServerReplayAuthorityTests {
    @Test func scopedResolutionDuringFirstWritePreflightCannotInstallReplayAuthority() async throws {
        let fixture = try ReplayAuthorityFixture()
        let barrier = ReplayWriteBarrier()
        defer { fixture.peer.close(); barrier.release() }
        try await fixture.client.start()
        var events = fixture.client.events.makeAsyncIterator()
        guard case .request(let id, _, _)? = await events.next() else { Issue.record("Approval missing"); return }
        let authority = ReplayGate()
        let answer = Task {
            try await fixture.client.answer(id, result: .object(["decision": .string("accept")]),
                replayAuthority: authority, beforeResponse: { try barrier.suspendWrite() })
        }
        let entered = await runOnBackground { barrier.waitUntilEntered() }
        #expect(entered)
        try await fixture.client.resolveServerRequest(id)
        barrier.release()
        if case .success = await answer.result { Issue.record("Resolved request wrote a late approval") }
        await fixture.client.stop(deadline: .now.advanced(by: .seconds(2)))
        await fixture.server.value
        #expect(fixture.capture.receivedResponses == 0)
    }

    @Test func activeDuplicateReusesWrittenAnswerWithoutAnotherActionableRequest() async throws {
        let fixture = try ReplayAuthorityFixture()
        defer { fixture.peer.close() }
        try await fixture.client.start()
        var events = fixture.client.events.makeAsyncIterator()
        guard case .request(let id, _, _)? = await events.next() else { Issue.record("Approval missing"); return }
        let authority = ReplayGate()
        try await fixture.client.answer(id, result: .object(["decision": .string("accept")]),
            replayAuthority: authority, beforeResponse: { try authority.validate() })
        var responses = fixture.capture.responses.makeAsyncIterator()
        #expect(await responses.next() == 1)
        try await fixture.peer.write(ReplayAuthorityFixture.question.encoded(), deadline: .now.advanced(by: .seconds(5)))
        #expect(await responses.next() == 2)
        await fixture.client.stop(deadline: .now.advanced(by: .seconds(2)))
        guard case .disconnected? = await events.next() else { Issue.record("Duplicate became actionable"); return }
        await fixture.server.value
    }

    @Test func cachedAnswerDoesNotKeepItsOwnerAlive() async throws {
        let fixture = try ReplayAuthorityFixture()
        defer { fixture.peer.close() }
        try await fixture.client.start()
        var events = fixture.client.events.makeAsyncIterator()
        guard case .request(let id, _, _)? = await events.next() else { Issue.record("Approval missing"); return }
        var authority: ReplayGate? = ReplayGate()
        let weakAuthority = WeakReplayGate(value: authority)
        do {
            let owner = try #require(authority)
            try await fixture.client.answer(id, result: .object(["decision": .string("accept")]),
                replayAuthority: owner, beforeResponse: {})
        }
        authority = nil
        #expect(weakAuthority.value == nil)
        var responses = fixture.capture.responses.makeAsyncIterator()
        #expect(await responses.next() == 1)
        try await fixture.peer.write(ReplayAuthorityFixture.question.encoded(), deadline: .now.advanced(by: .seconds(5)))
        #expect(await responses.next() == nil)
        await fixture.client.stop(deadline: .now.advanced(by: .seconds(2)))
        await fixture.server.value
        #expect(fixture.capture.receivedResponses == 1)
    }

    @Test func scopedResolutionFencesCachedAnswerEvenIfOwnerIsStillAlive() async throws {
        let fixture = try ReplayAuthorityFixture()
        defer { fixture.peer.close() }
        try await fixture.client.start()
        var events = fixture.client.events.makeAsyncIterator()
        guard case .request(let id, _, _)? = await events.next() else { Issue.record("Approval missing"); return }
        let authority = ReplayGate()
        try await fixture.client.answer(id, result: .object(["decision": .string("accept")]),
            replayAuthority: authority, beforeResponse: {})
        var responses = fixture.capture.responses.makeAsyncIterator()
        #expect(await responses.next() == 1)
        try await fixture.client.resolveServerRequest(id)
        try await fixture.peer.write(ReplayAuthorityFixture.question.encoded(), deadline: .now.advanced(by: .seconds(5)))
        #expect(await responses.next() == nil)
        await fixture.client.stop(deadline: .now.advanced(by: .seconds(2)))
        await fixture.server.value
        #expect(fixture.capture.receivedResponses == 1)
    }

    @Test func revokedAuthorityCannotReplayPreviouslyWrittenApproval() async throws {
        let fixture = try ReplayAuthorityFixture()
        defer { fixture.peer.close() }
        try await fixture.client.start()
        var events = fixture.client.events.makeAsyncIterator()
        guard case .request(let id, _, _)? = await events.next() else {
            Issue.record("Approval request missing")
            return
        }
        let authority = ReplayGate()
        try await fixture.client.answer(id, result: .object(["decision": .string("accept")]),
                                        replayAuthority: authority,
                                        beforeResponse: { try authority.validate() })
        var responses = fixture.capture.responses.makeAsyncIterator()
        #expect(await responses.next() == 1)
        authority.revoke()
        try await fixture.peer.write(ReplayAuthorityFixture.question.encoded(), deadline: .now.advanced(by: .seconds(5)))
        #expect(await responses.next() == nil)
        await fixture.client.stop(deadline: .now.advanced(by: .seconds(2)))
        await fixture.server.value
        #expect(fixture.capture.receivedResponses == 1)
    }
}

nonisolated private struct ReplayAuthorityFixture: Sendable {
    let client: CodexAppServerClient
    let peer: CodexAppServerStdioChannel
    let capture: ReplayCapture
    let server: Task<Void, Never>
    private let error: Pipe
    private let peerError: Pipe
    static var question: CodexAppServerMessage {
        .request(.string("fixture-approval"), method: "item/commandExecution/requestApproval", params: .object([
            "threadId": .string("fixture-thread"), "turnId": .string("fixture-turn"), "itemId": .string("fixture-item")
        ]))
    }

    init() throws {
        let input = Pipe()
        let output = Pipe()
        error = Pipe()
        peerError = Pipe()
        let channel = try CodexAppServerStdioChannel(standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading, standardError: error.fileHandleForReading)
        let peer = try CodexAppServerStdioChannel(standardInput: output.fileHandleForWriting,
            standardOutput: input.fileHandleForReading, standardError: peerError.fileHandleForReading)
        self.peer = peer
        let capture = ReplayCapture()
        self.capture = capture
        client = CodexAppServerClient(sessionDeadline: .now.advanced(by: .seconds(15))) { _ in
            CodexAppServerOwnedChild(channel: channel, stop: { _ in peer.close() })
        }
        server = Task {
            defer { peer.close(); capture.finish() }
            do {
                while let message = try await peer.readNext(deadline: .now.advanced(by: .seconds(10))) {
                    switch message {
                    case .request(let id, "initialize", _):
                        try await Self.write(.response(id, result: .object(["userAgent": .string("fixture")])), to: peer)
                    case .notification("initialized", _): try await Self.write(Self.question, to: peer)
                    case .response(.string("fixture-approval"), let response):
                        #expect(response == .object(["decision": .string("accept")]))
                        capture.record()
                    default: Issue.record("Unexpected replay fixture traffic"); return
                    }
                }
            } catch { /* Revocation closes the client and its owned peer. */ }
        }
    }

    private static func write(_ message: CodexAppServerMessage, to peer: CodexAppServerStdioChannel) async throws {
        try await peer.write(message.encoded(), deadline: .now.advanced(by: .seconds(5)))
    }
}

nonisolated private final class ReplayGate: CodexAppServerResponseReplayAuthority {
    private let active = Mutex(true)
    func validate() throws {
        try active.withLock { guard $0 else { throw CodexAppServerWireError.closed } }
    }
    func revoke() { active.withLock { $0 = false } }
    func validateReplay() throws { try validate() }
}

nonisolated private struct WeakReplayGate: Sendable { weak var value: ReplayGate? }

nonisolated private final class ReplayCapture: Sendable {
    let responses: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation
    private let value = Mutex(0)
    var receivedResponses: Int { value.withLock { $0 } }
    init() { (responses, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(4)) }
    func record() { continuation.yield(value.withLock { $0 += 1; return $0 }) }
    func finish() { continuation.finish() }
}

nonisolated private final class ReplayWriteBarrier: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func suspendWrite() throws {
        entered.signal()
        guard released.wait(timeout: .now() + 5) == .success else { throw CodexAppServerWireError.closed }
    }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func release() { released.signal() }
}
