//
//  AgentHandoffSettingsViewSnapshotTests.swift
//  PineTests
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("AgentHandoffSettingsView snapshots")
@MainActor
struct AgentHandoffSettingsViewSnapshotTests {
    private func makeView(
        enabled: Bool
    ) throws -> some View {
        let name = "AgentHandoffSettingsViewSnapshotTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let settings = AgentHandoffSettings(defaults: defaults)
        settings.setReadOnlyContextEnabled(enabled)
        return AgentHandoffSettingsView(settings: settings)
            .environment(\.locale, Locale(identifier: "en"))
    }

    @Test("Disabled handoff renders in light appearance")
    func disabledLight() throws {
        try assertSnapshot(
            of: makeView(enabled: false),
            size: NSSize(width: 720, height: 500),
            appearance: .light,
            named: "AgentHandoffSettingsView.disabled.light",
            tolerance: 0.02
        )
    }

    @Test("Disabled handoff renders in dark appearance")
    func disabledDark() throws {
        try assertSnapshot(
            of: makeView(enabled: false),
            size: NSSize(width: 720, height: 500),
            appearance: .dark,
            named: "AgentHandoffSettingsView.disabled.dark",
            tolerance: 0.02
        )
    }

    @Test("Enabled handoff renders in light appearance")
    func enabledLight() throws {
        try assertSnapshot(
            of: makeView(enabled: true),
            size: NSSize(width: 720, height: 500),
            appearance: .light,
            named: "AgentHandoffSettingsView.enabled.light",
            tolerance: 0.02
        )
    }

    @Test("Enabled handoff renders in dark appearance")
    func enabledDark() throws {
        try assertSnapshot(
            of: makeView(enabled: true),
            size: NSSize(width: 720, height: 500),
            appearance: .dark,
            named: "AgentHandoffSettingsView.enabled.dark",
            tolerance: 0.02
        )
    }
}
