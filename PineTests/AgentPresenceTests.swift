//
//  AgentPresenceTests.swift
//  PineTests
//

import Foundation
import Testing
import UserNotifications
@testable import Pine

@MainActor
struct AgentPresenceTests {
    // MARK: - Dock badge + sudden-termination guard (#1355)

    @Test("Dock badge tracks the live-run count, including backgrounded projects")
    func badgeTracksLiveRunCount() {
        let registry = AgentTaskRegistry()
        let applier = RecordingAgentPresenceApplier()
        let controller = AgentPresenceController(
            registry: registry,
            applier: applier
        )
        controller.start()
        // start() seeds the empty baseline: badge cleared, guard untouched.
        #expect(applier.badgeCounts == [0])
        #expect(applier.suddenTerminationCalls.isEmpty)

        // A backgrounded project (window closed → availability .background)
        // is still executing and must still be counted, so closing every
        // window never makes live agents invisible.
        let backgrounded = makeTask(seed: 1, availability: .background)
        let live = makeTask(seed: 2)
        registry.setTasksForTesting([backgrounded, live])

        #expect(applier.badgeCounts.last == 2)
        #expect(applier.suddenTerminationCalls == [true])

        // The last run ending clears the badge and re-enables termination.
        registry.setTasksForTesting([])
        #expect(applier.badgeCounts.last == 0)
        #expect(applier.suddenTerminationCalls == [true, false])
        controller.stop()
    }

    @Test("sudden-termination guard stays balanced across run and controller cycles")
    func suddenTerminationBalanced() {
        let registry = AgentTaskRegistry()
        let applier = RecordingAgentPresenceApplier()
        let controller = AgentPresenceController(
            registry: registry,
            applier: applier
        )
        controller.start()

        // 0 -> 1 -> 0 -> 1, then stop.
        registry.setTasksForTesting([makeTask(seed: 1)])
        registry.setTasksForTesting([])
        registry.setTasksForTesting([makeTask(seed: 2)])
        controller.stop()

        let calls = applier.suddenTerminationCalls
        // Every disable is paired with a later enable — balanced to the run
        // lifecycle, never to each mutation.
        #expect(calls.filter { $0 }.count == calls.filter { !$0 }.count)
        // Disables first, ends enabled, strictly alternating.
        #expect(calls.first == true)
        #expect(calls.last == false)
        #expect(zip(calls, calls.dropFirst()).allSatisfy { $0.0 != $0.1 })
        // A redundant mutation (same count) never reaches the applier.
        #expect(applier.badgeCounts.filter { $0 == 1 }.count == 2)
        // stop() always restores the baseline.
        #expect(applier.badgeCounts.last == 0)
    }

    @Test("identical live-run counts do not re-publish the badge")
    func noRedundantPublish() {
        let registry = AgentTaskRegistry()
        let applier = RecordingAgentPresenceApplier()
        let controller = AgentPresenceController(
            registry: registry,
            applier: applier
        )
        controller.start()

        // Two distinct tasks, same live count → badge published once for 1.
        registry.setTasksForTesting([makeTask(seed: 1)])
        registry.setTasksForTesting([makeTask(seed: 2)])
        #expect(applier.badgeCounts == [0, 1])
        #expect(applier.suddenTerminationCalls == [true])
        controller.stop()
    }

    // MARK: - Foreground notification presentation (#1355, gap 3)

    @Test("foreground notifications request banner, list, and sound while frontmost")
    func willPresentRequestsBanner() {
        let options = SystemAgentNotificationCenter.foregroundPresentationOptions
        #expect(options.contains(.banner))
        #expect(options.contains(.list))
        #expect(options.contains(.sound))
    }

    // MARK: - Dock menu projection (#1355)

    @Test("Dock menu lists only live runs, newest-first, with a stable title")
    func dockMenuProjection() {
        let older = makeTask(seed: 1, title: "Older task")
        let newer = makeTask(seed: 2, title: "Newer task")
        let terminated = makeTask(
            seed: 3,
            liveness: .terminated,
            lifecycle: .paused,
            title: "Ended"
        )
        let tasks = [older, newer, terminated]

        #expect(AgentPresenceController.liveAgentRunCount(tasks) == 2)

        let live = AgentPresenceController.liveTasks(for: tasks)
        #expect(live.map(\.id) == [newer.id, older.id])
        #expect(!live.contains { $0.id == terminated.id })

        let titled = AgentPresenceController.dockMenuAgentTitle(for: newer)
        // agent — objective — project
        #expect(titled.components(separatedBy: " — ").count == 3)
        #expect(titled.contains("Codex"))
        #expect(titled.contains("Newer task"))
        #expect(titled.contains("presence-demo"))

        // No objective collapses to agent — project only.
        let untitled = AgentPresenceController.dockMenuAgentTitle(
            for: makeTask(seed: 4, title: nil)
        )
        #expect(untitled.components(separatedBy: " — ").count == 2)
        #expect(untitled.contains("Codex"))
        #expect(untitled.contains("presence-demo"))

        // A large fleet is capped so the Dock menu cannot overflow.
        let fleet = (1...25).map { makeTask(seed: $0) }
        #expect(AgentPresenceController.liveTasks(for: fleet).count == 10)
    }

    // MARK: - Fixtures

    private func makeTask(
        seed: Int,
        agentType: AgentType = .codex,
        state: AgentRunState = .executing,
        liveness: AgentRunLiveness = .live,
        lifecycle: AgentTaskLifecycle = .active,
        availability: AgentTaskRouteAvailability = .available,
        title: String? = "Review tests",
        project: String = "/tmp/presence-demo"
    ) -> AgentTask {
        let route = AgentTaskRoute(
            paneID: uuid(seed),
            tabID: uuid(seed + 1),
            terminalID: uuid(seed + 1),
            availability: availability
        )
        let started = Date(timeIntervalSince1970: TimeInterval(1_000 + seed))
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: project,
                canonicalWorktreePath: project
            ),
            route: route,
            origin: .discoveredInTerminal,
            observedAt: started
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: agentType),
            context: context,
            title: title
        )
        task.lifecycle = lifecycle
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: uuid(seed + 100),
            terminalID: route.terminalID,
            process: AgentProcessEvidence(
                processIdentifier: Int32(seed),
                processGeneration: UInt64(seed),
                startIdentifier: "presence-\(seed)",
                observedStartedAt: started,
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: liveness,
                observedAt: started
            )
        ))]
        return task
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }
}

@MainActor
private final class RecordingAgentPresenceApplier: AgentPresenceApplier {
    private(set) var badgeCounts: [Int] = []
    private(set) var suddenTerminationCalls: [Bool] = []

    func setDockBadge(count: Int) {
        badgeCounts.append(count)
    }

    func setSuddenTerminationDisabled(_ disabled: Bool) {
        suddenTerminationCalls.append(disabled)
    }
}
