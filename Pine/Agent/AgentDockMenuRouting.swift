//
//  AgentDockMenuRouting.swift
//  Pine
//
//  Exact per-task routing for the Dock menu's live agent entries (#1492).
//
//  `AppDelegate.applicationDockMenu` builds one entry per live agent run
//  (#1355). Before this file every entry carried only `AgentTask.id` and every
//  click opened the general Agent Inbox, so a Dock full of distinct tasks
//  performed one indistinguishable action.
//
//  The projection below captures the same notification-grade identity the
//  user-notification path already routes with — task, run, and process
//  generation — so a Dock entry can only ever focus the exact process it was
//  rendered for. PID reuse, a replacement shell, or a newer run inside the same
//  task all change the identity, and the stored one stops matching. Navigation
//  itself is not reimplemented here: the identity is handed to the existing
//  `AgentNotificationRouteIdentity` authority, which fails closed to durable
//  Inbox history.
//
//  Privacy: an entry carries a title built from
//  ``AgentPresenceController/dockMenuAgentTitle(for:)`` (agent name, objective,
//  project display name) and three opaque Pine-owned identifiers. No prompt,
//  terminal output, token, absolute path, or opaque vendor session identifier
//  ever reaches the Dock.
//

import Foundation

/// One Dock entry for a live agent task: what it reads and where it routes.
nonisolated struct AgentDockMenuItem: Equatable, Sendable {
    let title: String
    let identity: AgentNotificationRouteIdentity
}

/// The action a Dock agent entry resolved to.
nonisolated enum AgentDockMenuRoute: Equatable, Sendable {
    /// Focus this exact task, run, and process generation.
    case task(AgentNotificationRouteIdentity)
    /// Fail closed: present the Agent Inbox and its truthful durable history.
    case inbox
}

@MainActor
enum AgentDockMenuRouting {
    /// Matches the Dock projection cap in ``AgentPresenceController/liveTasks(for:limit:)``.
    static let itemLimit = 10

    /// Notification-grade identity for one live task, or `nil` when the task
    /// has no live latest run.
    ///
    /// The identity is read from `runs.last` exactly as
    /// ``AgentTaskRegistry/matchesNotificationRoute(_:)`` reads it, so a
    /// captured entry validates against the same authority that admitted it.
    /// A paused, completed, dismissed, ended, or evidence-stale task never
    /// produces one: the Dock must not offer a route it cannot substantiate.
    nonisolated static func routeIdentity(
        for task: AgentTask
    ) -> AgentNotificationRouteIdentity? {
        guard task.lifecycle == .active,
              let run = task.runs.last,
              run.liveness == .live,
              run.endedAt == nil else {
            return nil
        }
        return AgentNotificationRouteIdentity(
            taskID: task.id,
            runID: run.id,
            processGeneration: run.process.processGeneration
        )
    }

    /// Dock entries for the live tasks, newest-first, capped so an extreme
    /// fleet cannot overflow the Dock menu. Order and cap match the Inbox
    /// `working` section via ``AgentPresenceController/liveTasks(for:limit:)``.
    static func items(
        for tasks: [AgentTask],
        limit: Int = itemLimit
    ) -> [AgentDockMenuItem] {
        AgentPresenceController.liveTasks(for: tasks, limit: limit)
            .compactMap { task in
                guard let identity = routeIdentity(for: task) else { return nil }
                return AgentDockMenuItem(
                    title: AgentPresenceController.dockMenuAgentTitle(for: task),
                    identity: identity
                )
            }
    }

    /// Whether a captured entry still describes the task's current live run.
    ///
    /// This is deliberately "re-render the entry and compare", not a second
    /// hand-written predicate: the Dock may navigate only when the row it
    /// would build right now is byte-for-byte the row the user selected. It is
    /// strictly stronger than
    /// ``AgentTaskRegistry/matchesNotificationRoute(_:)`` — which compares the
    /// latest run and generation but not lifecycle, liveness, or end time —
    /// and matches the preconditions
    /// `ProjectRegistry.navigateToAgentTaskFromInbox` enforces after every
    /// suspension, so it can only reject routes that would have failed later.
    nonisolated static func matchesCurrentRoute(
        _ identity: AgentNotificationRouteIdentity,
        task: AgentTask?
    ) -> Bool {
        guard let task, task.id == identity.taskID else { return false }
        return routeIdentity(for: task) == identity
    }

    /// Fail-closed decode of an `NSMenuItem.representedObject`.
    ///
    /// Only a full route identity is accepted. A bare task UUID — the value
    /// Dock entries carried before #1492 — a path, a string, or any other
    /// payload returns `nil` so the action degrades to the Inbox instead of
    /// guessing which session the user meant.
    nonisolated static func routeIdentity(
        fromRepresentedObject object: Any?
    ) -> AgentNotificationRouteIdentity? {
        object as? AgentNotificationRouteIdentity
    }
}
