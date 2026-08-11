//
//  AgentNotificationController.swift
//  Pine
//

import Foundation
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

@MainActor
protocol AgentNotificationDelivering: AnyObject {
    var responseHandler: ((AgentNotificationResponseAction) -> Void)? { get set }
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
    /// Suppression of an already-visible route stays with
    /// `AgentNotificationController.process`, which skips delivery entirely
    /// when `isPresented(taskID)` is true; that path never reaches
    /// `willPresent`. The options here therefore always request the full set.
    nonisolated static let foregroundPresentationOptions:
        UNNotificationPresentationOptions = [.banner, .list, .sound]

    var responseHandler: ((AgentNotificationResponseAction) -> Void)?
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.foregroundPresentationOptions)
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
        observerToken = registry.addTaskChangeObserver { [weak self] old, new in
            self?.process(oldTasks: old, newTasks: new)
        }
        Task { await refreshAuthorizationStatus() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observerToken { registry.removeTaskChangeObserver(observerToken) }
        observerToken = nil
        delivery.responseHandler = nil
        deliveryTasks.values.forEach { $0.cancel() }
        deliveryTasks.removeAll()
        pendingDeliveryIDs.removeAll()
        clearDeferredEvents()
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await delivery.authorizationStatus()
        switch authorizationStatus {
        case .authorized:
            flushDeferredEvents()
        case .denied:
            settings.setEnabled(false)
            clearDeferredEvents()
        case .notDetermined:
            break
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await delivery.requestAuthorization()
            authorizationStatus = granted ? .authorized : .denied
            settings.setEnabled(granted)
            if granted {
                flushDeferredEvents()
            } else {
                clearDeferredEvents()
            }
            return granted
        } catch {
            await refreshAuthorizationStatus()
            settings.setEnabled(false)
            clearDeferredEvents()
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
            guard let task = tasks[event.taskID] else { continue }
            switch authorizationStatus {
            case .authorized:
                scheduleDelivery(event: event, task: task)
            case .notDetermined:
                deferEvent(event, task: task)
            case .denied:
                break
            }
        }
    }

    private func scheduleDelivery(
        event: AgentNotificationEvent,
        task: AgentTask
    ) {
        guard isRunning,
              settings.allows(event, task: task),
              !isPresented(event.taskID),
              !settings.hasDelivered(event.id),
              pendingDeliveryIDs.insert(event.id).inserted else { return }
        let request = Self.request(for: event)
        deliveryTasks[event.id] = Task { @MainActor [weak self] in
            await self?.deliver(request, eventID: event.id)
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
        eventID: String
    ) async {
        defer {
            pendingDeliveryIDs.remove(eventID)
            deliveryTasks[eventID] = nil
        }

        let delays = [Duration.zero] + deliveryRetryDelays
        for delay in delays {
            guard isRunning,
                  settings.isEnabled,
                  authorizationStatus == .authorized,
                  !Task.isCancelled else { return }
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
                _ = settings.claimDelivery(of: eventID)
                return
            } catch {
                continue
            }
        }
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
