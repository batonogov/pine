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
        #expect(await waitUntil { delivery.requests.count == 1 })

        let deliveredTaskID = try #require(
            delivery.requests.first?.userInfo["taskID"]
        )
        let secondTaskID = try #require(UUID(uuidString: deliveredTaskID))
        #expect(secondTaskID == expectedSecondTaskID)

        registry.refresh(sessions: [first, second])
        // Deliberately a settle and not a wait: the point is that *no second*
        // request appears, and there is no positive signal for "the duplicate
        // was considered and dropped" to wait on.
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

    @Test("startup authorization refresh preserves transitions observed in flight")
    func startupAuthorizationRefreshPreservesTransitions() async throws {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        let settings = AgentNotificationSettings(defaults: fixture.defaults)
        settings.setEnabled(true)
        let registry = AgentTaskRegistry()
        let delivery = RecordingAgentNotificationDelivery(status: .authorized)
        delivery.suspendAuthorizationStatus = true
        let controller = AgentNotificationController(
            registry: registry,
            settings: settings,
            delivery: delivery,
            isPresented: { _ in false },
            openTask: { _ in }
        )
        controller.start()

        let working = task(seed: 29, state: .executing)
        var ended = working
        update(&ended, state: .done, liveness: .terminated, offset: 1)
        registry.setTasksForTesting([working])
        registry.setTasksForTesting([ended])

        // The signal is the suspended authorization request arriving, not a
        // handful of yields. `requests.isEmpty` is then a real statement about
        // ordering: the delivery is blocked behind that status call.
        #expect(await waitUntil { delivery.hasPendingAuthorizationStatusRequest })
        #expect(delivery.requests.isEmpty)

        delivery.resumeAuthorizationStatus()
        // Resuming only makes the controller's continuation *ready*; it still
        // has to run. Waiting for the request it then makes is the signal.
        #expect(await waitUntil { delivery.requests.count == 1 })
        #expect(controller.authorizationStatus == .authorized)
        controller.stop()
    }

    @Test("transient delivery failure retries before persisting deduplication")
    func transientDeliveryFailureRetries() async throws {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        let settings = AgentNotificationSettings(defaults: fixture.defaults)
        settings.setEnabled(true)
        let registry = AgentTaskRegistry()
        let delivery = RecordingAgentNotificationDelivery(status: .authorized)
        delivery.failuresRemaining = 1
        let controller = AgentNotificationController(
            registry: registry,
            settings: settings,
            delivery: delivery,
            deliveryRetryDelays: [.zero],
            isPresented: { _ in false },
            openTask: { _ in }
        )
        controller.start()
        await controller.refreshAuthorizationStatus()

        let session = makeSession(seed: 30)
        registry.bridge(
            session,
            replacing: nil,
            context: context(seed: 30, project: "/tmp/notify-retry")
        )
        session.applyLiveness(.terminated)
        registry.refresh(sessions: [session])
        #expect(await waitUntil { delivery.deliveryAttemptCount == 2 })

        let request = try #require(delivery.requests.first)
        #expect(settings.hasDelivered(request.identifier))
        controller.stop()
    }

    @Test("exhausted delivery remains eligible for the same event later")
    func exhaustedDeliveryIsNotClaimed() async throws {
        let fixture = DefaultsFixture()
        defer { fixture.cleanup() }
        let settings = AgentNotificationSettings(defaults: fixture.defaults)
        settings.setEnabled(true)
        let registry = AgentTaskRegistry()
        let delivery = RecordingAgentNotificationDelivery(status: .authorized)
        delivery.failuresRemaining = 2
        let controller = AgentNotificationController(
            registry: registry,
            settings: settings,
            delivery: delivery,
            accuracy: { _ in .processTerminationOnly },
            deliveryRetryDelays: [.zero],
            isPresented: { _ in false },
            openTask: { _ in }
        )
        controller.start()
        await controller.refreshAuthorizationStatus()

        let working = task(seed: 31, state: .executing)
        var ended = working
        update(&ended, state: .done, liveness: .terminated, offset: 1)
        registry.setTasksForTesting([working])
        registry.setTasksForTesting([ended])
        #expect(await waitUntil { delivery.deliveryAttemptCount == 2 })

        #expect(delivery.requests.isEmpty)
        #expect(settings.deliveredEventIDs.isEmpty)

        registry.setTasksForTesting([working])
        registry.setTasksForTesting([ended])
        #expect(await waitUntil { delivery.deliveryAttemptCount == 3 })

        let request = try #require(delivery.requests.first)
        #expect(settings.hasDelivered(request.identifier))
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
            ),
            lifecycleAccuracy: .verifiedLifecycleTransitions
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

    /// Gives already-runnable work a chance to run, for assertions that
    /// something did **not** happen.
    ///
    /// This is the only job `Task.yield()` can do honestly. It is not a wait:
    /// yielding hands the actor to whatever is already runnable, and a
    /// continuation parked on another executor is not made ready by it. Using
    /// it to wait for something to *arrive* is a coin flip that lands wrong
    /// under load — which is how "startup authorization refresh preserves
    /// transitions observed in flight" failed on CI with
    /// `(delivery.requests.count → 0) == 1` in run 32733740918. Every site
    /// here that waits for an event now uses ``waitUntil(_:within:)``; the
    /// remaining `settle()` calls precede assertions that a count stayed put,
    /// where a short settle can only make the test weaker, never flaky.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Waits for a condition on a wall-clock deadline, recording a failure
    /// rather than hanging if it never becomes true.
    @discardableResult
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        within duration: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for agent-notification test state")
        return false
    }
}

@MainActor
private final class RecordingAgentNotificationDelivery: AgentNotificationDelivering {
    var responseHandler: ((AgentNotificationResponseAction) -> Void)?
    var status: AgentNotificationAuthorizationStatus
    var requestResult = false
    var failuresRemaining = 0
    var suspendAuthorizationStatus = false
    private(set) var requests: [AgentNotificationRequest] = []
    private(set) var deliveryAttemptCount = 0
    private var authorizationStatusContinuation:
        CheckedContinuation<AgentNotificationAuthorizationStatus, Never>?

    var hasPendingAuthorizationStatusRequest: Bool {
        authorizationStatusContinuation != nil
    }

    init(status: AgentNotificationAuthorizationStatus) {
        self.status = status
    }

    func registerActions() {}
    func authorizationStatus() async -> AgentNotificationAuthorizationStatus {
        guard suspendAuthorizationStatus else { return status }
        return await withCheckedContinuation { continuation in
            authorizationStatusContinuation = continuation
        }
    }

    func resumeAuthorizationStatus() {
        suspendAuthorizationStatus = false
        authorizationStatusContinuation?.resume(returning: status)
        authorizationStatusContinuation = nil
    }
    func requestAuthorization() async throws -> Bool { requestResult }
    func deliver(_ request: AgentNotificationRequest) async throws {
        deliveryAttemptCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw RecordingDeliveryError.transient
        }
        requests.append(request)
    }
    func respond(_ action: AgentNotificationResponseAction) {
        responseHandler?(action)
    }
}

private enum RecordingDeliveryError: Error {
    case transient
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
