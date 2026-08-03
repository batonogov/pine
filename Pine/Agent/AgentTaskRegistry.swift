//
//  AgentTaskRegistry.swift
//  Pine
//
//  Application-lifetime durable agent task registry (#1302).
//

import Foundation
import Observation

nonisolated private struct AgentTaskTerminalKey: Hashable, Sendable {
    let project: AgentTaskProjectIdentity
    let terminalID: UUID
}

nonisolated struct AgentTaskLaunchReservation: Equatable, Sendable {
    let taskID: UUID
    fileprivate let token: UUID

}

nonisolated enum AgentTaskLaunchResult: Equatable, Sendable {
    case reserved(AgentTaskLaunchReservation)
    case sentWithoutReservation
    case rejected
}

nonisolated private enum AgentTaskClaimKind: Sendable {
    case initialLaunch
    case resume(previousRunID: UUID)
}

nonisolated private enum AgentTaskClaimState: Equatable, Sendable {
    case dormant
    case armed
}

nonisolated private struct AgentTaskPendingClaim: Sendable {
    let token: UUID
    let taskID: UUID
    let project: AgentTaskProjectIdentity
    var route: AgentTaskRoute
    let descriptor: AgentDescriptor
    let kind: AgentTaskClaimKind
    let expectedRunCount: Int
    let generationFloor: UInt64
    let launchBoundary: Date
    var deadline: ContinuousClock.Instant
    var state: AgentTaskClaimState
}

nonisolated private struct AgentTaskTerminationRollback: Sendable {
    let lifecycle: AgentTaskLifecycle
    let availability: AgentTaskRouteAvailability
    let liveness: AgentRunLiveness?
    let attention: AgentTaskAttention
    let updatedAt: Date
}

/// Application-lifetime durable task ownership. The registry is MainActor so
/// terminal lifecycle mutations are ordered, while its metadata actor performs
/// all file I/O. Stored state consists only of value models and identifier maps:
/// no ProjectManager, window, view, TerminalTab, Process, or session references.
@MainActor
@Observable
final class AgentTaskRegistry {
    private(set) var tasks: [AgentTask] = [] {
        didSet {
            guard oldValue != tasks else { return }
            for observer in Array(taskChangeObservers.values) {
                observer(oldValue, tasks)
            }
        }
    }
    private(set) var loadStatusByProject:
        [String: AgentTaskMetadataLoadStatus] = [:]
    private(set) var saveResultByProject:
        [String: AgentTaskMetadataSaveResult] = [:]

    @ObservationIgnored
    private let persistence: any AgentTaskPersisting
    @ObservationIgnored
    private let limits: AgentTaskPersistenceLimits
    @ObservationIgnored
    private var taskIDByRunID: [UUID: UUID] = [:]
    @ObservationIgnored
    private var historicalTaskIDByRunID: [UUID: UUID] = [:]
    @ObservationIgnored
    private var taskIDByTerminal: [AgentTaskTerminalKey: UUID] = [:]
    @ObservationIgnored
    private var pendingClaims: [AgentTaskTerminalKey: AgentTaskPendingClaim] = [:]
    @ObservationIgnored
    private var pendingClaimKeyByToken: [UUID: AgentTaskTerminalKey] = [:]
    @ObservationIgnored
    private var terminationClaimRemaining: [UUID: Duration] = [:]
    @ObservationIgnored
    private var registeredProjects = Set<AgentTaskProjectIdentity>()
    @ObservationIgnored
    private var loadedProjects = Set<AgentTaskProjectIdentity>()
    @ObservationIgnored
    private var quarantinedProjects = Set<AgentTaskProjectIdentity>()
    @ObservationIgnored
    private var loadedInterruptedTaskIDs = Set<UUID>()
    @ObservationIgnored
    private var dirtyProjects = Set<AgentTaskProjectIdentity>()
    @ObservationIgnored
    private var persistenceRetryBlocked = Set<AgentTaskProjectIdentity>()
    @ObservationIgnored
    private var unpersistableDirtyProjects = Set<AgentTaskProjectIdentity>()
    @ObservationIgnored
    private var persistenceRevision: [AgentTaskProjectIdentity: UUID] = [:]
    @ObservationIgnored
    private var diskRevisionByProject:
        [AgentTaskProjectIdentity: AgentTaskDiskRevision] = [:]
    @ObservationIgnored
    private var loadTasks:
        [AgentTaskProjectIdentity: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var persistenceTail: Task<Void, Never>?
    @ObservationIgnored
    private var persistenceTailTicket: AgentTaskPersistenceTicket?
    @ObservationIgnored
    private var abandonedPersistenceTickets = Set<AgentTaskPersistenceTicket>()
    @ObservationIgnored
    private var persistenceSequence: UInt64 = 0
    @ObservationIgnored
    private var completedPersistenceSequence: UInt64 = 0
    @ObservationIgnored
    private var persistenceGeneration: UUID
    @ObservationIgnored
    private let publicationFence: AgentTaskPublicationFence
    @ObservationIgnored
    private var isTerminating = false
    @ObservationIgnored
    private var terminationRollback:
        [UUID: AgentTaskTerminationRollback] = [:]
    @ObservationIgnored
    private var claimExpiryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored
    private let claimTTL: Duration
    @ObservationIgnored
    private let flushTotal: Duration
    @ObservationIgnored
    private let flushTail: Duration
    @ObservationIgnored
    private let abandonedPersistenceLimit = 2
    @ObservationIgnored
    private var taskChangeObservers: [
        UUID: @MainActor ([AgentTask], [AgentTask]) -> Void
    ] = [:]

    init(
        persistence: any AgentTaskPersisting = AgentTaskMetadataStore(),
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        claimTTL: Duration = .seconds(30),
        flushTotal: Duration = .seconds(5),
        flushTail: Duration = .seconds(2),
        limits: AgentTaskPersistenceLimits = AgentTaskPersistenceLimits()
    ) {
        let generation = UUID()
        self.persistence = persistence
        self.limits = limits
        persistenceGeneration = generation
        publicationFence = AgentTaskPublicationFence(generation: generation)
        self.monotonicNow = monotonicNow
        self.claimTTL = claimTTL
        self.flushTotal = flushTotal
        self.flushTail = flushTail
    }

    func task(for id: UUID) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    func matchesNotificationRoute(
        _ identity: AgentNotificationRouteIdentity
    ) -> Bool {
        guard let task = task(for: identity.taskID),
              let run = task.runs.last else { return false }
        return run.id == identity.runID
            && run.process.processGeneration == identity.processGeneration
    }

    /// Observes ordered, value-only snapshots without exposing persistence or
    /// terminal ownership internals. The returned token must be removed by the
    /// application-lifetime consumer when it stops.
    func addTaskChangeObserver(
        _ observer: @escaping @MainActor ([AgentTask], [AgentTask]) -> Void
    ) -> UUID {
        let token = UUID()
        taskChangeObservers[token] = observer
        return token
    }

    func removeTaskChangeObserver(_ token: UUID) {
        taskChangeObservers.removeValue(forKey: token)
    }

    /// Explicitly changes Inbox review state. Merely reading or rendering the
    /// registry never calls this method, so opening the Inbox cannot clear a
    /// badge as a side effect.
    @discardableResult
    func setReviewed(_ reviewed: Bool, taskID: UUID) -> Bool {
        guard !isTerminating,
              let index = taskIndex(for: taskID),
              tasks[index].isUnread == reviewed else {
            return false
        }
        tasks[index].isUnread = !reviewed
        markDirty(tasks[index].project)
        return true
    }

    /// Removes a finished/stale task from Inbox history without destroying a
    /// live ownership route. Dismissed metadata remains durable until bounded
    /// retention safely reclaims it.
    @discardableResult
    func dismissTask(_ taskID: UUID, at timestamp: Date = Date()) -> Bool {
        guard !isTerminating,
              let index = taskIndex(for: taskID),
              tasks[index].runs.last?.liveness != .live,
              tasks[index].lifecycle != .active,
              tasks[index].lifecycle != .dismissed else {
            return false
        }
        tasks[index].lifecycle = .dismissed
        tasks[index].attention = .none
        tasks[index].isUnread = false
        tasks[index].updatedAt = max(tasks[index].updatedAt, timestamp)
        markDirty(tasks[index].project)
        return true
    }

    func taskID(forSessionID sessionID: UUID) -> UUID? {
        taskIDByRunID[sessionID]
    }

    func task(forSessionID sessionID: UUID) -> AgentTask? {
        guard let taskID = taskIDByRunID[sessionID] else { return nil }
        return task(for: taskID)
    }

    func historicalTask(forSessionID sessionID: UUID) -> AgentTask? {
        tasks.first { task in task.runs.contains { $0.id == sessionID } }
    }

    #if DEBUG
    func persistenceIsQuarantinedForTesting(
        _ project: AgentTaskProjectIdentity
    ) -> Bool {
        quarantinedProjects.contains(project)
    }
    #endif

    func isExactLiveOwner(
        taskID: UUID,
        terminalID: UUID,
        runID: UUID
    ) -> Bool {
        guard let task = task(for: taskID) else { return false }
        let key = AgentTaskTerminalKey(
            project: task.project,
            terminalID: terminalID
        )
        return taskIDByTerminal[key] == taskID
            && taskIDByRunID[runID] == taskID
    }

    /// Loads a canonical project scope once. The metadata actor performs path
    /// checks and decoding; MainActor only merges the returned values.
    func registerProject(_ project: AgentTaskProjectIdentity) {
        guard !isTerminating else { return }
        guard registeredProjects.insert(project).inserted else { return }
        let store = persistence
        let load = Task { @MainActor [weak self] in
            let result = await store.load(project: project)
            guard let self, !Task.isCancelled else { return }
            acceptLoad(result, project: project)
            loadTasks[project] = nil
        }
        loadTasks[project] = load
    }

    /// Bridges the legacy terminal `AgentSession` model into durable identity.
    /// Repeated observations retain both IDs. A detector replacement ends the
    /// old run; only a Pine-owned reservation may inherit the durable task.
    func bridge(
        _ session: AgentSession,
        replacing previous: AgentSession?,
        context: AgentTaskBridgeContext,
        reservation: AgentTaskLaunchReservation? = nil
    ) {
        expireClaims()
        // Manual discovery is eligible only with a complete detector-owned
        // process observation. Never infer ownership from agent type or route.
        guard !isTerminating, session.processEvidence != nil else {
            return
        }
        if let existingTaskID = taskIDByRunID[session.id] {
            guard mappedEvidenceMatches(
                session,
                context: context,
                taskID: existingTaskID
            ) else { return }
            updateMappedSession(session, route: context.route)
            if session.liveness == .terminated,
               let task = task(for: existingTaskID) {
                removeLiveOwnership(
                    taskID: existingTaskID,
                    key: AgentTaskTerminalKey(
                        project: task.project,
                        terminalID: task.route.terminalID
                    )
                )
            }
            markDirty(taskID: existingTaskID)
            return
        }
        // Terminal close removes live ownership before the detector reports
        // process termination. A durable run UUID is a tombstone: late
        // evidence may never create another task containing that run.
        if historicalTaskIDByRunID[session.id] != nil { return }

        let key = terminalKey(context)
        if let previous, previous.id != session.id,
           let previousTaskID = taskIDByRunID[previous.id],
           taskIDByTerminal[key] == previousTaskID {
            updateMappedSession(previous, route: nil)
            detachRun(sessionID: previous.id, at: context.observedAt)
        }

        if let reservation {
            let reservationBelongsToKey = pendingClaimKeyByToken[reservation.token]
                == key
                && pendingClaims[key]?.taskID == reservation.taskID
            guard consume(
                reservation,
                session: session,
                context: context
            ) else {
                if !reservationBelongsToKey {
                    cancelClaim(reservation)
                    cancelClaim(for: key)
                }
                return
            }
            return
        }
        if pendingClaims[key] != nil {
            // An ordinary detector poll is not launch-owner authority. Keep
            // the one-shot claim until its owner attaches, cancels, or its
            // deterministic deadline expires.
            return
        }

        guard acceptedProcessForNewRun(session) != nil else { return }
        guard makeRoomForTask(in: context.project) else { return }
        detachCurrentOwner(for: key, at: context.observedAt)

        let discoveryContext = AgentTaskBridgeContext(
            project: context.project,
            route: context.route,
            origin: .discoveredInTerminal,
            observedAt: context.observedAt
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: session.agentType),
            context: discoveryContext
        )
        guard appendRun(session, to: &task, context: discoveryContext) else {
            return
        }
        tasks.append(task)
        indexLiveTask(task)
        markDirty(task.project)
    }

    /// Refreshes mapped runs after every successful or failed detector poll,
    /// including sessions whose terminal pane has already disappeared.
    func refresh(sessions: [AgentSession]) {
        expireClaims()
        guard !isTerminating else { return }
        var changedProjects = Set<AgentTaskProjectIdentity>()
        for session in sessions {
            guard let taskID = taskIDByRunID[session.id],
                  updateMappedSession(session, route: nil),
                  let task = task(for: taskID) else {
                continue
            }
            if session.liveness == .terminated {
                removeLiveOwnership(
                    taskID: taskID,
                    key: AgentTaskTerminalKey(
                    project: task.project,
                    terminalID: task.route.terminalID
                    )
                )
            }
            changedProjects.insert(task.project)
        }
        changedProjects.forEach(markDirty)
    }

    /// Records detector unavailability without claiming process termination.
    func markEvidenceUnavailable(sessionIDs: [UUID]) {
        expireClaims()
        guard !isTerminating else { return }
        var changedProjects = Set<AgentTaskProjectIdentity>()
        for sessionID in sessionIDs {
            guard let taskIndex = taskIndex(forRunID: sessionID),
                  let runIndex = tasks[taskIndex].runs.firstIndex(
                    where: { $0.id == sessionID }
                  ),
                  tasks[taskIndex].runs[runIndex].liveness != .terminated else {
                continue
            }
            tasks[taskIndex].runs[runIndex].liveness = .stale
            tasks[taskIndex].attention = .none
            tasks[taskIndex].updatedAt = max(
                tasks[taskIndex].updatedAt,
                tasks[taskIndex].runs[runIndex].lastObservedAt
            )
            changedProjects.insert(tasks[taskIndex].project)
        }
        changedProjects.forEach(markDirty)
    }

    /// Reserves durable identity before a Pine-owned launch. The real detector
    /// later supplies the run and process evidence for this exact route.
    func preparePineLaunch(
        descriptor: AgentDescriptor,
        context: AgentTaskBridgeContext,
        title: String?,
        objective: String?,
        boundary: AgentTaskLaunchBoundary
    ) -> AgentTaskLaunchResult {
        expireClaims()
        guard !isTerminating,
              context.origin == .pineLaunched,
              validLaunchRoute(context.route),
              validLaunchExecutable(descriptor),
              validUserText(title, maximum: limits.maxTitleBytes),
              validUserText(objective, maximum: limits.maxObjectiveBytes) else {
            return .rejected
        }
        let key = terminalKey(context)
        guard pendingClaims[key] == nil,
              taskIDByTerminal[key] == nil else { return .rejected }
        guard makeRoomForTask(in: context.project) else { return .rejected }
        var task = AgentTask(
            descriptor: descriptor,
            context: context,
            title: title,
            objective: objective
        )
        task.lifecycle = .paused
        task.route.availability = .missing
        let reservation = AgentTaskLaunchReservation(
            taskID: task.id,
            token: UUID()
        )
        tasks.append(task)
        installClaim(AgentTaskPendingClaim(
            token: reservation.token,
            taskID: task.id,
            project: context.project,
            route: context.route,
            descriptor: descriptor,
            kind: .initialLaunch,
            expectedRunCount: 0,
            generationFloor: boundary.generationFloor,
            launchBoundary: normalizedLaunchBoundary(boundary.capturedAt),
            deadline: monotonicNow().advanced(by: claimTTL),
            state: .dormant
        ), key: key)
        return .reserved(reservation)
    }

    /// Reserves relaunch intent. Detector-owned evidence must claim it later.
    func prepareResume(
        taskID: UUID,
        context: AgentTaskBridgeContext,
        boundary: AgentTaskLaunchBoundary
    ) -> AgentTaskLaunchResult {
        expireClaims()
        guard let index = taskIndex(for: taskID),
              !isTerminating,
              context.origin == .pineLaunched,
              validLaunchRoute(context.route),
              tasks[index].project == context.project,
              isResumableTask(at: index),
              let prior = tasks[index].runs.last,
              pendingClaims[terminalKey(context)] == nil,
              taskIDByTerminal[terminalKey(context)] == nil else {
            return .rejected
        }
        let previousRunID = prior.id
        let reservation = AgentTaskLaunchReservation(
            taskID: taskID,
            token: UUID()
        )
        installClaim(AgentTaskPendingClaim(
            token: reservation.token,
            taskID: taskID,
            project: context.project,
            route: context.route,
            descriptor: tasks[index].descriptor,
            kind: .resume(previousRunID: previousRunID),
            expectedRunCount: tasks[index].runs.count,
            generationFloor: boundary.generationFloor,
            launchBoundary: normalizedLaunchBoundary(boundary.capturedAt),
            deadline: monotonicNow().advanced(by: claimTTL),
            state: .dormant
        ), key: terminalKey(context))
        return .reserved(reservation)
    }

    func canResumeTask(_ taskID: UUID) -> Bool {
        expireClaims()
        guard !isTerminating,
              let index = taskIndex(for: taskID) else { return false }
        return isResumableTask(at: index)
    }

    /// Makes a reserved claim consumable only after Pine's exact PTY write was
    /// acknowledged in full. Dormant claims still occupy their route and TTL,
    /// but detector evidence cannot consume them.
    @discardableResult
    func armLaunch(_ reservation: AgentTaskLaunchReservation) -> Bool {
        if !isTerminating { expireClaims() }
        guard let key = pendingClaimKeyByToken[reservation.token],
              var claim = pendingClaims[key],
              claim.taskID == reservation.taskID,
              claim.state == .dormant else { return false }
        let deadlineIsValid: Bool
        if isTerminating {
            deadlineIsValid = terminationClaimRemaining[reservation.token]
                .map { $0 > .zero } ?? false
        } else {
            deadlineIsValid = monotonicNow() < claim.deadline
        }
        guard deadlineIsValid else { return false }
        claim.state = .armed
        pendingClaims[key] = claim
        return true
    }

    func cancelLaunch(_ reservation: AgentTaskLaunchReservation) {
        if !isTerminating { expireClaims() }
        cancelClaim(reservation)
    }

    func isLaunchPending(_ reservation: AgentTaskLaunchReservation) -> Bool {
        guard let key = pendingClaimKeyByToken[reservation.token] else {
            return false
        }
        return pendingClaims[key]?.taskID == reservation.taskID
    }

    /// A closed project window leaves terminal processes alive in Pine's
    /// background project registry. Only route presentation changes.
    func setWindowOpen(_ isOpen: Bool, projectPath: String) {
        setWindowOpen(isOpen) {
            $0.canonicalProjectPath == projectPath
        }
    }

    /// Updates only one project/worktree window. Multiple managed worktrees
    /// deliberately share `canonicalProjectPath`, so closing one must not
    /// background sibling agent runs.
    func setWindowOpen(
        _ isOpen: Bool,
        project: AgentTaskProjectIdentity
    ) {
        setWindowOpen(isOpen) { $0 == project }
    }

    private func setWindowOpen(
        _ isOpen: Bool,
        matchesProject: (AgentTaskProjectIdentity) -> Bool
    ) {
        expireClaims()
        guard !isTerminating else { return }
        var projects = Set<AgentTaskProjectIdentity>()
        for key in Array(pendingClaims.keys)
        where matchesProject(key.project) {
            guard var claim = pendingClaims[key] else { continue }
            if isOpen, claim.route.availability == .background {
                claim.route.availability = .available
            } else if !isOpen, claim.route.availability == .available {
                claim.route.availability = .background
            } else {
                continue
            }
            pendingClaims[key] = claim
        }
        for (_, taskID) in taskIDByTerminal
        where task(for: taskID).map({ matchesProject($0.project) }) == true {
            guard let index = taskIndex(for: taskID) else { continue }
            let availability = tasks[index].route.availability
            if isOpen, availability == .background {
                tasks[index].route.availability = .available
            } else if !isOpen, availability == .available {
                tasks[index].route.availability = .background
            } else {
                continue
            }
            tasks[index].updatedAt = max(
                tasks[index].updatedAt,
                tasks[index].runs.last?.lastObservedAt ?? tasks[index].createdAt
            )
            projects.insert(tasks[index].project)
        }
        projects.forEach(markDirty)
    }

    /// Updates a runtime route only for the uniquely owned terminal in the
    /// same canonical project/worktree scope. A move never ends its run.
    func updateRoute(
        terminalID: UUID,
        project: AgentTaskProjectIdentity,
        route: AgentTaskRoute
    ) {
        expireClaims()
        let key = AgentTaskTerminalKey(
            project: project,
            terminalID: terminalID
        )
        guard !isTerminating,
              route.terminalID == terminalID,
              route.tabID == terminalID else { return }
        if var claim = pendingClaims[key] {
            claim.route = route
            pendingClaims[key] = claim
        }
        guard let taskID = taskIDByTerminal[key],
              let index = taskIndex(for: taskID) else { return }
        let availability = tasks[index].route.availability
        tasks[index].route = AgentTaskRoute(
            paneID: route.paneID,
            tabID: route.tabID,
            terminalID: route.terminalID,
            availability: availability
        )
        tasks[index].updatedAt = max(
            tasks[index].updatedAt,
            tasks[index].runs.last?.lastObservedAt ?? tasks[index].createdAt
        )
        taskIDByTerminal[AgentTaskTerminalKey(
            project: project,
            terminalID: terminalID
        )] = tasks[index].id
        markDirty(project)
    }

    /// Closing a terminal is authoritative terminal-lifecycle evidence. The
    /// process observer may confirm termination later, but may not revive it.
    func markTerminalClosed(
        terminalID: UUID,
        project: AgentTaskProjectIdentity,
        at timestamp: Date = Date()
    ) {
        expireClaims()
        guard !isTerminating else { return }
        let key = AgentTaskTerminalKey(project: project, terminalID: terminalID)
        cancelClaim(for: key)
        guard let taskID = taskIDByTerminal[key],
              let index = taskIndex(for: taskID) else { return }
        tasks[index].route.availability = .missing
        if let runIndex = tasks[index].runs.indices.last,
           tasks[index].runs[runIndex].liveness != .terminated {
            tasks[index].runs[runIndex].liveness = .terminated
            tasks[index].runs[runIndex].endedAt = max(
                tasks[index].runs[runIndex].lastObservedAt,
                timestamp
            )
            tasks[index].lifecycle = .paused
            tasks[index].attention = .none
            tasks[index].lastActivityAt = max(
                tasks[index].lastActivityAt,
                timestamp
            )
        }
        tasks[index].updatedAt = max(tasks[index].updatedAt, timestamp)
        removeLiveOwnership(taskID: taskID, key: key)
        markDirty(project)
    }

    /// Invalidates runtime-only routing before the asynchronous quit barrier.
    /// This is not task completion and does not manufacture user attention.
    func prepareForApplicationTermination(at timestamp: Date = Date()) {
        guard !isTerminating else { return }
        expireClaims()
        isTerminating = true
        let now = monotonicNow()
        terminationClaimRemaining.removeAll(keepingCapacity: true)
        for claim in pendingClaims.values {
            terminationClaimRemaining[claim.token] = max(
                .zero,
                now.duration(to: claim.deadline)
            )
            claimExpiryTasks.removeValue(forKey: claim.token)?.cancel()
        }
        var changedProjects = Set<AgentTaskProjectIdentity>()
        for taskIndex in tasks.indices {
            let runIndex = tasks[taskIndex].runs.indices.last
            terminationRollback[tasks[taskIndex].id] = AgentTaskTerminationRollback(
                lifecycle: tasks[taskIndex].lifecycle,
                availability: tasks[taskIndex].route.availability,
                liveness: runIndex.map { tasks[taskIndex].runs[$0].liveness },
                attention: tasks[taskIndex].attention,
                updatedAt: tasks[taskIndex].updatedAt
            )
            tasks[taskIndex].route.availability = .missing
            if let runIndex,
               tasks[taskIndex].runs[runIndex].liveness == .live {
                tasks[taskIndex].runs[runIndex].liveness = .stale
            }
            if tasks[taskIndex].lifecycle == .active {
                tasks[taskIndex].lifecycle = .paused
            }
            tasks[taskIndex].attention = .none
            tasks[taskIndex].updatedAt = max(
                tasks[taskIndex].updatedAt,
                timestamp
            )
            changedProjects.insert(tasks[taskIndex].project)
        }
        changedProjects.forEach(markDirty)
    }

    func cancelApplicationTerminationAndFlush(
        maximumDuration: Duration? = nil
    ) async -> Bool {
        guard isTerminating else { return true }
        restoreTerminationSnapshot()
        let rollbackWasSaved = await flushPersistence(
            maximumDuration: maximumDuration
        ) == .saved
        // A failed durability barrier is surfaced to the caller, but it must
        // never leave the still-running application in termination mode.
        // Runtime admission and bounded claim expiry are restored regardless.
        finishTerminationCancellation()
        return rollbackWasSaved
    }

    #if DEBUG
    func cancelApplicationTermination() {
        guard isTerminating else { return }
        restoreTerminationSnapshot()
        finishTerminationCancellation()
    }
    #endif

    private func restoreTerminationSnapshot() {
        var restoredProjects = Set<AgentTaskProjectIdentity>()
        for index in tasks.indices {
            if let rollback = terminationRollback[tasks[index].id] {
                tasks[index].lifecycle = rollback.lifecycle
                tasks[index].route.availability = rollback.availability
                tasks[index].attention = rollback.attention
                tasks[index].updatedAt = rollback.updatedAt
                if let runIndex = tasks[index].runs.indices.last,
                   let liveness = rollback.liveness {
                    tasks[index].runs[runIndex].liveness = liveness
                }
                restoredProjects.insert(tasks[index].project)
            }
        }
        restoredProjects.forEach(markDirty)
    }

    private func finishTerminationCancellation() {
        isTerminating = false
        terminationRollback.removeAll()
        let now = monotonicNow()
        for key in Array(pendingClaims.keys) {
            guard var claim = pendingClaims[key],
                  let remaining = terminationClaimRemaining[claim.token] else {
                continue
            }
            claim.deadline = now.advanced(by: remaining)
            installClaim(claim, key: key)
        }
        terminationClaimRemaining.removeAll(keepingCapacity: true)
    }

    /// Waits for loads and every queued save, with a five-second total and
    /// two-second per-tail monotonic deadline. A hung store fails closed.
    func flushPersistence(
        maximumDuration: Duration? = nil
    ) async -> AgentTaskPersistenceFlushResult {
        let requestedDuration = maximumDuration.map {
            max(.zero, $0)
        } ?? flushTotal
        let deadline = monotonicNow().advanced(
            by: min(flushTotal, requestedDuration)
        )
        let loadingProjects = Array(loadTasks.keys)
        for project in loadingProjects {
            guard await waitForLoad(project, until: deadline) else {
                return .failed
            }
        }
        guard unpersistableDirtyProjects.isEmpty else { return .failed }
        var failedAttempts = 0
        while monotonicNow() < deadline {
            guard unpersistableDirtyProjects.isEmpty else { return .failed }
            guard monotonicNow() < deadline else { return .failed }
            if persistenceTail == nil,
               !dirtyProjects.isEmpty,
               dirtyProjects.isSubset(of: persistenceRetryBlocked) {
                let retry = dirtyProjects.min {
                    $0.persistenceKey < $1.persistenceKey
                }
                if let retry { persistenceRetryBlocked.remove(retry) }
            }
            let dirty = dirtyProjects
            dirty.forEach(scheduleSaveIfReady)
            guard persistenceTail != nil else {
                return dirtyProjects.isEmpty ? .saved : .failed
            }
            let ticket = persistenceTailTicket
            let attempt = min(
                deadline,
                monotonicNow().advanced(by: flushTail)
            )
            guard let ticket,
                  await waitForPersistence(ticket, until: attempt) else {
                abandonPersistenceTail()
                return .failed
            }
            if let result = saveResultByProject[ticket.projectKey],
               !result.isDurablySaved {
                failedAttempts += 1
                if failedAttempts >= 3 { return .failed }
            }
        }
        return .failed
    }

    private func acceptLoad(
        _ result: AgentTaskMetadataLoadResult,
        project: AgentTaskProjectIdentity
    ) {
        loadStatusByProject[project.persistenceKey] = result.status
        if case .rejected(let rejection) = result.status {
            quarantineLoadedProject(project, rejection: rejection)
            return
        }
        let currentTaskIDs = Set(tasks.map(\.id))
        let currentRunIDs = Set(tasks.flatMap(\.runs).map(\.id))
        var stagedTaskIDs = Set<UUID>()
        var stagedRunIDs = Set<UUID>()
        var needsNormalizedSave = result.requiresMigration
        var stagedTasks: [AgentTask] = []
        var stagedInterruptedTaskIDs = Set<UUID>()
        for loadedTask in result.tasks {
            if loadedTask.origin == .pineLaunched,
               loadedTask.runs.isEmpty {
                needsNormalizedSave = true
                continue
            }
            let loadedRunIDs = Set(loadedTask.runs.map(\.id))
            guard loadedTask.project == project,
                  loadedRunIDs.count == loadedTask.runs.count,
                  !currentTaskIDs.contains(loadedTask.id),
                  stagedTaskIDs.insert(loadedTask.id).inserted,
                  currentRunIDs.isDisjoint(with: loadedRunIDs),
                  stagedRunIDs.isDisjoint(with: loadedRunIDs) else {
                quarantineLoadedProject(project, rejection: .invalidMetadata)
                return
            }
            stagedRunIDs.formUnion(loadedRunIDs)
            var task = loadedTask
            if normalizeLoadedTask(&task) {
                stagedInterruptedTaskIDs.insert(task.id)
                needsNormalizedSave = true
            }
            stagedTasks.append(task)
            if isTerminating { needsNormalizedSave = true }
        }
        let currentProjectTaskCount = tasks.lazy.filter {
            $0.project == project
        }.count
        guard currentProjectTaskCount + stagedTasks.count
                <= limits.maxTasksPerProject else {
            quarantineLoadedProject(project, rejection: .storageLimit)
            return
        }
        var stagedHistorical = historicalTaskIDByRunID
        for task in stagedTasks {
            for run in task.runs {
                if let existing = stagedHistorical[run.id], existing != task.id {
                    quarantineLoadedProject(project, rejection: .invalidMetadata)
                    return
                }
                if stagedHistorical[run.id] == nil,
                   stagedHistorical.count >= limits.maxHistoricalRunIDs {
                    quarantineLoadedProject(project, rejection: .storageLimit)
                    return
                }
                stagedHistorical[run.id] = task.id
            }
        }
        loadedProjects.insert(project)
        diskRevisionByProject[project] = result.revision
        historicalTaskIDByRunID = stagedHistorical
        loadedInterruptedTaskIDs.formUnion(stagedInterruptedTaskIDs)
        tasks.append(contentsOf: stagedTasks)
        if needsNormalizedSave { markDirty(project) }
        scheduleSaveIfReady(project)
    }

    private func quarantineLoadedProject(
        _ project: AgentTaskProjectIdentity,
        rejection: AgentTaskMetadataRejection
    ) {
        loadStatusByProject[project.persistenceKey] = .rejected(rejection)
        loadedProjects.remove(project)
        diskRevisionByProject[project] = nil
        quarantinedProjects.insert(project)
        if dirtyProjects.contains(project) {
            unpersistableDirtyProjects.insert(project)
        }
        dirtyProjects.remove(project)
        persistenceRetryBlocked.remove(project)
    }

    private func waitForLoad(
        _ project: AgentTaskProjectIdentity,
        until deadline: ContinuousClock.Instant
    ) async -> Bool {
        let clock = ContinuousClock()
        while loadTasks[project] != nil, monotonicNow() < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return loadTasks[project] == nil
    }

    private func waitForPersistence(
        _ ticket: AgentTaskPersistenceTicket,
        until deadline: ContinuousClock.Instant
    ) async -> Bool {
        let clock = ContinuousClock()
        while monotonicNow() < deadline {
            guard ticket.generation == persistenceGeneration else {
                return false
            }
            if completedPersistenceSequence >= ticket.sequence {
                return true
            }
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return ticket.generation == persistenceGeneration
            && completedPersistenceSequence >= ticket.sequence
    }

    private func normalizeLoadedTask(_ task: inout AgentTask) -> Bool {
        task.route.availability = .missing
        var invalidatedLiveRun = false
        for index in task.runs.indices
        where task.runs[index].liveness == .live
            || task.runs[index].liveness == .stale {
            task.runs[index].liveness = .stale
            invalidatedLiveRun = true
        }
        if invalidatedLiveRun {
            task.attention = .none
            if task.lifecycle == .active {
                task.lifecycle = .paused
            }
        }
        return invalidatedLiveRun
    }

    private func appendRun(
        _ session: AgentSession,
        to taskID: UUID,
        context: AgentTaskBridgeContext
    ) -> Bool {
        guard let index = taskIndex(for: taskID),
              acceptedProcessForNewRun(session) != nil,
              canMakeRoomForRun(at: index) else {
            return false
        }
        trimRunHistoryForAppend(at: index)
        guard appendRun(
            session,
            to: &tasks[index],
            context: context
        ) else {
            return false
        }
        indexLiveTask(tasks[index])
        markDirty(tasks[index].project)
        return true
    }

    private func appendRun(
        _ session: AgentSession,
        to task: inout AgentTask,
        context: AgentTaskBridgeContext
    ) -> Bool {
        guard let process = acceptedProcessForNewRun(session) else { return false }
        let liveness = AgentRunLiveness(session.liveness)
        let run = AgentTaskRun(AgentTaskRunInput(
            id: session.id,
            terminalID: context.route.terminalID,
            process: process,
            status: AgentTaskRunStatus(
                state: AgentRunState(session.state),
                liveness: liveness,
                observedAt: max(session.lastObservedAt, session.startedAt)
            )
        ))
        task.route = context.route
        task.runs.append(run)
        task.lifecycle = liveness == .terminated ? .paused : .active
        if liveness == .terminated {
            task.route.availability = .missing
        }
        task.completedAt = nil
        task.updatedAt = max(
            task.updatedAt,
            max(context.observedAt, session.lastObservedAt)
        )
        task.lastActivityAt = max(
            task.lastActivityAt,
            session.lastObservedAt
        )
        applyAttention(to: &task, from: run)
        return true
    }

    @discardableResult
    private func updateMappedSession(
        _ session: AgentSession,
        route: AgentTaskRoute?
    ) -> Bool {
        guard let taskIndex = taskIndex(forRunID: session.id),
              let runIndex = tasks[taskIndex].runs.firstIndex(
                where: { $0.id == session.id }
              ),
              tasks[taskIndex].runs[runIndex].liveness != .terminated else {
            return false
        }
        var run = tasks[taskIndex].runs[runIndex]
        let nextState = AgentRunState(session.state)
        let nextLiveness = AgentRunLiveness(session.liveness)
        let nextObservedAt = max(session.lastObservedAt, run.startedAt)
        let changed = run.state != nextState
            || run.liveness != nextLiveness
            || run.lastObservedAt != nextObservedAt
            || route.map({ $0 != tasks[taskIndex].route }) == true
        guard changed else { return false }

        run.state = nextState
        run.liveness = nextLiveness
        run.lastObservedAt = nextObservedAt
        if nextLiveness == .terminated {
            run.endedAt = nextObservedAt
        }
        tasks[taskIndex].runs[runIndex] = run
        if let route,
           route.terminalID == run.terminalID,
           route.tabID == run.terminalID {
            let availability = tasks[taskIndex].route.availability
            tasks[taskIndex].route = AgentTaskRoute(
                paneID: route.paneID,
                tabID: route.tabID,
                terminalID: route.terminalID,
                availability: availability
            )
        }
        tasks[taskIndex].updatedAt = max(
            tasks[taskIndex].updatedAt,
            nextObservedAt
        )
        tasks[taskIndex].lastActivityAt = max(
            tasks[taskIndex].lastActivityAt,
            nextObservedAt
        )
        if nextLiveness == .terminated,
           tasks[taskIndex].lifecycle == .active {
            tasks[taskIndex].lifecycle = .paused
            tasks[taskIndex].route.availability = .missing
        }
        applyAttention(to: &tasks[taskIndex], from: run)
        return true
    }

    private func applyAttention(
        to task: inout AgentTask,
        from run: AgentTaskRun
    ) {
        let next: AgentTaskAttention
        if run.liveness != .live {
            next = .none
        } else if run.state == .waitingInput {
            next = .waitingInput
        } else {
            next = .none
        }
        if next != .none, next != task.attention {
            task.isUnread = true
        }
        task.attention = next
    }

    private func consume(
        _ reservation: AgentTaskLaunchReservation,
        session: AgentSession,
        context: AgentTaskBridgeContext
    ) -> Bool {
        guard let key = pendingClaimKeyByToken[reservation.token],
              let claim = pendingClaims[key],
              claim.state == .armed,
              claim.token == reservation.token,
              claim.taskID == reservation.taskID,
              monotonicNow() < claim.deadline,
              canAcceptPending(claim, session: session, context: context),
              acceptedProcessForNewRun(session) != nil,
              canMakeRoomForClaimRun(taskID: claim.taskID) else {
            return false
        }
        removeClaim(for: key)
        if loadedInterruptedTaskIDs.remove(claim.taskID) != nil,
           let index = taskIndex(for: claim.taskID),
           let runIndex = tasks[index].runs.indices.last {
            let end = max(
                tasks[index].runs[runIndex].lastObservedAt,
                session.startedAt
            )
            tasks[index].runs[runIndex].liveness = .terminated
            tasks[index].runs[runIndex].endedAt = end
            advanceTaskChronology(at: index, through: end)
        }
        return appendRun(session, to: claim.taskID, context: context)
    }

    private func canAcceptPending(
        _ claim: AgentTaskPendingClaim,
        session: AgentSession,
        context: AgentTaskBridgeContext
    ) -> Bool {
        guard let task = task(for: claim.taskID),
              let evidence = session.processEvidence else { return false }
        guard task.runs.count == claim.expectedRunCount,
              context.origin == .pineLaunched,
              task.origin == .pineLaunched,
              task.project == claim.project,
              context.project == claim.project,
              context.route == claim.route,
              task.descriptor == claim.descriptor,
              claim.descriptor.agentType == session.agentType,
              evidence.startIdentifier != nil,
              evidence.startIsAuthoritative,
              evidence.processGeneration > claim.generationFloor,
              evidence.observedStartedAt > claim.launchBoundary else {
            return false
        }
        switch claim.kind {
        case .initialLaunch:
            return task.runs.isEmpty
                && task.route.terminalID == claim.route.terminalID
        case .resume(let previousRunID):
            guard let previous = task.runs.last else { return false }
            let generationIsValid = previous.terminalID != context.route.terminalID
                || evidence.processGeneration
                    > previous.process.processGeneration
            let interruptedTail = loadedInterruptedTaskIDs.contains(task.id)
                && previous.liveness == .stale
                && previous.endedAt == nil
                && evidence.observedStartedAt >= previous.lastObservedAt
            let terminatedTail = previous.liveness == .terminated
                && previous.endedAt != nil
            return previous.id == previousRunID
                && (terminatedTail || interruptedTail)
                && generationIsValid
        }
    }

    private func endRun(sessionID: UUID, at timestamp: Date) {
        guard let taskIndex = taskIndex(forRunID: sessionID),
              let runIndex = tasks[taskIndex].runs.firstIndex(
                where: { $0.id == sessionID }
              ) else {
            return
        }
        tasks[taskIndex].runs[runIndex].liveness = .terminated
        tasks[taskIndex].runs[runIndex].endedAt = max(
            tasks[taskIndex].runs[runIndex].lastObservedAt,
            timestamp
        )
        tasks[taskIndex].lifecycle = .paused
        tasks[taskIndex].attention = .none
        if let endedAt = tasks[taskIndex].runs[runIndex].endedAt {
            advanceTaskChronology(at: taskIndex, through: endedAt)
        }
    }

    private func indexLiveTask(_ task: AgentTask) {
        guard let run = task.runs.last else { return }
        historicalTaskIDByRunID[run.id] = task.id
        guard task.lifecycle == .active,
              run.liveness != .terminated else { return }
        taskIDByRunID[run.id] = task.id
        taskIDByTerminal[AgentTaskTerminalKey(
            project: task.project,
            terminalID: task.route.terminalID
        )] = task.id
    }

    private func removeLiveOwnership(
        taskID: UUID,
        key: AgentTaskTerminalKey
    ) {
        if let task = task(for: taskID), let run = task.runs.last {
            taskIDByRunID[run.id] = nil
        }
        if taskIDByTerminal[key] == taskID {
            taskIDByTerminal[key] = nil
        }
        if let index = taskIndex(for: taskID) {
            tasks[index].route.availability = .missing
        }
    }

    private func installClaim(
        _ claim: AgentTaskPendingClaim,
        key: AgentTaskTerminalKey
    ) {
        pendingClaims[key] = claim
        pendingClaimKeyByToken[claim.token] = key
        claimExpiryTasks[claim.token]?.cancel()
        claimExpiryTasks[claim.token] = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(until: claim.deadline)
            } catch {
                return
            }
            guard let self,
                  pendingClaims[key]?.token == claim.token else { return }
            cancelClaim(for: key)
        }
    }

    private func removeClaim(for key: AgentTaskTerminalKey) {
        guard let claim = pendingClaims.removeValue(forKey: key) else { return }
        pendingClaimKeyByToken[claim.token] = nil
        terminationClaimRemaining[claim.token] = nil
        claimExpiryTasks.removeValue(forKey: claim.token)?.cancel()
    }

    private func cancelClaim(_ reservation: AgentTaskLaunchReservation) {
        guard let key = pendingClaimKeyByToken[reservation.token],
              pendingClaims[key]?.taskID == reservation.taskID else { return }
        cancelClaim(for: key)
    }

    private func cancelClaim(for key: AgentTaskTerminalKey) {
        guard let claim = pendingClaims[key] else { return }
        removeClaim(for: key)
        guard let index = taskIndex(for: claim.taskID) else { return }
        tasks[index].route.availability = .missing
        if case .initialLaunch = claim.kind, tasks[index].runs.isEmpty {
            let project = tasks[index].project
            tasks.remove(at: index)
            markDirty(project)
        } else {
            tasks[index].lifecycle = .paused
            markDirty(tasks[index].project)
        }
    }

    private func expireClaims() {
        let now = monotonicNow()
        let expired = pendingClaims.compactMap { key, claim in
            claim.deadline <= now ? key : nil
        }
        expired.forEach(cancelClaim)
    }

    private func terminalKey(
        _ context: AgentTaskBridgeContext
    ) -> AgentTaskTerminalKey {
        AgentTaskTerminalKey(
            project: context.project,
            terminalID: context.route.terminalID
        )
    }

    private func taskIndex(for taskID: UUID) -> Int? {
        tasks.firstIndex { $0.id == taskID }
    }

    private func taskIndex(forRunID runID: UUID) -> Int? {
        guard let taskID = taskIDByRunID[runID] else { return nil }
        return taskIndex(for: taskID)
    }

    private func markDirty(taskID: UUID) {
        guard let task = task(for: taskID) else { return }
        markDirty(task.project)
    }

    private func markDirty(_ project: AgentTaskProjectIdentity) {
        if quarantinedProjects.contains(project) {
            unpersistableDirtyProjects.insert(project)
            return
        }
        guard !isTerminating || registeredProjects.contains(project) else {
            return
        }
        persistenceRevision[project] = UUID()
        dirtyProjects.insert(project)
        persistenceRetryBlocked.remove(project)
        scheduleSaveIfReady(project)
    }

    private func scheduleSaveIfReady(_ project: AgentTaskProjectIdentity) {
        guard registeredProjects.contains(project),
              loadedProjects.contains(project),
              !quarantinedProjects.contains(project),
              !persistenceRetryBlocked.contains(project),
              abandonedPersistenceTickets.count < abandonedPersistenceLimit,
              persistenceTail == nil,
              dirtyProjects.remove(project) != nil else {
            return
        }
        guard persistenceSequence < UInt64.max else {
            dirtyProjects.insert(project)
            return
        }
        persistenceSequence += 1
        let pendingInitialTaskIDs = Set<UUID>(
            pendingClaims.values.compactMap { claim in
                guard case .initialLaunch = claim.kind else { return nil }
                return claim.taskID
            }
        )
        // A Pine-owned task is not durable until authoritative process
        // evidence appends its first run. This covers both pre-ACK dormant and
        // post-ACK armed claims, including snapshots taken during Quit.
        let snapshot = tasks.filter {
            $0.project == project
                && !pendingInitialTaskIDs.contains($0.id)
        }
        let store = persistence
        let revision = persistenceRevision[project]
        let ticket = AgentTaskPersistenceTicket(
            generation: persistenceGeneration,
            sequence: persistenceSequence,
            projectKey: project.persistenceKey,
            expectedDiskRevision: diskRevisionByProject[project],
            nextDiskRevision: UUID()
        )
        publicationFence.authorize(ticket)
        let authorization = AgentTaskPublicationAuthorization(
            ticket: ticket,
            fence: publicationFence
        )
        saveResultByProject[project.persistenceKey] = nil
        persistenceTailTicket = ticket
        persistenceTail = Task { @MainActor [weak self] in
            defer { self?.abandonedPersistenceTickets.remove(ticket) }
            let result = await store.save(
                tasks: snapshot,
                project: project,
                authorization: authorization
            )
            guard let self else { return }
            if let published = publicationFence.publishedRevision(
                for: ticket.projectKey
            ) {
                diskRevisionByProject[project] = published
            }
            guard persistenceGeneration == ticket.generation else { return }
            completedPersistenceSequence = max(
                completedPersistenceSequence,
                ticket.sequence
            )
            switch result {
            case .saved:
                diskRevisionByProject[project] = .versioned(
                    ticket.nextDiskRevision
                )
            case .publishedButDurabilityUnknown(_, let revision):
                diskRevisionByProject[project] = .versioned(revision)
            case .rejected:
                break
            }
            let ownsTail = persistenceTailTicket == ticket
            if ownsTail {
                persistenceTail = nil
                persistenceTailTicket = nil
            }
            if persistenceRevision[project] == revision {
                saveResultByProject[project.persistenceKey] = result
                if !result.isDurablySaved {
                    dirtyProjects.insert(project)
                    persistenceRetryBlocked.insert(project)
                } else {
                    persistenceRetryBlocked.remove(project)
                }
            }
            if ownsTail {
                let pendingProjects = Array(dirtyProjects)
                pendingProjects.forEach(scheduleSaveIfReady)
            }
        }
    }

    private func abandonPersistenceTail() {
        persistenceTail?.cancel()
        if let persistenceTailTicket {
            abandonedPersistenceTickets.insert(persistenceTailTicket)
        }
        persistenceGeneration = UUID()
        let published = publicationFence.advance(to: persistenceGeneration)
        for project in registeredProjects {
            if let revision = published[project.persistenceKey] {
                diskRevisionByProject[project] = revision
            }
        }
        persistenceSequence = 0
        completedPersistenceSequence = 0
        persistenceTail = nil
        persistenceTailTicket = nil
        persistenceRetryBlocked.removeAll(keepingCapacity: true)
        for project in registeredProjects where !quarantinedProjects.contains(project) {
            dirtyProjects.insert(project)
            persistenceRevision[project] = UUID()
        }
    }

    private func advanceTaskChronology(at index: Int, through timestamp: Date) {
        tasks[index].updatedAt = max(tasks[index].updatedAt, timestamp)
        tasks[index].lastActivityAt = max(
            tasks[index].lastActivityAt,
            timestamp
        )
    }

    private func mappedEvidenceMatches(
        _ session: AgentSession,
        context: AgentTaskBridgeContext,
        taskID: UUID
    ) -> Bool {
        guard let task = task(for: taskID),
              task.project == context.project,
              task.route.terminalID == context.route.terminalID,
              task.descriptor.agentType == session.agentType,
              let run = task.runs.last,
              run.id == session.id,
              run.terminalID == context.route.terminalID,
              let evidence = session.processEvidence else { return false }
        return run.process.identifiesSameProcess(as: evidence)
    }

    private func detachCurrentOwner(
        for key: AgentTaskTerminalKey,
        at timestamp: Date
    ) {
        guard let taskID = taskIDByTerminal.removeValue(forKey: key),
              let task = task(for: taskID),
              let run = task.runs.last else { return }
        detachRun(sessionID: run.id, at: timestamp)
    }

    private func detachRun(sessionID: UUID, at timestamp: Date) {
        guard let index = taskIndex(forRunID: sessionID) else { return }
        let key = AgentTaskTerminalKey(
            project: tasks[index].project,
            terminalID: tasks[index].route.terminalID
        )
        endRun(sessionID: sessionID, at: timestamp)
        tasks[index].route.availability = .missing
        taskIDByRunID[sessionID] = nil
        taskIDByTerminal[key] = nil
        markDirty(tasks[index].project)
    }

    private func makeRoomForTask(
        in project: AgentTaskProjectIdentity
    ) -> Bool {
        let maximum = max(1, limits.maxTasksPerProject)
        while tasks.lazy.filter({ $0.project == project }).count >= maximum {
            guard let removalIndex = tasks.indices
                .filter({ tasks[$0].project == project })
                .filter({
                    tasks[$0].lifecycle == .completed
                        || tasks[$0].lifecycle == .dismissed
                })
                .min(by: {
                    tasks[$0].updatedAt < tasks[$1].updatedAt
                }) else {
                return false
            }
            removeTaskFromMemory(at: removalIndex)
        }
        return true
    }

    private func removeTaskFromMemory(at index: Int) {
        let task = tasks[index]
        let claimKeys = pendingClaims.compactMap { key, claim in
            claim.taskID == task.id ? key : nil
        }
        claimKeys.forEach { removeClaim(for: $0) }
        for run in task.runs {
            taskIDByRunID[run.id] = nil
        }
        taskIDByTerminal = taskIDByTerminal.filter { $0.value != task.id }
        loadedInterruptedTaskIDs.remove(task.id)
        terminationRollback[task.id] = nil
        tasks.remove(at: index)
    }

    private func acceptedProcessForNewRun(
        _ session: AgentSession
    ) -> AgentProcessEvidence? {
        guard historicalTaskIDByRunID[session.id] != nil
                || historicalTaskIDByRunID.count < limits.maxHistoricalRunIDs,
              let process = session.processEvidence,
              validUserText(
                  process.startIdentifier,
                  maximum: limits.maxProcessStartBytes
              ) else {
            return nil
        }
        return process
    }

    private func canMakeRoomForClaimRun(taskID: UUID) -> Bool {
        guard let index = taskIndex(for: taskID) else { return false }
        if canMakeRoomForRun(at: index) { return true }
        return loadedInterruptedTaskIDs.contains(taskID)
            && tasks[index].runs.indices.last != nil
    }

    private func canMakeRoomForRun(at taskIndex: Int) -> Bool {
        let maximum = max(1, limits.maxRunsPerTask)
        return tasks[taskIndex].runs.count < maximum
            || tasks[taskIndex].runs.contains(where: {
                $0.liveness == .terminated
            })
    }

    private func trimRunHistoryForAppend(at taskIndex: Int) {
        let maximum = max(1, limits.maxRunsPerTask)
        while tasks[taskIndex].runs.count >= maximum,
              let removalIndex = tasks[taskIndex].runs.firstIndex(where: {
                  $0.liveness == .terminated
              }) {
            let runID = tasks[taskIndex].runs.remove(at: removalIndex).id
            taskIDByRunID[runID] = nil
        }
    }

    private func validLaunchExecutable(_ descriptor: AgentDescriptor) -> Bool {
        guard let executable = descriptor.launchExecutable else { return true }
        return descriptor.agentType.cliNames.contains(executable)
            && executable.utf8.count <= limits.maxAgentIdentifierBytes
            && !executable.contains(where: { $0.isWhitespace })
            && !executable.contains("/")
            && !executable.contains("\0")
    }

    private func validUserText(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= maximum
            && !value.contains("\0")
    }

    private func normalizedLaunchBoundary(_ date: Date) -> Date { date }

    private func validLaunchRoute(_ route: AgentTaskRoute) -> Bool {
        route.terminalID == route.tabID && route.availability != .missing
    }

    private func isResumableTask(at index: Int) -> Bool {
        let task = tasks[index]
        guard task.origin == .pineLaunched,
              task.lifecycle == .paused,
              task.route.availability == .missing,
              let executable = task.descriptor.launchExecutable,
              task.descriptor.agentType.cliNames.contains(executable),
              !executable.contains(where: { $0.isWhitespace }),
              let tail = task.runs.last,
              resumableTail(tail, taskID: task.id) else {
            return false
        }
        return !pendingClaims.values.contains { $0.taskID == task.id }
    }

    private func resumableTail(_ run: AgentTaskRun, taskID: UUID) -> Bool {
        run.liveness == .terminated && run.endedAt != nil
            || loadedInterruptedTaskIDs.contains(taskID)
    }
}
