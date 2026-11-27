import Foundation
import Observation
import Synchronization

/// A loopback endpoint a result action may own.
nonisolated struct AgentProjectResultEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let port: UInt16

    var isValid: Bool { (host == "127.0.0.1" || host == "::1") && port > 0 }
}

/// Pine-observed ownership of a result process. Stop and relaunch apply
/// only to this exact process group; the model provides no primitive to
/// affect other processes.
nonisolated struct AgentTaskResultOwnership: Equatable, Sendable {
    let processID: UInt32
    let processGroupID: UInt32
    /// Present while the owned server endpoint is up.
    let endpoint: AgentProjectResultEndpoint?
}

/// Binds a result action to the current candidate and environment
/// identity (consumed from #1753's capture contract) and to the owning
/// task. Two actions for different tasks or snapshots are never
/// interchangeable, even when they share a port, artifact path, or recipe.
nonisolated struct AgentTaskResultActionBinding: Equatable, Sendable {
    let taskID: UUID
    let project: AgentTaskProjectIdentity
    let recipeFingerprint: String
    let resultActionID: String
    let output: AgentProjectResultOutput
    let snapshot: AgentVerificationIdentitySnapshot

    init(
        taskID: UUID,
        project: AgentTaskProjectIdentity,
        recipeFingerprint: String,
        resultActionID: String,
        output: AgentProjectResultOutput,
        snapshot: AgentVerificationIdentitySnapshot
    ) {
        self.taskID = taskID
        self.project = project
        self.recipeFingerprint = recipeFingerprint
        self.resultActionID = resultActionID
        self.output = output
        self.snapshot = snapshot
    }

    /// Selection is side-effect free. It binds exactly one selected recipe
    /// action to one task candidate; it neither prepares nor launches it.
    init?(
        task: AgentTask,
        selection: AgentProjectRecipe.Selected,
        actionID: String,
        snapshot: AgentVerificationIdentitySnapshot
    ) {
        guard let action = selection.recipe.results.first(where: { $0.id == actionID }),
              action.isValid, selection.recipe.isValid,
              selection.recipe.canonicalProjectPath == task.project.canonicalProjectPath,
              AgentTaskMetadataStore.validCodeState(snapshot.code),
              AgentTaskMetadataStore.validEnvironment(snapshot.environment) else {
            return nil
        }
        self.init(
            taskID: task.id, project: task.project,
            recipeFingerprint: selection.recipe.fingerprint,
            resultActionID: action.id, output: action.output, snapshot: snapshot
        )
    }
}

nonisolated enum AgentTaskResultLaunchRefusal: String, Equatable, Sendable {
    case bindingChanged
    case notReady
    case grantNotCurrent
    case environmentUnavailable
    case originalCheckout
    case unsupportedOutput
    case authorityChanged
}

/// Live command authority shared by setup and result execution. Every call
/// recaptures content/tool identity with the exact child environment, re-reads
/// current task readiness, then rechecks grant and binding/lease authority.
nonisolated struct AgentTaskResultCommandAuthority: Sendable {
    let taskID: UUID
    let project: AgentTaskProjectIdentity
    let plan: AgentTaskCheckPlan
    let expected: AgentVerificationIdentitySnapshot
    private let currentGrant: @Sendable () -> AgentTaskCheckGrant?
    private let currentReadiness: @Sendable (
        AgentVerificationIdentitySnapshot
    ) -> AgentTaskReadiness?
    private let captureIdentity: @Sendable (
        [String: String]
    ) -> AgentVerificationIdentityCaptureResult
    private let environmentIsCurrent: @Sendable () -> Bool

    init(
        taskID: UUID,
        project: AgentTaskProjectIdentity,
        plan: AgentTaskCheckPlan,
        expected: AgentVerificationIdentitySnapshot,
        currentGrant: @escaping @Sendable () -> AgentTaskCheckGrant?,
        currentReadiness: @escaping @Sendable (
            AgentVerificationIdentitySnapshot
        ) -> AgentTaskReadiness?,
        captureIdentity: @escaping @Sendable (
            [String: String]
        ) -> AgentVerificationIdentityCaptureResult,
        environmentIsCurrent: @escaping @Sendable () -> Bool
    ) {
        self.taskID = taskID
        self.project = project
        self.plan = plan
        self.expected = expected
        self.currentGrant = currentGrant
        self.currentReadiness = currentReadiness
        self.captureIdentity = captureIdentity
        self.environmentIsCurrent = environmentIsCurrent
    }

    func validate(environment: [String: String]) -> AgentTaskResultLaunchRefusal? {
        guard project.canonicalProjectPath != project.canonicalWorktreePath else {
            return .originalCheckout
        }
        switch captureIdentity(environment) {
        case .current(let snapshot):
            guard snapshot == expected else { return .bindingChanged }
        case .changed:
            return .bindingChanged
        case .cancelled:
            return .authorityChanged
        case .unavailable:
            return .environmentUnavailable
        }
        guard let readiness = currentReadiness(expected),
              readiness.isReady, readiness.gaps.isEmpty else {
            return .notReady
        }
        guard currentGrant()?.matchesScope(
            taskID: taskID, plan: plan, environment: expected.environment
        ) == true else {
            return .grantNotCurrent
        }
        guard environmentIsCurrent() else { return .environmentUnavailable }
        return nil
    }
}

/// Fresh authority for one explicit result launch. Preparation remains a
/// separate observed dimension; the spawn gate never reuses cached readiness.
nonisolated struct AgentTaskResultLaunchContext: Sendable {
    let binding: AgentTaskResultActionBinding
    let command: AgentTaskCheckCommand
    let preparation: AgentProjectPreparation
    let authority: AgentTaskResultCommandAuthority

    init(
        binding: AgentTaskResultActionBinding,
        command: AgentTaskCheckCommand,
        preparation: AgentProjectPreparation,
        authority: AgentTaskResultCommandAuthority
    ) {
        self.binding = binding
        self.command = command
        self.preparation = preparation
        self.authority = authority
    }

    static func make(
        binding: AgentTaskResultActionBinding,
        selection: AgentProjectRecipe.Selected,
        preparation: AgentProjectPreparation,
        authority: AgentTaskResultCommandAuthority
    ) -> Self? {
        guard let action = selection.recipe.results.first(where: {
            $0.id == binding.resultActionID
        }), action.output == binding.output,
              selection.recipe.secretRequirements[action.command.id]?.isEmpty != false,
              selection.recipe.fingerprint == binding.recipeFingerprint,
              selection.plan.recipeFingerprint == selection.recipe.checks.fingerprint,
              authority.taskID == binding.taskID,
              authority.project == binding.project,
              authority.plan == selection.plan,
              authority.expected == binding.snapshot else {
            return nil
        }
        return Self(
            binding: binding, command: action.command,
            preparation: preparation, authority: authority
        )
    }

    var workingDirectory: URL {
        let root = URL(
            fileURLWithPath: binding.project.canonicalWorktreePath,
            isDirectory: true
        )
        guard !command.workingDirectory.isEmpty else { return root }
        return root.appendingPathComponent(command.workingDirectory, isDirectory: true)
    }

    /// Called off-main before scheduling and again inside the runner's
    /// pre-spawn gate with the exact environment inherited by that child.
    func validate(environment: [String: String]) -> AgentTaskResultLaunchRefusal? {
        guard preparation.isCurrentFor(binding.recipeFingerprint) else { return .notReady }
        guard binding.output.isRunnable else { return .unsupportedOutput }
        // The first slice executes Swift package CLI examples. Other typed
        // outputs retain their presentation/lifecycle without a fake runner.
        guard binding.output.isOneShot else { return .unsupportedOutput }
        guard command.isValid else { return .bindingChanged }
        return authority.validate(environment: environment)
    }
}

nonisolated struct AgentTaskResultLaunchRejection: Error {
    let refusal: AgentTaskResultLaunchRefusal
}

nonisolated protocol AgentTaskResultActionExecuting: Sendable {
    @discardableResult
    func execute(
        command: AgentTaskCheckCommand,
        workingDirectory: URL,
        preSpawnValidation: @escaping @Sendable ([String: String]) throws -> Void,
        processObserved: @escaping @Sendable (UInt32) -> Void,
        progress: UserTaskProgress
    ) -> UserTaskCancellation
}

/// Production adapter over Pine's bounded literal-argv, process-group runner.
nonisolated struct AgentTaskResultProcessExecutor: AgentTaskResultActionExecuting {
    func execute(
        command: AgentTaskCheckCommand,
        workingDirectory: URL,
        preSpawnValidation: @escaping @Sendable ([String: String]) throws -> Void,
        processObserved: @escaping @Sendable (UInt32) -> Void,
        progress: UserTaskProgress
    ) -> UserTaskCancellation {
        let runner = UserTaskRunner(
            timeout: command.timeout,
            processDidSpawn: { processID in
                guard processID > 0 else { return }
                processObserved(UInt32(processID))
            }
        )
        return runner.run(
            taskID: command.id,
            executableURL: command.executable,
            arguments: command.arguments,
            workingDirectory: workingDirectory,
            preSpawnValidation: preSpawnValidation,
            progress: progress
        )
    }
}

/// The presentation verb for a result output; non-runnable changes keep
/// View changes instead of a fictional launch action. Localization is the
/// presentation layer's concern (#1725).
nonisolated enum AgentProjectResultVerb: String, CaseIterable, Sendable {
    case openPreview
    case runApplication
    case runExample
    case viewChanges

    var title: String {
        switch self {
        case .openPreview: return "Open preview"
        case .runApplication: return "Run application"
        case .runExample: return "Run example"
        case .viewChanges: return "View changes"
        }
    }
}

extension AgentProjectResultOutput {
    nonisolated var verb: AgentProjectResultVerb {
        switch self {
        case .server: return .openPreview
        case .artifact: return .runApplication
        case .cli: return .runExample
        case .document: return .viewChanges
        }
    }
}

/// The lifecycle of one owned result action against one exact binding.
/// The executor drives transitions with observed facts; nothing here
/// starts or kills a process. Preparation and build are separate from
/// execution: a state starts at `.prepared` once the candidate's setup
/// and checks are current, and only an explicit launch runs a result.
nonisolated struct AgentTaskResultActionState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Preparation and build are complete; nothing is running.
        case prepared
        case starting
        /// A current result is available for this exact binding.
        case ready
        case failed(FailureReason)
        /// The requested endpoint is occupied by a non-owned process.
        /// The occupant is never killed; the user resolves the conflict.
        case portConflict
        case stopping
        /// The owned process terminated; the result is no longer current.
        /// Work (code state) is preserved.
        case stopped
        case cancelled
        /// The candidate or environment changed while the result was
        /// current; the evidence is no longer current.
        case stale
    }

    enum FailureReason: Equatable, Sendable {
        case startupFailed
        case missingPrerequisite(String)
        case processExited(Int32)
        case launchRefused(AgentTaskResultLaunchRefusal)
    }

    let binding: AgentTaskResultActionBinding
    private(set) var phase: Phase = .prepared
    private(set) var ownership: AgentTaskResultOwnership? = nil
    /// Launch attempts for this binding, including relaunches.
    /// Informational diagnostic only (in-memory, not persisted); every
    /// increment requires an explicit user launch request.
    private(set) var attempts = 0

    init(binding: AgentTaskResultActionBinding) {
        self.binding = binding
    }

    var isCurrent: Bool { phase == .ready }
    /// A current live preview: mutable content that changes without new
    /// evidence whenever the worktree changes.
    var isLivePreview: Bool { isCurrent && binding.output.isLivePreview }
    /// The concrete verb to present for this action.
    var verb: AgentProjectResultVerb { binding.output.verb }

    enum Event: Equatable, Sendable {
        /// An explicit user launch, relaunch, or re-run for this binding.
        case launchRequested
        /// Pine observed the process it launched.
        case processObserved(processID: UInt32, processGroupID: UInt32)
        /// The executor verified readiness (endpoint responded / app alive).
        case readyObserved
        case startupFailed
        case launchRefused(AgentTaskResultLaunchRefusal)
        case prerequisiteMissing(String)
        /// Bind failed: the endpoint is occupied by a non-owned process.
        case portOccupied
        /// Pine observed the owned process terminate.
        case processExited(Int32)
        /// An explicit user stop of the owned process.
        case stopRequested
        /// The launch was cancelled.
        case cancelled
        /// The candidate or environment identity changed.
        case candidateChanged
    }

    func reduced(by event: Event) -> Self {
        var next = self
        let ownedEndpoint: AgentProjectResultEndpoint? = {
            if case .server(let host, let port) = binding.output {
                return AgentProjectResultEndpoint(host: host, port: port)
            }
            return nil
        }()
        switch (phase, event) {
        case (.prepared, .launchRequested),
             (.stopped, .launchRequested),
             (.failed, .launchRequested),
             (.cancelled, .launchRequested),
             (.portConflict, .launchRequested),
             (.ready, .launchRequested) where binding.output.isOneShot:
            // Initial launch, relaunch, conflict retry, or example re-run
            // reuse the same binding and count as one more attempt. A
            // long-running ready result reuses the live process instead.
            next.phase = .starting
            next.ownership = nil
            next.attempts += 1
        case (.starting, .processObserved(let processID, let processGroupID))
            where processID != 0:
            // A degenerate observation (pid 0) would hand a future killpg the
            // caller's own process group; ignore it.
            next.ownership = AgentTaskResultOwnership(
                processID: processID, processGroupID: processGroupID, endpoint: ownedEndpoint
            )
        case (.starting, .readyObserved) where next.ownership != nil:
            // Readiness requires Pine-observed ownership.
            next.phase = .ready
        case (.starting, .startupFailed):
            next.phase = .failed(.startupFailed)
            next.ownership = nil
        case (.prepared, .launchRefused(let reason)),
             (.starting, .launchRefused(let reason)):
            next.phase = .failed(.launchRefused(reason))
            next.ownership = nil
        case (.prepared, .prerequisiteMissing(let name)),
             (.starting, .prerequisiteMissing(let name)):
            next.phase = .failed(.missingPrerequisite(name))
            next.ownership = nil
        case (.starting, .portOccupied):
            // The occupant is not ours: never kill it, stay truthful.
            next.phase = .portConflict
            next.ownership = nil
        case (.starting, .cancelled):
            next.phase = .cancelled
            next.ownership = nil
        case (.starting, .processExited(let code)):
            if binding.output.isOneShot, code == 0 {
                // A completed one-shot is the observed result; no live
                // process remains to own.
                next.phase = .ready
            } else {
                next.phase = .failed(.processExited(code))
            }
            next.ownership = nil
        case (.starting, .stopRequested):
            // Cancellation was accepted by the executor. Keep process
            // ownership until its final cleanup callback completes.
            next.phase = .stopping
        case (.ready, .stopRequested) where next.ownership != nil,
             (.stale, .stopRequested) where next.ownership != nil:
            next.phase = .stopping
        case (.ready, .processExited(let code)),
             (.stale, .processExited(let code)) where !binding.output.isOneShot:
            // The owned result process ended on its own; a stale preview
            // with a dead process must not keep claiming it.
            next.phase = code == 0 ? .stopped : .failed(.processExited(code))
            next.ownership = nil
        case (.stopping, .cancelled):
            next.phase = .cancelled
            next.ownership = nil
        case (.stopping, .processExited):
            next.phase = .stopped
            next.ownership = nil
        case (.ready, .candidateChanged):
            // Live changes make current evidence stale.
            next.phase = .stale
        default:
            // Unknown combinations, events for the wrong phase, and
            // requests against a stale binding fail closed as no-ops.
            break
        }
        return next
    }
}

/// Slot for the refusal the spawn gate named during pre-spawn validation. A
/// noncopyable `Mutex` reaches the `@Sendable` validation closure only
/// through a sendable box, the same shape as `AgentTaskResultGrantStore`.
nonisolated private final class PreSpawnRefusalBox: Sendable {
    private let value = Mutex<AgentTaskResultLaunchRefusal?>(nil)

    func set(_ refusal: AgentTaskResultLaunchRefusal?) { value.withLock { $0 = refusal } }

    func take() -> AgentTaskResultLaunchRefusal? {
        value.withLock { named -> AgentTaskResultLaunchRefusal? in
            defer { named = nil }
            return named
        }
    }
}

/// Explicit-user driver for the result-action value lifecycle. Constructing or
/// presenting it starts nothing. Only `launch` revalidates and may execute;
/// trying a result has no acceptance, Git, or publication side effect.
@MainActor
@Observable
final class AgentTaskResultActionDriver {
    private(set) var state: AgentTaskResultActionState
    private(set) var lastOutcome: UserTaskOutcome?

    @ObservationIgnored private let executor: any AgentTaskResultActionExecuting
    @ObservationIgnored private var activeAttempt: UUID?
    @ObservationIgnored private var cancellation: UserTaskCancellation?
    /// The runner reports a pre-spawn rejection as a bare fact; the refusal
    /// the spawn gate named is kept here so the failure states that reason.
    @ObservationIgnored private let preSpawnRefusal = PreSpawnRefusalBox()

    init(
        binding: AgentTaskResultActionBinding,
        executor: any AgentTaskResultActionExecuting = AgentTaskResultProcessExecutor()
    ) {
        state = AgentTaskResultActionState(binding: binding)
        self.executor = executor
    }

    func launch(
        revalidate: @escaping @Sendable (
            AgentTaskResultActionBinding
        ) async -> AgentTaskResultLaunchContext?
    ) {
        let next = state.reduced(by: .launchRequested)
        guard next.phase == .starting, next.attempts == state.attempts + 1 else { return }
        state = next
        lastOutcome = nil
        preSpawnRefusal.set(nil)
        let attempt = UUID()
        activeAttempt = attempt
        let binding = state.binding
        Task { @MainActor [weak self] in
            guard let self, self.activeAttempt == attempt else { return }
            guard let context = await revalidate(binding) else {
                self.refuse(.authorityChanged, attempt: attempt)
                return
            }
            guard context.binding == binding else {
                self.refuse(.bindingChanged, attempt: attempt)
                return
            }
            let refusal = await runOnBackground {
                context.validate(environment: ProcessInfo.processInfo.environment)
            }
            guard self.activeAttempt == attempt else { return }
            if let refusal {
                self.refuse(refusal, attempt: attempt)
                return
            }
            self.start(context: context, attempt: attempt)
        }
    }

    func stop() {
        switch state.phase {
        case .starting:
            if let cancellation {
                // False means completion already owns the terminal transition.
                guard cancellation.cancel() else { return }
                state = state.reduced(by: .stopRequested)
                // Keep attempt, handle, and ownership through final cleanup.
            } else {
                // No executor handle yet: no process cleanup can be outstanding.
                state = state.reduced(by: .cancelled)
                activeAttempt = nil
            }
        case .ready where state.ownership != nil,
             .stale where state.ownership != nil:
            state = state.reduced(by: .stopRequested)
            cancellation?.cancel()
        default:
            break
        }
    }

    /// A change during launch revokes that launch before spawn. A live result
    /// becomes stale and remains owned until the user explicitly stops it.
    func candidateChanged() {
        if state.phase == .starting {
            if let cancellation {
                guard cancellation.cancel() else { return }
                state = state.reduced(by: .stopRequested)
            } else {
                state = state.reduced(by: .cancelled)
                activeAttempt = nil
            }
        } else {
            state = state.reduced(by: .candidateChanged)
        }
    }

    /// Fresh binding only; stale snapshots are never relaunched. An old live
    /// process must first be stopped through its own scoped cancellation.
    @discardableResult
    func rebind(to binding: AgentTaskResultActionBinding) -> Bool {
        guard binding != state.binding, state.ownership == nil else { return false }
        switch state.phase {
        case .starting, .stopping:
            return false
        default:
            break
        }
        state = AgentTaskResultActionState(binding: binding)
        activeAttempt = nil
        cancellation = nil
        lastOutcome = nil
        return true
    }

    private func start(context: AgentTaskResultLaunchContext, attempt: UUID) {
        let preSpawnRefusal = preSpawnRefusal
        let handle = executor.execute(
            command: context.command,
            workingDirectory: context.workingDirectory,
            preSpawnValidation: { environment in
                if let refusal = context.validate(environment: environment) {
                    preSpawnRefusal.set(refusal)
                    throw AgentTaskResultLaunchRejection(refusal: refusal)
                }
            },
            processObserved: { [weak self] processID in
                Task { @MainActor [weak self] in
                    guard let self, self.activeAttempt == attempt,
                          self.state.phase == .starting else { return }
                    self.state = self.state.reduced(by: .processObserved(
                        processID: processID, processGroupID: processID
                    ))
                }
            },
            progress: UserTaskProgress(
                onFinish: { [weak self] outcome, cancelled in
                    Task { @MainActor [weak self] in
                        self?.finish(outcome, cancelled: cancelled, attempt: attempt)
                    }
                }
            )
        )
        guard activeAttempt == attempt else {
            handle.cancel()
            return
        }
        cancellation = handle
    }

    private func finish(
        _ outcome: UserTaskOutcome,
        cancelled: Bool,
        attempt: UUID
    ) {
        guard activeAttempt == attempt else { return }
        lastOutcome = outcome
        let handle = cancellation
        Task { @MainActor [weak self] in
            guard let self, self.activeAttempt == attempt else { return }
            // The runner's wait also covers deferred process-tree/pipe
            // ownership released after an incomplete first cleanup pass.
            let released = await runOnBackground {
                handle?.wait(until: .now() + 30) ?? true
            }
            guard released else { return } // fail closed: no relaunch/rebind
            self.applyFinished(outcome, cancelled: cancelled, attempt: attempt)
        }
    }

    private func applyFinished(
        _ outcome: UserTaskOutcome,
        cancelled: Bool,
        attempt: UUID
    ) {
        guard activeAttempt == attempt else { return }
        if outcome.preSpawnRejected {
            guard state.phase == .stopping else {
                // A rejection the runner raised on its own keeps the generic
                // authority reason.
                let refusal = preSpawnRefusal.take()
                refuse(refusal ?? .authorityChanged, attempt: attempt)
                return
            }
            // Cancellation already owns this launch: finish that transition
            // instead of emitting a refusal the stopping reducer cannot accept.
            state = state.reduced(by: .cancelled)
        } else {
            switch state.phase {
            case .starting where cancelled:
                state = state.reduced(by: .cancelled)
            case .starting:
                let exitCode = outcome.succeeded
                    ? 0 : (outcome.processExitCode == 0 ? -1 : outcome.processExitCode ?? -1)
                state = state.reduced(by: .processExited(exitCode))
            case .stopping where cancelled:
                state = state.reduced(by: .cancelled)
            case .stopping:
                state = state.reduced(by: .processExited(outcome.processExitCode ?? 0))
            case .ready, .stale:
                state = state.reduced(by: .processExited(outcome.processExitCode ?? -1))
            default:
                break
            }
        }
        activeAttempt = nil
        cancellation = nil
    }

    private func refuse(_ refusal: AgentTaskResultLaunchRefusal, attempt: UUID) {
        guard activeAttempt == attempt else { return }
        preSpawnRefusal.set(nil)
        state = state.reduced(by: .launchRefused(refusal))
        activeAttempt = nil
        cancellation = nil
    }
}
