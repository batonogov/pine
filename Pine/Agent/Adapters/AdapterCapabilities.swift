import Foundation

nonisolated struct PineAdapterContractVersion: Hashable, Comparable, Sendable {
    let major: UInt16
    let minor: UInt16
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

nonisolated struct PineAdapterContractVersionRange: Equatable, Sendable {
    let minimum: PineAdapterContractVersion
    let maximum: PineAdapterContractVersion
    var isValid: Bool { minimum <= maximum }
    func contains(_ value: PineAdapterContractVersion) -> Bool { minimum <= value && value <= maximum }
}

nonisolated enum AdapterTransport: String, Hashable, Sendable { case ownedStandardIO, authenticatedLocalIPC }
nonisolated enum AdapterLifecycleScope: String, Hashable, Sendable { case session, run, turn, item }
nonisolated enum AdapterLifecyclePhase: String, Hashable, Sendable {
    case started, working, waitingForQuestion, waitingForApproval, succeeded, failed, cancelled, settled
}
nonisolated enum AdapterEvidence: String, Hashable, Sendable { case tool, fileChange }
nonisolated enum AdapterReplay: String, Hashable, Sendable { case none, sourceCursor }
nonisolated enum AdapterOrdering: String, Hashable, Sendable { case unordered, ordered }
nonisolated enum CoreAuthenticationRequirement: String, Hashable, Sendable {
    case ownedChildPipe, authenticatedPeer
}

nonisolated enum AdapterProfileError: Error, Equatable, Sendable {
    case emptyLifecycle
    case missingDependency
    case replayRequiresOrdering
    case transportAuthenticationMismatch
}

nonisolated struct AdapterLifecycleCapabilities: Hashable, Sendable {
    struct Signal: Hashable, Sendable {
        let scope: AdapterLifecycleScope
        let phase: AdapterLifecyclePhase
    }

    let signals: Set<Signal>
    let evidence: Set<AdapterEvidence>

    init(signals: Set<Signal>, evidence: Set<AdapterEvidence>) throws {
        guard !signals.isEmpty else { throw AdapterProfileError.emptyLifecycle }
        let scopes = Set(signals.map(\.scope))
        guard !scopes.contains(.item) || scopes.contains(.turn) else { throw AdapterProfileError.missingDependency }
        guard !evidence.contains(.fileChange) || evidence.contains(.tool) else {
            throw AdapterProfileError.missingDependency
        }
        self.signals = signals
        self.evidence = evidence
    }

    func authorizes(scope: AdapterLifecycleScope, phase: AdapterLifecyclePhase) -> Bool {
        signals.contains(Signal(scope: scope, phase: phase))
    }
}

nonisolated struct AdapterDeliverySemantics: Hashable, Sendable {
    let replay: AdapterReplay
    let ordering: AdapterOrdering
    let minimumAuthentication: CoreAuthenticationRequirement

    init(
        replay: AdapterReplay = .none,
        ordering: AdapterOrdering,
        minimumAuthentication: CoreAuthenticationRequirement
    ) throws {
        guard replay == .none || ordering == .ordered else { throw AdapterProfileError.replayRequiresOrdering }
        self.replay = replay
        self.ordering = ordering
        self.minimumAuthentication = minimumAuthentication
    }
}

nonisolated struct AdapterCapabilityProfile: Hashable, Sendable {
    let transport: AdapterTransport
    let lifecycle: AdapterLifecycleCapabilities
    let delivery: AdapterDeliverySemantics

    var lifecycleSignals: Set<AdapterLifecycleCapabilities.Signal> { lifecycle.signals }
    var evidence: Set<AdapterEvidence> { lifecycle.evidence }
    var replay: AdapterReplay { delivery.replay }
    var ordering: AdapterOrdering { delivery.ordering }
    var minimumAuthentication: CoreAuthenticationRequirement { delivery.minimumAuthentication }

    init(
        transport: AdapterTransport,
        lifecycle: AdapterLifecycleCapabilities,
        delivery: AdapterDeliverySemantics
    ) throws {
        guard (transport == .ownedStandardIO && delivery.minimumAuthentication == .ownedChildPipe)
                || (transport == .authenticatedLocalIPC && delivery.minimumAuthentication == .authenticatedPeer) else {
            throw AdapterProfileError.transportAuthenticationMismatch
        }
        self.transport = transport
        self.lifecycle = lifecycle
        self.delivery = delivery
    }

    var deterministicWireValues: [String] {
        (["transport:\(transport.rawValue)", "replay:\(replay.rawValue)",
          "ordering:\(ordering.rawValue)", "authentication:\(minimumAuthentication.rawValue)"]
            + lifecycleSignals.map { "lifecycle:\($0.scope.rawValue):\($0.phase.rawValue)" }
            + evidence.map { "evidence:\($0.rawValue)" }).sorted()
    }

    func isSubset(of maximum: Self) -> Bool {
        transport == maximum.transport && lifecycleSignals.isSubset(of: maximum.lifecycleSignals)
            && evidence.isSubset(of: maximum.evidence)
            && replay == maximum.replay && ordering == maximum.ordering
            && minimumAuthentication == maximum.minimumAuthentication
    }
}
