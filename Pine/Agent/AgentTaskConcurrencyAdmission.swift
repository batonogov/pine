//
//  AgentTaskConcurrencyAdmission.swift
//  Pine
//
//  Bounded concurrent launch admission for independent ADE tasks (#1728).
//

import Foundation

/// The documented, bounded concurrency contract for independent ADE tasks
/// (#1728).
///
/// `maximumConcurrentAgentTasks` is the internal maximum `N` of concurrent
/// agent processes/tasks within one current project — that is, per
/// canonical project (repository) path. The binding contract holds at most
/// one active task per (repository, worktree) pair, so N is the
/// per-repository bound: independent worktrees of the same repository share
/// one admission bucket. Rationale: the release target proves three
/// independent same-repository tasks, and each concurrent agent holds a PTY,
/// a provider process, a terminal view, and bounded evidence/output buffers;
/// `N` is pinned to that proven floor rather than an aspirational fleet size.
/// It is an internal constant, not a user setting.
///
/// An `(N+1)`th launch request never starts a process: it is queued
/// (FIFO, bounded by `maximumQueuedLaunchRequests`) or honestly deferred.
/// The launch path must call `requestLaunch` before spawn, start at most one
/// process per returned grant, and call `release` or `cancel` when the task's
/// process ends, is cancelled, or is torn down. A task holds at most one slot;
/// a new attempt for the same task re-requests after its predecessor is
/// released, so cancellation and relaunch never duplicate work. A crash
/// between grant and spawn holds the slot until process death: admission
/// state is runtime-only and there is no automatic release — the relaunch
/// then requests a fresh grant, which is the honest behavior.
nonisolated enum AgentTaskConcurrencyLimits {
    static let maximumConcurrentAgentTasks = 3
    static let maximumQueuedLaunchRequests = 8
}

/// One authoritative launch grant. The launch path starts at most one agent
/// process per grant it holds; possession alone is not an execution grant and
/// environment/grant revalidation still happens at each authorized action.
/// `launchGeneration` is a monotonic per-project fencing key: event traffic
/// and child-job ownership are attributed to the generation that admitted
/// them. Enforcing that fencing on drained/observed events is the INTEGRATION
/// CALLER's duty: before acting on an event, compare the held grant against
/// the gate's current grant (`grant(project:taskID:)`) and/or filter the
/// event by its `runID`/`launchGeneration`, so a superseded or relaunched
/// attempt cannot inherit another's events or resources.
nonisolated struct AgentTaskLaunchGrant: Hashable, Sendable {
    let taskID: UUID
    let runID: UUID
    let project: AgentTaskProjectIdentity
    let launchGeneration: UInt64
}

nonisolated enum AgentTaskLaunchDeferral: Equatable, Sendable {
    /// The task already holds an active grant or a queued request; a second
    /// request for the same task is rejected rather than duplicated.
    case duplicateRequest
    /// The bounded queue is full. The request is deferred honestly; the
    /// caller presents it as waiting, not running.
    case queueFull
}

nonisolated enum AgentTaskLaunchAdmission: Equatable, Sendable {
    case admitted(AgentTaskLaunchGrant)
    case queued(position: Int)
    case deferred(AgentTaskLaunchDeferral)
}

/// The FIFO admission gate, one bucket per canonical project (repository)
/// path.
///
/// The public API accepts a full `AgentTaskProjectIdentity`, but the bucket
/// is keyed by `canonicalProjectPath` alone: the binding contract holds at
/// most one active task per (repository, worktree) pair, so keying by the
/// full identity would give every worktree its own bucket and leave
/// same-repository concurrency unbounded. N is therefore enforced per
/// repository, across its worktrees.
///
/// A pure gate: it owns no terminals, processes, or providers and never
/// launches anything. The invariants — active grants ≤ `N`, queued requests
/// ≤ the documented bound, generations unique and monotonic per project,
/// one slot per task — hold after every operation, and the only way a slot
/// becomes available is an explicit `release` or `cancel`.
actor AgentTaskConcurrencyAdmission {
    private struct QueuedRequest: Sendable {
        let taskID: UUID
        let runID: UUID
        /// The requesting identity: a promoted grant carries the worktree it
        /// was requested for, never the identity of whoever freed the slot.
        let project: AgentTaskProjectIdentity
    }

    private struct ProjectState: Sendable {
        var active: [UUID: AgentTaskLaunchGrant] = [:]
        var queued: [QueuedRequest] = []
        var nextGeneration: UInt64 = 0
    }

    private let maximumConcurrent: Int
    private let maximumQueued: Int
    /// Keyed by canonical project (repository) path, NOT the full
    /// (project, worktree) identity — see the type documentation above.
    private var projects: [String: ProjectState] = [:]

    init(
        maximumConcurrent: Int = AgentTaskConcurrencyLimits.maximumConcurrentAgentTasks,
        maximumQueued: Int = AgentTaskConcurrencyLimits.maximumQueuedLaunchRequests
    ) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumQueued = max(1, maximumQueued)
    }

    /// Reserves launch capacity before any provider process starts.
    /// Returns the only thing the caller may act on: a grant (start one
    /// process), a queue position (present as waiting), or an honest
    /// deferral (present as deferred; do not start anything).
    func requestLaunch(
        project: AgentTaskProjectIdentity,
        taskID: UUID,
        runID: UUID
    ) async -> AgentTaskLaunchAdmission {
        let key = project.canonicalProjectPath
        var state = projects[key, default: ProjectState()]
        if state.active[taskID] != nil || state.queued.contains(where: { $0.taskID == taskID }) {
            projects[key] = state
            return .deferred(.duplicateRequest)
        }
        if state.active.count < maximumConcurrent {
            state.nextGeneration += 1
            let grant = AgentTaskLaunchGrant(
                taskID: taskID,
                runID: runID,
                project: project,
                launchGeneration: state.nextGeneration
            )
            state.active[taskID] = grant
            projects[key] = state
            return .admitted(grant)
        }
        guard state.queued.count < maximumQueued else {
            projects[key] = state
            return .deferred(.queueFull)
        }
        state.queued.append(QueuedRequest(taskID: taskID, runID: runID, project: project))
        projects[key] = state
        return .queued(position: state.queued.count)
    }

    /// Returns the task's slot and honestly promotes queued requests, one
    /// grant per freed slot, in FIFO order. The returned grants are the only
    /// new launches the caller may start. Releasing a task that holds no
    /// grant is a no-op: a double release or a late relaunch cleanup can
    /// never promote a second copy of the same request.
    func release(
        project: AgentTaskProjectIdentity,
        taskID: UUID
    ) async -> [AgentTaskLaunchGrant] {
        let key = project.canonicalProjectPath
        guard var state = projects[key], state.active[taskID] != nil else {
            return []
        }
        state.active.removeValue(forKey: taskID)
        projects[key] = state
        return promote(key: key)
    }

    /// Cancels the task's active grant or queued request (cancellation,
    /// teardown, dismissal). Idempotent. An active cancellation frees the
    /// slot and promotes the queue exactly like a release; a cancelled grant
    /// is dead — its generation is never reused, and the task must request
    /// a fresh grant before any new attempt.
    func cancel(project: AgentTaskProjectIdentity, taskID: UUID) async {
        let key = project.canonicalProjectPath
        guard var state = projects[key] else { return }
        if state.active[taskID] != nil {
            state.active.removeValue(forKey: taskID)
            projects[key] = state
            _ = promote(key: key)
            return
        }
        guard state.queued.contains(where: { $0.taskID == taskID }) else { return }
        state.queued.removeAll { $0.taskID == taskID }
        projects[key] = state
    }

    // MARK: - Observability (read-only, for presentation and tests)

    func activeCount(project: AgentTaskProjectIdentity) async -> Int {
        projects[project.canonicalProjectPath]?.active.count ?? 0
    }

    func queuedCount(project: AgentTaskProjectIdentity) async -> Int {
        projects[project.canonicalProjectPath]?.queued.count ?? 0
    }

    func grant(
        project: AgentTaskProjectIdentity,
        taskID: UUID
    ) async -> AgentTaskLaunchGrant? {
        projects[project.canonicalProjectPath]?.active[taskID]
    }

    private func promote(key: String) -> [AgentTaskLaunchGrant] {
        guard var state = projects[key] else { return [] }
        var promoted: [AgentTaskLaunchGrant] = []
        while state.active.count < maximumConcurrent, !state.queued.isEmpty {
            let next = state.queued.removeFirst()
            state.nextGeneration += 1
            let grant = AgentTaskLaunchGrant(
                taskID: next.taskID,
                runID: next.runID,
                project: next.project,
                launchGeneration: state.nextGeneration
            )
            state.active[next.taskID] = grant
            promoted.append(grant)
        }
        projects[key] = state
        return promoted
    }
}
