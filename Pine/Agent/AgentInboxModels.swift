//
//  AgentInboxModels.swift
//  Pine
//
//  Value-only cross-project Agent Inbox projection (#1305).
//

import Foundation

nonisolated enum AgentInboxSectionID: String, CaseIterable, Sendable {
    case needsAttention
    case failed
    case completedUnread
    case working
    case history
}

nonisolated struct AgentInboxRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let section: AgentInboxSectionID
    let projectPath: String
    let worktreePath: String
    let title: String?
    let agentName: String
    let lifecycle: AgentTaskLifecycle
    let state: AgentRunState?
    let liveness: AgentRunLiveness?
    let routeAvailability: AgentTaskRouteAvailability
    let startedAt: Date
    let lastVerifiedActivityAt: Date
    let isUnread: Bool

    var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    var worktreeName: String? {
        guard worktreePath != projectPath else { return nil }
        return URL(fileURLWithPath: worktreePath).lastPathComponent
    }

    var canNavigateToLiveRun: Bool {
        lifecycle == .active
            && liveness == .live
            && routeAvailability != .missing
    }

    var canRecover: Bool {
        !canNavigateToLiveRun
            && (lifecycle == .paused || lifecycle == .completed)
            && liveness != .live
    }
}

nonisolated struct AgentInboxSection: Identifiable, Equatable, Sendable {
    let id: AgentInboxSectionID
    let rows: [AgentInboxRow]
}

nonisolated struct AgentInboxSnapshot: Equatable, Sendable {
    let sections: [AgentInboxSection]

    var rows: [AgentInboxRow] {
        sections.flatMap(\.rows)
    }

    var isEmpty: Bool { rows.isEmpty }

    /// Creates a deterministic, privacy-preserving presentation snapshot.
    /// It deliberately projects metadata only: prompts and terminal output do
    /// not exist on the durable task model and cannot leak into the Inbox.
    @MainActor
    init(
        tasks: [AgentTask],
        accuracyPolicy: AgentLifecycleAccuracyPolicy = .production
    ) {
        var grouped: [AgentInboxSectionID: [AgentInboxRow]] = [:]
        for task in tasks where task.lifecycle != .dismissed {
            let latestRun = task.runs.last
            let section = Self.section(
                for: task,
                latestRun: latestRun,
                accuracyPolicy: accuracyPolicy
            )
            grouped[section, default: []].append(AgentInboxRow(
                id: task.id,
                section: section,
                projectPath: task.project.canonicalProjectPath,
                worktreePath: task.project.canonicalWorktreePath,
                title: task.title,
                agentName: task.descriptor.agentType.displayName,
                lifecycle: task.lifecycle,
                state: Self.userFacingState(
                    for: task,
                    latestRun: latestRun,
                    accuracyPolicy: accuracyPolicy
                ),
                liveness: latestRun?.liveness,
                routeAvailability: task.route.availability,
                startedAt: latestRun?.startedAt ?? task.createdAt,
                lastVerifiedActivityAt:
                    latestRun?.lastObservedAt ?? task.lastActivityAt,
                isUnread: task.isUnread
            ))
        }

        sections = AgentInboxSectionID.allCases.compactMap { id in
            guard var rows = grouped[id], !rows.isEmpty else { return nil }
            rows.sort(by: Self.rowPrecedes)
            return AgentInboxSection(id: id, rows: rows)
        }
    }

    private static func section(
        for task: AgentTask,
        latestRun: AgentTaskRun?,
        accuracyPolicy: AgentLifecycleAccuracyPolicy
    ) -> AgentInboxSectionID {
        if task.attention == .waitingInput,
           latestRun?.liveness == .live,
           latestRun.map({
               accuracyPolicy.permitsUserFacingAttention(
                   for: task.descriptor.typeIdentifier,
                   evidence: $0.lifecycleAccuracy
               )
           }) == true {
            return .needsAttention
        }
        if task.attention == .failed, task.isUnread {
            return .failed
        }
        if task.isUnread,
           task.attention == .completed || task.lifecycle == .completed {
            return .completedUnread
        }
        if task.lifecycle == .active, latestRun?.liveness == .live {
            return .working
        }
        return .history
    }

    private static func userFacingState(
        for task: AgentTask,
        latestRun: AgentTaskRun?,
        accuracyPolicy: AgentLifecycleAccuracyPolicy
    ) -> AgentRunState? {
        guard let latestRun else { return nil }
        guard latestRun.state == .waitingInput,
              !accuracyPolicy.permitsUserFacingAttention(
                for: task.descriptor.typeIdentifier,
                evidence: latestRun.lifecycleAccuracy
              ) else {
            return latestRun.state
        }
        return .idle
    }

    private static func rowPrecedes(
        _ lhs: AgentInboxRow,
        _ rhs: AgentInboxRow
    ) -> Bool {
        if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
        // Sort by the run's start time, not the polling-driven
        // `lastVerifiedActivityAt`. `startedAt` is write-once stable for an
        // existing row, so rows never re-order on every detection poll —
        // which previously made the list flicker when a single missed poll
        // inverted two tasks' activity timestamps (#1336).
        // `lastVerifiedActivityAt` is retained on the row for display only.
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
