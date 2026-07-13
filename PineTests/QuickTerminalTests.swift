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

    // MARK: - QuickTerminalController

    @Test("coordinator starts hidden with no tab")
    func coordinatorInitialState() {
        let coordinator = QuickTerminalController()
        #expect(coordinator.isVisible == false)
        #expect(coordinator.paneState.terminalTabs.isEmpty)
    }

    @Test("toggle flips visibility")
    func toggleFlipsVisibility() {
        let coordinator = QuickTerminalController()
        defer { coordinator.shutdown() }
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
    func hideKeepsSessionAlive() {
        let coordinator = QuickTerminalController()
        defer { coordinator.shutdown() }
        coordinator.show()
        let firstTabID = coordinator.paneState.activeTab?.id
        coordinator.hide()
        coordinator.show()
        // Same tab survives the hide/show cycle (keep-alive).
        #expect(coordinator.paneState.activeTab?.id == firstTabID)
    }

    @Test("cwd resolves to most-recent project, else $HOME")
    func cwdFallbackChain() {
        let coordinator = QuickTerminalController()
        defer { coordinator.shutdown() }
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
