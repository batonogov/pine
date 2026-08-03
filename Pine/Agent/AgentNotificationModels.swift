//
//  AgentNotificationModels.swift
//  Pine
//
//  Privacy-bounded notification transitions for cross-project agent work.
//

import Foundation

nonisolated enum AgentNotificationEventKind: String, CaseIterable, Sendable {
    case waitingInput
    case failed
    case completed
    case processEnded
}

/// A value-only event whose identifier contains stable opaque identity and no
/// project path, command, prompt, output, or environment data.
nonisolated struct AgentNotificationEvent: Equatable, Sendable, Identifiable {
    let taskID: UUID
    let runID: UUID
    let processGeneration: UInt64
    let kind: AgentNotificationEventKind
    let observedAt: Date
    let agentName: String
    let projectName: String
    let taskTitle: String?
    let startedAt: Date

    var id: String {
        let milliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
        return [
            "pine-agent", taskID.uuidString, runID.uuidString,
            String(processGeneration), kind.rawValue, String(milliseconds),
        ].joined(separator: ".")
    }
}

enum AgentNotificationTransitionResolver {
    static func events(
        from oldTasks: [AgentTask],
        to newTasks: [AgentTask],
        accuracy: (String) -> FirstPartyAgentNotificationAccuracy
    ) -> [AgentNotificationEvent] {
        let previousByID = Dictionary(uniqueKeysWithValues: oldTasks.map { ($0.id, $0) })
        return newTasks.compactMap { task in
            guard let previous = previousByID[task.id],
                  task.lifecycle != .dismissed,
                  let oldRun = previous.runs.last,
                  let newRun = task.runs.last,
                  oldRun.id == newRun.id,
                  oldRun.process.processGeneration == newRun.process.processGeneration,
                  newRun.lastObservedAt >= oldRun.lastObservedAt,
                  newRun.liveness != .stale,
                  let kind = eventKind(
                      previousTask: previous,
                      task: task,
                      previousRun: oldRun,
                      run: newRun,
                      accuracy: accuracy(task.descriptor.typeIdentifier)
                  ) else {
                return nil
            }
            return AgentNotificationEvent(
                taskID: task.id,
                runID: newRun.id,
                processGeneration: newRun.process.processGeneration,
                kind: kind,
                observedAt: newRun.lastObservedAt,
                agentName: safeDisplayName(for: task),
                projectName: sanitizedProjectName(task.project.canonicalProjectPath),
                taskTitle: sanitizedTitle(task.title),
                startedAt: newRun.startedAt
            )
        }
    }

    private static func eventKind(
        previousTask: AgentTask,
        task: AgentTask,
        previousRun: AgentTaskRun,
        run: AgentTaskRun,
        accuracy: FirstPartyAgentNotificationAccuracy
    ) -> AgentNotificationEventKind? {
        switch accuracy {
        case .processTerminationOnly:
            guard previousRun.liveness == .live,
                  run.liveness == .terminated else { return nil }
            return .processEnded
        case .verifiedLifecycleTransitions:
            if task.attention == .failed,
               previousTask.attention != .failed {
                return .failed
            }
            let isCompleted = task.attention == .completed
                || task.lifecycle == .completed
                || run.state == .done
            let wasCompleted = previousTask.attention == .completed
                || previousTask.lifecycle == .completed
                || previousRun.state == .done
            if isCompleted, !wasCompleted { return .completed }
            if run.liveness == .live,
               run.state == .waitingInput,
               previousRun.state != .waitingInput {
                return .waitingInput
            }
            return nil
        }
    }

    private static func safeDisplayName(for task: AgentTask) -> String {
        guard let record = FirstPartyAgentCompatibilityCatalog.record(
            stableIdentifier: task.descriptor.typeIdentifier
        ) else { return "Agent" }
        return String(record.displayName.prefix(64))
    }

    private static func sanitizedProjectName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(name.prefix(80))
    }

    private static func sanitizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let value = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(120))
    }
}
