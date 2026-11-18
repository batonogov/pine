//
//  AgentTaskSettingsIsolation.swift
//  Pine
//
//  Settings and service isolation for concurrent ADE tasks (#1728, CLI
//  capability audit additions 2026-11-14).
//

import Foundation

/// The scope of one mutable setting or service relative to a task launch.
///
/// A distinct session ID by itself isolates nothing: it names a PTY, not the
/// credentials, forwarded MCP definitions, approval policy, or backend
/// startup flags the session inherits. The scope recorded here is what the
/// compatibility decision below trusts.
nonisolated enum AgentTaskSettingsScope: String, Codable, Sendable, CaseIterable {
    /// One terminal/PTY session, recreated per launch.
    case session
    /// One worktree or project directory, owned per task environment.
    case directory
    /// A process owned by the launch itself.
    case ownedProcess
    /// A provider account shared by every launch on the machine.
    case account
    /// Machine- or user-global state shared by every launch.
    case global
}

/// Recorded scope and isolation behavior of one mutable setting/service.
nonisolated struct AgentTaskSettingDefinition: Equatable, Identifiable, Sendable {
    let name: String
    let scope: AgentTaskSettingsScope
    /// Whether one launch can vary this independently of concurrent
    /// launches. Directory- and owned-process-scoped settings are isolated;
    /// account- and global-scoped settings are not.
    let isolatedAcrossConcurrentLaunches: Bool
    /// Whether conflicting concurrent operations on this setting can be
    /// serialized safely. When false, a conflicting combination must be
    /// exposed as concretely unsupported, never promised safe.
    let serializableWhenConflicting: Bool

    var id: String { name }
}

/// The recorded scope of each mutable setting/service (#1728 audit).
///
/// This is the owner map: every launch or settings change that touches one
/// of these names flows through the compatibility decision, and any new
/// mutable setting must be added here before two concurrent launches may
/// vary it.
nonisolated enum AgentTaskSettingsIsolationTable {
    static let known: [AgentTaskSettingDefinition] = [
        .init(
            name: "terminalEnvironment",
            scope: .session,
            isolatedAcrossConcurrentLaunches: true,
            serializableWhenConflicting: true
        ),
        .init(
            name: "workingDirectory",
            scope: .directory,
            isolatedAcrossConcurrentLaunches: true,
            serializableWhenConflicting: true
        ),
        .init(
            name: "worktreeLocalGitConfig",
            scope: .directory,
            isolatedAcrossConcurrentLaunches: true,
            serializableWhenConflicting: true
        ),
        .init(
            name: "derivedDataPath",
            scope: .ownedProcess,
            isolatedAcrossConcurrentLaunches: true,
            serializableWhenConflicting: true
        ),
        .init(
            name: "launchCommandLineFlags",
            scope: .ownedProcess,
            isolatedAcrossConcurrentLaunches: true,
            serializableWhenConflicting: true
        ),
        .init(
            name: "globalGitConfig",
            scope: .global,
            isolatedAcrossConcurrentLaunches: false,
            serializableWhenConflicting: false
        ),
        .init(
            name: "agentNativeConfiguration",
            scope: .global,
            isolatedAcrossConcurrentLaunches: false,
            serializableWhenConflicting: true
        ),
        .init(
            name: "mcpServerDefinitions",
            scope: .global,
            isolatedAcrossConcurrentLaunches: false,
            serializableWhenConflicting: false
        ),
        .init(
            name: "approvalPolicy",
            scope: .global,
            isolatedAcrossConcurrentLaunches: false,
            serializableWhenConflicting: true
        ),
        .init(
            name: "providerCredentials",
            scope: .account,
            isolatedAcrossConcurrentLaunches: false,
            serializableWhenConflicting: false
        ),
        .init(
            name: "providerAccountBilling",
            scope: .account,
            isolatedAcrossConcurrentLaunches: false,
            serializableWhenConflicting: false
        ),
    ]

    static func definition(named name: String) -> AgentTaskSettingDefinition? {
        known.first { $0.name == name }
    }
}

/// One launch's immutable settings, captured at spawn time.
///
/// A settings change after capture produces new values and never rewrites an
/// existing snapshot: one task's launch or settings change cannot silently
/// change another task's or reviewer's recorded effective settings. Re-
/// validation (for example before try-the-result) compares the live setting
/// against the snapshot and fails closed on any difference.
nonisolated struct AgentTaskLaunchSettings: Equatable, Sendable {
    static let maximumEntries = 32
    static let maximumKeyBytes = 128
    static let maximumValueBytes = 4_096

    let taskID: UUID
    let runID: UUID
    let launchGeneration: UInt64
    let values: [String: String]

    /// Shape validation of one launch's settings. Not called by this slice:
    /// it is enforced at the #1811 integration's snapshot capture, where
    /// settings first flow from the launch configuration into this value.
    static func isValid(
        values: [String: String]
    ) -> Bool {
        guard values.count <= maximumEntries else { return false }
        for (key, value) in values {
            guard !key.isEmpty, key.utf8.count <= maximumKeyBytes else { return false }
            guard value.utf8.count <= maximumValueBytes else { return false }
            if key.unicodeScalars.contains(where: { $0.value < 32 })
                || value.unicodeScalars.contains(where: { $0.value < 32 }) {
                return false
            }
        }
        return true
    }
}

nonisolated enum AgentTaskSettingsCompatibility: Equatable, Sendable {
    /// The two launches vary no shared non-isolated setting to different
    /// values and may run concurrently.
    case concurrent
    /// A conflict exists on a setting whose conflicting operations can be
    /// serialized; the launches must not run at the same time on that
    /// setting.
    case serialized
    /// A conflict exists on a setting that cannot be isolated or serialized;
    /// the combination is concretely unsupported and must be presented as
    /// such, never run "safely".
    case unsupported(conflicting: [String])
}

nonisolated enum AgentTaskSettingsIsolation {
    /// Decides whether two launches may run concurrently given the settings
    /// each varies. Fail closed: an unknown setting name is treated as
    /// non-isolated and non-serializable, and equal values never conflict.
    static func compatibility(
        of first: AgentTaskLaunchSettings,
        and second: AgentTaskLaunchSettings
    ) -> AgentTaskSettingsCompatibility {
        let shared = Set(first.values.keys)
            .intersection(second.values.keys)
            .filter { first.values[$0] != second.values[$0] }
            .sorted()
        var serializing: [String] = []
        var unsupported: [String] = []
        for name in shared {
            let definition = AgentTaskSettingsIsolationTable.definition(named: name)
            if let definition, definition.isolatedAcrossConcurrentLaunches {
                continue
            }
            if let definition, definition.serializableWhenConflicting {
                serializing.append(name)
            } else {
                unsupported.append(name)
            }
        }
        if !unsupported.isEmpty { return .unsupported(conflicting: unsupported) }
        if !serializing.isEmpty { return .serialized }
        return .concurrent
    }
}

/// Ownership of a child job observed after its parent turn has ended.
///
/// Unknown ownership stays unknown: Pine never re-attributes or reaps a job
/// it cannot tie to an exact task, attempt, and launch generation.
nonisolated enum AgentTaskChildJobOwnership: Hashable, Sendable {
    case owned(taskID: UUID, runID: UUID, launchGeneration: UInt64)
    case unknown
}

nonisolated enum AgentTaskDescendantTeardown {
    /// The jobs a cancellation or relaunch teardown may stop: exactly the
    /// owned descendants of the torn-down task, attempt, and launch
    /// generation. Shared services, unrelated tasks' jobs, and jobs of
    /// unknown ownership are preserved.
    static func teardownTargets(
        jobs: [UUID: AgentTaskChildJobOwnership],
        taskID: UUID,
        runID: UUID,
        launchGeneration: UInt64
    ) -> Set<UUID> {
        jobs.reduce(into: Set<UUID>()) { targets, entry in
            guard case .owned(let ownerTask, let ownerRun, let ownerGeneration) =
                entry.value else { return }
            if ownerTask == taskID, ownerRun == runID, ownerGeneration == launchGeneration {
                targets.insert(entry.key)
            }
        }
    }
}
