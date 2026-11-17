import Foundation
import Testing
@testable import Pine

/// The Claude side of the shared provider contract suite (#1727). Every
/// scenario runs against the owned stream-json/control codec, connection,
/// and task mapper. Real-version flows (live permission exchange, live
/// interrupt receipt) are the final gate and are not claimed here.
struct ClaudeCodeProviderContractTests {
    static let sessionID = "fixture-session"

    private struct Fixture {
        var connection: ClaudeCodeStreamConnection
        var mapper: ClaudeCodeStreamTaskMapper
        var connectionID: UUID { connection.identity }
    }

    private func readyFixture(_ writes: inout [Data]) throws -> Fixture {
        var connection = ClaudeCodeStreamConnection()
        let initID = try connection.initialize { writes.append($0) }
        let envelope = """
        {"type":"control_response","response":{"subtype":"success","request_id":"\(initID.value)",\
        "response":{"claude_code_version":"2.1.311",\
        "account":{"tokenSource":"none","apiProvider":"firstParty"}},\
        "pending_permission_requests":[],"pending_user_dialog_requests":[]}}
        """
        let response = try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))
        guard case .controlResponseSuccess(requestID: let answered, _, _, _, _, _) =
            try connection.receive(response) { writes.append($0) }, answered == initID else {
            throw ClaudeCodeWireError.invalidState
        }
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection.identity)
        let initEffects = try mapper.map(
            .systemInit(sessionID: Self.sessionID, claudeCodeVersion: "2.1.311",
                        permissionMode: "default", model: "fixture-model",
                        capabilities: ["interrupt_receipt_v1", "interrupt_cancel_queued_v1"],
                        account: .init(tokenSource: .none, provider: .firstParty)),
            connection: connection.identity
        )
        guard case .candidate(let candidate)? = initEffects.first,
              case .lifecycle(let event) = candidate.event, event.scope == .session else {
            throw ClaudeCodeWireError.invalidState
        }
        return Fixture(connection: connection, mapper: mapper)
    }

    private func bindTurn(_ fx: inout Fixture) throws {
        try fx.mapper.prepareTurn(messageUUID: "turn-uuid-1")
        let effects = try fx.mapper.map(
            .assistant(sessionID: Self.sessionID, userMessageUUID: "turn-uuid-1", toolCalls: []),
            connection: fx.connectionID
        )
        guard case .candidate(let candidate)? = effects.first,
              case .lifecycle(let event) = candidate.event, event.phase == .started else {
            throw ClaudeCodeWireError.invalidState
        }
    }

    private func approvalRequest(_ id: String, tool: String) throws -> ClaudeCodePermissionRequest {
        .init(id: try ClaudeCodeControlRequestID(id), toolName: tool, toolUseID: "tool-\(id)", agentID: nil)
    }

    @Test func providerContractTable() throws {
        var table: [String: AgentProviderContractOutcome] = [:]
        var writes: [Data] = []

        // Question: native user questions arrive via pending_user_dialog_requests.
        table["question"] = .unsupported(
            "User-dialog requests are parsed at the initialize wrapper (count only, entries"
            + " data-only) but no question state is mapped; the live dialog shape is not exercised"
            + " at the codec/model level"
        )

        // Approval: full one-shot cycle with idempotent redelivery.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx)
            let request = try approvalRequest("perm-1", tool: "Bash")
            guard case .attention =
                try fx.mapper.map(.permissionRequest(request), connection: fx.connectionID).first else {
                throw ClaudeCodeWireError.invalidState
            }
            // The connection must hold the request before it can be answered.
            _ = try fx.connection.receive(.permissionRequest(request)) { writes.append($0) }
            _ = try fx.connection.answer(request.id, allow: true, write: { writes.append($0) })
            try fx.mapper.markResponseWritten(request.id)
            let redelivery = try fx.connection.receive(.permissionRequest(request)) { writes.append($0) }
            let ack = try fx.mapper.map(
                .userToolResults(sessionID: Self.sessionID,
                                 results: [.init(toolUseID: "tool-perm-1", isError: false)]),
                connection: fx.connectionID
            )
            guard redelivery == .replayedResponse, ack.contains(where: { effect in
                guard case .requestResolved(_, let id) = effect else { return false }
                return id == request.id
            }) else {
                throw ClaudeCodeWireError.invalidState
            }
            table["approval"] = .pass
        }

        // Continuation: new authorized turn after Stop reuses the session.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx)
            guard try fx.mapper.map(.result(sessionID: Self.sessionID, subtype: .success),
                                    connection: fx.connectionID) == [.mainTurnEnd] else {
                throw ClaudeCodeWireError.invalidState
            }
            try fx.mapper.prepareTurn(messageUUID: "turn-uuid-2")
            let effects = try fx.mapper.map(
                .assistant(sessionID: Self.sessionID, userMessageUUID: "turn-uuid-2", toolCalls: []),
                connection: fx.connectionID
            )
            guard case .candidate(let candidate)? = effects.first,
                  case .lifecycle(let event) = candidate.event, event.phase == .started else {
                throw ClaudeCodeWireError.invalidState
            }
            table["continuation"] = .pass
        }

        // Cancellation: requested until confirmed; queued input never auto-resent.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx)
            try fx.mapper.requestCancellation()
            guard case .interruptReceiptObserved(stillQueued: let queued, _) =
                fx.mapper.observeInterruptReceipt(stillQueued: ["queued-1"], cancelled: []),
                queued == ["queued-1"] else {
                throw ClaudeCodeWireError.invalidState
            }
            let outcome = try fx.mapper.map(.result(sessionID: Self.sessionID, subtype: .success),
                                            connection: fx.connectionID)
            guard case .candidate(let candidate)? = outcome.first,
                  case .lifecycle(let event) = candidate.event, event.phase == .cancelled else {
                throw ClaudeCodeWireError.invalidState
            }
            table["cancellation"] = .pass
        }

        // Malformed, duplicate, stale: fences, replay, and stale-turn ignores.
        do {
            writes = []
            var connection = ClaudeCodeStreamConnection()
            let initID = try connection.initialize { writes.append($0) }
            let envelope = """
            {"type":"control_response","response":{"subtype":"success","request_id":"\(initID.value)","response":{}}}
            """
            _ = try connection.receive(try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))) {
                writes.append($0)
            }
            var framer = ClaudeCodeStreamFramer()
            var fenced = false
            do {
                try framer.receive(Data("garbage-not-json\n".utf8)) { _ in }
            } catch {
                fenced = framer.isClosed
            }
            let request = try approvalRequest("perm-dup", tool: "Read")
            _ = try connection.receive(.permissionRequest(request)) { writes.append($0) }
            _ = try connection.answer(request.id, allow: false, write: { writes.append($0) })
            let replay = try connection.receive(.permissionRequest(request)) { writes.append($0) }
            var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection.identity)
            _ = try mapper.map(
                .systemInit(sessionID: Self.sessionID, claudeCodeVersion: nil,
                            permissionMode: nil, model: nil, capabilities: nil, account: nil),
                connection: connection.identity
            )
            try mapper.prepareTurn(messageUUID: "stale-turn")
            _ = try mapper.map(
                .assistant(sessionID: Self.sessionID, userMessageUUID: "stale-turn", toolCalls: []),
                connection: connection.identity
            )
            _ = try mapper.map(.result(sessionID: Self.sessionID, subtype: .success),
                               connection: connection.identity)
            // A replayed settlement for an already-ended turn cannot create
            // state: with no active turn it needs reconciliation.
            let stale = try mapper.map(.result(sessionID: Self.sessionID, subtype: .success),
                                       connection: connection.identity)
            guard fenced, replay == .replayedResponse, stale == [.needsReconciliation] else {
                throw ClaudeCodeWireError.invalidState
            }
            table["malformed-duplicate-stale"] = .pass
        }

        // Reconnect: no transport reconnect on owned stdio.
        table["reconnect"] = .unsupported(
            "Owned-child stdio has no transport reconnect: process death ends the attempt. Pending-"
            + "request recovery (pending_permission_requests, floor 2.1.268) is wired at the codec for"
            + " in-process reinitialize, which this slice does not send; post-gap approval state stays"
            + " unknown, never \"no pending requests\""
        )

        // Relaunch: a new process is a new attempt; nothing auto-starts.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx)
            _ = try fx.mapper.map(.result(sessionID: Self.sessionID, subtype: .success),
                                  connection: fx.connectionID)
            fx.mapper.close()
            var relaunchBlocked = true
            do {
                try fx.mapper.prepareTurn(messageUUID: "turn-uuid-3")
                relaunchBlocked = false
            } catch {}
            guard relaunchBlocked else { throw ClaudeCodeWireError.invalidState }
            // A fresh mapper is a fresh attempt: it rebinds the same provider
            // session without inheriting the old attempt's state.
            var fresh = ClaudeCodeStreamTaskMapper(connectionID: UUID())
            let effects = try fresh.map(
                .systemInit(sessionID: Self.sessionID, claudeCodeVersion: "2.1.311",
                            permissionMode: "default", model: "fixture-model",
                            capabilities: nil, account: nil),
                connection: fresh.connectionID
            )
            guard case .candidate(let candidate)? = effects.first,
                  case .lifecycle(let event) = candidate.event,
                  event.scope == .session, event.phase == .started else {
                throw ClaudeCodeWireError.invalidState
            }
            table["relaunch"] = .pass
        }

        // Evidence fencing: foreign sessions and payloads never cross over.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx)
            // Bind the connection's session with the owned session first.
            _ = try fx.connection.receive(
                .assistant(sessionID: Self.sessionID, userMessageUUID: nil, toolCalls: []),
                write: { writes.append($0) }
            )
            #expect(fx.connection.sessionID == Self.sessionID)
            let foreign = try fx.connection.receive(
                .assistant(sessionID: "other-session", userMessageUUID: nil, toolCalls: []),
                write: { writes.append($0) }
            )
            guard foreign == .ignoredForeignSession else { throw ClaudeCodeWireError.invalidState }
            let effects = try fx.mapper.map(
                .assistant(sessionID: Self.sessionID, userMessageUUID: "turn-uuid-1",
                           toolCalls: [ClaudeCodeToolCall(id: "tool-1", name: "Bash")]),
                connection: fx.connectionID
            )
            guard case .candidate(let candidate)? = effects.last,
                  case .tool(let toolEvent) = candidate.event else {
                throw ClaudeCodeWireError.invalidState
            }
            // Shared references are redacted; no provider payload text leaks.
            guard !String(describing: toolEvent.toolCall).contains("SECRET") else {
                throw ClaudeCodeWireError.invalidState
            }
            table["evidence-fencing"] = .pass
        }

        // Backpressure: bounded pending approvals fail closed.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx)
            for index in 0..<ClaudeCodeStreamTaskMapper.maximumPendingApprovals {
                let request = try approvalRequest("perm-cap-\(index)", tool: "Bash")
                guard case .attention =
                    try fx.mapper.map(.permissionRequest(request), connection: fx.connectionID).first else {
                    throw ClaudeCodeWireError.invalidState
                }
            }
            guard fx.mapper.pendingApprovalsCount == ClaudeCodeStreamTaskMapper.maximumPendingApprovals else {
                throw ClaudeCodeWireError.invalidState
            }
            let overflow = try approvalRequest("perm-overflow", tool: "Bash")
            do {
                _ = try fx.mapper.map(.permissionRequest(overflow), connection: fx.connectionID)
                throw ClaudeCodeWireError.invalidState
            } catch ClaudeCodeWireError.capacityExceeded {}
            table["backpressure"] = .pass
        }

        // Secret-bearing payloads: nothing retained by codec or mapper.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx)
            let secret = "SECRET-BEARING-PAYLOAD-\(UUID().uuidString)"
            let assistantLine = """
            {"type":"assistant","session_id":"\(Self.sessionID)","user_message_uuid":"turn-uuid-1",\
            "message":{"role":"assistant","content":[{"type":"text","text":"\(secret)"}]}}
            """
            let assistant = try ClaudeCodeStreamMessage.parse(data: Data(assistantLine.utf8))
            let effects = try fx.mapper.map(assistant, connection: fx.connectionID)
            let candidateText = effects.map { String(describing: $0) }.joined()
            let canUseToolLine = """
            {"type":"control_request","request_id":"perm-secret",\
            "request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-perm-secret",\
            "input":{"command":"\(secret)"}}}
            """
            let parsedControl = try ClaudeCodeStreamMessage.parse(data: Data(canUseToolLine.utf8))
            let request = try approvalRequest("perm-secret", tool: "Bash")
            // Full structural equality is the allowlist proof: the parsed
            // values contain nothing but the retained metadata.
            guard assistant == .assistant(
                sessionID: Self.sessionID, userMessageUUID: "turn-uuid-1", toolCalls: []
            ), parsedControl == .permissionRequest(request) else {
                throw ClaudeCodeWireError.invalidState
            }
            guard !candidateText.contains(secret) else {
                throw ClaudeCodeWireError.invalidState
            }
            _ = try fx.connection.receive(.permissionRequest(request)) { writes.append($0) }
            _ = try fx.connection.answer(request.id, allow: false, write: { writes.append($0) })
            let lastWrite = try #require(writes.last)
            let lastText = String(data: lastWrite, encoding: .utf8) ?? ""
            guard !lastText.contains(secret), lastText.contains("Denied in Pine.") else {
                throw ClaudeCodeWireError.invalidState
            }
            table["secret-bearing-payloads"] = .pass
        }

        expectProviderContractOutcomes(table, provider: "claude")
    }
}
