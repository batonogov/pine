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
    /// terminate the spawned process. Cleared when a run finishes.
    private var cancellationHandles: [UUID: UserTaskCancellation] = [:]
    /// Cancel clicks received before the runner publishes its handle.
    private var pendingCancellationRunIDs: Set<UUID> = []
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
        if pendingCancellationRunIDs.remove(id) != nil {
            guard let run = run(forID: id), run.state.isActive else {
                _ = handle.cancel()
                return
            }
            cancellationHandles[id] = handle
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

    /// Applies the terminal result and releases its cancellation handle.
    ///
    /// A run cancelled before its handle arrived remains cancelled when the
    /// process later reports its concrete exit status and captured output.
    @discardableResult
    func finishRun(
        id: UUID,
        outcome: UserTaskOutcome,
        cancelled: Bool
    ) -> Bool {
        cancellationHandles.removeValue(forKey: id)
        pendingCancellationRunIDs.remove(id)
        guard let run = run(forID: id) else { return false }
        let cancellationWon = cancelled || run.state == .cancelling
        guard run.state.isActive else { return false }
        run.applyOutcome(
            stdout: outcome.stdout,
            stderr: outcome.stderr,
            exitCode: outcome.exitCode,
            timedOut: outcome.timedOut,
            cancelled: cancellationWon,
            cleanupSucceeded: outcome.cleanupSucceeded,
            standardInputCompleted: outcome.standardInputCompleted,
            retainedOutputBytes: outcome.retainedOutputBytes
        )
        if run.state == .failed || run.hasOutput {
            isOutputVisible = true
        }
        trimToCapacity()
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
        cancellationHandles.removeValue(forKey: id)
        pendingCancellationRunIDs.remove(id)
    }

    /// Clears all finished runs.
    func clearFinished() {
        let finishedIDs = Set(
            runs.lazy.filter { !$0.state.isActive }.map { $0.id }
        )
        runs.removeAll { finishedIDs.contains($0.id) }
        cancellationHandles = cancellationHandles.filter {
            !finishedIDs.contains($0.key)
        }
        pendingCancellationRunIDs.subtract(finishedIDs)
    }

    /// Immediately clears every run and requests active-process cancellation.
    /// Project teardown should prefer ``shutdownAll(until:)`` so it can wait.
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
        cancellationHandles.removeAll()
    }

    /// Requests cancellation for every active run without waiting. Project
    /// shutdown calls this across all stores before it waits on any one store,
    /// ensuring the first TERM reaches every project promptly.
    func requestShutdown() {
        for run in runs where run.state.isActive {
            if let handle = cancellationHandles[run.id] {
                if handle.cancel() {
                    run.markCancelling()
                }
            } else {
                pendingCancellationRunIDs.insert(run.id)
            }
        }
    }

    /// Cancels and waits for every active run using one shared absolute
    /// deadline. Runner completion is published before its main-thread finish
    /// callback, so this bounded wait cannot deadlock the main actor.
    @discardableResult
    func shutdownAll(until deadline: DispatchTime) -> Bool {
        requestShutdown()
        let activeIDs = Array(runs.lazy
            .filter { $0.state.isActive }
            .map { $0.id })
        var handles: [UserTaskCancellation] = []
        var allCompleted = true

        for id in activeIDs {
            if let handle = cancellationHandles[id] {
                handles.append(handle)
            } else {
                pendingCancellationRunIDs.insert(id)
                allCompleted = false
            }
        }
        for handle in handles where !handle.wait(until: deadline) {
            allCompleted = false
        }

        if allCompleted {
            runs.removeAll()
            cancellationHandles.removeAll()
            pendingCancellationRunIDs.removeAll()
        }
        return allCompleted
    }

    // MARK: - Private

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
        }
        pendingCancellationRunIDs.subtract(toDrop)
    }
}
