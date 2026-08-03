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
    init(tasks: [AgentTask]) {
        var grouped: [AgentInboxSectionID: [AgentInboxRow]] = [:]
        for task in tasks where task.lifecycle != .dismissed {
            let latestRun = task.runs.last
            let section = Self.section(for: task, latestRun: latestRun)
            grouped[section, default: []].append(AgentInboxRow(
                id: task.id,
                section: section,
                projectPath: task.project.canonicalProjectPath,
                worktreePath: task.project.canonicalWorktreePath,
                title: task.title,
                agentName: task.descriptor.agentType.displayName,
                lifecycle: task.lifecycle,
                state: latestRun?.state,
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
        latestRun: AgentTaskRun?
    ) -> AgentInboxSectionID {
        if task.attention == .waitingInput,
           latestRun?.liveness == .live {
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

    private static func rowPrecedes(
        _ lhs: AgentInboxRow,
        _ rhs: AgentInboxRow
    ) -> Bool {
        if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
        if lhs.lastVerifiedActivityAt != rhs.lastVerifiedActivityAt {
            return lhs.lastVerifiedActivityAt > rhs.lastVerifiedActivityAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
