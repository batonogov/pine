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

@Suite("Terminal theme and cursor settings")
@MainActor
struct TerminalThemeSettingsTests {
    @Test("Built-in themes have stable unique IDs and complete palettes")
    func builtInThemeShape() {
        let themes = TerminalTheme.builtIn

        #expect(
            themes.map(\.id)
                == ["pine", "solarized", "dracula", "nord", "github", "digital-rain"]
        )
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

    @Test("Fresh installs use a blinking vertical bar cursor")
    func defaultCursor() throws {
        let settings = try TerminalCursorSettingsFixture().makeSettings()

        #expect(settings.cursorStyle.tagName == "blinkBar")
        #expect(settings.cursorShape == .verticalBar)
        #expect(settings.cursorBlinks)
    }

    @Test("Existing theme preferences gain the cursor default independently")
    func existingThemePreferencesUseDefaultCursor() throws {
        let fixture = try TerminalCursorSettingsFixture()
        fixture.defaults.set(
            TerminalTheme.dracula.id,
            forKey: TerminalThemeSettings.Keys.themeID
        )
        fixture.defaults.set(
            TerminalAppearancePolicy.alwaysDark.rawValue,
            forKey: TerminalThemeSettings.Keys.appearancePolicy
        )

        let cursorSettings = fixture.makeSettings()
        let themeSettings = TerminalThemeSettings(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )

        #expect(cursorSettings.cursorStyle.tagName == "blinkBar")
        #expect(
            fixture.defaults.string(
                forKey: TerminalCursorSettings.Keys.cursorStyle
            ) == nil
        )
        #expect(themeSettings.selectedThemeID == TerminalTheme.dracula.id)
        #expect(themeSettings.appearancePolicy == .alwaysDark)
    }

    @Test("All cursor shape and blink combinations persist as stable tags")
    func cursorPersistenceAndMapping() throws {
        let fixture = try TerminalCursorSettingsFixture()
        let settings = fixture.makeSettings()
        let combinations: [(TerminalCursorShape, Bool, String)] = [
            (.verticalBar, true, "blinkBar"),
            (.verticalBar, false, "steadyBar"),
            (.block, true, "blinkBlock"),
            (.block, false, "steadyBlock"),
            (.underline, true, "blinkUnderline"),
            (.underline, false, "steadyUnderline"),
        ]

        for (shape, blinks, expectedTag) in combinations {
            settings.setCursorStyle(
                expectedTag == "blinkBar" ? .steadyBar : .blinkBar
            )
            settings.cursorShape = shape
            settings.cursorBlinks = blinks

            #expect(settings.cursorStyle.tagName == expectedTag)
            #expect(
                fixture.defaults.string(
                    forKey: TerminalCursorSettings.Keys.cursorStyle
                ) == expectedTag
            )

            let restored = fixture.makeSettings()
            #expect(restored.cursorShape == shape)
            #expect(restored.cursorBlinks == blinks)
            #expect(restored.cursorStyle.tagName == expectedTag)
        }
    }

    @Test("Invalid persisted cursor style normalizes to Pine's default")
    func invalidCursorFallback() throws {
        let fixture = try TerminalCursorSettingsFixture()
        fixture.defaults.set(
            "wobblyBlock",
            forKey: TerminalCursorSettings.Keys.cursorStyle
        )

        let settings = fixture.makeSettings()

        #expect(settings.cursorStyle.tagName == "blinkBar")
        #expect(
            fixture.defaults.string(
                forKey: TerminalCursorSettings.Keys.cursorStyle
            ) == "blinkBar"
        )
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

    @Test("Cursor changes use a separate deduplicated notification")
    func cursorNotificationsAreDeduplicated() throws {
        let fixture = try TerminalCursorSettingsFixture()
        let settings = fixture.makeSettings()
        let themeSettings = TerminalThemeSettings(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        let counter = NotificationCounter()
        let token = fixture.notificationCenter.addObserver(
            forName: .terminalCursorStyleChanged,
            object: settings,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { fixture.notificationCenter.removeObserver(token) }

        settings.setCursorStyle(settings.cursorStyle)
        settings.cursorShape = .verticalBar
        settings.cursorBlinks = true
        themeSettings.setTheme(id: TerminalTheme.nord.id)
        #expect(counter.value == 0)

        settings.cursorShape = .block
        #expect(counter.value == 1)

        settings.cursorBlinks = false
        #expect(counter.value == 2)

        settings.cursorBlinks = false
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

    @Test("Cursor changes update project and Quick Terminal tabs in place")
    func cursorPropagationKeepsLiveSessions() async throws {
        let fixture = try TerminalCursorSettingsFixture()
        let cursorSettings = fixture.makeSettings()
        let themeSettings = TerminalThemeSettings(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        let quickSettings = QuickTerminalSettings(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        let projectPane = TerminalPaneState(
            themeSettings: themeSettings,
            cursorSettings: cursorSettings
        )
        let quickController = QuickTerminalController(
            settings: quickSettings,
            themeSettings: themeSettings,
            cursorSettings: cursorSettings
        )
        defer { quickController.shutdown() }
        let inertProcess = TerminalInitialProcess(
            executablePath: "/bin/cat",
            arguments: []
        )
        let projectTab = projectPane.addTab(
            workingDirectory: nil,
            initialProcess: inertProcess
        )
        let quickTab = quickController.paneState.addTab(
            workingDirectory: nil,
            initialProcess: inertProcess
        )
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
        let projectTerminal = projectView.getTerminal()
        let quickTerminal = quickView.getTerminal()

        #expect(projectTerminal.options.cursorStyle.tagName == "blinkBar")
        #expect(quickTerminal.options.cursorStyle.tagName == "blinkBar")

        projectTab.startIfNeeded()
        quickTab.startIfNeeded()
        let projectProcess = try #require(projectView.process)
        let quickProcess = try #require(quickView.process)
        let projectPID = projectProcess.shellPid
        let quickPID = quickProcess.shellPid
        let projectPTY = projectProcess.childfd
        let quickPTY = quickProcess.childfd
        feed("project-cursor-sentinel", to: projectView)
        feed("quick-cursor-sentinel", to: quickView)

        #expect(projectPID > 0)
        #expect(quickPID > 0)
        #expect(projectPTY >= 0)
        #expect(quickPTY >= 0)
        #expect(
            projectTerminal.getLine(row: 0)?
                .translateToString(trimRight: true)
                .contains("project-cursor-sentinel") == true
        )
        #expect(
            quickTerminal.getLine(row: 0)?
                .translateToString(trimRight: true)
                .contains("quick-cursor-sentinel") == true
        )

        cursorSettings.cursorShape = .underline
        cursorSettings.cursorBlinks = false
        let propagated = await waitForTerminalSettingsCondition {
            projectTerminal.options.cursorStyle.tagName == "steadyUnderline"
                && quickTerminal.options.cursorStyle.tagName == "steadyUnderline"
        }

        #expect(propagated)

        feed("\u{1B}[2 q", to: projectView)
        feed("\u{1B}[2 q", to: quickView)
        #expect(projectTerminal.options.cursorStyle.tagName == "steadyBlock")
        #expect(quickTerminal.options.cursorStyle.tagName == "steadyBlock")

        // Codex/crossterm restores the user's cursor with Ps=0 when its TUI
        // exits. Project and Quick Terminal tabs share this exact policy.
        feed("\u{1B}[0 q", to: projectView)
        feed("\u{1B}[0 q", to: quickView)
        #expect(projectTerminal.options.cursorStyle.tagName == "steadyUnderline")
        #expect(quickTerminal.options.cursorStyle.tagName == "steadyUnderline")
        #expect(cursorSettings.cursorStyle.tagName == "steadyUnderline")
        #expect(
            fixture.defaults.string(
                forKey: TerminalCursorSettings.Keys.cursorStyle
            ) == "steadyUnderline"
        )

        #expect(projectTab.terminalView === projectView)
        #expect(quickTab.terminalView === quickView)
        #expect(projectView.getTerminal() === projectTerminal)
        #expect(quickView.getTerminal() === quickTerminal)
        #expect(projectView.process === projectProcess)
        #expect(quickView.process === quickProcess)
        #expect(projectView.process?.shellPid == projectPID)
        #expect(quickView.process?.shellPid == quickPID)
        #expect(projectView.process?.childfd == projectPTY)
        #expect(quickView.process?.childfd == quickPTY)
        #expect(!projectTab.isTerminated)
        #expect(!quickTab.isTerminated)
        #expect(
            projectTerminal.getLine(row: 0)?
                .translateToString(trimRight: true)
                .contains("project-cursor-sentinel") == true
        )
        #expect(
            quickTerminal.getLine(row: 0)?
                .translateToString(trimRight: true)
                .contains("quick-cursor-sentinel") == true
        )
    }

    @Test("Theme repaints preserve application-issued DECSCUSR styles")
    func decscusrRemainsAuthoritativeAcrossThemeChanges() async throws {
        let fixture = try TerminalThemeSettingsFixture()
        let themeSettings = fixture.makeSettings()
        let cursorSettings = TerminalCursorSettings(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        themeSettings.appearancePolicy = .alwaysDark
        let tab = TerminalTab(
            name: "cursor",
            themeSettings: themeSettings,
            cursorSettings: cursorSettings
        )
        let view = try #require(tab.terminalView as? PineTerminalView)
        let terminal = view.getTerminal()

        #expect(terminal.options.cursorStyle.tagName == "blinkBar")

        feed("\u{1B}[2 q", to: view)
        #expect(terminal.options.cursorStyle.tagName == "steadyBlock")

        themeSettings.setTheme(id: TerminalTheme.dracula.id)
        let repainted = await waitForTerminalSettingsCondition {
            view.nativeBackgroundColor
                == TerminalTheme.dracula.dark.backgroundColor()
        }
        #expect(repainted)
        #expect(terminal.options.cursorStyle.tagName == "steadyBlock")

        cursorSettings.cursorShape = .underline
        #expect(terminal.options.cursorStyle.tagName == "blinkUnderline")

        feed("\u{1B}[6 q", to: view)
        await Task.yield()
        #expect(terminal.options.cursorStyle.tagName == "steadyBar")
    }

    @Test("DECSCUSR maps all six styles without changing preferences")
    func decscusrMapsEveryStyleWithoutPersisting() throws {
        let fixture = try TerminalCursorSettingsFixture()
        let settings = fixture.makeSettings()
        let tab = TerminalTab(name: "cursor", cursorSettings: settings)
        let view = try #require(tab.terminalView as? PineTerminalView)
        let expectedStyles = [
            (1, "blinkBlock"),
            (2, "steadyBlock"),
            (3, "blinkUnderline"),
            (4, "steadyUnderline"),
            (5, "blinkBar"),
            (6, "steadyBar"),
        ]

        for (parameter, expectedTag) in expectedStyles {
            feed("\u{1B}[\(parameter) q", to: view)
            #expect(
                view.getTerminal().options.cursorStyle.tagName == expectedTag
            )
        }

        #expect(settings.cursorStyle.tagName == "blinkBar")
        #expect(
            fixture.defaults.string(
                forKey: TerminalCursorSettings.Keys.cursorStyle
            ) == nil
        )
    }

    @Test("Codex default cursor reset restores the persisted preference")
    func decscusrDefaultResetRestoresPreference() throws {
        let fixture = try TerminalCursorSettingsFixture()
        let settings = fixture.makeSettings()
        settings.setCursorStyle(.steadyUnderline)
        let tab = TerminalTab(name: "cursor-reset", cursorSettings: settings)
        let view = try #require(tab.terminalView as? PineTerminalView)
        let terminal = view.getTerminal()

        feed("\u{1B}[2 q", to: view)
        #expect(terminal.options.cursorStyle.tagName == "steadyBlock")

        feed("\u{1B}[0 q", to: view)

        #expect(terminal.options.cursorStyle.tagName == "steadyUnderline")
        #expect(settings.cursorStyle.tagName == "steadyUnderline")
        #expect(
            fixture.defaults.string(
                forKey: TerminalCursorSettings.Keys.cursorStyle
            ) == "steadyUnderline"
        )
    }

    @Test("Default cursor resets survive every ESC and C1 chunk boundary")
    func decscusrDefaultResetSurvivesEveryChunkBoundary() throws {
        let fixture = try TerminalCursorSettingsFixture()
        let settings = fixture.makeSettings()
        settings.setCursorStyle(.steadyUnderline)
        let tab = TerminalTab(name: "cursor-splits", cursorSettings: settings)
        let view = try #require(tab.terminalView as? PineTerminalView)
        let terminal = view.getTerminal()
        let resetSequences: [[UInt8]] = [
            Array("\u{1B}[0 q".utf8),
            Array("\u{1B}[ q".utf8),
            [0x9B, 0x30, 0x20, 0x71],
            [0x9B, 0x20, 0x71],
        ]

        for sequence in resetSequences {
            for splitIndex in 0...sequence.count {
                tab.applyPreferredCursorStyle()
                feed("\u{1B}[2 q", to: view)
                #expect(terminal.options.cursorStyle.tagName == "steadyBlock")

                feed(Array(sequence.prefix(splitIndex)), to: view)
                feed(Array(sequence.dropFirst(splitIndex)), to: view)

                #expect(
                    terminal.options.cursorStyle.tagName == "steadyUnderline",
                    "Failed at split \(splitIndex) for \(sequence)"
                )
            }
        }
    }

    @Test("The last supported DECSCUSR wins in stream order")
    func decscusrUsesLastSupportedDirective() throws {
        let fixture = try TerminalCursorSettingsFixture()
        let settings = fixture.makeSettings()
        settings.setCursorStyle(.steadyUnderline)
        let tab = TerminalTab(name: "cursor-ordering", cursorSettings: settings)
        let view = try #require(tab.terminalView as? PineTerminalView)
        let terminal = view.getTerminal()

        feed("\u{1B}[0 q\u{1B}[6 q", to: view)
        #expect(terminal.options.cursorStyle.tagName == "steadyBar")

        feed("\u{1B}[2 q\u{1B}[0 q", to: view)
        #expect(terminal.options.cursorStyle.tagName == "steadyUnderline")

        // SwiftTerm currently reads the first value of a multi-parameter
        // command. Pine must keep the last grammatically supported directive
        // authoritative even when such a lookalike follows it.
        feed("\u{1B}[0 q\u{1B}[0;1 q", to: view)
        #expect(terminal.options.cursorStyle.tagName == "steadyUnderline")

        feed("\u{1B}[6 q", to: view)
        feed("\u{1B}[0;1 q", to: view)
        #expect(terminal.options.cursorStyle.tagName == "steadyBar")
    }

    @Test("DECSCUSR tracker rejects text, control strings, and invalid grammar")
    func decscusrTrackerRejectsLookalikes() throws {
        let explicitBar = Array("\u{1B}[6 q".utf8)
        let invalidSequences: [[UInt8]] = [
            Array("visible [0 q text".utf8),
            Array("\u{1B}[7 q".utf8),
            Array("\u{1B}[0;1 q".utf8),
            Array("\u{1B}[; q".utf8),
            Array("\u{1B}[?0 q".utf8),
            Array("\u{1B}[0! q".utf8),
            Array("\u{1B}[0  q".utf8),
            Array("\u{1B}[0q".utf8),
            Array("\u{1B}[0 p".utf8),
        ]

        for invalidSequence in invalidSequences {
            var tracker = DECSCUSRStreamTracker()
            let stream = explicitBar + invalidSequence
            #expect(
                tracker.consume(stream[...]) == .explicit(parameter: 6),
                "Invalid sequence changed the decision: \(invalidSequence)"
            )
        }

        let embeddedSequences: [[UInt8]] = [
            // 7-bit OSC containing an ESC-[ lookalike, terminated by BEL.
            [0x1B, 0x5D, 0x30, 0x3B, 0x1B, 0x5B, 0x30, 0x20, 0x71, 0x07],
            // C1 OSC containing a C1 CSI lookalike, terminated by C1 ST.
            [0x9D, 0x30, 0x3B, 0x9B, 0x30, 0x20, 0x71, 0x9C],
            // 7-bit DCS payload containing an ESC-[ lookalike and ESC-\\ ST.
            [0x1B, 0x50, 0x71, 0x1B, 0x5B, 0x30, 0x20, 0x71, 0x1B, 0x5C],
            // C1 DCS payload containing a C1 CSI lookalike and C1 ST.
            [0x90, 0x71, 0x9B, 0x30, 0x20, 0x71, 0x9C],
        ]

        for embeddedSequence in embeddedSequences {
            var tracker = DECSCUSRStreamTracker()
            #expect(tracker.consume(embeddedSequence[...]) == nil)
            let reset = Array("\u{1B}[0 q".utf8)
            #expect(tracker.consume(reset[...]) == .preferred)
        }

        let fixture = try TerminalCursorSettingsFixture()
        let settings = fixture.makeSettings()
        settings.setCursorStyle(.steadyUnderline)
        let tab = TerminalTab(name: "cursor-negatives", cursorSettings: settings)
        let view = try #require(tab.terminalView as? PineTerminalView)
        feed(explicitBar, to: view)

        for lookalike in invalidSequences + embeddedSequences {
            feed(lookalike, to: view)
            #expect(
                view.getTerminal().options.cursorStyle.tagName == "steadyBar",
                "Lookalike changed the live cursor: \(lookalike)"
            )
        }

        // A hostile parameter run cannot overflow or grow parser storage.
        var oversized = Array("\u{1B}[".utf8)
        oversized.append(contentsOf: repeatElement(0x39, count: 4_096))
        oversized.append(contentsOf: [0x20, 0x71])
        var boundedTracker = DECSCUSRStreamTracker()
        let boundedStream = explicitBar + oversized
        #expect(
            boundedTracker.consume(boundedStream[...])
                == .explicit(parameter: 6)
        )
    }
}

@MainActor
private func feed(_ text: String, to view: PineTerminalView) {
    let bytes = Array(text.utf8)
    view.dataReceived(slice: bytes[...])
}

@MainActor
private func feed(_ bytes: [UInt8], to view: PineTerminalView) {
    view.dataReceived(slice: bytes[...])
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

@MainActor
private struct TerminalCursorSettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let notificationCenter = NotificationCenter()

    init() throws {
        suiteName = "TerminalCursorSettingsTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeSettings() -> TerminalCursorSettings {
        TerminalCursorSettings(
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
        "settings.terminal.cursor.blink",
        "settings.terminal.cursor.help",
        "settings.terminal.cursor.shape",
        "settings.terminal.cursor.title",
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
        "terminal.cursor.shape.block",
        "terminal.cursor.shape.underline",
        "terminal.cursor.shape.verticalBar",
        "terminal.theme.digital-rain.name",
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

    /// Guards the class of bug where a new built-in theme ships with a name key
    /// that was never added to the catalog — the picker would then render the
    /// raw key ("terminal.theme.digital-rain.name") as the theme's name.
    @Test("Every built-in theme's name key exists in the catalog")
    func everyBuiltInThemeNameKeyIsTranslated() throws {
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

        for theme in TerminalTheme.builtIn {
            #expect(
                Self.keys.contains(theme.nameKey),
                "\(theme.nameKey) is missing from the localization coverage list"
            )
            let entry = try #require(
                catalog[theme.nameKey] as? [String: Any],
                "\(theme.nameKey) is missing from Localizable.xcstrings"
            )
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            #expect(Set(localizations.keys) == Set(Self.languages))
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
        #expect(
            fixture.defaults.double(
                forKey: "quickTerminal.heightFraction"
            ) == 0.8
        )

        fixture.defaults.set(
            Double.nan,
            forKey: "quickTerminal.heightFraction"
        )
        let nonFinite = fixture.makeSettings()
        #expect(nonFinite.heightFraction == 0.4)
        #expect(
            fixture.defaults.double(
                forKey: "quickTerminal.heightFraction"
            ) == 0.4
        )
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

    @Test("Panel size normalizes bounds and non-finite writes")
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

        settings.heightFraction = Double.nan
        #expect(settings.heightFraction == 0.4)
        #expect(fixture.makeSettings().heightFraction == 0.4)
        #expect(counter.value == 3)

        settings.heightFraction = Double.infinity
        #expect(settings.heightFraction == 0.4)
        #expect(fixture.makeSettings().heightFraction == 0.4)
        #expect(counter.value == 4)
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
        fixture.settings.hideOnFocusLoss = false
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
