//
//  TerminalThemeSettingsTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Terminal theme settings")
@MainActor
struct TerminalThemeSettingsTests {
    @Test("Built-in themes have stable unique IDs and complete palettes")
    func builtInThemeShape() {
        let themes = TerminalTheme.builtIn

        #expect(themes.map(\.id) == ["pine", "solarized", "dracula", "nord", "github"])
        #expect(Set(themes.map(\.id)).count == themes.count)
        #expect(themes.allSatisfy { !$0.nameKey.isEmpty })
        #expect(themes.allSatisfy { $0.light.ansiColors.count == 16 })
        #expect(themes.allSatisfy { $0.dark.ansiColors.count == 16 })
    }

    @Test("Unknown persisted theme falls back without overwriting the stored ID")
    func unknownThemeFallback() throws {
        let fixture = try TerminalThemeSettingsFixture()
        fixture.defaults.set("removed-theme", forKey: TerminalThemeSettings.Keys.themeID)

        let settings = fixture.makeSettings()

        #expect(settings.selectedThemeID == "removed-theme")
        #expect(settings.selectedTheme == .pine)
    }

    @Test("Theme and appearance policy persist across instances")
    func persistence() throws {
        let fixture = try TerminalThemeSettingsFixture()
        let settings = fixture.makeSettings()

        settings.selectedThemeID = TerminalTheme.dracula.id
        settings.appearancePolicy = .alwaysDark

        let restored = fixture.makeSettings()
        #expect(restored.selectedThemeID == TerminalTheme.dracula.id)
        #expect(restored.appearancePolicy == .alwaysDark)
    }

    @Test("Invalid persisted policy safely falls back to Follow System")
    func invalidPolicyFallback() throws {
        let fixture = try TerminalThemeSettingsFixture()
        fixture.defaults.set(
            "future-policy",
            forKey: TerminalThemeSettings.Keys.appearancePolicy
        )

        #expect(fixture.makeSettings().appearancePolicy == .followSystem)
    }

    @Test(
        "Scheme resolution follows system only when requested",
        arguments: [
            (TerminalAppearancePolicy.followSystem, false, false),
            (TerminalAppearancePolicy.followSystem, true, true),
            (TerminalAppearancePolicy.alwaysLight, true, false),
            (TerminalAppearancePolicy.alwaysDark, false, true),
        ]
    )
    func schemeResolution(
        policy: TerminalAppearancePolicy,
        systemDark: Bool,
        expectedDark: Bool
    ) throws {
        let fixture = try TerminalThemeSettingsFixture()
        let settings = fixture.makeSettings()
        settings.selectedThemeID = TerminalTheme.solarized.id
        settings.appearancePolicy = policy

        #expect(settings.isDarkActive(isDarkAppearance: systemDark) == expectedDark)
        #expect(
            settings.currentScheme(isDarkAppearance: systemDark)
                == (expectedDark ? TerminalTheme.solarized.dark : TerminalTheme.solarized.light)
        )
    }

    @Test("Each effective change emits one repaint notification")
    func notificationsAreDeduplicated() throws {
        let fixture = try TerminalThemeSettingsFixture()
        let settings = fixture.makeSettings()
        let counter = NotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: .terminalThemeChanged,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        settings.selectedThemeID = settings.selectedThemeID
        settings.appearancePolicy = settings.appearancePolicy
        #expect(counter.value == 0)

        settings.setTheme(id: TerminalTheme.nord.id)
        #expect(counter.value == 1)

        settings.appearancePolicy = .alwaysLight
        #expect(counter.value == 2)
    }

    @Test("Reset restores both defaults and broadcasts both effective changes")
    func reset() throws {
        let fixture = try TerminalThemeSettingsFixture()
        let settings = fixture.makeSettings()
        settings.selectedThemeID = TerminalTheme.github.id
        settings.appearancePolicy = .alwaysDark

        let counter = NotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: .terminalThemeChanged,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        settings.reset()

        #expect(settings.selectedThemeID == TerminalTheme.defaultID)
        #expect(settings.appearancePolicy == .followSystem)
        #expect(counter.value == 2)
    }
}

@MainActor
private struct TerminalThemeSettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let notificationCenter = NotificationCenter()

    init() throws {
        suiteName = "TerminalThemeSettingsTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeSettings() -> TerminalThemeSettings {
        TerminalThemeSettings(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
    }
}

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
