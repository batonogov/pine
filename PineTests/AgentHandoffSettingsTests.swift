//
//  AgentHandoffSettingsTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

nonisolated private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock {
            count += 1
        }
    }

    var value: Int {
        lock.withLock { count }
    }
}

@Suite("Agent handoff settings", .serialized)
@MainActor
struct AgentHandoffSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "AgentHandoffSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("Failed to create isolated defaults")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Read-only context permission defaults off")
    func defaultsOff() {
        let settings = AgentHandoffSettings(defaults: makeDefaults())
        #expect(!settings.isReadOnlyContextEnabled)
    }

    @Test("Explicit persisted permission survives reconstruction")
    func persistence() {
        let defaults = makeDefaults()
        let settings = AgentHandoffSettings(defaults: defaults)

        settings.setReadOnlyContextEnabled(true)

        #expect(settings.isReadOnlyContextEnabled)
        #expect(
            defaults.bool(
                forKey: AgentHandoffSettings.Keys.readOnlyContextEnabled
            )
        )
        #expect(
            AgentHandoffSettings(defaults: defaults)
                .isReadOnlyContextEnabled
        )
    }

    @Test("Stored false remains false")
    func persistedFalse() {
        let defaults = makeDefaults()
        defaults.set(
            false,
            forKey: AgentHandoffSettings.Keys.readOnlyContextEnabled
        )

        let settings = AgentHandoffSettings(defaults: defaults)

        #expect(!settings.isReadOnlyContextEnabled)
    }

    @Test("A real permission change posts exactly one refresh notification")
    func changeNotification() {
        let settings = AgentHandoffSettings(defaults: makeDefaults())
        let notificationCount = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .agentHandoffSettingsChanged,
            object: settings,
            queue: nil
        ) { _ in
            notificationCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.setReadOnlyContextEnabled(false)
        settings.setReadOnlyContextEnabled(true)
        settings.setReadOnlyContextEnabled(true)

        #expect(notificationCount.value == 1)
    }
}
