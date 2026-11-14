import Foundation

/// Request-only projection over the shared, registry-validated contract. One
/// instance belongs to exactly one source attempt. It never derives idle,
/// success, Ready or acceptance from resolving the last pending question.
nonisolated struct AgentAdapterAttentionState {
    enum Outcome: Equatable, Sendable {
        case opened, resolved(remaining: Int), expired(count: Int)
        case historicalResolution, duplicate, foreignSource, unrelated, mismatchedContext
        case needsReconciliation
    }

    private struct Key: Hashable {
        let scope: AdapterLifecycleScope
        let context: VendorReference
        let request: VendorReference
    }
    private struct Context: Hashable {
        let scope: AdapterLifecycleScope
        let reference: VendorReference
    }

    static let maximumRetainedRequests = 64
    let source: ValidatedAgentSourceIdentity
    private var pending: Set<Key> = []
    private var resolved: Set<Key> = []
    private var closedContexts: Set<Context> = []
    private var invalidated = false

    init?(owner: any AgentAdapterSession, firstEvent: ValidatedAgentEvent) {
        guard firstEvent.hasSameAttempt(as: owner) else { return nil }
        source = firstEvent.sourceIdentity
    }

    var pendingCount: Int { pending.count }

    func isActionable(scope: AdapterLifecycleScope, request: VendorReference, context: VendorReference) -> Bool {
        !invalidated && pending.contains(Key(scope: scope, context: context, request: request))
    }

    mutating func invalidate() {
        invalidated = true
        pending.removeAll()
    }

    mutating func cancel(scope: AdapterLifecycleScope, context: VendorReference) -> Outcome {
        guard !invalidated else { return .needsReconciliation }
        let closed = Context(scope: scope, reference: context)
        guard closedContexts.count < Self.maximumRetainedRequests || closedContexts.contains(closed) else {
            invalidate()
            return .needsReconciliation
        }
        closedContexts.insert(closed)
        let expired = pending.filter { $0.scope == scope && $0.context == context }
        pending.subtract(expired)
        return .expired(count: expired.count)
    }

    mutating func apply(_ event: ValidatedAgentEvent) -> Outcome {
        guard event.sourceIdentity == source else { return .foreignSource }
        guard !invalidated else { return .needsReconciliation }
        switch event.candidate.event {
        case .question(let attention), .approval(let attention):
            guard let context = attention.context else {
                invalidate()
                return .needsReconciliation
            }
            let key = Key(scope: attention.scope, context: context, request: attention.request)
            guard !closedContexts.contains(Context(scope: key.scope, reference: key.context)),
                  !resolved.contains(key) else { return .duplicate }
            if pending.contains(key) { return .duplicate }
            guard !pending.contains(where: { $0.request == key.request && $0 != key }),
                  !resolved.contains(where: { $0.request == key.request && $0 != key }) else {
                return .mismatchedContext
            }
            guard pending.count + resolved.count < Self.maximumRetainedRequests else {
                invalidate()
                return .needsReconciliation
            }
            pending.insert(key)
            return .opened
        case .requestResolved(let resolution):
            let key = Key(scope: resolution.scope, context: resolution.context, request: resolution.request)
            if resolved.contains(key) { return .duplicate }
            guard !pending.contains(where: { $0.request == key.request && $0 != key }),
                  !resolved.contains(where: { $0.request == key.request && $0 != key }) else {
                return .mismatchedContext
            }
            guard pending.count + resolved.count < Self.maximumRetainedRequests || pending.contains(key) else {
                invalidate()
                return .needsReconciliation
            }
            let wasPending = pending.remove(key) != nil
            resolved.insert(key)
            return wasPending ? .resolved(remaining: pending.count) : .historicalResolution
        case .lifecycle(let lifecycle):
            guard [.succeeded, .failed, .cancelled, .settled].contains(lifecycle.phase),
                  let reference = lifecycle.reference else { return .unrelated }
            if lifecycle.scope == .session || lifecycle.scope == .run {
                invalidate()
                return .needsReconciliation
            }
            return cancel(scope: lifecycle.scope, context: reference)
        case .processExited:
            invalidate()
            return .needsReconciliation
        case .tool:
            return .unrelated
        }
    }
}
