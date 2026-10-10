//
//  TerminalFontSettingsTests.swift
//  PineTests
//
//  Issue #1649: terminal font customization + Nerd Font support.
//

import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import Pine

@Suite("Terminal font settings")
@MainActor
struct TerminalFontSettingsTests {
    @Test("Fresh installs use Automatic family detection and the 13 pt default")
    func defaultsOnFreshInstall() throws {
        let fixture = try TerminalFontSettingsFixture()
        let settings = fixture.makeSettings()

        #expect(settings.fontFamilySelection == nil)
        #expect(settings.fontSize == TerminalFontSettings.defaultSize)
        #expect(settings.fontResolution == .system)
        #expect(settings.detectedNerdFontFamily == nil)
    }

    @Test("Family and size persist across instances")
    func persistence() throws {
        let fixture = try TerminalFontSettingsFixture()
        let settings = fixture.makeSettings()

        settings.fontFamilySelection = "Menlo"
        settings.fontSize = 16

        let restored = fixture.makeSettings()
        #expect(restored.fontFamilySelection == "Menlo")
        #expect(restored.fontSize == 16)
        #expect(restored.fontResolution == .family("Menlo"))
    }

    @Test("Explicit System choice is never overridden by auto-detection")
    func explicitSystemSurvivesAutoDetection() throws {
        let fixture = try TerminalFontSettingsFixture()
        let nerdFonts = { Set(["MesloLGS NF"]) }
        let settings = fixture.makeSettings(availableFontFamilies: nerdFonts)

        // Automatic resolves to the detected Nerd Font.
        #expect(settings.fontResolution == .family("MesloLGS NF"))
        #expect(settings.detectedNerdFontFamily == "MesloLGS NF")

        settings.fontFamilySelection = TerminalFontSettings.systemFamilyMarker
        #expect(settings.fontResolution == .system)

        let restored = fixture.makeSettings(availableFontFamilies: nerdFonts)
        #expect(
            restored.fontFamilySelection
                == TerminalFontSettings.systemFamilyMarker
        )
        #expect(restored.fontResolution == .system)

        // Returning to Automatic removes the persisted key entirely.
        restored.fontFamilySelection = nil
        #expect(restored.fontResolution == .family("MesloLGS NF"))
        #expect(
            fixture.defaults.string(
                forKey: TerminalFontSettings.Keys.fontFamily
            ) == nil
        )
    }

    @Test("A vanished explicit family falls back to SF Mono at resolution")
    func vanishedFamilyFallsBack() throws {
        let fixture = try TerminalFontSettingsFixture()
        let settings = fixture.makeSettings()
        settings.fontFamilySelection = "NoSuchFamily-#1649"
        settings.fontSize = 15

        // The preference is kept verbatim so reinstalling the font re-applies
        // it, but the resolved font is a usable monospace fallback.
        #expect(settings.fontResolution == .family("NoSuchFamily-#1649"))
        let font = settings.resolvedFont
        #expect(font.pointSize == 15)
        #expect(font.isFixedPitch)
    }

    @Test("Size writes clamp to 8…24 and non-finite values to the default")
    func sizeClamping() throws {
        let fixture = try TerminalFontSettingsFixture()
        let settings = fixture.makeSettings()

        settings.fontSize = 30
        #expect(settings.fontSize == TerminalFontSettings.maximumSize)
        #expect(
            fixture.defaults.double(
                forKey: TerminalFontSettings.Keys.fontSize
            ) == TerminalFontSettings.maximumSize
        )

        settings.fontSize = 5
        #expect(settings.fontSize == TerminalFontSettings.minimumSize)
        #expect(fixture.makeSettings().fontSize == TerminalFontSettings.minimumSize)

        settings.fontSize = .nan
        #expect(settings.fontSize == TerminalFontSettings.defaultSize)
        #expect(fixture.makeSettings().fontSize == TerminalFontSettings.defaultSize)

        settings.fontSize = .infinity
        #expect(settings.fontSize == TerminalFontSettings.defaultSize)
    }

    @Test("Corrupt persisted values normalize on load")
    func corruptPersistedValuesNormalize() throws {
        let fixture = try TerminalFontSettingsFixture()
        fixture.defaults.set("banana", forKey: TerminalFontSettings.Keys.fontSize)
        fixture.defaults.set("", forKey: TerminalFontSettings.Keys.fontFamily)

        let settings = fixture.makeSettings()

        #expect(settings.fontSize == TerminalFontSettings.defaultSize)
        #expect(
            fixture.defaults.double(
                forKey: TerminalFontSettings.Keys.fontSize
            ) == TerminalFontSettings.defaultSize
        )
        #expect(settings.fontFamilySelection == nil)
        #expect(
            fixture.defaults.object(
                forKey: TerminalFontSettings.Keys.fontFamily
            ) == nil
        )

        fixture.defaults.set(2.0, forKey: TerminalFontSettings.Keys.fontSize)
        #expect(
            fixture.makeSettings().fontSize == TerminalFontSettings.minimumSize
        )
        #expect(
            fixture.defaults.double(
                forKey: TerminalFontSettings.Keys.fontSize
            ) == TerminalFontSettings.minimumSize
        )

        fixture.defaults.set(99.0, forKey: TerminalFontSettings.Keys.fontSize)
        #expect(
            fixture.makeSettings().fontSize == TerminalFontSettings.maximumSize
        )

        fixture.defaults.set(
            Double.nan,
            forKey: TerminalFontSettings.Keys.fontSize
        )
        #expect(
            fixture.makeSettings().fontSize == TerminalFontSettings.defaultSize
        )
    }

    @Test("Each effective change emits exactly one notification")
    func notificationsAreDeduplicated() throws {
        let fixture = try TerminalFontSettingsFixture()
        let settings = fixture.makeSettings()
        let counter = FontNotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: .terminalFontChanged,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        // Identical writes are deduplicated.
        settings.fontFamilySelection = nil
        settings.fontSize = TerminalFontSettings.defaultSize
        #expect(counter.value == 0)

        settings.fontSize = 15
        #expect(counter.value == 1)

        settings.fontFamilySelection = "Menlo"
        #expect(counter.value == 2)

        settings.fontFamilySelection = nil
        #expect(counter.value == 3)

        // Out-of-range writes normalize with exactly one notification when
        // the effective value changes…
        settings.fontSize = 30
        #expect(counter.value == 4)
        #expect(settings.fontSize == TerminalFontSettings.maximumSize)

        // …and none when the clamped result is unchanged.
        settings.fontSize = 99
        #expect(counter.value == 4)
    }

    @Test("Reset restores Automatic detection and the default size")
    func reset() throws {
        let fixture = try TerminalFontSettingsFixture()
        let settings = fixture.makeSettings()
        settings.fontFamilySelection = "Menlo"
        settings.fontSize = 18
        let counter = FontNotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: .terminalFontChanged,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        settings.reset()

        #expect(settings.fontFamilySelection == nil)
        #expect(settings.fontSize == TerminalFontSettings.defaultSize)
        #expect(counter.value == 2)
        #expect(
            fixture.defaults.object(
                forKey: TerminalFontSettings.Keys.fontFamily
            ) == nil
        )
    }

    @Test("Auto-detection follows the curated priority order")
    func autoDetectionPriority() {
        #expect(
            TerminalFontSettings.detectedNerdFontFamily(
                availableFamilies: []
            ) == nil
        )
        #expect(
            TerminalFontSettings.detectedNerdFontFamily(
                availableFamilies: ["Menlo", "Fira Code"]
            ) == nil
        )
        #expect(
            TerminalFontSettings.detectedNerdFontFamily(
                availableFamilies: ["Hack Nerd Font Mono"]
            ) == "Hack Nerd Font Mono"
        )
        #expect(
            TerminalFontSettings.detectedNerdFontFamily(
                availableFamilies: [
                    "Hack Nerd Font Mono",
                    "MesloLGS NF",
                ]
            ) == "MesloLGS NF"
        )
        #expect(
            TerminalFontSettings.detectedNerdFontFamily(
                availableFamilies: [
                    "FiraCode Nerd Font Mono",
                    "JetBrainsMono Nerd Font Mono",
                ]
            ) == "JetBrainsMono Nerd Font Mono"
        )
        #expect(
            TerminalFontSettings.detectedNerdFontFamily(
                availableFamilies: Set(TerminalFontSettings.nerdFontCandidates)
            ) == TerminalFontSettings.nerdFontCandidates.first
        )
    }

    @Test("Resolved font honors the explicit family and size")
    func resolvedFontUsesSelection() throws {
        let fixture = try TerminalFontSettingsFixture()
        let settings = fixture.makeSettings()
        settings.fontFamilySelection = "Menlo"
        settings.fontSize = 15

        let font = settings.resolvedFont
        #expect(font.familyName == "Menlo")
        #expect(font.pointSize == 15)
        #expect(font.isFixedPitch)

        // The explicit System choice resolves to the same monospaced system
        // font the terminal used before this setting existed.
        settings.fontFamilySelection = TerminalFontSettings.systemFamilyMarker
        let systemFont = settings.resolvedFont
        let reference = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        #expect(systemFont.familyName == reference.familyName)
        #expect(systemFont.pointSize == reference.pointSize)
    }

    @Test("A proportional family from hand-edited defaults never reaches the grid")
    func proportionalFamilyFallsBackToSystemFont() throws {
        let fixture = try TerminalFontSettingsFixture()
        let settings = fixture.makeSettings()
        settings.fontFamilySelection = "Helvetica"
        settings.fontSize = 14

        // Resolution preserves the persisted intent, but instantiation is the
        // trust boundary: a proportional family is refused and SF Mono is
        // served instead of corrupting the terminal cell grid.
        #expect(settings.fontResolution == .family("Helvetica"))
        let font = settings.resolvedFont
        let reference = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        #expect(font.isFixedPitch)
        #expect(font.familyName == reference.familyName)
        #expect(font.pointSize == 14)
    }

    @Test("Tabs pick up the resolved font at creation and re-apply it live")
    func tabAppliesFontLive() throws {
        let fixture = try TerminalFontSettingsFixture()
        let settings = fixture.makeSettings()
        settings.fontFamilySelection = "Menlo"
        settings.fontSize = 15

        let tab = TerminalTab(name: "font", fontSettings: settings)
        defer { tab.stop() }
        let view = try #require(tab.terminalView as? PineTerminalView)
        #expect(view.font.familyName == "Menlo")
        #expect(view.font.pointSize == 15)
        let terminal = view.getTerminal()
        let initialCols = terminal.cols
        let initialRows = terminal.rows

        var redrawRequests = 0
        view.backendRedrawRequestObserver = { redrawRequests += 1 }

        // The observer hop is synchronous on the main actor (the same
        // delivery path cursor settings use), so the view has already
        // re-applied by the time the mutation returns.
        settings.fontSize = 20

        #expect(view.font.familyName == "Menlo")
        #expect(view.font.pointSize == 20)
        #expect(redrawRequests == 1)
        // Larger cells recompute the grid — the resize that drives SIGWINCH.
        #expect(terminal.cols < initialCols)
        #expect(terminal.rows < initialRows)

        settings.fontFamilySelection = "Monaco"
        #expect(view.font.familyName == "Monaco")
        #expect(redrawRequests == 2)
    }

    @Test("Injected channel updates project and Quick Terminal tabs")
    func fontPropagationKeepsLiveSessions() throws {
        let fixture = try TerminalFontSettingsFixture()
        let fontSettings = fixture.makeSettings()
        let themeSettings = TerminalThemeSettings(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        let cursorSettings = TerminalCursorSettings(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        let quickSettings = QuickTerminalSettings(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        let projectPane = TerminalPaneState(
            themeSettings: themeSettings,
            cursorSettings: cursorSettings,
            fontSettings: fontSettings
        )
        let quickController = QuickTerminalController(
            settings: quickSettings,
            themeSettings: themeSettings,
            cursorSettings: cursorSettings,
            fontSettings: fontSettings
        )
        defer { quickController.shutdown() }
        let projectTab = projectPane.addTab(workingDirectory: nil)
        let quickTab = quickController.paneState.addTab(workingDirectory: nil)
        defer {
            projectTab.stop()
            quickTab.stop()
        }
        let projectView = try #require(
            projectTab.terminalView as? PineTerminalView
        )
        let quickView = try #require(
            quickTab.terminalView as? PineTerminalView
        )
        var projectRedraws = 0
        var quickRedraws = 0
        projectView.backendRedrawRequestObserver = { projectRedraws += 1 }
        quickView.backendRedrawRequestObserver = { quickRedraws += 1 }

        fontSettings.fontFamilySelection = "Menlo"
        fontSettings.fontSize = 17

        #expect(projectView.font.familyName == "Menlo")
        #expect(quickView.font.familyName == "Menlo")
        #expect(projectView.font.pointSize == 17)
        #expect(quickView.font.pointSize == 17)
        #expect(projectRedraws == 2)
        #expect(quickRedraws == 2)
        // The live views are re-fonted in place — no session replacement.
        #expect(projectTab.terminalView === projectView)
        #expect(quickTab.terminalView === quickView)
    }
}

@Suite("Terminal font localization")
struct TerminalFontLocalizationTests {
    private static let languages = [
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]
    private static let keys = [
        "settings.terminal.font.family",
        "settings.terminal.font.familyAutomatic",
        "settings.terminal.font.familySystem",
        "settings.terminal.font.help",
        "settings.terminal.font.nerdDetected",
        "settings.terminal.font.nerdMissing",
        "settings.terminal.font.size",
        "settings.terminal.font.title",
    ]

    @Test("Every terminal font string is translated in all supported languages")
    func completeCatalogCoverage() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = projectRoot.appendingPathComponent(
            "Pine/Localizable.xcstrings"
        )
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let catalog = try #require(root["strings"] as? [String: Any])

        for key in Self.keys {
            let entry = try #require(catalog[key] as? [String: Any])
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            #expect(Set(localizations.keys) == Set(Self.languages))

            for language in Self.languages {
                let localization = try #require(
                    localizations[language] as? [String: Any]
                )
                let unit = try #require(
                    localization["stringUnit"] as? [String: Any]
                )
                #expect(unit["state"] as? String == "translated")
                let value = try #require(unit["value"] as? String)
                #expect(
                    !value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }
        }
    }
}

nonisolated private final class FontNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

@MainActor
private struct TerminalFontSettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let notificationCenter = NotificationCenter()

    init() throws {
        suiteName = "TerminalFontSettingsTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeSettings(
        availableFontFamilies: @escaping () -> Set<String> = { [] }
    ) -> TerminalFontSettings {
        TerminalFontSettings(
            defaults: defaults,
            notificationCenter: notificationCenter,
            availableFontFamilies: availableFontFamilies
        )
    }
}
