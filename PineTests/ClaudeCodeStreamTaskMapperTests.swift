import Foundation
import Testing
@testable import Pine

struct ClaudeCodeStreamTaskMapperTests {
    private let connection = UUID()
    private let sessionID = "fixture-session"

    private func session() -> ClaudeCodeStreamMessage {
        .systemInit(sessionID: sessionID, claudeCodeVersion: "2.1.311",
                    permissionMode: "default", model: "fixture-model",
                    capabilities: nil, account: nil)
    }

    private func assistant(_ uuid: String, toolCalls: [ClaudeCodeToolCall] = []) -> ClaudeCodeStreamMessage {
        .assistant(sessionID: sessionID, userMessageUUID: uuid, toolCalls: toolCalls)
    }

    private func bindSession(_ mapper: inout ClaudeCodeStreamTaskMapper) throws {
        let effects = try mapper.map(session(), connection: connection)
        guard case .candidate(let candidate)? = effects.first,
              case .lifecycle(let event) = candidate.event,
              event.scope == .session, event.phase == .started else {
            throw ClaudeCodeWireError.invalidState
        }
    }

    private func bindTurn(_ mapper: inout ClaudeCodeStreamTaskMapper, uuid: String = "turn-1") throws {
        try mapper.prepareTurn(messageUUID: uuid)
        let effects = try mapper.map(assistant(uuid), connection: connection)
        guard case .candidate(let candidate)? = effects.first,
              case .lifecycle(let event) = candidate.event,
              event.scope == .turn, event.phase == .started else {
            throw ClaudeCodeWireError.invalidState
        }
    }

    private func assertPhase(_ effects: [ClaudeCodeStreamTaskMapper.Effect], _ phase: AdapterLifecyclePhase) {
        guard case .candidate(let candidate)? = effects.first,
              case .lifecycle(let event) = candidate.event else {
            Issue.record("Expected shared lifecycle candidate")
            return
        }
        #expect(event.phase == phase)
        #expect(candidate.sourcePosition == nil) // No manufactured stream position.
    }

    @Test func sessionBindingIsExactAndOneShot() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        #expect(try mapper.map(session(), connection: connection) == [.ignored])
        #expect(throws: ClaudeCodeWireError.foreignSession) {
            _ = try mapper.map(
                .systemInit(sessionID: "other", claudeCodeVersion: nil,
                            permissionMode: nil, model: nil, capabilities: nil, account: nil),
                connection: connection)
        }
        #expect(mapper.isClosed)
    }

    @Test func stopIsMainTurnEndOnlyAndNeverReady() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        let effects = try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
        #expect(effects == [.mainTurnEnd])
        // No lifecycle candidate was emitted for the main-turn end: a final
        // Stop cannot independently produce verified completion or Ready.
        #expect(!effects.contains { effect in
            guard case .candidate(let candidate) = effect, case .lifecycle(let event) = candidate.event else {
                return false
            }
            return [.succeeded, .settled].contains(event.phase)
        })
        #expect(!mapper.hasUnsettledTurn)
    }

    @Test func errorResultMapsTurnFailure() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        assertPhase(
            try mapper.map(.result(sessionID: sessionID, subtype: .errorDuringExecution), connection: connection),
            .failed
        )
        // Each terminal frame settles its own turn; a second frame needs a
        // second authorized turn or it maps to reconciliation.
        try bindTurn(&mapper, uuid: "turn-2")
        assertPhase(
            try mapper.map(.result(sessionID: sessionID, subtype: .errorMaxTurns), connection: connection),
            .failed
        )
    }

    @Test func resultWithoutAuthorizedTurnNeedsReconciliation() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        #expect(try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
            == [.needsReconciliation])
        #expect(mapper.isClosed)
    }

    @Test func unsolicitedAssistantWorkNeedsReconciliation() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        #expect(try mapper.map(assistant("stray-turn"), connection: connection) == [.needsReconciliation])
        // Correlated mismatch also fences: the turn was not what Pine submitted.
        var mismatched = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mismatched)
        try mismatched.prepareTurn(messageUUID: "turn-a")
        #expect(try mismatched.map(assistant("turn-b"), connection: connection) == [.needsReconciliation])
    }

    @Test func assistantBeforeSessionBindingNeedsReconciliation() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try mapper.prepareTurn(messageUUID: "turn-1")
        #expect(try mapper.map(assistant("turn-1"), connection: connection) == [.needsReconciliation])
        #expect(mapper.isClosed)
    }

    @Test func toolEventsCarryIdentityOnly() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        let calls = [ClaudeCodeToolCall(id: "tool-1", name: "Bash"),
                     ClaudeCodeToolCall(id: "tool-2", name: "Read"),
                     ClaudeCodeToolCall(id: "tool-3", name: "Mystery")]
        let effects = try mapper.map(assistant("turn-1", toolCalls: calls), connection: connection)
        let toolEffects = effects.filter { effect in
            guard case .candidate(let candidate) = effect, case .tool = candidate.event else { return false }
            return true
        }
        #expect(toolEffects.count == 3)
        guard case .candidate(let first)? = toolEffects.first,
              case .tool(let firstEvent) = first.event else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(firstEvent.phase == .started)
        #expect(firstEvent.category == .execute)
        #expect(firstEvent.toolCall.rawValue == "tool-1")
        let results = try mapper.map(
            .userToolResults(sessionID: sessionID, results: [
                .init(toolUseID: "tool-1", isError: false),
                .init(toolUseID: "tool-2", isError: true)
            ]),
            connection: connection
        )
        let resultPhases = results.compactMap { effect -> CandidateToolPhase? in
            guard case .candidate(let candidate) = effect, case .tool(let event) = candidate.event else {
                return nil
            }
            return event.phase
        }
        #expect(resultPhases == [.succeeded, .failed])
    }

    @Test func continuationStartsFreshTurnOnSameSession() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        _ = try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
        try bindTurn(&mapper, uuid: "turn-2")
        #expect(try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
            == [.mainTurnEnd])
        #expect(!mapper.hasUnsettledTurn)
    }

    @Test func staleClosedTurnTrafficDuringActiveTurnNeedsReconciliation() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper, uuid: "old-turn")
        #expect(try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
            == [.mainTurnEnd])
        try bindTurn(&mapper, uuid: "new-turn")
        #expect(try mapper.map(assistant("old-turn"), connection: connection) == [.needsReconciliation])
        #expect(mapper.isClosed)
        // Once stale traffic is observed, its uncorrelated result cannot settle the new turn.
        #expect(try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
            == [.needsReconciliation])
        // A mismatch that is not a closed turn still fences.
        var mismatched = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mismatched)
        try bindTurn(&mismatched, uuid: "new-turn")
        #expect(try mismatched.map(assistant("never-seen-turn"), connection: connection)
            == [.needsReconciliation])
    }

    @Test func approvalLifecycleIsOneShotAndReconciled() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        let request = try ClaudeCodePermissionRequest(
            id: try ClaudeCodeControlRequestID("perm-1"), toolName: "Bash", toolUseID: "tool-1", agentID: nil
        )
        let effects = try mapper.map(.permissionRequest(request), connection: connection)
        guard case .attention(let same, let candidate)? = effects.first,
              case .approval(let attention) = candidate.event else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(same == request)
        #expect(attention.phase == .waitingForApproval)
        #expect(attention.request.rawValue == "perm-1")
        #expect(attention.context?.rawValue == "turn-1")
        #expect(mapper.isActionable(request.id, connection: connection))
        #expect(!mapper.isActionable(request.id, connection: UUID()))
        // Duplicate delivery surfaces no second prompt.
        #expect(try mapper.map(.permissionRequest(request), connection: connection) == [.ignored])
        try mapper.markResponseWritten(request.id)
        #expect(!mapper.isActionable(request.id, connection: connection))
        #expect(throws: ClaudeCodeWireError.invalidState) { try mapper.markResponseWritten(request.id) }
        // Provider acknowledgement via tool result resolves exactly once.
        let ack = try mapper.map(
            .userToolResults(sessionID: sessionID, results: [.init(toolUseID: "tool-1", isError: false)]),
            connection: connection
        )
        guard case .requestResolved(let resolution, let resolvedID)? = ack.last,
              case .requestResolved(let scopedResolution) = resolution.event else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(resolvedID == request.id)
        #expect(scopedResolution.scope == attention.scope)
        #expect(scopedResolution.request == attention.request)
        #expect(scopedResolution.context == attention.context)
        let second = try mapper.map(
            .userToolResults(sessionID: sessionID, results: [.init(toolUseID: "tool-1", isError: false)]),
            connection: connection
        )
        #expect(!second.contains { effect in
            guard case .requestResolved(_, let id) = effect else { return false }
            return id == request.id
        })
        // Denial path reconciles through permission_denied.
        let denied = try ClaudeCodePermissionRequest(
            id: try ClaudeCodeControlRequestID("perm-2"), toolName: "Edit", toolUseID: "tool-2", agentID: nil
        )
        _ = try mapper.map(.permissionRequest(denied), connection: connection)
        try mapper.markResponseWritten(denied.id)
        let denial = try mapper.map(
            .permissionDenied(sessionID: sessionID, toolUseID: "tool-2"), connection: connection
        )
        guard case .requestResolved(_, let deniedID)? = denial.first else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(deniedID == denied.id)
        // The exact shared resolution leaves no approval blocking a successful Stop.
        #expect(try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
            == [.mainTurnEnd])
        #expect(!mapper.hasUnsettledTurn)
    }

    @Test func toolResultForUnansweredApprovalFences() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        let request = try ClaudeCodePermissionRequest(
            id: try ClaudeCodeControlRequestID("perm-3"), toolName: "Bash", toolUseID: "tool-3", agentID: nil
        )
        _ = try mapper.map(.permissionRequest(request), connection: connection)
        let effects = try mapper.map(
            .userToolResults(sessionID: sessionID, results: [.init(toolUseID: "tool-3", isError: false)]),
            connection: connection
        )
        #expect(effects.contains(.needsReconciliation))
        #expect(mapper.isClosed)
    }

    @Test func cancellationStopsActionabilityImmediately() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        let request = try ClaudeCodePermissionRequest(
            id: try ClaudeCodeControlRequestID("perm-4"), toolName: "Bash", toolUseID: "tool-4", agentID: nil
        )
        _ = try mapper.map(.permissionRequest(request), connection: connection)
        try mapper.requestCancellation()
        #expect(mapper.turnAwaitingCancellation?.rawValue == "turn-1")
        #expect(!mapper.isActionable(request.id, connection: connection))
        // Late permission traffic after cancellation is unsupported.
        let late = try ClaudeCodePermissionRequest(
            id: try ClaudeCodeControlRequestID("perm-5"), toolName: "Bash", toolUseID: "tool-5", agentID: nil
        )
        #expect(try mapper.map(.permissionRequest(late), connection: connection)
            == [.unsupportedControlRequest(late.id)])
    }

    @Test func confirmedInterruptMapsCancelledAndUnconfirmedIsRace() throws {
        var confirmed = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&confirmed)
        try bindTurn(&confirmed)
        try confirmed.requestCancellation()
        _ = confirmed.observeInterruptReceipt(stillQueued: ["q-1"], cancelled: [])
        assertPhase(
            try confirmed.map(.result(sessionID: sessionID, subtype: .success), connection: connection),
            .cancelled
        )

        var unconfirmed = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&unconfirmed)
        try bindTurn(&unconfirmed)
        try unconfirmed.requestCancellation()
        #expect(try unconfirmed.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
            == [.lateCompletionAfterCancellation])
        // A late completion after cancellation is never success or Ready.
        #expect(!unconfirmed.hasUnsettledTurn)
    }

    @Test func interruptReceiptWithoutCancellationIsIgnored() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        #expect(mapper.observeInterruptReceipt(stillQueued: ["q-1"], cancelled: []) == .ignored)
    }

    @Test func queuedMessagesAreNeverAutoResent() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        try mapper.requestCancellation()
        let receipt = mapper.observeInterruptReceipt(stillQueued: ["queued-1", "queued-2"], cancelled: [])
        guard case .interruptReceiptObserved(stillQueued: let queued, cancelled: let cancelled) = receipt else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(queued == ["queued-1", "queued-2"])
        #expect(cancelled.isEmpty)
        // The receipt is an observation; the mapper has no resend path and
        // the queued turn does not start by itself.
        #expect(mapper.hasUnsettledTurn)
        let outcome = try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
        guard case .candidate(let candidate)? = outcome.first, case .lifecycle(let event) = candidate.event,
              event.phase == .cancelled else {
            throw ClaudeCodeWireError.invalidState
        }
        #expect(!mapper.hasUnsettledTurn)
    }

    @Test func endOfStreamWithUnsettledStateNeedsReconciliation() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        try bindTurn(&mapper)
        #expect(mapper.endOfStream() == .needsReconciliation)
        #expect(mapper.endOfStream() == .ignored)

        var answered = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&answered)
        try bindTurn(&answered)
        let request = try ClaudeCodePermissionRequest(
            id: try ClaudeCodeControlRequestID("perm-6"), toolName: "Bash", toolUseID: "tool-6", agentID: nil
        )
        _ = try answered.map(.permissionRequest(request), connection: connection)
        try answered.markResponseWritten(request.id)
        // A response written but never acknowledged: lost until reconciled.
        #expect(answered.endOfStream() == .needsReconciliation)

        var clean = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&clean)
        #expect(clean.endOfStream() == .sessionEnded)
    }

    @Test func unresolvedApprovalsAtResultFence() throws {
        var pending = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&pending)
        try bindTurn(&pending)
        let request = try ClaudeCodePermissionRequest(
            id: try ClaudeCodeControlRequestID("perm-7"), toolName: "Bash", toolUseID: "tool-7", agentID: nil
        )
        _ = try pending.map(.permissionRequest(request), connection: connection)
        #expect(try pending.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
            == [.needsReconciliation])
    }

    @Test func foreignConnectionAndClosedMapperNeverCreateState() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        #expect(try mapper.map(session(), connection: UUID()) == [.ignored])
        try bindSession(&mapper)
        try bindTurn(&mapper)
        #expect(throws: ClaudeCodeWireError.invalidState) { try mapper.prepareTurn(messageUUID: "turn-2") }
        mapper.close()
        #expect(try mapper.map(session(), connection: connection) == [.needsReconciliation])
        #expect(mapper.isClosed)
    }

    @Test func closedTurnsAreBounded() throws {
        var mapper = ClaudeCodeStreamTaskMapper(connectionID: connection)
        try bindSession(&mapper)
        for index in 0..<ClaudeCodeStreamTaskMapper.maximumClosedTurns {
            try bindTurn(&mapper, uuid: "turn-\(index)")
            _ = try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
        }
        try bindTurn(&mapper, uuid: "turn-overflow")
        #expect(throws: ClaudeCodeWireError.capacityExceeded) {
            _ = try mapper.map(.result(sessionID: sessionID, subtype: .success), connection: connection)
        }
    }
}
