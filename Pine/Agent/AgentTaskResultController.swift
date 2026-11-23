import Foundation
import Observation
import Synchronization

nonisolated private final class AgentTaskResultGrantStore: Sendable {
    private let state = Mutex<AgentTaskCheckGrant?>(nil)
    var current: AgentTaskCheckGrant? { state.withLock { $0 } }
    func set(_ grant: AgentTaskCheckGrant) { state.withLock { $0 = grant } }
    func clear() { state.withLock { $0 = nil } }
}

/// Production task/result composition for the existing Agent Inbox. Opening
/// creates no recipe selection, grant, process, acceptance, or Git authority.
@MainActor
@Observable
final class AgentTaskResultController {
    private struct TaskSignature: Equatable {
        let runID: UUID?
        let outcome: AgentTaskOutcome?
        let processGeneration: UInt64?
        let verification: AgentTaskVerificationState
        let evidence: [AgentTaskEvidenceFact]
        let environment: AgentTaskEnvironmentIdentity?
        let candidateGeneration: UInt64
        let reviewCycle: AgentTaskCorrectionCycle?
        let lifecycle: AgentTaskLifecycle
        let nativeDispatch: AgentTaskNativeDispatch?

        init(_ task: AgentTask) {
            let run = task.runs.last
            runID = run?.id
            outcome = run?.outcome
            processGeneration = run?.process.processGeneration
            verification = task.verificationState
            evidence = task.evidence
            environment = task.environment
            candidateGeneration = task.candidateGeneration
            reviewCycle = task.reviewCycle
            lifecycle = task.lifecycle
            nativeDispatch = task.nativeDispatch
        }
    }

    private let registry: AgentTaskRegistry
    private let editorPreflight: () -> AgentVerificationEditorPreflight
    private let executor: any AgentTaskResultActionExecuting
    private let grant = AgentTaskResultGrantStore()
    private var task: AgentTask
    private var taskSignature: TaskSignature
    private var observerToken: UUID?
    private var snapshot: AgentVerificationIdentitySnapshot?
    private var selection: AgentProjectRecipe.Selected?
    private var selectionOperation = UUID()
    private var preparationOperation = UUID()
    private var preparationTask: Task<Void, Never>?
    private var preparationCancellation: UserTaskCancellation?

    private(set) var proposal: AgentProjectRecipe?
    private(set) var preparation: AgentProjectPreparation?
    private(set) var driver: AgentTaskResultActionDriver?

    var presentation: AgentTaskResultPresentation {
        AgentTaskResultPresentation(
            task: task, codeState: snapshot?.code, environment: snapshot?.environment,
            action: driver?.state, preparation: preparation,
            preparationIsRunning: preparationTask != nil,
            lastOutcome: driver?.lastOutcome
        )
    }

    init?(
        registry: AgentTaskRegistry,
        taskID: UUID,
        editorPreflight: @escaping () -> AgentVerificationEditorPreflight,
        executor: any AgentTaskResultActionExecuting = AgentTaskResultProcessExecutor(),
        initialDriver: AgentTaskResultActionDriver? = nil
    ) {
        guard let task = registry.task(for: taskID) else { return nil }
        self.registry = registry
        self.task = task
        self.editorPreflight = editorPreflight
        self.executor = executor
        taskSignature = TaskSignature(task)
        if let initialDriver, initialDriver.state.binding.taskID == taskID,
           initialDriver.state.binding.project == task.project {
            driver = initialDriver
            snapshot = initialDriver.state.binding.snapshot
            selection = nil
        }
        observerToken = registry.addTaskChangeObserver { [weak self] _, tasks in
            self?.observe(tasks)
        }
        Task { @MainActor [weak self] in await self?.discoverRecipe() }
    }

    isolated deinit {
        if let observerToken { registry.removeTaskChangeObserver(observerToken) }
        grant.clear()
        preparationTask?.cancel()
        preparationCancellation?.cancel()
        driver?.stop()
        driver = nil
    }

    /// Explicit recipe selection and identity capture; never a command grant.
    func selectRecipe() {
        guard let proposal else { return }
        let operation = UUID()
        selectionOperation = operation
        Task { @MainActor [weak self] in
            guard let self, self.selectionOperation == operation else { return }
            do {
                guard let owner = self.registry.resultActionOwnership(for: self.taskID) else {
                    return
                }
                try await owner.validateOperation()
                let result = await self.capture(owner: owner, recipe: proposal).capture()
                guard self.selectionOperation == operation,
                      case .current(let snapshot) = result else { return }
                let selection = try AgentProjectRecipe.select(
                    projectCheckedIn: proposal, for: self.task.project
                )
                guard let binding = AgentTaskResultActionBinding(
                    task: self.task, selection: selection,
                    actionID: "run-example", snapshot: snapshot
                ) else { return }
                if let driver = self.driver, driver.state.binding != binding {
                    guard driver.rebind(to: binding) else { return }
                } else if self.driver == nil {
                    self.driver = AgentTaskResultActionDriver(
                        binding: binding, executor: self.executor
                    )
                }
                self.selection = selection
                self.snapshot = snapshot
                self.preparation = AgentProjectPreparation(recipe: proposal)
            } catch {
                return
            }
        }
    }

    /// Explicit setup command authorization and bounded execution.
    func prepareResult() {
        guard let selection, let snapshot, var preparation,
              !preparation.isUsable else { return }
        if preparation.phase == .failed {
            preparation = preparation.reduced(by: .retryRequested)
        }
        guard preparation.phase == .preparing else { return }
        self.preparation = preparation
        issueGrant(plan: selection.plan, snapshot: snapshot)
        let operation = UUID()
        preparationOperation = operation
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for prerequisite in selection.recipe.prerequisites {
                if self.preparation?.resolvedPrerequisites.contains(prerequisite.name) == true {
                    continue
                }
                let available = await runOnBackground {
                    FileManager.default.isExecutableFile(atPath: prerequisite.executable.path)
                }
                guard available else {
                    self.failPreparation(.prerequisiteUnavailable(prerequisite.name), operation: operation)
                    return
                }
                self.applyPreparation(
                    .prerequisiteResolved(prerequisite.name), operation: operation
                )
            }
            for command in selection.recipe.setup {
                if self.preparation?.completedActions.contains(command.id) == true {
                    continue
                }
                guard self.preparationOperation == operation, !Task.isCancelled else { return }
                guard let owner = self.registry.resultActionOwnership(for: self.taskID) else {
                    self.cancelPreparation()
                    return
                }
                do {
                    try await owner.validateOperation()
                } catch {
                    self.cancelPreparation()
                    return
                }
                guard let authority = self.authority(
                    owner: owner, selection: selection, snapshot: snapshot
                ) else {
                    self.cancelPreparation()
                    return
                }
                let outcome = await self.executeSetup(
                    command: command, authority: authority, operation: operation
                )
                guard self.preparationOperation == operation, !Task.isCancelled else { return }
                if outcome.succeeded {
                    self.applyPreparation(.setupSucceeded(command.id), operation: operation)
                } else {
                    self.failPreparation(.setupFailed(command.id), operation: operation)
                    return
                }
            }
            self.preparationTask = nil
            self.preparationCancellation = nil
        }
    }

    func cancelPreparation() {
        if let preparationCancellation {
            guard preparationCancellation.cancel() else { return }
        }
        preparationOperation = UUID()
        preparationTask?.cancel()
        preparation = preparation?.reduced(by: .cancelled)
        preparationTask = nil
        preparationCancellation = nil
        grant.clear()
    }

    /// Distinct result launch. The driver calls the closure before execution,
    /// and the authority recaptures identity again inside the spawn gate.
    func launchResult() {
        guard let driver, let selection, let preparation else { return }
        if grant.current == nil {
            issueGrant(plan: selection.plan, snapshot: driver.state.binding.snapshot)
        }
        driver.launch { [weak self] binding in
            guard let self else { return nil }
            guard let owner = await self.registry.resultActionOwnership(for: self.taskID) else {
                return nil
            }
            do {
                try await owner.validateOperation()
            } catch {
                return nil
            }
            guard let authority = await self.authority(
                owner: owner, selection: selection, snapshot: binding.snapshot
            ) else { return nil }
            return AgentTaskResultLaunchContext.make(
                binding: binding, selection: selection,
                preparation: preparation, authority: authority
            )
        }
    }

    func stopResult() {
        driver?.stop()
    }

    /// Ends UI ownership of this result. The runner retains its own bounded
    /// cleanup after stop; no live result command stays available without an
    /// owning controller.
    func close() {
        selectionOperation = UUID()
        cancelPreparation()
        grant.clear()
        driver?.stop()
        driver = nil
        snapshot = nil
        selection = nil
        preparation = nil
        proposal = nil
        if let observerToken {
            registry.removeTaskChangeObserver(observerToken)
            self.observerToken = nil
        }
    }

    private var taskID: UUID { task.id }

    private func observe(_ tasks: [AgentTask]) {
        guard let current = tasks.first(where: { $0.id == taskID }) else {
            close()
            return
        }
        let signature = TaskSignature(current)
        task = current
        guard signature != taskSignature else { return }
        taskSignature = signature
        selectionOperation = UUID()
        snapshot = nil
        grant.clear()
        cancelPreparation()
        if current.lifecycle == .dismissed || current.nativeDispatch?.phase == .unavailable {
            close()
        } else {
            driver?.candidateChanged()
        }
    }

    private func issueGrant(
        plan: AgentTaskCheckPlan,
        snapshot: AgentVerificationIdentitySnapshot
    ) {
        let value = AgentTaskCheckGrant(
            scheme: AgentTaskCheckGrant.currentScheme,
            id: UUID(), taskID: taskID, planFingerprint: plan.fingerprint,
            environment: snapshot.environment, approvedAt: Date(), revokedAt: nil
        )
        grant.set(value)
    }

    private func applyPreparation(
        _ event: AgentProjectPreparation.Event,
        operation: UUID
    ) {
        guard preparationOperation == operation, let current = preparation else { return }
        preparation = current.reduced(by: event)
    }

    private func failPreparation(
        _ event: AgentProjectPreparation.Event,
        operation: UUID
    ) {
        applyPreparation(event, operation: operation)
        preparationOperation = UUID()
        preparationTask = nil
        preparationCancellation = nil
        grant.clear()
    }

    private func executeSetup(
        command: AgentTaskCheckCommand,
        authority: AgentTaskResultCommandAuthority,
        operation: UUID
    ) async -> UserTaskOutcome {
        let cancellation = Mutex<UserTaskCancellation?>(nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let handle = executor.execute(
                    command: command,
                    workingDirectory: workingDirectory(for: command),
                    preSpawnValidation: { environment in
                        if let refusal = authority.validate(environment: environment) {
                            throw AgentTaskResultLaunchRejection(refusal: refusal)
                        }
                    },
                    processObserved: { _ in },
                    progress: UserTaskProgress(onFinish: { outcome, _ in
                        continuation.resume(returning: outcome)
                    })
                )
                cancellation.withLock { $0 = handle }
                if preparationOperation == operation {
                    preparationCancellation = handle
                } else {
                    handle.cancel()
                }
            }
        } onCancel: {
            cancellation.withLock { $0 }?.cancel()
        }
    }

    private func workingDirectory(for command: AgentTaskCheckCommand) -> URL {
        let root = URL(
            fileURLWithPath: task.project.canonicalWorktreePath, isDirectory: true
        )
        guard !command.workingDirectory.isEmpty else { return root }
        return root.appendingPathComponent(command.workingDirectory, isDirectory: true)
    }

    private func authority(
        owner: AgentTaskNativeOwnership,
        selection: AgentProjectRecipe.Selected,
        snapshot: AgentVerificationIdentitySnapshot
    ) -> AgentTaskResultCommandAuthority? {
        guard owner.binding.taskID == taskID,
              owner.binding.identity == task.project else { return nil }
        let capture = capture(owner: owner, recipe: selection.recipe)
        let registry = registry
        let taskID = taskID
        let grant = grant
        return AgentTaskResultCommandAuthority(
            taskID: taskID, project: task.project,
            plan: selection.plan, expected: snapshot,
            currentGrant: { grant.current },
            currentReadiness: { current in
                precondition(!Thread.isMainThread)
                return DispatchQueue.main.sync {
                    registry.readiness(
                        for: taskID, codeState: current.code,
                        environment: current.environment
                    )
                }
            },
            captureIdentity: { environment in
                precondition(!Thread.isMainThread)
                var exact = capture
                exact.environmentValues = { environment }
                return exact.captureSynchronously()
            },
            environmentIsCurrent: {
                guard (try? owner.validateSelection()) != nil else { return false }
                return owner.filesystem.revalidate()
                    && owner.filesystem.identity == owner.binding.identity
            }
        )
    }

    private func capture(
        owner: AgentTaskNativeOwnership,
        recipe: AgentProjectRecipe
    ) -> AgentVerificationIdentityCapture {
        let root = owner.filesystem.canonicalWorktree
        let tools = Set(
            recipe.prerequisites.map(\.executable)
                + recipe.setup.map(\.executable)
                + recipe.checks.commands.map(\.executable)
                + recipe.results.map(\.command.executable)
        ).sorted { $0.path < $1.path }
        let inputs = AgentVerificationIdentityCapture.Inputs(
            lease: owner.filesystem, policy: recipe.checks.capturePolicy,
            editor: editorPreflight(), tools: tools,
            configurationFiles: recipe.checks.configurationFiles.sorted().map {
                root.appending(path: $0)
            }
        )
        var capture = AgentVerificationIdentityCapture(
            inputs: inputs, cancellation: GitCommandCancellationToken()
        )
        capture.authorityIsCurrent = {
            (try? owner.validateSelection()) != nil
        }
        return capture
    }

    private func discoverRecipe() async {
        let root = URL(fileURLWithPath: task.project.canonicalWorktreePath)
        let operation = selectionOperation
        let files = await runOnBackground {
            var recognized = Set<String>()
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                return recognized
            }
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > 20_000 { break }
                let relative = url.path.dropFirst(root.path.count + 1)
                if url.lastPathComponent == ".git" || url.lastPathComponent == ".build" {
                    enumerator.skipDescendants()
                    continue
                }
                let path = String(relative)
                if path == "Package.swift" || path == "Package.resolved"
                        || path.hasPrefix("Tests/") || path.hasPrefix("Sources/") {
                    recognized.insert(path)
                }
            }
            return recognized
        }
        guard operation == selectionOperation else { return }
        proposal = AgentProjectRecipe.propose(recognizedFiles: files, for: task.project)
    }
}
