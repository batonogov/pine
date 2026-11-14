import Foundation
import Testing
@testable import Pine

struct CodexAppServerWireTests {
    @Test func diagnosticsRedactProviderIdentifiersAndPayloads() {
        let identifier = CodexAppServerRequestID.string("fixture-sensitive-id")
        let message = CodexAppServerMessage.response(identifier, result: .object([
            "question": .string("fixture-sensitive-input")
        ]))
        var output = ""
        dump(identifier, to: &output)
        dump(message, to: &output)
        output += String(describing: identifier) + String(reflecting: message)
        #expect(!output.contains("fixture-sensitive"))
        #expect(output.contains("redacted"))
    }

    @Test func fragmentedUnicodeAndCoalescedFrames() throws {
        let bytes = Data("{\"method\":\"future/event\",\"params\":{\"label\":\"🌲\"}}\n{\"id\":1,\"result\":{}}\n".utf8)
        var framer = CodexAppServerFramer()
        var received: [CodexAppServerMessage] = []
        // Every byte boundary, including a UTF-8 scalar, may split a pipe read.
        for byte in bytes { try framer.receive(Data([byte])) { received.append($0) } }
        #expect(received.count == 2)
        #expect(received.last == .response(.integer(1), result: .object([:])))
        try framer.finish()
        #expect(framer.isClosed)
    }

    @Test(arguments: [
        #"{"id":1,"id":2,"result":{}}"#,
        #"{"id":1,"\u0069d":2,"result":{}}"#,
        #"{"id":1,"result":{"nested":1,"nested":2}}"#,
        #"{"id":true,"result":{}}"#,
        #"{"id":1.0,"result":{}}"#,
        #"{"id":null,"result":{}}"#,
        #"{"id":1,"result":{},"error":{"code":-1,"message":"x"}}"#,
        #"{"method":"turn/completed","params":[],"id":1}"#,
        #"{"method":"turn/completed","result":{},"params":{}}"#,
        #"{"jsonrpc":"1.0","id":1,"result":{}}"#,
    ])
    func rejectsAmbiguousOrMalformedFrames(_ input: String) {
        var framer = CodexAppServerFramer()
        #expect(throws: (any Error).self) {
            try framer.receive(Data((input + "\n").utf8)) { _ in Issue.record("Invalid message delivered") }
        }
        #expect(framer.isClosed)
        #expect(throws: CodexAppServerWireError.closed) {
            try framer.receive(Data("{\"id\":2,\"result\":{}}\n".utf8)) { _ in }
        }
    }

    @Test func partialEOFNeverDelivers() {
        var framer = CodexAppServerFramer()
        #expect(throws: Never.self) {
            try framer.receive(Data("{\"id\":1,\"result\":{}}".utf8)) { _ in Issue.record("Partial frame delivered") }
        }
        #expect(throws: CodexAppServerWireError.truncatedFrame) { try framer.finish() }
        #expect(framer.isClosed)
    }

    @Test func limitsFrameBeforeNewline() {
        var framer = CodexAppServerFramer()
        #expect(throws: CodexAppServerWireError.frameTooLarge) {
            try framer.receive(Data(repeating: 32, count: CodexAppServerFramer.maximumFrameBytes + 1)) { _ in }
        }
        #expect(framer.isClosed)
    }

    @Test func boundsDepthBeforeRecursiveParser() {
        var framer = CodexAppServerFramer()
        let nested = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        let input = "{\"method\":\"future\",\"params\":{\"nested\":" + nested + "}}\n"
        #expect(throws: CodexAppServerWireError.nestingTooDeep) {
            try framer.receive(Data(input.utf8)) { _ in }
        }
    }

    @Test func deliveryBackpressurePoisonsIngress() {
        var framer = CodexAppServerFramer()
        var count = 0
        #expect(throws: CodexAppServerWireError.capacityExceeded) {
            try framer.receive(Data("{\"method\":\"a\"}\n{\"method\":\"b\"}\n".utf8)) { _ in
                count += 1
                throw CodexAppServerWireError.capacityExceeded
            }
        }
        #expect(count == 1)
        #expect(framer.isClosed)
    }

    @Test func unknownAdditiveFieldsAndMethodsAreDataOnly() throws {
        let message = try CodexAppServerMessage(data: Data(
            #"{"method":"future/action","params":{},"id":"server-1","future":true}"#.utf8
        ))
        #expect(message == .request(.string("server-1"), method: "future/action", params: .object([:])))
        let encoded = try message.encoded()
        #expect(encoded.last == 10)
        #expect(try CodexAppServerMessage(data: encoded.dropLast()) == message)
    }
}
