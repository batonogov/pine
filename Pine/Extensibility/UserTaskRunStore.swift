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

    /// Optional binding target the presenter watches to auto-expand the
    /// output surface when a new run starts or fails.
    var isOutputVisible: Bool = false

    /// Cancellation handles keyed by run id, so the UI's Cancel button can
    /// terminate the spawned process. Cleared when a run finishes.
    private var cancellationHandles: [UUID: UserTaskCancellation] = [:]

    init() {}

    // MARK: - Recording

    /// Registers a new run and surfaces it immediately so the UI can show
    /// progress. Returns the run so the caller can drive its state.
    @discardableResult
    func start(_ run: UserTaskRun) -> UserTaskRun {
        runs.insert(run, at: 0)
        trimToCapacity()
        return run
    }

    // MARK: - Cancellation

    /// Stores the cancellation handle for a run so the UI can cancel it.
    func registerCancellation(
        _ handle: UserTaskCancellation,
        forRunID id: UUID
    ) {
        cancellationHandles[id] = handle
    }

    /// Cancels an active run by id, terminating its process and updating the
    /// UI model. No-op for finished runs or unknown ids.
    func cancelRun(id: UUID) {
        guard let run = run(forID: id), run.state.isActive else { return }
        cancellationHandles[id]?.cancel()
        run.markCancelled()
        cancellationHandles.removeValue(forKey: id)
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

    /// Finds a run by id.
    func run(forID id: UUID) -> UserTaskRun? {
        runs.first { $0.id == id }
    }

    // MARK: - Mutation
        guard let run = run(forID: id), run.state.isActive else { return }
        run.markCancelled()
    }

    /// Removes a finished run from the history (used by the output surface's
    /// Clear action). Active runs cannot be dismissed — cancel them first.
    func removeRun(id: UUID) {
        guard let run = run(forID: id), !run.state.isActive else { return }
        runs.removeAll { $0.id == id }
    }

    /// Clears all finished runs.
    func clearFinished() {
        runs.removeAll { !$0.state.isActive }
    }

    /// Clears every run (used on project teardown).
    func clearAll() {
        runs.removeAll()
    }

    // MARK: - Private

    private func trimToCapacity() {
        // Never trim active runs; only drop the oldest finished runs.
        let finished = runs.filter { !$0.state.isActive }
        let overflow = finished.count - Self.maxRuns
        guard overflow > 0 else { return }
        let toDrop = Set(finished.suffix(overflow).map { $0.id })
        runs.removeAll { toDrop.contains($0.id) }
    }
}
