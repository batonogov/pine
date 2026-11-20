//
//  AgentFeedbackDelivery.swift
//  Pine
//
//  Revision-bound feedback delivery contract (#1758).
//
//  Submission is bound to the viewed revision, dispatched ONCE through the
//  owning adapter and #1756's continuation contract, and carries
//  distinguishable queued/delivered/failed/cancelled/delivery-unknown
//  states. Attachments are validated against the selected model AND
//  transport's actual input support before submission; nothing is dropped
//  silently, and "sent" is never shown merely because a request accepted an
//  ignored field.
//

import Foundation

/// The input support the selected model AND transport actually carry.
///
/// Seam: populated by the adapter owners (#1723, #1732, #1727, #1811) from
/// the negotiated adapter contract's attachment capability flags. #1758
/// validates against this value and never against the provider identity.
/// A missing limit means the kind is not supported: support fails closed.
nonisolated struct AgentFeedbackInputSupport: Codable, Hashable, Sendable {
    struct Support: Codable, Hashable, Sendable {
        /// `nil` = the transport does not accept this resource kind at all.
        let maximumBytes: UInt64?
    }

    static let none = AgentFeedbackInputSupport(
        image: Support(maximumBytes: nil),
        textResource: Support(maximumBytes: nil),
        binaryBlob: Support(maximumBytes: nil)
    )

    let image: Support
    let textResource: Support
    let binaryBlob: Support

    func byteLimit(for kind: AgentFeedbackAttachment.Kind) -> UInt64? {
        switch kind {
        case .image: image.maximumBytes
        case .textResource: textResource.maximumBytes
        case .binaryBlob: binaryBlob.maximumBytes
        }
    }

    func supports(_ kind: AgentFeedbackAttachment.Kind, byteCount: UInt64) -> Bool {
        guard let limit = byteLimit(for: kind) else { return false }
        return byteCount <= limit
    }
}

/// One explicitly explained rejection of one attachment.
nonisolated struct AgentFeedbackAttachmentRejection: Codable, Hashable, Sendable {
    let attachmentID: UUID
    let reason: Reason

    enum Reason: Codable, Hashable, Sendable {
        /// The selected model/transport does not accept this resource kind.
        case unsupportedKind
        /// The resource exceeds the transport's declared byte limit.
        case exceedsByteLimit(limit: UInt64)
        /// The attachment fails its own bounds.
        case invalidAttachment
        /// The user explicitly chose the text-only path.
        case omittedByUserChoice
    }
}

/// The pre-submission gate result (#1761 audit addition).
nonisolated struct AgentFeedbackGateResult: Equatable, Sendable {
    let reference: AgentFeedbackReference
    let rejections: [AgentFeedbackAttachmentRejection]

    var isFullySupported: Bool { rejections.isEmpty }

    /// The explicit text-only projection, present exactly when something
    /// was rejected. Sending it discloses every omitted attachment.
    var textOnlyVariant: AgentFeedbackReference? {
        isFullySupported ? nil : reference.textOnlyVariant
    }
}

nonisolated enum AgentFeedbackSubmissionGate {
    /// Validates every attachment against the selected model AND
    /// transport's actual input support before submission. The draft is
    /// never mutated: an unsupported resource is rejected with an explicit
    /// reason and the text-only path stays available — nothing is dropped
    /// silently.
    static func validate(
        _ reference: AgentFeedbackReference,
        against support: AgentFeedbackInputSupport
    ) -> AgentFeedbackGateResult {
        var rejections: [AgentFeedbackAttachmentRejection] = []
        for attachment in reference.attachments {
            guard attachment.isValid else {
                rejections.append(AgentFeedbackAttachmentRejection(
                    attachmentID: attachment.id,
                    reason: .invalidAttachment
                ))
                continue
            }
            guard let limit = support.byteLimit(for: attachment.kind) else {
                rejections.append(AgentFeedbackAttachmentRejection(
                    attachmentID: attachment.id,
                    reason: .unsupportedKind
                ))
                continue
            }
            if attachment.byteCount > limit {
                rejections.append(AgentFeedbackAttachmentRejection(
                    attachmentID: attachment.id,
                    reason: .exceedsByteLimit(limit: limit)
                ))
            }
        }
        return AgentFeedbackGateResult(
            reference: reference,
            rejections: rejections
        )
    }
}

/// The transport's acknowledgment of one dispatched submission.
///
/// `carriedAttachmentIDs` is what the transport actually carried as input;
/// `observedArtifactIdentity` is the content identity the provider claims
/// to have received for the annotated artifact (#1753). A forwarded path
/// or editor buffer is not proof.
nonisolated struct AgentFeedbackDeliveryReceipt: Codable, Hashable, Sendable {
    /// The idempotency key of the request this receipt acknowledges.
    let submissionID: UUID
    /// Attachments the transport carried as input.
    let carriedAttachmentIDs: Set<UUID>
    /// The content identity the provider claims to have seen.
    let observedArtifactIdentity: AgentFeedbackArtifactIdentity?
    let acknowledgedAt: Date

    init(
        submissionID: UUID,
        carriedAttachmentIDs: Set<UUID> = [],
        observedArtifactIdentity: AgentFeedbackArtifactIdentity? = nil,
        acknowledgedAt: Date = Date()
    ) {
        self.submissionID = submissionID
        self.carriedAttachmentIDs = carriedAttachmentIDs
        self.observedArtifactIdentity = observedArtifactIdentity
        self.acknowledgedAt = acknowledgedAt
    }
}

/// A bounded content identity claimed by a transport.
nonisolated struct AgentFeedbackArtifactIdentity: Codable, Hashable, Sendable {
    let sha256: String
    let byteCount: UInt64

    init(sha256: String, byteCount: UInt64) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    var isValid: Bool {
        AgentTaskMetadataStore.validLowerHex(sha256, length: 64) && byteCount > 0
    }
}

/// The delivered state: the receipt plus what was actually sent.
nonisolated struct AgentFeedbackDeliveryOutcome: Codable, Hashable, Sendable {
    let receipt: AgentFeedbackDeliveryReceipt
    let sentAttachmentIDs: [UUID]

    /// Attachments sent that the transport did not carry. Non-empty means
    /// the feedback is not fully delivered: "sent" is never shown merely
    /// because a request accepted an ignored field.
    var undeliveredAttachmentIDs: [UUID] {
        sentAttachmentIDs.filter { !receipt.carriedAttachmentIDs.contains($0) }
    }

    var isComplete: Bool { undeliveredAttachmentIDs.isEmpty }
}

/// Why a dispatched submission failed. A definite failure means the
/// provider did not take the feedback, so an explicit retry is safe under
/// the same idempotency key.
nonisolated enum AgentFeedbackDeliveryFailure: String, Codable, Sendable {
    case transportUnavailable
    case providerRejected
    /// The owning adapter or #1756 continuation contract could not accept
    /// the submission.
    case continuationUnavailable
}

/// The distinguishable delivery states of one submission (#1758).
nonisolated enum AgentFeedbackDeliveryState: Codable, Hashable, Sendable {
    case queued
    case delivered(AgentFeedbackDeliveryOutcome)
    case failed(AgentFeedbackDeliveryFailure)
    case cancelled
    case deliveryUnknown

    var isTerminal: Bool {
        switch self {
        case .queued:
            return false
        case .delivered, .failed, .cancelled, .deliveryUnknown:
            return true
        }
    }

    /// States in which another submission with the same content would risk
    /// a second dispatch of the same feedback.
    var isDuplicateBlocking: Bool {
        switch self {
        case .queued, .delivered, .deliveryUnknown:
            return true
        case .failed, .cancelled:
            return false
        }
    }
}

/// One revision-bound feedback submission and its delivery state (#1758).
///
/// `id` is the idempotency key: the owning adapter and #1756's
/// continuation contract key the single dispatch — and any resulting new
/// attempt — on it, so duplicate submission or delivery cannot create two
/// revisions.
nonisolated struct AgentFeedbackSubmission: Codable, Hashable, Sendable {
    static let currentScheme: UInt8 = 1

    let scheme: UInt8
    let id: UUID
    let reference: AgentFeedbackReference
    let submittedAt: Date
    /// How the anchor resolved when the user submitted. A non-`resolved`
    /// value is shown to the user; it never re-targets the reference.
    let anchorResolutionAtSubmission: AgentFeedbackAnchorResolution
    /// Attachments the user explicitly chose not to send (text-only path).
    /// Anything not in `reference` and not here would be a silent drop,
    /// which the state machine prevents.
    let disclosedOmissions: [AgentFeedbackAttachmentRejection]
    var state: AgentFeedbackDeliveryState
    var resolution: AgentFeedbackResolution

    init(
        id: UUID = UUID(),
        reference: AgentFeedbackReference,
        anchorResolutionAtSubmission: AgentFeedbackAnchorResolution = .resolved,
        disclosedOmissions: [AgentFeedbackAttachmentRejection] = [],
        state: AgentFeedbackDeliveryState = .queued,
        submittedAt: Date = Date(),
        resolution: AgentFeedbackResolution = .unresolved
    ) {
        scheme = Self.currentScheme
        self.id = id
        self.reference = reference
        self.submittedAt = submittedAt
        self.anchorResolutionAtSubmission = anchorResolutionAtSubmission
        self.disclosedOmissions = disclosedOmissions
        self.state = state
        self.resolution = resolution
    }

    var fingerprint: String { reference.fingerprint }

    /// Applies one delivery receipt. A receipt for another submission is
    /// foreign and never applied; a receipt on a non-queued state is late
    /// and never applied.
    mutating func apply(
        receipt: AgentFeedbackDeliveryReceipt
    ) -> AgentFeedbackReceiptAdmission {
        guard case .queued = state else { return .fenced(.notQueued) }
        guard receipt.submissionID == id else { return .fenced(.foreignReceipt) }
        state = .delivered(AgentFeedbackDeliveryOutcome(
            receipt: receipt,
            sentAttachmentIDs: reference.attachments.map(\.id)
        ))
        return .applied
    }

    /// Records a definite transport/provider failure.
    @discardableResult
    mutating func markFailed(_ failure: AgentFeedbackDeliveryFailure) -> Bool {
        guard case .queued = state else { return false }
        state = .failed(failure)
        return true
    }

    /// An explicit user retry after a definite failure. The only
    /// re-dispatch path; the idempotency key stays stable.
    @discardableResult
    mutating func retry() -> Bool {
        guard case .failed = state else { return false }
        state = .queued
        return true
    }

    /// Cancellation. A queued submission may already be in flight: without
    /// dispatcher confirmation the honest state is ``deliveryUnknown``,
    /// which is never retried blindly.
    mutating func cancel(dispatcherConfirmed: Bool) -> AgentFeedbackCancellationResult {
        guard case .queued = state else { return .alreadyTerminal }
        if dispatcherConfirmed {
            state = .cancelled
            return .cancelled
        }
        state = .deliveryUnknown
        return .deliveryUnknown
    }
}

nonisolated enum AgentFeedbackReceiptAdmission: Equatable, Sendable {
    case applied
    case fenced(AgentFeedbackReceiptFence)
}

nonisolated enum AgentFeedbackReceiptFence: String, Sendable, Equatable {
    /// The receipt acknowledges a different submission id.
    case foreignReceipt
    /// The receipt arrived for a submission that is not queued.
    case notQueued
}

nonisolated enum AgentFeedbackCancellationResult: String, Sendable, Equatable {
    case cancelled
    case deliveryUnknown
    case alreadyTerminal
}

/// How the feedback's outcome is known.
///
/// An agent's "addressed" report is not user acceptance and not
/// independent verification: it is its own state, and only an explicit
/// user fact accepts.
nonisolated enum AgentFeedbackResolution: String, Codable, Sendable {
    case unresolved
    case agentReportedAddressed
    case acceptedByUser

    /// Unknown future values fail closed to `.unresolved`.
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unresolved
    }
}

extension AgentFeedbackSubmission {
    /// The attachment the anchor annotates: for a visual reference, the
    /// first image. The receipt's claimed identity is compared against its
    /// content identity.
    var annotatedAttachment: AgentFeedbackAttachment? {
        guard reference.artifactKind == .visualPreview else { return nil }
        return reference.attachments.first { $0.kind == .image }
    }

    /// Did the provider provably see the annotated revision? A forwarded
    /// path or editor buffer is not proof: only matching bytes are.
    var revisionProof: AgentFeedbackRevisionProof {
        guard case let .delivered(outcome) = state,
              let attachment = annotatedAttachment,
              let observed = outcome.receipt.observedArtifactIdentity,
              observed.isValid else {
            return .unproven
        }
        return observed.sha256 == attachment.sha256
                && observed.byteCount == attachment.byteCount
            ? .contentVerified
            : .mismatchClaimed
    }

    /// The content-free durable record for the existing C1b
    /// `recordFeedback` API: the reference fingerprint — never text,
    /// paths, or bytes — bound to the viewed candidate's code state.
    var durableRecord: AgentTaskFeedbackRecord {
        AgentTaskFeedbackRecord(
            reference: reference.fingerprint,
            observedAt: submittedAt,
            codeState: reference.candidate.codeState
        )
    }

    /// Unresolved feedback survives continuation: #1756 carries every
    /// submission that is not user-accepted into the next attempt.
    var isUnresolved: Bool { resolution != .acceptedByUser }

    /// The one dispatch of this submission through the task's owning
    /// adapter. `id` is the idempotency key the transport and the
    /// continuation contract deduplicate on.
    var dispatchRequest: AgentFeedbackDispatchRequest {
        AgentFeedbackDispatchRequest(
            submissionID: id,
            taskID: reference.taskID,
            reference: reference,
            submittedAt: submittedAt
        )
    }

    @discardableResult
    mutating func noteAgentReportedAddressed() -> Bool {
        guard resolution == .unresolved else { return false }
        resolution = .agentReportedAddressed
        return true
    }

    @discardableResult
    mutating func noteUserAcceptance() -> Bool {
        guard resolution == .unresolved
                || resolution == .agentReportedAddressed else {
            return false
        }
        resolution = .acceptedByUser
        return true
    }
}

nonisolated enum AgentFeedbackRevisionProof: String, Codable, Sendable {
    /// The receipt's content identity matches the annotated attachment.
    case contentVerified
    /// The provider claimed a different content identity: it saw
    /// something else, honestly reported.
    case mismatchClaimed
    /// No content identity was acknowledged: delivery is known, the
    /// revision observation is not.
    case unproven
}

/// The one dispatch of a submission through the task's owning adapter.
nonisolated struct AgentFeedbackDispatchRequest: Hashable, Sendable {
    let submissionID: UUID
    let taskID: UUID
    let reference: AgentFeedbackReference
    let submittedAt: Date
}

/// Seam for #1756's continuation contract: the single dispatch path.
/// #1758 owns the request and validates the receipt; #1756 owns the
/// routing. The closure is called exactly once per queued submission; a
/// `nil` result means no acknowledgment arrived (delivery-unknown), never
/// a delivery.
typealias AgentFeedbackDispatch = @Sendable (AgentFeedbackDispatchRequest) async -> AgentFeedbackDeliveryReceipt?

nonisolated enum AgentFeedbackSubmissionFence: Error, Equatable, Sendable {
    /// The reference fails its bounds.
    case invalidReference
    /// Attachments the transport cannot carry; the draft is preserved for
    /// the explicit text-only path.
    case attachmentUnsupported([AgentFeedbackAttachmentRejection])
    /// A submission with the same content fingerprint is already
    /// queued/delivered/unknown — resubmitting would risk a second
    /// revision.
    case duplicateSubmission(UUID)
}

nonisolated enum AgentFeedbackStateMachine {
    /// Binds the draft to its viewed candidate and submits it. The
    /// reference is used exactly as stored — a newer candidate does not
    /// re-target it.
    static func submit(
        draft: AgentFeedbackDraft,
        support: AgentFeedbackInputSupport,
        anchorResolution: AgentFeedbackAnchorResolution = .resolved,
        existing: [AgentFeedbackSubmission],
        now: Date = Date()
    ) -> Result<AgentFeedbackSubmission, AgentFeedbackSubmissionFence> {
        guard draft.reference.isValid else { return .failure(.invalidReference) }
        if case let .failure(fence) = checkDuplicate(draft.reference, existing: existing) {
            return .failure(fence)
        }
        let gate = AgentFeedbackSubmissionGate.validate(draft.reference, against: support)
        guard gate.isFullySupported else {
            return .failure(.attachmentUnsupported(gate.rejections))
        }
        return .success(AgentFeedbackSubmission(
            reference: draft.reference,
            anchorResolutionAtSubmission: anchorResolution,
            disclosedOmissions: [],
            submittedAt: now
        ))
    }

    /// The explicit text-only path: sends the text-only projection and
    /// records every omitted attachment. The user chose this after the
    /// gate's explanation; nothing is dropped silently.
    static func submitTextOnly(
        draft: AgentFeedbackDraft,
        rejections: [AgentFeedbackAttachmentRejection],
        anchorResolution: AgentFeedbackAnchorResolution = .resolved,
        existing: [AgentFeedbackSubmission],
        now: Date = Date()
    ) -> Result<AgentFeedbackSubmission, AgentFeedbackSubmissionFence> {
        guard draft.reference.isValid else { return .failure(.invalidReference) }
        let projection = draft.reference.textOnlyVariant
        guard projection.isValid else { return .failure(.invalidReference) }
        if case let .failure(fence) = checkDuplicate(projection, existing: existing) {
            return .failure(fence)
        }
        var disclosed = rejections
        let rejectedIDs = Set(rejections.map(\.attachmentID))
        for attachment in draft.reference.attachments where !rejectedIDs.contains(attachment.id) {
            disclosed.append(AgentFeedbackAttachmentRejection(
                attachmentID: attachment.id,
                reason: .omittedByUserChoice
            ))
        }
        return .success(AgentFeedbackSubmission(
            reference: projection,
            anchorResolutionAtSubmission: anchorResolution,
            disclosedOmissions: disclosed,
            submittedAt: now
        ))
    }

    private static func checkDuplicate(
        _ reference: AgentFeedbackReference,
        existing: [AgentFeedbackSubmission]
    ) -> Result<Void, AgentFeedbackSubmissionFence> {
        let fingerprint = reference.fingerprint
        if let live = existing.first(where: {
            $0.reference.fingerprint == fingerprint && $0.state.isDuplicateBlocking
        }) {
            return .failure(.duplicateSubmission(live.id))
        }
        return .success(())
    }
}
