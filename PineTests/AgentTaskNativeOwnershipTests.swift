import Foundation
import Testing
@testable import Pine

/// Runtime ownership tests for the policy-based token (#1723): constructor
/// cross-checks, the source join, the environment digest, the filesystem
/// lease, and irreversible revocation. Executable stamp gates live in the
/// spawner and the process receipt, not here.
struct AgentTaskNativeOwnershipTests {
    @Test func initCrossChecksPolicyAndBinding() async throws {
        let fixture = try await NativeOwnershipFixture()
        defer { fixture.remove() }
        let environment = ProcessInfo.processInfo.environment
        let binding = fixture.ownership.binding
        let wrongTask = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: UUID(), runID: fixture.reservation.runID)
        await #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            try await runOnBackground {
                try AgentTaskNativeOwnership(policy: fixture.policy, binding: wrongTask,
                    filesystem: fixture.lease, bindings: fixture.validator, environment: environment)
            }
        }
        let wrongRun = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: fixture.reservation.taskID, runID: UUID())
        await #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            try await runOnBackground {
                try AgentTaskNativeOwnership(policy: fixture.policy, binding: wrongRun,
                    filesystem: fixture.lease, bindings: fixture.validator, environment: environment)
            }
        }
        // A policy minted for another binding ID cannot join this binding.
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: fixture.policy.agentID, selectedExecutable: URL(fileURLWithPath: "/selected/codex"))
        guard case .eligible(let mismatchedPolicy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: fixture.reservation.taskID, runID: fixture.reservation.runID,
            bindingID: UUID(), selection: selection) else {
            throw AgentTaskNativeAdmissionError.invalidPolicy
        }
        await #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            try await runOnBackground {
                try AgentTaskNativeOwnership(policy: mismatchedPolicy, binding: binding,
                    filesystem: fixture.lease, bindings: fixture.validator, environment: environment)
            }
        }
    }

    @Test func validationRequiresTheRegistrySourceJoin() async throws {
        let fixture = try await NativeOwnershipFixture()
        defer { fixture.remove() }
        // The fixture's ownership is source-bound by the registry path.
        try await runOnBackground { try fixture.ownership.validate() }
        // A second source join on the same ownership is refused.
        await #expect(throws: AgentTaskNativeAdmissionError.unavailable) {
            try fixture.ownership.bindSource(fixture.adapters.sourceIdentity(for: fixture.session))
        }
        // A fresh, unbound ownership validates its selection but not itself.
        let unbound = try AgentTaskNativeOwnership(
            policy: fixture.policy,
            binding: AgentTaskEnvironmentBinding.nativeBindingForTesting(
                taskID: fixture.reservation.taskID, runID: fixture.reservation.runID),
            filesystem: fixture.lease, bindings: fixture.validator,
            environment: ProcessInfo.processInfo.environment)
        try await runOnBackground { try unbound.validateSelection() }
        await #expect(throws: AgentTaskNativeAdmissionError.self) {
            try await runOnBackground { try unbound.validate() }
        }
    }

    @Test func revokeIsIrreversibleAndRedacted() async throws {
        let fixture = try await NativeOwnershipFixture()
        defer { fixture.remove() }
        let ownership = fixture.ownership
        try await runOnBackground { try ownership.validate() }
        ownership.revoke()
        await #expect(throws: AgentTaskNativeAdmissionError.self) {
            try await runOnBackground { try ownership.validate() }
        }
        await #expect(throws: AgentTaskNativeAdmissionError.self) {
            try await runOnBackground { try ownership.validateSelection() }
        }
        #expect(ownership.description == "<redacted:native-ownership>")
        #expect(ownership.debugDescription.contains("redacted"))
        #expect(Mirror(reflecting: ownership).children.map(\.label) == ["value"])
    }

    @Test func environmentDigestFencesTheLaunchGate() async throws {
        let fixture = try await NativeOwnershipFixture()
        defer { fixture.remove() }
        let ownership = fixture.ownership
        let environment = ProcessInfo.processInfo.environment
        try await runOnBackground { try ownership.validateLaunch(environment: environment) }
        var mutated = environment
        mutated["PATH"] = "/different"
        await #expect(throws: AgentTaskNativeAdmissionError.invalidPolicy) {
            try await runOnBackground { try ownership.validateLaunch(environment: mutated) }
        }
    }

    @Test func filesystemLeaseFencesTheLaunchGate() async throws {
        let fixture = try await NativeOwnershipFixture()
        defer { fixture.remove() }
        let ownership = fixture.ownership
        let environment = ProcessInfo.processInfo.environment
        try await runOnBackground { try ownership.validateLaunch(environment: environment) }
        // The bound worktree vanishes: the lease stops revalidating.
        try FileManager.default.removeItem(at: fixture.root)
        await #expect(throws: AgentTaskNativeAdmissionError.self) {
            try await runOnBackground { try ownership.validateLaunch(environment: environment) }
        }
    }
}

nonisolated actor NativeOwnershipValidator: AgentTaskNativeBindingValidator {
    let binding: AgentTaskEnvironmentBinding
    let lease: RecentAgentTaskFilesystemValidationLease
    init(binding: AgentTaskEnvironmentBinding, lease: RecentAgentTaskFilesystemValidationLease) {
        self.binding = binding
        self.lease = lease
    }
    func revalidate(_ requested: AgentTaskEnvironmentBinding) async throws -> RecentAgentTaskFilesystemValidationLease {
        guard requested == binding else { throw AgentTaskEnvironmentBindingError.staleBinding }
        try requested.validateAuthority()
        return lease
    }
}

nonisolated struct NativeOwnershipFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    let result: AdapterProbeResult
    func probe() async throws -> AdapterProbeResult { result }
    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        NativeOwnershipSession(contract: request.contract)
    }
}

nonisolated struct NativeOwnershipSession: AgentAdapterSession {
    let contract: NegotiatedAdapterContract
    func start() async throws {}
    func stop(deadline: ContinuousClock.Instant) async {}
}

nonisolated struct NativeOwnershipFixture: Sendable {
    let root: URL
    let reservation: AgentTaskNativeReservation
    let policy: AgentTaskNativeLaunchPolicy
    let lease: RecentAgentTaskFilesystemValidationLease
    let validator: NativeOwnershipValidator
    let adapters: AgentAdapterRegistry
    let session: any AgentAdapterSession
    let ownership: AgentTaskNativeOwnership

    @MainActor
    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-native-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reservation = AgentTaskNativeReservation(taskID: UUID(), runID: UUID())
        let binding = AgentTaskEnvironmentBinding.nativeBindingForTesting(
            taskID: reservation.taskID, runID: reservation.runID)
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(validating: "codex"),
            selectedExecutable: URL(fileURLWithPath: "/selected/codex"))
        policy = try #require({
            guard case .eligible(let value) = AgentTaskNativeLaunchPolicy.evaluate(
                taskID: reservation.taskID, runID: reservation.runID, bindingID: binding.id,
                selection: selection) else { return nil }
            return value
        }())
        lease = try #require(
            await runOnBackground {
                RecentAgentTaskFilesystemValidator.validationLease(
                    for: AgentTaskProjectIdentity(canonicalProjectPath: root.path, canonicalWorktreePath: root.path),
                    expectedProof: nil
                )
            }
        )
        validator = NativeOwnershipValidator(binding: binding, lease: lease)
        ownership = try AgentTaskNativeOwnership(
            policy: policy, binding: binding, filesystem: lease, bindings: validator,
            environment: ProcessInfo.processInfo.environment
        )
        let factoryID = try AdapterFactoryID(validating: "test.native.ownership")
        let signals: Set<AdapterLifecycleCapabilities.Signal> = [
            .init(scope: .turn, phase: .started),
            .init(scope: .turn, phase: .failed),
            .init(scope: .turn, phase: .cancelled)
        ]
        let profile = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: signals, evidence: []),
            delivery: AdapterDeliverySemantics(ordering: .unordered, minimumAuthentication: .ownedChildPipe))
        let version = PineAdapterContractVersion(major: 1, minor: 1)
        let versions = PineAdapterContractVersionRange(minimum: version, maximum: version)
        let descriptor = AdapterDescriptor(
            adapterID: try AdapterID(validating: "test:native-ownership"),
            agentID: selection.agentID, factoryID: factoryID,
            contractVersions: versions, maximumProfiles: [profile])
        let presentation = try AgentPresentationDescriptor(
            agentID: selection.agentID, displayName: "Codex",
            executableAliases: [ExecutableAlias(validating: "codex")], style: .codex)
        adapters = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(descriptor, NativeOwnershipFactory(id: factoryID, result: try AdapterProbeResult(
                detectedVendorVersion: DetectedVendorVersion("fixture"), detectedSchema: nil,
                offeredProfiles: [profile], offeredContractVersions: versions)))]
        )
        let offer = try await adapters.probe(adapterID: descriptor.adapterID)
        let contract = try await adapters.negotiate(
            offer: offer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: versions, transportPreference: [.ownedStandardIO],
                acceptedAuthentication: [.ownedChildPipe]
            )
        )
        session = try await adapters.makeSession(contract: contract, resumeFrom: nil) { _ in .accepted }
        try ownership.bindSource(adapters.sourceIdentity(for: session))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
