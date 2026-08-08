//
//  AgentPresenceController.swift
//  Pine
//
//  App-level visibility for background agent work (#1355).
//
//  Closing a project window backgrounds the project but keeps its terminals
//  and agents alive (`ProjectRegistry.closeProjectWindow`). Without a surface
//  that survives the last window, "I closed everything" silently becomes a
//  lie. This controller drives three macOS-visible signals from the same
//  `AgentTaskRegistry` mutation stream that feeds the per-window Agent Inbox
//  badge (#1337):
//
//    1. `NSApp.dockTile.badgeLabel` — the live agent-run count.
//    2. The sudden-termination guard — balanced across run start/stop cycles.
//
//  The Dock menu entries are built by `AppDelegate.applicationDockMenu`,
//  which reads the same registry through ``liveTasks(for:)`` below.
//

import AppKit
import Foundation

/// Testable side-effect seam for the Dock tile and the sudden-termination
/// guard. The production implementation touches `NSApp` and `ProcessInfo`;
/// tests inject a recording double to assert balanced calls and the exact
/// badge value without depending on AppKit state.
@MainActor
protocol AgentPresenceApplier: AnyObject {
    /// Sets the Dock badge to the live agent-run count. `0` clears it.
    func setDockBadge(count: Int)
    /// Disables sudden termination while at least one agent run is live and
    /// re-enables it when the last one ends. Calls must stay balanced.
    func setSuddenTerminationDisabled(_ disabled: Bool)
}

/// Production applier: writes `NSApp.dockTile.badgeLabel` and toggles the
/// sudden-termination guard on `ProcessInfo`. Both are main-thread surfaces.
@MainActor
final class AppKitAgentPresenceApplier: AgentPresenceApplier {
    func setDockBadge(count: Int) {
        // `badgeLabel` is `String?`. Setting `nil` removes the badge; a numeric
        // string renders as the red Dock counter. Assigning the property
        // redisplays the tile, so no explicit `display()` is required.
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    func setSuddenTerminationDisabled(_ disabled: Bool) {
        // Pine does not opt into sudden termination via Info.plist
        // (`NSSupportsSuddenTermination`), so these calls are forward-
        // compatible protection rather than an active toggle today: if Pine
        // ever enables it (or a system heuristic considers it), live agents
        // are never killed at logout/restart without the quit handshake.
        // The controller keeps its own bookkeeping so the paired calls always
        // balance to the agent-run lifecycle, never to each mutation.
        if disabled {
            ProcessInfo.processInfo.disableSuddenTermination()
        } else {
            ProcessInfo.processInfo.enableSuddenTermination()
        }
    }
}

/// Drives app-level visibility for background agent work from a single
/// `AgentTaskRegistry` observer.
///
/// One mutation rebuilds the live-run count and applies both signals in a
/// single pass. The live-run definition matches the Inbox `working` section
/// (`AgentInboxSnapshot`): `lifecycle == .active` with a live latest run,
/// regardless of window state, so a backgrounded project is still counted.
@MainActor
final class AgentPresenceController {
    private let registry: AgentTaskRegistry
    private let applier: any AgentPresenceApplier
    private var observerToken: UUID?
    private var isRunning = false
    // `-1` forces the first pass to publish even when the initial count is 0.
    private var lastLiveCount = -1
    private var suddenTerminationDisabled = false

    init(
        registry: AgentTaskRegistry,
        applier: any AgentPresenceApplier = AppKitAgentPresenceApplier()
    ) {
        self.registry = registry
        self.applier = applier
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observerToken = registry.addTaskChangeObserver { [weak self] _, tasks in
            self?.apply(tasks: tasks)
        }
        // Seed the initial state so a relaunch with durable, still-live tasks
        // re-arms the badge and guard without waiting for the next mutation.
        apply(tasks: registry.tasks)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observerToken { registry.removeTaskChangeObserver(observerToken) }
        observerToken = nil
        // Restore the baseline so a stop/start cycle never leaves the guard
        // disabled or a stale badge on the Dock.
        if suddenTerminationDisabled {
            suddenTerminationDisabled = false
            applier.setSuddenTerminationDisabled(false)
        }
        if lastLiveCount != 0 {
            lastLiveCount = 0
            applier.setDockBadge(count: 0)
        }
        lastLiveCount = -1
    }

    /// Pure projection: the number of agent runs currently executing across
    /// every project, including backgrounded ones. Mirrors the Inbox
    /// `working` section exactly so the Dock badge and the Inbox agree.
    nonisolated static func liveAgentRunCount(_ tasks: [AgentTask]) -> Int {
        tasks.count { task in
            task.lifecycle == .active && task.runs.last?.liveness == .live
        }
    }

    /// Pure projection of the live agent tasks the Dock menu should list, in
    /// the same newest-first order the Inbox `working` section renders, capped
    /// so an extreme fleet does not overflow the Dock menu.
    nonisolated static func liveTasks(
        for tasks: [AgentTask],
        limit: Int = 10
    ) -> [AgentTask] {
        let live = tasks.filter {
            $0.lifecycle == .active && $0.runs.last?.liveness == .live
        }
        let sorted = live.sorted(by: Self.rowPrecedes)
        return sorted.count > limit ? Array(sorted.prefix(limit)) : sorted
    }

    /// Dock menu title for a live agent task: agent name, objective, and the
    /// owning project's display name. Proper nouns are not localized, matching
    /// `recentProjectDisplayTitle`, so the title reads the same in any locale.
    /// `@MainActor` because `AgentDescriptor.agentType` resolves through the
    /// compatibility catalog on the main actor.
    static func dockMenuAgentTitle(for task: AgentTask) -> String {
        let agent = task.descriptor.agentType.displayName
        let projectName = URL(
            fileURLWithPath: task.project.canonicalProjectPath
        ).lastPathComponent
        let trimmedTitle = task.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            return "\(agent) — \(trimmedTitle) — \(projectName)"
        }
        return "\(agent) — \(projectName)"
    }

    private func apply(tasks: [AgentTask]) {
        guard isRunning else { return }
        let count = Self.liveAgentRunCount(tasks)
        guard count != lastLiveCount else { return }
        lastLiveCount = count
        applier.setDockBadge(count: count)
        // Disable exactly once on the 0→1 transition and re-enable exactly
        // once when the last run ends. The controller's own boolean keeps the
        // `ProcessInfo` reference count balanced across any sequence of
        // start/stop/mutation, independent of how many mutations fire.
        let shouldDisable = count > 0
        if shouldDisable != suddenTerminationDisabled {
            suddenTerminationDisabled = shouldDisable
            applier.setSuddenTerminationDisabled(shouldDisable)
        }
    }

    /// Sorts live tasks newest-first by run start, then by stable id, matching
    /// `AgentInboxSnapshot.rowPrecedes` so the Dock list and the Inbox read in
    /// the same order.
    nonisolated private static func rowPrecedes(_ lhs: AgentTask, _ rhs: AgentTask) -> Bool {
        let lhsStarted = lhs.runs.last?.startedAt ?? lhs.createdAt
        let rhsStarted = rhs.runs.last?.startedAt ?? rhs.createdAt
        if lhsStarted != rhsStarted { return lhsStarted > rhsStarted }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
