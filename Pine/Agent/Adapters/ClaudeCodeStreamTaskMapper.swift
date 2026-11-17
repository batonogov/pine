import Foundation

/// Ephemeral routing of one owned Claude CLI stream into the shared adapter
/// contract. Candidates are not trusted until registry ingress. No prompt,
/// tool input, assistant text, transcript content, provider timestamp, or
/// cost figure is retained by this mapper.
///
/// `result success` is agent-reported main-turn end (Stop) only: it may
/// coexist with background work and never independently establishes verified
/// completion or Ready.
nonisolated struct ClaudeCodeStreamTaskMapper {
    enum Effect: Sendable {
        case candidate(AdapterCandidate)
        /// Agent-reported main-turn end. Settlement stays unknown; this is not
        /// a lifecycle candidate and cannot feed Ready.
        case mainTurnEnd
        case attention(ClaudeCodePermissionRequest, AdapterCandidate)
        case requestResolved(ClaudeCodeControlRequestID)
        case unsupportedControlRequest(ClaudeCodeControlRequestID)
        case needsReconciliation
        /// A late completion after a requested cancellation is a race outcome,
        /// never success.
        case lateCompletionAfterCancellation
        /// Observation only: the interrupt receipt arrived. Queued messages
        /// are reported, never automatically resent.
        case interruptReceiptObserved(stillQueued: [String], cancelled: [String])
        /// The owned stream ended. Process exit is an observation, not
        /// successful completion.
        case sessionEnded
        case ignored
    }

    static let maximumClosedTurns = 64
    static let maximumPendingApprovals = 32

    let connectionID: UUID
    private(set) var session: VendorReference?
    private var pendingTurnUUID: String?
    private var activeTurn: VendorReference?
    private var awaitingTurn = false
    private var cancellationRequested = false
    private var interruptReceiptObserved = false
    private var closed = false
    private var closedTurns: Set<VendorReference> = []
    private var pendingApprovals: Set<ClaudeCodeControlRequestID> = []
    private var answeredApprovals: Set<ClaudeCodeControlRequestID> = []
    private var approvalToolUseIDs: [ClaudeCodeControlRequestID: String] = [:]

    init(connectionID: UUID) {
        self.connectionID = connectionID
    }

    var hasUnsettledTurn: Bool { awaitingTurn || activeTurn != nil }
    var turnAwaitingCancellation: VendorReference? { cancellationRequested ? activeTurn : nil }
    var pendingApprovalsCount: Int { pendingApprovals.count }
    var isClosed: Bool { closed }

    /// Called only for an explicitly authorized user-message submission on
    /// this binding. It does not send or retry user input; the transport
    /// write is the owner's responsibility.
    mutating func prepareTurn(messageUUID: String) throws {
        guard !closed, !awaitingTurn, activeTurn == nil else {
            throw ClaudeCodeWireError.invalidState
        }
        guard messageUUID.utf8.count <= 256, !messageUUID.isEmpty,
              !messageUUID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ClaudeCodeWireError.invalidIdentifier
        }
        pendingTurnUUID = messageUUID
        awaitingTurn = true
    }

    mutating func requestCancellation() throws {
        guard !closed, activeTurn != nil || awaitingTurn else {
            throw ClaudeCodeWireError.invalidState
        }
        cancellationRequested = true
        // Pending controls stop being actionable immediately; acknowledgement
        // of the interrupt alone does not confirm cancellation.
        pendingApprovals.removeAll()
    }

    /// The interrupt control response carried a receipt. Observing it does not
    /// resend, cancel, or settle anything by itself.
    mutating func observeInterruptReceipt(
        stillQueued: [String],
        cancelled: [String]
    ) -> Effect {
        guard !closed, cancellationRequested else { return .ignored }
        interruptReceiptObserved = true
        return .interruptReceiptObserved(stillQueued: stillQueued, cancelled: cancelled)
    }

    func isActionable(_ id: ClaudeCodeControlRequestID, connection: UUID) -> Bool {
        !closed && connection == connectionID && !cancellationRequested
            && activeTurn != nil && pendingApprovals.contains(id)
            && !answeredApprovals.contains(id)
    }

    /// A successful pipe write makes the UI response one-shot, but provider
    /// acknowledgement stays unresolved until a tool result or permission
    /// denial for the same tool call arrives.
    mutating func markResponseWritten(_ id: ClaudeCodeControlRequestID) throws {
        guard isActionable(id, connection: connectionID) else {
            throw ClaudeCodeWireError.invalidState
        }
        pendingApprovals.remove(id)
        answeredApprovals.insert(id)
    }

    mutating func close() {
        closed = true
        awaitingTurn = false
        activeTurn = nil
        pendingTurnUUID = nil
        pendingApprovals.removeAll()
        answeredApprovals.removeAll()
        approvalToolUseIDs.removeAll()
    }

    /// The owned stream hit EOF. Lost lifecycle evidence makes execution
    /// unknown; this never settles the turn or the session.
    mutating func endOfStream() -> Effect {
        if closed { return .ignored }
        if hasUnsettledTurn || !answeredApprovals.isEmpty {
            close()
            return .needsReconciliation
        }
        close()
        return .sessionEnded
    }

    mutating func map(_ message: ClaudeCodeStreamMessage, connection: UUID) throws -> [Effect] {
        guard connection == connectionID else { return [.ignored] }
        guard !closed else { return [.needsReconciliation] }
        do {
            switch message {
            case let .systemInit(sessionID: observed, _, _, _, _, _):
                return try bindSession(observed)
            case let .assistant(_, userMessageUUID, toolCalls):
                return try assistant(userMessageUUID: userMessageUUID, toolCalls: toolCalls)
            case let .userToolResults(_, results):
                return try toolResults(results)
            case let .result(_, subtype):
                return [try result(subtype)]
            case let .permissionRequest(request):
                return [try permission(request)]
            case .controlResponseSuccess, .controlResponseError, .unsupportedControlRequest:
                // Correlation belongs to the connection owner.
                return [.ignored]
            case .permissionDenied(let toolUseID):
                if let resolved = try reconcileApproval(toolUseID) { return [resolved] }
                return [.ignored]
            case .dataOnly:
                return [.ignored]
            }
        } catch {
            close()
            throw error
        }
    }

    private mutating func bindSession(_ observed: String) throws -> [Effect] {
        let reference = try VendorReference(role: .conversation, value: observed)
        guard session == nil else {
            guard session == reference else { throw ClaudeCodeWireError.foreignSession }
            return [.ignored]
        }
        session = reference
        return [.candidate(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
            scope: .session, phase: .started, reference: reference
        ))))]
    }

    private mutating func assistant(
        userMessageUUID: String?,
        toolCalls: [ClaudeCodeToolCall]
    ) throws -> [Effect] {
        if activeTurn == nil {
            guard let pending = pendingTurnUUID else {
                // Work without an authorized submission on this attempt.
                close()
                return [.needsReconciliation]
            }
            if let observed = userMessageUUID, observed != pending {
                close()
                return [.needsReconciliation]
            }
            let reference = try VendorReference(role: .turn, value: pending)
            guard !closedTurns.contains(reference) else { throw ClaudeCodeWireError.invalidEnvelope }
            activeTurn = reference
            awaitingTurn = false
            pendingTurnUUID = nil
            var effects = [Effect.candidate(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
                scope: .turn, phase: .started, reference: reference
            ))))]
            effects.append(contentsOf: try toolStarts(toolCalls))
            return effects
        }
        if let observed = userMessageUUID, let active = activeTurn, observed != active.rawValue {
            // A replay of an already-closed turn is stale data; any other
            // mismatch is a live turn Pine never authorized.
            if let stale = try? VendorReference(role: .turn, value: observed),
               closedTurns.contains(stale) {
                return [.ignored]
            }
            close()
            return [.needsReconciliation]
        }
        return try toolStarts(toolCalls)
    }

    private func toolStarts(_ toolCalls: [ClaudeCodeToolCall]) throws -> [Effect] {
        var effects: [Effect] = []
        for call in toolCalls {
            let toolCall = try VendorReference(role: .toolCall, value: call.id)
            let event = try CandidateToolEvent(
                phase: .started,
                category: Self.category(of: call.name),
                toolCall: toolCall,
                fileChanges: []
            )
            effects.append(.candidate(AdapterCandidate(event: .tool(event))))
        }
        return effects
    }

    private mutating func toolResults(_ results: [ClaudeCodeToolResult]) throws -> [Effect] {
        guard activeTurn != nil else { return [.ignored] }
        var effects: [Effect] = []
        for result in results {
            let toolCall = try VendorReference(role: .toolCall, value: result.toolUseID)
            let event = try CandidateToolEvent(
                phase: result.isError ? .failed : .succeeded,
                category: .other,
                toolCall: toolCall,
                fileChanges: []
            )
            effects.append(.candidate(AdapterCandidate(event: .tool(event))))
            if let resolved = try reconcileApproval(result.toolUseID) {
                effects.append(resolved)
            }
        }
        return effects.isEmpty ? [.ignored] : effects
    }

    /// Returns the one-shot resolution effect when a tool result or denial
    /// acknowledges a response Pine wrote; nil when nothing is reconciled.
    private mutating func reconcileApproval(_ toolUseID: String) throws -> Effect? {
        guard let id = approvalToolUseIDs.first(where: { $0.value == toolUseID })?.key else { return nil }
        guard answeredApprovals.remove(id) != nil else {
            // A tool result for a request Pine never answered is a
            // contradiction, not evidence.
            if pendingApprovals.contains(id) {
                close()
                return .needsReconciliation
            }
            return nil
        }
        approvalToolUseIDs.removeValue(forKey: id)
        return .requestResolved(id)
    }

    private mutating func permission(_ request: ClaudeCodePermissionRequest) throws -> Effect {
        guard let activeTurn = activeTurn, !cancellationRequested else {
            return .unsupportedControlRequest(request.id)
        }
        if pendingApprovals.contains(request.id) || answeredApprovals.contains(request.id) {
            // Duplicate delivery: the connection replays the remembered
            // response; no second user prompt.
            return .ignored
        }
        guard pendingApprovals.count < Self.maximumPendingApprovals else {
            throw ClaudeCodeWireError.capacityExceeded
        }
        pendingApprovals.insert(request.id)
        approvalToolUseIDs[request.id] = request.toolUseID
        let reference = try VendorReference(role: .request, value: request.id.value)
        let context = try VendorReference(role: .turn, value: activeTurn.rawValue)
        let attention = try CandidateAttentionEvent(
            scope: .turn, phase: .waitingForApproval,
            request: reference, context: context
        )
        return .attention(request, AdapterCandidate(event: .approval(attention)))
    }

    private mutating func result(_ subtype: ClaudeCodeResultSubtype) throws -> Effect {
        guard let currentTurn = activeTurn else {
            // Settlement without an authorized turn on this attempt.
            close()
            return .needsReconciliation
        }
        // Unreconciled approvals at turn end mean we lost the provider's
        // resolution signal; fence rather than guess.
        if !pendingApprovals.isEmpty || !answeredApprovals.isEmpty {
            close()
            return .needsReconciliation
        }
        if closedTurns.contains(currentTurn) {
            activeTurn = nil
            awaitingTurn = false
            cancellationRequested = false
            interruptReceiptObserved = false
            return .ignored
        }
        guard closedTurns.count < Self.maximumClosedTurns else {
            throw ClaudeCodeWireError.capacityExceeded
        }
        closedTurns.insert(currentTurn)
        let finishedTurn = currentTurn
        activeTurn = nil
        awaitingTurn = false

        if cancellationRequested {
            // A confirmed interrupt (receipt observed) ends the turn as
            // cancelled; a cancellation without its receipt is a race outcome
            // that can never become success.
            let confirmed = interruptReceiptObserved
            cancellationRequested = false
            interruptReceiptObserved = false
            if confirmed {
                return .candidate(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
                    scope: .turn, phase: .cancelled, reference: finishedTurn
                ))))
            }
            return .lateCompletionAfterCancellation
        }

        cancellationRequested = false
        interruptReceiptObserved = false
        switch subtype {
        case .success:
            // Stop: agent-reported main-turn end only. It may coexist with
            // background work; it never independently establishes verified
            // completion or Ready.
            return .mainTurnEnd
        case .errorMaxTurns, .errorDuringExecution:
            return .candidate(AdapterCandidate(event: .lifecycle(try CandidateLifecycleEvent(
                scope: .turn, phase: .failed, reference: finishedTurn
            ))))
        }
    }

    /// `.fileChange` is reserved for events that carry a bounded
    /// file-change list with content identities; this slice retains tool
    /// identity only, so file-writing tools map to `.write`.
    static func category(of toolName: String) -> CandidateToolCategory {
        switch toolName {
        case "Bash", "PowerShell", "Monitor": .execute
        case "Read", "NotebookRead": .read
        case "Grep", "Glob", "WebSearch": .search
        case "Edit", "Write", "NotebookEdit": .write
        case "WebFetch": .network
        default: .other
        }
    }
}

/// Structural equality at the effect layer. `.candidate` values are never
/// equal at this layer: `AdapterCandidate` equality belongs to the shared
/// model, and treating two candidates as not-provably-equal is fail-closed.
extension ClaudeCodeStreamTaskMapper.Effect: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.candidate, .candidate): return false
        case (.mainTurnEnd, .mainTurnEnd), (.needsReconciliation, .needsReconciliation),
             (.lateCompletionAfterCancellation, .lateCompletionAfterCancellation),
             (.sessionEnded, .sessionEnded), (.ignored, .ignored):
            return true
        case let (.attention(l, _), .attention(r, _)): return l == r
        case let (.requestResolved(l), .requestResolved(r)): return l == r
        case let (.unsupportedControlRequest(l), .unsupportedControlRequest(r)): return l == r
        case let (.interruptReceiptObserved(l1, l2), .interruptReceiptObserved(r1, r2)):
            return l1 == r1 && l2 == r2
        default: return false
        }
    }
}
