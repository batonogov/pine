//
//  TerminalThemeSettingsTests.swift
//  PineTests
//

import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftTerm
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

    @Test("Unknown persisted theme normalizes to a selected built-in theme")
    func unknownThemeFallback() throws {
        let fixture = try TerminalThemeSettingsFixture()
        fixture.defaults.set("removed-theme", forKey: TerminalThemeSettings.Keys.themeID)

        let settings = fixture.makeSettings()

        #expect(settings.selectedThemeID == TerminalTheme.defaultID)
        #expect(settings.selectedTheme == .pine)
        #expect(
            fixture.defaults.string(forKey: TerminalThemeSettings.Keys.themeID)
                == TerminalTheme.defaultID
        )
    }

    @Test("Unknown programmatic theme selection also normalizes")
    func unknownSelectionFallback() throws {
        let fixture = try TerminalThemeSettingsFixture()
        let settings = fixture.makeSettings()

        settings.setTheme(id: "removed-theme")

        #expect(settings.selectedThemeID == TerminalTheme.defaultID)
        #expect(settings.selectedTheme == .pine)
    }

    @Test("Theme and appearance policy persist across instances")
    func persistence() throws {
        let fixture = try TerminalThemeSettingsFixture()
        let settings = fixture.makeSettings()

        settings.setTheme(id: TerminalTheme.dracula.id)
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
        settings.setTheme(id: TerminalTheme.solarized.id)
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

        settings.setTheme(id: settings.selectedThemeID)
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
        settings.setTheme(id: TerminalTheme.github.id)
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

    @Test("Injected repaint channel updates project and Quick Terminal tabs")
    func injectedRepaintChannel() async throws {
        let fixture = try TerminalThemeSettingsFixture()
        let settings = fixture.makeSettings()
        settings.appearancePolicy = .alwaysDark
        let quickSettings = QuickTerminalSettings(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        let projectPane = TerminalPaneState(themeSettings: settings)
        let quickController = QuickTerminalController(
            settings: quickSettings,
            themeSettings: settings
        )
        defer { quickController.shutdown() }
        let projectTab = projectPane.addTab(workingDirectory: nil)
        let quickTab = quickController.paneState.addTab(workingDirectory: nil)
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

        settings.setTheme(id: TerminalTheme.dracula.id)
        let repainted = await waitForTerminalSettingsCondition {
            projectRedraws == 1 && quickRedraws == 1
        }

        #expect(repainted)
        #expect(
            projectView.nativeBackgroundColor
                == TerminalTheme.dracula.dark.backgroundColor()
        )
        #expect(
            quickView.nativeBackgroundColor
                == TerminalTheme.dracula.dark.backgroundColor()
        )
        #expect(projectRedraws == 1)
        #expect(quickRedraws == 1)
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

nonisolated private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

@Suite("Terminal theme localization")
struct TerminalThemeLocalizationTests {
    private static let languages = [
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]
    private static let keys = [
        "settings.quickTerminal.display.active",
        "settings.quickTerminal.display.main",
        "settings.quickTerminal.edge.bottom",
        "settings.quickTerminal.edge.left",
        "settings.quickTerminal.edge.right",
        "settings.quickTerminal.edge.top",
        "settings.quickTerminal.enabled",
        "settings.quickTerminal.enabled.help",
        "settings.quickTerminal.hideOnFocusLoss",
        "settings.quickTerminal.hideOnFocusLoss.help",
        "settings.quickTerminal.hotkey",
        "settings.quickTerminal.hotkey.help",
        "settings.quickTerminal.hotkey.modifierRequired",
        "settings.quickTerminal.hotkey.recording",
        "settings.quickTerminal.reset",
        "settings.quickTerminal.screenEdge",
        "settings.quickTerminal.size",
        "settings.quickTerminal.targetDisplay",
        "settings.quickTerminal.title",
        "settings.tab.terminal",
        "settings.terminal.appearance.help",
        "settings.terminal.appearance.label",
        "settings.terminal.arguments",
        "settings.terminal.argumentsHelp",
        "settings.terminal.quickTerminal",
        "settings.terminal.resetArgs",
        "settings.terminal.resolvedPrefix",
        "settings.terminal.shell",
        "settings.terminal.shellOther",
        "settings.terminal.shellPathPlaceholder",
        "settings.terminal.shellPicker",
        "settings.terminal.theme.previewLabel",
        "settings.terminal.theme.selectionLabel",
        "settings.terminal.theme.subtitle",
        "settings.terminal.theme.title",
        "settings.terminal.title",
        "terminal.appearance.alwaysDark",
        "terminal.appearance.alwaysLight",
        "terminal.appearance.followSystem",
        "terminal.theme.dracula.name",
        "terminal.theme.github.name",
        "terminal.theme.nord.name",
        "terminal.theme.pine.name",
        "terminal.theme.solarized.name",
    ]

    @Test("Every terminal theme string is translated in all supported languages")
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

// Controller tests create real NSPanels. Serial execution prevents one test's
// panel from resigning another test's key window and exercising focus-loss
// behavior instead of the setting under test.
@Suite("Quick Terminal settings", .serialized)
@MainActor
struct QuickTerminalSettingsTests {
    @Test("UI test preference suites require reset-state and a safe namespace")
    func uiTestDefaultsSuiteIsGuarded() {
        let key = PineSettingsDefaults.uiTestSuiteEnvironmentKey
        let validSuite = "PineUITests.Settings.1234"

        #expect(
            PineSettingsDefaults.uiTestSuiteName(
                arguments: ["Pine"],
                environment: [key: validSuite]
            ) == nil
        )
        #expect(
            PineSettingsDefaults.uiTestSuiteName(
                arguments: ["Pine", "--reset-state"],
                environment: [key: "untrusted"]
            ) == nil
        )
        #expect(
            PineSettingsDefaults.uiTestSuiteName(
                arguments: ["Pine", "--reset-state"],
                environment: [key: validSuite]
            ) == validSuite
        )
    }

    @Test("Every preference persists across instances")
    func persistence() throws {
        let fixture = try QuickTerminalSettingsFixture()
        let settings = fixture.settings
        settings.enabled = false
        settings.setHotkey(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | optionKey)
        )
        settings.screenEdge = .right
        settings.heightFraction = 0.7
        settings.targetDisplay = .main
        settings.hideOnFocusLoss = false

        let restored = fixture.makeSettings()
        #expect(restored.enabled == false)
        #expect(restored.keyCode == UInt32(kVK_ANSI_K))
        #expect(restored.modifiers == UInt32(cmdKey | optionKey))
        #expect(restored.screenEdge == .right)
        #expect(restored.heightFraction == 0.7)
        #expect(restored.targetDisplay == .main)
        #expect(restored.hideOnFocusLoss == false)
    }

    @Test("Every reachable control emits and persists its mutation")
    func everyControlMutationHasImmediateContract() throws {
        let fixture = try QuickTerminalSettingsFixture()
        let settings = fixture.settings
        let counter = NotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: QuickTerminalSettings.didChangeNotification,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        settings.enabled = false
        #expect(counter.value == 1)
        #expect(fixture.makeSettings().enabled == false)

        settings.setHotkey(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | optionKey)
        )
        #expect(counter.value == 2)
        let hotkeyRestore = fixture.makeSettings()
        #expect(hotkeyRestore.keyCode == UInt32(kVK_ANSI_K))
        #expect(hotkeyRestore.modifiers == UInt32(cmdKey | optionKey))

        settings.screenEdge = .right
        #expect(counter.value == 3)
        #expect(fixture.makeSettings().screenEdge == .right)

        settings.heightFraction = 0.65
        #expect(counter.value == 4)
        #expect(fixture.makeSettings().heightFraction == 0.65)

        settings.targetDisplay = .main
        #expect(counter.value == 5)
        #expect(fixture.makeSettings().targetDisplay == .main)

        settings.hideOnFocusLoss = false
        #expect(counter.value == 6)
        #expect(fixture.makeSettings().hideOnFocusLoss == false)
    }

    @Test("Invalid persisted enum values and sizes fall back safely")
    func invalidPersistenceFallsBack() throws {
        let fixture = try QuickTerminalSettingsFixture()
        fixture.defaults.set("diagonal", forKey: "quickTerminal.screenEdge")
        fixture.defaults.set("secondary", forKey: "quickTerminal.targetDisplay")
        fixture.defaults.set(5.0, forKey: "quickTerminal.heightFraction")

        let restored = fixture.makeSettings()

        #expect(restored.screenEdge == .top)
        #expect(restored.targetDisplay == .active)
        #expect(restored.heightFraction == 0.8)
    }

    @Test("Corrupt or bare persisted hotkeys normalize without trapping")
    func invalidPersistedHotkeysFallBack() throws {
        let fixture = try QuickTerminalSettingsFixture()
        fixture.defaults.set(-1, forKey: "quickTerminal.hotkey.keyCode")
        fixture.defaults.set(0, forKey: "quickTerminal.hotkey.modifiers")

        let restored = fixture.makeSettings()

        #expect(restored.keyCode == QuickTerminalSettings.defaultKeyCode)
        #expect(restored.modifiers == QuickTerminalSettings.defaultModifiers)
        let persisted = fixture.makeSettings()
        #expect(persisted.keyCode == QuickTerminalSettings.defaultKeyCode)
        #expect(persisted.modifiers == QuickTerminalSettings.defaultModifiers)

        fixture.defaults.set(
            Int(UInt16.max),
            forKey: "quickTerminal.hotkey.keyCode"
        )
        fixture.defaults.set(
            Int(cmdKey),
            forKey: "quickTerminal.hotkey.modifiers"
        )
        let oversized = fixture.makeSettings()
        #expect(oversized.keyCode == QuickTerminalSettings.defaultKeyCode)
        #expect(oversized.modifiers == QuickTerminalSettings.defaultModifiers)

        fixture.defaults.set(
            Int(kVK_ANSI_K),
            forKey: "quickTerminal.hotkey.keyCode"
        )
        fixture.defaults.set(
            Int(shiftKey),
            forKey: "quickTerminal.hotkey.modifiers"
        )
        let shiftOnly = fixture.makeSettings()
        #expect(shiftOnly.keyCode == QuickTerminalSettings.defaultKeyCode)
        #expect(shiftOnly.modifiers == QuickTerminalSettings.defaultModifiers)
    }

    @Test("Panel size clamps writes at both boundaries")
    func sizeClampsWrites() throws {
        let fixture = try QuickTerminalSettingsFixture()
        let settings = fixture.settings
        let counter = NotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: QuickTerminalSettings.didChangeNotification,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        settings.heightFraction = 0.05
        #expect(settings.heightFraction == 0.2)
        #expect(fixture.makeSettings().heightFraction == 0.2)
        #expect(counter.value == 1)

        settings.heightFraction = 1.5
        #expect(settings.heightFraction == 0.8)
        #expect(fixture.makeSettings().heightFraction == 0.8)
        #expect(counter.value == 2)
    }

    @Test("Hotkey update persists atomically and notifies once")
    func hotkeyUpdateIsAtomic() throws {
        let fixture = try QuickTerminalSettingsFixture()
        let settings = fixture.settings
        let counter = NotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: QuickTerminalSettings.didChangeNotification,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        settings.setHotkey(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | shiftKey)
        )

        #expect(settings.keyCode == UInt32(kVK_ANSI_K))
        #expect(settings.modifiers == UInt32(cmdKey | shiftKey))
        #expect(counter.value == 1)
        let restored = fixture.makeSettings()
        #expect(restored.keyCode == UInt32(kVK_ANSI_K))
        #expect(restored.modifiers == UInt32(cmdKey | shiftKey))
    }

    @Test("Bare and out-of-range hotkeys are rejected without mutation")
    func invalidHotkeyUpdatesAreRejected() throws {
        let fixture = try QuickTerminalSettingsFixture()
        let settings = fixture.settings
        let originalKeyCode = settings.keyCode
        let originalModifiers = settings.modifiers
        let counter = NotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: QuickTerminalSettings.didChangeNotification,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        #expect(
            settings.setHotkey(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: 0
            ) == false
        )
        #expect(
            settings.setHotkey(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: UInt32(shiftKey)
            ) == false
        )
        #expect(
            settings.setHotkey(
                keyCode: UInt32(kVK_UpArrow) + 1,
                modifiers: UInt32(cmdKey)
            ) == false
        )
        #expect(
            settings.setHotkey(
                keyCode: UInt32(UInt16.max),
                modifiers: UInt32(cmdKey)
            ) == false
        )

        #expect(settings.keyCode == originalKeyCode)
        #expect(settings.modifiers == originalModifiers)
        #expect(counter.value == 0)
    }

    @Test("Identical values do not re-arm runtime observers")
    func identicalValuesAreDeduplicated() throws {
        let fixture = try QuickTerminalSettingsFixture()
        let settings = fixture.settings
        let counter = NotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: QuickTerminalSettings.didChangeNotification,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        settings.enabled = settings.enabled
        settings.screenEdge = settings.screenEdge
        settings.heightFraction = settings.heightFraction
        settings.targetDisplay = settings.targetDisplay
        settings.hideOnFocusLoss = settings.hideOnFocusLoss
        settings.setHotkey(
            keyCode: settings.keyCode,
            modifiers: settings.modifiers
        )

        #expect(counter.value == 0)
    }

    @Test("Reset restores every field with one runtime update")
    func resetIsAtomic() throws {
        let fixture = try QuickTerminalSettingsFixture()
        let settings = fixture.settings
        settings.enabled = false
        settings.setHotkey(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey)
        )
        settings.screenEdge = .left
        settings.heightFraction = 0.75
        settings.targetDisplay = .main
        settings.hideOnFocusLoss = false
        let counter = NotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: QuickTerminalSettings.didChangeNotification,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        settings.reset()

        #expect(settings.enabled)
        #expect(settings.keyCode == QuickTerminalSettings.defaultKeyCode)
        #expect(settings.modifiers == QuickTerminalSettings.defaultModifiers)
        #expect(settings.screenEdge == .top)
        #expect(settings.heightFraction == 0.4)
        #expect(settings.targetDisplay == .active)
        #expect(settings.hideOnFocusLoss)
        #expect(counter.value == 1)
    }

    @Test("Production runtime binding applies launch state and atomic updates")
    func runtimeBindingAppliesCompleteSnapshots() async throws {
        let fixture = try QuickTerminalSettingsFixture()
        let settings = fixture.settings
        var snapshots: [(Bool, UInt32, UInt32)] = []
        let binding = QuickTerminalSettingsRuntimeBinding(
            settings: settings
        ) { current in
            snapshots.append((
                current.enabled,
                current.keyCode,
                current.modifiers
            ))
        }

        #expect(snapshots.count == 1)
        #expect(snapshots[0].0)

        settings.setHotkey(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | shiftKey)
        )
        let hotkeyApplied = await waitForTerminalSettingsCondition {
            snapshots.count == 2
        }

        #expect(hotkeyApplied)
        #expect(snapshots[1].1 == UInt32(kVK_ANSI_K))
        #expect(snapshots[1].2 == UInt32(cmdKey | shiftKey))

        settings.enabled = false
        let disableApplied = await waitForTerminalSettingsCondition {
            snapshots.count == 3
        }

        #expect(disableApplied)
        #expect(snapshots[2].0 == false)
        withExtendedLifetime(binding) {}
    }

    @Test("Visible controller applies changes without replacing its session")
    func controllerAppliesSettingsLive() async throws {
        let fixture = try QuickTerminalSettingsFixture()
        let controller = QuickTerminalController(settings: fixture.settings)
        defer { controller.shutdown() }
        controller.show()
        let tabID = try #require(controller.paneState.activeTab?.id)
        let initialFrame = try #require(controller.presentedFrame)

        fixture.settings.screenEdge = .left
        let movedToLeftEdge = await waitForTerminalSettingsCondition {
            controller.presentedFrame != initialFrame
        }

        #expect(movedToLeftEdge)
        let leftFrame = try #require(controller.presentedFrame)
        #expect(leftFrame.width != initialFrame.width)
        #expect(leftFrame.height != initialFrame.height)
        #expect(controller.paneState.activeTab?.id == tabID)

        fixture.settings.heightFraction = 0.65
        let resized = await waitForTerminalSettingsCondition {
            controller.presentedFrame?.width != leftFrame.width
        }

        #expect(resized)
        let resizedFrame = try #require(controller.presentedFrame)
        #expect(resizedFrame.width != leftFrame.width)
        #expect(controller.paneState.activeTab?.id == tabID)

        fixture.settings.targetDisplay = .main
        await Task.yield()

        #expect(controller.paneState.activeTab?.id == tabID)

        fixture.settings.enabled = false
        let hidden = await waitForTerminalSettingsCondition {
            controller.isVisible == false
        }

        #expect(hidden)
        #expect(controller.isVisible == false)
        #expect(controller.paneState.activeTab?.id == tabID)
    }

    @Test("Controller honors focus-loss policy without replacing its session")
    func controllerHonorsFocusLossPolicy() throws {
        let fixture = try QuickTerminalSettingsFixture()
        let controller = QuickTerminalController(settings: fixture.settings)
        defer { controller.shutdown() }
        fixture.settings.hideOnFocusLoss = false
        controller.show()
        let tabID = try #require(controller.paneState.activeTab?.id)

        controller.handleWindowDidResignKey()
        #expect(controller.isVisible)

        fixture.settings.hideOnFocusLoss = true
        controller.handleWindowDidResignKey()
        #expect(controller.isVisible == false)
        #expect(controller.paneState.activeTab?.id == tabID)
    }

    @Test("Disabled controller cannot be shown through a stale trigger")
    func disabledControllerRejectsShow() throws {
        let fixture = try QuickTerminalSettingsFixture()
        fixture.settings.enabled = false
        let controller = QuickTerminalController(settings: fixture.settings)
        defer { controller.shutdown() }

        controller.show()
        #expect(controller.isVisible == false)
        #expect(controller.paneState.terminalTabs.isEmpty)

        controller.toggle()
        #expect(controller.isVisible == false)
        #expect(controller.paneState.terminalTabs.isEmpty)
    }
}

@Suite("Quick Terminal hotkey capture")
struct QuickTerminalHotkeyCaptureTests {
    @Test("The shared key-down path gives an active recorder exclusive ownership")
    @MainActor
    func captureRouterOwnsKeyDownUntilItsTokenEnds() throws {
        let router = QuickTerminalHotkeyCaptureRouter()
        var capturedKeyCode: UInt16?
        let token = try #require(router.begin { event in
            capturedKeyCode = event.keyCode
        })
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_K)
        ))

        #expect(router.isCapturing)
        #expect(router.begin { _ in } == nil)
        #expect(router.route(event))
        #expect(capturedKeyCode == UInt16(kVK_ANSI_K))

        router.end(token)
        #expect(router.isCapturing == false)
        #expect(router.route(event) == false)
    }

    @Test("Escape cancels without requiring modifiers")
    func escapeCancels() {
        #expect(
            QuickTerminalHotkeyCapture.decision(
                keyCode: UInt16(kVK_Escape),
                modifiers: []
            ) == .cancel
        )
    }

    @Test("Bare keys are rejected explicitly")
    func bareKeyIsRejected() {
        #expect(
            QuickTerminalHotkeyCapture.decision(
                keyCode: UInt16(kVK_ANSI_K),
                modifiers: []
            ) == .rejectMissingModifier
        )
    }

    @Test("Shift-only keys are rejected to avoid shadowing ordinary typing")
    func shiftOnlyKeyIsRejected() {
        #expect(
            QuickTerminalHotkeyCapture.decision(
                keyCode: UInt16(kVK_ANSI_K),
                modifiers: .shift
            ) == .rejectMissingModifier
        )
    }

    @Test("Modified keys convert to Carbon flags")
    func modifiedKeyIsAccepted() {
        #expect(
            QuickTerminalHotkeyCapture.decision(
                keyCode: UInt16(kVK_ANSI_K),
                modifiers: [.command, .option, .shift]
            ) == .accept(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: UInt32(cmdKey | optionKey | shiftKey)
            )
        )
    }

    @Test("Incidental-only event flags are rejected as bare keys")
    func incidentalOnlyFlagsAreRejected() {
        let incidentalFlags: [NSEvent.ModifierFlags] = [
            .capsLock,
            .numericPad,
            .function,
        ]

        for modifiers in incidentalFlags {
            #expect(
                QuickTerminalHotkeyCapture.decision(
                    keyCode: UInt16(kVK_ANSI_K),
                    modifiers: modifiers
                ) == .rejectMissingModifier
            )
        }
    }

    @Test("Incidental flags are ignored beside a supported modifier")
    func incidentalFlagsAreIgnoredWithSupportedModifier() {
        #expect(
            QuickTerminalHotkeyCapture.decision(
                keyCode: UInt16(kVK_ANSI_K),
                modifiers: [.command, .capsLock, .numericPad, .function]
            ) == .accept(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: UInt32(cmdKey)
            )
        )
    }

    @Test("Accepted capture persists the exact key and supported modifiers")
    @MainActor
    func acceptedCapturePersists() throws {
        let fixture = try QuickTerminalSettingsFixture()
        let decision = QuickTerminalHotkeyCapture.decision(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.control, .option, .capsLock]
        )
        let accepted = try #require(decision.acceptedHotkey)

        #expect(
            fixture.settings.setHotkey(
                keyCode: accepted.keyCode,
                modifiers: accepted.modifiers
            )
        )

        let restored = fixture.makeSettings()
        #expect(restored.keyCode == UInt32(kVK_ANSI_K))
        #expect(restored.modifiers == UInt32(controlKey | optionKey))
    }
}

private extension QuickTerminalHotkeyCaptureDecision {
    var acceptedHotkey: (keyCode: UInt32, modifiers: UInt32)? {
        guard case let .accept(keyCode, modifiers) = self else { return nil }
        return (keyCode, modifiers)
    }
}

@MainActor
private func waitForTerminalSettingsCondition(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
private struct QuickTerminalSettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let notificationCenter = NotificationCenter()
    let settings: QuickTerminalSettings

    init() throws {
        suiteName = "QuickTerminalSettingsTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        settings = QuickTerminalSettings(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
    }

    func makeSettings() -> QuickTerminalSettings {
        QuickTerminalSettings(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
    }
}
