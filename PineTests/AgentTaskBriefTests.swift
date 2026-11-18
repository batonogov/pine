import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Explicit task brief")
struct AgentTaskBriefTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func task() -> AgentTask {
        let terminalID = UUID()
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: AgentTaskBridgeContext(
                project: AgentTaskProjectIdentity(
                    canonicalProjectPath: "/project", canonicalWorktreePath: "/project"
                ),
                route: AgentTaskRoute(paneID: UUID(), tabID: terminalID, terminalID: terminalID),
                origin: .pineLaunched, observedAt: now
            ),
            objective: "User-approved objective"
        )
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: UUID(), terminalID: terminalID,
            process: AgentProcessEvidence(
                processIdentifier: nil, processGeneration: 1,
                startIdentifier: nil, observedStartedAt: now
            ),
            status: AgentTaskRunStatus(state: .idle, liveness: .stale, observedAt: now)
        ))]
        return task
    }

    private func record(
        task: AgentTask, id: UUID = UUID(), revision: UInt64 = 1,
        reference: String = "redacted-decision-id"
    ) -> AgentTaskDecisionReference {
        AgentTaskDecisionReference(
            id: id, kind: .decision, reference: reference,
            runID: task.runs[0].id, revision: revision, recordedAt: now
        )
    }

    @Test func briefIsFactualAndDoesNotResolveReferencesImplicitly() {
        var task = task()
        let decision = record(task: task)
        task.decisionReferences = [decision]
        task.verificationState = .stale
        let brief = AgentTaskBrief(task: task)
        #expect(brief.objective == task.objective)
        #expect(brief.latestAttempt == task.runs.last)
        #expect(brief.latestAttempt?.outcome == nil)
        #expect(brief.verification == .stale)
        #expect(brief.annotations[0].state == .notResolved)
        #expect(brief.annotations[0].attemptRetained)

        task.runs = []
        let missing = AgentTaskBrief(task: task, referenceStates: [decision.id: .expired])
        #expect(missing.annotations[0].state == .expired)
        #expect(!missing.annotations[0].attemptRetained)
        #expect(missing.annotations[0].record == decision)
    }

    @Test func explicitAnnotationsCanBeCorrectedAndRemovedWithConflictDetection() {
        let task = task()
        let registry = AgentTaskRegistry(persistence: BriefStore())
        registry.setTasksForTesting([task])
        let decision = record(task: task)
        #expect(registry.setDecisionReference(decision, expectedRevision: nil, taskID: task.id))
        let corrected = record(task: task, id: decision.id, revision: 2, reference: "corrected-id")
        #expect(!registry.setDecisionReference(corrected, expectedRevision: 0, taskID: task.id))
        #expect(registry.setDecisionReference(corrected, expectedRevision: 1, taskID: task.id))
        #expect(!registry.removeDecisionReference(id: decision.id, expectedRevision: 1, taskID: task.id))
        #expect(registry.removeDecisionReference(id: decision.id, expectedRevision: 2, taskID: task.id))
        #expect(registry.task(for: task.id)?.decisionReferences.isEmpty == true)
        #expect(registry.task(for: task.id)?.runs == task.runs)
        #expect(registry.task(for: task.id)?.objective == task.objective)
    }

    @Test func goalVersionBumpsAndInvalidatesEvidenceWithoutRewritingHistory() {
        var task = task()
        let run = task.runs[0]
        let snapshot = AgentTaskResultSnapshot(
            runID: run.id, outcome: .success,
            codeState: nil, environment: nil, recordedAt: now
        )
        let fact = AgentTaskEvidenceFact(
            kind: .reviewerOutcome, runID: run.id, processGeneration: 1,
            trust: .verified, result: .succeeded, observedAt: now
        )
        task.reviewedSnapshot = snapshot
        task.acceptedSnapshot = snapshot
        task.verificationState = .verified
        task.acceptanceState = .accepted
        task.evidence = [fact]
        #expect(task.objectiveRevision == 1)
        let registry = AgentTaskRegistry(persistence: BriefStore())
        registry.setTasksForTesting([task])

        #expect(registry.setObjective("Revised goal", expectedRevision: 1, taskID: task.id))
        let updated = registry.task(for: task.id)
        #expect(updated?.objective == "Revised goal")
        #expect(updated?.objectiveRevision == 2)
        #expect(updated?.verificationState == .stale)
        #expect(updated?.acceptanceState == .notAccepted)
        // History is invalidated, never rewritten or erased.
        #expect(updated?.reviewedSnapshot == snapshot)
        #expect(updated?.acceptedSnapshot == snapshot)
        #expect(updated?.evidence == [fact])
        #expect(updated?.runs == task.runs)

        #expect(!registry.setObjective("Again", expectedRevision: 1, taskID: task.id))
        #expect(registry.task(for: task.id)?.objective == "Revised goal")
        #expect(registry.setObjective("Again", expectedRevision: 2, taskID: task.id))
        #expect(registry.task(for: task.id)?.objectiveRevision == 3)
        // No-op edit: identical text does not bump or invalidate further.
        #expect(registry.setObjective("Again", expectedRevision: 3, taskID: task.id))
        #expect(registry.task(for: task.id)?.objectiveRevision == 3)
        #expect(registry.task(for: task.id)?.verificationState == .stale)

        #expect(!registry.setObjective(
            String(repeating: "a", count: 2_049), expectedRevision: 3, taskID: task.id
        ))
        #expect(!registry.setObjective("bad\0goal", expectedRevision: 3, taskID: task.id))

        var dismissed = self.task()
        dismissed.lifecycle = .dismissed
        registry.setTasksForTesting([dismissed])
        #expect(!registry.setObjective("Nope", expectedRevision: 1, taskID: dismissed.id))
    }

    @Test func briefExposesGoalVersionAndInvalidation() throws {
        var task = task()
        task.verificationState = .verified
        let registry = AgentTaskRegistry(persistence: BriefStore())
        registry.setTasksForTesting([task])
        let initial = try #require(registry.task(for: task.id))
        let before = AgentTaskBrief(task: initial)
        #expect(before.objectiveRevision == 1)
        _ = registry.setObjective("Second goal", expectedRevision: 1, taskID: task.id)
        let updated = try #require(registry.task(for: task.id))
        let after = AgentTaskBrief(task: updated)
        #expect(after.objective == "Second goal")
        #expect(after.objectiveRevision == 2)
        #expect(after.verification == .stale)
    }

    @Test func goalRevisionRoundTripsAndLegacyDecodesToFirstVersion() throws {
        let task = task()
        #expect(task.objectiveRevision == 1)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(task)
        #expect(try decoder.decode(AgentTask.self, from: data).objectiveRevision == 1)
        // Legacy metadata without the key defaults from goal presence.
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root.removeValue(forKey: "objectiveRevision")
        let legacy = try JSONSerialization.data(withJSONObject: root)
        #expect(try decoder.decode(AgentTask.self, from: legacy).objectiveRevision == 1)
        root.removeValue(forKey: "objective")
        let noGoal = try JSONSerialization.data(withJSONObject: root)
        #expect(try decoder.decode(AgentTask.self, from: noGoal).objectiveRevision == 0)
    }

    @Test func boundsAndForeignAttemptsAreRejected() {
        let task = task()
        let registry = AgentTaskRegistry(persistence: BriefStore())
        registry.setTasksForTesting([task])
        for _ in 0..<AgentTaskDecisionReference.maximumCount {
            #expect(registry.setDecisionReference(record(task: task), expectedRevision: nil, taskID: task.id))
        }
        #expect(!registry.setDecisionReference(record(task: task), expectedRevision: nil, taskID: task.id))
        #expect(!record(task: task, reference: "").isValid)
        #expect(!record(task: task, reference: "id\ntranscript").isValid)
        #expect(!record(task: task, reference: String(repeating: "é", count: 129)).isValid)

        let other = self.task()
        registry.setTasksForTesting([task])
        #expect(!registry.setDecisionReference(record(task: other), expectedRevision: nil, taskID: task.id))
    }

    @Test func metadataRoundTripAndLegacyDefaults() throws {
        var task = task()
        task.decisionReferences = [record(task: task)]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(task)
        #expect(try decoder.decode(AgentTask.self, from: data) == task)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "decisionReferences")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try decoder.decode(AgentTask.self, from: oldData).decisionReferences.isEmpty)
    }
}

private actor BriefStore: AgentTaskPersisting {
    func save(
        tasks: [AgentTask], project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) -> AgentTaskMetadataSaveResult {
        .saved(taskCount: tasks.count)
    }

    func load(project: AgentTaskProjectIdentity) -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: .missing, tasks: [])
    }
}
