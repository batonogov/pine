import Foundation
import XCTest
@testable import Pine

@MainActor
final class AgentWorkflowPerformanceTests: XCTestCase {
    private let taskCount = 500

    func testProcessPolling500Agents() {
        let detector = AgentDetector(maxSessionHistory: 1_000)
        let aliases = FirstPartyAgentCompatibilityCatalog.records
            .compactMap { $0.executableAliases.sorted().first }
        let processes = (0..<taskCount).map { index in
            DetectedProcess(
                pid: Int32(10_000 + index),
                command: aliases[index % aliases.count],
                cpuTime: index,
                startIdentifier: "synthetic-\(index)"
            )
        }

        assertUnderBudget(.seconds(1)) {
            detector.processSnapshotDidUpdate(processes)
        }
        measure(metrics: [XCTClockMetric()]) {
            detector.processSnapshotDidUpdate(processes)
        }
    }

    func testEventEnvelopeIngestion1000Events() throws {
        let events = (0..<1_000).map(makeEnvelope)
        let data = try JSONEncoder().encode(events)

        assertUnderBudget(.seconds(1)) {
            _ = try? JSONDecoder().decode([AgentEventEnvelope].self, from: data)
        }
        measure(metrics: [XCTClockMetric()]) {
            _ = try? JSONDecoder().decode([AgentEventEnvelope].self, from: data)
        }
    }

    func testRegistryRefresh500Tasks() {
        let registry = AgentTaskRegistry(
            persistence: PerformanceAgentTaskStore(),
            limits: AgentTaskPersistenceLimits(maxTasksPerProject: taskCount)
        )
        let sessions = (0..<taskCount).map(makeSession)
        for (index, session) in sessions.enumerated() {
            registry.bridge(
                session,
                replacing: nil,
                context: makeContext(index)
            )
        }

        assertUnderBudget(.seconds(1)) {
            registry.refresh(sessions: sessions)
        }
        measure(metrics: [XCTClockMetric()]) {
            registry.refresh(sessions: sessions)
        }
    }

    func testInboxProjectionAndNotificationCoalescing500Tasks() {
        let oldTasks = (0..<taskCount).map {
            makeTask(index: $0, state: .executing, observedOffset: 0)
        }
        let newTasks = oldTasks.map { task in
            var task = task
            let observedAt = task.updatedAt.addingTimeInterval(1)
            task.runs[task.runs.count - 1].state = .waitingInput
            task.runs[task.runs.count - 1].lastObservedAt = observedAt
            task.attention = .waitingInput
            task.updatedAt = observedAt
            task.lastActivityAt = observedAt
            return task
        }

        assertUnderBudget(.seconds(1)) {
            _ = AgentInboxSnapshot(tasks: newTasks)
            _ = AgentNotificationTransitionResolver.events(
                from: oldTasks,
                to: newTasks,
                accuracy: { _ in .verifiedLifecycleTransitions }
            )
        }
        measure(metrics: [XCTClockMetric()]) {
            _ = AgentInboxSnapshot(tasks: newTasks)
            _ = AgentNotificationTransitionResolver.events(
                from: oldTasks,
                to: newTasks,
                accuracy: { _ in .verifiedLifecycleTransitions }
            )
        }
    }

    private func assertUnderBudget(
        _ budget: Duration,
        operation: () -> Void
    ) {
        let clock = ContinuousClock()
        let startedAt = clock.now
        operation()
        XCTAssertLessThan(startedAt.duration(to: clock.now), budget)
    }

    private func makeEnvelope(_ index: Int) -> AgentEventEnvelope {
        AgentEventEnvelope(
            id: uuid(index),
            projectID: uuid(index + 1_000),
            sessionID: uuid(index + 2_000),
            agentTypeRaw: "codex",
            process: AgentProcessIdentity(
                terminalID: uuid(index + 3_000),
                processGeneration: UInt64(index + 1)
            ),
            location: AgentEventLocation(
                worktreePath: "/tmp/project",
                cwd: "/tmp/project"
            ),
            cursorValue: UInt64(index + 1),
            timestamp: Date(timeIntervalSince1970: 1_000),
            source: .terminalProcess,
            trustLevel: .observed
        )
    }

    private func makeSession(_ index: Int) -> AgentSession {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index + 1))
        let session = AgentSession(
            id: uuid(index + 4_000),
            agentType: .codex,
            state: .executing,
            startedAt: startedAt
        )
        XCTAssertTrue(session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: Int32(index + 20_000),
            processGeneration: UInt64(index + 1),
            startIdentifier: "synthetic-\(index)",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        )))
        return session
    }

    private func makeContext(_ index: Int) -> AgentTaskBridgeContext {
        let terminalID = uuid(index + 5_000)
        return AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: "/tmp/performance-project",
                canonicalWorktreePath: "/tmp/performance-project"
            ),
            route: AgentTaskRoute(
                paneID: uuid(index + 6_000),
                tabID: terminalID,
                terminalID: terminalID
            ),
            origin: .discoveredInTerminal,
            observedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
        )
    }

    private func makeTask(
        index: Int,
        state: AgentRunState,
        observedOffset: TimeInterval
    ) -> AgentTask {
        let context = makeContext(index)
        let observedAt = context.observedAt.addingTimeInterval(observedOffset)
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: context,
            title: "Synthetic task \(index)"
        )
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: uuid(index + 4_000),
            terminalID: context.route.terminalID,
            process: AgentProcessEvidence(
                processIdentifier: Int32(index + 20_000),
                processGeneration: UInt64(index + 1),
                startIdentifier: "synthetic-\(index)",
                observedStartedAt: context.observedAt,
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: .live,
                observedAt: observedAt
            )
        ))]
        task.attention = state == .waitingInput ? .waitingInput : .none
        task.updatedAt = observedAt
        task.lastActivityAt = observedAt
        return task
    }

    private func uuid(_ seed: Int) -> UUID {
        guard let value = UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012x",
            seed
        )) else {
            preconditionFailure("Synthetic UUID seed must fit the fixture")
        }
        return value
    }
}

private actor PerformanceAgentTaskStore: AgentTaskPersisting {
    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) -> AgentTaskMetadataSaveResult {
        .saved(taskCount: tasks.count)
    }

    func load(
        project: AgentTaskProjectIdentity
    ) -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: .missing, tasks: [])
    }
}
