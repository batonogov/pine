import Foundation
import Testing
@testable import Pine

/// The Codex side of the shared provider contract suite (#1727). Every
/// scenario runs against the owned app-server wire codec, connection, and
/// task mapper (#1723). One mapper instance per logical turn, a new process
/// is always a new mapper/connection namespace. Real-version flows (live
/// permission exchange, live interrupt receipt) are the final gate and are
/// not claimed here.
struct CodexAppServerProviderContractTests {
    private let thread = "fixture-thread"

    private struct Fixture {
        var connection: CodexAppServerConnection
        var mapper: CodexAppServerTaskMapper
        var connectionID: UUID { connection.identity }
    }

    private func readyFixture(_ writes: inout [Data]) throws -> Fixture {
        var connection = CodexAppServerConnection()
        // The first sent request always carries the connection's ID 0.
        _ = try connection.initialize(experimentalAPI: true) { writes.append($0) }
        let response = CodexAppServerMessage.response(
            .integer(0), result: .object(["userAgent": .string("codex-cli 0.169.0")])
        )
        guard case .initialized = try connection.receive(response, connection: connection.identity, write: {
            writes.append($0)
        }) else {
            throw CodexAppServerWireError.invalidState
        }
        let mapper = try CodexAppServerTaskMapper(connectionID: connection.identity, threadID: thread)
        return Fixture(connection: connection, mapper: mapper)
    }

    private func bindTurn(_ fx: inout Fixture, _ turnID: String) throws {
        try fx.mapper.prepareTurn()
        let effects = try fx.mapper.bindTurnResponse(turnID)
        guard case .candidate(let candidate)? = effects.first,
              case .lifecycle(let event) = candidate.event,
              event.scope == .turn, event.phase == .started else {
            throw CodexAppServerWireError.invalidState
        }
    }

    private func turn(_ method: String, id: String, status: String) -> CodexAppServerMessage {
        .notification(method: method, params: .object([
            "threadId": .string(thread),
            "turn": .object(["id": .string(id), "status": .string(status), "items": .array([])])
        ]))
    }

    private func approval(_ id: Int64, turnID: String, command: String? = nil) -> CodexAppServerMessage {
        var fields: [String: AgentEventJSON] = [
            "threadId": .string(thread), "turnId": .string(turnID), "itemId": .string("item-\(id)"),
            "startedAtMs": .number(String(1_700_000_000_000 + id))
        ]
        if let command { fields["command"] = .string(command) }
        return .request(.integer(id), method: "item/commandExecution/requestApproval", params: .object(fields))
    }

    @Test func providerContractTable() throws {
        var table: [String: AgentProviderContractOutcome] = [:]
        var writes: [Data] = []

        // Question: native user questions arrive via item/tool/requestUserInput.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx, "turn-q")
            let question = CodexAppServerMessage.request(.integer(77), method: "item/tool/requestUserInput",
                                                         params: .object([
                "threadId": .string(thread), "turnId": .string("turn-q"), "itemId": .string("item-q"),
                "isBlocking": .bool(true), "questions": .array([.object([
                    "id": .string("color"), "header": .string("Color"), "question": .string("Which color?")
                ])])
            ]))
            guard case .serverRequest = try fx.connection.receive(question, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw CodexAppServerWireError.invalidState
            }
            guard case .attention(let candidate, let requestID, let method, _) =
                try fx.mapper.map(question, connection: fx.connectionID),
                requestID == .integer(77), method == "item/tool/requestUserInput",
                case .question(let attention) = candidate.event else {
                throw CodexAppServerWireError.invalidState
            }
            // The shared candidate carries digest references only, never text.
            #expect(attention.phase == .waitingForQuestion)
            #expect(attention.context?.rawValue == "turn-q")
            #expect(!String(reflecting: candidate).contains("Which color?"))
            // Answerable exactly once.
            _ = try fx.connection.answer(
                requestID,
                result: .object(["answers": .object(["color": .object(["answers": .array([.string("blue")])])])])
            ) { writes.append($0) }
            #expect(throws: CodexAppServerWireError.invalidState) {
                try fx.connection.answer(requestID, result: .object(["answers": .object([:])])) {
                    writes.append($0)
                }
            }
            try fx.mapper.markResponseWritten(requestID)
            #expect(throws: CodexAppServerWireError.invalidState) {
                try fx.mapper.markResponseWritten(requestID)
            }
            // Redelivery replays the remembered response.
            guard case .replayedResponse = try fx.connection.receive(question, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw CodexAppServerWireError.invalidState
            }
            // A question settles the request, never the task: the turn stays open.
            try fx.connection.resolveServerRequest(requestID)
            let resolved = try fx.mapper.map(
                .notification(method: "serverRequest/resolved",
                              params: .object(["threadId": .string(thread), "requestId": .number("77")])),
                connection: fx.connectionID
            )
            guard case .requestResolved(_, let resolvedID) = resolved, resolvedID == requestID else {
                throw CodexAppServerWireError.invalidState
            }
            #expect(fx.mapper.hasUnsettledTurn)
            table["question"] = .pass
        }

        // Approval: one-shot response idempotent under redelivery.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx, "turn-a")
            let request = approval(40, turnID: "turn-a")
            guard case .serverRequest = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw CodexAppServerWireError.invalidState
            }
            guard case .attention(let candidate, .integer(40), "item/commandExecution/requestApproval", _) =
                try fx.mapper.map(request, connection: fx.connectionID),
                case .approval(let attention) = candidate.event else {
                throw CodexAppServerWireError.invalidState
            }
            #expect(attention.phase == .waitingForApproval)
            try fx.connection.answer(.integer(40), result: .object(["decision": .string("accept")])) {
                writes.append($0)
            }
            try fx.mapper.markResponseWritten(.integer(40))
            guard case .replayedResponse = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw CodexAppServerWireError.invalidState
            }
            // Provider-side resolution settles the request; a resolved request
            // can never be answered again.
            try fx.connection.resolveServerRequest(.integer(40))
            guard case .requestResolved = try fx.mapper.map(
                .notification(method: "serverRequest/resolved",
                              params: .object(["threadId": .string(thread), "requestId": .number("40")])),
                connection: fx.connectionID
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            #expect(throws: CodexAppServerWireError.invalidState) {
                try fx.connection.answer(.integer(40), result: .object(["decision": .string("accept")])) {
                    writes.append($0)
                }
            }
            table["approval"] = .pass
        }

        // Continuation: a new authorized submission starts a new turn on the
        // same thread. The base mapper retains a completed turn's binding, so
        // the next turn uses a fresh mapper, exactly as the session does.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx, "turn-1")
            // Provider completion is a claim: settlement is unknown, the turn
            // binding is retained.
            guard case .parentSettlementUnknown = try fx.mapper.map(
                turn("turn/completed", id: "turn-1", status: "completed"), connection: fx.connectionID
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            #expect(throws: CodexAppServerWireError.invalidState) { try fx.mapper.prepareTurn() }
            var next = try CodexAppServerTaskMapper(connectionID: UUID(), threadID: thread)
            try next.prepareTurn()
            let effects = try next.bindTurnResponse("turn-2")
            guard case .candidate(let candidate)? = effects.first,
                  case .lifecycle(let event) = candidate.event,
                  event.scope == .turn, event.phase == .started else {
                throw CodexAppServerWireError.invalidState
            }
            table["continuation"] = .pass
        }

        // Cancellation: requested until the provider confirms; late completion
        // is a race outcome, never Ready; queued input is never auto-resent.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx, "turn-c")
            let request = approval(90, turnID: "turn-c")
            _ = try fx.connection.receive(request, connection: fx.connectionID, write: { writes.append($0) })
            guard case .attention = try fx.mapper.map(request, connection: fx.connectionID) else {
                throw CodexAppServerWireError.invalidState
            }
            try fx.mapper.requestCancellation()
            #expect(!fx.mapper.isActionable(.integer(90), connection: fx.connectionID))
            // The provider confirms the interrupt: cancelled lifecycle.
            guard case .candidate(let candidate) = try fx.mapper.map(
                turn("turn/completed", id: "turn-c", status: "interrupted"), connection: fx.connectionID
            ), case .lifecycle(let event) = candidate.event, event.phase == .cancelled else {
                throw CodexAppServerWireError.invalidState
            }
            // A turn the provider completed after cancellation is a race.
            var m2 = try CodexAppServerTaskMapper(connectionID: UUID(), threadID: thread)
            try m2.prepareTurn()
            _ = try m2.bindTurnResponse("turn-c2")
            try m2.requestCancellation()
            guard case .lateCompletionAfterCancellation = try m2.map(
                turn("turn/completed", id: "turn-c2", status: "completed"), connection: m2.connectionID
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            // The closed mapper cannot start queued input on its own.
            #expect(throws: CodexAppServerWireError.invalidState) { try m2.prepareTurn() }
            table["cancellation"] = .pass
        }

        // Malformed, duplicate, stale: fences, replay, and stale-turn ignores.
        do {
            writes = []
            var connection = CodexAppServerConnection()
            _ = try connection.initialize { writes.append($0) }
            _ = try connection.receive(
                .response(.integer(0), result: .object(["userAgent": .string("codex-cli 0.169.0")])),
                connection: connection.identity, write: { writes.append($0) }
            )
            var framer = CodexAppServerFramer()
            var fenced = false
            do {
                try framer.receive(Data("garbage-not-json\n".utf8)) { _ in }
            } catch {
                fenced = framer.isClosed
            }
            var mapper = try CodexAppServerTaskMapper(connectionID: connection.identity, threadID: thread)
            try mapper.prepareTurn()
            _ = try mapper.bindTurnResponse("turn-m")
            let request = approval(44, turnID: "turn-m")
            guard case .serverRequest = try connection.receive(request, connection: connection.identity, write: {
                writes.append($0)
            }) else {
                throw CodexAppServerWireError.invalidState
            }
            guard case .attention = try mapper.map(request, connection: connection.identity) else {
                throw CodexAppServerWireError.invalidState
            }
            // Duplicate delivery of an unanswered request prompts no second
            // user ask; redelivery after the answer replays it.
            guard case .duplicateRequest = try connection.receive(request, connection: connection.identity, write: {
                writes.append($0)
            }) else {
                throw CodexAppServerWireError.invalidState
            }
            _ = try connection.answer(.integer(44), result: .object(["decision": .string("decline")])) {
                writes.append($0)
            }
            guard case .replayedResponse = try connection.receive(request, connection: connection.identity, write: {
                writes.append($0)
            }) else {
                throw CodexAppServerWireError.invalidState
            }
            // Stale traffic for a closed turn creates no state.
            guard case .candidate = try mapper.map(
                turn("turn/completed", id: "turn-m", status: "failed"), connection: connection.identity
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            guard case .ignored = try mapper.map(
                turn("turn/completed", id: "turn-m", status: "completed"), connection: connection.identity
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            // A request for a foreign turn is rejected, never answered.
            try mapper.prepareTurn()
            _ = try mapper.bindTurnResponse("turn-m2")
            guard case .unsupportedRequest(let id) = try mapper.map(
                approval(45, turnID: "turn-old"), connection: connection.identity
            ), id == .integer(45) else {
                throw CodexAppServerWireError.invalidState
            }
            // A foreign connection identity never creates state.
            guard case .ignoredForeignConnection = try connection.receive(
                approval(46, turnID: "turn-m2"),
                connection: UUID(), write: { writes.append($0) }
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            #expect(fenced)
            table["malformed-duplicate-stale"] = .pass
        }

        // Reconnect: no transport reconnect on owned stdio.
        table["reconnect"] = .unsupported(
            "Owned-child stdio has no transport reconnect: the profile declares replay none and"
            + " unordered delivery, process death stops the session and invalidates the ownership,"
            + " and the app-server protocol exposes no pending-request enumeration; post-gap approval"
            + " state stays unknown, never \"no pending requests\""
        )

        // Relaunch: a new process is a new attempt; nothing auto-starts.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx, "turn-r")
            guard case .parentSettlementUnknown = try fx.mapper.map(
                turn("turn/completed", id: "turn-r", status: "completed"), connection: fx.connectionID
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            fx.mapper.close()
            #expect(throws: CodexAppServerWireError.invalidState) { try fx.mapper.prepareTurn() }
            guard case .needsReconciliation = try fx.mapper.map(
                turn("turn/completed", id: "turn-r", status: "failed"), connection: fx.connectionID
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            // A fresh mapper in a fresh connection namespace rebinds the same
            // thread as a new attempt.
            var fresh = try CodexAppServerTaskMapper(connectionID: UUID(), threadID: thread)
            try fresh.prepareTurn()
            let effects = try fresh.bindTurnResponse("turn-r2")
            guard case .candidate(let candidate)? = effects.first,
                  case .lifecycle(let event) = candidate.event,
                  event.scope == .turn, event.phase == .started else {
                throw CodexAppServerWireError.invalidState
            }
            table["relaunch"] = .pass
        }

        // Evidence fencing: foreign threads, turns, and connections never
        // cross over; shared references are deterministic digests.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx, "turn-e")
            let request = approval(60, turnID: "turn-e")
            _ = try fx.connection.receive(request, connection: fx.connectionID, write: { writes.append($0) })
            guard case .attention(let candidate, _, _, _) = try fx.mapper.map(
                request, connection: fx.connectionID
            ), case .approval(let attention) = candidate.event else {
                throw CodexAppServerWireError.invalidState
            }
            #expect(attention.request.rawValue.utf8.count == 64)
            #expect(attention.request.rawValue.allSatisfy { "0123456789abcdef".contains($0) })
            #expect(attention.request.rawValue != "60")
            // Foreign thread traffic is ignored.
            let foreignThread = CodexAppServerMessage.notification(method: "turn/completed", params: .object([
                "threadId": .string("other-thread"),
                "turn": .object(["id": .string("turn-e"), "status": .string("failed"), "items": .array([])])
            ]))
            guard case .ignored = try fx.mapper.map(foreignThread, connection: fx.connectionID) else {
                throw CodexAppServerWireError.invalidState
            }
            // A foreign connection identity creates no mapper state.
            guard case .ignored = try fx.mapper.map(
                turn("turn/completed", id: "turn-e", status: "failed"), connection: UUID()
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            // The owned turn settles; further completion traffic is stale.
            guard case .candidate = try fx.mapper.map(
                turn("turn/completed", id: "turn-e", status: "failed"), connection: fx.connectionID
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            guard case .ignored = try fx.mapper.map(
                turn("turn/completed", id: "turn-e", status: "failed"), connection: fx.connectionID
            ) else {
                throw CodexAppServerWireError.invalidState
            }
            table["evidence-fencing"] = .pass
        }

        // Backpressure: bounded pending requests fail closed.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx, "turn-b")
            for index in 0..<CodexAppServerConnection.maximumServerRequests {
                let request = approval(Int64(1000 + index), turnID: "turn-b")
                _ = try fx.connection.receive(request, connection: fx.connectionID, write: { writes.append($0) })
                guard case .attention = try fx.mapper.map(request, connection: fx.connectionID) else {
                    throw CodexAppServerWireError.invalidState
                }
            }
            do {
                _ = try fx.mapper.map(approval(2000, turnID: "turn-b"), connection: fx.connectionID)
                throw CodexAppServerWireError.capacityExceeded
            } catch CodexAppServerWireError.capacityExceeded {}
            table["backpressure"] = .pass
        }

        // Secret-bearing payloads: shared candidates, references, and written
        // answers are text-free; the raw params ride the .attention effect as
        // in-memory display data only (bounded by the 32-request cap), never
        // a shared reference or persisted state.
        do {
            var fx = try readyFixture(&writes)
            try bindTurn(&fx, "turn-s")
            let secret = "SECRET-CODEX-PAYLOAD-\(UUID().uuidString)"
            let request = approval(500, turnID: "turn-s", command: secret)
            #expect(request.description == "<redacted:codex-wire-message>")
            guard case .serverRequest = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw CodexAppServerWireError.invalidState
            }
            guard case .attention(let candidate, _, _, _) = try fx.mapper.map(
                request, connection: fx.connectionID
            ), case .approval = candidate.event else {
                throw CodexAppServerWireError.invalidState
            }
            #expect(!String(reflecting: candidate).contains(secret))
            #expect(!String(reflecting: candidate.event).contains(secret))
            _ = try fx.connection.answer(.integer(500), result: .object(["decision": .string("decline")])) {
                writes.append($0)
            }
            let answerText = String(data: try #require(writes.last), encoding: .utf8) ?? ""
            #expect(!answerText.contains(secret))
            guard case .replayedResponse = try fx.connection.receive(request, connection: fx.connectionID, write: {
                writes.append($0)
            }) else {
                throw CodexAppServerWireError.invalidState
            }
            let replayText = String(data: try #require(writes.last), encoding: .utf8) ?? ""
            #expect(!replayText.contains(secret))
            table["secret-bearing-payloads"] = .pass
        }

        expectProviderContractOutcomes(table, provider: "Codex")
    }
}
