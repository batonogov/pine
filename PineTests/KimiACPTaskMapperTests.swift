import Foundation
import Testing
@testable import Pine

struct KimiACPTaskMapperTests {
    private let connection = UUID()
    private let sessionID = "kimi_fixture_new"

    private func mapper() throws -> KimiACPTaskMapper {
        try KimiACPTaskMapper(connectionID: connection, sessionID: sessionID)
    }

    private func update(_ kind: String, extra: [String: AgentEventJSON] = [:]) -> CodexAppServerMessage {
        var update: [String: AgentEventJSON] = ["sessionUpdate": .string(kind)]
        for (key, value) in extra { update[key] = value }
        return .notification(method: "session/update", params: .object([
            "sessionId": .string(sessionID), "update": .object(update)
        ]))
    }

    private func permission(_ id: Int64, toolCallID: String? = "tool_fixture_1") -> CodexAppServerMessage {
        var toolCall: [String: AgentEventJSON] = ["title": .string("Fixture write"), "kind": .string("edit")]
        if let toolCallID { toolCall["toolCallId"] = .string(toolCallID) }
        return .request(.integer(id), method: "session/request_permission", params: .object([
            "sessionId": .string(sessionID),
            "toolCall": .object(toolCall),
            "options": .array([
                .object(["optionId": .string("allow-once"), "name": .string("Allow once"),
                         "kind": .string("allow_once")]),
                .object(["optionId": .string("reject-once"), "name": .string("Reject"),
                         "kind": .string("reject_once")])
            ])
        ]))
    }

    private func question(_ id: Int64, mode: String = "form") -> CodexAppServerMessage {
        var fields: [String: AgentEventJSON] = [
            "sessionId": .string(sessionID), "mode": .string(mode),
            "message": .string("Fixture question")
        ]
        if mode == "form" {
            fields["requestedSchema"] = .object([
                "type": .string("object"), "required": .array([.string("choice")]),
                "properties": .object(["choice": .object([
                    "type": .string("string"),
                    "oneOf": .array([
                        .object(["const": .string("blue"), "title": .string("Blue")]),
                        .object(["const": .string("amber"), "title": .string("Amber")])
                    ])
                ])])
            ])
        } else {
            fields["elicitationId"] = .string("fixture-oauth")
            fields["url"] = .string("https://fixture.example/authorize")
        }
        return .request(.integer(id), method: "elicitation/create", params: .object(fields))
    }

    @Test func invalidSessionIDIsRefused() {
        #expect(throws: KimiACPWireError.invalidSessionID) {
            _ = try KimiACPTaskMapper(connectionID: connection, sessionID: "")
        }
    }

    @Test func requestsWithoutAnActivePromptAreStale() throws {
        var mapper = try mapper()
        #expect(try mapper.noteRequest(.integer(1), method: "session/request_permission",
                                       params: permission(1).params)
            == .unsupportedRequest(.integer(1)))
        #expect(try mapper.noteRequest(.integer(2), method: "elicitation/create",
                                       params: question(2).params)
            == .unsupportedRequest(.integer(2)))
    }

    @Test func permissionProducesExactScopedAttention() throws {
        var mapper = try mapper()
        try mapper.beginPrompt()
        let effect = try mapper.noteRequest(.integer(5), method: "session/request_permission",
                                            params: permission(5).params)
        guard case .attention(let attention, let wireID, let method) = effect else {
            Issue.record("Expected attention"); return
        }
        #expect(wireID == .integer(5))
        #expect(method == "session/request_permission")
        #expect(attention.context.role == .conversation)
        #expect(attention.context.rawValue == sessionID)
        #expect(attention.request.role == .request)
        #expect(attention.toolCall?.rawValue == "tool_fixture_1")
        #expect(attention.options["allow_once"] == "allow-once")
        #expect(attention.options["reject_once"] == "reject-once")
        #expect(attention.form == nil)
        #expect(mapper.isActionable(.integer(5)))
        // Redelivery of the same request is a duplicate, not a second ask.
        #expect(try mapper.noteRequest(.integer(5), method: "session/request_permission",
                                       params: permission(5).params)
            == .ignored)
        // The digest reference is deterministic for the same wire ID.
        var second = try self.mapper()
        try second.beginPrompt()
        guard case .attention(let secondAttention, _, _) = try second.noteRequest(
            .integer(5), method: "session/request_permission", params: permission(5).params
        ) else { Issue.record("Expected attention"); return }
        #expect(secondAttention.request == attention.request)
    }

    @Test func permissionMissingDenyOptionIsUnsupported() throws {
        var mapper = try mapper()
        try mapper.beginPrompt()
        let params: AgentEventJSON = .object([
            "sessionId": .string(sessionID),
            "toolCall": .object(["toolCallId": .string("tool_fixture_2")]),
            "options": .array([
                .object(["optionId": .string("allow-once"), "name": .string("Allow once"),
                         "kind": .string("allow_once")])
            ])
        ])
        #expect(try mapper.noteRequest(.integer(6), method: "session/request_permission",
                                       params: params)
            == .unsupportedRequest(.integer(6)))
    }

    @Test func foreignSessionRequestsAreUnsupported() throws {
        var mapper = try mapper()
        try mapper.beginPrompt()
        var fields = try KimiACPWire.object(permission(7).params)
        fields["sessionId"] = .string("kimi_fixture_other")
        #expect(try mapper.noteRequest(.integer(7), method: "session/request_permission",
                                       params: .object(fields))
            == .unsupportedRequest(.integer(7)))
    }

    @Test func formQuestionProducesQuestionAttention() throws {
        var mapper = try mapper()
        try mapper.beginPrompt()
        let effect = try mapper.noteRequest(.integer(8), method: "elicitation/create",
                                            params: question(8).params)
        guard case .attention(let attention, _, let method) = effect else {
            Issue.record("Expected attention"); return
        }
        #expect(method == "elicitation/create")
        #expect(attention.form != nil)
        #expect(attention.options.isEmpty)
        // URL mode is rejected so Kimi falls back to request_permission.
        #expect(try mapper.noteRequest(.integer(9), method: "elicitation/create",
                                       params: question(9, mode: "url").params)
            == .unsupportedRequest(.integer(9)))
    }

    @Test func updatesProjectWorkingWithBoundedChunkText() throws {
        var mapper = try mapper()
        try mapper.beginPrompt()
        let effects = try mapper.map(update("agent_message_chunk", extra: [
            "content": .object(["type": .string("text"), "text": .string("fixture-output")])
        ]), connection: connection)
        #expect(effects == [.working(chunk: "fixture-output")])
        // Thought chunks are activity, not retained result text.
        let thought = try mapper.map(update("agent_thought_chunk", extra: [
            "content": .object(["type": .string("text"), "text": .string("thinking")])
        ]), connection: connection)
        #expect(thought == [.working(chunk: nil)])
        // Unknown future kinds are observed and ignored.
        #expect(try mapper.map(update("pine_future_update"), connection: connection).isEmpty)
        // Foreign sessions are ignored, never fatal.
        let foreign: CodexAppServerMessage = .notification(method: "session/update", params: .object([
            "sessionId": .string("kimi_fixture_other"),
            "update": .object(["sessionUpdate": .string("agent_message_chunk")])
        ]))
        #expect(try mapper.map(foreign, connection: connection).isEmpty)
        // Late activity after the prompt settles is not projected.
        try mapper.endPrompt()
        #expect(try mapper.map(update("agent_message_chunk", extra: [
            "content": .object(["type": .string("text"), "text": .string("late")])
        ]), connection: connection).isEmpty)
    }

    @Test func toolSettlementResolvesAssociatedRequestOnce() throws {
        var mapper = try mapper()
        try mapper.beginPrompt()
        _ = try mapper.noteRequest(.integer(10), method: "session/request_permission",
                                   params: permission(10, toolCallID: "tool_fixture_3").params)
        let effects = try mapper.map(update("tool_call_update", extra: [
            "toolCallId": .string("tool_fixture_3"), "status": .string("completed")
        ]), connection: connection)
        #expect(effects.count == 2)
        guard case .requestResolved(let request)? = effects.first else {
            Issue.record("Expected requestResolved"); return
        }
        #expect(request.role == .request)
        #expect(!mapper.isActionable(.integer(10)))
        // A second settlement of the same tool is silent.
        #expect(try mapper.map(update("tool_call_update", extra: [
            "toolCallId": .string("tool_fixture_3"), "status": .string("completed")
        ]), connection: connection).filter { $0 != .working(chunk: nil) }.isEmpty)
    }

    @Test func cancellationFencesPendingRequests() throws {
        var mapper = try mapper()
        try mapper.beginPrompt()
        _ = try mapper.noteRequest(.integer(11), method: "session/request_permission",
                                   params: permission(11).params)
        #expect(mapper.cancelledPending() == [.integer(11)])
        // No second sweep, no new asks, no answers.
        #expect(mapper.cancelledPending().isEmpty)
        #expect(!mapper.isActionable(.integer(11)))
        #expect(try mapper.noteRequest(.integer(12), method: "session/request_permission",
                                       params: permission(12).params)
            == .unsupportedRequest(.integer(12)))
        // The provider's cancelled stop reason ends the prompt cleanly.
        try mapper.endPrompt()
        #expect(!mapper.promptActive)
    }

    @Test func closedMapperRequiresReconciliation() throws {
        var mapper = try mapper()
        try mapper.beginPrompt()
        mapper.close()
        #expect(try mapper.map(update("agent_message_chunk"), connection: connection)
            == [.needsReconciliation])
        #expect(try mapper.noteRequest(.integer(13), method: "session/request_permission",
                                       params: permission(13).params)
            == .needsReconciliation)
    }

    @Test func unsupportedMethodsNeverReachAttention() throws {
        var mapper = try mapper()
        try mapper.beginPrompt()
        let fs: CodexAppServerMessage = .request(.integer(14), method: "fs/read_text_file",
                          params: .object(["sessionId": .string(sessionID)]))
        #expect(try mapper.noteRequest(.integer(14), method: "fs/read_text_file",
                                       params: fs.params)
            == .unsupportedRequest(.integer(14)))
    }
}
