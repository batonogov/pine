//
//  AgentNotificationController.swift
//  Pine
//

import AppKit
import Foundation
import os
import UserNotifications

nonisolated enum AgentNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

nonisolated struct AgentNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let categoryIdentifier: String
    let userInfo: [String: String]
}

nonisolated struct AgentNotificationRouteIdentity: Equatable, Sendable {
    let taskID: UUID
    let runID: UUID
    let processGeneration: UInt64
}

nonisolated enum AgentNotificationResponseAction: Equatable, Sendable {
    case open(AgentNotificationRouteIdentity)
    case mute(taskID: UUID)
}

/// Transfers the delegate's completion handler across the hop to the main
/// actor. The notification center invokes the delegate off the main actor,
/// the handler is called exactly once, and `UNNotificationPresentationOptions`
/// is value state, so no shared mutable state crosses the boundary.
nonisolated private final class NotificationPresentationHandlerBox: @unchecked Sendable {
    let handler: (UNNotificationPresentationOptions) -> Void

    init(_ handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        self.handler = handler
    }
}

@MainActor
protocol AgentNotificationDelivering: AnyObject {
    var responseHandler: ((AgentNotificationResponseAction) -> Void)? { get set }
    /// Presentation-time check for a delivered notification's task id; when
    /// it returns true the foreground banner is suppressed because the user
    /// is already watching that terminal route.
    var presentationSuppression: ((UUID) -> Bool)? { get set }
    func registerActions()
    func authorizationStatus() async -> AgentNotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func deliver(_ request: AgentNotificationRequest) async throws
}

@MainActor
final class SystemAgentNotificationCenter: NSObject,
    AgentNotificationDelivering, UNUserNotificationCenterDelegate {
    static let categoryIdentifier = "pine.agent.task"
    static let openActionIdentifier = "pine.agent.open"
    static let muteActionIdentifier = "pine.agent.mute"

    /// Presentation options requested while Pine is frontmost. The system
    /// default suppresses banners for the active app, so without
    /// ``userNotificationCenter(_:willPresent:withCompletionHandler:)`` the
    /// notifications a backgrounded project produced accumulate unseen in
    /// Notification Center and surface as a burst once Pine stops being
    /// frontmost (#1355).
    ///
    /// Suppression of an already-visible route happens twice: at delivery
    /// time in `AgentNotificationController.scheduleDelivery`, and again at
    /// presentation time in ``presentationOptions(forTaskID:)`` via
    /// ``presentationSuppression``, which covers a banner that was queued
    /// before the user switched to the route's tab. Everything else requests
    /// the full set.
    nonisolated static let foregroundPresentationOptions:
        UNNotificationPresentationOptions = [.banner, .list, .sound]

    var responseHandler: ((AgentNotificationResponseAction) -> Void)?
    var presentationSuppression: ((UUID) -> Bool)?
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    func registerActions() {
        let open = UNNotificationAction(
            identifier: Self.openActionIdentifier,
            title: String(localized: "agentNotifications.action.open"),
            options: [.foreground]
        )
        let mute = UNNotificationAction(
            identifier: Self.muteActionIdentifier,
            title: String(localized: "agentNotifications.action.mute")
        )
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [open, mute],
            intentIdentifiers: []
        )])
        center.delegate = self
    }

    func authorizationStatus() async -> AgentNotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ request: AgentNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.categoryIdentifier = request.categoryIdentifier
        content.userInfo = request.userInfo
        try await center.add(UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: nil
        ))
    }

    /// Foreground presentation decision for a delivered notification: a
    /// banner for the terminal route the user is currently watching stays
    /// silent; everything else gets the full foreground set so background
    /// agent work remains visible while Pine is frontmost.
    ///
    /// Suppression returns the empty set on purpose — no banner *and* no
    /// Notification Center `.list` entry — matching the delivery-time
    /// suppression in `AgentNotificationController.scheduleDelivery`: the
    /// user watched the process end live, so there is nothing to review
    /// later in Notification Center either.
    func presentationOptions(
        forTaskID taskID: UUID?
    ) -> UNNotificationPresentationOptions {
        guard let taskID, presentationSuppression?(taskID) == true else {
            return Self.foregroundPresentationOptions
        }
        Logger.agent.debug(
            "Suppressing foreground banner for presented agent task \(taskID.uuidString, privacy: .public)"
        )
        return []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let taskID = (notification.request.content.userInfo["taskID"] as? String)
            .flatMap(UUID.init(uuidString:))
        let handler = NotificationPresentationHandlerBox(completionHandler)
        Task { @MainActor [weak self] in
            handler.handler(
                self?.presentationOptions(forTaskID: taskID)
                    ?? Self.foregroundPresentationOptions
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let taskID = (userInfo["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let runID = (userInfo["runID"] as? String).flatMap(UUID.init(uuidString:))
        let generation = (userInfo["generation"] as? String).flatMap(UInt64.init)
        completionHandler()
        Task { @MainActor [weak self] in
            guard let taskID else { return }
            switch actionIdentifier {
            case Self.muteActionIdentifier:
                self?.responseHandler?(.mute(taskID: taskID))
            case Self.openActionIdentifier, UNNotificationDefaultActionIdentifier:
                guard let runID, let generation else { return }
                self?.responseHandler?(.open(AgentNotificationRouteIdentity(
                    taskID: taskID,
                    runID: runID,
                    processGeneration: generation
                )))
            default:
                break
            }
        }
    }
}

@MainActor
@Observable
final class AgentNotificationController {
    private struct PendingDelivery {
        let event: AgentNotificationEvent
        let token: UUID
        let task: Task<Void, Never>
    }

    private(set) var authorizationStatus: AgentNotificationAuthorizationStatus =
        .notDetermined

    let settings: AgentNotificationSettings
    @ObservationIgnored
    private let registry: AgentTaskRegistry
    @ObservationIgnored
    private let delivery: any AgentNotificationDelivering
    @ObservationIgnored
    private let accuracy: (String) -> FirstPartyAgentNotificationAccuracy
    @ObservationIgnored
    private let isPresented: (UUID) -> Bool
    @ObservationIgnored
    private let openTask: (AgentNotificationRouteIdentity) -> Void
    @ObservationIgnored
    private let deliveryRetryDelays: [Duration]
    @ObservationIgnored
    private var observerToken: UUID?
    @ObservationIgnored
    private var activationObserver: NSObjectProtocol?
    @ObservationIgnored
    private var isRunning = false
    @ObservationIgnored
    private var runGeneration: UInt64 = 0
    @ObservationIgnored
    private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored
    private var authorizationSequence: UInt64 = 0
    @ObservationIgnored
    private var permissionSequence: UInt64 = 0
    @ObservationIgnored
    private var authorizationPending = false
    @ObservationIgnored
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored
    private var deliveryTasks: [String: PendingDelivery] = [:]
    @ObservationIgnored
    private var deferredEventOrder: [String] = []
    @ObservationIgnored
    private var deferredEvents: [String: AgentNotificationEvent] = [:]
    @ObservationIgnored
    private let notificationCenter: NotificationCenter
    @ObservationIgnored
    private let retrySleep: (Duration) async throws -> Void

    init(
        registry: AgentTaskRegistry,
        settings: AgentNotificationSettings,
        delivery: any AgentNotificationDelivering = SystemAgentNotificationCenter(),
        accuracy: @escaping (String) -> FirstPartyAgentNotificationAccuracy = {
            AgentLifecycleAccuracyPolicy.production.accuracy(for: $0)
        },
        deliveryRetryDelays: [Duration] = [
            .milliseconds(250),
            .seconds(1),
        ],
        notificationCenter: NotificationCenter = .default,
        retrySleep: @escaping (Duration) async throws -> Void = { delay in
            try await ContinuousClock().sleep(for: delay)
        },
        isPresented: @escaping (UUID) -> Bool,
        openTask: @escaping (AgentNotificationRouteIdentity) -> Void
    ) {
        self.registry = registry
        self.settings = settings
        self.delivery = delivery
        self.accuracy = accuracy
        self.deliveryRetryDelays = deliveryRetryDelays
        self.notificationCenter = notificationCenter
        self.retrySleep = retrySleep
        self.isPresented = isPresented
        self.openTask = openTask
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        delivery.registerActions()
        delivery.responseHandler = { [weak self] action in
            self?.handle(action)
        }
        delivery.presentationSuppression = { [weak self] taskID in
            self?.isPresented(taskID) ?? false
        }
        observerToken = registry.addTaskChangeObserver { [weak self] old, new in
            self?.process(oldTasks: old, newTasks: new)
        }
        // Permission can change in System Settings while Pine runs; re-read
        // it on activation so delivery recovers without a relaunch.
        let generation = runGeneration
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning,
                      self.runGeneration == generation else { return }
                await self.refreshAuthorizationStatus()
            }
        }
        Task { [weak self] in
            guard let self, self.isRunning,
                  self.runGeneration == generation else { return }
            await self.refreshAuthorizationStatus()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        runGeneration &+= 1
        if let observerToken { registry.removeTaskChangeObserver(observerToken) }
        observerToken = nil
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        delivery.responseHandler = nil
        delivery.presentationSuppression = nil
        invalidateDeliveries()
    }

    func refreshAuthorizationStatus() async {
        let generation = lifecycleGeneration
        authorizationSequence &+= 1
        let sequence = authorizationSequence
        authorizationPending = true
        let current = await delivery.authorizationStatus()
        guard generation == lifecycleGeneration,
              sequence == authorizationSequence else { return }
        let previous = authorizationStatus
        authorizationStatus = current
        if current != previous {
            let transition = "\(String(describing: previous)) -> \(String(describing: current))"
            Logger.agent.info(
                "Agent notification authorization changed: \(transition, privacy: .public)"
            )
        }
        // The persisted master toggle stays the user's choice on every
        // status; OS authorization is a runtime condition only, so a grant
        // restored in System Settings resumes delivery on its own.
        if current == .authorized {
            flushDeferredEvents()
        }
        finishAuthorizationSettlement()
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let generation = lifecycleGeneration
        permissionSequence &+= 1
        let intent = permissionSequence
        authorizationSequence &+= 1
        authorizationPending = true
        do {
            let granted = try await delivery.requestAuthorization()
            guard generation == lifecycleGeneration,
                  intent == permissionSequence else { return false }
            // An observational read cannot cancel an explicit enable intent.
            // The permission result also supersedes reads begun during the
            // prompt, which may have sampled the pre-prompt OS status.
            authorizationSequence &+= 1
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                settings.setEnabled(true)
                flushDeferredEvents()
            } else {
                Logger.agent.warning(
                    "Agent notification authorization request was denied; the user's enabled preference is kept"
                )
            }
            finishAuthorizationSettlement()
            return granted
        } catch {
            guard generation == lifecycleGeneration,
                  intent == permissionSequence else { return false }
            Logger.agent.error(
                "Agent notification authorization request failed: \(error.localizedDescription, privacy: .public)"
            )
            await refreshAuthorizationStatus()
            return false
        }
    }

    func disable() {
        settings.setEnabled(false)
        invalidateDeliveries()
    }

    private func process(oldTasks: [AgentTask], newTasks: [AgentTask]) {
        guard isRunning, settings.isEnabled else { return }
        let events = AgentNotificationTransitionResolver.events(
            from: oldTasks,
            to: newTasks,
            accuracy: accuracy
        )
        let tasks = Dictionary(uniqueKeysWithValues: newTasks.map { ($0.id, $0) })
        for event in events {
            Logger.agent.debug(
                "Agent notification event resolved: kind=\(event.kind.rawValue, privacy: .public) id=\(event.id, privacy: .public)"
            )
            guard let task = tasks[event.taskID] else { continue }
            supersedeOlderEvents(with: event)
            switch authorizationStatus {
            case .authorized:
                scheduleDelivery(event: event, task: task)
            case .notDetermined:
                deferEvent(event, task: task)
            case .denied:
                // Deliberate drop, not defer: events resolved while denied
                // are discarded so a later re-grant cannot replay arbitrarily
                // old history. Only events already in flight when revocation
                // is discovered are re-armed (see `deliver`).
                Logger.agent.debug(
                    "Agent notification event dropped: authorization denied (id=\(event.id, privacy: .public))"
                )
            }
        }
    }

    private func scheduleDelivery(
        event: AgentNotificationEvent,
        task: AgentTask
    ) {
        guard isRunning else { return }
        guard settings.allows(event, task: task) else {
            Logger.agent.debug(
                "Agent notification suppressed by settings filters (id=\(event.id, privacy: .public))"
            )
            return
        }
        guard !isPresented(event.taskID) else {
            Logger.agent.debug(
                "Agent notification suppressed: terminal route is presented (id=\(event.id, privacy: .public))"
            )
            return
        }
        guard !settings.hasDelivered(event.id) else {
            Logger.agent.debug(
                "Agent notification suppressed: already delivered (id=\(event.id, privacy: .public))"
            )
            return
        }
        guard deliveryTasks[event.id] == nil else { return }
        let token = UUID()
        let generation = lifecycleGeneration
        let operation = Task<Void, Never> { @MainActor [weak self] in
            await self?.deliver(event: event, token: token, generation: generation)
        }
        deliveryTasks[event.id] = PendingDelivery(event: event, token: token, task: operation)
    }

    private func deferEvent(_ event: AgentNotificationEvent, task: AgentTask) {
        guard deferredEvents[event.id] == nil else { return }
        guard currentTask(for: event) != nil else { return }
        deferredEvents[event.id] = event
        deferredEventOrder.append(event.id)
        if deferredEventOrder.count > 512 {
            let discardCount = deferredEventOrder.count - 384
            let discarded = Array(deferredEventOrder.prefix(discardCount))
            deferredEventOrder.removeFirst(discardCount)
            discarded.forEach { deferredEvents[$0] = nil }
        }
    }

    private func flushDeferredEvents() {
        let pending = deferredEventOrder.compactMap { deferredEvents[$0] }
        clearDeferredEvents()
        for event in pending {
            // A delayed notification must still describe the current run:
            // the user may have dismissed, resumed, or answered the task
            // while the notification service was unavailable.
            guard let task = currentTask(for: event) else { continue }
            scheduleDelivery(event: event, task: task)
        }
    }

    private func currentTask(for event: AgentNotificationEvent) -> AgentTask? {
        guard let task = registry.task(for: event.taskID),
              task.lifecycle != .dismissed,
              let run = task.runs.last,
              run.id == event.runID,
              run.process.processGeneration == event.processGeneration,
              run.liveness != .stale else { return nil }
        let isCurrent: Bool = switch event.kind {
        case .processEnded: run.liveness == .terminated
        case .waitingInput: run.liveness == .live && run.state == .waitingInput
        case .failed: task.attention == .failed
        case .completed:
            task.attention == .completed || task.lifecycle == .completed || run.state == .done
        }
        return isCurrent ? task : nil
    }

    private func clearDeferredEvents() {
        deferredEventOrder.removeAll()
        deferredEvents.removeAll()
    }

    private func finishAuthorizationSettlement() {
        authorizationPending = false
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForAuthorizationSettlement(generation: UInt64) async {
        // A newer read merely starting is not evidence of permission. In
        // particular an old post-add denial must not claim against the cached
        // grant while the newer authoritative read is still suspended.
        while generation == lifecycleGeneration, authorizationPending, !Task.isCancelled {
            await withCheckedContinuation { authorizationWaiters.append($0) }
        }
    }

    private func invalidateDeliveries() {
        lifecycleGeneration &+= 1
        authorizationSequence &+= 1
        permissionSequence &+= 1
        finishAuthorizationSettlement()
        deliveryTasks.values.forEach { $0.task.cancel() }
        deliveryTasks.removeAll()
        clearDeferredEvents()
    }

    private func supersedeOlderEvents(with event: AgentNotificationEvent) {
        // Only resolved transitions supersede events. A waiting-to-waiting poll
        // advances lastObservedAt but must not invalidate a recoverable wait.
        func isOlder(_ previous: AgentNotificationEvent) -> Bool {
            previous.taskID == event.taskID && previous.runID == event.runID
                && previous.processGeneration == event.processGeneration
                && previous.kind == event.kind && previous.observedAt < event.observedAt
        }
        for (id, previous) in deferredEvents where isOlder(previous) {
            deferredEvents[id] = nil
        }
        deferredEventOrder.removeAll { deferredEvents[$0] == nil }
        for (id, pending) in deliveryTasks where isOlder(pending.event) {
            pending.task.cancel()
            deliveryTasks[id] = nil
        }
    }

    private func deliver(
        event: AgentNotificationEvent,
        token: UUID,
        generation: UInt64
    ) async {
        let eventID = event.id
        defer {
            // A cancelled completion must not remove a restarted job's claim.
            if deliveryTasks[eventID]?.token == token { deliveryTasks[eventID] = nil }
        }
        func isActive() -> Bool {
            isRunning && generation == lifecycleGeneration && !Task.isCancelled
                && deliveryTasks[eventID]?.token == token
        }
        func eligibleTask() -> AgentTask? {
            guard isActive(), let task = currentTask(for: event),
                  settings.allows(event, task: task), !isPresented(event.taskID),
                  !settings.hasDelivered(eventID) else { return nil }
            return task
        }

        let request = Self.request(for: event)
        let delays = [Duration.zero] + deliveryRetryDelays
        for (attempt, delay) in delays.enumerated() {
            guard isActive() else { return }
            if delay > .zero {
                do { try await retrySleep(delay) } catch { return }
            }
            // This check is deliberately AFTER the backoff and before every
            // attempt, rather than against the original task/settings snapshot.
            guard let task = eligibleTask() else { return }
            guard authorizationStatus == .authorized else {
                // Authorization was revoked or reset before this attempt
                // ran; re-arm the event so the flush that follows an
                // authorization recovery can deliver it instead of the
                // event being silently consumed.
                Logger.agent.warning(
                    "Agent notification delivery re-armed: authorization is not authorized (id=\(eventID, privacy: .public))"
                )
                deferEvent(event, task: task)
                return
            }

            do {
                try await delivery.deliver(request)
            } catch {
                let reason = error.localizedDescription
                let message = "Agent notification attempt \(attempt + 1) "
                    + "failed (id=\(eventID)): \(reason)"
                Logger.agent.warning("\(message, privacy: .public)")
                continue
            }
            // `UNUserNotificationCenter.add` does not throw when permission
            // was revoked in System Settings while Pine is running; re-read
            // the status so a revoked grant is not claimed as delivered.
            guard isActive() else { return }
            await refreshAuthorizationStatus()
            await waitForAuthorizationSettlement(generation: generation)
            guard isActive() else { return }
            // A superseded status response still finishes this one-shot event
            // using the newest accepted authorization, never its stale result.
            guard authorizationStatus == .authorized else {
                Logger.agent.warning(
                    "Agent notification delivery re-armed: authorization revoked at delivery time (id=\(eventID, privacy: .public))"
                )
                if let task = eligibleTask() { deferEvent(event, task: task) }
                return
            }
            _ = settings.claimDelivery(of: eventID)
            Logger.agent.debug(
                "Agent notification delivered and claimed (id=\(eventID, privacy: .public))"
            )
            return
        }
        Logger.agent.error(
            "Agent notification exhausted \(delays.count, privacy: .public) attempts (id=\(eventID, privacy: .public)); still undelivered"
        )
        // Registry transitions are one-shot: an ended process will not emit
        // its event again when the notification service recovers. Retain it
        // in the bounded queue for the next activation/authorization refresh
        // rather than requiring an impossible replay of the transition.
        guard let task = eligibleTask() else { return }
        deferEvent(event, task: task)
    }

    private func handle(_ action: AgentNotificationResponseAction) {
        switch action {
        case .open(let identity): openTask(identity)
        case .mute(let taskID): settings.muteTask(taskID)
        }
    }

    static func request(for event: AgentNotificationEvent) -> AgentNotificationRequest {
        let titleKey = switch event.kind {
        case .waitingInput: "agentNotifications.event.waiting"
        case .failed: "agentNotifications.event.failed"
        case .completed: "agentNotifications.event.completed"
        case .processEnded: "agentNotifications.event.processEnded"
        }
        let state = String(localized: String.LocalizationValue(titleKey))
        let title = "\(event.agentName): \(state)"
        let elapsed = Duration.seconds(
            max(0, event.observedAt.timeIntervalSince(event.startedAt))
        ).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        let fields = [event.projectName, event.taskTitle, elapsed].compactMap { $0 }
        return AgentNotificationRequest(
            identifier: event.id,
            title: title,
            body: fields.joined(separator: " • "),
            categoryIdentifier: SystemAgentNotificationCenter.categoryIdentifier,
            userInfo: [
                "taskID": event.taskID.uuidString,
                "runID": event.runID.uuidString,
                "generation": String(event.processGeneration),
            ]
        )
    }
}
