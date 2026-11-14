import Foundation
import Testing
@testable import Pine

struct CodexAppServerOutboundTests {
    @Test func concurrentSendsWriteWholeFramesOnce() async throws {
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let channel = try CodexAppServerStdioChannel(
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading
        )
        defer { channel.close() }
        let writer = CodexAppServerOutbound(channel: channel)
        let frames = (0..<8).map { Data("frame-\($0)\n".utf8) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for frame in frames {
                group.addTask { try await writer.send(frame, deadline: .now.advanced(by: .seconds(5))) }
            }
            try await group.waitForAll()
        }
        await writer.close()
        let readData = try input.fileHandleForReading.readToEnd()
        let received = try #require(readData)
        let text = try #require(String(data: received, encoding: .utf8))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 8)
        #expect(Set(lines) == Set((0..<8).map { "frame-\($0)" }))
        await #expect(throws: CodexAppServerWireError.closed) {
            try await writer.send(Data("late\n".utf8), deadline: .now.advanced(by: .seconds(5)))
        }
    }

    @Test func preCancelledSendCannotWriteQueuedInput() async throws {
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let channel = try CodexAppServerStdioChannel(
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading
        )
        defer { channel.close() }
        let writer = CodexAppServerOutbound(channel: channel)
        let gate = OutboundCancellationGate()
        let task = Task {
            await gate.wait()
            try await writer.send(Data("never-send\n".utf8), deadline: .now.advanced(by: .seconds(5)))
        }
        task.cancel()
        await gate.release()
        if case .success = await task.result { Issue.record("Cancelled send succeeded") }
        await writer.close()
        let queued = try input.fileHandleForReading.readToEnd()
        #expect(queued?.isEmpty ?? true)
    }

    @Test func revokedDispatchGrantPreventsAnyInputBytes() async throws {
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let channel = try CodexAppServerStdioChannel(
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading
        )
        defer { channel.close() }
        let writer = CodexAppServerOutbound(channel: channel)
        await #expect(throws: CodexAppServerWireError.closed) {
            try await writer.send(Data("must-not-dispatch\n".utf8), deadline: .now.advanced(by: .seconds(5)), beforeWrite: {
                throw CodexAppServerWireError.closed
            })
        }
        let received = try input.fileHandleForReading.readToEnd()
        #expect(received?.isEmpty ?? true)
    }

}

private actor OutboundCancellationGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
