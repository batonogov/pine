import Foundation
import Testing
@testable import Pine

struct ClaudeCodeStreamConnectionTests {
    private func initialize(_ writes: inout [Data]) throws -> ClaudeCodeStreamConnection {
        var connection = ClaudeCodeStreamConnection()
        let initID = try connection.initialize { writes.append($0) }
        let envelope = """
        {"type":"control_response","response":{"subtype":"success","request_id":"\(initID.value)","response":{}}}
        """
        let delivery = try connection.receive(
            try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))) { writes.append($0) }
        guard case .controlResponseSuccess(requestID: let answered, _, _, _, _, _) = delivery,
              answered == initID else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(connection.phase == .ready)
        return connection
    }

    private func permission(_ id: String, tool: String = "Bash", useID: String? = nil) throws -> ClaudeCodePermissionRequest {
        .init(id: try ClaudeCodeControlRequestID(id), toolName: tool,
              toolUseID: useID ?? "tool-\(id)", agentID: nil)
    }

    @Test func initializeHandshakeAndCorrelation() throws {
        var writes: [Data] = []
        var connection = ClaudeCodeStreamConnection()
        let initID = try connection.initialize { writes.append($0) }
        #expect(writes.count == 1)
        var initParser = AgentEventJSONParser(data: writes[0].dropLast())
        #expect(try initParser.parse().isInitializedRequest)
        // A response for an unknown id fences the connection.
        let foreign = """
        {"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}
        """
        #expect(throws: ClaudeCodeWireError.invalidEnvelope) {
            _ = try connection.receive(try ClaudeCodeStreamMessage.parse(data: Data(foreign.utf8))) { writes.append($0) }
        }
        #expect(connection.phase == .closed)
        #expect(throws: ClaudeCodeWireError.closed) {
            _ = try connection.receive(try ClaudeCodeStreamMessage.parse(data: Data(foreign.utf8))) { writes.append($0) }
        }
        _ = initID
    }

    @Test func interruptResponseCarriesReceiptThroughDelivery() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let interruptID = try connection.sendInterrupt(cancelQueued: true) { writes.append($0) }
        let envelope = """
        {"type":"control_response","response":{"subtype":"success","request_id":"\(interruptID.value)",\
        "response":{"still_queued":["q-1"],"cancelled":["q-2"]}}}
        """
        let delivery = try connection.receive(
            try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))) { writes.append($0) }
        guard case .controlResponseSuccess(requestID: let answered, _, _, _, _,
                                           interruptReceipt: let receipt) = delivery else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(answered == interruptID)
        #expect(receipt?.stillQueued == ["q-1"])
        #expect(receipt?.cancelled == ["q-2"])
        // The interrupt response is one-shot: a second delivery is foreign.
        #expect(throws: ClaudeCodeWireError.invalidEnvelope) {
            _ = try connection.receive(try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))) { writes.append($0) }
        }
    }

    @Test func initializeErrorFencesWithoutReadyPhase() throws {
        var writes: [Data] = []
        var connection = ClaudeCodeStreamConnection()
        let initID = try connection.initialize { writes.append($0) }
        let envelope = """
        {"type":"control_response","response":{"subtype":"error","request_id":"\(initID.value)","error":"auth required"}}
        """
        let delivery = try connection.receive(
            try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))) { writes.append($0) }
        guard case .controlResponseError(requestID: let answered, message: "auth required") = delivery else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(answered == initID)
        #expect(connection.phase == .closed)
    }

    @Test func oneShotAnswerReplaysOnRedelivery() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let request = try permission("perm-1")
        #expect(try connection.receive(.permissionRequest(request)) { writes.append($0) }
            == .serverRequest(request))
        let beforeAnswer = writes.count
        _ = try connection.answer(request.id, allow: true, write: { writes.append($0) })
        #expect(writes.count == beforeAnswer + 1)
        // Redelivery replays the remembered response byte-for-byte.
        #expect(try connection.receive(.permissionRequest(request)) { writes.append($0) } == .replayedResponse)
        #expect(writes.count == beforeAnswer + 2)
        #expect(writes[beforeAnswer] == writes[beforeAnswer + 1])
        #expect(throws: ClaudeCodeWireError.invalidState) {
            _ = try connection.answer(request.id, allow: false, write: { writes.append($0) })
        }
        #expect(connection.phase == .closed)
    }

    @Test func duplicateRequestDoesNotReprompt() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let request = try permission("perm-2")
        #expect(try connection.receive(.permissionRequest(request)) { writes.append($0) }
            == .serverRequest(request))
        #expect(try connection.receive(.permissionRequest(request)) { writes.append($0) }
            == .duplicateRequest)
        // A changed payload for a known id fences; the remembered identity wins.
        let changed = try permission("perm-2", tool: "Edit")
        #expect(throws: ClaudeCodeWireError.invalidEnvelope) {
            _ = try connection.receive(.permissionRequest(changed)) { writes.append($0) }
        }
        #expect(connection.phase == .closed)
    }

    @Test func asynchronousPrepareConfirmReplay() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let request = try permission("perm-3")
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        let prepared = try connection.prepareAnswer(request.id, allow: false)
        // Redelivery while the write is in flight stays a duplicate.
        #expect(try connection.receive(.permissionRequest(request)) { writes.append($0) } == .duplicateRequest)
        try connection.confirmResponseWritten(prepared)
        #expect(try connection.receive(.permissionRequest(request)) { writes.append($0) } == .replayedResponse)
        #expect(throws: ClaudeCodeWireError.invalidState) {
            try connection.confirmResponseWritten(prepared)
        }
    }

    @Test func providerResolutionRacesAnswerWrite() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let request = try permission("perm-4")
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        let prepared = try connection.prepareAnswer(request.id, allow: true)
        try connection.resolveRequest(request.id)
        try connection.confirmResponseWritten(prepared)
        // The confirmed answer is cached even though the CLI resolved first.
        #expect(try connection.receive(.permissionRequest(request)) { writes.append($0) } == .replayedResponse)
    }

    @Test func resolvedUnansweredRequestCannotBeAnswered() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let request = try permission("perm-5")
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        try connection.resolveRequest(request.id)
        #expect(throws: ClaudeCodeWireError.invalidState) {
            _ = try connection.prepareAnswer(request.id, allow: true)
        }
        #expect(throws: ClaudeCodeWireError.invalidState) {
            _ = try connection.answer(request.id, allow: true, write: { writes.append($0) })
        }
        #expect(connection.phase == .closed)
        // A redelivery after provider resolution fences: the remembered
        // identity no longer holds. Use a fresh connection because the failed
        // answer above closed the first one.
        connection = try initialize(&writes)
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        try connection.resolveRequest(request.id)
        #expect(throws: ClaudeCodeWireError.invalidEnvelope) {
            _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        }
        #expect(connection.phase == .closed)
    }

    @Test func rejectWritesFixedTextAndRetainsNothing() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let request = try permission("perm-6")
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        _ = try connection.reject(request.id) { writes.append($0) }
        let last = try #require(writes.last)
        let text = String(data: last, encoding: .utf8) ?? ""
        #expect(text.contains("Request not supported by Pine."))
        // Rejecting an unknown request writes once without caching.
        let unknown = try ClaudeCodeControlRequestID("perm-unknown")
        _ = try connection.reject(unknown) { writes.append($0) }
    }

    @Test func rejectAfterAnswerCannotWriteConflictingResponse() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let request = try permission("perm-reject-answered")
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        _ = try connection.answer(request.id, allow: true, write: { writes.append($0) })
        let writeCount = writes.count
        #expect(throws: ClaudeCodeWireError.invalidState) {
            try connection.reject(request.id) { writes.append($0) }
        }
        #expect(connection.phase == .closed)
        #expect(writes.count == writeCount)
    }

    @Test func rejectWhileAnswerIsPreparedFencesConfirmation() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let request = try permission("perm-reject-preparing")
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        let prepared = try connection.prepareAnswer(request.id, allow: true)
        let writeCount = writes.count
        #expect(throws: ClaudeCodeWireError.invalidState) {
            try connection.reject(request.id) { writes.append($0) }
        }
        #expect(connection.phase == .closed)
        #expect(throws: ClaudeCodeWireError.invalidState) {
            try connection.confirmResponseWritten(prepared)
        }
        #expect(writes.count == writeCount)
    }

    @Test func redeliveredPendingRequestsFlowThroughOneShotPath() throws {
        var writes: [Data] = []
        var connection = ClaudeCodeStreamConnection()
        let initID = try connection.initialize { writes.append($0) }
        let request = try permission("perm-re", tool: "Read")
        let envelope = """
        {"type":"control_response","response":{"subtype":"success","request_id":"\(initID.value)",\
        "response":{},"pending_permission_requests":[\
        {"type":"control_request","request_id":"perm-re",\
        "request":{"subtype":"can_use_tool","tool_name":"Read","tool_use_id":"tool-perm-re"}}]}}
        """
        let delivery = try connection.receive(
            try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))) { writes.append($0) }
        guard case .controlResponseSuccess(requestID: _, _, _, redelivered: let redelivered?, _, _) = delivery else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(redelivered == [request])
        // The owner routes each redelivery through the same one-shot path.
        #expect(try connection.noteRedelivered(redelivered[0]) { writes.append($0) }
            == .serverRequest(request))
        _ = try connection.answer(request.id, allow: true, write: { writes.append($0) })
        try connection.resolveRequest(request.id)
        // A later standalone redelivery replays the remembered response.
        #expect(try connection.receive(.permissionRequest(request)) { writes.append($0) } == .replayedResponse)
    }

    @Test func initializePreservesAbsentVersusEmptyPendingRequests() throws {
        func redelivered(_ pendingField: String) throws -> [ClaudeCodePermissionRequest]? {
            var connection = ClaudeCodeStreamConnection()
            let initID = try connection.initialize { _ in }
            let envelope = """
            {"type":"control_response","response":{"subtype":"success","request_id":"\(initID.value)",\
            "response":{}\(pendingField)}}
            """
            let delivery = try connection.receive(
                try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))) { _ in }
            guard case .controlResponseSuccess(requestID: _, _, _, redelivered: let requests, _, _) = delivery else {
                throw ClaudeCodeWireError.invalidState
            }
            return requests
        }
        #expect(try redelivered("") == nil)
        #expect(try redelivered(", \"pending_permission_requests\":[]") == [])
    }

    @Test func sessionFencingRejectsForeignSessions() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        #expect(try connection.receive(
            .assistant(sessionID: "s-1", userMessageUUID: nil, toolCalls: []),
            write: { writes.append($0) }) == .message(.assistant(sessionID: "s-1", userMessageUUID: nil, toolCalls: [])))
        #expect(connection.sessionID == "s-1")
        #expect(try connection.receive(
            .assistant(sessionID: "s-2", userMessageUUID: nil, toolCalls: []),
            write: { writes.append($0) }) == .ignoredForeignSession)
        #expect(connection.sessionID == "s-1")
        #expect(connection.phase == .ready)
    }

    @Test func permissionDenialUsesSessionFencing() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        _ = try connection.receive(
            .assistant(sessionID: "s-1", userMessageUUID: nil, toolCalls: []),
            write: { writes.append($0) }
        )
        let request = try permission("perm-foreign")
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        let foreign = ClaudeCodeStreamMessage.permissionDenied(sessionID: "s-2", toolUseID: request.toolUseID)
        #expect(try connection.receive(foreign, write: { writes.append($0) }) == .ignoredForeignSession)
        #expect(connection.phase == .ready)
        // The foreign denial never reached the owner, so the request remains answerable.
        _ = try connection.answer(request.id, allow: false, write: { writes.append($0) })
    }

    @Test func serverRequestCapacityFailsClosed() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        for index in 0..<ClaudeCodeStreamConnection.maximumServerRequests {
            _ = try connection.receive(.permissionRequest(try permission("cap-\(index)"))) { writes.append($0) }
        }
        #expect(throws: ClaudeCodeWireError.capacityExceeded) {
            _ = try connection.receive(.permissionRequest(try permission("cap-overflow"))) { writes.append($0) }
        }
        #expect(connection.phase == .closed)
    }

    @Test func rememberedCapacityFailsClosed() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        for index in 0..<ClaudeCodeStreamConnection.maximumRememberedResponses {
            let request = try permission("mem-\(index)")
            _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
            try connection.resolveRequest(request.id)
        }
        let request = try permission("mem-overflow")
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        #expect(throws: ClaudeCodeWireError.capacityExceeded) {
            try connection.resolveRequest(request.id)
        }
    }

    @Test func writeLossFencesWithoutResend() throws {
        var writes: [Data] = []
        var connection = try initialize(&writes)
        let request = try permission("perm-7")
        _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
        #expect(throws: ClaudeCodeWireError.closed) {
            _ = try connection.answer(request.id, allow: true) { _ in throw ClaudeCodeWireError.closed }
        }
        #expect(connection.phase == .closed)
        #expect(throws: ClaudeCodeWireError.closed) {
            _ = try connection.sendInterrupt(cancelQueued: false) { writes.append($0) }
        }
        #expect(throws: ClaudeCodeWireError.invalidState) {
            _ = try connection.initialize { writes.append($0) }
        }
    }

    @Test func messagesBeforeReadyAreInvalid() throws {
        var writes: [Data] = []
        var connection = ClaudeCodeStreamConnection()
        // A data message before the handshake fences the connection.
        #expect(throws: ClaudeCodeWireError.invalidState) {
            _ = try connection.receive(
                .assistant(sessionID: "s-1", userMessageUUID: nil, toolCalls: []),
                write: { writes.append($0) })
        }
        #expect(throws: ClaudeCodeWireError.closed) {
            _ = try connection.sendInterrupt(cancelQueued: false) { writes.append($0) }
        }
        var fresh = ClaudeCodeStreamConnection()
        #expect(throws: ClaudeCodeWireError.invalidState) {
            _ = try fresh.sendInterrupt(cancelQueued: false) { writes.append($0) }
        }
        // initialize is single-use on this connection.
        _ = try fresh.initialize { writes.append($0) }
        #expect(throws: ClaudeCodeWireError.invalidState) {
            _ = try fresh.initialize { writes.append($0) }
        }
    }
}

private extension AgentEventJSON {
    var isInitializedRequest: Bool {
        guard case .object(let fields) = self,
              case .string("control_request") = fields["type"],
              case .object(let request) = fields["request"],
              case .string("initialize") = request["subtype"] else {
            return false
        }
        return true
    }
}
