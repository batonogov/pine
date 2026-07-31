//
//  SettingsPaneSnapshotTests.swift
//  PineTests
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Consolidated Settings snapshots", .serialized)
@MainActor
struct SettingsPaneSnapshotTests {
    private func makeGeneralView(locale: String) throws -> some View {
        let defaults = try isolatedDefaults(prefix: "GeneralSettingsView")
        return GeneralSettingsView(
            editor: EditorSettings(defaults: defaults),
            fontSizeSettings: FontSizeSettings(defaults: defaults),
            defaults: defaults
        )
        .environment(\.locale, Locale(identifier: locale))
    }

    private func makeKeyBindingsView(locale: String) -> some View {
        let configurationDirectory = URL(
            fileURLWithPath: "/Users/pine/Library/Application Support/Pine",
            isDirectory: true
        )
        return KeyBindingsTasksSettingsView(
            presentation: .init(
                keybindingsFileURL: configurationDirectory
                    .appendingPathComponent("keybindings.json"),
                keybindingCount: 2,
                tasksFileURL: configurationDirectory
                    .appendingPathComponent("tasks.json"),
                taskCount: 1,
                effectiveEntries: []
            )
        )
        .environment(\.locale, Locale(identifier: locale))
    }

    private func isolatedDefaults(prefix: String) throws -> UserDefaults {
        let suiteName = "\(prefix)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("General pane renders localized English content")
    func generalEnglish() throws {
        try assertSnapshot(
            of: makeGeneralView(locale: "en"),
            size: NSSize(width: 720, height: 500),
            appearance: .light,
            named: "GeneralSettingsView.en.light",
            tolerance: 0.02
        )
    }

    @Test("General pane accommodates wide Russian labels")
    func generalRussian() throws {
        try assertSnapshot(
            of: makeGeneralView(locale: "ru"),
            size: NSSize(width: 720, height: 500),
            appearance: .light,
            named: "GeneralSettingsView.ru.light",
            tolerance: 0.02
        )
    }

    @Test("Key Bindings and Tasks pane renders localized English content")
    func keyBindingsEnglish() throws {
        try assertSnapshot(
            of: makeKeyBindingsView(locale: "en"),
            size: NSSize(width: 720, height: 500),
            appearance: .light,
            named: "KeyBindingsTasksSettingsView.en.light",
            tolerance: 0.02
        )
    }

    @Test("Key Bindings and Tasks pane accommodates Russian content")
    func keyBindingsRussian() throws {
        try assertSnapshot(
            of: makeKeyBindingsView(locale: "ru"),
            size: NSSize(width: 720, height: 500),
            appearance: .light,
            named: "KeyBindingsTasksSettingsView.ru.light",
            tolerance: 0.02
        )
    }
}
