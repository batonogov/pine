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
    private struct DeferredEvent {
        let event: AgentNotificationEvent
        let task: AgentTask
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
    private var pendingDeliveryIDs: Set<String> = []
    @ObservationIgnored
    private var deliveryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var deferredEventOrder: [String] = []
    @ObservationIgnored
    private var deferredEvents: [String: DeferredEvent] = [:]

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
        isPresented: @escaping (UUID) -> Bool,
        openTask: @escaping (AgentNotificationRouteIdentity) -> Void
    ) {
        self.registry = registry
        self.settings = settings
        self.delivery = delivery
        self.accuracy = accuracy
        self.deliveryRetryDelays = deliveryRetryDelays
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
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                await self.refreshAuthorizationStatus()
            }
        }
        Task { await refreshAuthorizationStatus() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observerToken { registry.removeTaskChangeObserver(observerToken) }
        observerToken = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        delivery.responseHandler = nil
        delivery.presentationSuppression = nil
        deliveryTasks.values.forEach { $0.cancel() }
        deliveryTasks.removeAll()
        pendingDeliveryIDs.removeAll()
        clearDeferredEvents()
    }

    func refreshAuthorizationStatus() async {
        let previous = authorizationStatus
        let current = await delivery.authorizationStatus()
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
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await delivery.requestAuthorization()
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                settings.setEnabled(true)
                flushDeferredEvents()
            } else {
                Logger.agent.warning(
                    "Agent notification authorization request was denied; the user's enabled preference is kept"
                )
            }
            return granted
        } catch {
            Logger.agent.error(
                "Agent notification authorization request failed: \(error.localizedDescription, privacy: .public)"
            )
            await refreshAuthorizationStatus()
            return false
        }
    }

    func disable() {
        settings.setEnabled(false)
        clearDeferredEvents()
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
            switch authorizationStatus {
            case .authorized:
                scheduleDelivery(event: event, task: task)
            case .notDetermined:
                deferEvent(event, task: task)
            case .denied:
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
        guard pendingDeliveryIDs.insert(event.id).inserted else { return }
        let request = Self.request(for: event)
        deliveryTasks[event.id] = Task { @MainActor [weak self] in
            await self?.deliver(request, event: event, task: task)
        }
    }

    private func deferEvent(_ event: AgentNotificationEvent, task: AgentTask) {
        guard deferredEvents[event.id] == nil else { return }
        deferredEvents[event.id] = DeferredEvent(event: event, task: task)
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
        pending.forEach {
            scheduleDelivery(event: $0.event, task: $0.task)
        }
    }

    private func clearDeferredEvents() {
        deferredEventOrder.removeAll()
        deferredEvents.removeAll()
    }

    private func deliver(
        _ request: AgentNotificationRequest,
        event: AgentNotificationEvent,
        task: AgentTask
    ) async {
        let eventID = event.id
        defer {
            pendingDeliveryIDs.remove(eventID)
            deliveryTasks[eventID] = nil
        }

        let delays = [Duration.zero] + deliveryRetryDelays
        for (attempt, delay) in delays.enumerated() {
            guard isRunning,
                  settings.isEnabled,
                  !Task.isCancelled else { return }
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
            if delay > .zero {
                do {
                    try await ContinuousClock().sleep(for: delay)
                } catch {
                    return
                }
                guard isRunning, !Task.isCancelled else { return }
            }
            do {
                try await delivery.deliver(request)
            } catch {
                let reason = error.localizedDescription
                Logger.agent.warning(
                    "Agent notification attempt \(attempt + 1, privacy: .public) failed (id=\(eventID, privacy: .public))"
                )
                Logger.agent.warning(
                    "Agent notification delivery error (id=\(eventID, privacy: .public)): \(reason, privacy: .public)"
                )
                continue
            }
            // `UNUserNotificationCenter.add` does not throw when permission
            // was revoked in System Settings while Pine is running; re-read
            // the status so a revoked grant is not claimed as delivered.
            let currentStatus = await delivery.authorizationStatus()
            if currentStatus != authorizationStatus {
                let transition =
                    "\(String(describing: authorizationStatus)) -> \(String(describing: currentStatus))"
                Logger.agent.info(
                    "Agent notification authorization changed: \(transition, privacy: .public)"
                )
                authorizationStatus = currentStatus
            }
            guard currentStatus == .authorized else {
                Logger.agent.warning(
                    "Agent notification delivery re-armed: authorization revoked at delivery time (id=\(eventID, privacy: .public))"
                )
                deferEvent(event, task: task)
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
