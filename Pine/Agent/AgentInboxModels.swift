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
    let surface: AgentTaskTerminalSurface
    let projectPath: String
    let worktreePath: String
    let projectName: String
    let worktreeName: String?
    let terminalLabel: String
    let title: String?
    let agentName: String
    let lifecycle: AgentTaskLifecycle
    let state: AgentRunState?
    let liveness: AgentRunLiveness?
    let routeAvailability: AgentTaskRouteAvailability
    let startedAt: Date
    let lastVerifiedActivityAt: Date
    let isUnread: Bool

    var canNavigateToLiveRun: Bool {
        lifecycle == .active
            && liveness == .live
            && routeAvailability != .missing
    }

    var canRecover: Bool {
        surface == .projectWindow
            && !canNavigateToLiveRun
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
        let visibleTasks = tasks.filter { $0.lifecycle != .dismissed }
        let projectBackedTasks = visibleTasks.filter {
            $0.route.surface.isProjectBacked
        }
        let projectNames = Self.shortestUniquePathLabels(
            projectBackedTasks.map(\.project.canonicalProjectPath)
        )
        // Worktrees form their own label namespace. A worktree basename must
        // neither widen a project label nor be widened by one.
        let worktreeNames = Self.shortestUniquePathLabels(
            projectBackedTasks.compactMap { task in
                task.project.canonicalWorktreePath
                    == task.project.canonicalProjectPath
                    ? nil
                    : task.project.canonicalWorktreePath
            }
        )
        let terminalScopes = Dictionary(
            grouping: visibleTasks,
            by: Self.terminalLabelScope
        )
        let terminalIDsByScope = terminalScopes.mapValues { tasks in
            Set(tasks.map(\.route.terminalID))
        }
        let terminalTokensByScope = terminalIDsByScope.mapValues { identifiers in
            Self.uniqueOpaqueTokens(Array(identifiers))
        }

        var grouped: [AgentInboxSectionID: [AgentInboxRow]] = [:]
        for task in visibleTasks {
            let latestRun = task.runs.last
            let section = Self.section(
                for: task,
                latestRun: latestRun,
                accuracyPolicy: accuracyPolicy
            )
            grouped[section, default: []].append(AgentInboxRow(
                id: task.id,
                section: section,
                surface: task.route.surface,
                projectPath: task.route.surface.isProjectBacked
                    ? task.project.canonicalProjectPath
                    : "",
                worktreePath: task.route.surface.isProjectBacked
                    ? task.project.canonicalWorktreePath
                    : "",
                projectName: Self.projectName(
                    for: task,
                    projectNames: projectNames
                ),
                worktreeName: task.route.surface.isProjectBacked
                    ? worktreeNames[task.project.canonicalWorktreePath]
                    : nil,
                terminalLabel: Self.terminalLabel(
                    for: task,
                    terminalIDsByScope: terminalIDsByScope,
                    tokensByScope: terminalTokensByScope
                ),
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

    private struct TerminalLabelScope: Hashable {
        let project: AgentTaskProjectIdentity
        let surface: AgentTaskTerminalSurface
        let source: TerminalLabelSource
    }

    private enum TerminalLabelSource: Hashable {
        case stable(String)
        case legacyFallback
    }

    private static func terminalLabelScope(
        for task: AgentTask
    ) -> TerminalLabelScope {
        TerminalLabelScope(
            project: task.project,
            surface: task.route.surface,
            source: task.presentationContext.map {
                .stable($0.terminalLabel)
            } ?? .legacyFallback
        )
    }

    @MainActor
    private static func terminalLabel(
        for task: AgentTask,
        terminalIDsByScope: [TerminalLabelScope: Set<UUID>],
        tokensByScope: [TerminalLabelScope: [UUID: String]]
    ) -> String {
        if task.route.surface == .quickTerminalStandalone {
            return task.presentationContext?.terminalLabel
                ?? Strings.quickTerminalText()
        }
        let scope = terminalLabelScope(for: task)
        let token = tokensByScope[scope]?[task.route.terminalID]
            ?? task.route.terminalID.uuidString
        guard let stableLabel = task.presentationContext?.terminalLabel else {
            return "\(Strings.terminalLabelText()) #\(token)"
        }
        guard terminalIDsByScope[scope, default: []].count > 1 else {
            return stableLabel
        }
        return "\(stableLabel) · #\(token)"
    }

    @MainActor
    private static func projectName(
        for task: AgentTask,
        projectNames: [String: String]
    ) -> String {
        guard task.route.surface.isProjectBacked else {
            return task.presentationContext?.terminalLabel
                ?? Strings.quickTerminalText()
        }
        return projectNames[task.project.canonicalProjectPath]
            ?? task.project.canonicalProjectPath
    }

    /// Returns deterministic shortest trailing path suffixes. Equal canonical
    /// paths are one identity, so repeated rows never widen each other's label.
    private static func shortestUniquePathLabels(
        _ paths: [String]
    ) -> [String: String] {
        let identities = Array(Set(paths)).sorted()
        let components = Dictionary(uniqueKeysWithValues: identities.map {
            ($0, pathComponents($0))
        })
        var depths = Dictionary(uniqueKeysWithValues: identities.map {
            ($0, min(1, components[$0, default: []].count))
        })

        while true {
            let collisions = Dictionary(grouping: identities) { path in
                pathSuffix(
                    components[path, default: []],
                    depth: depths[path, default: 0]
                )
            }.values.filter { $0.count > 1 }
            var expanded = false
            for collision in collisions {
                for path in collision {
                    let maximum = components[path, default: []].count
                    guard depths[path, default: 0] < maximum else { continue }
                    depths[path, default: 0] += 1
                    expanded = true
                }
            }
            if !expanded { break }
        }

        return Dictionary(uniqueKeysWithValues: identities.map { path in
            (
                path,
                pathSuffix(
                    components[path, default: []],
                    depth: depths[path, default: 0]
                )
            )
        })
    }

    private static func pathComponents(_ path: String) -> [String] {
        (path as NSString).pathComponents.filter { $0 != "/" }
    }

    private static func pathSuffix(
        _ components: [String],
        depth: Int
    ) -> String {
        guard !components.isEmpty else { return "/" }
        return components.suffix(max(1, depth)).joined(separator: "/")
    }

    /// UUIDs are opaque presentation tokens. Start compact, then expand every
    /// colliding prefix until it is unique within the caller's exact scope.
    private static func uniqueOpaqueTokens(
        _ identifiers: [UUID]
    ) -> [UUID: String] {
        let unique = Array(Set(identifiers)).sorted {
            $0.uuidString < $1.uuidString
        }
        let compact = Dictionary(uniqueKeysWithValues: unique.map {
            ($0, $0.uuidString.replacingOccurrences(of: "-", with: ""))
        })
        var lengths = Dictionary(uniqueKeysWithValues: unique.map { ($0, 6) })
        while true {
            let collisions = Dictionary(grouping: unique) { identifier in
                String(compact[identifier, default: ""].prefix(
                    lengths[identifier, default: 6]
                ))
            }.values.filter { $0.count > 1 }
            var expanded = false
            for collision in collisions {
                for identifier in collision {
                    let maximum = compact[identifier, default: ""].count
                    guard lengths[identifier, default: 6] < maximum else {
                        continue
                    }
                    lengths[identifier, default: 6] += 1
                    expanded = true
                }
            }
            if !expanded { break }
        }
        return Dictionary(uniqueKeysWithValues: unique.map { identifier in
            (
                identifier,
                String(compact[identifier, default: ""].prefix(
                    lengths[identifier, default: 6]
                ))
            )
        })
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
