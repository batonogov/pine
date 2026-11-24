import Foundation

/// Semantic controls, not provider RPC or execution authority. The task owner
/// supplies exact request/context references and separately validates its grant.
nonisolated enum AgentAdapterControl: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    enum Permission: Sendable { case allowOnce, deny }
    case submitInstruction(String)
    case answerQuestion(request: VendorReference, context: VendorReference, answers: [String: [String]])
    case answerPermission(request: VendorReference, context: VendorReference, decision: Permission)
    case requestCancellation(context: VendorReference)

    var description: String { "<redacted:adapter-control>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

/// Acknowledgement is not request resolution, confirmed cancellation, or
/// aggregate settlement. Uncertain dispatch must never be retried implicitly.
nonisolated enum AgentAdapterControlDispatch: Equatable, Sendable {
    case acknowledged, uncertain
}

nonisolated enum AgentAdapterControlError: Error, Equatable, Sendable {
    case unsupported
}

nonisolated protocol AgentAdapterControlledSession: AgentAdapterSession {
    /// Implementations must invoke beforeDispatch immediately before EVERY
    /// physical write (including deferred writes), propagating rejection.
    /// The supplied gate revalidates only; it must not consume a user response.
    /// Provider schemas, bounds, one-shot decisions and wire IDs stay private.
    /// Throwing after a possible effect must not conceal dispatch uncertainty.
    func dispatch(
        _ control: AgentAdapterControl,
        beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterControlDispatch
}

/// Candidate access supplied to a reviewer at session creation and again at
/// dispatch. The lease is runtime-only; checks are Pine observations, not a
/// reviewer-reported success claim.
nonisolated struct AgentAdapterReviewBinding: Sendable {
    let lease: RecentAgentTaskFilesystemValidationLease
    let expected: AgentVerificationIdentitySnapshot
    let changeContext: String
    let checks: AgentTaskCheckObservation

    func validate() throws {
        guard lease.revalidate(), changeContext.utf8.count <= 65_536,
              checks.isJudgment, checks.requiredSucceeded,
              checks.preCodeState == expected.code,
              checks.postCodeState == expected.code,
              checks.environment == expected.environment else {
            throw AgentAdapterControlError.unsupported
        }
    }
}

/// Transient review I/O for a separate session. Neither value is durable
/// evidence: the verification coordinator still fences identities and records
/// the only reviewer-outcome fact used for Ready.
nonisolated struct AgentAdapterReviewRequest: Sendable {
    let objective: String
    let criteria: String
    let candidateFingerprint: String
    let checkPlanIdentity: String
    let binding: AgentAdapterReviewBinding
}

nonisolated struct AgentAdapterReviewResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case passed, requestedChanges }
    let outcome: Outcome
    /// Ephemeral feedback for the automatic correction dispatch. Pine persists
    /// only its bounded content hash, not reviewer transcript text.
    let finding: String?
}

/// Optional reviewer capability. The registry forwards to the exact underlying
/// session instead of letting an implementer manufacture reviewer evidence.
nonisolated protocol AgentAdapterReviewingSession: AgentAdapterSession {
    var reviewerIdentity: AgentVendorSessionIdentity { get async throws }
    func review(
        _ request: AgentAdapterReviewRequest,
        beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterReviewResult
}
