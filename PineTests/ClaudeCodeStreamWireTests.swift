import Foundation
import Testing
@testable import Pine

struct ClaudeCodeStreamWireTests {
    @Test func systemInitRetainsAllowlistOnly() throws {
        let line = """
        {"type":"system","subtype":"init","uuid":"u-1","session_id":"s-1",\
        "claude_code_version":"2.1.311","cwd":"/Users/someone/secret-project",\
        "model":"fixture-model","current_permission_mode":"default",\
        "tools":["Bash","Read"],"mcp_servers":[{"name":"fixture","status":"connected"}],\
        "capabilities":["interrupt_receipt_v1","ui_surface_v1"],\
        "account":{"tokenSource":"none","apiProvider":"firstParty"}}
        """
        let message = try ClaudeCodeStreamMessage.parse(data: Data(line.utf8))
        guard case .systemInit(sessionID: let session, claudeCodeVersion: let version,
                       permissionMode: let mode,
                               model: let model, capabilities: let caps, account: let account) = message else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(session == "s-1")
        #expect(version == "2.1.311")
        #expect(mode == "default")
        #expect(model == "fixture-model")
        #expect(caps == ["interrupt_receipt_v1", "ui_surface_v1"])
        #expect(account == ClaudeCodeStreamAccountState(tokenSource: .none, provider: .firstParty))
        // cwd, tools, mcp servers, and uuid are dropped at the boundary.
        let rendered = String(describing: message)
        #expect(!rendered.contains("secret-project"))
        #expect(!rendered.contains("fixture"))
    }

    @Test func assistantDropsTextAndRetainsToolCallsOnly() throws {
        let secret = "ASSISTANT-TEXT-\(UUID().uuidString)"
        let line = """
        {"type":"assistant","session_id":"s-1","uuid":"u-2","user_message_uuid":"turn-1",\
        "message":{"role":"assistant","content":[\
        {"type":"text","text":"\(secret)"},\
        {"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"\(secret)"}},\
        {"type":"tool_use","id":"tool-2","name":"Read","input":{"file_path":"\(secret)"}}]}}
        """
        let message = try ClaudeCodeStreamMessage.parse(data: Data(line.utf8))
        // Full structural equality: the allowlist is exactly these fields;
        // the text and tool inputs are gone by construction.
        #expect(message == .assistant(
            sessionID: "s-1", userMessageUUID: "turn-1",
            toolCalls: [
                ClaudeCodeToolCall(id: "tool-1", name: "Bash"),
                ClaudeCodeToolCall(id: "tool-2", name: "Read")
            ]
        ))
        #expect(!String(describing: message).contains(secret))
    }

    @Test func userToolResultsAreBoundedAndContentFree() throws {
        let line = """
        {"type":"user","session_id":"s-1","message":{"role":"user","content":[\
        {"type":"tool_result","tool_use_id":"tool-1","content":"SECRET-RESULT-CONTENT",\
        "is_error":true}]}}
        """
        let message = try ClaudeCodeStreamMessage.parse(data: Data(line.utf8))
        guard case .userToolResults(sessionID: "s-1", results: let results) = message else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(results == [ClaudeCodeToolResult(toolUseID: "tool-1", isError: true)])
        #expect(!String(describing: message).contains("SECRET-RESULT-CONTENT"))
    }

    @Test func resultSubtypesAreClosedAndUnretained() throws {
        for (subtype, expected) in [
            ("success", ClaudeCodeResultSubtype.success),
            ("error_max_turns", .errorMaxTurns),
            ("error_during_execution", .errorDuringExecution)
        ] {
            let line = """
            {"type":"result","subtype":"\(subtype)","session_id":"s-1",\
            "result":"SECRET-RESULT-TEXT","num_turns":3,"total_cost_usd":1.5}
            """
            let message = try ClaudeCodeStreamMessage.parse(data: Data(line.utf8))
            #expect(message == .result(sessionID: "s-1", subtype: expected))
            #expect(!String(describing: message).contains("SECRET-RESULT-TEXT"))
        }
        #expect(throws: ClaudeCodeWireError.invalidEnvelope) {
            _ = try ClaudeCodeStreamMessage.parse(data: Data(
                #"{"type":"result","subtype":"future","session_id":"s-1"}"#.utf8))
        }
        #expect(throws: ClaudeCodeWireError.invalidEnvelope) {
            _ = try ClaudeCodeStreamMessage.parse(data: Data(#"{"type":"result"}"#.utf8))
        }
    }

    @Test func permissionRequestDropsProviderInput() throws {
        let secret = "TOOL-INPUT-\(UUID().uuidString)"
        let line = """
        {"type":"control_request","request_id":"req-1",\
        "request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-9",\
        "agent_id":"agent-1","permission_suggestions":[{"type":"rule"}],\
        "decision_reason":"\(secret)","input":{"command":"\(secret)"}}}
        """
        let message = try ClaudeCodeStreamMessage.parse(data: Data(line.utf8))
        #expect(message == .permissionRequest(
            .init(id: try ClaudeCodeControlRequestID("req-1"),
                  toolName: "Bash", toolUseID: "tool-9", agentID: "agent-1")
        ))
        #expect(!String(describing: message).contains(secret))
    }

    @Test func unsupportedControlRequestsRetainNothing() throws {
        let line = """
        {"type":"control_request","request_id":"req-2",\
        "request":{"subtype":"future_control","payload":{"secret":"PAYLOAD"}}}
        """
        let message = try ClaudeCodeStreamMessage.parse(data: Data(line.utf8))
        guard case .unsupportedControlRequest(id: let id, subtype: "future_control") = message else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(id.value == "req-2")
        #expect(!String(describing: message).contains("PAYLOAD"))
    }

    @Test func initializeResponseRedeliversPendingRequests() throws {
        let envelope = """
        {"type":"control_response","response":{"subtype":"success","request_id":"init-1",\
        "response":{"claude_code_version":"2.1.311","account":{"tokenSource":"none","apiProvider":"firstParty"}},\
        "pending_permission_requests":[\
        {"type":"control_request","request_id":"perm-a",\
        "request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-a","input":{"x":"SECRET"}}},\
        {"type":"control_request","request_id":"perm-b",\
        "request":{"subtype":"can_use_tool","tool_name":"Read","tool_use_id":"tool-b"}}],\
        "pending_user_dialog_requests":[{"type":"control_request","request_id":"dlg-1","request":{}}]}}
        """
        let message = try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))
        guard case .controlResponseSuccess(requestID: let id, claudeCodeVersion: let version, account: let account,
                                           redelivered: let redelivered, userDialogRequestCount: let dialogs,
                                           interruptReceipt: nil) = message else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(id.value == "init-1")
        #expect(version == "2.1.311")
        #expect(account == ClaudeCodeStreamAccountState(tokenSource: .none, provider: .firstParty))
        #expect(redelivered.count == 2)
        #expect(redelivered[0].toolUseID == "tool-a")
        #expect(redelivered[1].toolName == "Read")
        #expect(dialogs == 1)
        #expect(!String(describing: message).contains("SECRET"))
        // A redelivered entry of an unrecognized subtype fences, not skips.
        let badEnvelope = envelope.replacingOccurrences(
            of: "\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Read\",\"tool_use_id\":\"tool-b\"}",
            with: "\"request\":{\"subtype\":\"future\",\"tool_name\":\"Read\",\"tool_use_id\":\"tool-b\"}"
        )
        #expect(throws: ClaudeCodeWireError.invalidEnvelope) {
            _ = try ClaudeCodeStreamMessage.parse(data: Data(badEnvelope.utf8))
        }
    }

    @Test func interruptReceiptIsBounded() throws {
        let envelope = """
        {"type":"control_response","response":{"subtype":"success","request_id":"int-1",\
        "response":{"still_queued":["q-1","q-2"],"cancelled":[]}}}
        """
        let message = try ClaudeCodeStreamMessage.parse(data: Data(envelope.utf8))
        guard case .controlResponseSuccess(requestID: _, claudeCodeVersion: nil, account: nil, redelivered: [],
                                           userDialogRequestCount: 0, interruptReceipt: let receipt) = message else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(receipt?.stillQueued == ["q-1", "q-2"])
        #expect(receipt?.cancelled == [])
        // Absent receipt fields mean no interrupt response, not an empty queue.
        let envelopeWithout = """
        {"type":"control_response","response":{"subtype":"success","request_id":"int-2","response":{}}}
        """
        let other = try ClaudeCodeStreamMessage.parse(data: Data(envelopeWithout.utf8))
        guard case .controlResponseSuccess(requestID: _, claudeCodeVersion: nil, account: nil, redelivered: [],
                                           userDialogRequestCount: 0, interruptReceipt: let none) = other else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(none == nil)
    }

    @Test func dataOnlyKindsNeverRetainPayloads() throws {
        for line in [
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"text":"SECRET"}}}"#,
            #"{"type":"hook_progress","hook_event_name":"Stop","stdout":"SECRET"}"#,
            #"{"type":"future_event","payload":"SECRET"}"#
        ] {
            let message = try ClaudeCodeStreamMessage.parse(data: Data(line.utf8))
            guard case .dataOnly(let kind) = message else { throw ClaudeCodeWireError.invalidEnvelope }
            #expect(!kind.isEmpty)
            #expect(!String(describing: message).contains("SECRET"))
        }
    }

    @Test func malformedFramesThrow() {
        for line in [
            "{",
            "not json",
            #"{"subtype":"init"}"#,
            #"{"type":"assistant"}"#,
            #"{"type":"system"}"#,
            #"{"type":"result","subtype":"success"}"#,
            #"{"type":"control_response","response":{"subtype":"weird","request_id":"x"}}"#,
            #"{"type":"control_request","request":{"subtype":"can_use_tool"}}"#
        ] {
            #expect(throws: ClaudeCodeWireError.self) {
                _ = try ClaudeCodeStreamMessage.parse(data: Data(line.utf8))
            }
        }
    }

    @Test func framerBoundsAndFencesIngress() throws {
        var framer = ClaudeCodeStreamFramer()
        var delivered = 0
        try framer.receive(Data(#"{"type":"system","subtype":"init","session_id":"s-1"}"#.utf8)) { _ in delivered += 1 }
        #expect(delivered == 1)
        // Oversized frame.
        let big = String(repeating: "a", count: ClaudeCodeStreamFramer.maximumFrameBytes)
        #expect(throws: ClaudeCodeWireError.frameTooLarge) {
            try framer.receive(Data(("{\(big)\n").utf8)) { _ in }
        }
        #expect(framer.isClosed)
        #expect(throws: ClaudeCodeWireError.closed) {
            try framer.receive(Data("x\n".utf8)) { _ in }
        }

        var nested = ClaudeCodeStreamFramer()
        let deep = String(repeating: "[", count: ClaudeCodeStreamFramer.maximumDepth + 1)
            + String(repeating: "]", count: ClaudeCodeStreamFramer.maximumDepth + 1)
        #expect(throws: ClaudeCodeWireError.nestingTooDeep) {
            try nested.receive(Data(("{\(deep)\n").utf8)) { _ in }
        }

        var truncated = ClaudeCodeStreamFramer()
        try truncated.receive(Data(#"{"type":"system""#.utf8)) { _ in }
        #expect(throws: ClaudeCodeWireError.truncatedFrame) { try truncated.finish() }

        var empty = ClaudeCodeStreamFramer()
        #expect(throws: ClaudeCodeWireError.invalidEnvelope) {
            try empty.receive(Data("\n".utf8)) { _ in }
        }
    }

    @Test func egressEncodesDeterministicFrames() throws {
        let user = try ClaudeCodeStreamMessage.userMessage(
            text: "Fix the failing test", messageUUID: "msg-1", sessionID: "s-1")
        var userParser = AgentEventJSONParser(data: user.dropLast())
        let parsedUser = try userParser.parse()
        guard case .object(let userFields) = parsedUser else { throw ClaudeCodeWireError.invalidEnvelope }
        #expect(userFields["type"] == .string("user"))
        #expect(userFields["uuid"] == .string("msg-1"))
        #expect(userFields["session_id"] == .string("s-1"))
        #expect(userFields["parent_tool_use_id"] == .null)

        let id = try ClaudeCodeControlRequestID("req-1")
        let interrupt = try ClaudeCodeStreamMessage.interruptRequest(id: id, cancelQueued: true)
        var interruptParser = AgentEventJSONParser(data: interrupt.dropLast())
        let parsedInterrupt = try interruptParser.parse()
        guard case .object(let interruptFields) = parsedInterrupt else { throw ClaudeCodeWireError.invalidEnvelope }
        #expect(interruptFields["request_id"] == .string("req-1"))
        guard case .object(let requestFields) = interruptFields["request"] ?? .null else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(requestFields["subtype"] == .string("interrupt"))
        #expect(requestFields["cancel_queued"] == .bool(true))

        let noCancel = try ClaudeCodeStreamMessage.interruptRequest(id: id, cancelQueued: false)
        var noCancelParser = AgentEventJSONParser(data: noCancel.dropLast())
        let parsedNoCancel = try noCancelParser.parse()
        guard case .object(let noCancelFields) = parsedNoCancel else { throw ClaudeCodeWireError.invalidEnvelope }
        guard case .object(let noCancelRequest) = noCancelFields["request"] ?? .null else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(noCancelRequest["cancel_queued"] == nil)

        let allow = try ClaudeCodeStreamMessage.permissionAllowResponse(id: id, toolUseID: "tool-1")
        let parsedAllow = try ClaudeCodeStreamMessage.parse(data: allow)
        guard case .controlResponseSuccess(requestID: let allowID, claudeCodeVersion: nil, account: nil,
                                           redelivered: [], userDialogRequestCount: 0, interruptReceipt: nil) = parsedAllow else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(allowID == id)

        let deny = try ClaudeCodeStreamMessage.permissionDenyResponse(id: id, toolUseID: "tool-1")
        var denyParser = AgentEventJSONParser(data: deny.dropLast())
        let parsedDeny = try denyParser.parse()
        guard case .object(let denyFields) = parsedDeny, case .object(let denyResponse) =
            denyFields["response"] ?? .null else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        guard case .object(let behavior) = denyResponse["response"] ?? .null else {
            throw ClaudeCodeWireError.invalidEnvelope
        }
        #expect(behavior["behavior"] == .string("deny"))
        #expect(behavior["message"] == .string("Denied in Pine."))
    }

    @Test func diagnosticsRedactProviderIdentifiers() throws {
        let id = try ClaudeCodeControlRequestID("secret-request-id")
        #expect(id.description == "<redacted:claude-request-id>")
        let message = try ClaudeCodeStreamMessage.parse(data: Data(
            #"{"type":"system","subtype":"init","session_id":"s-1"}"#.utf8))
        #expect(message.description == "<redacted:claude-stream-message>")
        #expect(message.debugDescription == message.description)
    }
}
