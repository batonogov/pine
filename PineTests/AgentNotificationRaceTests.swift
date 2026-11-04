import AppKit
import Foundation
import Testing
@testable import Pine

@MainActor
struct AgentNotificationRaceTests {
    @Test(arguments: [
        "mute", "disable", "dismiss", "answer", "run", "generation", "missing",
        "stale", "presented", "event", "agent", "project", "restart",
    ])
    func retryRevalidates(_ change: String) async throws {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.delivery.parkDeliveries = true
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.attempts == 1 })
        switch change {
        case "mute": fixture.settings.muteTask(fixture.current.id)
        case "disable":
            fixture.controller.disable()
            fixture.settings.setEnabled(true)
        case "dismiss": fixture.current.lifecycle = .dismissed
        case "answer": fixture.current.runs[0].state = .executing
        case "run": fixture.current.runs = NotificationRaceFixture.makeTask().runs
        case "generation":
            let old = fixture.current.runs[0].process
            fixture.current.runs[0].process = AgentProcessEvidence(
                processIdentifier: old.processIdentifier,
                processGeneration: old.processGeneration + 1,
                startIdentifier: old.startIdentifier,
                observedStartedAt: old.observedStartedAt
            )
        case "stale": fixture.current.runs[0].liveness = .stale
        case "presented": fixture.presented = true
        case "event": fixture.settings.setEvent(.waitingInput, enabled: false)
        case "agent": fixture.settings.setAgent(fixture.current.descriptor.typeIdentifier, enabled: false)
        case "project": fixture.settings.setProject(fixture.current.project.canonicalProjectPath, enabled: false)
        case "restart":
            fixture.controller.stop()
            fixture.controller.start()
        default: break
        }
        fixture.registry.setTasksForTesting(change == "missing" ? [] : [fixture.current])
        fixture.delivery.parkDeliveries = false
        fixture.delivery.finishDelivery(1, fails: true)
        await fixture.settle()
        #expect(fixture.delivery.attempts == 1)
        #expect(fixture.settings.deliveredEventIDs.isEmpty)
    }

    @Test(arguments: [true, false])
    func eventDuringAuthorizationRecoveryUsesFreshStatus(_ granted: Bool) async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        await fixture.refresh(.denied)
        let refresh = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
        fixture.waiting(offset: 1)
        fixture.delivery.finishStatus(3, granted ? .authorized : .denied)
        await refresh.value
        if granted {
            #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(4) })
            fixture.delivery.finishStatus(4, .authorized)
            #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 1 })
            #expect(fixture.delivery.attempts == 1)
        } else {
            await fixture.activate()
            #expect(fixture.delivery.attempts == 0)
            #expect(fixture.settings.deliveredEventIDs.isEmpty)
        }
    }

    @Test func deniedRefreshDiscardsOnlyProvisionalEvents() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        fixture.delivery.finishStatus(2, .denied)
        #expect(await waitUntilMainActor { fixture.controller.authorizationStatus == .denied })
        await fixture.settle()

        let other = NotificationRaceFixture.makeTask()
        fixture.registry.setTasksForTesting([fixture.current, other])
        let refresh = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
        var waiting = other
        waiting.runs[0].state = .waitingInput
        waiting.runs[0].lastObservedAt.addTimeInterval(1)
        fixture.registry.setTasksForTesting([fixture.current, waiting])
        fixture.delivery.finishStatus(3, .denied)
        await refresh.value

        await fixture.activate()
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(5) })
        fixture.delivery.finishStatus(5, .authorized)
        #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 1 })
        #expect(fixture.delivery.attempts == 2)
        #expect(fixture.delivery.requests.allSatisfy {
            $0.userInfo["taskID"] == fixture.current.id.uuidString
        })
    }

    @Test func refreshResponsesAreOrdered() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        let old = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        let new = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
        fixture.delivery.finishStatus(3, .authorized)
        await new.value
        fixture.delivery.finishStatus(2, .denied)
        await old.value
        #expect(fixture.controller.authorizationStatus == .authorized)
    }

    @Test(arguments: [true, false])
    func stalePostDeliveryResponseFinishesEvent(_ latestAuthorized: Bool) async throws {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        let refresh = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
        fixture.delivery.finishStatus(3, latestAuthorized ? .authorized : .denied)
        await refresh.value
        fixture.delivery.finishStatus(2, latestAuthorized ? .denied : .authorized)
        await fixture.settle()
        #expect(fixture.controller.authorizationStatus == (latestAuthorized ? .authorized : .denied))
        #expect(fixture.settings.deliveredEventIDs.count == (latestAuthorized ? 1 : 0))
        let recovery = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(4) })
        fixture.delivery.finishStatus(4, .authorized)
        await recovery.value
        await fixture.settle()
        if !latestAuthorized {
            #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(5) })
            fixture.delivery.finishStatus(5, .authorized)
        }
        #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 1 })
        #expect(fixture.delivery.attempts == (latestAuthorized ? 1 : 2))
    }

    @Test(arguments: ["stop", "disable"])
    func deliveryCompletionCannotCrossLifecycle(_ boundary: String) async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        if boundary == "stop" {
            fixture.controller.stop()
            fixture.controller.start()
        } else {
            fixture.controller.disable()
            fixture.settings.setEnabled(true)
        }
        fixture.delivery.finishStatus(2, .denied)
        await fixture.settle()
        #expect(fixture.controller.authorizationStatus == .authorized)
        #expect(fixture.settings.deliveredEventIDs.isEmpty)
        fixture.delivery.finishAllStatuses(.authorized)
        await fixture.settle()
        #expect(fixture.delivery.attempts == 1)
    }

    @Test(arguments: [true, false])
    func deferredWaitingTracksTransitionsNotPolls(_ newCycle: Bool) async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        // Keep startup authorization unresolved so waiting is deferred.
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(1) })
        fixture.waiting(offset: 1)
        if newCycle {
            fixture.current.runs[0].state = .executing
            fixture.registry.setTasksForTesting([fixture.current])
        }
        fixture.waiting(offset: 2)
        fixture.delivery.finishStatus(1, .authorized)
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.count >= 1 })
        fixture.delivery.finishAllStatuses(.authorized)
        #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count >= 1 })
        await fixture.settle()
        #expect(fixture.delivery.attempts == 1)
        let expected = AgentNotificationTransitionResolver.events(
            from: [fixture.initial], to: [fixture.current], accuracy: { _ in .verifiedLifecycleTransitions }
        ).first
        if newCycle {
            #expect(fixture.delivery.requests.first?.identifier == expected?.id)
        } else {
            #expect(fixture.delivery.requests.first?.identifier != expected?.id)
        }
    }
    @Test(arguments: ["mute", "disable", "answer", "presented", "authorization"])
    func retryRevalidatesAfterBackoff(_ change: String) async {
        let fixture = NotificationRaceFixture(gatedBackoff: true)
        defer { fixture.close() }
        await fixture.ready()
        fixture.delivery.failDeliveries = true
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.retryContinuation != nil })
        switch change {
        case "mute": fixture.settings.muteTask(fixture.current.id)
        case "disable": fixture.controller.disable()
        case "answer":
            fixture.current.runs[0].state = .executing
            fixture.registry.setTasksForTesting([fixture.current])
        case "presented": fixture.presented = true
        default: await fixture.refresh(.denied)
        }
        fixture.delivery.failDeliveries = false
        fixture.releaseRetry()
        await fixture.settle()
        #expect(fixture.delivery.attempts == 1)
        if change == "authorization" {
            await fixture.refresh(.authorized)
            #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(4) })
            fixture.delivery.finishStatus(4, .authorized)
            #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 1 })
        }
    }

    @Test(arguments: ["refresh", "disable", "stop", "error"])
    func permissionRequestPreservesIntentAcrossObservation(_ boundary: String) async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        if boundary == "refresh" { fixture.settings.setEnabled(false) }
        let request = Task { await fixture.controller.requestAuthorization() }
        #expect(await waitUntilMainActor { fixture.delivery.permissionContinuation != nil })
        if boundary == "disable" {
            fixture.controller.disable()
        } else if boundary == "stop" {
            fixture.controller.stop()
        } else {
            await fixture.refresh(.denied)
        }
        fixture.delivery.finishPermission(fails: boundary == "error")
        if boundary == "error" {
            #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
            fixture.delivery.finishStatus(3, .denied)
        }
        #expect(await request.value == (boundary == "refresh"))
        await fixture.settle()
        #expect(fixture.controller.authorizationStatus == (boundary == "error" ? .denied : .authorized))
        if boundary == "disable" { #expect(!fixture.settings.isEnabled) }
        if boundary == "refresh" { #expect(fixture.settings.isEnabled) }
        #expect(fixture.delivery.statusIDs.isEmpty)
    }

    @Test(arguments: ["stop", "disable"])
    func acceptedDeliveryCannotCrossLifecycle(_ boundary: String) async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.delivery.parkDeliveries = true
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.attempts == 1 })
        if boundary == "stop" { fixture.controller.stop() } else { fixture.controller.disable() }
        fixture.delivery.finishDelivery(1, fails: false)
        await fixture.settle()
        #expect(fixture.delivery.statusIDs.isEmpty)
        #expect(fixture.settings.deliveredEventIDs.isEmpty)
    }

    @Test func exhaustedRecoveryIsBoundedAndDuplicateFree() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.delivery.failDeliveries = true
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.attempts == 2 })
        await fixture.activate()
        #expect(await waitUntilMainActor { fixture.delivery.attempts == 4 })
        await fixture.settle()
        #expect(fixture.delivery.attempts == 4)
        fixture.delivery.failDeliveries = false
        // Continuous waiting polls must not discard the exhausted event.
        fixture.waiting(offset: 2)
        await fixture.activate()
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(4) })
        fixture.delivery.finishStatus(4, .authorized)
        #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 1 })
        await fixture.activate()
        #expect(fixture.delivery.attempts == 5)
        #expect(fixture.delivery.requests.count == 1)
    }

    @Test func exhaustedWaitingCycleSupersedesOldEvent() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.delivery.failDeliveries = true
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.attempts == 2 })
        fixture.current.runs[0].state = .executing
        fixture.registry.setTasksForTesting([fixture.current])
        fixture.waiting(offset: 2)
        #expect(await waitUntilMainActor { fixture.delivery.attempts == 4 })
        fixture.delivery.failDeliveries = false
        await fixture.activate()
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
        fixture.delivery.finishStatus(3, .authorized)
        #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 1 })
        #expect(fixture.delivery.requests.count == 1)
        let expected = AgentNotificationTransitionResolver.events(
            from: [fixture.initial], to: [fixture.current], accuracy: { _ in .verifiedLifecycleTransitions }
        ).first
        #expect(fixture.delivery.requests.first?.identifier == expected?.id)
    }

    @Test func supersededInFlightCompletionCannotRearmOldWait() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        fixture.current.runs[0].state = .executing
        fixture.registry.setTasksForTesting([fixture.current])
        fixture.waiting(offset: 2)
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
        fixture.delivery.finishStatus(3, .authorized)
        #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 1 })
        fixture.delivery.finishStatus(2, .denied)
        await fixture.settle()
        await fixture.activate()
        #expect(fixture.delivery.attempts == 2)
        #expect(fixture.settings.deliveredEventIDs.count == 1)
        #expect(fixture.controller.authorizationStatus == .authorized)
    }

    @Test(arguments: [true, false])
    func deliveryWaitsForNewerPendingAuthorization(_ newerAuthorized: Bool) async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        let newer = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
        // The old post-delivery denial arrives FIRST, before the newer read.
        fixture.delivery.finishStatus(2, .denied)
        await fixture.settle()
        #expect(fixture.settings.deliveredEventIDs.isEmpty)
        #expect(fixture.delivery.attempts == 1)
        fixture.delivery.finishStatus(3, newerAuthorized ? .authorized : .denied)
        await newer.value
        await fixture.settle()
        #expect(fixture.settings.deliveredEventIDs.count == (newerAuthorized ? 1 : 0))
        await fixture.refresh(.authorized)
        if !newerAuthorized {
            #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(5) })
            fixture.delivery.finishStatus(5, .authorized)
        }
        #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 1 })
        #expect(fixture.delivery.attempts == (newerAuthorized ? 1 : 2))
    }

    @Test func newerPermissionIntentWins() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.settings.setEnabled(false)
        let old = Task { await fixture.controller.requestAuthorization() }
        #expect(await waitUntilMainActor { fixture.delivery.permissionIDs.contains(1) })
        let newer = Task { await fixture.controller.requestAuthorization() }
        #expect(await waitUntilMainActor { fixture.delivery.permissionIDs.contains(2) })
        fixture.delivery.finishPermission(2, granted: false)
        #expect(await newer.value == false)
        fixture.delivery.finishPermission(1)
        #expect(await old.value == false)
        #expect(fixture.controller.authorizationStatus == .denied)
        #expect(!fixture.settings.isEnabled)
    }

    @Test func permissionCompletionSupersedesInFlightObservation() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.settings.setEnabled(false)
        let request = Task { await fixture.controller.requestAuthorization() }
        #expect(await waitUntilMainActor { fixture.delivery.permissionIDs.contains(1) })
        let observation = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        fixture.delivery.finishPermission(1)
        #expect(await request.value)
        fixture.delivery.finishStatus(2, .denied)
        await observation.value
        #expect(fixture.controller.authorizationStatus == .authorized)
        #expect(fixture.settings.isEnabled)
    }

    @Test(arguments: ["stop", "disable"])
    func authorizationSettlementWaiterRespectsLifecycle(_ boundary: String) async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        let newer = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
        fixture.delivery.finishStatus(2, .denied)
        await fixture.settle()
        if boundary == "stop" { fixture.controller.stop() } else { fixture.controller.disable() }
        await fixture.settle()
        fixture.delivery.finishStatus(3, .denied)
        await newer.value
        #expect(fixture.controller.authorizationStatus == .authorized)
        #expect(fixture.settings.deliveredEventIDs.isEmpty)
        #expect(fixture.delivery.attempts == 1)
    }

    @Test func permissionGrantSupersedesOlderRefresh() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        let old = Task { await fixture.controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        let request = Task { await fixture.controller.requestAuthorization() }
        #expect(await waitUntilMainActor { fixture.delivery.permissionContinuation != nil })
        fixture.delivery.finishPermission()
        #expect(await request.value)
        fixture.delivery.finishStatus(2, .denied)
        await old.value
        #expect(fixture.controller.authorizationStatus == .authorized)
        #expect(fixture.settings.isEnabled)
    }

    @Test func activationSurvivesDisableWithoutCrossingControllers() async {
        let fixture = NotificationRaceFixture()
        let other = NotificationRaceFixture()
        defer { fixture.close(); other.close() }
        await fixture.ready()
        await other.ready()
        fixture.controller.disable()
        fixture.settings.setEnabled(true)
        await fixture.activate()
        #expect(fixture.delivery.statusReadCount == 2)
        #expect(other.delivery.statusReadCount == 1)
    }

    @Test func oldCompletionCannotRemoveRestartedJob() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        await fixture.ready()
        fixture.waiting(offset: 1)
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(2) })
        fixture.controller.stop()
        fixture.controller.start()
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(3) })
        fixture.delivery.finishStatus(3, .authorized)
        await fixture.settle()
        fixture.registry.setTasksForTesting([fixture.initial])
        fixture.registry.setTasksForTesting([fixture.current])
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(4) })
        fixture.delivery.finishStatus(2, .denied)
        await fixture.settle()
        fixture.registry.setTasksForTesting([fixture.initial])
        fixture.registry.setTasksForTesting([fixture.current])
        await fixture.settle()
        #expect(fixture.delivery.attempts == 2)
        fixture.delivery.finishStatus(4, .authorized)
        #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 1 })
    }

    @Test func deferredQueueRemainsBounded() async {
        let fixture = NotificationRaceFixture()
        defer { fixture.close() }
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.contains(1) })
        let working = (0..<520).map { _ in NotificationRaceFixture.makeTask() }
        fixture.registry.setTasksForTesting(working)
        var waiting = working
        for index in waiting.indices {
            waiting[index].runs[0].state = .waitingInput
            waiting[index].runs[0].lastObservedAt.addTimeInterval(1)
        }
        fixture.registry.setTasksForTesting(waiting)
        fixture.delivery.finishStatus(1, .authorized)
        // At 513 events, prune to 384; the remaining seven yield 391.
        #expect(await waitUntilMainActor { fixture.delivery.statusIDs.count == 391 })
        fixture.delivery.finishAllStatuses(.authorized)
        #expect(await waitUntilMainActor { fixture.settings.deliveredEventIDs.count == 391 })
        #expect(Set(fixture.delivery.requests.map(\.identifier)).count == 391)
        await fixture.activate()
        #expect(fixture.delivery.attempts == 391)
    }
}

@MainActor
private final class NotificationRaceFixture {
    let defaultsName = "Pine.NotificationRace.\(UUID())"
    let registry = AgentTaskRegistry()
    let delivery = AddressedNotificationDelivery()
    let settings: AgentNotificationSettings
    let initial: AgentTask
    var current: AgentTask
    var presented = false
    let notificationCenter = NotificationCenter()
    let gatedBackoff: Bool
    var retryContinuation: CheckedContinuation<Void, Never>?
    lazy var controller = AgentNotificationController(
        registry: registry, settings: settings, delivery: delivery,
        accuracy: { _ in .verifiedLifecycleTransitions },
        deliveryRetryDelays: [gatedBackoff ? .seconds(1) : .zero],
        notificationCenter: notificationCenter,
        retrySleep: { [weak self] _ in
            guard let self else { return }
            await withCheckedContinuation { self.retryContinuation = $0 }
        },
        isPresented: { [weak self] _ in self?.presented ?? false }, openTask: { _ in }
    )

    init(gatedBackoff: Bool = false) {
        self.gatedBackoff = gatedBackoff
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            fatalError("Cannot create isolated notification-test defaults")
        }
        settings = AgentNotificationSettings(defaults: defaults)
        settings.setEnabled(true)
        initial = Self.makeTask()
        current = initial
        controller.start()
        registry.setTasksForTesting([initial])
    }

    static func makeTask() -> AgentTask {
        let date = Date().addingTimeInterval(-100)
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(canonicalProjectPath: "/tmp/notification-race", canonicalWorktreePath: "/tmp/notification-race"),
            route: AgentTaskRoute(paneID: UUID(), tabID: UUID(), terminalID: UUID()),
            origin: .discoveredInTerminal, observedAt: date
        )
        var task = AgentTask(descriptor: AgentDescriptor(agentType: .codex), context: context)
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: UUID(), terminalID: context.route.terminalID,
            process: AgentProcessEvidence(processIdentifier: 42, processGeneration: 1, startIdentifier: "race", observedStartedAt: date),
            status: AgentTaskRunStatus(state: .executing, liveness: .live, observedAt: date),
            lifecycleAccuracy: .verifiedLifecycleTransitions
        ))]
        return task
    }

    func ready() async {
        #expect(await waitUntilMainActor { self.delivery.statusIDs.contains(1) })
        delivery.finishStatus(1, .authorized)
        #expect(await waitUntilMainActor { self.controller.authorizationStatus == .authorized })
    }

    func waiting(offset: TimeInterval) {
        current.runs[0].state = .waitingInput
        current.runs[0].lastObservedAt = initial.runs[0].startedAt.addingTimeInterval(offset)
        registry.setTasksForTesting([current])
    }

    func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    func refresh(_ status: AgentNotificationAuthorizationStatus) async {
        let id = delivery.statusReadCount + 1
        let operation = Task { await controller.refreshAuthorizationStatus() }
        #expect(await waitUntilMainActor { self.delivery.statusIDs.contains(id) })
        delivery.finishStatus(id, status)
        await operation.value
    }

    func activate() async {
        let id = delivery.statusReadCount + 1
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await waitUntilMainActor { self.delivery.statusIDs.contains(id) })
        delivery.finishStatus(id, .authorized)
        await settle()
    }

    func releaseRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }

    func close() {
        controller.stop()
        delivery.finishAllStatuses(.authorized)
        delivery.finishAllDeliveries()
        releaseRetry()
        for id in delivery.permissionIDs { delivery.finishPermission(id) }
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}

@MainActor
private final class AddressedNotificationDelivery: AgentNotificationDelivering {
    var responseHandler: ((AgentNotificationResponseAction) -> Void)?
    var presentationSuppression: ((UUID) -> Bool)?
    var parkDeliveries = false
    var failDeliveries = false
    private var permissions: [Int: CheckedContinuation<Bool, Error>] = [:]
    private var permissionReadCount = 0
    var permissionIDs: Set<Int> { Set(permissions.keys) }
    var permissionContinuation: CheckedContinuation<Bool, Error>? { permissions.values.first }
    private(set) var attempts = 0
    private(set) var requests: [AgentNotificationRequest] = []
    private(set) var statusReadCount = 0
    private var statuses: [Int: CheckedContinuation<AgentNotificationAuthorizationStatus, Never>] = [:]
    private var deliveries: [Int: CheckedContinuation<Void, Error>] = [:]
    var statusIDs: Set<Int> { Set(statuses.keys) }
    func registerActions() {}
    func authorizationStatus() async -> AgentNotificationAuthorizationStatus {
        statusReadCount += 1
        let id = statusReadCount
        return await withCheckedContinuation { statuses[id] = $0 }
    }
    func requestAuthorization() async throws -> Bool {
        permissionReadCount += 1
        let id = permissionReadCount
        return try await withCheckedThrowingContinuation { permissions[id] = $0 }
    }
    func finishPermission(_ id: Int = 1, granted: Bool = true, fails: Bool = false) {
        let continuation = permissions.removeValue(forKey: id)
        if fails { continuation?.resume(throwing: CocoaError(.coderInvalidValue)) } else { continuation?.resume(returning: granted) }
    }
    func deliver(_ request: AgentNotificationRequest) async throws {
        attempts += 1
        let id = attempts
        if failDeliveries { throw CocoaError(.coderInvalidValue) }
        if parkDeliveries {
            try await withCheckedThrowingContinuation { deliveries[id] = $0 }
        }
        requests.append(request)
    }
    func finishStatus(_ id: Int, _ status: AgentNotificationAuthorizationStatus) {
        statuses.removeValue(forKey: id)?.resume(returning: status)
    }
    func finishAllStatuses(_ status: AgentNotificationAuthorizationStatus) {
        for id in statusIDs { finishStatus(id, status) }
    }
    func finishDelivery(_ id: Int, fails: Bool) {
        let continuation = deliveries.removeValue(forKey: id)
        if fails { continuation?.resume(throwing: CocoaError(.coderInvalidValue)) } else { continuation?.resume() }
    }
    func finishAllDeliveries() {
        for id in Array(deliveries.keys) { finishDelivery(id, fails: false) }
    }
}
