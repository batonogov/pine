import Foundation
import Testing
@testable import Pine

struct KimiACPConnectionTests {
    private func initializeResult() -> AgentEventJSON {
        .object([
            "protocolVersion": .number("1"),
            "agentInfo": .object([
                "name": .string("Kimi Code CLI"),
                "version": .string(KimiACPCapabilities.pinnedCLIVersion)
            ]),
            "agentCapabilities": .object(["loadSession": .bool(true)]),
            "authMethods": .array([])
        ])
    }

    @Test func initializeSendsClientCapabilitiesAndHandshakes() throws {
        var connection = KimiACPConnection()
        var bytes: Data?
        _ = try connection.initialize { bytes = $0 }
        guard let bytes else { Issue.record("initialize must write bytes"); return }
        guard case .request(let id, let method, let params) = try CodexAppServerMessage(data: bytes) else {
            Issue.record("initialize must be a request"); return
        }
        #expect(id == .integer(0))
        #expect(method == "initialize")
        let fields = try KimiACPWire.object(params)
        #expect(fields["protocolVersion"] == .number("1"))
        let capabilities = try KimiACPWire.object(fields["clientCapabilities"] ?? .null)
        let elicitation = try KimiACPWire.object(capabilities["elicitation"] ?? .null)
        #expect(elicitation["form"] != nil)
        #expect(capabilities["fs"] == nil)
        #expect(capabilities["terminal"] == nil)
        #expect(capabilities["auth"] == nil)
        let delivery = try connection.receive(
            .response(id, result: initializeResult()), connection: connection.identity
        ) { _ in }
        #expect(delivery == .initialized(initializeResult()))
        #expect(connection.phase == .ready)
    }

    @Test func requestsBeforeReadyAreRefused() throws {
        var connection = KimiACPConnection()
        _ = try connection.initialize { _ in }
        #expect(throws: KimiACPWireError.invalidState) {
            _ = try connection.request(method: "session/new", params: .object([:])) { _ in }
        }
    }

    @Test func promptResponseCorrelatesAndForeignResponsesClose() async throws {
        var connection = KimiACPConnection()
        _ = try connection.initialize { _ in }
        _ = try connection.receive(.response(.integer(0), result: initializeResult()),
                                   connection: connection.identity) { _ in }
        var bytes: Data?
        let id = try connection.request(method: "session/prompt", params: .object([:])) { bytes = $0 }
        #expect(id == .integer(1))
        let delivery = try connection.receive(
            .response(id, result: .object(["stopReason": .string("end_turn")])),
            connection: connection.identity
        ) { _ in }
        #expect(delivery == .response(id, method: "session/prompt",
                                      result: .object(["stopReason": .string("end_turn")])))
        #expect(throws: KimiACPWireError.self) {
            _ = try connection.receive(.response(.integer(99), result: .object([:])),
                                       connection: connection.identity) { _ in }
        }
        #expect(connection.phase == .closed)
        _ = bytes
    }

    @Test func duplicateServerRequestsDoNotRepromptAndReplayReanswers() async throws {
        var connection = KimiACPConnection()
        _ = try connection.initialize { _ in }
        _ = try connection.receive(.response(.integer(0), result: initializeResult()),
                                   connection: connection.identity) { _ in }
        let request = CodexAppServerMessage.request(
            .integer(40), method: "session/request_permission",
            params: .object(["sessionId": .string("kimi_fixture_new")])
        )
        let first = try connection.receive(request, connection: connection.identity) { _ in }
        #expect(first == .serverRequest(.integer(40), method: "session/request_permission",
                                        params: request.params))
        let second = try connection.receive(request, connection: connection.identity) { _ in }
        #expect(second == .duplicateRequest)
        let prepared = try connection.prepareAnswer(.integer(40),
                                                    result: .object(["outcome": .object([:])]))
        try connection.confirmResponseWritten(prepared)
        var replayed: Data?
        let third = try connection.receive(request, connection: connection.identity) { replayed = $0 }
        #expect(third == .replayedResponse)
        #expect(replayed != nil)
        // One-shot: the request is no longer answerable after the cached write.
        #expect(throws: KimiACPWireError.invalidState) {
            _ = try connection.prepareAnswer(.integer(40), result: .object([:]))
        }
    }

    @Test func resolvedRequestsCannotBeAnswered() async throws {
        var connection = KimiACPConnection()
        _ = try connection.initialize { _ in }
        _ = try connection.receive(.response(.integer(0), result: initializeResult()),
                                   connection: connection.identity) { _ in }
        let request = CodexAppServerMessage.request(
            .integer(41), method: "session/request_permission",
            params: .object(["sessionId": .string("kimi_fixture_new")])
        )
        _ = try connection.receive(request, connection: connection.identity) { _ in }
        try connection.resolveServerRequest(.integer(41))
        #expect(throws: KimiACPWireError.invalidState) {
            _ = try connection.prepareAnswer(.integer(41), result: .object([:]))
        }
        // A redelivery of a resolved request is protocol corruption, not an
        // opportunity to answer again.
        #expect(throws: KimiACPWireError.self) {
            _ = try connection.receive(request, connection: connection.identity) { _ in }
        }
        #expect(connection.phase == .closed)
    }

    @Test func rejectionWritesMethodNotFound() async throws {
        var connection = KimiACPConnection()
        _ = try connection.initialize { _ in }
        _ = try connection.receive(.response(.integer(0), result: initializeResult()),
                                   connection: connection.identity) { _ in }
        let request = CodexAppServerMessage.request(
            .integer(42), method: "fs/read_text_file", params: .object([:])
        )
        _ = try connection.receive(request, connection: connection.identity) { _ in }
        var bytes: Data?
        try connection.reject(.integer(42)) { bytes = $0 }
        guard let bytes, case .failure(let id, let code) = try CodexAppServerMessage(data: bytes) else {
            Issue.record("rejection must be a failure"); return
        }
        #expect(id == .integer(42))
        #expect(code == -32601)
    }

    @Test func serverRequestCapacityIsBounded() async throws {
        var connection = KimiACPConnection()
        _ = try connection.initialize { _ in }
        _ = try connection.receive(.response(.integer(0), result: initializeResult()),
                                   connection: connection.identity) { _ in }
        for index in 0..<KimiACPConnection.maximumServerRequests {
            let request = CodexAppServerMessage.request(
                .integer(Int64(50 + index)), method: "session/request_permission",
                params: .object(["n": .number(String(index))])
            )
            _ = try connection.receive(request, connection: connection.identity) { _ in }
        }
        let overflow = CodexAppServerMessage.request(
            .integer(99), method: "session/request_permission", params: .object([:])
        )
        #expect(throws: KimiACPWireError.capacity) {
            _ = try connection.receive(overflow, connection: connection.identity) { _ in }
        }
        #expect(connection.phase == .closed)
    }

    @Test func closeFencesAllState() async throws {
        var connection = KimiACPConnection()
        _ = try connection.initialize { _ in }
        connection.close()
        #expect(throws: KimiACPWireError.self) {
            _ = try connection.receive(.notification(method: "session/update", params: .object([:])),
                                       connection: connection.identity) { _ in }
        }
        #expect(throws: KimiACPWireError.invalidState) {
            _ = try connection.request(method: "session/new", params: .object([:])) { _ in }
        }
    }
}
