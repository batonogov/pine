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
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var allCompleted = true
                for handle in handles where !handle.wait(until: deadline) {
                    allCompleted = false
                }
                continuation.resume(returning: allCompleted)
            }
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
    private let maximumRuns: Int
    private let maximumRetainedOutputBytes: Int

    init(
        maximumRuns: Int = UserTaskRunStore.maxRuns,
        maximumRetainedOutputBytes: Int =
            UserTaskRunStore.maxRetainedOutputBytes
    ) {
        self.maximumRuns = max(maximumRuns, 0)
        self.maximumRetainedOutputBytes =
            max(maximumRetainedOutputBytes, 0)
    }

    // MARK: - Recording

    /// Registers a new run and surfaces it immediately so the UI can show
    /// progress. Returns the run so the caller can drive its state.
    @discardableResult
    func start(_ run: UserTaskRun) -> UserTaskRun {
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
        if !unresolvedCleanupRunIDs.contains(id) {
            cancellationHandles.removeValue(forKey: id)
            pendingCancellationRunIDs.remove(id)
        }
    }

    /// Clears all finished runs.
    func clearFinished() {
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
        let activeIDs = Set(runs.lazy.filter { $0.state.isActive }.map { $0.id })
        for id in activeIDs {
            if let handle = cancellationHandles[id] {
                _ = handle.cancel()
            } else {
                pendingCancellationRunIDs.insert(id)
            }
        }
        runs.removeAll()
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

    /// Waits only for the execution generations the user authorized. A new
    /// run appearing while the wait is suspended is left untouched and makes
    /// the shutdown fail closed.
    @discardableResult
    func waitForShutdown(
        authorizedBy authorization: UserTaskExecutionAuthorization,
        until deadline: DispatchTime
    ) async -> Bool {
        pruneResolvedCleanupOwnership()
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
            || !executionOwnershipRunIDs.isSubset(
                of: authorization.executionIDs
            )
        let allCompleted = ownsEveryExecution
            && handlesCompleted
            && !hasUnauthorizedExecution

        if allCompleted {
            runs.removeAll()
            cancellationHandles.removeAll()
            pendingCancellationRunIDs.removeAll()
            unresolvedCleanupRunIDs.removeAll()
        }
        return allCompleted
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
        return await waitForShutdown(
            authorizedBy: authorization,
            until: deadline
        )
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
