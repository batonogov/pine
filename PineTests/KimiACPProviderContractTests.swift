import Foundation
import Testing
@testable import Pine

/// The Kimi side of the shared provider contract suite (#1727). Every
/// scenario runs against the owned ACP wire codec, connection, and task
/// mapper (#1732). ACP carries no provider turn ID on the wire; the session
/// actor owns prompt correlation, so the mapper is driven with
/// begin/endPrompt exactly as the owning session does. A new process is
/// always a new connection/mapper namespace. Real-version flows are the
/// final gate and are not claimed here.
struct KimiACPProviderContractTests {
    private let sessionID = "kimi_fixture_new"

    private struct Fixture {
        var connection: KimiACPConnection
        var mapper: KimiACPTaskMapper
        var connectionID: UUID { connection.identity }
    }

    private func readyFixture(_ writes: inout [Data]) throws -> Fixture {
        var connection = KimiACPConnection()
        // The first sent request always carries the connection's ID 0.
        _ = try connection.initialize { writes.append($0) }
        let result: AgentEventJSON = .object([
            "protocolVersion": .number("1"),
            "agentInfo": .object(["name": .string("Kimi Code CLI"), "version": .string("2.6.2")]),
            "agentCapabilities": .object([:])
        ])
        guard case .initialized = try connection.receive(
            .response(.integer(0), result: result),
            connection: connection.identity, write: { writes.append($0) }
        ) else {
            throw KimiACPWireError.invalidState
        }
        var mapper = try KimiACPTaskMapper(connectionID: connection.identity, sessionID: sessionID)
        try mapper.beginPrompt()
        return Fixture(connection: connection, mapper: mapper)
    }

    private func update(_ kind: String, extra: [String: AgentEventJSON] = [:]) -> CodexAppServerMessage {
        var fields: [String: AgentEventJSON] = ["sessionUpdate": .string(kind)]
        for (key, value) in extra { fields[key] = value }
        return .notification(method: "session/update", params: .object([
            "sessionId": .string(sessionID), "update": .object(fields)
        ]))
    }

    private func chunk(_ text: String) -> CodexAppServerMessage {
        update("agent_message_chunk", extra: [
            "content": .object(["type": .string("text"), "text": .string(text)])
        ])
    }

    private func permission(_ id: Int64, toolCallID: String) -> CodexAppServerMessage {
        .request(.integer(id), method: "session/request_permission", params: .object([
            "sessionId": .string(sessionID),
            "toolCall": .object(["toolCallId": .string(toolCallID)]),
            "options": .array([
                .object(["optionId": .string("allow-once"), "name": .string("Allow once"),
                         "kind": .string("allow_once")]),
                .object(["optionId": .string("reject-once"), "name": .string("Reject"),
                         "kind": .string("reject_once")])
            ])
        ]))
    }

    private func question(_ id: Int64, message: String) -> CodexAppServerMessage {
        .request(.integer(id), method: "elicitation/create", params: .object([
            "sessionId": .string(sessionID), "mode": .string("form"),
            "message": .string(message),
            "requestedSchema": .object([
                "type": .string("object"), "required": .array([.string("choice")]),
                "properties": .object(["choice": .object([
                    "type": .string("string"),
                    "oneOf": .array([
                        .object(["const": .string("blue"), "title": .string("Blue")]),
                        .object(["const": .string("amber"), "title": .string("Amber")])
                    ])
                ])])
            ])
        ]))
    }

    @Test func providerContractTable() throws {
        var table: [String: AgentProviderContractOutcome] = [:]
        var writes: [Data] = []

        // Question: native user questions arrive via elicitation/create
        // (strict form mode; URL mode is rejected and falls back upstream).
        do {
            var fx = try readyFixture(&writes)
            let request = question(11, message: "Which color?")
            guard case .serverRequest = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            guard case .attention(let attention, .integer(11), "elicitation/create") =
                try fx.mapper.noteRequest(.integer(11), method: "elicitation/create", params: request.params)
            else {
                throw KimiACPWireError.invalidState
            }
            // The shared candidate the owning session emits is digest-only.
            let candidate = try CandidateAttentionEvent(
                scope: .session, phase: .waitingForQuestion,
                request: attention.request, context: attention.context
            )
            #expect(candidate.request.rawValue.utf8.count == 64)
            #expect(!String(reflecting: candidate).contains("Which color?"))
            #expect(!String(reflecting: attention).contains("Which color?"))
            // Answerable exactly once through the session's prepare/confirm/
            // mark sequence.
            let form = try #require(attention.form)
            let content = try form.content(answers: ["choice": ["blue"]])
            let prepared = try fx.connection.prepareAnswer(
                .integer(11), result: .object(["action": .string("accept"), "content": content])
            )
            try fx.connection.confirmResponseWritten(prepared)
            try fx.mapper.markAnswered(.integer(11))
            #expect(throws: KimiACPWireError.invalidState) { try fx.mapper.markAnswered(.integer(11)) }
            #expect(throws: KimiACPWireError.invalidState) {
                try fx.connection.prepareAnswer(.integer(11), result: .object(["action": .string("accept")]))
            }
            // Redelivery replays the remembered answer byte-for-byte.
            guard case .replayedResponse = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            // A question never settles the task: the prompt stays active.
            #expect(fx.mapper.promptActive)
            table["question"] = .pass
        }

        // Approval: session/request_permission one-shot response, idempotent
        // under redelivery; provider-side resolution settles the request.
        do {
            var fx = try readyFixture(&writes)
            let request = permission(21, toolCallID: "tool_fixture_1")
            guard case .serverRequest = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            guard case .attention(let attention, .integer(21), "session/request_permission") =
                try fx.mapper.noteRequest(.integer(21), method: "session/request_permission", params: request.params)
            else {
                throw KimiACPWireError.invalidState
            }
            #expect(attention.options["allow_once"] == "allow-once")
            #expect(attention.options["reject_once"] == "reject-once")
            let candidate = try CandidateAttentionEvent(
                scope: .session, phase: .waitingForApproval,
                request: attention.request, context: attention.context
            )
            #expect(!String(reflecting: candidate).contains("tool_fixture_1"))
            let prepared = try fx.connection.prepareAnswer(.integer(21), result: .object([
                "outcome": .object(["outcome": .string("selected"), "optionId": .string("allow-once")])
            ]))
            try fx.connection.confirmResponseWritten(prepared)
            try fx.mapper.markAnswered(.integer(21))
            #expect(throws: KimiACPWireError.invalidState) { try fx.mapper.markAnswered(.integer(21)) }
            guard case .replayedResponse = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            // A second request settles provider-side before any answer: the
            // terminal tool update resolves it, and a resolved request can
            // never be answered.
            let second = permission(22, toolCallID: "tool_fixture_2")
            guard case .serverRequest = try fx.connection.receive(second, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            guard case .attention(let secondAttention, .integer(22), _) =
                try fx.mapper.noteRequest(.integer(22), method: "session/request_permission", params: second.params)
            else {
                throw KimiACPWireError.invalidState
            }
            try fx.mapper.endPrompt()
            let settled = try fx.mapper.map(
                update("tool_call_update", extra: [
                    "toolCallId": .string("tool_fixture_2"), "status": .string("completed")
                ]), connection: fx.connectionID
            )
            #expect(settled == [.requestResolved(request: secondAttention.request)])
            try fx.connection.resolveServerRequest(.integer(22))
            #expect(throws: KimiACPWireError.invalidState) {
                try fx.connection.prepareAnswer(.integer(22), result: .object([:]))
            }
            table["approval"] = .pass
        }

        // Continuation: after the main turn ends (the session/prompt response
        // is the only ACP turn terminator), a new authorized prompt starts a
        // new turn on the same session.
        do {
            var fx = try readyFixture(&writes)
            let activity = try fx.mapper.map(chunk("turn one"), connection: fx.connectionID)
            #expect(activity == [.working(chunk: "turn one")])
            try fx.mapper.endPrompt()
            #expect(!fx.mapper.promptActive)
            try fx.mapper.beginPrompt()
            #expect(fx.mapper.promptActive)
            let second = try fx.mapper.map(chunk("turn two"), connection: fx.connectionID)
            #expect(second == [.working(chunk: "turn two")])
            table["continuation"] = .pass
        }

        // Cancellation: requested until the provider confirms; the spec's
        // cancelled outcomes cover exactly the pending asks; queued input is
        // never auto-resent. The stop-reason race (late end_turn after cancel
        // settles .unknown, never success) is enforced by the owning session.
        do {
            var fx = try readyFixture(&writes)
            let request = permission(31, toolCallID: "tool_fixture_3")
            guard case .serverRequest = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            guard case .attention = try fx.mapper.noteRequest(
                .integer(31), method: "session/request_permission", params: request.params
            ) else {
                throw KimiACPWireError.invalidState
            }
            // session/cancel: the pending asks are enumerated exactly once.
            let cancelled = fx.mapper.cancelledPending()
            #expect(cancelled == [.integer(31)])
            #expect(fx.mapper.cancelledPending().isEmpty)
            // While cancellation stays requested, new asks are rejected and a
            // queued prompt cannot start.
            guard case .unsupportedRequest(let id) = try fx.mapper.noteRequest(
                .integer(32), method: "session/request_permission",
                params: permission(32, toolCallID: "tool_fixture_4").params
            ), id == .integer(32) else {
                throw KimiACPWireError.invalidState
            }
            #expect(throws: KimiACPWireError.invalidState) { try fx.mapper.beginPrompt() }
            // The provider's cancelled stop reason confirms the settlement:
            // the turn-scoped flag clears and a new prompt may start.
            try fx.mapper.endPrompt()
            try fx.mapper.beginPrompt()
            table["cancellation"] = .pass
        }

        // Malformed, duplicate, stale: fences, replay, and stale or foreign
        // traffic never creates state.
        do {
            writes = []
            var connection = KimiACPConnection()
            _ = try connection.initialize { writes.append($0) }
            _ = try connection.receive(
                .response(.integer(0), result: .object(["protocolVersion": .number("1")])),
                connection: connection.identity, write: { writes.append($0) }
            )
            var framer = CodexAppServerFramer()
            var fenced = false
            do {
                try framer.receive(Data("garbage-not-json\n".utf8)) { _ in }
            } catch {
                fenced = framer.isClosed
            }
            var mapper = try KimiACPTaskMapper(connectionID: connection.identity, sessionID: sessionID)
            try mapper.beginPrompt()
            let request = permission(41, toolCallID: "tool_fixture_5")
            guard case .serverRequest = try connection.receive(request, connection: connection.identity, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            guard case .attention = try mapper.noteRequest(
                .integer(41), method: "session/request_permission", params: request.params
            ) else {
                throw KimiACPWireError.invalidState
            }
            // Duplicate delivery of an unanswered request prompts no second
            // user ask; redelivery after the answer replays it.
            guard case .duplicateRequest = try connection.receive(request, connection: connection.identity, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            let prepared = try connection.prepareAnswer(.integer(41), result: .object([
                "outcome": .object(["outcome": .string("selected"), "optionId": .string("reject-once")])
            ]))
            try connection.confirmResponseWritten(prepared)
            try mapper.markAnswered(.integer(41))
            guard case .replayedResponse = try connection.receive(request, connection: connection.identity, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            // Stale: without an active prompt a request is rejected, never
            // answered; foreign session updates create no state.
            try mapper.endPrompt()
            guard case .unsupportedRequest = try mapper.noteRequest(
                .integer(42), method: "session/request_permission",
                params: permission(42, toolCallID: "tool_fixture_6").params
            ) else {
                throw KimiACPWireError.invalidState
            }
            let foreign = CodexAppServerMessage.notification(method: "session/update", params: .object([
                "sessionId": .string("kimi_other_session"),
                "update": .object(["sessionUpdate": .string("agent_message_chunk")])
            ]))
            #expect(try mapper.map(foreign, connection: connection.identity).isEmpty)
            #expect(fenced)
            table["malformed-duplicate-stale"] = .pass
        }

        // Reconnect: no transport reconnect on owned stdio ACP.
        table["reconnect"] = .unsupported(
            "Owned-child stdio ACP has no transport reconnect or replay cursor: the profile declares"
            + " unordered delivery with replay none, channel loss closes the session and revokes the"
            + " control authority, and pending-ask evidence after the gap stays unknown, never \"no"
            + " pending\". session/resume is an explicit user action in a new attempt"
        )

        // Relaunch: a new process is a new attempt; nothing auto-starts.
        do {
            var fx = try readyFixture(&writes)
            try fx.mapper.endPrompt()
            fx.mapper.close()
            fx.connection.close()
            #expect(throws: KimiACPWireError.invalidState) { try fx.mapper.beginPrompt() }
            #expect(try fx.mapper.map(chunk("late"), connection: fx.connectionID) == [.needsReconciliation])
            let dead = permission(43, toolCallID: "tool_fixture_7")
            #expect(throws: KimiACPWireError.closed) {
                _ = try fx.connection.receive(dead, connection: fx.connectionID, write: { writes.append($0) })
            }
            // A fresh connection and mapper namespace is a new attempt.
            var freshConnection = KimiACPConnection()
            _ = try freshConnection.initialize { writes.append($0) }
            _ = try freshConnection.receive(
                .response(.integer(0), result: .object(["protocolVersion": .number("1")])),
                connection: freshConnection.identity, write: { writes.append($0) }
            )
            var fresh = try KimiACPTaskMapper(connectionID: freshConnection.identity, sessionID: sessionID)
            try fresh.beginPrompt()
            #expect(fresh.promptActive)
            table["relaunch"] = .pass
        }

        // Evidence fencing: foreign sessions and connections never cross
        // over; shared references are deterministic digests.
        do {
            var fx = try readyFixture(&writes)
            let request = permission(51, toolCallID: "tool_fixture_8")
            guard case .serverRequest = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            guard case .attention(let attention, .integer(51), _) = try fx.mapper.noteRequest(
                .integer(51), method: "session/request_permission", params: request.params
            ) else {
                throw KimiACPWireError.invalidState
            }
            #expect(attention.request.rawValue.utf8.count == 64)
            #expect(attention.request.rawValue.allSatisfy { "0123456789abcdef".contains($0) })
            // The digest is deterministic across mapper instances.
            var second = try KimiACPTaskMapper(connectionID: UUID(), sessionID: sessionID)
            try second.beginPrompt()
            guard case .attention(let secondAttention, _, _) = try second.noteRequest(
                .integer(51), method: "session/request_permission", params: request.params
            ) else {
                throw KimiACPWireError.invalidState
            }
            #expect(secondAttention.request == attention.request)
            // A foreign session's request is rejected, never answered.
            let foreign = CodexAppServerMessage.request(.integer(52), method: "session/request_permission",
                                                        params: .object([
                "sessionId": .string("kimi_other_session"),
                "toolCall": .object(["toolCallId": .string("tool_fixture_9")]),
                "options": .array([
                    .object(["optionId": .string("allow-once"), "name": .string("Allow once"),
                             "kind": .string("allow_once")]),
                    .object(["optionId": .string("reject-once"), "name": .string("Reject"),
                             "kind": .string("reject_once")])
                ])
            ]))
            guard case .unsupportedRequest(let id) = try fx.mapper.noteRequest(
                .integer(52), method: "session/request_permission", params: foreign.params
            ), id == .integer(52) else {
                throw KimiACPWireError.invalidState
            }
            // A foreign connection identity creates no state anywhere.
            #expect(try fx.mapper.map(chunk("foreign"), connection: UUID()).isEmpty)
            guard case .ignoredForeignConnection = try fx.connection.receive(request, connection: UUID(), write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            table["evidence-fencing"] = .pass
        }

        // Backpressure: bounded pending asks fail closed.
        do {
            var fx = try readyFixture(&writes)
            for index in 0..<KimiACPConnection.maximumServerRequests {
                let request = permission(Int64(100 + index), toolCallID: "tool_bp_\(index)")
                _ = try fx.connection.receive(request, connection: fx.connectionID, write: { writes.append($0) })
                guard case .attention = try fx.mapper.noteRequest(
                    .integer(Int64(100 + index)), method: "session/request_permission", params: request.params
                ) else {
                    throw KimiACPWireError.invalidState
                }
            }
            let overflow = permission(200, toolCallID: "tool_overflow")
            do {
                _ = try fx.mapper.noteRequest(.integer(200), method: "session/request_permission",
                                              params: overflow.params)
                throw KimiACPWireError.capacity
            } catch KimiACPWireError.capacity {}
            table["backpressure"] = .pass
        }

        // Secret-bearing payloads: the wire codec redacts, shared candidates
        // and references are digest-only, and the written answer carries the
        // user's choice, never the request text. The form retains the question
        // message for presentation only (bounded, in-memory), not as a shared
        // reference.
        do {
            var fx = try readyFixture(&writes)
            let secret = "SECRET-KIMI-PAYLOAD-\(UUID().uuidString)"
            let request = question(61, message: secret)
            #expect(request.description == "<redacted:codex-wire-message>")
            guard case .serverRequest = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            guard case .attention(let attention, .integer(61), _) = try fx.mapper.noteRequest(
                .integer(61), method: "elicitation/create", params: request.params
            ) else {
                throw KimiACPWireError.invalidState
            }
            let candidate = try CandidateAttentionEvent(
                scope: .session, phase: .waitingForQuestion,
                request: attention.request, context: attention.context
            )
            #expect(!String(reflecting: candidate).contains(secret))
            #expect(!String(reflecting: attention).contains(secret))
            let form = try #require(attention.form)
            let content = try form.content(answers: ["choice": ["blue"]])
            let prepared = try fx.connection.prepareAnswer(
                .integer(61), result: .object(["action": .string("accept"), "content": content])
            )
            let answerText = String(data: prepared.bytes, encoding: .utf8) ?? ""
            #expect(!answerText.contains(secret) && answerText.contains("blue"))
            try fx.connection.confirmResponseWritten(prepared)
            try fx.mapper.markAnswered(.integer(61))
            guard case .replayedResponse = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw KimiACPWireError.invalidState
            }
            let replayText = String(data: try #require(writes.last), encoding: .utf8) ?? ""
            #expect(!replayText.contains(secret))
            table["secret-bearing-payloads"] = .pass
        }

        expectProviderContractOutcomes(table, provider: "Kimi")
    }
}
