import Foundation
import Testing
@testable import Pine

struct CodexAppServerConnectionTests {
    private func connected() throws -> CodexAppServerConnection {
        var connection = CodexAppServerConnection()
        try connection.initialize { _ in }
        let delivery = try connection.receive(
            .response(.integer(0), result: .object(["userAgent": .string("fixture")])),
            connection: connection.identity,
            write: { _ in }
        )
        #expect(delivery == .initialized)
        #expect(connection.phase == .ready)
        return connection
    }

    @Test func handshakeAndCorrelatedResponse() throws {
        var connection = CodexAppServerConnection()
        var output: [CodexAppServerMessage] = []
        try connection.initialize { output.append(try CodexAppServerMessage(data: $0.dropLast())) }
        #expect(throws: CodexAppServerWireError.invalidState) {
            try connection.request(method: "thread/start", params: .object([:])) { _ in }
        }
        _ = try connection.receive(
            .response(.integer(0), result: .object(["userAgent": .string("fixture")])),
            connection: connection.identity
        ) { output.append(try CodexAppServerMessage(data: $0.dropLast())) }
        #expect(output.count == 2)
        #expect(output.last == .notification(method: "initialized", params: .object([:])))
        let identifier = try connection.request(method: "thread/start", params: .object([:])) { _ in }
        let result = AgentEventJSON.object(["thread": .object(["id": .string("fixture-thread")])])
        let delivery = try connection.receive(.response(identifier, result: result), connection: connection.identity) { _ in }
        #expect(delivery == .response(identifier, method: "thread/start", result: result))
        // Replayed or uncorrelated client responses never advance state.
        #expect(throws: CodexAppServerWireError.foreignResponse) {
            try connection.receive(.response(identifier, result: result), connection: connection.identity) { _ in }
        }
        #expect(connection.phase == .closed)
    }

    @Test func oldConnectionIsIgnoredWithoutChangingCurrentState() throws {
        var connection = try connected()
        let result = try connection.receive(
            .failure(.integer(0), code: -1), connection: UUID(), write: { _ in }
        )
        #expect(result == .ignoredForeignConnection)
        #expect(connection.phase == .ready)
    }

    @Test func pendingRequestsAreBounded() throws {
        var connection = try connected()
        for _ in 0..<CodexAppServerConnection.maximumPendingRequests {
            try connection.request(method: "thread/read", params: .object([:])) { _ in }
        }
        #expect(throws: CodexAppServerWireError.capacityExceeded) {
            try connection.request(method: "thread/read", params: .object([:])) { _ in }
        }
        #expect(connection.phase == .closed)
    }

    @Test func duplicateQuestionAndAnswerAreOneShot() throws {
        var connection = try connected()
        let identifier = CodexAppServerRequestID.string("fixture-question")
        let request = CodexAppServerMessage.request(identifier, method: "fixture/request", params: .object([:]))
        let identity = connection.identity
        #expect(try connection.receive(request, connection: identity) { _ in }
            == .serverRequest(identifier, method: "fixture/request", params: .object([:])))
        #expect(try connection.receive(request, connection: identity) { _ in } == .duplicateRequest)
        var output: [Data] = []
        try connection.answer(identifier, result: .object(["decision": .string("decline")])) { output.append($0) }
        #expect(throws: CodexAppServerWireError.invalidState) {
            try connection.answer(identifier, result: .object(["decision": .string("accept")])) { output.append($0) }
        }
        #expect(try connection.receive(request, connection: identity) { output.append($0) } == .replayedResponse)
        #expect(output.count == 2)
        #expect(output.first == output.last)
    }

    @Test func changedRequestCannotReuseAnsweredIdentifier() throws {
        var connection = try connected()
        let identifier = CodexAppServerRequestID.integer(99)
        _ = try connection.receive(.request(identifier, method: "future/request", params: .object([:])),
                                   connection: connection.identity) { _ in }
        try connection.reject(identifier) { _ in }
        #expect(throws: CodexAppServerWireError.invalidEnvelope) {
            try connection.receive(.request(identifier, method: "other/request", params: .object([:])),
                                   connection: connection.identity) { _ in }
        }
        #expect(connection.phase == .closed)
    }

    @Test func writeLossClosesWithoutAutomaticResend() throws {
        var connection = try connected()
        var writes = 0
        #expect(throws: CodexAppServerWireError.closed) {
            try connection.request(method: "turn/start", params: .object([:])) { _ in
                writes += 1
                throw CodexAppServerWireError.closed
            }
        }
        #expect(writes == 1)
        #expect(connection.phase == .closed)
        #expect(throws: CodexAppServerWireError.invalidState) {
            try connection.request(method: "turn/start", params: .object([:])) { _ in writes += 1 }
        }
        #expect(writes == 1)
    }

    @Test func initializedWriteFailureDoesNotProduceReadyConnection() throws {
        var connection = CodexAppServerConnection()
        try connection.initialize { _ in }
        #expect(throws: CodexAppServerWireError.closed) {
            try connection.receive(.response(.integer(0), result: .object(["userAgent": .string("fixture")])),
                                   connection: connection.identity) { _ in throw CodexAppServerWireError.closed }
        }
        #expect(connection.phase == .closed)
    }

    @Test func unsupportedRequestGetsMethodErrorWithoutAuthority() throws {
        var connection = try connected()
        let identifier = CodexAppServerRequestID.string("future")
        let incoming = CodexAppServerMessage.request(
            identifier, method: "future/execute", params: .object(["payload": .string("SECRET-FIXTURE")])
        )
        _ = try connection.receive(incoming, connection: connection.identity) { _ in }
        var reply: CodexAppServerMessage?
        try connection.reject(identifier) { reply = try CodexAppServerMessage(data: $0.dropLast()) }
        #expect(reply == .failure(identifier, code: -32601))
        // Provider-supplied method/arguments are not echoed in error messages.
        let encoded = try #require(reply).encoded()
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("SECRET-FIXTURE"))
        #expect(connection.phase == .ready)
    }

    @Test func serverRequestCapacityFailsClosed() throws {
        var connection = try connected()
        let identity = connection.identity
        for number in 0..<CodexAppServerConnection.maximumServerRequests {
            _ = try connection.receive(.request(.integer(Int64(number)), method: "future", params: .object([:])),
                                       connection: identity) { _ in }
        }
        #expect(throws: CodexAppServerWireError.capacityExceeded) {
            try connection.receive(.request(.integer(100), method: "future", params: .object([:])),
                                   connection: identity) { _ in }
        }
        #expect(connection.phase == .closed)
    }

    @Test func answerWriteLossCannotBeReanswered() throws {
        var connection = try connected()
        let identifier = CodexAppServerRequestID.integer(42)
        _ = try connection.receive(.request(identifier, method: "future", params: .object([:])),
                                   connection: connection.identity) { _ in }
        var writes = 0
        #expect(throws: CodexAppServerWireError.closed) {
            try connection.answer(identifier, result: .object([:])) { _ in
                writes += 1
                throw CodexAppServerWireError.closed
            }
        }
        #expect(connection.phase == .closed)
        #expect(throws: CodexAppServerWireError.invalidState) {
            try connection.answer(identifier, result: .object([:])) { _ in writes += 1 }
        }
        #expect(writes == 1)
    }

    @Test func sameMethodResponsesRetainCorrelationAcrossReordering() throws {
        var connection = try connected()
        let first = try connection.request(method: "thread/read", params: .object([:])) { _ in }
        let second = try connection.request(method: "thread/read", params: .object([:])) { _ in }
        let secondDelivery = try connection.receive(.response(second, result: .object([:])), connection: connection.identity) { _ in }
        #expect(secondDelivery == .response(second, method: "thread/read", result: .object([:])))
        let firstDelivery = try connection.receive(.failure(first, code: -32001), connection: connection.identity) { _ in }
        #expect(firstDelivery == .failure(first, method: "thread/read", code: -32001))
    }

    @Test func asynchronousResponseIsCachedOnlyAfterSuccessfulPhysicalWrite() throws {
        var connection = try connected()
        let identifier = CodexAppServerRequestID.integer(88)
        let message = CodexAppServerMessage.request(identifier, method: "future/request", params: .object([:]))
        _ = try connection.receive(message, connection: connection.identity) { _ in }
        let prepared = try connection.prepareAnswer(identifier, result: .object([:]))
        var prematureWrites = 0
        let pending = try connection.receive(message, connection: connection.identity) { _ in prematureWrites += 1 }
        #expect(pending == .duplicateRequest)
        #expect(prematureWrites == 0)
        try connection.confirmResponseWritten(prepared)
        var replay: Data?
        let completed = try connection.receive(message, connection: connection.identity) { replay = $0 }
        #expect(completed == .replayedResponse)
        #expect(replay == prepared.bytes)
        #expect(throws: CodexAppServerWireError.invalidState) { try connection.confirmResponseWritten(prepared) }
    }

    @Test func experimentalQuestionSupportRequiresExplicitOptIn() throws {
        var connection = CodexAppServerConnection()
        var frame: CodexAppServerMessage?
        try connection.initialize(experimentalAPI: true) { frame = try CodexAppServerMessage(data: $0.dropLast()) }
        guard case .request(_, "initialize", .object(let fields)) = frame else {
            Issue.record("Missing explicit initialize request")
            return
        }
        #expect(fields["capabilities"] == .object(["experimentalApi": .bool(true)]))
    }

    @Test func resolvedUnansweredRequestCannotBeAnsweredOrReopened() throws {
        var connection = try connected()
        let identifier = CodexAppServerRequestID.integer(98)
        let request = CodexAppServerMessage.request(identifier, method: "future/request", params: .object([:]))
        _ = try connection.receive(request, connection: connection.identity) { _ in }
        try connection.resolveServerRequest(identifier)
        #expect(throws: CodexAppServerWireError.invalidState) {
            try connection.answer(identifier, result: .object([:])) { _ in Issue.record("Stale answer written") }
        }
        #expect(throws: CodexAppServerWireError.invalidEnvelope) {
            try connection.receive(request, connection: connection.identity) { _ in }
        }
    }

    @Test func providerResolutionCanRaceSuccessfulAnswerWrite() throws {
        var connection = try connected()
        let identifier = CodexAppServerRequestID.integer(99)
        let request = CodexAppServerMessage.request(identifier, method: "future/request", params: .object([:]))
        _ = try connection.receive(request, connection: connection.identity) { _ in }
        let prepared = try connection.prepareAnswer(identifier, result: .object([:]))
        try connection.resolveServerRequest(identifier)
        try connection.confirmResponseWritten(prepared)
        let repeated = try connection.receive(request, connection: connection.identity) { _ in }
        #expect(repeated == .replayedResponse)
    }

}
