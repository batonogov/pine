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
