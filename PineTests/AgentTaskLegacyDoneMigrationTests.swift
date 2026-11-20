//
//  AgentTaskLegacyDoneMigrationTests.swift
//  PineTests
//
//  Legacy `.done` / task-completed migration guard (#1722): a run's
//  `.done` state and the legacy task-completed notification mean only
//  "the agent reported or appeared to finish". They must not migrate
//  into verified-result or Ready, at the notification, model, or
//  persistence level.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Legacy .done migration guard", .serialized)
struct AgentTaskLegacyDoneMigrationTests {
    private var codeState: AgentTaskCodeStateIdentity {
        ADEContractFixtures.codeState("a")
    }
    private var env: AgentTaskEnvironmentIdentity { ADEContractFixtures.environment }

    /// The legacy flow: a live run whose state moves to `.done` (the agent
    /// reported or appeared to finish), then the process terminates without
    /// any recorded evidence facts.
    private func terminatedDoneRun(
        seed: Int,
        accuracy: FirstPartyAgentNotificationAccuracy,
        projectPath: String? = nil,
        now: Date = Date(timeIntervalSince1970: 10_000)
    ) -> (live: AgentTask, settled: AgentTask) {
        var live = ADEContractFixtures.makeTask(
            seed: seed,
            state: .executing,
            liveness: .live,
            accuracy: accuracy,
            now: now,
            projectPath: projectPath
        )
        live.route.availability = .available
        var settled = live
        settled.runs[0].state = .done
        settled.runs[0].liveness = .terminated
        settled.runs[0].endedAt = live.runs[0].lastObservedAt
        settled.lifecycle = .paused
        settled.route.availability = .missing
        AgentTaskLifecycleReducer.settleTerminated(task: &settled, runIndex: 0)
        return (live, settled)
    }

    @Test("an agent-reported done run settles unverified and is never Ready")
    func doneRunSettlesUnverified() throws {
        let (live, settled) = terminatedDoneRun(
            seed: 41,
            accuracy: .verifiedLifecycleTransitions
        )
        let run = try #require(settled.runs.first)
        #expect(run.state == .done)
        #expect(settled.runs.last?.outcome == .unverified)
        #expect(settled.verificationState == .none)
        #expect(settled.lifecycle == .paused)
        #expect(settled.completedAt == nil)

        // The legacy `.completed` notification is the "appeared to finish"
        // signal and stays exactly that: one event of the legacy kind.
        let events = AgentNotificationTransitionResolver.events(
            from: [live],
            to: [settled],
            accuracy: { _ in .verifiedLifecycleTransitions }
        )
        #expect(events.map(\.kind) == [.completed])
        #expect(events.map(\.taskID) == [settled.id])

        // The legacy signal must not migrate into the new model: no
        // verified result, no Ready, no verification state.
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: settled,
            codeState: codeState,
            environment: env
        ).isReady)
        #expect(
            AgentTaskLifecycleReducer.readiness(
                for: settled,
                codeState: codeState,
                environment: env
            ).gaps.contains(.unverifiedOutcome)
        )
    }

    @Test("process-only accuracy never turns a .done run into a notification event")
    func doneRunStaysSilent() throws {
        let (live, settled) = terminatedDoneRun(
            seed: 42,
            accuracy: .processTerminationOnly
        )
        #expect(settled.runs.last?.state == .done)
        #expect(settled.runs.last?.outcome == .unverified)

        let events = AgentNotificationTransitionResolver.events(
            from: [live],
            to: [settled],
            accuracy: { _ in .processTerminationOnly }
        )
        #expect(events.isEmpty)
    }

    @Test("no verified-result or Ready notification kind exists")
    func notificationKindsHaveNoVerifiedResult() {
        // The kind set is the whole notification surface: only actionable
        // interruption signals remain, and there is no verified-result,
        // verified, or Ready kind that a legacy `.done` could migrate into.
        #expect(Set(AgentNotificationEventKind.allCases) == [
            .waitingInput, .failed, .completed,
        ])
    }

    @Test("a legacy .done notification carries only bounded content fields")
    func legacyDoneNotificationContentIsBounded() throws {
        var live = ADEContractFixtures.makeTask(
            seed: 43,
            state: .executing,
            liveness: .live,
            accuracy: .verifiedLifecycleTransitions,
            now: Date(timeIntervalSince1970: 10_000),
            projectPath: "/tmp/pine-ade-43"
        )
        live.title = String(repeating: "s", count: 500)
        var settled = live
        settled.runs[0].state = .done
        settled.runs[0].liveness = .terminated
        settled.runs[0].endedAt = live.runs[0].lastObservedAt
        settled.lifecycle = .paused
        AgentTaskLifecycleReducer.settleTerminated(task: &settled, runIndex: 0)

        // The resolver is the production path: it sanitizes the title
        // before the event can reach delivery.
        let events = AgentNotificationTransitionResolver.events(
            from: [live],
            to: [settled],
            accuracy: { _ in .verifiedLifecycleTransitions }
        )
        #expect(events.map(\.kind) == [.completed])
        let event = try #require(events.first)
        // Sanitized at event construction: the 500-char title is bounded.
        #expect((event.taskTitle?.utf8.count ?? 0) <= 120)

        let request = AgentNotificationController.request(for: event)
        // The body is only the bounded project name, title, and elapsed
        // time — no transcript, prompt, output, path, or verified claim.
        #expect(request.body.components(separatedBy: " • ").count <= 3)
        #expect(!request.body.contains(String(repeating: "s", count: 121)))
        #expect(!request.body.contains("/tmp"))
        #expect(Set(request.userInfo.keys) == ["taskID", "runID", "generation"])
        #expect(request.userInfo["taskID"] == settled.id.uuidString)
        #expect(request.userInfo["generation"] == "43")
    }

    @Test("the legacy completed outcome state cannot be persisted or loaded")
    func legacyCompletedStateIsRejectedAtStorage() async throws {
        let fixture = try ADEContractPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = ADEContractFixtures.project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        // A settled unverified task, then rewrite it as the LEGACY
        // "task completed" state: completed lifecycle + attention with no
        // outcome and no evidence basis.
        let (_, settled) = terminatedDoneRun(
            seed: 44,
            accuracy: .verifiedLifecycleTransitions,
            projectPath: fixture.project.path,
            now: Date(timeIntervalSince1970: 1_000)
        )
        registry.setTasksForTesting([settled])
        #expect(
            registry.recordFeedback(
                "seed-ref",
                codeState: nil,
                for: settled.id,
                at: Date(timeIntervalSince1970: 1_000)
            )
        )
        #expect(await registry.flushPersistence() == .saved)
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        var root = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: file)
            ) as? [String: Any]
        )
        var tasks = try #require(root["tasks"] as? [[String: Any]])
        var task = try #require(tasks.first)
        var runs = try #require(task["runs"] as? [[String: Any]])
        var run = try #require(runs.first)
        run["outcome"] = nil
        runs[0] = run
        task["runs"] = runs
        task["lifecycle"] = "completed"
        task["completedAt"] = run["endedAt"]
        task["attention"] = "completed"
        tasks[0] = task
        root["tasks"] = tasks
        try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        ).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )

        // The store rejects the file: the legacy completed state has no
        // evidence basis and never migrates into an outcome.
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .rejected(.invalidMetadata))
    }
}
