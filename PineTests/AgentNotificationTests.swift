//
//  AgentNotificationTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@MainActor
struct AgentNotificationTests {
    @Test("verified waiting, failure, and completion transitions are actionable")
    func verifiedTransitions() throws {
        let working = task(seed: 1, state: .executing)

        var waiting = working
        update(&waiting, state: .waitingInput, offset: 1)
        #expect(events(working, waiting, accuracy: .verifiedLifecycleTransitions).map(\.kind) == [.waitingInput])

        var failed = waiting
        failed.attention = .failed
        update(&failed, state: .executing, offset: 2)
        #expect(events(waiting, failed, accuracy: .verifiedLifecycleTransitions).map(\.kind) == [.failed])

        var completed = working
        completed.lifecycle = .completed
        completed.attention = .completed
        update(&completed, state: .done, liveness: .terminated, offset: 3)
        #expect(events(working, completed, accuracy: .verifiedLifecycleTransitions).map(\.kind) == [.completed])
    }

    @Test("process-only adapters never invent attention or completion")
    func processOnlyAccuracy() {
        let working = task(seed: 2, state: .executing)
        var waiting = working
        update(&waiting, state: .waitingInput, offset: 1)
        #expect(events(working, waiting, accuracy: .processTerminationOnly).isEmpty)

        var ended = waiting
        update(&ended, state: .done, liveness: .terminated, offset: 2)
        #expect(events(waiting, ended, accuracy: .processTerminationOnly).map(\.kind) == [.processEnded])
    }

    @Test("duplicates, reordered evidence, stale evidence, and new generations are ignored")
    func rejectsUntrustworthyTransitions() {
        let original = task(seed: 3, state: .executing)
        var unchanged = original
        update(&unchanged, state: .executing, offset: 1)
        #expect(events(original, unchanged, accuracy: .verifiedLifecycleTransitions).isEmpty)

        var reordered = original
        update(&reordered, state: .waitingInput, offset: -1)
        #expect(events(original, reordered, accuracy: .verifiedLifecycleTransitions).isEmpty)

        var stale = original
        update(&stale, state: .waitingInput, liveness: .stale, offset: 1)
        #expect(events(original, stale, accuracy: .verifiedLifecycleTransitions).isEmpty)

        var replacement = original
        replacement.runs[0].process = AgentProcessEvidence(
            processIdentifier: 99,
            processGeneration: 999,
            startIdentifier: "replacement",
            observedStartedAt: replacement.runs[0].startedAt,
            startIsAuthoritative: true
        )
        update(&replacement, state: .waitingInput, offset: 1)
        #expect(events(original, replacement, accuracy: .verifiedLifecycleTransitions).isEmpty)
    }

    @Test("notification identifiers and routing metadata contain opaque identity only")
    func privacyBoundedRequest() throws {
        let original = task(
            seed: 4,
            state: .executing,
            project: "/private/secret/project",
            title: "User title\ncontinued"
        )
        var waiting = original
        update(&waiting, state: .waitingInput, offset: 60)
        let event = try #require(events(
            original,
            waiting,
            accuracy: .verifiedLifecycleTransitions
        ).first)
        let request = AgentNotificationController.request(for: event)

        #expect(!request.identifier.contains("secret"))
        #expect(!request.identifier.contains("project"))
        #expect(request.body.contains("project"))
        #expect(!request.body.contains("\n"))
        #expect(Set(request.userInfo.keys) == ["taskID", "runID", "generation"])
        #expect(!request.userInfo.values.contains { $0.contains("secret") })
    }

    @Test("notification navigation authority is bound to the exact run generation")
    func exactNotificationRouteIdentity() throws {
        let registry = AgentTaskRegistry()
        let session = makeSession(seed: 42)
        let routeContext = context(seed: 42, project: "/tmp/notify-route")
        registry.bridge(session, replacing: nil, context: routeContext)
        let taskID = try #require(registry.taskID(forSessionID: session.id))
        #expect(registry.matchesNotificationRoute(AgentNotificationRouteIdentity(
            taskID: taskID,
            runID: session.id,
            processGeneration: 42
        )))
        #expect(!registry.matchesNotificationRoute(AgentNotificationRouteIdentity(
            taskID: taskID,
            runID: session.id,
            processGeneration: 43
        )))
        #expect(!registry.matchesNotificationRoute(AgentNotificationRouteIdentity(
            taskID: taskID,
            runID: UUID(),
            processGeneration: 42
        )))
    }

    @Test("preferences persist event, task, agent, and project controls")
    func persistedPreferences() {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        let settings = AgentNotificationSettings(defaults: fixture.defaults)
        let sample = task(seed: 5, state: .executing)
        var ended = sample
        update(&ended, state: .done, liveness: .terminated, offset: 2)
        let event = events(sample, ended, accuracy: .processTerminationOnly)[0]

        settings.setEnabled(true)
        settings.setEvent(.completed, enabled: false)
        settings.setAgent(sample.descriptor.typeIdentifier, enabled: false)
        settings.setProject(sample.project.canonicalProjectPath, enabled: false)
        settings.muteTask(sample.id)
        #expect(!settings.allows(event, task: sample))
        #expect(settings.claimDelivery(of: event.id))
        #expect(!settings.claimDelivery(of: event.id))

        let restored = AgentNotificationSettings(defaults: fixture.defaults)
        #expect(restored.isEnabled)
        #expect(!restored.enabledEvents.contains(.completed))
        #expect(restored.mutedTaskIDs.contains(sample.id))
        #expect(restored.disabledAgentIDs.contains(sample.descriptor.typeIdentifier))
        #expect(restored.disabledProjectPaths.contains(sample.project.canonicalProjectPath))
        #expect(!restored.claimDelivery(of: event.id))
        restored.setTask(sample.id, enabled: true)
        #expect(!AgentNotificationSettings(
            defaults: fixture.defaults
        ).mutedTaskIDs.contains(sample.id))
    }

    @Test("controller delivers across projects, suppresses the exact visible task, and deduplicates")
    func multiProjectDeliveryAndSuppression() async throws {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        let settings = AgentNotificationSettings(defaults: fixture.defaults)
        settings.setEnabled(true)
        let registry = AgentTaskRegistry()
        let delivery = RecordingAgentNotificationDelivery(status: .authorized)
        var presented = Set<UUID>()
        var opened: AgentNotificationRouteIdentity?
        let controller = AgentNotificationController(
            registry: registry,
            settings: settings,
            delivery: delivery,
            isPresented: { presented.contains($0) },
            openTask: { opened = $0 }
        )
        controller.start()
        await controller.refreshAuthorizationStatus()

        let first = makeSession(seed: 10)
        let second = makeSession(seed: 20)
        registry.bridge(first, replacing: nil, context: context(seed: 10, project: "/tmp/notify-a"))
        registry.bridge(second, replacing: nil, context: context(seed: 20, project: "/tmp/notify-b"))
        let firstTaskID = try #require(registry.taskID(forSessionID: first.id))
        let expectedSecondTaskID = try #require(
            registry.taskID(forSessionID: second.id)
        )
        presented.insert(firstTaskID)

        first.applyLiveness(.terminated)
        second.applyLiveness(.terminated)
        registry.refresh(sessions: [first, second])
        await settle()

        #expect(delivery.requests.count == 1)
        let deliveredTaskID = try #require(
            delivery.requests.first?.userInfo["taskID"]
        )
        let secondTaskID = try #require(UUID(uuidString: deliveredTaskID))
        #expect(secondTaskID == expectedSecondTaskID)

        registry.refresh(sessions: [first, second])
        await settle()
        #expect(delivery.requests.count == 1)

        let routeIdentity = AgentNotificationRouteIdentity(
            taskID: secondTaskID,
            runID: second.id,
            processGeneration: 20
        )
        delivery.respond(.open(routeIdentity))
        #expect(opened == routeIdentity)
        delivery.respond(.mute(taskID: secondTaskID))
        #expect(settings.mutedTaskIDs.contains(secondTaskID))
        controller.stop()
    }

    @Test("denied authorization disables delivery but remains reversible")
    func deniedAuthorization() async {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        let settings = AgentNotificationSettings(defaults: fixture.defaults)
        settings.setEnabled(true)
        let delivery = RecordingAgentNotificationDelivery(status: .denied)
        let controller = AgentNotificationController(
            registry: AgentTaskRegistry(),
            settings: settings,
            delivery: delivery,
            isPresented: { _ in false },
            openTask: { _ in }
        )

        await controller.refreshAuthorizationStatus()
        #expect(controller.authorizationStatus == .denied)
        #expect(!settings.isEnabled)

        delivery.status = .authorized
        delivery.requestResult = true
        #expect(await controller.requestAuthorization())
        #expect(settings.isEnabled)
    }

    private func events(
        _ old: AgentTask,
        _ new: AgentTask,
        accuracy: FirstPartyAgentNotificationAccuracy
    ) -> [AgentNotificationEvent] {
        AgentNotificationTransitionResolver.events(
            from: [old],
            to: [new],
            accuracy: { _ in accuracy }
        )
    }

    private func task(
        seed: Int,
        state: AgentRunState,
        project: String = "/tmp/notify-project",
        title: String? = "Review tests"
    ) -> AgentTask {
        let context = context(seed: seed, project: project)
        let started = Date(timeIntervalSince1970: TimeInterval(1_000 + seed))
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: context,
            title: title,
            createdAt: started
        )
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: uuid(seed + 100),
            terminalID: context.route.terminalID,
            process: AgentProcessEvidence(
                processIdentifier: Int32(seed),
                processGeneration: UInt64(seed),
                startIdentifier: "verified-\(seed)",
                observedStartedAt: started,
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: .live,
                observedAt: started
            )
        ))]
        task.updatedAt = started
        task.lastActivityAt = started
        return task
    }

    private func update(
        _ task: inout AgentTask,
        state: AgentRunState,
        liveness: AgentRunLiveness = .live,
        offset: TimeInterval
    ) {
        task.runs[0].state = state
        task.runs[0].liveness = liveness
        task.runs[0].lastObservedAt = task.runs[0].startedAt.addingTimeInterval(offset)
        task.runs[0].endedAt = liveness == .terminated
            ? task.runs[0].lastObservedAt
            : nil
        task.updatedAt = task.runs[0].lastObservedAt
    }

    private func makeSession(seed: Int) -> AgentSession {
        let session = AgentSession(
            agentType: .codex,
            state: .executing,
            startedAt: Date(timeIntervalSince1970: TimeInterval(seed))
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: Int32(seed),
            processGeneration: UInt64(seed),
            startIdentifier: "verified-session-\(seed)",
            observedStartedAt: session.startedAt,
            startIsAuthoritative: true
        ))
        return session
    }

    private func context(seed: Int, project: String) -> AgentTaskBridgeContext {
        AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: project,
                canonicalWorktreePath: project
            ),
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: uuid(seed + 1_000),
                terminalID: uuid(seed + 1_000)
            ),
            origin: .discoveredInTerminal,
            observedAt: Date(timeIntervalSince1970: TimeInterval(seed))
        )
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private final class RecordingAgentNotificationDelivery: AgentNotificationDelivering {
    var responseHandler: ((AgentNotificationResponseAction) -> Void)?
    var status: AgentNotificationAuthorizationStatus
    var requestResult = false
    private(set) var requests: [AgentNotificationRequest] = []

    init(status: AgentNotificationAuthorizationStatus) {
        self.status = status
    }

    func registerActions() {}
    func authorizationStatus() async -> AgentNotificationAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool { requestResult }
    func deliver(_ request: AgentNotificationRequest) async throws {
        requests.append(request)
    }
    func respond(_ action: AgentNotificationResponseAction) {
        responseHandler?(action)
    }
}

private final class DefaultsFixture {
    let suiteName = "AgentNotificationTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
