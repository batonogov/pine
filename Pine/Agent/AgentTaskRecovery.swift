//
//  AgentTaskRecovery.swift
//  Pine
//
//  Explicit, capability-gated recovery for durable agent tasks (#1307).
//

import Foundation

nonisolated enum AgentTaskRecoveryAction: Equatable, Sendable {
    /// Continue a vendor conversation only through a documented adapter.
    case resumeVendorSession
    /// Open a fresh shell in the original worktree. This is never described as
    /// continuing the previous vendor conversation.
    case startNewSession
}

nonisolated enum AgentTaskRecoveryUnavailableReason: Equatable, Sendable {
    case taskNotRecoverable
    case projectMissing
    case worktreeMissing
    case executableMissing
    case adapterUnavailable
    case vendorIdentityMissing
    case vendorIdentityInvalid
    case versionProbeFailed
    case versionChanged
}

/// An executable and argv are kept separate all the way to SwiftTerm. No
/// recovery path constructs a shell command string.
nonisolated struct AgentRecoveryProcess: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
}

nonisolated struct AgentTaskRecoveryPlan: Equatable, Sendable {
    let taskID: UUID
    let project: AgentTaskProjectIdentity
    let action: AgentTaskRecoveryAction
    let workingDirectory: URL
    let process: AgentRecoveryProcess?
    let objective: String?
}

nonisolated enum AgentTaskRecoveryEvaluation: Equatable, Sendable {
    case ready(AgentTaskRecoveryPlan)
    case unavailable(AgentTaskRecoveryUnavailableReason)
}

/// A reviewed adapter recipe. `identifierArgumentPrefix` and suffix are fixed
/// data; the opaque ID is inserted as exactly one argv element.
nonisolated struct AgentTaskResumeRecipe: Equatable, Sendable {
    let provider: String
    let agentTypeIdentifier: String
    let executableAliases: Set<String>
    let supportedVersions: Set<String>
    let identifierArgumentPrefix: [String]
    let identifierArgumentSuffix: [String]

    func arguments(opaqueIdentifier: String) -> [String] {
        identifierArgumentPrefix
            + [opaqueIdentifier]
            + identifierArgumentSuffix
    }
}

nonisolated struct AgentTaskRecoveryInspection: Equatable, Sendable {
    let projectExists: Bool
    let worktreeExists: Bool
    let resolvedExecutablePath: String?
    let executableVersion: String?
}

/// Pure recovery policy. Filesystem and process probing happen outside this
/// type, which makes every failure and race outcome deterministic in tests.
nonisolated enum AgentTaskRecoveryPlanner {
    static func evaluate(
        task: AgentTask,
        action: AgentTaskRecoveryAction,
        inspection: AgentTaskRecoveryInspection,
        recipes: [AgentTaskResumeRecipe]
    ) -> AgentTaskRecoveryEvaluation {
        guard task.runs.last?.liveness != .live else {
            return .unavailable(.taskNotRecoverable)
        }
        guard inspection.projectExists else {
            return .unavailable(.projectMissing)
        }
        guard inspection.worktreeExists else {
            return .unavailable(.worktreeMissing)
        }

        let directory = URL(
            fileURLWithPath: task.project.canonicalWorktreePath,
            isDirectory: true
        ).standardizedFileURL

        switch action {
        case .startNewSession:
            guard task.lifecycle == .paused || task.lifecycle == .completed else {
                return .unavailable(.taskNotRecoverable)
            }
            return .ready(AgentTaskRecoveryPlan(
                taskID: task.id,
                project: task.project,
                action: action,
                workingDirectory: directory,
                process: nil,
                objective: task.objective
            ))

        case .resumeVendorSession:
            guard task.lifecycle == .paused,
                  task.origin == .pineLaunched else {
                return .unavailable(.taskNotRecoverable)
            }
            guard let identity = task.runs.last?.vendorIdentity else {
                return .unavailable(.vendorIdentityMissing)
            }
            guard isSafeOpaqueValue(identity.provider, maximumBytes: 128),
                  isSafeOpaqueValue(
                      identity.opaqueIdentifier,
                      maximumBytes: 1_024
                  ) else {
                return .unavailable(.vendorIdentityInvalid)
            }
            guard let executable = inspection.resolvedExecutablePath else {
                return .unavailable(.executableMissing)
            }
            let executableName = URL(fileURLWithPath: executable)
                .lastPathComponent.lowercased()
            guard let recipe = recipes.first(where: {
                $0.provider == identity.provider
                    && $0.agentTypeIdentifier == task.descriptor.typeIdentifier
                    && $0.executableAliases.contains(executableName)
            }) else {
                return .unavailable(.adapterUnavailable)
            }
            guard let version = inspection.executableVersion else {
                return .unavailable(.versionProbeFailed)
            }
            guard let recordedVersion = identity.executableVersion else {
                return .unavailable(.versionProbeFailed)
            }
            if recordedVersion != version {
                return .unavailable(.versionChanged)
            }
            guard recipe.supportedVersions.contains(version) else {
                return .unavailable(.versionChanged)
            }
            return .ready(AgentTaskRecoveryPlan(
                taskID: task.id,
                project: task.project,
                action: action,
                workingDirectory: directory,
                process: AgentRecoveryProcess(
                    executablePath: executable,
                    arguments: recipe.arguments(
                        opaqueIdentifier: identity.opaqueIdentifier
                    )
                ),
                objective: task.objective
            ))
        }
    }

    private static func isSafeOpaqueValue(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}

/// Production inspection is deliberately bounded. The planner is run again
/// with these fresh values immediately before the user-requested launch.
nonisolated struct AgentTaskRecoveryInspector: Sendable {
    let resolver: ExternalToolResolver
    let processRunner: ProcessRunner
    let recipes: [AgentTaskResumeRecipe]

    init(
        resolver: ExternalToolResolver = .fromEnvironment(),
        processRunner: @escaping ProcessRunner = runRealProcess,
        recipes: [AgentTaskResumeRecipe] = []
    ) {
        self.resolver = resolver
        self.processRunner = processRunner
        self.recipes = recipes
    }

    func inspect(
        task: AgentTask,
        action: AgentTaskRecoveryAction
    ) async -> AgentTaskRecoveryEvaluation {
        let projectPath = task.project.canonicalProjectPath
        let worktreePath = task.project.canonicalWorktreePath
        let executableName = task.descriptor.launchExecutable
        let resolver = resolver
        let processRunner = processRunner

        let inspection = await Task.detached(priority: .userInitiated) {
            var isProjectDirectory: ObjCBool = false
            var isWorktreeDirectory: ObjCBool = false
            let fileManager = FileManager.default
            let projectExists = fileManager.fileExists(
                atPath: projectPath,
                isDirectory: &isProjectDirectory
            ) && isProjectDirectory.boolValue
            let worktreeExists = fileManager.fileExists(
                atPath: worktreePath,
                isDirectory: &isWorktreeDirectory
            ) && isWorktreeDirectory.boolValue

            guard action == .resumeVendorSession,
                  let executableName,
                  let executable = resolver.resolve(tool: executableName),
                  fileManager.isExecutableFile(atPath: executable) else {
                return AgentTaskRecoveryInspection(
                    projectExists: projectExists,
                    worktreeExists: worktreeExists,
                    resolvedExecutablePath: nil,
                    executableVersion: nil
                )
            }
            let result = processRunner(executable, ["--version"], "", 2)
            let version: String?
            if !result.timedOut, result.exitCode == 0 {
                let output = result.stdout.isEmpty ? result.stderr : result.stdout
                let candidate = output
                    .split(whereSeparator: \Character.isNewline)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                version = candidate?.isEmpty == false ? candidate : nil
            } else {
                version = nil
            }
            return AgentTaskRecoveryInspection(
                projectExists: projectExists,
                worktreeExists: worktreeExists,
                resolvedExecutablePath: executable,
                executableVersion: version
            )
        }.value

        return AgentTaskRecoveryPlanner.evaluate(
            task: task,
            action: action,
            inspection: inspection,
            recipes: recipes
        )
    }
}
