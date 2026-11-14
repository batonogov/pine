import Foundation
import Testing
@testable import Pine

struct CodexAppServerTaskMapperTests {
    private let connection = UUID()

    private func turn(_ method: String, id: String = "fixture-turn", thread: String = "fixture-thread", status: String) -> CodexAppServerMessage {
        .notification(method: method, params: .object([
            "threadId": .string(thread),
            "turn": .object(["id": .string(id), "status": .string(status), "items": .array([])])
        ]))
    }

    private func mapper() throws -> CodexAppServerTaskMapper {
        try CodexAppServerTaskMapper(connectionID: connection, threadID: "fixture-thread")
    }

    private func assertPhase(_ effect: CodexAppServerTaskMapper.Effect, _ phase: AdapterLifecyclePhase) {
        guard case .candidate(let candidate) = effect,
              case .lifecycle(let event) = candidate.event else {
            Issue.record("Expected shared lifecycle candidate")
            return
        }
        #expect(event.scope == .turn)
        #expect(event.phase == phase)
        #expect(candidate.sourcePosition == nil) // No manufactured stream sequence.
    }

    @Test func bufferedQuestionAndSuccessKeepExactTurnOwnership() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        let question = CodexAppServerMessage.request(.integer(77), method: "item/tool/requestUserInput", params: .object([
            "threadId": .string("fixture-thread"), "turnId": .string("fixture-turn"), "itemId": .string("fixture-item"),
            "isBlocking": .bool(true), "questions": .array([.object([
                "id": .string("fixture-question"), "header": .string("Header"), "question": .string("Question")
            ])])
        ]))
        guard case .bufferedUntilTurnBinding = try mapper.map(question, connection: connection),
              case .bufferedUntilTurnBinding = try mapper.map(
                turn("turn/completed", status: "completed"), connection: connection
              ) else { Issue.record("Both pre-response events must enter the mapper buffer"); return }
        let effects = try mapper.bindTurnResponse("fixture-turn")
        #expect(effects.count == 3)
        // Candidate-only typed diagnostic assertion. The preserved old-policy
        // RED uses all ownership/cancellation assertions below without this
        // new enum case, so its failure is behavioral rather than compilation.
        guard case .parentSettlementUnknown = try #require(effects.last) else {
            Issue.record("Buffered parent completion must remain unknown")
            return
        }
        let positiveClaims = effects.filter { effect in
            guard case .candidate(let candidate) = effect, case .lifecycle(let value) = candidate.event else { return false }
            return [.succeeded, .settled].contains(value.phase)
        }
        #expect(positiveClaims.isEmpty)
        let questions = effects.compactMap { effect -> CandidateAttentionEvent? in
            guard case .attention(let candidate, .integer(77), _, _) = effect,
                  case .question(let question) = candidate.event else { return nil }
            return question
        }
        #expect(questions.count == 1)
        #expect(questions.first?.context?.rawValue == "fixture-turn")
        #expect(mapper.thread.rawValue == "fixture-thread")
        #expect(mapper.isActionable(.integer(77), connection: connection))
        #expect(mapper.hasUnsettledTurn)
        #expect(throws: Never.self) { try mapper.markResponseWritten(.integer(77)) }
        #expect(throws: Never.self) { try mapper.requestCancellation() }
        #expect(mapper.turnAwaitingCancellation?.rawValue == "fixture-turn")
        #expect(!mapper.isActionable(.integer(77), connection: connection))
    }

    @Test func turnCompletionIsOnlyProviderClaimAndNeverReady() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        guard case .bufferedUntilTurnBinding = try mapper.map(turn("turn/started", status: "inProgress"), connection: connection) else {
            Issue.record("Uncorrelated turn notification acquired authority")
            return
        }
        let bound = try mapper.bindTurnResponse("fixture-turn")
        #expect(bound.count == 1)
        assertPhase(try #require(bound.first), .started)
        guard case .parentSettlementUnknown = try mapper.map(turn("turn/completed", status: "completed"), connection: connection) else {
            Issue.record("Parent completion gained settlement authority")
            return
        }
        #expect(mapper.hasUnsettledTurn)
        if case .ignored = try mapper.map(turn("turn/completed", status: "completed"), connection: connection) {
            // A duplicate completion cannot create a second settlement.
        } else { Issue.record("Duplicate completion acquired authority") }
    }

    @Test func responseBeforeNotificationStartsExactlyOnce() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        let bound = try mapper.bindTurnResponse("fixture-turn")
        assertPhase(try #require(bound.first), .started)
        guard case .ignored = try mapper.map(turn("turn/started", status: "inProgress"), connection: connection) else {
            Issue.record("Started notification duplicated response lifecycle")
            return
        }
    }

    @Test func foreignConnectionThreadAndTurnCannotSettleTask() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        try mapper.bindTurnResponse("fixture-turn")
        for (event, source) in [
            (turn("turn/completed", status: "completed"), UUID()),
            (turn("turn/completed", thread: "foreign-thread", status: "completed"), connection),
            (turn("turn/completed", id: "old-turn", status: "completed"), connection)
        ] {
            guard case .ignored = try mapper.map(event, connection: source) else {
                Issue.record("Foreign event acquired lifecycle authority")
                return
            }
        }
        assertPhase(try mapper.map(turn("turn/completed", status: "failed"), connection: connection), .failed)
    }

    @Test func interruptAcknowledgementIsNotCancellationAndLateCompletionIsNotSuccess() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        try mapper.bindTurnResponse("fixture-turn")
        try mapper.requestCancellation()
        #expect(mapper.turnAwaitingCancellation != nil)
        guard case .ignored = try mapper.map(.response(.integer(2), result: .object([:])), connection: connection) else {
            Issue.record("Interrupt acknowledgement settled turn")
            return
        }
        guard case .parentSettlementUnknown = try mapper.map(turn("turn/completed", status: "completed"), connection: connection) else {
            Issue.record("Late completion after cancellation became success")
            return
        }
    }

    @Test func confirmedInterruptedTurnMapsCancellation() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        try mapper.bindTurnResponse("fixture-turn")
        try mapper.requestCancellation()
        assertPhase(try mapper.map(turn("turn/completed", status: "interrupted"), connection: connection), .cancelled)
    }

    @Test func requestsAreScopedAndResolvedExactlyOnce() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        try mapper.bindTurnResponse("fixture-turn")
        let request = CodexAppServerMessage.request(.integer(7), method: "item/commandExecution/requestApproval", params: .object([
            "threadId": .string("fixture-thread"), "turnId": .string("fixture-turn"),
            "itemId": .string("fixture-item"), "startedAtMs": .number("1"),
            "command": .string("SECRET-COMMAND-FIXTURE")
        ]))
        guard case .attention(let candidate, .integer(7), _, _) = try mapper.map(request, connection: connection),
              case .approval(let attention) = candidate.event else {
            Issue.record("Valid approval not mapped")
            return
        }
        #expect(attention.phase == .waitingForApproval)
        #expect(!attention.request.rawValue.contains("SECRET"))
        #expect(mapper.isActionable(.integer(7), connection: connection))
        #expect(!mapper.isActionable(.integer(7), connection: UUID()))
        try mapper.markResponseWritten(.integer(7))
        #expect(!mapper.isActionable(.integer(7), connection: connection))
        #expect(throws: CodexAppServerWireError.invalidState) { try mapper.markResponseWritten(.integer(7)) }
        let resolved = CodexAppServerMessage.notification(method: "serverRequest/resolved", params: .object([
            "threadId": .string("fixture-thread"), "requestId": .number("7")
        ]))
        guard case .requestResolved(let resolution, .integer(7)) = try mapper.map(resolved, connection: connection),
              case .requestResolved(let scopedResolution) = resolution.event,
              case .ignored = try mapper.map(resolved, connection: connection) else {
            Issue.record("Request resolution was not one-shot")
            return
        }
        #expect(scopedResolution.request == attention.request)
        #expect(scopedResolution.context == attention.context)
    }

    @Test func unsupportedAndUnsolicitedTrafficNeverBecomesPositiveState() throws {
        var mapper = try mapper()
        guard case .unsupportedRequest(.integer(1)) = try mapper.map(
            .request(.integer(1), method: "future/execute", params: .object([:])), connection: connection
        ) else { Issue.record("Unknown method was not rejected"); return }
        guard case .ignored = try mapper.map(.notification(method: "future/success", params: .object([:])), connection: connection) else {
            Issue.record("Unknown success notification gained authority")
            return
        }
        guard case .needsReconciliation = try mapper.map(turn("turn/started", status: "inProgress"), connection: connection) else {
            Issue.record("Unsolicited turn was accepted")
            return
        }
        #expect(throws: CodexAppServerWireError.invalidState) { try mapper.prepareTurn() }
    }

    @Test func blockingQuestionUsesSharedAttentionAndRejectsMalformedQuestions() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        try mapper.bindTurnResponse("fixture-turn")
        var fields: [String: AgentEventJSON] = [
            "threadId": .string("fixture-thread"), "turnId": .string("fixture-turn"),
            "itemId": .string("fixture-item"), "isBlocking": .bool(true),
            "questions": .array([.object([
                "id": .string("choice"), "header": .string("Choice"),
                "question": .string("SECRET-QUESTION-FIXTURE"), "isSecret": .bool(true)
            ])])
        ]
        let valid = CodexAppServerMessage.request(.string("question"), method: "item/tool/requestUserInput", params: .object(fields))
        guard case .attention(let candidate, .string("question"), _, _) = try mapper.map(valid, connection: connection),
              case .question(let question) = candidate.event else {
            Issue.record("Blocking question was not mapped to shared attention")
            return
        }
        #expect(question.phase == .waitingForQuestion)
        fields["questions"] = .array([.object(["id": .string("malformed")])])
        #expect(throws: CodexAppServerWireError.invalidEnvelope) {
            try mapper.map(.request(.string("bad"), method: "item/tool/requestUserInput", params: .object(fields)), connection: connection)
        }
        guard case .needsReconciliation = try mapper.map(turn("turn/completed", status: "completed"), connection: connection) else {
            Issue.record("Malformed authoritative request did not fence later completion")
            return
        }
    }

    @Test func cancellationBeforeStartResponseRetainsInterruptIntent() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        try mapper.requestCancellation()
        #expect(mapper.turnAwaitingCancellation == nil)
        try mapper.bindTurnResponse("fixture-turn")
        #expect(mapper.turnAwaitingCancellation?.rawValue == "fixture-turn")
        assertPhase(try mapper.map(turn("turn/completed", status: "interrupted"), connection: connection), .cancelled)
    }

    @Test func replayedOldTurnCannotBindOrSettleNewLogicalAttempt() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        try mapper.bindTurnResponse("old-turn")
        assertPhase(try mapper.map(turn("turn/completed", id: "old-turn", status: "interrupted"), connection: connection), .cancelled)
        try mapper.prepareTurn()
        for method in ["turn/started", "turn/completed"] {
            let event = turn(method, id: "old-turn", status: method == "turn/started" ? "inProgress" : "completed")
            guard case .ignored = try mapper.map(event, connection: connection) else {
                Issue.record("Old logical turn gained authority during new dispatch")
                return
            }
        }
        let effects = try mapper.bindTurnResponse("new-turn")
        #expect(effects.count == 1)
        assertPhase(try #require(effects.first), .started)
        guard case .parentSettlementUnknown = try mapper.map(
            turn("turn/completed", id: "new-turn", status: "completed"), connection: connection
        ) else {
            Issue.record("New parent completion gained aggregate authority")
            return
        }
        #expect(mapper.hasUnsettledTurn)
    }

    @Test func preResponseForeignTurnNeverSettlesCorrelatedTurn() throws {
        var mapper = try mapper()
        try mapper.prepareTurn()
        _ = try mapper.map(turn("turn/started", id: "foreign-turn", status: "inProgress"), connection: connection)
        _ = try mapper.map(turn("turn/completed", id: "foreign-turn", status: "completed"), connection: connection)
        let effects = try mapper.bindTurnResponse("actual-turn")
        #expect(effects.count == 1)
        assertPhase(try #require(effects.first), .started)
        assertPhase(try mapper.map(turn("turn/completed", id: "actual-turn", status: "interrupted"), connection: connection), .cancelled)
    }

}
