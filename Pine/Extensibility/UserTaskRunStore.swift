//
//  UserTaskRunStore.swift
//  Pine
//
//  Task execution UI (issue #1246): a `@MainActor @Observable` store, owned
//  by the initiating `ProjectManager`, that tracks active and recent
//  user-task runs for a single project window. It is the single source of
//  truth for the task output surface and the success/failure toast.
//
//  The store only holds UI state; it never spawns processes. `UserTaskRunner`
//  reports progress and outcomes here, and `UserTaskRunPresenter` renders it.
//

import Foundation

#if DEBUG
nonisolated enum UserTaskResultCheckpoint {
    case recovered
    case recoveryDropped
    case preparing(UUID)
    case capturedPreparations(Set<UUID>)
    case beforeWrite(Set<UUID>)
}
#endif

/// Stable execution identities covered by one explicit shutdown decision.
/// A later run of the same configured task receives a new run ID and is not
/// covered by this authorization.
@MainActor
struct UserTaskExecutionAuthorization: Equatable {
    fileprivate let executionIDs: Set<UUID>
    fileprivate let launchGeneration: UUID?

    init(
        executionIDs: Set<UUID> = [],
        launchGeneration: UUID? = nil
    ) {
        self.executionIDs = executionIDs
        self.launchGeneration = launchGeneration
    }

    var requiresConfirmation: Bool { !executionIDs.isEmpty }
}

nonisolated private enum UserTaskCompletionWaiter {
    static func wait(
        for handles: [UserTaskCancellation],
        until deadline: DispatchTime
    ) async -> Bool {
        guard !handles.isEmpty else { return true }
        // `runOnBackground` gives the blocking waits an autorelease pool
        // (#1509) — the raw global-queue work item it replaces had none (#1548).
        return await runOnBackground(qos: .userInitiated) {
            var allCompleted = true
            for handle in handles where !handle.wait(until: deadline) {
                allCompleted = false
            }
            return allCompleted
        }
    }
}

/// Owns the active and recent task runs for one project window.
///
/// Capped to `maxRuns` to bound memory; the most-recent run is always
/// retained so the output surface can show the latest result. A run is kept
/// while active so the UI can show elapsed time and a Cancel button, then
/// transitions to a finished state in place.
@MainActor
@Observable
final class UserTaskRunStore {
    /// All tracked runs, newest-first. Active runs are kept at the front.
    private(set) var runs: [UserTaskRun] = []

    /// Maximum number of finished runs retained for the output history.
    static let maxRuns = 25
    /// Independent memory bound for retained UTF-8 stdout/stderr history.
    static let maxRetainedOutputBytes = 32 * 1_024 * 1_024

    /// Optional binding target the presenter watches to auto-expand the
    /// output surface when a new run starts or fails.
    var isOutputVisible: Bool = false

    /// Cancellation handles keyed by run id, so the UI's Cancel button can
    /// terminate the spawned process. A failed bounded cleanup retains its
    /// handle until the runner's deferred ownership cleanup resolves.
    private var cancellationHandles: [UUID: UserTaskCancellation] = [:]
    /// Cancel clicks received before the runner publishes its handle.
    private var pendingCancellationRunIDs: Set<UUID> = []
    /// Terminal outcomes whose subprocess/descriptor ownership has not yet
    /// been released. This also covers the short race before a late handle is
    /// published on the main queue.
    private var unresolvedCleanupRunIDs: Set<UUID> = []
    /// Changes for every accepted invocation and deliberately survives run
    /// cleanup, so a transient late execution cannot disappear between Quit
    /// authorization checks.
    private var launchGeneration: UUID?
    /// Changes whenever runner ownership publishes or replaces a handle.
    /// A wait cannot prepare a handle that changed while it was suspended.
    private var cancellationRegistrationGeneration: UUID?
    /// A successful wait is only the prepare phase of application-wide
    /// shutdown. History and execution ownership remain intact until every
    /// project store has prepared and the registry commits them together.
    private var preparedShutdownAuthorization:
        UserTaskExecutionAuthorization?
    private let maximumRuns: Int
    private let maximumRetainedOutputBytes: Int
    private let resultPersistence: UserTaskResultPersistence
    private(set) var resultProjectRoot: URL?
    private(set) var resultPersistenceFailed = false
    private var resultRootGeneration = UUID()
    private var resultGeneration: UInt64 = 0
    private var savedResultGeneration: UInt64 = 0
    private var resultSnapshot: UserTaskResultPersistence.Snapshot?
    private var attemptedResultRevision: UUID?
    private var resultRecords: [UUID: UserTaskResultRecord] = [:]
    private var removedResultIDs: Set<UUID> = []
    private var clearedResultsDuringLoad = false
    /// Set when reclamation destroys the owning manager.
    private var resultStoreReleased = false
    /// The project directory is gone; its durable target can never exist
    /// again for this workspace identity, so results are unrecoverable by design.
    private var resultRootMissing = false
    private var outputRetentionRunIDs: Set<UUID> = []
    private var pendingOutputRetentionIDs: Set<UUID> = []
    private var resultLoadTask: Task<Void, Never>?
    @ObservationIgnored private var resultWriteTask: Task<Void, Never>?
    @ObservationIgnored private var resultExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var resultPreparationTasks: [UUID: Task<Void, Never>] = [:]
    #if DEBUG
    @ObservationIgnored var resultCheckpointForTesting:
        (@MainActor (UserTaskResultCheckpoint) async -> Void)?
    #endif

    init(
        maximumRuns: Int = UserTaskRunStore.maxRuns,
        maximumRetainedOutputBytes: Int =
            UserTaskRunStore.maxRetainedOutputBytes,
        resultPersistence: UserTaskResultPersistence = UserTaskResultPersistence()
    ) {
        self.maximumRuns = max(maximumRuns, 0)
        self.maximumRetainedOutputBytes =
            max(maximumRetainedOutputBytes, 0)
        self.resultPersistence = resultPersistence
    }

    isolated deinit {
        resultExpiryTask?.cancel()
    }

    // MARK: - Recording

    /// Registers a new run and surfaces it immediately so the UI can show
    /// progress. Returns the run so the caller can drive its state.
    @discardableResult
    func start(_ run: UserTaskRun) -> UserTaskRun {
        preparedShutdownAuthorization = nil
        launchGeneration = UUID()
        runs.insert(run, at: 0)
        isOutputVisible = true
        trimToCapacity()
        return run
    }

    // MARK: - Cancellation

    /// Stores the cancellation handle for a run so the UI can cancel it.
    func registerCancellation(
        _ handle: UserTaskCancellation,
        forRunID id: UUID
    ) {
        preparedShutdownAuthorization = nil
        cancellationRegistrationGeneration = UUID()
        let cancellationWasPending =
            pendingCancellationRunIDs.remove(id) != nil
        if unresolvedCleanupRunIDs.contains(id) {
            cancellationHandles[id] = handle
            pruneResolvedCleanupOwnership()
            return
        }
        if cancellationWasPending {
            cancellationHandles[id] = handle
            guard let run = run(forID: id), run.state.isActive else {
                _ = handle.cancel()
                return
            }
            if handle.cancel() {
                run.markCancelling()
            }
            return
        }
        guard let run = run(forID: id), run.state.isActive else { return }
        cancellationHandles[id] = handle
    }

    /// Cancels an active run by id, terminating its process and updating the
    /// UI model. No-op for finished runs or unknown ids.
    func cancelRun(id: UUID) {
        guard let run = run(forID: id), run.state.isActive else { return }
        guard let handle = cancellationHandles[id] else {
            pendingCancellationRunIDs.insert(id)
            return
        }
        if handle.cancel() {
            run.markCancelling()
        }
    }

    /// Applies the terminal result and releases resolved execution ownership.
    ///
    /// A run cancelled before its handle arrived remains cancelled when the
    /// process later reports its concrete exit status and captured output.
    @discardableResult
    func finishRun(
        id: UUID,
        outcome: UserTaskOutcome,
        cancelled: Bool
    ) -> Bool {
        let run = run(forID: id)
        let ownsExecution =
            cancellationHandles[id] != nil
            || pendingCancellationRunIDs.contains(id)
            || unresolvedCleanupRunIDs.contains(id)
        let tracksExecution =
            run?.state.isActive == true || ownsExecution
        guard tracksExecution else { return false }

        pendingCancellationRunIDs.remove(id)
        if outcome.cleanupSucceeded {
            cancellationHandles.removeValue(forKey: id)
            unresolvedCleanupRunIDs.remove(id)
        } else {
            unresolvedCleanupRunIDs.insert(id)
        }

        guard let run else {
            pruneResolvedCleanupOwnership()
            return false
        }
        let cancellationWon = cancelled || run.state == .cancelling
        guard run.state.isActive else { return false }
        run.applyOutcome(outcome, cancelled: cancellationWon)
        prepareResult(run, outcome: outcome)
        if run.state == .failed || run.hasOutput {
            isOutputVisible = true
        }
        trimToCapacity()
        pruneResolvedCleanupOwnership()
        return true
    }

    // MARK: - Queries

    /// Runs that have not reached a terminal state.
    var activeRuns: [UserTaskRun] {
        runs.filter { $0.state.isActive }
    }

    /// `true` when at least one run is pending or running.
    var hasActiveRuns: Bool {
        runs.contains { $0.state.isActive }
    }

    /// The most recent run, if any.
    var mostRecentRun: UserTaskRun? {
        runs.first
    }

    /// Internal lifecycle observability used by unit tests.
    var cancellationHandleCount: Int {
        cancellationHandles.count
    }

    var pendingCancellationCount: Int {
        pendingCancellationRunIDs.count
    }

    var retainedOutputByteCount: Int {
        runs.lazy
            .filter { !$0.state.isActive }
            .reduce(into: 0) { total, run in
                total += run.retainedOutputBytes
            }
    }

    /// Finds a run by id.
    func run(forID id: UUID) -> UserTaskRun? {
        runs.first { $0.id == id }
    }

    // MARK: - Mutation

    /// Removes a finished run from the history (used by the output surface's
    /// Clear action). Active runs cannot be dismissed — cancel them first.
    func removeRun(id: UUID) {
        guard let run = run(forID: id), !run.state.isActive else { return }
        runs.removeAll { $0.id == id }
        removeResult(id: id)
        if !unresolvedCleanupRunIDs.contains(id) {
            cancellationHandles.removeValue(forKey: id)
            pendingCancellationRunIDs.remove(id)
        }
    }

    /// Clears all finished runs.
    func clearFinished() {
        // Clear also covers restored rows not yet delivered by the asynchronous load.
        clearedResultsDuringLoad = resultLoadTask != nil || resultSnapshot == nil
        for id in Array(resultPreparationTasks.keys) { removeResult(id: id) }
        for id in Array(resultRecords.keys) { removeResult(id: id) }
        resultsChanged()
        let finishedIDs = Set(
            runs.lazy.filter { !$0.state.isActive }.map { $0.id }
        )
        runs.removeAll { finishedIDs.contains($0.id) }
        cancellationHandles = cancellationHandles.filter {
            !finishedIDs.contains($0.key)
                || unresolvedCleanupRunIDs.contains($0.key)
        }
        pendingCancellationRunIDs.subtract(
            finishedIDs.subtracting(unresolvedCleanupRunIDs)
        )
    }

    /// Immediately clears UI history and requests active-process cancellation.
    /// Execution handles remain owned until their terminal callbacks resolve;
    /// project teardown should prefer ``shutdownAll(until:)`` so it can wait.
    ///
    /// Runs whose handle has not arrived remain in the pending-cancellation
    /// set so a late handle is terminated instead of becoming unreachable.
    func clearAll() {
        clearFinished()
        let activeIDs = Set(runs.lazy.filter { $0.state.isActive }.map { $0.id })
        for id in activeIDs {
            if let handle = cancellationHandles[id] {
                _ = handle.cancel()
            } else {
                pendingCancellationRunIDs.insert(id)
            }
        }
        runs.removeAll()
        outputRetentionRunIDs.removeAll()
    }

    /// Requests cancellation for every active run without waiting. Project
    /// shutdown calls this across all stores before it waits on any one store,
    /// ensuring the first TERM reaches every project promptly.
    func requestShutdown() {
        for run in runs
        where run.state.isActive && run.state != .cancelling {
            if let handle = cancellationHandles[run.id] {
                if handle.cancel() {
                    run.markCancelling()
                }
            } else {
                pendingCancellationRunIDs.insert(run.id)
            }
        }
    }

    /// Captures every execution for which this store still owns process or
    /// cleanup responsibility. This intentionally includes more than the
    /// visible active-run array.
    func captureShutdownAuthorization() -> UserTaskExecutionAuthorization {
        pruneResolvedCleanupOwnership()
        return UserTaskExecutionAuthorization(
            executionIDs: executionOwnershipRunIDs,
            launchGeneration: launchGeneration
        )
    }

    /// New execution ownership is never covered by an older user decision.
    func shutdownAuthorizationStillCovers(
        _ authorization: UserTaskExecutionAuthorization
    ) -> Bool {
        pruneResolvedCleanupOwnership()
        return launchGeneration == authorization.launchGeneration
            && executionOwnershipRunIDs.isSubset(
            of: authorization.executionIDs
        )
    }

    /// Requests cancellation only for executions named by the authorization.
    /// The all-or-nothing preflight prevents partial cancellation if any new
    /// execution appeared before this method reached the MainActor.
    @discardableResult
    func requestShutdown(
        authorizedBy authorization: UserTaskExecutionAuthorization
    ) -> Bool {
        preparedShutdownAuthorization = nil
        guard shutdownAuthorizationStillCovers(authorization) else {
            return false
        }
        for run in runs
        where authorization.executionIDs.contains(run.id)
            && run.state.isActive
            && run.state != .cancelling {
            if let handle = cancellationHandles[run.id] {
                if handle.cancel() {
                    run.markCancelling()
                }
            } else {
                pendingCancellationRunIDs.insert(run.id)
            }
        }
        return true
    }

    /// Waits only for the execution generations the user authorized. This is
    /// the prepare phase: a successful wait retains runs, output, and cleanup
    /// ownership until the caller commits after every owner has prepared. A
    /// new run appearing while the wait is suspended is left untouched and
    /// makes the shutdown fail closed.
    @discardableResult
    func waitForShutdown(
        authorizedBy authorization: UserTaskExecutionAuthorization,
        until deadline: DispatchTime
    ) async -> Bool {
        preparedShutdownAuthorization = nil
        pruneResolvedCleanupOwnership()
        let registrationGeneration = cancellationRegistrationGeneration
        let ownedAuthorizedIDs = executionOwnershipRunIDs.intersection(
            authorization.executionIDs
        )
        var handles: [UserTaskCancellation] = []
        var ownsEveryExecution = true

        for id in ownedAuthorizedIDs {
            if let handle = cancellationHandles[id] {
                handles.append(handle)
            } else {
                pendingCancellationRunIDs.insert(id)
                ownsEveryExecution = false
            }
        }
        let handlesCompleted = await UserTaskCompletionWaiter.wait(
            for: handles,
            until: deadline
        )
        let hasUnauthorizedExecution =
            launchGeneration != authorization.launchGeneration
            || cancellationRegistrationGeneration != registrationGeneration
            || !executionOwnershipRunIDs.isSubset(
                of: authorization.executionIDs
            )
        // Runner ownership can resolve before its MainActor result delivery.
        func awaitingResultDelivery() -> Bool {
            resultProjectRoot != nil && runs.contains {
                $0.state.isActive && authorization.executionIDs.contains($0.id)
            }
        }
        if !Task.isCancelled { retryFailedResultPersistence() }
        while ownsEveryExecution, handlesCompleted, !hasUnauthorizedExecution,
              hasUnpersistedResultOwnership || awaitingResultDelivery(),
              !Task.isCancelled, DispatchTime.now() < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        let resultsSaved = !hasUnpersistedResultOwnership && !awaitingResultDelivery()
        let allCompleted = ownsEveryExecution
            && handlesCompleted
            && !hasUnauthorizedExecution
            && resultsSaved
            && !Task.isCancelled
            && cancellationRegistrationGeneration == registrationGeneration
            && shutdownAuthorizationStillCovers(authorization)

        if allCompleted {
            preparedShutdownAuthorization = authorization
        }
        return allCompleted
    }

    /// Revalidates a successful prepare phase immediately before commit.
    /// Callers must perform this check for every store without suspension,
    /// then commit every prepared store without suspension.
    func shutdownIsPreparedForCommit(
        authorizedBy authorization: UserTaskExecutionAuthorization
    ) -> Bool {
        preparedShutdownAuthorization == authorization
            && shutdownAuthorizationStillCovers(authorization)
            && !hasUnpersistedResultOwnership
    }

    /// Commits a previously revalidated prepare phase. There must be no
    /// suspension between the all-owner preflight and this mutation.
    func commitPreparedShutdown(
        authorizedBy authorization: UserTaskExecutionAuthorization
    ) {
        precondition(preparedShutdownAuthorization == authorization)
        resultLoadTask?.cancel()
        resultExpiryTask?.cancel()
        runs.removeAll()
        cancellationHandles.removeAll()
        pendingCancellationRunIDs.removeAll()
        unresolvedCleanupRunIDs.removeAll()
        preparedShutdownAuthorization = nil
    }

    /// Cancels and waits for every active run using one shared absolute
    /// deadline.
    ///
    /// Cancellation ownership is snapshotted on the main actor, but the
    /// blocking process waits run on a background queue. This keeps project
    /// reopening and AppKit's asynchronous termination handshake responsive
    /// while the runner reaps direct children and finishes bounded cleanup.
    @discardableResult
    func shutdownAll(until deadline: DispatchTime) async -> Bool {
        let authorization = captureShutdownAuthorization()
        guard requestShutdown(authorizedBy: authorization) else {
            return false
        }
        guard await waitForShutdown(
            authorizedBy: authorization,
            until: deadline
        ), shutdownIsPreparedForCommit(authorizedBy: authorization) else {
            return false
        }
        commitPreparedShutdown(authorizedBy: authorization)
        return true
    }

    /// Whether teardown can release this store without dropping ownership of
    /// an active or not-yet-published task execution.
    var hasOutstandingExecutionOwnership: Bool {
        pruneResolvedCleanupOwnership()
        return hasActiveRuns
            || !cancellationHandles.isEmpty
            || !pendingCancellationRunIDs.isEmpty
            || !unresolvedCleanupRunIDs.isEmpty
    }

    // MARK: - Durable completed results

    var hasPendingResultPersistence: Bool {
        resultProjectRoot != nil && (
            resultLoadTask != nil || resultSnapshot == nil
                || resultWriteTask != nil || !resultPreparationTasks.isEmpty
                || !pendingOutputRetentionIDs.isEmpty
                || resultGeneration != savedResultGeneration
        )
    }

    /// An in-flight recovery load never retains: the manager may be reclaimed
    /// while it runs, and the abandoned load publishes nothing (the durable
    /// file stays intact and is pruned on next access). Failed read-only
    /// recovery has no sole copy to lose; accepted results and Clear always
    /// retain ownership.
    var hasUnpersistedResultOwnership: Bool {
        resultProjectRoot != nil && (
            resultGeneration != savedResultGeneration || resultWriteTask != nil
                || !resultPreparationTasks.isEmpty || !pendingOutputRetentionIDs.isEmpty
        )
    }

    /// Reclamation destroyed the owning manager. A still-running recovery
    /// must drop its result instead of publishing a write from an orphan.
    func abandonResultPersistence() {
        resultStoreReleased = true
    }

    /// Background reopen of a project directory that may have been deleted
    /// and recreated while backgrounded: the workspace identity (path,
    /// device, inode) can only have changed, so the stale snapshot and the
    /// missing-root state can never match the new root. Re-derive from disk,
    /// letting an in-flight write finish first so its save is not orphaned.
    func recoverRecreatedRoot() {
        guard resultProjectRoot != nil else { return }
        resultRootMissing = false
        attemptedResultRevision = nil
        let inFlightWrite = resultWriteTask
        resultSnapshot = nil
        guard inFlightWrite != nil else {
            loadResults()
            return
        }
        Task { [self] in
            _ = await inFlightWrite?.value
            guard resultProjectRoot != nil else { return }
            // A write straddling the delete→recreate gap can re-set the
            // missing-root flag after the reset above; re-assert for the
            // live root. If the root was deleted again, loadResults' own
            // rootMissing catch re-sets it.
            resultRootMissing = false
            attemptedResultRevision = nil
            loadResults()
        }
    }

    func canChangeResultRoot(to root: URL) -> Bool {
        resultProjectRoot == root || (!hasPendingResultPersistence && !hasOutstandingExecutionOwnership)
    }

    @discardableResult
    func updateResultRoot(_ root: URL) -> Bool {
        if resultProjectRoot == root { return true }
        guard canChangeResultRoot(to: root) else { return false }
        resultRootGeneration = UUID()
        resultProjectRoot = root
        resultSnapshot = nil
        attemptedResultRevision = nil
        resultRecords.removeAll()
        removedResultIDs.removeAll()
        clearedResultsDuringLoad = false
        resultGeneration = 0
        savedResultGeneration = 0
        resultRootMissing = false
        runs.removeAll()
        resultExpiryTask?.cancel()
        loadResults()
        return true
    }

    private func loadResults() {
        guard let root = resultProjectRoot, resultLoadTask == nil,
              !resultRootMissing else { return }
        let rootGeneration = resultRootGeneration
        resultLoadTask = Task { [self] in
            defer { resultLoadTask = nil }
            do {
                let loaded = try await resultPersistence.load(root: root)
                #if DEBUG
                await resultCheckpointForTesting?(.recovered)
                #endif
                guard !Task.isCancelled, rootGeneration == resultRootGeneration,
                      root == resultProjectRoot else { return }
                if resultStoreReleased {
                    // The manager is gone: publish nothing, keep the file intact.
                    #if DEBUG
                    await resultCheckpointForTesting?(.recoveryDropped)
                    #endif
                    return
                }
                resultSnapshot = loaded
                let retained = UserTaskResultRecord.retained(loaded.records, now: Date())
                if !clearedResultsDuringLoad {
                    for record in retained
                    where !removedResultIDs.contains(record.id) && resultRecords[record.id] == nil {
                        resultRecords[record.id] = record
                        if run(forID: record.id) == nil { runs.append(UserTaskRun(result: record)) }
                    }
                }
                removedResultIDs.removeAll()
                if loaded.records != retained { resultGeneration &+= 1 }
                resultPersistenceFailed = false
                trimToCapacity()
                scheduleResultExpiry()
                persistResults()
            } catch is UserTaskResultPersistence.Failure.rootMissing {
                // No directory, no durable file: nothing to restore or persist.
                resultRootMissing = true
            } catch {
                resultPersistenceFailed = true
            }
        }
    }

    private func prepareResult(_ run: UserTaskRun, outcome: UserTaskOutcome) {
        guard resultProjectRoot != nil, let finishedAt = run.finishedAt else { return }
        let id = run.id
        let rootGeneration = resultRootGeneration
        let command = run.command
        let taskID = run.taskID
        let startedAt = run.startedAt
        let state = run.state
        let retainOutput = outputRetentionRunIDs.contains(id)
        resultGeneration &+= 1
        resultPreparationTasks[id] = Task { [self] in
            #if DEBUG
            await resultCheckpointForTesting?(.preparing(id))
            #endif
            let record = await runOnBackground(qos: .utility) {
                UserTaskResultRecord(
                    id: id,
                    commandIdentity: UserTaskResultRecord.identity(command),
                    taskIdentity: UserTaskResultRecord.identity(taskID),
                    startedAt: startedAt, finishedAt: finishedAt,
                    state: state, exitCode: outcome.exitCode,
                    processExitCode: outcome.processExitCode,
                    outputCaptureSucceeded: outcome.outputCaptureSucceeded,
                    preSpawnRejected: outcome.preSpawnRejected,
                    timedOut: outcome.timedOut,
                    cleanupSucceeded: outcome.cleanupSucceeded,
                    standardInputCompleted: outcome.standardInputCompleted,
                    output: retainOutput ? .init(stdout: outcome.stdout, stderr: outcome.stderr) : nil
                )
            }
            guard !Task.isCancelled, rootGeneration == resultRootGeneration,
                  !removedResultIDs.contains(id) else { return }
            resultRecords[id] = record
            run.setRetainedOutput(record.output)
            if pendingOutputRetentionIDs.contains(id) { run.requestOutputRetention() }
            outputRetentionRunIDs.remove(id)
            resultPreparationTasks.removeValue(forKey: id)
            expireResults()
            // A writer may have captured admission without this prepared record.
            resultsChanged()
        }
    }

    /// This run only; execution consent never implies output-retention consent.
    func retainOutput(forRunID id: UUID) async {
        guard resultProjectRoot != nil, let run = run(forID: id),
              !run.outputRetentionRequested, !run.isRestoredResult else { return }
        if run.state.isActive {
            outputRetentionRunIDs.insert(id)
            run.requestOutputRetention()
            return
        }
        guard !pendingOutputRetentionIDs.contains(id),
              resultRecords[id] != nil || resultPreparationTasks[id] != nil else { return }
        pendingOutputRetentionIDs.insert(id)
        run.requestOutputRetention()
        resultGeneration &+= 1
        defer {
            pendingOutputRetentionIDs.remove(id)
            persistResults()
        }
        if let preparation = resultPreparationTasks[id] { await preparation.value }
        guard let record = resultRecords[id], record.expiresAt > Date(), record.output == nil else {
            run.setRetainedOutput(resultRecords[id]?.output)
            return
        }
        let rootGeneration = resultRootGeneration
        let stdout = run.stdout
        let stderr = run.stderr
        let output = await runOnBackground(qos: .utility) {
            UserTaskResultRecord.Output(stdout: stdout, stderr: stderr)
        }
        guard rootGeneration == resultRootGeneration, resultRecords[id] == record,
              var current = resultRecords[id], current.expiresAt > Date() else { return }
        current.output = output
        resultRecords[id] = current
        run.setRetainedOutput(output)
        resultsChanged()
    }

    private func removeResult(id: UUID) {
        guard resultProjectRoot != nil else { return }
        if resultLoadTask != nil || resultSnapshot == nil { removedResultIDs.insert(id) }
        resultPreparationTasks.removeValue(forKey: id)?.cancel()
        outputRetentionRunIDs.remove(id)
        pendingOutputRetentionIDs.remove(id)
        resultRecords.removeValue(forKey: id)
        resultsChanged()
    }

    private func resultsChanged() {
        guard resultProjectRoot != nil else { return }
        resultGeneration &+= 1
        persistResults()
    }

    private func expireResults() {
        let retained = UserTaskResultRecord.retained(Array(resultRecords.values), now: Date())
        let retainedIDs = Set(retained.map(\.id))
        let expired = Set(resultRecords.keys).subtracting(retainedIDs)
        for id in expired {
            resultRecords.removeValue(forKey: id)
            run(forID: id)?.setRetainedOutput(nil)
        }
        runs.removeAll { $0.isRestoredResult && expired.contains($0.id) }
        if !expired.isEmpty { resultGeneration &+= 1 }
        scheduleResultExpiry()
    }

    private func scheduleResultExpiry() {
        resultExpiryTask?.cancel()
        guard let next = resultRecords.values.map(\.expiresAt).min() else { return }
        resultExpiryTask = Task { [weak self] in
            do {
                let delay = min(UserTaskResultRecord.lifetime, max(0, next.timeIntervalSinceNow))
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            guard let self else { return }
            self.expireResults()
            self.persistResults()
        }
    }

    private func persistResults() {
        guard resultProjectRoot != nil, resultSnapshot != nil, !resultRootMissing,
              resultWriteTask == nil, pendingOutputRetentionIDs.isEmpty,
              resultGeneration != savedResultGeneration else { return }
        resultWriteTask = Task { [self] in
            defer { resultWriteTask = nil }
            while let root = resultProjectRoot, let previous = resultSnapshot {
                let preparations = Array(resultPreparationTasks)
                #if DEBUG
                await resultCheckpointForTesting?(.capturedPreparations(Set(preparations.map(\.key))))
                #endif
                for (_, preparation) in preparations { await preparation.value }
                guard pendingOutputRetentionIDs.isEmpty else { return }
                expireResults()
                let generation = resultGeneration
                let rootGeneration = resultRootGeneration
                let candidate = UserTaskResultPersistence.Snapshot(
                    version: 1, workspace: previous.workspace, revision: UUID(),
                    records: UserTaskResultRecord.retained(Array(resultRecords.values), now: Date())
                )
                let recoveryRevision = attemptedResultRevision
                #if DEBUG
                await resultCheckpointForTesting?(.beforeWrite(Set(candidate.records.map(\.id))))
                #endif
                do {
                    let saved = try await resultPersistence.save(
                        candidate, root: root, replacing: previous.revision,
                        recovering: recoveryRevision
                    )
                    guard root == resultProjectRoot, rootGeneration == resultRootGeneration else { return }
                    resultSnapshot = saved
                    attemptedResultRevision = nil
                    savedResultGeneration = generation
                    resultPersistenceFailed = false
                    if generation == resultGeneration { return }
                } catch {
                    if error is UserTaskResultPersistence.Failure.rootMissing {
                        // The project directory is gone: a recreated directory gets a
                        // new workspace identity, so this durable file can never be
                        // reached again. Drop the in-memory copy and release ownership
                        // instead of blocking reclamation and Quit.
                        resultRootMissing = true
                        resultRecords.removeAll()
                        resultSnapshot = nil
                        savedResultGeneration = resultGeneration
                        runs.removeAll { $0.isRestoredResult }
                        return
                    }
                    if let failure = error as? UserTaskResultPersistence.WriteFailure {
                        attemptedResultRevision = candidate.revision
                        resultSnapshot = UserTaskResultPersistence.Snapshot(
                            version: previous.version, workspace: previous.workspace,
                            revision: failure.observedRevision, records: previous.records
                        )
                    }
                    resultPersistenceFailed = true
                    return
                }
            }
        }
    }

    /// A result-bearing barrier, not a queue drain. Concurrent mutation fails closed.
    func flushResultPersistence() async -> Bool {
        guard resultProjectRoot != nil else { return true }
        guard !Task.isCancelled else { return false }
        if resultSnapshot == nil, resultLoadTask == nil, hasUnpersistedResultOwnership {
            loadResults()
        }
        if let load = resultLoadTask { await load.value }
        guard resultSnapshot != nil else { return false }
        for preparation in Array(resultPreparationTasks.values) { await preparation.value }
        while !pendingOutputRetentionIDs.isEmpty {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        guard !Task.isCancelled else { return false }
        expireResults()
        retryFailedResultPersistence()
        if let write = resultWriteTask { await write.value }
        return !hasPendingResultPersistence
    }

    // Fail-closed edge: a permanently unreadable result file (0o400/ACL/corrupt)
    // blocks reclamation/Quit until manually repaired (chmod or delete
    // <App Support>/Pine/CommandResults/<identity>.json). Never "fix" it by allowing overwrite.
    func retryFailedResultPersistence() {
        guard resultProjectRoot != nil else { return }
        if resultSnapshot == nil { loadResults() } else { persistResults() }
    }

    func canRetainOutput(forRunID id: UUID) -> Bool {
        guard resultProjectRoot != nil, let run = run(forID: id),
              !run.outputRetentionRequested, !run.isRestoredResult else { return false }
        if run.state.isActive { return true }
        if resultPreparationTasks[id] != nil { return run.hasOutput }
        guard run.hasOutput, let record = resultRecords[id] else { return false }
        return record.output == nil && record.expiresAt > Date()
    }

    // MARK: - Private

    private var executionOwnershipRunIDs: Set<UUID> {
        var ids = Set(runs.lazy
            .filter { $0.state.isActive }
            .map { $0.id })
        ids.formUnion(cancellationHandles.keys)
        ids.formUnion(pendingCancellationRunIDs)
        ids.formUnion(unresolvedCleanupRunIDs)
        return ids
    }

    /// Drops only cleanup handles whose runner-owned completion token is
    /// already resolved. The zero-deadline wait never blocks the main actor.
    private func pruneResolvedCleanupOwnership() {
        let resolvedIDs = unresolvedCleanupRunIDs.filter { id in
            guard let handle = cancellationHandles[id] else { return false }
            return handle.wait(until: .now())
        }
        guard !resolvedIDs.isEmpty else { return }
        unresolvedCleanupRunIDs.subtract(resolvedIDs)
        for id in resolvedIDs {
            cancellationHandles.removeValue(forKey: id)
        }
    }

    private func trimToCapacity() {
        // Never trim active runs. Remove oldest terminal runs until both the
        // count and retained-byte limits hold after every terminal transition.
        var finishedCount = runs.lazy.filter { !$0.state.isActive }.count
        var retainedBytes = retainedOutputByteCount
        var toDrop: Set<UUID> = []

        for run in runs.reversed() where !run.state.isActive {
            guard finishedCount > maximumRuns
                    || retainedBytes > maximumRetainedOutputBytes else {
                break
            }
            toDrop.insert(run.id)
            finishedCount -= 1
            retainedBytes -= run.retainedOutputBytes
        }
        guard !toDrop.isEmpty else { return }
        runs.removeAll { toDrop.contains($0.id) }
        cancellationHandles = cancellationHandles.filter {
            !toDrop.contains($0.key)
                || unresolvedCleanupRunIDs.contains($0.key)
        }
        pendingCancellationRunIDs.subtract(
            toDrop.subtracting(unresolvedCleanupRunIDs)
        )
    }
}
