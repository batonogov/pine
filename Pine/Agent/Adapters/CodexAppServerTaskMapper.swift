import CryptoKit
import Foundation

/// Ephemeral routing of a pinned Codex 0.169.0 connection into the existing
/// shared adapter contract. Candidates are not trusted until registry ingress.
/// No transcript, command, question text, or provider timestamp is retained.
nonisolated struct CodexAppServerTaskMapper {
    enum Effect: Sendable {
        case candidate(AdapterCandidate)
        case parentSettlementUnknown
        case attention(AdapterCandidate, requestID: CodexAppServerRequestID, method: String, params: AgentEventJSON)
        case requestResolved(AdapterCandidate, requestID: CodexAppServerRequestID)
        case unsupportedRequest(CodexAppServerRequestID)
        case needsReconciliation
        case lateCompletionAfterCancellation
        case ignored
        case bufferedUntilTurnBinding
    }

    let connectionID: UUID
    let thread: VendorReference
    private var awaitingTurn = false
    private var activeTurn: VendorReference?
    private var cancellationRequested = false
    private var parentCompletionObserved = false
    private var pendingRequests: Set<CodexAppServerRequestID> = []
    private var answeredRequests: Set<CodexAppServerRequestID> = []
    private var closed = false
    private var bufferedUntilBinding: [CodexAppServerMessage] = []
    private var closedTurns: Set<VendorReference> = []
    private var resolvedRequests: Set<CodexAppServerRequestID> = []

    init(connectionID: UUID, threadID: String) throws {
        self.connectionID = connectionID
        thread = try VendorReference(role: .conversation, value: threadID)
    }

    /// Called only for an explicitly authorized turn/start on this binding.
    /// It does not send or retry user input.
    mutating func prepareTurn() throws {
        guard !closed, !awaitingTurn, activeTurn == nil else { throw CodexAppServerWireError.invalidState }
        guard closedTurns.count < 64 else {
            close()
            throw CodexAppServerWireError.capacityExceeded
        }
        parentCompletionObserved = false
        awaitingTurn = true
    }

    /// Only the correlated turn/start response can bind a turn to the current
    /// logical attempt. Earlier notifications/requests are bounded and replayed
    /// after binding; their arrival order never becomes lifecycle authority.
    @discardableResult
    mutating func bindTurnResponse(_ turnID: String) throws -> [Effect] {
        guard !closed else { throw CodexAppServerWireError.closed }
        do {
            let reference = try VendorReference(role: .turn, value: turnID)
            guard !closedTurns.contains(reference) else { throw CodexAppServerWireError.invalidEnvelope }
            if let activeTurn {
                guard activeTurn == reference else { throw CodexAppServerWireError.invalidEnvelope }
                return []
            }
            guard awaitingTurn else { throw CodexAppServerWireError.invalidState }
            activeTurn = reference
            awaitingTurn = false
            var effects: [Effect] = [.candidate(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
                scope: .turn, phase: .started, reference: reference
            ))))]
            let buffered = bufferedUntilBinding
            bufferedUntilBinding.removeAll()
            for message in buffered {
                let effect = try map(message, connection: connectionID)
                switch effect {
                case .ignored: break
                default: effects.append(effect)
                }
            }
            return effects
        } catch {
            close()
            throw error
        }
    }

    var hasUnsettledTurn: Bool { awaitingTurn || activeTurn != nil }

    var turnAwaitingCancellation: VendorReference? { cancellationRequested ? activeTurn : nil }

    mutating func requestCancellation() throws {
        guard !closed, activeTurn != nil || awaitingTurn else { throw CodexAppServerWireError.invalidState }
        cancellationRequested = true
        // Pending controls stop being actionable immediately; acknowledgement
        // of turn/interrupt alone does not confirm cancellation.
        pendingRequests.removeAll()
        answeredRequests.removeAll()
    }

    func isActionable(_ identifier: CodexAppServerRequestID, connection: UUID) -> Bool {
        !closed && connection == connectionID && !cancellationRequested
            && activeTurn != nil && pendingRequests.contains(identifier) && !answeredRequests.contains(identifier)
    }

    /// A successful pipe write makes the UI response one-shot, but pending
    /// provider acknowledgement stays unresolved until serverRequest/resolved.
    mutating func markResponseWritten(_ identifier: CodexAppServerRequestID) throws {
        guard isActionable(identifier, connection: connectionID) else { throw CodexAppServerWireError.invalidState }
        answeredRequests.insert(identifier)
    }

    mutating func close() {
        closed = true
        awaitingTurn = false
        activeTurn = nil
        pendingRequests.removeAll()
        answeredRequests.removeAll()
        bufferedUntilBinding.removeAll()
    }

    mutating func map(_ message: CodexAppServerMessage, connection: UUID) throws -> Effect {
        guard connection == connectionID else { return .ignored }
        guard !closed else { return .needsReconciliation }
        do {
            if awaitingTurn, activeTurn == nil, let deferred = try bufferBeforeBinding(message) { return deferred }
            switch message {
            case .notification(let method, let params):
                return try notification(method, params: params)
            case .request(let identifier, let method, let params):
                return try request(identifier, method: method, params: params)
            case .response, .failure:
                // Correlation and authentication belong to the connection owner.
                return .ignored
            }
        } catch {
            close()
            throw error
        }
    }

    private mutating func bufferBeforeBinding(_ message: CodexAppServerMessage) throws -> Effect? {
        let params: AgentEventJSON
        switch message {
        case .notification(let method, let value)
            where ["turn/started", "turn/completed", "serverRequest/resolved"].contains(method):
            params = value
        case .request(_, let method, let value)
            where ["item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method):
            params = value
        default: return nil
        }
        guard case .object(let fields) = params else { throw CodexAppServerWireError.invalidEnvelope }
        guard try reference(fields["threadId"], role: .conversation) == thread else { return .ignored }
        let turnValue: AgentEventJSON?
        if case .object(let turn) = fields["turn"] { turnValue = turn["id"] } else { turnValue = fields["turnId"] }
        if let turnValue, closedTurns.contains(try reference(turnValue, role: .turn)) { return .ignored }
        guard bufferedUntilBinding.count < 32 else { throw CodexAppServerWireError.capacityExceeded }
        bufferedUntilBinding.append(message)
        return .bufferedUntilTurnBinding
    }

    private mutating func notification(_ method: String, params: AgentEventJSON) throws -> Effect {
        // Additive/unknown notifications cannot establish lifecycle state.
        guard ["turn/started", "turn/completed", "serverRequest/resolved"].contains(method) else { return .ignored }
        guard case .object(let fields) = params else { throw CodexAppServerWireError.invalidEnvelope }
        guard try reference(fields["threadId"], role: .conversation) == thread else { return .ignored }
        if method == "serverRequest/resolved" {
            guard let value = fields["requestId"] else { throw CodexAppServerWireError.invalidEnvelope }
            let identifier = try CodexAppServerRequestID(value)
            guard resolvedRequests.count < 64 || resolvedRequests.contains(identifier) else {
                throw CodexAppServerWireError.capacityExceeded
            }
            resolvedRequests.insert(identifier)
            guard pendingRequests.remove(identifier) != nil else { return .ignored }
            answeredRequests.remove(identifier)
            guard let activeTurn else {
                close()
                return .needsReconciliation
            }
            let resolution = try CandidateRequestResolutionEvent(
                scope: .turn, request: VendorReference(role: .request, value: requestDigest(identifier)), context: activeTurn
            )
            return .requestResolved(AdapterCandidate(event: .requestResolved(resolution)), requestID: identifier)
        }
        guard case .object(let turn) = fields["turn"],
              case .string(let status) = turn["status"],
              case .array = turn["items"] else { throw CodexAppServerWireError.invalidEnvelope }
        let turnReference = try reference(turn["id"], role: .turn)
        if method == "turn/started" {
            guard status == "inProgress" else { throw CodexAppServerWireError.invalidEnvelope }
            if let activeTurn {
                guard activeTurn == turnReference else { return .ignored }
                return .ignored // Response and started notification may overlap.
            }
            if closedTurns.contains(turnReference) { return .ignored }
            close()
            return .needsReconciliation
        }
        guard activeTurn == turnReference else { return .ignored }
        // Parent completion is not aggregate settlement. Apply this policy
        // before ANY ownership mutation, including bindTurnResponse's replay.
        if status == "completed" {
            guard !parentCompletionObserved else { return .ignored }
            parentCompletionObserved = true
            return .parentSettlementUnknown
        }
        let phase: AdapterLifecyclePhase
        switch status {
        case "failed": phase = .failed
        case "interrupted": phase = .cancelled
        default: throw CodexAppServerWireError.invalidEnvelope
        }
        let lateCompletion = cancellationRequested && status != "interrupted"
        guard closedTurns.count < 64 else { throw CodexAppServerWireError.capacityExceeded }
        closedTurns.insert(turnReference)
        activeTurn = nil
        awaitingTurn = false
        pendingRequests.removeAll()
        answeredRequests.removeAll()
        if lateCompletion {
            close()
            return .lateCompletionAfterCancellation
        }
        cancellationRequested = false
        // A provider success is only a completion claim; Ready still requires
        // Pine-observed checks, independent review, and current fingerprints.
        return .candidate(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .turn, phase: phase, reference: turnReference
        ))))
    }

    private mutating func request(
        _ identifier: CodexAppServerRequestID,
        method: String,
        params: AgentEventJSON
    ) throws -> Effect {
        let question = method == "item/tool/requestUserInput"
        let approval = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method)
        guard question || approval else { return .unsupportedRequest(identifier) }
        guard !resolvedRequests.contains(identifier) else { return .unsupportedRequest(identifier) }
        guard case .object(let fields) = params else { throw CodexAppServerWireError.invalidEnvelope }
        guard try reference(fields["threadId"], role: .conversation) == thread,
              let activeTurn,
              try reference(fields["turnId"], role: .turn) == activeTurn,
              !cancellationRequested else { return .unsupportedRequest(identifier) }
        _ = try reference(fields["itemId"], role: .item)
        if question {
            guard case .bool(let blocking) = fields["isBlocking"],
                  case .array(let questions) = fields["questions"], !questions.isEmpty, questions.count <= 8 else {
                throw CodexAppServerWireError.invalidEnvelope
            }
            guard blocking else { return .unsupportedRequest(identifier) }
            try validateQuestions(questions)
        } else {
            guard case .number(let startedAt) = fields["startedAtMs"], let timestamp = Int64(startedAt), timestamp >= 0 else {
                throw CodexAppServerWireError.invalidEnvelope
            }
        }
        guard !pendingRequests.contains(identifier) else { return .ignored }
        guard pendingRequests.count < CodexAppServerConnection.maximumServerRequests else {
            throw CodexAppServerWireError.capacityExceeded
        }
        pendingRequests.insert(identifier)
        let requestReference = try VendorReference(role: .request, value: requestDigest(identifier))
        let attention = try CandidateAttentionEvent(
            scope: .turn, phase: question ? .waitingForQuestion : .waitingForApproval,
            request: requestReference, context: activeTurn
        )
        return .attention(AdapterCandidate(event: question ? .question(attention) : .approval(attention)),
                          requestID: identifier, method: method, params: params)
    }

    private func validateQuestions(_ questions: [AgentEventJSON]) throws {
        var identifiers: Set<String> = []
        for question in questions {
            guard case .object(let fields) = question,
                  case .string(let identifier) = fields["id"],
                  case .string(let header) = fields["header"],
                  case .string(let text) = fields["question"],
                  !identifier.isEmpty, identifier.utf8.count <= 256,
                  identifiers.insert(identifier).inserted,
                  !header.isEmpty, header.utf8.count <= 256,
                  !text.isEmpty, text.utf8.count <= 8_192 else {
                throw CodexAppServerWireError.invalidEnvelope
            }
            for flag in ["isSecret", "isOther"] {
                if let value = fields[flag] {
                    guard case .bool = value else { throw CodexAppServerWireError.invalidEnvelope }
                }
            }
            if let options = fields["options"], options != .null {
                guard case .array(let choices) = options, choices.count <= 16 else {
                    throw CodexAppServerWireError.invalidEnvelope
                }
                for choice in choices {
                    guard case .object(let option) = choice,
                          case .string(let label) = option["label"],
                          case .string(let description) = option["description"],
                          !label.isEmpty, label.utf8.count <= 256,
                          description.utf8.count <= 2_048 else {
                        throw CodexAppServerWireError.invalidEnvelope
                    }
                }
            }
        }
    }

    private func reference(_ value: AgentEventJSON?, role: VendorReference.Role) throws -> VendorReference {
        guard case .string(let string) = value else { throw CodexAppServerWireError.invalidEnvelope }
        return try VendorReference(role: role, value: string)
    }

    private func requestDigest(_ identifier: CodexAppServerRequestID) throws -> String {
        // Typed JSON preserves integer-vs-string ID identity. This is a redacted
        // reference, not an authentication token or a streaming replay cursor.
        SHA256.hash(data: try identifier.json.canonicalData()).map { String(format: "%02x", $0) }.joined()
    }
}
