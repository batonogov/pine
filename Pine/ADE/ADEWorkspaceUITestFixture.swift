//
//  ADEWorkspaceUITestFixture.swift
//  Pine
//
//  One task in every row state, for the workspace XCUITest (#1760).
//

#if DEBUG
import Foundation

/// Seeds the opened project with a task in each row state.
///
/// Presentation-only: no process, grant, acceptance, or provider is
/// involved. Task IDs are fixed so a selection survives the relaunch the
/// test performs.
enum ADEWorkspaceUITestFixture {
    static let argument = "--ui-test-ade-workspace"

    static let readyGoal = "Ready fixture task"
    static let decisionGoal = "Decision fixture task"
    static let runningGoal = "Running fixture task"
    static let failedGoal = "Failed fixture task"
    static let cancelledGoal = "Cancelled fixture task"
    static let unverifiedGoal = "Unverified fixture task"
    static let unstartedGoal = "Unstarted fixture task"

    static func seedIfNeeded(
        registry: ProjectRegistry,
        projectURL: URL,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        guard arguments.contains(argument),
              !registry.agentTasks.tasks.contains(where: { $0.id == id(1) }) else { return }
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: projectURL.path, canonicalWorktreePath: projectURL.path
        )
        registry.agentTasks.setTasksForTesting(
            registry.agentTasks.tasks + tasks(for: identity, now: Date())
        )
    }

    /// The same seeds for a unit or hosted test, under any project identity.
    static func tasks(
        for identity: AgentTaskProjectIdentity, now: Date
    ) -> [AgentTask] {
        func minutesAgo(_ minutes: TimeInterval) -> Date {
            now.addingTimeInterval(-minutes * 60)
        }
        return [
            verified(2, goal: decisionGoal, identity: identity, started: minutesAgo(30), decision: true),
            verified(1, goal: readyGoal, identity: identity, started: minutesAgo(20), decision: false),
            live(3, goal: runningGoal, identity: identity, started: minutesAgo(4)),
            ended(4, goal: failedGoal, identity: identity, started: minutesAgo(9), outcome: .failure),
            ended(5, goal: cancelledGoal, identity: identity, started: minutesAgo(12), outcome: .cancellation),
            ended(6, goal: unverifiedGoal, identity: identity, started: minutesAgo(15), outcome: .unverified),
            reserved(7, goal: unstartedGoal, identity: identity, created: minutesAgo(1)),
        ]
    }

    // MARK: - Shapes

    private static func id(_ seed: UInt32) -> UUID {
        UUID(uuidString: String(format: "0ADE0000-0000-4000-8000-%012llX", UInt64(seed)))
            ?? UUID()
    }

    private static func context(
        _ identity: AgentTaskProjectIdentity, at startedAt: Date,
        availability: AgentTaskRouteAvailability
    ) -> AgentTaskBridgeContext {
        AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(ownedProcessAvailability: availability),
            origin: .pineLaunched,
            observedAt: startedAt
        )
    }

    private static func run(
        seed: UInt32, started: Date, liveness: AgentRunLiveness, state: AgentRunState
    ) -> AgentTaskRun {
        AgentTaskRun(AgentTaskRunInput(
            id: id(seed + 100),
            terminalID: nil,
            process: AgentProcessEvidence(
                processIdentifier: 42, processGeneration: 1,
                startIdentifier: "workspace-fixture",
                observedStartedAt: started, startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state, liveness: liveness, observedAt: started.addingTimeInterval(180)
            )
        ))
    }

    private static func task(
        seed: UInt32, goal: String, identity: AgentTaskProjectIdentity, started: Date,
        availability: AgentTaskRouteAvailability,
        descriptor: AgentDescriptor = AgentDescriptor(agentType: .openCode)
    ) -> AgentTask {
        var task = AgentTask(
            descriptor: descriptor,
            context: context(identity, at: started, availability: availability),
            title: goal, objective: goal, createdAt: started
        )
        let observed = started.addingTimeInterval(180)
        task.updatedAt = observed
        task.lastActivityAt = observed
        return task
    }

    /// A Pine-verified result, or the same result with its review stopped at
    /// a decision the user has to make.
    private static func verified(
        _ seed: UInt32, goal: String, identity: AgentTaskProjectIdentity,
        started: Date, decision: Bool
    ) -> AgentTask {
        let taskID = id(seed)
        var task = task(
            seed: seed, goal: goal, identity: identity, started: started, availability: .missing
        )
        let observed = started.addingTimeInterval(180)
        let attempt = run(seed: seed, started: started, liveness: .terminated, state: .done)
        task.runs = [attempt]
        let code = AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "b", count: 40),
            trackedFingerprint: String(repeating: "a", count: 64),
            untrackedFingerprint: String(repeating: "b", count: 64),
            ignoredRelevantFingerprint: String(repeating: "c", count: 64)
        )
        let environment = AgentTaskEnvironmentIdentity(
            osBuild: "26A5388g", toolchain: "Xcode 27.0",
            configurationFingerprint: String(repeating: "d", count: 64)
        )
        task.evidence = [
            AgentTaskEvidenceFact(
                kind: .agentReportedCompletion, runID: attempt.id, processGeneration: 1,
                trust: .verified, result: .reported, observedAt: observed,
                codeState: code, environment: environment, sourceSequence: 1
            ),
            AgentTaskEvidenceFact(
                kind: .independentCheck, runID: attempt.id, processGeneration: 1,
                trust: .verified, result: .succeeded, observedAt: observed,
                codeState: code, environment: environment, sourceSequence: 2,
                preOperationCodeState: code, postOperationCodeState: code
            ),
            AgentTaskEvidenceFact(
                kind: .reviewerOutcome, runID: attempt.id, processGeneration: 1,
                trust: .verified, result: .succeeded, observedAt: observed,
                codeState: code, environment: environment, sourceSequence: 3,
                preOperationCodeState: code, postOperationCodeState: code
            ),
        ]
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: 0)
        if decision {
            var cycle = AgentTaskCorrectionCycle(
                taskID: taskID, runID: attempt.id, codeState: code, environment: environment,
                requestedOutcomeReference: "outcome", criteriaVersion: "criteria",
                checkPlanIdentity: String(repeating: "f", count: 64),
                reviewerControl: .writeDisabledAtAdapter
            )
            cycle.stop(.checksFailed)
            task.reviewCycle = cycle
            task.verificationState = .stale
        }
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        return reidentified(task, id: taskID)
    }

    /// A live attempt with an unsettled turn.
    private static func live(
        _ seed: UInt32, goal: String, identity: AgentTaskProjectIdentity, started: Date
    ) -> AgentTask {
        var task = task(
            seed: seed, goal: goal, identity: identity, started: started, availability: .available
        )
        task.runs = [run(seed: seed, started: started, liveness: .live, state: .executing)]
        task.lifecycle = .active
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        return reidentified(task, id: id(seed))
    }

    /// An attempt that ended with the given recorded outcome.
    private static func ended(
        _ seed: UInt32, goal: String, identity: AgentTaskProjectIdentity,
        started: Date, outcome: AgentTaskOutcome
    ) -> AgentTask {
        var task = task(
            seed: seed, goal: goal, identity: identity, started: started, availability: .missing
        )
        let observed = started.addingTimeInterval(180)
        let attempt = run(seed: seed, started: started, liveness: .terminated, state: .done)
        task.runs = [attempt]
        task.runs[0].outcome = outcome
        task.evidence = [AgentTaskEvidenceFact(
            kind: .processCompletion, runID: attempt.id, processGeneration: 1,
            trust: .observed, result: .exited(status: nil), observedAt: observed
        )]
        task.lifecycle = .paused
        task.attention = outcome == .failure ? .failed : .none
        task.isUnread = outcome == .failure
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        return reidentified(task, id: id(seed))
    }

    /// A reserved task whose agent never started.
    private static func reserved(
        _ seed: UInt32, goal: String, identity: AgentTaskProjectIdentity, created: Date
    ) -> AgentTask {
        let taskID = id(seed)
        var task = task(
            seed: seed, goal: goal, identity: identity, started: created, availability: .missing,
            descriptor: AgentDescriptor(agentType: .openCode, launchExecutable: "opencode")
        )
        task.lifecycle = .paused
        task.nativeDispatch = AgentTaskNativeDispatch(taskID: taskID, runID: id(seed + 100))
        return reidentified(task, id: taskID)
    }

    /// A task's ID is fixed at birth, so the fixture round-trips the value
    /// through its own encoding to give it a stable one.
    private static func reidentified(_ task: AgentTask, id: UUID) -> AgentTask {
        guard let data = try? JSONEncoder().encode(task),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return task
        }
        object["id"] = id.uuidString
        guard let patched = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? JSONDecoder().decode(AgentTask.self, from: patched) else {
            return task
        }
        return decoded
    }
}
#endif
