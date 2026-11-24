import Foundation

/// Creates and retains one registry-owned reviewer session per durable cycle.
/// The implementer session is never passed to this driver. A provider without
/// `AgentAdapterReviewingSession` support fails instead of inventing a verdict
/// from lifecycle completion.
actor AgentTaskAdapterReviewDriver: AgentTaskReviewDriving {
    nonisolated let reviewerControl: AgentTaskReviewerControl
    private let adapters: AgentAdapterRegistry
    private let adapterID: AdapterID
    private let versions: PineAdapterContractVersionRange
    private var sessions: [UUID: any AgentAdapterSession] = [:]
    private var objectives: [UUID: String] = [:]
    private var reviewBindings: [UUID: AgentAdapterReviewBinding] = [:]
    private var starting: Set<UUID> = []

    init(
        adapters: AgentAdapterRegistry, adapterID: AdapterID,
        versions: PineAdapterContractVersionRange
    ) {
        self.adapters = adapters
        self.adapterID = adapterID
        reviewerControl = adapters.reviewerControl(adapterID: adapterID)
        self.versions = versions
    }

    func startReviewer(
        _ start: AgentTaskReviewStart
    ) async throws -> AgentVendorSessionIdentity {
        let task = start.task
        let cycleID = start.cycleID
        if let existing = sessions[cycleID] {
            return try await adapters.reviewerIdentity(for: existing)
        }
        // Reject reentrant creation rather than letting a later startup replace
        // the session whose identity is already persisted in the cycle.
        guard !starting.contains(cycleID) else {
            throw AgentTaskVerificationServiceError.unavailable
        }
        starting.insert(cycleID)
        defer { starting.remove(cycleID) }
        let lease = try await start.bindings.revalidate(start.binding)
        let reviewBinding = try await Self.binding(
            lease: lease, expected: start.request.expected, checks: start.checks
        )
        let offer = try await adapters.probe(adapterID: adapterID)
        let contract = try await adapters.negotiate(
            offer: offer,
            policy: AdapterNegotiationPolicy(
                allowedVersions: versions, transportPreference: [.ownedStandardIO],
                acceptedAuthentication: [.ownedChildPipe]
            )
        )
        let session = try await adapters.makeSession(
            contract: contract, resumeFrom: nil, downstream: { _ in .accepted },
            reviewBinding: reviewBinding
        )
        do {
            try await session.start()
            let identity = try await adapters.reviewerIdentity(for: session)
            sessions[cycleID] = session
            objectives[cycleID] = task.objective ?? task.title ?? "Task result"
            reviewBindings[cycleID] = reviewBinding
            return identity
        } catch {
            await session.stop(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
            throw error
        }
    }

    func reviewerIdentity(cycleID: UUID) async throws -> AgentVendorSessionIdentity {
        guard let session = sessions[cycleID] else {
            throw AgentTaskVerificationServiceError.unavailable
        }
        return try await adapters.reviewerIdentity(for: session)
    }

    func rebindReviewer(_ start: AgentTaskReviewStart) async throws {
        guard let session = sessions[start.cycleID] else {
            throw AgentTaskVerificationServiceError.unavailable
        }
        let lease = try await start.bindings.revalidate(start.binding)
        let binding = try await Self.binding(
            lease: lease, expected: start.request.expected, checks: start.checks
        )
        try await adapters.rebindReview(on: session, binding: binding)
        reviewBindings[start.cycleID] = binding
    }

    func review(
        dispatch: AgentTaskReviewDispatch, criteria: String,
        beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterReviewResult {
        guard let session = sessions[dispatch.cycleID],
              let objective = objectives[dispatch.cycleID],
              let binding = reviewBindings[dispatch.cycleID],
              binding.expected.code == dispatch.codeState,
              binding.expected.environment == dispatch.environment else {
            throw AgentTaskVerificationServiceError.unavailable
        }
        return try await withTaskCancellationHandler {
            try await adapters.review(
                on: session,
                request: AgentAdapterReviewRequest(
                    objective: objective, criteria: criteria,
                    candidateFingerprint: dispatch.codeState.trackedFingerprint,
                    checkPlanIdentity: dispatch.checkPlanIdentity,
                    binding: binding
                ),
                beforeDispatch: beforeDispatch
            )
        } onCancel: {
            Task.detached { await self.disposeReviewer(cycleID: dispatch.cycleID) }
        }
    }

    func disposeReviewer(cycleID: UUID) async {
        let session = sessions.removeValue(forKey: cycleID)
        objectives.removeValue(forKey: cycleID)
        reviewBindings.removeValue(forKey: cycleID)
        if let session {
            await session.stop(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        }
    }

    var retainedContextCount: Int {
        sessions.count + objectives.count + reviewBindings.count
    }

    private static func binding(
        lease: RecentAgentTaskFilesystemValidationLease,
        expected: AgentVerificationIdentitySnapshot,
        checks: AgentTaskCheckObservation
    ) async throws -> AgentAdapterReviewBinding {
        let context = try await runOnBackground {
            var environment = [
                "-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1",
                "GIT_CONFIG_GLOBAL=/dev/null", "GIT_OPTIONAL_LOCKS=0",
                "GIT_TERMINAL_PROMPT=0"
            ]
            if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
                environment.append("DEVELOPER_DIR=" + developer)
            }
            let root = lease.canonicalWorktree
            let diff = GitCommand.runExecutable(
                URL(fileURLWithPath: "/usr/bin/env"),
                arguments: Array(environment) + [
                    "/usr/bin/git", "diff", "--no-ext-diff", "--text", "HEAD"
                ], at: root, timeout: 10, captureLimit: 65_536
            )
            guard diff.succeeded else { throw AgentAdapterControlError.unsupported }
            return diff.output
        }
        let binding = AgentAdapterReviewBinding(
            lease: lease, expected: expected, changeContext: context, checks: checks
        )
        try await runOnBackground { try binding.validate() }
        return binding
    }
}
