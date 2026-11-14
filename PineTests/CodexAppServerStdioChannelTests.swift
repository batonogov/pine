import Foundation
import Testing
@testable import Pine

struct CodexAppServerStdioChannelTests {
    @Test func coalescedMessagesRemainPullDriven() async throws {
        let fixture = try StdioFixture()
        defer { fixture.channel.close() }
        try fixture.output.fileHandleForWriting.write(contentsOf: Data(
            "{\"method\":\"future/a\"}\n{\"method\":\"future/b\"}\n".utf8
        ))
        let first = try await fixture.channel.readNext(deadline: .now.advanced(by: .seconds(5)))
        let second = try await fixture.channel.readNext(deadline: .now.advanced(by: .seconds(5)))
        #expect(first == .notification(method: "future/a", params: .object([:])))
        #expect(second == .notification(method: "future/b", params: .object([:])))
        try fixture.output.fileHandleForWriting.close()
        #expect(try await fixture.channel.readNext(deadline: .now.advanced(by: .seconds(5))) == nil)
        #expect(throws: CodexAppServerWireError.closed) { try fixture.channel.validateOpen() }
        await #expect(throws: CodexAppServerWireError.closed) {
            try await fixture.channel.write(Data([10]), deadline: .now.advanced(by: .seconds(5)))
        }
    }

    @Test func writesCompleteMessageWithoutShellInterpolation() async throws {
        let fixture = try StdioFixture()
        defer { fixture.channel.close() }
        let bytes = try CodexAppServerMessage.notification(
            method: "fixture", params: .object(["text": .string("$(touch never-execute); `no`\n🌲")])
        ).encoded()
        try await fixture.channel.write(bytes, deadline: .now.advanced(by: .seconds(5)))
        let received = try fixture.input.fileHandleForReading.read(upToCount: bytes.count)
        #expect(received == bytes)
    }

    @Test func eofWithPartialFrameFencesChannel() async throws {
        let fixture = try StdioFixture()
        defer { fixture.channel.close() }
        try fixture.output.fileHandleForWriting.write(contentsOf: Data("{\"method\":\"unfinished\"}".utf8))
        try fixture.output.fileHandleForWriting.close()
        await #expect(throws: CodexAppServerWireError.truncatedFrame) {
            try await fixture.channel.readNext(deadline: .now.advanced(by: .seconds(5)))
        }
        await #expect(throws: CodexAppServerWireError.closed) {
            try await fixture.channel.write(Data([10]), deadline: .now.advanced(by: .seconds(5)))
        }
    }

    @Test func cancellationStopsPendingReadAndFencesWrites() async throws {
        let fixture = try StdioFixture()
        defer { fixture.channel.close() }
        let task = Task {
            try await fixture.channel.readNext(deadline: .now.advanced(by: .seconds(60)))
        }
        task.cancel()
        switch await task.result {
        case .success: Issue.record("Cancelled read produced a message")
        case .failure: break
        }
        await #expect(throws: CodexAppServerWireError.closed) {
            try await fixture.channel.write(Data([10]), deadline: .now.advanced(by: .seconds(5)))
        }
    }

    @Test func stderrIsDrainedWithoutExposingPayloads() async throws {
        let fixture = try StdioFixture()
        defer { fixture.channel.close() }
        try fixture.error.fileHandleForWriting.write(contentsOf: Data("SECRET-STDERR-FIXTURE".utf8))
        try fixture.error.fileHandleForWriting.close()
        try await fixture.channel.drainStandardError(until: .now.advanced(by: .seconds(5)))
    }
}

private struct StdioFixture: Sendable {
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    let channel: CodexAppServerStdioChannel

    init() throws {
        channel = try CodexAppServerStdioChannel(
            standardInput: input.fileHandleForWriting,
            standardOutput: output.fileHandleForReading,
            standardError: error.fileHandleForReading
        )
    }
}
