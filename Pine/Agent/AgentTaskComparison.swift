//
//  AgentTaskComparison.swift
//  Pine
//
//  Fact-only comparison and explicit cross-agent handoff (#1309).
//

import Foundation

nonisolated struct AgentTaskComparisonCandidate: Sendable, Equatable {
    let taskID: UUID
    let worktreePath: String
    let agentTypeIdentifier: String
    let changedFiles: [AgentCompletionChange]
    let commands: [AgentCompletionCommand]
    let evidenceGaps: [AgentCompletionGap]
    let elapsedTime: TimeInterval?
    let verifiedTestCount: Int
    let failedCommandCount: Int
    let agentReportedNarrative: AgentCompletionNarrative?
}

/// Side-by-side facts have no score, rank, recommendation, or winner field.
/// Choosing a result is always a separate explicit user action.
nonisolated struct AgentTaskComparison: Sendable, Equatable {
    let objective: String?
    let left: AgentTaskComparisonCandidate
    let right: AgentTaskComparisonCandidate
}

nonisolated enum AgentTaskComparisonFailure: Error, Sendable, Equatable {
    case sameTask
    case differentProject
    case briefDoesNotBelongToTask(UUID)
}

@MainActor
enum AgentTaskComparisonBuilder {
    static func build(
        leftTask: AgentTask,
        leftBrief: AgentCompletionBrief,
        rightTask: AgentTask,
        rightBrief: AgentCompletionBrief
    ) -> Result<AgentTaskComparison, AgentTaskComparisonFailure> {
        guard leftTask.id != rightTask.id else { return .failure(.sameTask) }
        guard leftTask.project.canonicalProjectPath
                == rightTask.project.canonicalProjectPath else {
            return .failure(.differentProject)
        }
        guard brief(leftBrief, belongsTo: leftTask) else {
            return .failure(.briefDoesNotBelongToTask(leftTask.id))
        }
        guard brief(rightBrief, belongsTo: rightTask) else {
            return .failure(.briefDoesNotBelongToTask(rightTask.id))
        }
        let commonObjective = leftTask.objective == rightTask.objective
            ? leftTask.objective
            : nil
        return .success(AgentTaskComparison(
            objective: commonObjective,
            left: candidate(task: leftTask, brief: leftBrief),
            right: candidate(task: rightTask, brief: rightBrief)
        ))
    }

    private static func brief(
        _ brief: AgentCompletionBrief,
        belongsTo task: AgentTask
    ) -> Bool {
        task.runs.contains { $0.id == brief.sessionID }
            && task.descriptor.typeIdentifier == brief.agentTypeRaw
    }

    private static func candidate(
        task: AgentTask,
        brief: AgentCompletionBrief
    ) -> AgentTaskComparisonCandidate {
        let elapsed = brief.endedAt.map {
            max(0, $0.timeIntervalSince(brief.startedAt))
        }
        return AgentTaskComparisonCandidate(
            taskID: task.id,
            worktreePath: task.project.canonicalWorktreePath,
            agentTypeIdentifier: task.descriptor.typeIdentifier,
            changedFiles: brief.changes,
            commands: brief.commands,
            evidenceGaps: brief.gaps,
            elapsedTime: elapsed,
            verifiedTestCount: brief.verifiedTestCount,
            failedCommandCount: brief.commands.lazy.filter {
                if case .failed = $0.outcome { return true }
                return false
            }.count,
            agentReportedNarrative: brief.narrative
        )
    }
}

nonisolated struct AgentTaskHandoffRequest: Sendable, Equatable {
    let sourceTaskID: UUID
    let targetTaskID: UUID
    let sourceCompletionBriefID: UUID
    /// Fresh text authored by the user for this handoff. Pine never copies the
    /// source task objective, credentials, environment, or transcript here.
    let followUpObjective: String
    let selectedEvidencePaths: [String]
}

nonisolated struct AgentTaskHandoffAttribution: Sendable, Equatable {
    let relativePath: String
    let sourceTaskID: UUID
    let sourceSessionID: UUID
    let originalEvidence: AgentCompletionEvidenceLevel
}

nonisolated struct AgentTaskHandoffPackage: Sendable, Equatable, Identifiable {
    let id: UUID
    let sourceTaskID: UUID
    let targetTaskID: UUID
    let sourceCompletionBriefID: UUID
    let createdAt: Date
    let followUpObjective: String
    let priorAttribution: [AgentTaskHandoffAttribution]

    /// Deliberate schema guarantee: there is no transcript, environment,
    /// credential, command output, or copied agent narrative in this package.
}

nonisolated enum AgentTaskHandoffFailure: Error, Sendable, Equatable {
    case sameTask
    case taskMismatch
    case differentProject
    case sourceBriefMismatch
    case invalidObjective
    case invalidEvidencePath(String)
    case evidencePathNotInBrief(String)
    case resourceLimitExceeded
}

nonisolated enum AgentTaskHandoffPlanner {
    private static let maximumObjectiveBytes = 64 * 1_024
    private static let maximumEvidencePaths = 10_000

    static func prepare(
        request: AgentTaskHandoffRequest,
        sourceTask: AgentTask,
        targetTask: AgentTask,
        sourceBrief: AgentCompletionBrief,
        handoffID: UUID = UUID(),
        createdAt: Date = Date()
    ) -> Result<AgentTaskHandoffPackage, AgentTaskHandoffFailure> {
        guard sourceTask.id != targetTask.id else { return .failure(.sameTask) }
        guard request.sourceTaskID == sourceTask.id,
              request.targetTaskID == targetTask.id else {
            return .failure(.taskMismatch)
        }
        guard sourceTask.project.canonicalProjectPath
                == targetTask.project.canonicalProjectPath else {
            return .failure(.differentProject)
        }
        guard request.sourceCompletionBriefID == sourceBrief.id,
              sourceTask.runs.contains(where: {
                  $0.id == sourceBrief.sessionID
              }) else {
            return .failure(.sourceBriefMismatch)
        }
        let objective = request.followUpObjective.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !objective.isEmpty,
              objective.utf8.count <= maximumObjectiveBytes,
              !objective.utf8.contains(0),
              !objective.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      && $0 != "\n" && $0 != "\t"
              }) else {
            return .failure(.invalidObjective)
        }
        guard request.selectedEvidencePaths.count <= maximumEvidencePaths else {
            return .failure(.resourceLimitExceeded)
        }

        var changesByPath: [String: AgentCompletionChange] = [:]
        for change in sourceBrief.changes
        where changesByPath[change.relativePath] == nil {
            changesByPath[change.relativePath] = change
        }
        var seen: Set<String> = []
        var attributions: [AgentTaskHandoffAttribution] = []
        for path in request.selectedEvidencePaths {
            guard AgentHistoryUndoPreflight.isCanonicalRelativePath(path),
                  seen.insert(path).inserted else {
                return .failure(.invalidEvidencePath(path))
            }
            guard let change = changesByPath[path] else {
                return .failure(.evidencePathNotInBrief(path))
            }
            attributions.append(AgentTaskHandoffAttribution(
                relativePath: path,
                sourceTaskID: sourceTask.id,
                sourceSessionID: sourceBrief.sessionID,
                originalEvidence: change.attribution
            ))
        }

        return .success(AgentTaskHandoffPackage(
            id: handoffID,
            sourceTaskID: sourceTask.id,
            targetTaskID: targetTask.id,
            sourceCompletionBriefID: sourceBrief.id,
            createdAt: createdAt,
            followUpObjective: objective,
            priorAttribution: attributions
        ))
    }
}
