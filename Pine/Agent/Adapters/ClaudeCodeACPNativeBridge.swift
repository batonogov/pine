import Foundation
import Synchronization

/// Registry-owned launch materials for one exact ClaudeCode task attempt.
/// Construction starts nothing; the ownership remains the only execution grant.
nonisolated struct ClaudeCodeACPNativeMaterials: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var description: String { "<redacted:claude-code-native-materials>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    struct Spawn: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var description: String { "<redacted:claude-code-native-spawn>" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["value": description]) }
        let child: ClaudeCodeACPOwnedChild
        let receipt: AgentTaskOwnedProcessReceipt
    }

    let registry: AgentTaskRegistry
    let ownership: AgentTaskNativeOwnership
    let workingDirectory: URL
    let sessionDeadline: ContinuousClock.Instant
    let loadSession: VendorReference?
    let sessionCreated: @Sendable (ClaudeCodeACPSession) async -> Void
    let acknowledgementSeam: @Sendable () async -> Void
    let cancellationSeam: @Sendable () async -> Void
    let replayWriteSeam: @Sendable (AgentTaskNativeOwnership.Effect) throws -> Void
    let prepareLaunch: @Sendable (ContinuousClock.Instant) async throws -> Void
    let spawn: @Sendable (ContinuousClock.Instant) throws -> Spawn

    init(
        registry: AgentTaskRegistry,
        ownership: AgentTaskNativeOwnership,
        workingDirectory: URL,
        sessionDeadline: ContinuousClock.Instant,
        loadSession: VendorReference? = nil,
        sessionCreated: @escaping @Sendable (ClaudeCodeACPSession) async -> Void = { _ in },
        acknowledgementSeam: @escaping @Sendable () async -> Void = {},
        cancellationSeam: @escaping @Sendable () async -> Void = {},
        replayWriteSeam: @escaping @Sendable (AgentTaskNativeOwnership.Effect) throws -> Void = { _ in },
        prepareLaunch: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = { _ in },
        spawn: @escaping @Sendable (ContinuousClock.Instant) throws -> Spawn
    ) {
        self.registry = registry
        self.ownership = ownership
        self.workingDirectory = workingDirectory
        self.sessionDeadline = sessionDeadline
        self.loadSession = loadSession
        self.sessionCreated = sessionCreated
        self.acknowledgementSeam = acknowledgementSeam
        self.cancellationSeam = cancellationSeam
        self.replayWriteSeam = replayWriteSeam
        self.prepareLaunch = prepareLaunch
        self.spawn = spawn
    }

    static func owned(
        registry: AgentTaskRegistry,
        ownership: AgentTaskNativeOwnership,
        executable: ClaudeCodeACPExecutableIdentity,
        workingDirectory: URL,
        sessionDeadline: ContinuousClock.Instant,
        loadSession: VendorReference? = nil,
        sessionCreated: @escaping @Sendable (ClaudeCodeACPSession) async -> Void = { _ in }
    ) -> Self {
        Self(
            registry: registry, ownership: ownership, workingDirectory: workingDirectory,
            sessionDeadline: sessionDeadline, loadSession: loadSession, sessionCreated: sessionCreated,
            prepareLaunch: { deadline in
                try ownership.validateSelection()
                try await executable.probeVersion(at: workingDirectory, deadline: deadline)
                try ownership.validateSelection()
            },
            spawn: { launchDeadline in
                try ClaudeCodeACPNativeSpawner.spawn(
                    ownership: ownership, executable: executable, workingDirectory: workingDirectory,
                    launchDeadline: launchDeadline, sessionDeadline: sessionDeadline
                )
            }
        )
    }
}

/// Production literal-argv spawn. The existing native child is the single
/// process-group stop/reap path; this adapter adds only ACP channel strictness.
nonisolated enum ClaudeCodeACPNativeSpawner {
    static func spawn(
        ownership: AgentTaskNativeOwnership,
        executable: ClaudeCodeACPExecutableIdentity,
        workingDirectory: URL,
        launchDeadline: ContinuousClock.Instant,
        sessionDeadline: ContinuousClock.Instant
    ) throws -> ClaudeCodeACPNativeMaterials.Spawn {
        precondition(!Thread.isMainThread)
        guard ContinuousClock.now < launchDeadline else { throw ClaudeCodeACPLaunchError.unavailable }
        let boundDirectory = URL(fileURLWithPath: ownership.binding.identity.canonicalWorktreePath)
        guard boundDirectory.resolvingSymlinksInPath().standardizedFileURL.path
                == workingDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
              ownership.policy.selectedExecutable.resolvingSymlinksInPath().standardizedFileURL
                == executable.canonicalURL else {
            throw ClaudeCodeACPLaunchError.changed
        }
        try executable.validateMetadataSynchronously()
        guard ContinuousClock.now < launchDeadline else { throw ClaudeCodeACPLaunchError.unavailable }
        let subprocess: UserTaskSubprocess
        do {
            // UserTaskSubprocess inherits the authorized launch environment.
            // The official adapter therefore honors CLAUDE_CODE_EXECUTABLE;
            // Pine never reads or substitutes provider credentials itself.
            subprocess = try UserTaskSubprocess(
                executableURL: executable.canonicalURL,
                arguments: ClaudeCodeACPExecutableIdentity.acpArguments,
                workingDirectory: workingDirectory,
                preSpawnValidation: { _ in try ownership.validate() }
            )
        } catch {
            throw ClaudeCodeACPLaunchError.unavailable
        }
        do {
            let channel = try CodexAppServerStdioChannel(
                standardInput: subprocess.standardInput,
                standardOutput: subprocess.standardOutput,
                standardError: subprocess.standardError,
                requireJSONRPCVersion: true
            )
            let receipt = try AgentTaskOwnedProcessReceipt(process: subprocess, ownership: ownership) {
                try executable.validateProcessImageSynchronously(processID: $0.processID, incarnation: $0)
            }
            let child = CodexAppServerNativeChild(subprocess: subprocess, channel: channel, receipt: receipt)
            let stderrDrain = Task {
                try? await channel.drainStandardError(until: sessionDeadline)
            }
            return ClaudeCodeACPNativeMaterials.Spawn(
                child: ClaudeCodeACPOwnedChild(
                    channel: channel,
                    processIdentity: receipt.identity,
                    close: { channel.close() },
                    stop: { deadline in
                        stderrDrain.cancel()
                        channel.close()
                        await child.stop(deadline: deadline)
                    }
                ),
                receipt: receipt
            )
        } catch {
            let group = subprocess.processGroup
            if group.isAlive { group.requestTermination() }
            _ = group.waitForRequestedTermination(completionTimeout: 2)
            transferFailedSpawn(
                poll: subprocess.pollExit(),
                groupIsAlive: { group.isAlive },
                reap: { subprocess.reapInBackground() },
                finishDeferredCleanup: { group.finishDeferredCleanup() }
            )
            throw ClaudeCodeACPLaunchError.unavailable
        }
    }

    /// Every non-exited result transfers the direct child to the reaper.
    /// The deferred group task retains both the group and the reaper token.
    static func transferFailedSpawn(
        poll: UserTaskProcessExitPoll,
        groupIsAlive: @escaping @Sendable () -> Bool,
        reap: @escaping @Sendable () -> UserTaskBackgroundReaper,
        finishDeferredCleanup: @escaping @Sendable () -> Void
    ) {
        let reaper: UserTaskBackgroundReaper?
        if case .exited = poll {
            reaper = nil
        } else {
            reaper = reap()
        }
        guard groupIsAlive() else {
            withExtendedLifetime(reaper) {}
            return
        }
        Task.detached {
            finishDeferredCleanup()
            withExtendedLifetime(reaper) {}
        }
    }
}

nonisolated struct ClaudeCodeACPNativeSubmission: Sendable {
    let id: UUID
    let previous: UUID?
    let receipt: AgentTaskNativeSubmissionReceipt
}

/// Existing task-registry operations used by the ACP session. No second task
/// journal or lifecycle store is introduced here.
nonisolated struct ClaudeCodeACPNativeControl: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var description: String { "<redacted:claude-code-native-control>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    let registry: AgentTaskRegistry
    let ownership: AgentTaskNativeOwnership
    private let acknowledgementSeam: @Sendable () async -> Void
    private let cancellationSeam: @Sendable () async -> Void
    private let replayWriteSeam: @Sendable (AgentTaskNativeOwnership.Effect) throws -> Void

    init(
        registry: AgentTaskRegistry,
        ownership: AgentTaskNativeOwnership,
        acknowledgementSeam: @escaping @Sendable () async -> Void = {},
        cancellationSeam: @escaping @Sendable () async -> Void = {},
        replayWriteSeam: @escaping @Sendable (AgentTaskNativeOwnership.Effect) throws -> Void = { _ in }
    ) {
        self.registry = registry
        self.ownership = ownership
        self.acknowledgementSeam = acknowledgementSeam
        self.cancellationSeam = cancellationSeam
        self.replayWriteSeam = replayWriteSeam
    }

    func validateReplayWrite(_ effect: AgentTaskNativeOwnership.Effect) throws {
        try replayWriteSeam(effect)
        try ownership.validatePhysicalEffect(effect)
    }

    func waitForAcknowledgement() async { await acknowledgementSeam() }

    func prepareSubmission() async throws -> ClaudeCodeACPNativeSubmission {
        let taskID = ownership.policy.taskID
        let previous = await registry.task(for: taskID)?.nativeDispatch?.submissions.last?.id
        let id = try await registry.prepareNativeSubmission(afterResponseTo: previous, ownership: ownership)
        return ClaudeCodeACPNativeSubmission(
            id: id, previous: previous, receipt: try ownership.claimSubmission(id)
        )
    }

    func acknowledge(_ submission: ClaudeCodeACPNativeSubmission) async throws {
        // The seam runs inside the durable transition so a response observed
        // mid-persistence is claimed before the now-invalid ack can apply.
        await acknowledgementSeam()
        let transition: AgentTaskNativeTransition = submission.previous == nil
            ? .initialInputAcknowledged(operationID: nil)
            : .submissionAcknowledged(submission.receipt, operationID: nil)
        try await registry.recordNativeTransition(transition, ownership: ownership)
    }

    func responseObserved(_ submission: ClaudeCodeACPNativeSubmission) async throws {
        let operationID = await registry.task(for: ownership.policy.taskID)?.nativeDispatch?.operationID
        try await registry.recordNativeTransition(
            .submissionResponseObserved(submission.receipt, operationID: operationID), ownership: ownership
        )
    }

    func submissionUnknown(_ submission: ClaudeCodeACPNativeSubmission) async throws {
        try await registry.recordNativeTransition(
            .submissionUnknown(submissionID: submission.id), ownership: ownership
        )
    }

    func prepareCancellation() async throws {
        try await registry.recordNativeTransition(.cancellationRequested, ownership: ownership)
        await cancellationSeam()
    }

    func perform<Result: Sendable>(
        _ effect: AgentTaskNativeOwnership.Effect,
        deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await registry.performNativeEffect(effect, ownership: ownership) {
            try runClaudeCodeBoundedOperation(deadline: deadline, operation: operation)
        }
    }

    func invalidate() async {
        await registry.invalidateNativeOwnership(ownership)
    }
}

/// Production factory and registration descriptor for the owned ACP adapter.
/// A factory is one-shot and belongs to one prepared task/environment attempt.
nonisolated final class ClaudeCodeACPNativeFactory: AgentAdapterFactory, @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "<redacted:claude-code-native-factory>" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    static let contractVersion = PineAdapterContractVersion(major: 1, minor: 1)
    static func adapterID() throws -> AdapterID { try AdapterID(validating: "claude-code:acp") }
    static func factoryID() throws -> AdapterFactoryID { try AdapterFactoryID(validating: "pine.claude-code.acp") }

    nonisolated let id: AdapterFactoryID
    let maximumProfile: AdapterCapabilityProfile
    private let materials: ClaudeCodeACPNativeMaterials
    private let consumed = Mutex(false)

    static func descriptor(factoryID: AdapterFactoryID? = nil) throws -> AdapterDescriptor {
        try AdapterDescriptor(
            adapterID: Self.adapterID(),
            agentID: AgentID(migratingLegacyStableIdentifier: "claudeCode"),
            factoryID: try factoryID ?? Self.factoryID(),
            contractVersions: PineAdapterContractVersionRange(
                minimum: Self.contractVersion, maximum: Self.contractVersion
            ),
            maximumProfiles: [try ClaudeCodeACPSession.profile()]
        )
    }

    static func registered(materials: ClaudeCodeACPNativeMaterials) throws
        -> (descriptor: AdapterDescriptor, factory: ClaudeCodeACPNativeFactory) {
        let factory = try Self(materials: materials, factoryID: Self.factoryID())
        return (try descriptor(factoryID: factory.id), factory)
    }

    init(materials: ClaudeCodeACPNativeMaterials, factoryID: AdapterFactoryID) throws {
        guard materials.ownership.policy.agentID.value == "claudeCode",
              materials.ownership.policy.requestedSettings == .inheritNativeConfiguration else {
            throw AdapterSessionError.contractMismatch
        }
        self.materials = materials
        id = factoryID
        maximumProfile = try ClaudeCodeACPSession.profile()
    }

    func probe() async throws -> AdapterProbeResult {
        try Task.checkCancellation()
        let preparationDeadline = min(materials.sessionDeadline, .now.advanced(by: .seconds(30)))
        try await materials.prepareLaunch(preparationDeadline)
        try Task.checkCancellation()
        return try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion(ClaudeCodeACPSession.pinnedVersion),
            detectedSchema: DetectedVendorVersion("ACP 1"),
            offeredProfiles: [maximumProfile],
            offeredContractVersions: PineAdapterContractVersionRange(
                minimum: Self.contractVersion, maximum: Self.contractVersion
            )
        )
    }

    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        try Task.checkCancellation()
        guard request.resumeFrom == nil else { throw AdapterSessionError.checkpointNotSupported }
        guard consumed.withLock({ value in
            guard !value else { return false }
            value = true
            return true
        }) else { throw AdapterSessionError.contractAlreadyConsumed }
        let materials = self.materials
        let native = ClaudeCodeACPNativeControl(
            registry: materials.registry, ownership: materials.ownership,
            acknowledgementSeam: materials.acknowledgementSeam,
            cancellationSeam: materials.cancellationSeam,
            replayWriteSeam: materials.replayWriteSeam
        )
        let session = try ClaudeCodeACPSession(
            request: request,
            launch: { launchDeadline in
                try await materials.prepareLaunch(launchDeadline)
                let environment = ProcessInfo.processInfo.environment
                let spawned = try await materials.registry.performNativeEffect(
                    .launch(environment: environment), ownership: materials.ownership
                ) {
                    try materials.spawn(launchDeadline)
                }
                do {
                    try await materials.registry.admitNativeProcess(
                        materials.ownership, receipt: spawned.receipt
                    )
                    return try ClaudeCodeACPStdioTransport(
                        channel: spawned.child.channel,
                        authority: request.controlAuthority,
                        revokeOwnership: { Task { await native.invalidate() } },
                        child: spawned.child
                    )
                } catch {
                    // Spawn succeeded, so every later failure owns immediate
                    // bounded cleanup even before ownedTransport is installed.
                    await spawned.child.stop(min(materials.sessionDeadline, .now.advanced(by: .seconds(2))))
                    throw error
                }
            },
            cwd: materials.workingDirectory.path,
            deadline: materials.sessionDeadline,
            loadSession: materials.loadSession,
            native: native,
            beforeStartWrite: { try materials.ownership.validate() },
            revokeOwnership: { Task { await native.invalidate() } },
            sessionBound: { reference in
                try await materials.registry.recordNativeTransition(.sessionBound(AgentVendorSessionIdentity(
                    provider: materials.ownership.policy.agentID.value,
                    opaqueIdentifier: reference.rawValue,
                    executableVersion: ClaudeCodeACPSession.pinnedVersion
                )), ownership: materials.ownership)
            },
            promptResponded: { _ in .recorded },
            discovery: ClaudeCodeACPConfigurationDiscovery.Input(
                selectedExecutable: materials.ownership.policy.selectedExecutable,
                environmentProvenance: materials.ownership.policy.environmentProvenance
            )
        )
        await materials.sessionCreated(session)
        return session
    }
}

extension Notification.Name {
    nonisolated static let claudeCodeNativeOwnershipPrepared = Notification.Name("pine.claude-code.native-ownership-prepared")
}

nonisolated private final class ClaudeCodeACPNativeSessionBox: Sendable {
    let value = Mutex<ClaudeCodeACPSession?>(nil)
}

/// App-composition adapter owned by ProjectRegistry. It creates no task store,
/// starts no agent, and retains one runtime per exact task/run attempt.
@MainActor
final class ClaudeCodeACPNativeComposition: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "<redacted:claude-code-native-composition>" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    private let tasks: AgentTaskRegistry
    private var runtimes: [UUID: ClaudeCodeACPTaskRuntime] = [:]
    private var preparing: Set<UUID> = []

    init(tasks: AgentTaskRegistry) { self.tasks = tasks }

    func runtime(for taskID: UUID) -> ClaudeCodeACPTaskRuntime? { runtimes[taskID] }

    func prepare(_ ownership: AgentTaskNativeOwnership) async {
        let taskID = ownership.policy.taskID
        guard !preparing.contains(taskID) else { return }
        // Claim the preparing slot before the eviction await so the guard
        // and insertion are atomic across suspensions.
        preparing.insert(taskID)
        defer { preparing.remove(taskID) }
        // A retained runtime whose provider session already stopped is dead
        // (failed start or explicit stop): it cannot serve the replacement
        // ownership, so it is replaceable. Live or never-started runtimes
        // are retained.
        if let existing = runtimes[taskID], await existing.isProviderStopped() {
            runtimes[taskID] = nil
        }
        guard runtimes[taskID] == nil else { return }
        do {
            let working = URL(fileURLWithPath: ownership.binding.identity.canonicalWorktreePath)
            // Bounds preparation only. Session I/O keeps its own per-operation
            // bounds and must never be fenced by a fixed launch window.
            let captureDeadline = ContinuousClock.now.advanced(by: .seconds(60))
            let executable = try await ClaudeCodeACPExecutableIdentity.capture(
                selectedURL: ownership.policy.selectedExecutable, deadline: captureDeadline
            )
            let materials = ClaudeCodeACPNativeMaterials.owned(
                registry: tasks, ownership: ownership, executable: executable,
                workingDirectory: working, sessionDeadline: .claudeCodeACPUnbounded
            )
            _ = try await compose(materials)
        } catch {
            tasks.invalidateNativeOwnership(ownership)
        }
    }

    /// Shared by production preparation and deterministic composition tests.
    /// The returned runtime is retained here; callers explicitly start it.
    @discardableResult
    func compose(_ materials: ClaudeCodeACPNativeMaterials) async throws -> ClaudeCodeACPTaskRuntime {
        let ownership = materials.ownership
        let tasks = self.tasks
        guard materials.registry === tasks else { throw AgentTaskNativeAdmissionError.staleOwner }
        let taskID = ownership.policy.taskID
        if let existing = runtimes[taskID] {
            guard existing.runID == ownership.policy.runID,
                  existing.bindingID == ownership.policy.bindingID else {
                throw AgentTaskNativeAdmissionError.staleOwner
            }
            // A stopped provider makes the retained runtime dead; the
            // replacement composes fresh instead of inheriting the dead one.
            if await existing.isProviderStopped() {
                runtimes[taskID] = nil
            } else {
                return existing
            }
        }
        let box = ClaudeCodeACPNativeSessionBox()
        // Install the exact concrete-session receiver before factory creation.
        // NativeMaterials' callback is immutable, so compose over that owner only.
        let receiverMaterials = materials.withSessionCreated { session in
            box.value.withLock { $0 = session }
        }
        let registered = try ClaudeCodeACPNativeFactory.registered(materials: receiverMaterials)
        let presentation = try requireClaudeCodePresentation()
        let adapters = try AgentAdapterRegistry(
            compiledPresentations: [presentation],
            compiledAdapters: [(registered.descriptor, registered.factory)]
        )
        let offer = try await adapters.probe(adapterID: registered.descriptor.adapterID)
        let contract = try await adapters.negotiate(offer: offer, policy: AdapterNegotiationPolicy(
            allowedVersions: registered.descriptor.contractVersions,
            transportPreference: [.ownedStandardIO], acceptedAuthentication: [.ownedChildPipe]
        ))
        let session = try await adapters.makeSession(contract: contract, resumeFrom: nil) { event in
            await tasks.ingestNativeEvent(event, ownership: ownership)
        }
        try tasks.bindNativeSource(ownership, registry: adapters, session: session)
        guard let provider = box.value.withLock({ $0 }) else { throw ClaudeCodeACPError.unavailable }
        let runtime = try ClaudeCodeACPTaskRuntime(
            taskID: taskID, runID: ownership.policy.runID, bindingID: ownership.policy.bindingID,
            registry: adapters, owner: session, provider: provider,
            taskIsCurrent: { [tasks] in
                guard let task = tasks.task(for: taskID),
                      task.nativeDispatch?.runID == ownership.policy.runID,
                      task.nativeDispatch?.bindingID == ownership.policy.bindingID,
                      task.nativeDispatch?.phase != .unavailable,
                      task.lifecycle != .dismissed else { return false }
                return true
            },
            prepareControl: { _ in }, beforeDispatch: { _ in try ownership.validate() }
        )
        runtimes[taskID] = runtime
        return runtime
    }

    private func requireClaudeCodePresentation() throws -> AgentPresentationDescriptor {
        guard let presentation = try AgentPresentationCatalog.builtIn(stableIdentifier: "claudeCode") else {
            throw AdapterRegistrationError.descriptorMismatch
        }
        return presentation
    }
}

private extension ClaudeCodeACPNativeMaterials {
    func withSessionCreated(
        _ receiver: @escaping @Sendable (ClaudeCodeACPSession) -> Void
    ) -> Self {
        let previous = sessionCreated
        return Self(
            registry: registry, ownership: ownership, workingDirectory: workingDirectory,
            sessionDeadline: sessionDeadline, loadSession: loadSession,
            sessionCreated: { session in
                await previous(session)
                receiver(session)
            }, acknowledgementSeam: acknowledgementSeam,
            cancellationSeam: cancellationSeam, replayWriteSeam: replayWriteSeam,
            prepareLaunch: prepareLaunch, spawn: spawn
        )
    }
}

nonisolated private final class ClaudeCodeBoundedOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, any Error>?

    func settle(_ result: Result<T, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(until deadline: DispatchTime) -> Result<T, any Error>? {
        guard semaphore.wait(timeout: deadline) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return result
    }
}

/// The registry's physical-effect action is synchronous and already off-main.
/// Bridge the actor's async pipe write without blocking main or retrying it.
nonisolated private func runClaudeCodeBoundedOperation<T: Sendable>(
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable () async throws -> T
) throws -> T {
    guard ContinuousClock.now < deadline else { throw ClaudeCodeACPError.unavailable }
    let outcome = ClaudeCodeBoundedOutcome<T>()
    let task = Task.detached {
        do { outcome.settle(.success(try await operation())) } catch {
            outcome.settle(.failure(error))
        }
    }
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let seconds = max(Int(clamping: remaining.seconds + 5), 1)
    guard let result = outcome.wait(until: .now() + .seconds(seconds)) else {
        task.cancel()
        throw ClaudeCodeACPError.unavailable
    }
    task.cancel()
    return try result.get()
}
