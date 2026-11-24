import Foundation
import Synchronization

/// Bounded, content-free journal in the existing task metadata transaction.
/// Output is deliberately omitted: arbitrary tool output cannot be reliably
/// redacted. Inspectable diagnostics are typed reasons and observed exit codes.
nonisolated struct AgentTaskCheckExecution: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case succeeded, failed, cancelled, timedOut, launchFailed
        case authorityChanged, identityChanged, identityUnavailable, outputUnavailable, cleanupFailed
    }
    struct Operation: Codable, Equatable, Sendable {
        let id: UUID
        let commandFingerprint: String
        let required: Bool
        let startedAt: Date
        let finishedAt: Date
        let status: Status
        let exitCode: Int32?
        let identitiesMatched: Bool
    }
    let id: UUID
    var scheme: UInt8 = 1
    let runID: UUID
    let processGeneration: UInt64
    let passID: UUID
    let attempt: Int
    let grantID: UUID
    let planFingerprint: String
    let requiredCommands: Set<String>
    let code: AgentTaskCodeStateIdentity
    let environment: AgentTaskEnvironmentIdentity
    var operations: [Operation] = []
    var completed = false

    var isJudgment: Bool {
        completed && !requiredCommands.isEmpty && requiredCommands.allSatisfy { command in
            operations.contains {
                $0.commandFingerprint == command && $0.required && $0.identitiesMatched
                    && ($0.status == .succeeded || $0.status == .failed)
            }
        }
    }

    var passed: Bool {
        isJudgment && requiredCommands.allSatisfy { command in
            operations.contains {
                $0.commandFingerprint == command && $0.required && $0.status == .succeeded
            }
        }
    }

    var problem: Status? {
        if !completed {
            return operations.last?.status == .succeeded ? nil : operations.last?.status
        }
        if passed { return nil }
        if isJudgment { return .failed }
        return operations.first(where: {
            $0.required && $0.status != .succeeded && $0.status != .failed
        })?.status ?? .identityUnavailable
    }

    func authorizes(_ fact: AgentTaskEvidenceFact) -> Bool {
        isJudgment && fact.checkExecutionID == id && fact.runID == runID
            && fact.processGeneration == processGeneration
            && fact.codeState == code && fact.environment == environment
            && fact.preOperationCodeState == code && fact.postOperationCodeState == code
            && fact.result == (passed ? .succeeded : .failed)
    }

    func isValid(for task: AgentTask) -> Bool {
        scheme == 1 && processGeneration > 0 && attempt > 0 && task.runs.contains {
            $0.id == runID && $0.process.processGeneration == processGeneration
        } && AgentTaskCheckPlan.validFingerprint(planFingerprint)
            && !requiredCommands.isEmpty && requiredCommands.count <= 32
            && requiredCommands.allSatisfy(AgentTaskCheckPlan.validFingerprint)
            && AgentTaskMetadataStore.validCodeState(code) && AgentTaskMetadataStore.validEnvironment(environment)
            && operations.count <= 32 && Set(operations.map(\.id)).count == operations.count
            && Set(operations.map(\.commandFingerprint)).count == operations.count
            && operations.allSatisfy {
                AgentTaskCheckPlan.validFingerprint($0.commandFingerprint)
                    && $0.startedAt.timeIntervalSince1970.isFinite && $0.finishedAt.timeIntervalSince1970.isFinite
                    && $0.finishedAt >= $0.startedAt
                    && $0.required == requiredCommands.contains($0.commandFingerprint)
                    && ($0.status != .succeeded || ($0.exitCode == 0 && $0.identitiesMatched))
            }
    }
}

extension AgentTaskCheckExecution {
    func observation(
        taskID: UUID, cancelled: Bool = false, authorityRevoked: Bool = false
    ) -> AgentTaskCheckObservation? {
        let results = operations.compactMap { operation -> AgentTaskCheckObservation.CommandResult? in
            guard let status = AgentTaskCheckObservation.Status(rawValue: operation.status.rawValue) else { return nil }
            return .init(
                operationID: operation.id, fingerprint: operation.commandFingerprint,
                required: operation.required, status: status
            )
        }
        guard results.count == operations.count else { return nil }
        return AgentTaskCheckObservation(
            taskID: taskID, runID: runID, passID: passID,
            executionID: id, planFingerprint: planFingerprint,
            processGeneration: processGeneration, journalCompleted: completed,
            cancelled: cancelled, authorityRevoked: authorityRevoked,
            results: results, preCodeState: code,
            postCodeState: isJudgment ? code : nil,
            environment: environment
        )
    }
}

/// Runtime-only revocable launch authority. Every registry mutation is observed
/// on the main actor; the pre-spawn gate checks this shared token off-main.
nonisolated final class AgentTaskCheckAuthority: Sendable {
    private struct State {
        var active = true
        var cancellation: UserTaskCancellation?
        var environment: [String: String]?
        var rejection: AgentTaskCheckExecution.Status?
        var revocation: AgentTaskCheckExecution.Status?
        var captureCancellation: GitCommandCancellationToken?
        var finished = false
        var shutdownConfirmed = false
    }
    private let state = Mutex(State())
    private let completion = DispatchGroup()
    init() { completion.enter() }
    func finish() {
        let first = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            return true
        }
        if first { completion.leave() }
    }
    func waitForShutdown(until deadline: DispatchTime) -> Bool {
        precondition(!Thread.isMainThread)
        revoke()
        guard completion.wait(timeout: deadline) == .success else { return false }
        let cancellation = state.withLock { $0.cancellation }
        guard cancellation?.wait(until: deadline) ?? true else { return false }
        state.withLock { $0.shutdownConfirmed = true }
        return true
    }
    var shutdownConfirmed: Bool { state.withLock { $0.shutdownConfirmed } }
    func check() throws {
        guard state.withLock({ $0.active }) else { throw CancellationError() }
    }
    func revoke(_ reason: AgentTaskCheckExecution.Status = .authorityChanged) {
        let resources = state.withLock {
            $0.active = false
            if $0.revocation == nil { $0.revocation = reason }
            return ($0.cancellation, $0.captureCancellation)
        }
        resources.0?.cancel()
        resources.1?.cancel()
    }
    func install(_ cancellation: UserTaskCancellation) {
        let active = state.withLock {
            $0.cancellation = cancellation
            $0.shutdownConfirmed = false
            return $0.active
        }
        if !active { cancellation.cancel() }
    }
    func observed(_ environment: [String: String]) { state.withLock { $0.environment = environment } }
    func beginOperation() {
        state.withLock { $0.environment = nil; $0.rejection = nil; $0.cancellation = nil }
    }
    func installCapture(_ cancellation: GitCommandCancellationToken) {
        let active = state.withLock { $0.captureCancellation = cancellation; return $0.active }
        if !active { cancellation.cancel() }
    }
    func reject(_ reason: AgentTaskCheckExecution.Status) { state.withLock { $0.rejection = reason } }
    var environment: [String: String]? { state.withLock { $0.environment } }
    var rejection: AgentTaskCheckExecution.Status? { state.withLock { $0.rejection } }
    var revocation: AgentTaskCheckExecution.Status? { state.withLock { $0.revocation } }
}

/// Explicit-action executor. Construction, restore and opening a result do
/// nothing. One sequential plan per task, at most four plans per owner.
@MainActor
final class AgentTaskCheckExecutor {
    enum Checkpoint: Sendable, Equatable {
        case invalidated, beforeCommand, operationRecorded, beforeFinalCapture, completedJournal
        case operationFinished, beforeCompletedJournalWrite
    }
    private let registry: AgentTaskRegistry
    private let bindings: AgentTaskEnvironmentBindings
    private var active: [UUID: AgentTaskCheckAuthority] = [:]
    private let checkpoint: @MainActor (Checkpoint) async -> Void
    private let runner: @Sendable (TimeInterval) -> UserTaskRunner
    private let captureAfterProcess: @Sendable (AgentVerificationIdentityCapture) async -> AgentVerificationIdentityCaptureResult
    private let progress: @Sendable (UserTaskProgress) -> UserTaskProgress

    init(
        registry: AgentTaskRegistry, bindings: AgentTaskEnvironmentBindings,
        checkpoint: @escaping @MainActor (Checkpoint) async -> Void = { _ in },
        runner: @escaping @Sendable (TimeInterval) -> UserTaskRunner = {
            UserTaskRunner(timeout: $0, logOutput: false, maximumConcurrentExecutions: 1)
        },
        captureAfterProcess: @escaping @Sendable (AgentVerificationIdentityCapture) async
            -> AgentVerificationIdentityCaptureResult = { await $0.capture() },
        progress: @escaping @Sendable (UserTaskProgress) -> UserTaskProgress = { $0 }
    ) {
        self.registry = registry
        self.bindings = bindings
        self.checkpoint = checkpoint
        self.runner = runner
        self.captureAfterProcess = captureAfterProcess
        self.progress = progress
    }

    func cancel(taskID: UUID) { active[taskID]?.revoke(.cancelled) }

    /// Call only from an explicit local approval action, never recipe import.
    func approve(
        taskID: UUID, plan: AgentTaskCheckPlan, environment: AgentTaskEnvironmentIdentity
    ) async -> Bool {
        guard plan.isValid, AgentTaskMetadataStore.validEnvironment(environment) else { return false }
        let grant = AgentTaskCheckGrant(
            scheme: 1, id: UUID(), taskID: taskID, planFingerprint: plan.fingerprint,
            environment: environment, approvedAt: Date(), revokedAt: nil
        )
        return await registry.persistCheckSelection(grant, taskID: taskID)
    }

    func revoke(taskID: UUID) async -> Bool {
        active[taskID]?.revoke()
        guard var grant = registry.task(for: taskID)?.checkGrant else { return false }
        grant.revokedAt = Date()
        return await registry.persistCheckSelection(grant, taskID: taskID)
    }

    // swiftlint:disable:next function_body_length
    func run(
        request: AgentTaskVerificationCheckRequest, plan: AgentTaskCheckPlan,
        binding: AgentTaskEnvironmentBinding, editor: AgentVerificationEditorPreflight
    ) async -> AgentTaskCheckObservation? {
        let taskID = request.taskID
        // Bare nils: #1725 derives the Needs decision from plan.isValid, the settled run,
        // checkGrant/checkProblem, and the registry's durable-work availability.
        guard plan.isValid, request.attempt > 0, binding.taskID == taskID,
              active[taskID] == nil, active.count < 4,
              let task = registry.task(for: taskID), let run = task.runs.last,
              run.id == request.runID, run.process.processGeneration == request.processGeneration,
              AgentTaskLifecycleReducer.isSettled(run),
              registry.verificationPassIsCurrent(request.passID, taskID: taskID),
              let grant = task.checkGrant,
              grant.matchesScope(taskID: taskID, plan: plan, environment: request.expected.environment),
              await registry.prepareDurableWork(in: task.project),
              registry.task(for: taskID)?.checkGrant == grant,
              registry.verificationPassIsCurrent(request.passID, taskID: taskID) else { return nil }
        // No await between the second admission check and owning the slot.
        guard active[taskID] == nil, active.count < 4 else { return nil }
        let authority = AgentTaskCheckAuthority()
        guard registry.claimCheckRun(taskID: taskID, owner: authority) else { authority.finish(); return nil }
        var cleanupUncertain = false
        active[taskID] = authority
        defer {
            authority.revoke()
            authority.finish()
            // Keep the bounded slot quarantined when ownership is unresolved.
            // A new plan must not accumulate another deferred process owner.
            if !cleanupUncertain { active.removeValue(forKey: taskID); registry.finishCheckRun(taskID: taskID) }
        }
        let observer = registry.addTaskChangeObserver { [registry] _, tasks in
            guard let current = tasks.first(where: { $0.id == taskID }),
                  current.runs.last?.id == run.id,
                  current.runs.last?.process.processGeneration == run.process.processGeneration,
                  current.lifecycle != .dismissed, current.checkGrant == grant,
                  registry.verificationPassIsCurrent(request.passID, taskID: taskID) else {
                authority.revoke()
                return
            }
        }
        defer { registry.removeTaskChangeObserver(observer) }
        func validateAuthority() throws {
            try binding.validateAuthority()
            try authority.check()
        }
        var observedJournal: AgentTaskCheckExecution?
        let result: AgentTaskCheckObservation? = await withTaskCancellationHandler {
            do {
                guard await registry.persistCheckSelection(grant, taskID: taskID, resettingExecution: true) else { return nil }
                await checkpoint(.invalidated)
                try validateAuthority()
                let lease = try await bindings.revalidate(binding)
                try validateAuthority()
                guard lease.identity.canonicalProjectPath == task.project.canonicalProjectPath else {
                    await registry.persistCheckProblem(.authorityChanged, taskID: taskID, runID: run.id, grantID: grant.id)
                    return nil
                }
                let inputs = AgentVerificationIdentityCapture.Inputs(
                    lease: lease, policy: plan.capturePolicy, editor: editor,
                    tools: Array(Set(plan.commands.map(\.executable))),
                    configurationFiles: plan.configurationFiles.sorted().map { lease.canonicalWorktree.appending(path: $0) }
                )
                let initialCancellation = GitCommandCancellationToken()
                authority.installCapture(initialCancellation)
                let initial = AgentVerificationIdentityCapture(
                    inputs: inputs, authorityIsCurrent: {
                        (try? binding.validateAuthority()) != nil && (try? authority.check()) != nil
                    }, cancellation: initialCancellation
                )
                let captured = await initial.capture()
                try validateAuthority()
                let snapshot: AgentVerificationIdentitySnapshot
                switch captured {
                case .current(let current) where current == request.expected && current.environment == grant.environment:
                    snapshot = current
                case .current, .changed:
                    await registry.persistCheckProblem(.identityChanged, taskID: taskID, runID: run.id, grantID: grant.id)
                    return nil
                case .cancelled:
                    authority.revoke(.cancelled)
                    await registry.persistCheckProblem(.cancelled, taskID: taskID, runID: run.id, grantID: grant.id)
                    return nil
                case .unavailable:
                    await registry.persistCheckProblem(.identityUnavailable, taskID: taskID, runID: run.id, grantID: grant.id)
                    return nil
                }
                try validateAuthority()
                var journal = AgentTaskCheckExecution(
                    id: UUID(), runID: run.id, processGeneration: run.process.processGeneration,
                    passID: request.passID, attempt: request.attempt, grantID: grant.id,
                    planFingerprint: plan.fingerprint, requiredCommands: Set(plan.commands.filter(\.required).map(\.fingerprint)),
                    code: snapshot.code, environment: snapshot.environment
                )
                observedJournal = journal
                guard await registry.persistCheckExecution(journal, taskID: taskID, replacing: nil) else { return nil }
                try validateAuthority()
                for command in plan.commands {
                    await checkpoint(.beforeCommand)
                    try validateAuthority()
                    let operationInputs = AgentTaskCheckOperationInputs(
                        operationID: UUID(), taskID: taskID, runID: journal.runID,
                        processGeneration: journal.processGeneration, binding: binding, grantID: journal.grantID,
                        plan: plan, commandID: command.id, expected: snapshot, capture: inputs
                    )
                    let operation = await execute(
                        command, journal: journal, operation: operationInputs, authority: authority
                    )
                    await checkpoint(.operationFinished)
                    journal.operations.append(operation)
                    observedJournal = journal
                    cleanupUncertain = operation.status == .cleanupFailed
                    if Task.isCancelled {
                        return journal.observation(
                            taskID: taskID, cancelled: Task.isCancelled || authority.revocation == .cancelled
                        )
                    }
                    guard await registry.persistCheckExecution(journal, taskID: taskID, replacing: journal.id) else { return nil }
                    await checkpoint(.operationRecorded)
                    try validateAuthority()
                    if cleanupUncertain {
                        return journal.observation(
                            taskID: taskID, cancelled: Task.isCancelled || authority.revocation == .cancelled
                        )
                    }
                    if [.cancelled, .authorityChanged, .identityChanged, .identityUnavailable].contains(operation.status) { break }
                }
                await checkpoint(.beforeFinalCapture)
                authority.installCapture(initialCancellation)
                let final = await initial.revalidate(snapshot)
                try validateAuthority()
                switch final {
                case .current:
                    break
                case .cancelled:
                    authority.revoke(.cancelled)
                    await registry.persistCheckProblem(.cancelled, taskID: taskID, runID: run.id, grantID: grant.id)
                    return journal.observation(taskID: taskID, cancelled: true, authorityRevoked: true)
                case .changed:
                    await registry.persistCheckProblem(.identityChanged, taskID: taskID, runID: run.id, grantID: grant.id)
                    return journal.observation(taskID: taskID)
                case .unavailable:
                    await registry.persistCheckProblem(.identityUnavailable, taskID: taskID, runID: run.id, grantID: grant.id)
                    return journal.observation(taskID: taskID)
                }
                journal.completed = true
                observedJournal = journal
                await checkpoint(.beforeCompletedJournalWrite)
                try validateAuthority()
                guard await registry.persistCheckExecution(journal, taskID: taskID, replacing: journal.id) else { return nil }
                await checkpoint(.completedJournal)
                try validateAuthority()
                guard journal.operations.count == plan.commands.count,
                      journal.operations.allSatisfy(\.identitiesMatched) else {
                    return journal.observation(taskID: taskID, cancelled: Task.isCancelled || authority.revocation == .cancelled,
                            authorityRevoked: authority.revocation != nil)
                }
                // The coordinator alone records aggregate evidence and Ready.
                return journal.observation(taskID: taskID, cancelled: Task.isCancelled || authority.revocation == .cancelled,
                            authorityRevoked: authority.revocation != nil)
            } catch {
                if !Task.isCancelled {
                    await registry.persistCheckProblem(
                        authority.revocation ?? .authorityChanged, taskID: taskID, runID: run.id, grantID: grant.id
                    )
                }
                return registry.task(for: taskID)?.checkExecution?.observation(
                    taskID: taskID, cancelled: Task.isCancelled || authority.revocation == .cancelled,
                    authorityRevoked: authority.revocation != nil
                )
            }
        } onCancel: {
            authority.revoke(.cancelled)
        }
        if Task.isCancelled {
            await persistCancellation(observedJournal, taskID: taskID, runID: run.id, grant: grant, authority: authority)
        }
        let persisted = registry.task(for: taskID)?.checkExecution?
            .observation(taskID: taskID, cancelled: Task.isCancelled || authority.revocation == .cancelled,
                            authorityRevoked: authority.revocation != nil)
        if Task.isCancelled || authority.revocation != nil {
            return persisted ?? .blocked(
                request: request, planFingerprint: plan.fingerprint,
                cancelled: Task.isCancelled || authority.revocation == .cancelled,
                authorityRevoked: authority.revocation != nil
            )
        }
        return result
    }

    private func persistCancellation(
        _ observed: AgentTaskCheckExecution?, taskID: UUID, runID: UUID,
        grant: AgentTaskCheckGrant, authority: AgentTaskCheckAuthority
    ) async {
        authority.revoke(.cancelled)
        if var pending = observed, !pending.completed,
           let previous = registry.task(for: taskID)?.checkExecution, !previous.completed,
           previous.id == pending.id, previous.operations.count + 1 == pending.operations.count,
           previous.operations == Array(pending.operations.dropLast()), let operation = pending.operations.last {
            pending.operations[pending.operations.count - 1] = .init(
                id: operation.id, commandFingerprint: operation.commandFingerprint, required: operation.required,
                startedAt: operation.startedAt, finishedAt: operation.finishedAt,
                status: operation.status == .cleanupFailed ? .cleanupFailed : .cancelled,
                exitCode: operation.exitCode, identitiesMatched: false
            )
            _ = await registry.persistCancelledCheckOperation(pending, taskID: taskID, owner: authority)
        }
        _ = await registry.persistCancelledCheckProblem(
            taskID: taskID, runID: runID, grant: grant, executionID: observed?.id, owner: authority
        )
    }

    // swiftlint:disable:next function_body_length
    private func execute(
        _ command: AgentTaskCheckCommand, journal: AgentTaskCheckExecution,
        operation: AgentTaskCheckOperationInputs, authority: AgentTaskCheckAuthority
    ) async -> AgentTaskCheckExecution.Operation {
        let operationID = operation.operationID
        let binding = operation.binding
        let inputs = operation.capture
        let started = AgentTaskEvidenceEventIdentity.quantizeToMilliseconds(Date())
        let cancellation = GitCommandCancellationToken()
        authority.beginOperation()
        authority.installCapture(cancellation)
        let runner = runner(command.timeout)
        let cwd = command.workingDirectory.isEmpty ? inputs.lease.canonicalWorktree
            : inputs.lease.canonicalWorktree.appending(path: command.workingDirectory)
        let completion = Mutex(false)
        let result: (UserTaskOutcome, Bool) = await withCheckedContinuation { continuation in
            let handle = runner.run(
                taskID: operationID.uuidString, executableURL: command.executable, arguments: command.arguments,
                workingDirectory: cwd,
                preSpawnValidation: { environment in
                    try authority.check()
                    try binding.validateAuthority()
                    guard cwd.resolvingSymlinksInPath().path == cwd.path,
                          (try? cwd.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                        authority.reject(.authorityChanged)
                        throw CancellationError()
                    }
                    let capture = try AgentVerificationIdentityCapture.forCheckOperation(
                        operation, environmentValues: environment, cancellation: cancellation
                    )
                    switch capture.captureSynchronously() {
                    case .current(let observed) where observed.code == journal.code && observed.environment == journal.environment:
                        authority.observed(environment)
                    case .changed, .current:
                        authority.reject(.identityChanged)
                        throw CancellationError()
                    default:
                        authority.reject(.identityUnavailable)
                        throw CancellationError()
                    }
                    try binding.validateAuthority()
                    try authority.check()
                    guard cwd.resolvingSymlinksInPath().path == cwd.path else { throw CancellationError() }
                },
                progress: progress(UserTaskProgress(onFinish: { outcome, cancelled in
                    let first = completion.withLock { value in
                        if value { return false }
                        value = true
                        return true
                    }
                    if first { continuation.resume(returning: (outcome, cancelled)) }
                }))
            )
            authority.install(handle)
        }
        var status = Self.classify(result.0, cancelled: result.1)
        var identitiesMatched = false
        if let revocation = authority.revocation {
            status = revocation
        } else if let rejection = authority.rejection {
            status = rejection
        } else if let environment = authority.environment {
            let capture = try? AgentVerificationIdentityCapture.forCheckOperation(
                operation, environmentValues: environment, cancellation: cancellation
            )
            let observed: AgentVerificationIdentityCaptureResult
            if let capture {
                observed = await captureAfterProcess(capture)
            } else {
                observed = .unavailable(.unavailableBinding)
            }
            switch observed {
            case .current(let observed) where observed.code == journal.code && observed.environment == journal.environment:
                do {
                    try binding.validateAuthority()
                    try authority.check()
                    identitiesMatched = true
                } catch { status = .authorityChanged }
            case .changed, .current: status = .identityChanged
            default: status = .identityUnavailable
            }
        }
        if let revocation = authority.revocation {
            status = revocation
            identitiesMatched = false
        }
        if !result.0.cleanupSucceeded { status = .cleanupFailed; identitiesMatched = false }
        return .init(
            id: operationID, commandFingerprint: command.fingerprint, required: command.required,
            startedAt: started, finishedAt: AgentTaskEvidenceEventIdentity.quantizeToMilliseconds(Date()),
            status: status, exitCode: result.0.processExitCode,
            identitiesMatched: identitiesMatched
        )
    }

    nonisolated static func classify(_ outcome: UserTaskOutcome, cancelled: Bool) -> AgentTaskCheckExecution.Status {
        if cancelled { return .cancelled }
        if outcome.timedOut { return .timedOut }
        if outcome.preSpawnRejected { return .authorityChanged }
        if !outcome.cleanupSucceeded { return .cleanupFailed }
        if outcome.processExitCode == nil { return .launchFailed }
        if !outcome.outputCaptureSucceeded { return .outputUnavailable }
        return outcome.succeeded ? .succeeded : .failed
    }
}
