//
//  TerminalSettingsViewSnapshotTests.swift
//  PineTests
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Terminal Settings snapshots")
@MainActor
struct TerminalSettingsViewSnapshotTests {
    private func makeView(locale: String = "en") throws -> some View {
        let suiteName = "TerminalSettingsViewSnapshotTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let shell = ShellSettings(defaults: defaults)
        shell.shellPath = "/bin/zsh"
        shell.shellArgs = ["--login"]

        let theme = TerminalThemeSettings(defaults: defaults)
        theme.setTheme(id: TerminalTheme.dracula.id)
        theme.appearancePolicy = .followSystem

        return TerminalSettingsView(
            shell: shell,
            theme: theme,
            quickTerminal: QuickTerminalSettings(defaults: defaults),
            viewportHeight: 1_080
        )
        .environment(\.locale, Locale(identifier: locale))
    }

    private func makeQuickTerminalView() throws -> some View {
        let suiteName = "QuickTerminalSettingsViewSnapshotTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return QuickTerminalSettingsView(
            settings: QuickTerminalSettings(defaults: defaults)
        )
        .environment(\.locale, Locale(identifier: "en"))
    }

    @Test("Combined Terminal Settings renders in light appearance")
    func light() throws {
        try assertSnapshot(
            of: makeView(),
            size: NSSize(width: 720, height: 1_080),
            appearance: .light,
            named: "TerminalSettingsView.light",
            tolerance: 0.01
        )
    }

    @Test("Combined Terminal Settings renders in dark appearance")
    func dark() throws {
        try assertSnapshot(
            of: makeView(),
            size: NSSize(width: 720, height: 1_080),
            appearance: .dark,
            named: "TerminalSettingsView.dark",
            tolerance: 0.01
        )
    }

    @Test("Combined Terminal Settings honors a non-English environment locale")
    func russianLocale() throws {
        try assertSnapshot(
            of: makeView(locale: "ru"),
            size: NSSize(width: 720, height: 1_080),
            appearance: .light,
            named: "TerminalSettingsView.ru.light",
            tolerance: 0.01
        )
    }

    @Test("Quick Terminal controls render completely in light appearance")
    func quickTerminalLight() throws {
        try assertSnapshot(
            of: makeQuickTerminalView(),
            size: NSSize(width: 720, height: 540),
            appearance: .light,
            named: "QuickTerminalSettingsView.light",
            tolerance: 0.01
        )
    }

    @Test("Quick Terminal controls render completely in dark appearance")
    func quickTerminalDark() throws {
        try assertSnapshot(
            of: makeQuickTerminalView(),
            size: NSSize(width: 720, height: 540),
            appearance: .dark,
            named: "QuickTerminalSettingsView.dark",
            tolerance: 0.01
        )
    }
}
