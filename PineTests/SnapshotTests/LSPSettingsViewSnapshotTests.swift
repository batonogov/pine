//
//  LSPSettingsViewSnapshotTests.swift
//  PineTests
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

nonisolated private struct SnapshotLSPResolver: LanguageServerResolving {
    func resolve(
        config: LanguageServerConfig,
        serverOverride: LanguageServerOverride?
    ) -> LanguageServerResolution {
        if config.language == "python" {
            return .notFound(command: config.command)
        }
        return .resolved(
            LanguageServerLaunchConfiguration(
                executablePath:
                    serverOverride?.executablePath
                    ?? "/usr/local/bin/\(config.command)",
                arguments:
                    serverOverride?.arguments ?? config.arguments
            )
        )
    }
}

@Suite("LSPSettingsView Snapshots")
@MainActor
struct LSPSettingsViewSnapshotTests {
    private func makeView() throws -> LSPSettingsView {
        let name = "LSPSettingsViewSnapshotTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let settings = LSPSettings(defaults: defaults)
        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: ["--stdio", "--log-level=warning"]
        )
        return LSPSettingsView(
            settings: settings,
            resolver: SnapshotLSPResolver(),
            locale: Locale(identifier: "en")
        )
    }

    @Test("LSP Settings renders in light appearance")
    func light() throws {
        try assertSnapshot(
            of: makeView(),
            size: NSSize(width: 720, height: 500),
            appearance: .light,
            named: "LSPSettingsView.light",
            tolerance: 0.02
        )
    }

    @Test("LSP Settings renders in dark appearance")
    func dark() throws {
        try assertSnapshot(
            of: makeView(),
            size: NSSize(width: 720, height: 500),
            appearance: .dark,
            named: "LSPSettingsView.dark",
            tolerance: 0.02
        )
    }
}
