// Test-host-only observation of the real recovery and terminal boundaries.
#if PINE_TEST_HOST
import Foundation
import Observation

@MainActor
@Observable
final class RecoveryUITestEvidence {
    static let shared = RecoveryUITestEvidence()
    var processLaunches: [UUID] = []
    var processStarts: [UUID] = []
    var inputDispatches: [UUID] = []

    private struct Run: Encodable {
        let id: UUID
        let terminalID: UUID
        let startedAt: Date
        let endedAt: Date?
        let outcome: AgentTaskOutcome?
    }

    private struct TaskHistory: Encodable {
        let id: UUID
        let createdAt: Date
        let runs: [Run]
    }

    private struct Snapshot: Encodable {
        let tasks: [TaskHistory]
        let loadStatuses: [String]
        let processLaunches: [UUID]
        let processStarts: [UUID]
        let inputDispatches: [UUID]
    }

    func snapshot(registry: ProjectRegistry) -> String {
        let value = Snapshot(
            tasks: registry.agentTasks.tasks.map { task in
                TaskHistory(id: task.id, createdAt: task.createdAt, runs: task.runs.map {
                    Run(id: $0.id, terminalID: $0.terminalID, startedAt: $0.startedAt,
                        endedAt: $0.endedAt, outcome: $0.outcome)
                })
            },
            loadStatuses: registry.agentTasks.loadStatusByProject.values.map {
                String(describing: $0)
            }.sorted(),
            processLaunches: processLaunches,
            processStarts: processStarts,
            inputDispatches: inputDispatches
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
#endif
