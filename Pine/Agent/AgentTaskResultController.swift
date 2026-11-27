import Foundation
import Observation
import Synchronization

typealias AgentTaskResultReplyDispatcher = @MainActor (
    String, AgentTaskReviewDecision
) async -> Bool

typealias AgentTaskResultCommandAuthorityProvider = @MainActor (
    AgentProjectRecipe.Selected, AgentVerificationIdentitySnapshot
) -> AgentTaskResultCommandAuthority?

/// Re-proves the current identity of an opened result. Production captures
/// it with the #1753 primitives; nil means no proof was attempted.
typealias AgentTaskResultIdentityResolver = @MainActor (
    AgentTask
) async -> AgentVerificationIdentityCaptureResult?

/// The text of a review finding, supplied by the surface that received the
/// verdict; the task record keeps only an opaque reference.
typealias AgentTaskResultFindingProvider = @MainActor (AgentTaskReviewDecision) -> String?

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
    private let commandAuthority: AgentTaskResultCommandAuthorityProvider?
    private let replyDispatcher: AgentTaskResultReplyDispatcher?
    /// nil in production, where the #1753 capture re-proves the identity.
    private let identityResolver: AgentTaskResultIdentityResolver?
    private let findingProvider: AgentTaskResultFindingProvider?
    private let grant = AgentTaskResultGrantStore()
    private var task: AgentTask
    private var taskSignature: TaskSignature
    private var observerToken: UUID?
    private var snapshot: AgentVerificationIdentitySnapshot?
    /// Why the identity on open could not be proven; nil once it is.
    private(set) var identityGap: AgentTaskResultIdentityGap?
    private var selection: AgentProjectRecipe.Selected? {
        didSet { registry.updateResultActionSelection(selection, for: taskID) }
    }
    private var selectionOperation = UUID()
    private var preparationOperation = UUID()
    private var preparationTask: Task<Void, Never>?
    private var preparationCancellation: UserTaskCancellation?
    private var replyInFlight = false

    private(set) var replyDeliveryFailed = false
    private(set) var proposal: AgentProjectRecipe?
    private(set) var preparation: AgentProjectPreparation? {
        didSet { registry.updateResultActionPreparation(preparation, for: taskID) }
    }
    private(set) var driver: AgentTaskResultActionDriver?

    var presentation: AgentTaskResultPresentation {
        AgentTaskResultPresentation(
            task: task, codeState: snapshot?.code, environment: snapshot?.environment,
            identityGap: snapshot == nil ? identityGap : nil,
            action: driver?.state, preparation: preparation,
            preparationIsRunning: preparationTask != nil,
            lastOutcome: driver?.lastOutcome,
            findingText: AgentTaskReviewOrchestrator.decisionRequest(for: task)
                .flatMap { findingProvider?($0) },
            replyInFlight: replyInFlight, replyDeliveryFailed: replyDeliveryFailed
        )
    }

    init?(
        registry: AgentTaskRegistry,
        taskID: UUID,
        editorPreflight: @escaping () -> AgentVerificationEditorPreflight,
        executor: any AgentTaskResultActionExecuting = AgentTaskResultProcessExecutor(),
        initialDriver: AgentTaskResultActionDriver? = nil,
        initialSelection: AgentProjectRecipe.Selected? = nil,
        commandAuthority: AgentTaskResultCommandAuthorityProvider? = nil,
        replyDispatcher: AgentTaskResultReplyDispatcher? = nil,
        identityResolver: AgentTaskResultIdentityResolver? = nil,
        findingProvider: AgentTaskResultFindingProvider? = nil
    ) {
        guard let task = registry.task(for: taskID) else { return nil }
        self.registry = registry
        self.task = task
        self.editorPreflight = editorPreflight
        self.executor = executor
        self.commandAuthority = commandAuthority
        self.replyDispatcher = replyDispatcher
        self.findingProvider = findingProvider
        self.identityResolver = identityResolver
        snapshot = AgentTaskReviewOrchestrator.decisionRequest(for: task).map {
            AgentVerificationIdentitySnapshot(
                code: $0.candidateCodeState, environment: $0.candidateEnvironment
            )
        }
        taskSignature = TaskSignature(task)
        if let initialDriver, initialDriver.state.binding.taskID == taskID,
           initialDriver.state.binding.project == task.project {
            driver = registry.retainResultActionDriver(initialDriver)
        } else {
            driver = registry.resultActionDriver(for: taskID)
        }
        if let driver {
            snapshot = driver.state.binding.snapshot
            selection = registry.resultActionSelection(for: taskID)
            preparation = registry.resultActionPreparation(for: taskID)
            if let initialSelection,
               initialSelection.recipe.fingerprint == driver.state.binding.recipeFingerprint {
                selection = initialSelection
                preparation = AgentProjectPreparation(recipe: initialSelection.recipe)
                registry.updateResultActionSelection(initialSelection, for: taskID)
                registry.updateResultActionPreparation(preparation, for: taskID)
            }
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
        guard let proposal,
              !registry.resultPreparationExecutionIsPending(for: taskID) else { return }
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
                let driver = self.driver ?? self.registry.resultActionDriver(for: self.taskID)
                    ?? self.registry.retainResultActionDriver(AgentTaskResultActionDriver(
                        binding: binding, executor: self.executor
                    ))
                if driver.state.binding != binding {
                    guard driver.rebind(to: binding) else { return }
                }
                self.driver = driver
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
              preparationTask == nil,
              !registry.resultPreparationExecutionIsPending(for: taskID),
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
                let authority: AgentTaskResultCommandAuthority?
                if let commandAuthority = self.commandAuthority {
                    authority = commandAuthority(selection, snapshot)
                } else {
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
                    authority = self.authority(
                        owner: owner, selection: selection, snapshot: snapshot
                    )
                }
                guard let authority else {
                    self.cancelPreparation()
                    return
                }
                guard let outcome = await self.executeSetup(
                    command: command, authority: authority, operation: operation
                ) else {
                    self.cancelPreparation()
                    return
                }
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
        guard let driver, let selection, let preparation,
              !registry.resultPreparationExecutionIsPending(for: taskID) else { return }
        if grant.current == nil {
            issueGrant(plan: selection.plan, snapshot: driver.state.binding.snapshot)
        }
        let commandAuthority = commandAuthority
        driver.launch { [weak self] binding in
            guard let self else { return nil }
            if let commandAuthority {
                guard let authority = await commandAuthority(selection, binding.snapshot) else {
                    return nil
                }
                return AgentTaskResultLaunchContext.make(
                    binding: binding, selection: selection,
                    preparation: preparation, authority: authority
                )
            }
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

    /// Durably records the current decision reply before one same-session
    /// dispatch. Failure remains a visible pending revision, never a success.
    func reply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !replyInFlight,
              let decision = presentation.decision,
              let replyDispatcher else { return }
        replyDeliveryFailed = false
        replyInFlight = true
        let reference = AgentHistoryContentHash.sha256Hex(Data(trimmed.utf8))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.registry.recordResultDecisionReply(
                decision, feedbackReference: reference
            )
            guard let outcome else {
                self.replyDeliveryFailed = true
                self.replyInFlight = false
                return
            }
            if case .rejected = outcome {
                self.replyDeliveryFailed = true
                self.replyInFlight = false
                return
            }
            let delivered = await replyDispatcher(trimmed, decision)
            self.replyDeliveryFailed = !delivered
            self.replyInFlight = false
        }
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
        identityGap = nil
        // Selection and preparation stay with the registry-owned driver so a
        // production reopen resumes the same launch/preparation controls.
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
        let decisionSnapshot = AgentTaskReviewOrchestrator.decisionRequest(for: current).map {
            AgentVerificationIdentitySnapshot(
                code: $0.candidateCodeState, environment: $0.candidateEnvironment
            )
        }
        if snapshot != decisionSnapshot { snapshot = nil }
        identityGap = nil
        grant.clear()
        cancelPreparation()
        if current.lifecycle == .dismissed || current.nativeDispatch?.phase == .unavailable {
            close()
        } else {
            driver?.candidateChanged()
            Task { @MainActor [weak self] in await self?.establishIdentity() }
        }
    }

    /// Ready needs a Pine-observed identity that the bound evidence
    /// matches. Opening re-proves it; selecting a recipe is no
    /// precondition, and no snapshot is ever assumed.
    private func establishIdentity() async {
        let current = task
        guard snapshot == nil, current.verificationState == .verified,
              let run = current.runs.last, AgentTaskLifecycleReducer.isSettled(run),
              run.outcome == .success else { return }
        let operation = selectionOperation
        let result: AgentVerificationIdentityCaptureResult?
        if let identityResolver {
            result = await identityResolver(current)
        } else {
            result = await captureCurrentIdentity(current)
        }
        guard operation == selectionOperation, !Task.isCancelled else { return }
        switch result {
        case .current(let captured):
            snapshot = captured
            identityGap = nil
        case .unavailable(.unsavedEditorChanges):
            identityGap = .unsavedEditorChanges
        case nil, .changed, .cancelled, .unavailable:
            identityGap = .unproven
        }
    }

    /// Re-proves the current identity with the #1753 capture over the same
    /// inputs the recorded checks ran under. Opening selects no recipe: the
    /// recognized recipe only supplies those inputs, and only while its
    /// plan is the recorded one — another plan yields an environment
    /// identity that is not comparable with the evidence.
    private func captureCurrentIdentity(
        _ current: AgentTask
    ) async -> AgentVerificationIdentityCaptureResult? {
        guard let owner = registry.resultActionOwnership(for: taskID),
              let proposal, (try? owner.validateSelection()) != nil,
              let plan = Self.recordedPlan(proposal, for: current) else { return nil }
        let root = owner.filesystem.canonicalWorktree
        var capture = AgentVerificationIdentityCapture(
            inputs: AgentVerificationIdentityCapture.Inputs(
                lease: owner.filesystem, policy: plan.capturePolicy,
                editor: editorPreflight(), tools: Array(Set(plan.commands.map(\.executable))),
                configurationFiles: plan.configurationFiles.sorted().map {
                    root.appending(path: $0)
                }
            ),
            cancellation: GitCommandCancellationToken()
        )
        capture.authorityIsCurrent = {
            (try? owner.validateSelection()) != nil
        }
        return await capture.capture()
    }

    /// The plan the recorded checks ran under, rebuilt from the recognized
    /// recipe; nil when the recipe does not reproduce it. Built directly:
    /// the selection APIs are reserved for an explicit user choice.
    nonisolated private static func recordedPlan(
        _ recipe: AgentProjectRecipe, for task: AgentTask
    ) -> AgentTaskCheckPlan? {
        let plan = AgentTaskCheckPlan(
            scheme: AgentTaskCheckPlan.currentScheme,
            recipeFingerprint: recipe.checks.fingerprint,
            commands: recipe.checks.commands,
            capturePolicy: recipe.checks.capturePolicy,
            configurationFiles: recipe.checks.configurationFiles
        )
        let recorded = [task.checkGrant?.planFingerprint, task.checkExecution?.planFingerprint]
        return plan.isValid && recorded.contains(plan.fingerprint) ? plan : nil
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
    ) async -> UserTaskOutcome? {
        guard let executionID = registry.beginResultPreparationExecution(for: taskID) else {
            return nil
        }
        let cancellation = Mutex<UserTaskCancellation?>(nil)
        let outcome = await withTaskCancellationHandler {
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
                if registry.registerResultPreparationCancellation(
                    for: taskID, executionID: executionID, handle: handle
                ), preparationOperation == operation {
                    preparationCancellation = handle
                } else {
                    handle.cancel()
                }
            }
        } onCancel: {
            cancellation.withLock { $0 }?.cancel()
        }
        guard await registry.finishResultPreparationExecution(
            for: taskID, executionID: executionID
        ) else { return nil }
        return outcome
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
        let rootName = root.lastPathComponent
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
                if url.lastPathComponent == ".git" || url.lastPathComponent == ".build" {
                    enumerator.skipDescendants()
                    continue
                }
                // The enumerator reports the base with its symlinks resolved
                // (/var … becomes /private/var …), so a literal prefix strip
                // corrupts every relative path. Anchor on the base directory's
                // own component instead; a same-named ancestor merely fails
                // recognition, it never misattributes anything.
                let components = url.pathComponents
                guard let base = components.firstIndex(of: rootName),
                      base + 1 < components.count else { continue }
                let path = components[(base + 1)...].joined(separator: "/")
                if path == "Package.swift" || path == "Package.resolved"
                        || path.hasPrefix("Tests/") || path.hasPrefix("Sources/") {
                    recognized.insert(path)
                }
            }
            return recognized
        }
        guard operation == selectionOperation else { return }
        proposal = AgentProjectRecipe.propose(recognizedFiles: files, for: task.project)
        await establishIdentity()
    }
}
