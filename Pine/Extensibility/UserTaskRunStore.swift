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
    private var resultIOGeneration = UUID()
    private var resultGeneration: UInt64 = 0
    private var savedResultGeneration: UInt64 = 0
    private var resultWorkspace: UserTaskResultPersistence.Workspace?
    private var resultSnapshot: UserTaskResultPersistence.Snapshot?
    private var attemptedResultRevision: UUID?
    private var resultRecords: [UUID: UserTaskResultRecord] = [:]
    private var removedResultIDs: Set<UUID> = []
    private var clearedResultsDuringLoad = false
    private var discardedResultRunIDs: Set<UUID> = []
    private var nonDurableResultRunIDs: Set<UUID> = []
    /// Set when reclamation destroys the owning manager.
    private var resultStoreReleased = false
    /// The project directory is gone; its durable target can never exist
    /// again for this workspace identity, so results are unrecoverable by design.
    private var resultRootMissing = false
    private var outputRetentionRunIDs: Set<UUID> = []
    private var pendingOutputRetentionIDs: Set<UUID> = []
    private var resultLoadTask: Task<UserTaskResultPersistence.Workspace?, Never>?
    @ObservationIgnored private var resultWriteTask: Task<Void, Never>?
    @ObservationIgnored private var resultRecoveryTask: Task<Void, Never>?
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
        if resultRootMissing { recoverRecreatedRoot() }
        if resultWorkspace == nil || resultRecoveryTask != nil || resultRootMissing {
            nonDurableResultRunIDs.insert(run.id)
        }
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

        if discardedResultRunIDs.contains(id) {
            outputRetentionRunIDs.remove(id)
            pendingOutputRetentionIDs.remove(id)
            runs.removeAll { $0.id == id }
            discardedResultRunIDs.remove(id)
            return true
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
        let hasDurableResultState = resultPreparationTasks.keys.contains {
            !nonDurableResultRunIDs.contains($0)
        } || resultRecords.keys.contains { !nonDurableResultRunIDs.contains($0) }
            || runs.contains { !nonDurableResultRunIDs.contains($0.id) }
        let tracksDurableClear = nonDurableResultRunIDs.isEmpty || hasDurableResultState
            || resultLoadTask != nil || resultRecoveryTask != nil
            || resultSnapshot?.records.isEmpty == false
            || resultGeneration != savedResultGeneration
        // Clear also covers restored rows not yet delivered by the asynchronous load.
        if tracksDurableClear {
            clearedResultsDuringLoad = clearedResultsDuringLoad
                || resultLoadTask != nil || resultRecoveryTask != nil || resultSnapshot == nil
        }
        var clearedDurableResult = false
        for id in Array(resultPreparationTasks.keys) {
            clearedDurableResult = removeResult(id: id) || clearedDurableResult
        }
        for id in Array(resultRecords.keys) {
            clearedDurableResult = removeResult(id: id) || clearedDurableResult
        }
        if clearedDurableResult || (tracksDurableClear && clearedResultsDuringLoad) {
            resultsChanged()
        }
        let finishedIDs = Set(
            runs.lazy.filter { !$0.state.isActive }.map { $0.id }
        )
        nonDurableResultRunIDs.subtract(finishedIDs)
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
        nonDurableResultRunIDs.removeAll()
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
        resultRecoveryTask?.cancel()
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
        resultProjectRoot != nil && (resultRecoveryTask != nil || (!resultRootMissing && (
            resultLoadTask != nil || resultSnapshot == nil
                || resultWriteTask != nil || !resultPreparationTasks.isEmpty
                || !pendingOutputRetentionIDs.isEmpty
                || resultGeneration != savedResultGeneration
        )))
    }

    var hasNonDurableResults: Bool { !nonDurableResultRunIDs.isEmpty }

    /// Empty read-only recovery has no sole copy to lose. Accepted results, Clear,
    /// writes, and identity recovery with restored or still-loading results retain
    /// ownership until their durable state is known.
    var hasUnpersistedResultOwnership: Bool {
        resultProjectRoot != nil && (!nonDurableResultRunIDs.isEmpty
            || (resultRecoveryTask != nil && (resultLoadTask != nil || !resultRecords.isEmpty))
            || (!resultRootMissing && (
                resultGeneration != savedResultGeneration || resultWriteTask != nil
                    || !resultPreparationTasks.isEmpty || !pendingOutputRetentionIDs.isEmpty
            )))
    }

    /// Reclamation destroyed the owning manager. A still-running recovery
    /// must drop its result instead of publishing a write from an orphan.
    func abandonResultPersistence() {
        resultStoreReleased = true
    }

    /// Starts identity recovery synchronously so new runs and persistence
    /// barriers can await one fenced transition from the old workspace.
    func recoverRecreatedRoot() {
        guard let root = resultProjectRoot, resultRecoveryTask == nil else { return }
        let oldRunIDs = Set(runs.map(\.id))
        let preparations = Array(resultPreparationTasks.values)
        let retentionIDs = pendingOutputRetentionIDs
        let removedIDs = removedResultIDs
        let cleared = clearedResultsDuringLoad
        let generation = resultGeneration
        let rootGeneration = resultRootGeneration
        let previousWorkspace = resultWorkspace
        let ioGeneration = UUID()
        let load = resultLoadTask
        let write = resultWriteTask
        resultIOGeneration = ioGeneration
        load?.cancel()
        write?.cancel()
        attemptedResultRevision = nil
        resultSnapshot = nil
        resultRecoveryTask = Task { [self] in
            defer { resultRecoveryTask = nil }
            let loadWorkspace = await load?.value
            _ = await write?.value
            for preparation in preparations { await preparation.value }
            while !retentionIDs.isDisjoint(with: pendingOutputRetentionIDs) {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
            }
            do {
                let loaded = try await resultPersistence.load(root: root)
                #if DEBUG
                await resultCheckpointForTesting?(.recovered)
                #endif
                guard !Task.isCancelled, ioGeneration == resultIOGeneration,
                      rootGeneration == resultRootGeneration,
                      root == resultProjectRoot else { return }
                if resultStoreReleased {
                    #if DEBUG
                    await resultCheckpointForTesting?(.recoveryDropped)
                    #endif
                    return
                }
                installLoadedResults(
                    loaded, oldRunIDs: oldRunIDs, removedIDs: removedIDs,
                    cleared: cleared, generation: generation,
                    previousWorkspace: previousWorkspace ?? loadWorkspace
                )
                resultRootMissing = false
                resultPersistenceFailed = false
                resultRecoveryTask = nil
                trimToCapacity()
                scheduleResultExpiry()
                persistResults()
            } catch {
                guard !Task.isCancelled, ioGeneration == resultIOGeneration,
                      rootGeneration == resultRootGeneration,
                      root == resultProjectRoot else { return }
                if case UserTaskResultPersistence.Failure.rootMissing = error {
                    handleMissingResultRoot(oldRunIDs: oldRunIDs)
                } else {
                    resultPersistenceFailed = true
                }
            }
        }
    }

    func canChangeResultRoot(to root: URL) -> Bool {
        resultProjectRoot == root || (nonDurableResultRunIDs.isEmpty
            && !hasPendingResultPersistence && !hasOutstandingExecutionOwnership)
    }

    @discardableResult
    func updateResultRoot(_ root: URL) -> Bool {
        if resultProjectRoot == root { return true }
        guard canChangeResultRoot(to: root) else { return false }
        resultRootGeneration = UUID()
        resultIOGeneration = UUID()
        resultProjectRoot = root
        resultWorkspace = nil
        resultSnapshot = nil
        attemptedResultRevision = nil
        resultRecords.removeAll()
        removedResultIDs.removeAll()
        clearedResultsDuringLoad = false
        discardedResultRunIDs.removeAll()
        resultGeneration = 0
        savedResultGeneration = 0
        resultRootMissing = false
        runs.removeAll()
        outputRetentionRunIDs.removeAll()
        pendingOutputRetentionIDs.removeAll()
        resultExpiryTask?.cancel()
        loadResults()
        return true
    }

    private func loadResults() {
        guard let root = resultProjectRoot, resultLoadTask == nil,
              resultRecoveryTask == nil, !resultRootMissing else { return }
        let rootGeneration = resultRootGeneration
        let ioGeneration = resultIOGeneration
        let oldRunIDs = Set(runs.map(\.id))
        let removedIDs = removedResultIDs
        let cleared = clearedResultsDuringLoad
        let generation = resultGeneration
        resultLoadTask = Task { [self] in
            defer { resultLoadTask = nil }
            do {
                let loaded = try await resultPersistence.load(root: root)
                #if DEBUG
                await resultCheckpointForTesting?(.recovered)
                #endif
                guard !Task.isCancelled, ioGeneration == resultIOGeneration,
                      rootGeneration == resultRootGeneration,
                      root == resultProjectRoot else { return loaded.workspace }
                if resultStoreReleased {
                    // The manager is gone: publish nothing, keep the file intact.
                    #if DEBUG
                    await resultCheckpointForTesting?(.recoveryDropped)
                    #endif
                    return loaded.workspace
                }
                installLoadedResults(
                    loaded, oldRunIDs: oldRunIDs, removedIDs: removedIDs,
                    cleared: cleared, generation: generation
                )
                resultRootMissing = false
                resultPersistenceFailed = false
                trimToCapacity()
                scheduleResultExpiry()
                persistResults()
                return loaded.workspace
            } catch {
                guard !Task.isCancelled, ioGeneration == resultIOGeneration,
                      rootGeneration == resultRootGeneration,
                      root == resultProjectRoot else { return nil }
                if case UserTaskResultPersistence.Failure.rootMissing = error {
                    handleMissingResultRoot(oldRunIDs: oldRunIDs)
                } else {
                    resultPersistenceFailed = true
                }
                return nil
            }
        }
    }

    private func installLoadedResults(
        _ loaded: UserTaskResultPersistence.Snapshot,
        oldRunIDs: Set<UUID>, removedIDs: Set<UUID>, cleared: Bool,
        generation: UInt64,
        previousWorkspace: UserTaskResultPersistence.Workspace? = nil
    ) {
        let changedDuringLoad = resultGeneration != generation
        if let workspace = previousWorkspace ?? resultWorkspace, workspace != loaded.workspace {
            let duringLoadRemoved = removedResultIDs.subtracting(removedIDs)
            let duringLoadCleared = clearedResultsDuringLoad && !cleared
            resultRootGeneration = UUID()
            discardOldResultRuns(oldRunIDs)
            resultRecords = resultRecords.filter { nonDurableResultRunIDs.contains($0.key) }
            removedResultIDs = duringLoadRemoved
            clearedResultsDuringLoad = duringLoadCleared
            attemptedResultRevision = nil
            savedResultGeneration = changedDuringLoad ? generation : resultGeneration
        }
        resultWorkspace = loaded.workspace
        resultSnapshot = loaded
        let retained = UserTaskResultRecord.retained(loaded.records, now: Date())
        if !clearedResultsDuringLoad {
            for record in retained
            where !removedResultIDs.contains(record.id) && resultRecords[record.id] == nil {
                resultRecords[record.id] = record
                if run(forID: record.id) == nil { runs.append(UserTaskRun(result: record)) }
            }
        }
        if loaded.records != retained { resultGeneration &+= 1 }
    }

    private func discardOldResultRuns(_ oldRunIDs: Set<UUID>) {
        let discardedIDs = oldRunIDs.subtracting(nonDurableResultRunIDs)
        for run in runs where discardedIDs.contains(run.id) {
            run.setRetainedOutput(nil)
            if run.state.isActive { discardedResultRunIDs.insert(run.id) }
        }
        runs.removeAll { discardedIDs.contains($0.id) && !$0.state.isActive }
        outputRetentionRunIDs.subtract(discardedIDs)
        pendingOutputRetentionIDs.subtract(discardedIDs)
    }

    private func handleMissingResultRoot(oldRunIDs: Set<UUID>) {
        resultRootMissing = true
        resultRootGeneration = UUID()
        resultIOGeneration = UUID()
        resultLoadTask?.cancel()
        resultWriteTask?.cancel()
        for (id, preparation) in resultPreparationTasks
        where !nonDurableResultRunIDs.contains(id) {
            preparation.cancel()
        }
        resultRecords = resultRecords.filter { nonDurableResultRunIDs.contains($0.key) }
        resultSnapshot = nil
        attemptedResultRevision = nil
        removedResultIDs.removeAll()
        clearedResultsDuringLoad = false
        savedResultGeneration = resultGeneration
        outputRetentionRunIDs = outputRetentionRunIDs.filter { nonDurableResultRunIDs.contains($0) }
        pendingOutputRetentionIDs = pendingOutputRetentionIDs.filter { nonDurableResultRunIDs.contains($0) }
        discardOldResultRuns(oldRunIDs)
        for run in runs where !nonDurableResultRunIDs.contains(run.id) {
            run.setRetainedOutput(nil)
        }
        resultPersistenceFailed = false
        resultExpiryTask?.cancel()
    }

    private func prepareResult(_ run: UserTaskRun, outcome: UserTaskOutcome) {
        guard resultProjectRoot != nil, let finishedAt = run.finishedAt else { return }
        let id = run.id
        let nonDurable = nonDurableResultRunIDs.contains(id)
        let recovery = nonDurable ? nil : resultRecoveryTask
        let rootGeneration = nonDurable || recovery != nil ? nil : resultRootGeneration
        let command = run.command
        let taskID = run.taskID
        let startedAt = run.startedAt
        let state = run.state
        let retainOutput = outputRetentionRunIDs.contains(id)
        if !nonDurable { resultGeneration &+= 1 }
        resultPreparationTasks[id] = Task { [self] in
            defer { resultPreparationTasks.removeValue(forKey: id) }
            if let recovery { await recovery.value }
            let preparationRootGeneration = rootGeneration ?? resultRootGeneration
            guard !Task.isCancelled,
                  nonDurable || (preparationRootGeneration == resultRootGeneration
                    && !resultRootMissing),
                  !removedResultIDs.contains(id),
                  !discardedResultRunIDs.contains(id) else { return }
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
            guard !Task.isCancelled,
                  nonDurable || preparationRootGeneration == resultRootGeneration,
                  !removedResultIDs.contains(id), !discardedResultRunIDs.contains(id) else { return }
            resultRecords[id] = record
            run.setRetainedOutput(record.output)
            if pendingOutputRetentionIDs.contains(id) { run.requestOutputRetention() }
            outputRetentionRunIDs.remove(id)
            resultPreparationTasks.removeValue(forKey: id)
            expireResults()
            // A writer may have captured admission without this prepared record.
            if !nonDurable { resultsChanged() }
        }
    }

    /// This run only; execution consent never implies output-retention consent.
    func retainOutput(forRunID id: UUID) async {
        guard resultProjectRoot != nil, let run = run(forID: id),
              !run.outputRetentionRequested, !run.isRestoredResult,
              !discardedResultRunIDs.contains(id) else { return }
        if run.state.isActive {
            outputRetentionRunIDs.insert(id)
            run.requestOutputRetention()
            return
        }
        let nonDurable = nonDurableResultRunIDs.contains(id)
        guard !pendingOutputRetentionIDs.contains(id),
              resultRecords[id] != nil || resultPreparationTasks[id] != nil else { return }
        pendingOutputRetentionIDs.insert(id)
        run.requestOutputRetention()
        if !nonDurable { resultGeneration &+= 1 }
        defer {
            pendingOutputRetentionIDs.remove(id)
            if !nonDurable { persistResults() }
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
        guard nonDurable || rootGeneration == resultRootGeneration,
              resultRecords[id] == record,
              var current = resultRecords[id], current.expiresAt > Date() else { return }
        current.output = output
        resultRecords[id] = current
        run.setRetainedOutput(output)
        if !nonDurable { resultsChanged() }
    }

    @discardableResult
    private func removeResult(id: UUID) -> Bool {
        let nonDurable = nonDurableResultRunIDs.remove(id) != nil
        guard resultProjectRoot != nil else { return false }
        resultPreparationTasks.removeValue(forKey: id)?.cancel()
        outputRetentionRunIDs.remove(id)
        pendingOutputRetentionIDs.remove(id)
        resultRecords.removeValue(forKey: id)
        guard !nonDurable else { return false }
        removedResultIDs.insert(id)
        resultsChanged()
        return true
    }

    private func resultsChanged() {
        guard resultProjectRoot != nil else { return }
        resultGeneration &+= 1
        persistResults()
    }

    /// Quarantined records are exempt from expiry until explicit Clear; expiring
    /// their only copy would silently destroy results that could not be persisted.
    private func expireResults() {
        let durableRecords = resultRecords.values.filter { !nonDurableResultRunIDs.contains($0.id) }
        let retained = UserTaskResultRecord.retained(durableRecords, now: Date())
        let retainedIDs = Set(retained.map(\.id))
        let expired = Set(durableRecords.map(\.id)).subtracting(retainedIDs)
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
        let next = resultRecords.values
            .filter { !nonDurableResultRunIDs.contains($0.id) }
            .map(\.expiresAt).min()
        guard let next else { return }
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
              resultRecoveryTask == nil, resultWriteTask == nil,
              pendingOutputRetentionIDs.isEmpty,
              resultGeneration != savedResultGeneration else { return }
        let ioGeneration = resultIOGeneration
        resultWriteTask = Task { [self] in
            defer { resultWriteTask = nil }
            while let root = resultProjectRoot, let previous = resultSnapshot {
                let preparations = Array(resultPreparationTasks)
                #if DEBUG
                await resultCheckpointForTesting?(.capturedPreparations(Set(preparations.map(\.key))))
                #endif
                for (_, preparation) in preparations { await preparation.value }
                guard !Task.isCancelled, ioGeneration == resultIOGeneration,
                      pendingOutputRetentionIDs.isEmpty else { return }
                expireResults()
                let generation = resultGeneration
                let rootGeneration = resultRootGeneration
                let durableRecords = resultRecords.values.filter {
                    !nonDurableResultRunIDs.contains($0.id)
                }
                let candidate = UserTaskResultPersistence.Snapshot(
                    version: 1, workspace: previous.workspace, revision: UUID(),
                    records: UserTaskResultRecord.retained(durableRecords, now: Date())
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
                    guard !Task.isCancelled, ioGeneration == resultIOGeneration,
                          root == resultProjectRoot, rootGeneration == resultRootGeneration else { return }
                    resultWorkspace = saved.workspace
                    resultSnapshot = saved
                    attemptedResultRevision = nil
                    savedResultGeneration = generation
                    resultPersistenceFailed = false
                    if generation == resultGeneration {
                        removedResultIDs.removeAll()
                        clearedResultsDuringLoad = false
                        return
                    }
                } catch {
                    guard !Task.isCancelled, ioGeneration == resultIOGeneration,
                          root == resultProjectRoot, rootGeneration == resultRootGeneration else { return }
                    if case UserTaskResultPersistence.Failure.rootMissing = error {
                        handleMissingResultRoot(oldRunIDs: Set(runs.map(\.id)))
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
        if let recovery = resultRecoveryTask { await recovery.value }
        if resultRootMissing {
            recoverRecreatedRoot()
            if let recovery = resultRecoveryTask { await recovery.value }
        }
        guard !Task.isCancelled else { return false }
        if resultRootMissing { return !hasPendingResultPersistence && nonDurableResultRunIDs.isEmpty }
        if resultSnapshot == nil, resultLoadTask == nil { loadResults() }
        if let load = resultLoadTask { await load.value }
        if resultRootMissing {
            recoverRecreatedRoot()
            if let recovery = resultRecoveryTask { await recovery.value }
        }
        guard !Task.isCancelled else { return false }
        if resultRootMissing { return !hasPendingResultPersistence && nonDurableResultRunIDs.isEmpty }
        guard resultSnapshot != nil else { return false }
        for preparation in Array(resultPreparationTasks.values) { await preparation.value }
        while !pendingOutputRetentionIDs.isEmpty {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        guard !Task.isCancelled else { return false }
        expireResults()
        retryFailedResultPersistence()
        if let write = resultWriteTask { await write.value }
        return !hasPendingResultPersistence && nonDurableResultRunIDs.isEmpty
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
              !run.outputRetentionRequested, !run.isRestoredResult,
              !discardedResultRunIDs.contains(id) else { return false }
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
        // Never trim active runs. Quarantined results are exempt from count/output
        // trimming until explicit Clear: losing their only copy is worse than the
        // temporary memory growth. Remove oldest durable terminal runs instead.
        var finishedCount = runs.lazy.filter { !$0.state.isActive }.count
        var retainedBytes = retainedOutputByteCount
        var toDrop: Set<UUID> = []

        for run in runs.reversed() where !run.state.isActive
            && (resultProjectRoot == nil || !nonDurableResultRunIDs.contains(run.id)) {
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
