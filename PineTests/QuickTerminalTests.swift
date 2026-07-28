//
//  QuickTerminalTests.swift
//  PineTests
//
//  Tests for the global drop-down quick terminal (#1113).
//

import Testing
import AppKit
import Carbon.HIToolbox
@testable import Pine

@MainActor
struct QuickTerminalTests {

    // MARK: - GlobalHotkeyManager

    @Test("GlobalHotkeyManager starts unregistered")
    func managerInitiallyUnregistered() {
        let manager = GlobalHotkeyManager()
        #expect(manager.isRegistered == false)
    }

    @Test("register rejects unsafe shortcuts before calling Carbon")
    func registerRejectsUnsafeShortcuts() {
        let manager = GlobalHotkeyManager()

        #expect(
            manager.register(
                keyCode: UInt32(kVK_ANSI_K),
                carbonModifiers: 0
            ) == false
        )
        #expect(
            manager.register(
                keyCode: UInt32(kVK_ANSI_K),
                carbonModifiers: UInt32(shiftKey)
            ) == false
        )
        #expect(
            manager.register(
                keyCode: UInt32(kVK_UpArrow) + 1,
                carbonModifiers: UInt32(cmdKey)
            ) == false
        )
        #expect(manager.isRegistered == false)
    }

    @Test("register/unregister is safe and symmetric with a throwaway combo")
    func registerIsSafeAndSymmetric() {
        // Use a throwaway keyCode + modifiers unlikely to be claimed by any
        // real app, so the test never grabs the production ⌃⌥Space on the
        // developer's machine. The unit-test host (Pine.app) does run an
        // event loop, so registration may genuinely succeed — we assert
        // symmetry: after `unregister()`, `isRegistered` is false regardless
        // of whether `register()` succeeded (the combo could be claimed by
        // another process). Real delivery is validated by the manual
        // smoke-test (press ⌃⌥Space from another app).
        let manager = GlobalHotkeyManager()
        manager.onTrigger = {}
        // F19 + ctrl+option+shift — extremely unlikely to conflict.
        let dummyKeyCode: UInt32 = UInt32(kVK_F19)
        let dummyMods: UInt32 = UInt32(controlKey | optionKey | shiftKey)
        for _ in 0..<3 {
            _ = manager.register(keyCode: dummyKeyCode, carbonModifiers: dummyMods)
        }
        manager.unregister()
        #expect(manager.isRegistered == false)
    }

    @Test("A conflicting replacement keeps and restores the working shortcut")
    func conflictingReplacementRollsBack() throws {
        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        let candidateKeyCodes = [
            kVK_F13,
            kVK_F14,
            kVK_F15,
            kVK_F16,
            kVK_F17,
            kVK_F18,
            kVK_F19,
            kVK_F20,
        ].map(UInt32.init)
        var reservations: [(manager: GlobalHotkeyManager, keyCode: UInt32)] = []

        for keyCode in candidateKeyCodes where reservations.count < 2 {
            let candidate = GlobalHotkeyManager()
            if candidate.register(
                keyCode: keyCode,
                carbonModifiers: modifiers
            ) {
                reservations.append((candidate, keyCode))
            }
        }
        #expect(
            reservations.count == 2,
            "The test requires two free throwaway function-key shortcuts"
        )
        let blocker = try #require(reservations.first)
        let working = try #require(reservations.last)
        defer {
            working.manager.unregister()
            blocker.manager.unregister()
        }

        let suiteName = "QuickTerminalHotkeyRollback-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = QuickTerminalSettings(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )
        #expect(settings.setHotkey(
            keyCode: blocker.keyCode,
            modifiers: modifiers
        ))

        #expect(working.manager.applyQuickTerminalSettings(settings) == false)
        #expect(working.manager.isRegistered)
        #expect(
            working.manager.registeredShortcut == GlobalHotkeyShortcut(
                keyCode: working.keyCode,
                modifiers: modifiers
            )
        )
        #expect(settings.keyCode == working.keyCode)
        #expect(settings.modifiers == modifiers)

        working.manager.unregister()
        #expect(settings.setHotkey(
            keyCode: blocker.keyCode,
            modifiers: modifiers
        ))
        #expect(working.manager.applyQuickTerminalSettings(settings) == false)
        #expect(working.manager.isRegistered == false)
        #expect(settings.enabled == false)
    }

    // MARK: - QuickTerminalController

    @Test("coordinator starts hidden with no tab")
    func coordinatorInitialState() throws {
        let fixture = try QuickTerminalControllerFixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.controller
        #expect(coordinator.isVisible == false)
        #expect(coordinator.paneState.terminalTabs.isEmpty)
    }

    @Test("toggle flips visibility")
    func toggleFlipsVisibility() throws {
        let fixture = try QuickTerminalControllerFixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.controller
        // First toggle shows the window (keep-alive: created on first show).
        coordinator.toggle()
        #expect(coordinator.isVisible)
        #expect(coordinator.paneState.terminalTabs.count == 1)
        // Second toggle hides it — the session (tab) stays alive.
        coordinator.toggle()
        #expect(coordinator.isVisible == false)
        #expect(coordinator.paneState.terminalTabs.count == 1)
    }

    @Test("hide after show keeps the keep-alive session")
    func hideKeepsSessionAlive() throws {
        let fixture = try QuickTerminalControllerFixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.controller
        coordinator.show()
        let firstTabID = coordinator.paneState.activeTab?.id
        coordinator.hide()
        coordinator.show()
        // Same tab survives the hide/show cycle (keep-alive).
        #expect(coordinator.paneState.activeTab?.id == firstTabID)
    }

    @Test("cwd resolves to most-recent project, else $HOME")
    func cwdFallbackChain() throws {
        let fixture = try QuickTerminalControllerFixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.controller
        let registry = ProjectRegistry()
        coordinator.registry = registry
        coordinator.show()
        // No open project (openProjects is empty) → resolveCwd returns
        // recentProjects.first ?? $HOME. Assert the EXACT value, not a set
        // membership, so the test catches a wrong selection (e.g. .last).
        let expected = registry.recentProjects.first?.path ?? NSHomeDirectory()
        #expect(coordinator.paneState.activeTab?.workingDirectoryURL?.path == expected)
        coordinator.hide()
    }
}

@MainActor
private struct QuickTerminalControllerFixture {
    let suiteName: String
    let defaults: UserDefaults
    let controller: QuickTerminalController

    init() throws {
        suiteName = "QuickTerminalControllerTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let settings = QuickTerminalSettings(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )
        settings.enabled = true
        controller = QuickTerminalController(settings: settings)
    }

    func cleanUp() {
        controller.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
    }
}
