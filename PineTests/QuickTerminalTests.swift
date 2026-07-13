//
//  QuickTerminalTests.swift
//  PineTests
//
//  Tests for the global drop-down quick terminal (#1113).
//

import Testing
import AppKit
@testable import Pine

@MainActor
struct QuickTerminalTests {

    // MARK: - GlobalHotkeyManager

    @Test("GlobalHotkeyManager starts unregistered")
    func managerInitiallyUnregistered() {
        let manager = GlobalHotkeyManager()
        #expect(manager.isRegistered == false)
    }

    @Test("register attempt does not crash in a test host; idempotent")
    func registerIsSafeInTestHost() {
        // RegisterEventHotKey needs a running app event loop, which the
        // unit-test host does not provide — so we assert only that the call
        // is safe and symmetric, not that it succeeds. Real registration is
        // validated by manual smoke-test (press the hotkey) and by the app
        // launching with the hotkey armed.
        let manager = GlobalHotkeyManager()
        manager.onTrigger = {}
        for _ in 0..<3 {
            _ = manager.register(
                keyCode: GlobalHotkeyManager.defaultQuickTerminalKeyCode,
                carbonModifiers: GlobalHotkeyManager.defaultQuickTerminalModifiers
            )
        }
        // unregister is safe whether or not register succeeded.
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
        coordinator.show()
        let firstTabID = coordinator.paneState.activeTab?.id
        coordinator.hide()
        coordinator.show()
        // Same tab survives the hide/show cycle (keep-alive).
        #expect(coordinator.paneState.activeTab?.id == firstTabID)
    }

    @Test("cwd falls back through recent projects to home")
    func cwdFallbackChain() {
        let coordinator = QuickTerminalController()
        let registry = ProjectRegistry()
        coordinator.registry = registry
        coordinator.show()
        let cwd = coordinator.paneState.activeTab?.workingDirectoryURL
        // resolveCwd priority: open project → recent project → $HOME. The
        // test host has no window-open project, so the cwd is either the
        // most-recent project (if any are persisted) or $HOME.
        let expected: [String] = registry.recentProjects.map(\.path) + [NSHomeDirectory()]
        #expect(cwd.map(\.path).map(expected.contains) == true)
        coordinator.hide()
    }
}
