//
//  AgentNotificationSettings.swift
//  Pine
//

import Foundation

@MainActor
@Observable
final class AgentNotificationSettings {
    static let shared = AgentNotificationSettings(
        defaults: PineSettingsDefaults.shared()
    )

    enum Keys {
        static let enabled = "agentNotifications.enabled"
        static let eventPrefix = "agentNotifications.event."
        static let mutedTasks = "agentNotifications.mutedTasks"
        static let disabledAgents = "agentNotifications.disabledAgents"
        static let disabledProjects = "agentNotifications.disabledProjects"
        static let deliveredEventIDs = "agentNotifications.deliveredEventIDs"
    }

    private let defaults: UserDefaults
    private(set) var isEnabled: Bool
    private(set) var enabledEvents: Set<AgentNotificationEventKind>
    private(set) var mutedTaskIDs: Set<UUID>
    private(set) var disabledAgentIDs: Set<String>
    private(set) var disabledProjectPaths: Set<String>
    private(set) var deliveredEventIDs: Set<String>
    @ObservationIgnored
    private var deliveredEventOrder: [String]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = (defaults.object(forKey: Keys.enabled) as? Bool) ?? false
        enabledEvents = Set(AgentNotificationEventKind.allCases.filter { kind in
            (defaults.object(forKey: Keys.eventPrefix + kind.rawValue) as? Bool)
                ?? true
        })
        mutedTaskIDs = Self.uuidSet(defaults.stringArray(forKey: Keys.mutedTasks))
        disabledAgentIDs = Set(defaults.stringArray(forKey: Keys.disabledAgents) ?? [])
        disabledProjectPaths = Set(
            defaults.stringArray(forKey: Keys.disabledProjects) ?? []
        )
        let eventOrder = Array(
            (defaults.stringArray(forKey: Keys.deliveredEventIDs) ?? []).suffix(512)
        )
        deliveredEventOrder = eventOrder
        deliveredEventIDs = Set(eventOrder)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Keys.enabled)
    }

    func setEvent(_ kind: AgentNotificationEventKind, enabled: Bool) {
        if enabled { enabledEvents.insert(kind) } else { enabledEvents.remove(kind) }
        defaults.set(enabled, forKey: Keys.eventPrefix + kind.rawValue)
    }

    func setAgent(_ identifier: String, enabled: Bool) {
        if enabled { disabledAgentIDs.remove(identifier) } else { disabledAgentIDs.insert(identifier) }
        persist(disabledAgentIDs, key: Keys.disabledAgents)
    }

    func setProject(_ path: String, enabled: Bool) {
        if enabled { disabledProjectPaths.remove(path) } else { disabledProjectPaths.insert(path) }
        persist(disabledProjectPaths, key: Keys.disabledProjects)
    }

    func muteTask(_ taskID: UUID) {
        setTask(taskID, enabled: false)
    }

    func setTask(_ taskID: UUID, enabled: Bool) {
        if enabled { mutedTaskIDs.remove(taskID) } else { mutedTaskIDs.insert(taskID) }
        persist(Set(mutedTaskIDs.map(\.uuidString)), key: Keys.mutedTasks)
    }

    func allows(_ event: AgentNotificationEvent, task: AgentTask) -> Bool {
        isEnabled
            && enabledEvents.contains(event.kind)
            && !mutedTaskIDs.contains(task.id)
            && !disabledAgentIDs.contains(task.descriptor.typeIdentifier)
            && !disabledProjectPaths.contains(task.project.canonicalProjectPath)
    }

    /// Returns true exactly once for a deterministic transition identifier.
    func claimDelivery(of eventID: String) -> Bool {
        guard deliveredEventIDs.insert(eventID).inserted else { return false }
        deliveredEventOrder.append(eventID)
        if deliveredEventOrder.count > 512 {
            deliveredEventOrder.removeFirst(deliveredEventOrder.count - 384)
            deliveredEventIDs = Set(deliveredEventOrder)
        }
        defaults.set(deliveredEventOrder, forKey: Keys.deliveredEventIDs)
        return true
    }

    func hasDelivered(_ eventID: String) -> Bool {
        deliveredEventIDs.contains(eventID)
    }

    private func persist(_ values: Set<String>, key: String) {
        defaults.set(values.sorted(), forKey: key)
    }

    private static func uuidSet(_ strings: [String]?) -> Set<UUID> {
        Set((strings ?? []).compactMap(UUID.init(uuidString:)))
    }
}
