import Foundation

/// A same-run dispatch journal, never a saved execution grant. Relaunch retains
/// uncertainty and the exact session; it does not recreate an owner or replay input.
///
/// Lifecycle recovery: a `launchIntent` or an `unavailable` journal without an
/// observed run may be re-prepared while the same runtime binding is still
/// available (in-session retry after a failed start). Post-process-crash
/// re-prepare is NOT delivered: binding identity is runtime-fresh and not
/// persisted, so a restored task re-adopts a new binding and is dismissed and
/// re-created. An `unavailable` journal with an observed run is final.
nonisolated struct AgentTaskNativeDispatch: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Phase: String, Codable, Sendable {
        case reserved, launchIntent, sessionBound, inputIntent, inputAcknowledged
        case parentSettlementUnknown, inputUnknown, cancellationConfirmed, operationFailed, unavailable
    }
    struct Submission: Codable, Equatable, Sendable,
        CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        enum Phase: String, Codable, Sendable { case intent, acknowledged, responseObserved, unknown }
        let id: UUID
        let afterResponseTo: UUID?
        var phase: Phase = .intent
        var operationID: String?
        var description: String { "<redacted:native-submission>" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    }
    static let maximumSubmissions = 32
    let taskID: UUID
    let runID: UUID
    var bindingID: UUID?
    var phase: Phase
    var conversation: AgentVendorSessionIdentity?
    var operationID: String?
    var cancellationRequested: Bool
    var submissions: [Submission]

    init(taskID: UUID, runID: UUID) {
        self.taskID = taskID
        self.runID = runID
        bindingID = nil
        phase = .reserved
        conversation = nil
        operationID = nil
        cancellationRequested = false
        submissions = []
    }

    var description: String { "<redacted:native-dispatch>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    func isValid(for task: AgentTask) -> Bool {
        guard task.id == taskID, task.origin == .pineLaunched, task.route.surface == .ownedProcess,
              task.route.paneID == nil, task.route.tabID == nil, task.route.terminalID == nil,
              task.presentationContext == nil, task.launchInterruption == nil,
              task.runs.count <= 1, task.runs.allSatisfy({ $0.id == runID && $0.terminalID == nil }),
              task.lifecycle != .completed, task.completedAt == nil,
              task.acceptanceState == .notAccepted,
              task.runs.allSatisfy({ $0.outcome == nil || $0.outcome == .unverified }),
              submissions.count <= Self.maximumSubmissions,
              Set(submissions.map(\.id)).count == submissions.count,
              operationID.map({ (try? VendorReference(role: .turn, value: $0)) != nil }) ?? true else { return false }
        for (index, submission) in submissions.enumerated() {
            guard submission.afterResponseTo == (index == 0 ? nil : submissions[index - 1].id),
                  index == submissions.count - 1 || submission.phase == .responseObserved,
                  submission.operationID.map({ (try? VendorReference(role: .turn, value: $0)) != nil }) ?? true else { return false }
        }
        if !submissions.isEmpty {
            guard conversation != nil, operationID == submissions.last?.operationID else { return false }
        }
        if let conversation {
            guard conversation.provider == task.descriptor.typeIdentifier,
                  (try? VendorReference(role: .conversation, value: conversation.opaqueIdentifier)) != nil,
                  AgentTaskMetadataStore.validOptionalBoundedText(conversation.executableVersion, maximum: 256),
                  task.runs.count == 1, task.runs[0].vendorIdentity == conversation else { return false }
        } else if operationID != nil || task.runs.last?.vendorIdentity != nil { return false }
        if bindingID == nil, !task.runs.isEmpty || conversation != nil || operationID != nil { return false }
        switch phase {
        case .reserved:
            return bindingID == nil && task.runs.isEmpty && !cancellationRequested && submissions.isEmpty
        case .launchIntent:
            return bindingID != nil && conversation == nil && operationID == nil && !cancellationRequested && submissions.isEmpty
        case .sessionBound:
            return bindingID != nil && conversation != nil && operationID == nil && !cancellationRequested && submissions.isEmpty
        case .inputIntent:
            return bindingID != nil && conversation != nil && operationID == nil && submissions.last?.phase == .intent
        case .inputAcknowledged:
            return bindingID != nil && conversation != nil && submissions.last?.phase == .acknowledged
        case .parentSettlementUnknown:
            return bindingID != nil && conversation != nil
                && (submissions.last?.phase == .acknowledged || submissions.last?.phase == .responseObserved)
        case .inputUnknown:
            return bindingID != nil && conversation != nil && submissions.last?.phase == .unknown
        case .cancellationConfirmed:
            return bindingID != nil && conversation != nil
        case .operationFailed:
            return bindingID != nil && conversation != nil
        case .unavailable:
            return true
        }
    }

    /// A bounded explicit-input journal. No transition recreates reserved
    /// authority or retries an intent whose dispatch outcome is unknown.
    func applying(_ transition: AgentTaskNativeTransition) throws -> Self {
        var next = self
        switch transition {
        case .sessionBound(let identity):
            guard phase == .launchIntent, conversation == nil else { throw AgentTaskNativeAdmissionError.invalidTransition }
            next.conversation = identity
            next.phase = .sessionBound
        case .initialInputIntent:
            guard phase == .sessionBound, submissions.isEmpty else { throw AgentTaskNativeAdmissionError.invalidTransition }
            next.submissions.append(Submission(id: UUID(), afterResponseTo: nil))
            next.phase = .inputIntent
        case .initialInputAcknowledged(let operationID):
            guard phase == .inputIntent, submissions.count == 1 else { throw AgentTaskNativeAdmissionError.invalidTransition }
            next.operationID = operationID
            next.submissions[0].operationID = operationID
            next.submissions[0].phase = .acknowledged
            next.phase = .inputAcknowledged
        case .followupInputIntent(let id, let previous):
            guard phase == .parentSettlementUnknown, !cancellationRequested,
                  submissions.last?.id == previous, submissions.last?.phase == .responseObserved,
                  submissions.count < Self.maximumSubmissions, !submissions.contains(where: { $0.id == id }) else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            next.submissions.append(Submission(id: id, afterResponseTo: previous))
            next.operationID = nil
            next.phase = .inputIntent
        case .submissionAcknowledged(let receipt, let operationID),
             .submissionResponseObserved(let receipt, let operationID):
            guard submissions.last?.id == receipt.submissionID,
                  submissions.last?.phase == .intent || submissions.last?.phase == .acknowledged,
                  [.inputIntent, .inputAcknowledged, .parentSettlementUnknown].contains(phase),
                  self.operationID == nil || self.operationID == operationID else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            let responded: Bool
            if case .submissionResponseObserved = transition { responded = true } else { responded = false }
            next.operationID = operationID
            next.submissions[next.submissions.count - 1].operationID = operationID
            next.submissions[next.submissions.count - 1].phase = responded ? .responseObserved : .acknowledged
            next.phase = responded ? .parentSettlementUnknown : .inputAcknowledged
        case .submissionUnknown(let id):
            if phase == .inputUnknown, submissions.last?.id == id, submissions.last?.phase == .unknown { return self }
            guard submissions.last?.id == id, submissions.last?.phase == .intent || submissions.last?.phase == .acknowledged,
                  [.inputIntent, .inputAcknowledged, .parentSettlementUnknown].contains(phase) else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            next.submissions[next.submissions.count - 1].phase = .unknown
            next.phase = .inputUnknown
        case .cancellationRequested:
            guard [.inputIntent, .inputAcknowledged, .parentSettlementUnknown, .inputUnknown,
                   .operationFailed, .cancellationConfirmed].contains(phase),
                  !cancellationRequested else { throw AgentTaskNativeAdmissionError.invalidTransition }
            next.cancellationRequested = true
        case .cancellationConfirmed:
            guard [.inputIntent, .inputAcknowledged, .parentSettlementUnknown, .inputUnknown,
                   .operationFailed, .cancellationConfirmed].contains(phase) else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            next.phase = .cancellationConfirmed
        case .operationFailed:
            guard [.inputIntent, .inputAcknowledged, .parentSettlementUnknown, .inputUnknown].contains(phase) else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            next.phase = .operationFailed
        case .parentSettlementUnknown:
            guard [.inputAcknowledged, .parentSettlementUnknown].contains(phase) else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            next.phase = .parentSettlementUnknown
        case .unavailable:
            next.phase = .unavailable
        }
        return next
    }
}

nonisolated enum AgentTaskNativeTransition: Sendable {
    case sessionBound(AgentVendorSessionIdentity)
    case initialInputIntent
    /// nil is honest when the transport has no separate operation/turn ID.
    case initialInputAcknowledged(operationID: String?)
    case followupInputIntent(submissionID: UUID, afterResponseTo: UUID)
    case submissionAcknowledged(AgentTaskNativeSubmissionReceipt, operationID: String?)
    case submissionResponseObserved(AgentTaskNativeSubmissionReceipt, operationID: String?)
    case submissionUnknown(submissionID: UUID)
    case cancellationRequested
    case cancellationConfirmed
    case operationFailed
    case parentSettlementUnknown
    case unavailable
}

nonisolated struct AgentTaskNativeReservation: Sendable {
    let taskID: UUID
    let runID: UUID
}

nonisolated enum AgentTaskNativeAdmissionError: Error, Equatable {
    case unavailable, invalidPolicy, staleOwner, invalidTransition, persistenceUnavailable
}
