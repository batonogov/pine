//
//  GlobalTabSwitcherKeyControllerTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Global Tab Switcher Key Controller")
@MainActor
struct GlobalTabSwitcherKeyControllerTests {
    @MainActor
    private final class Delegate: GlobalTabSwitcherKeyControllerDelegate {
        var globalTabSwitcherTarget: GlobalTabSwitcherTarget?
    }

    private struct Fixture {
        let manager: PaneManager
        let tabManager: TabManager
        let window: NSWindow
        let originalID: UUID
        let alternateID: UUID
    }

    private func makeFixture(
        prefix: String,
        tabCount: Int = 2
    ) throws -> Fixture {
        precondition(tabCount >= 2)
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let tabManager = try #require(manager.tabManager(for: paneID))
        for index in 0..<tabCount {
            tabManager.tabs.append(EditorTab(
                url: URL(
                    fileURLWithPath: "/tmp/\(prefix)-\(index).swift"
                ),
                content: "",
                savedContent: ""
            ))
            manager.selectEditorTab(tabManager.tabs[index].id, in: paneID)
        }
        return Fixture(
            manager: manager,
            tabManager: tabManager,
            window: NSWindow(),
            originalID: tabManager.tabs[tabCount - 1].id,
            alternateID: tabManager.tabs[tabCount - 2].id
        )
    }

    private func makeController(
        target: GlobalTabSwitcherTarget,
        center: NotificationCenter
    ) -> (GlobalTabSwitcherKeyController, Delegate) {
        let delegate = Delegate()
        delegate.globalTabSwitcherTarget = target
        let controller = GlobalTabSwitcherKeyController(
            notificationCenter: center,
            observesSystemEvents: false
        )
        controller.delegate = delegate
        controller.install()
        return (controller, delegate)
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @Test("Control-Tab starts a visual session without moving focus")
    func startsVisualSession() throws {
        let fixture = try makeFixture(prefix: "controller-start")
        let center = NotificationCenter()
        let (controller, delegate) = makeController(
            target: GlobalTabSwitcherTarget(
                window: fixture.window,
                paneManager: fixture.manager
            ),
            center: center
        )
        defer { withExtendedLifetime(delegate) {} }

        #expect(controller.handleControlTab(reverse: false))
        #expect(fixture.manager.isGlobalTabSwitcherActive)
        #expect(fixture.tabManager.activeTabID == fixture.originalID)
        #expect(
            fixture.manager.globalTabSwitcherSession?.selectedIdentity?.tabID
                == fixture.alternateID
        )
    }

    @Test("Repeated Control-Tab cycles and release commits")
    func cyclesAndCommitsOnRelease() throws {
        let fixture = try makeFixture(prefix: "controller-commit")
        let center = NotificationCenter()
        let (controller, delegate) = makeController(
            target: GlobalTabSwitcherTarget(
                window: fixture.window,
                paneManager: fixture.manager
            ),
            center: center
        )
        defer { withExtendedLifetime(delegate) {} }

        #expect(controller.handleControlTab(reverse: false))
        #expect(controller.handleControlTab(reverse: false))
        #expect(!controller.handleModifierFlagsChanged(.control))
        #expect(fixture.manager.isGlobalTabSwitcherActive)
        #expect(controller.handleModifierFlagsChanged([]))

        #expect(!fixture.manager.isGlobalTabSwitcherActive)
        #expect(fixture.tabManager.activeTabID == fixture.originalID)
        #expect(
            fixture.manager.globalTabSwitchOrder.first?.tabID
                == fixture.originalID
        )
    }

    @Test("Reverse Control-Tab commits the previous item")
    func reverseCommitsPreviousItem() throws {
        let fixture = try makeFixture(prefix: "controller-reverse")
        let center = NotificationCenter()
        let (controller, delegate) = makeController(
            target: GlobalTabSwitcherTarget(
                window: fixture.window,
                paneManager: fixture.manager
            ),
            center: center
        )
        defer { withExtendedLifetime(delegate) {} }

        #expect(controller.handleControlTab(reverse: true))
        #expect(controller.handleModifierFlagsChanged([]))
        #expect(fixture.tabManager.activeTabID == fixture.alternateID)
    }

    @Test("Changing key windows discards the old owner before starting new")
    func ownerWindowDoesNotMigrate() throws {
        let first = try makeFixture(prefix: "controller-first")
        let second = try makeFixture(prefix: "controller-second")
        let center = NotificationCenter()
        let (controller, delegate) = makeController(
            target: GlobalTabSwitcherTarget(
                window: first.window,
                paneManager: first.manager
            ),
            center: center
        )
        defer { withExtendedLifetime(delegate) {} }

        #expect(controller.handleControlTab(reverse: false))
        #expect(first.manager.selectEditorTab(
            first.alternateID,
            in: first.manager.activePaneID
        ))
        let organicFocusRequest = try #require(
            first.tabManager.pendingFocusRequestID
        )
        delegate.globalTabSwitcherTarget = GlobalTabSwitcherTarget(
            window: second.window,
            paneManager: second.manager
        )
        #expect(controller.handleControlTab(reverse: false))

        #expect(!first.manager.isGlobalTabSwitcherActive)
        #expect(first.tabManager.activeTabID == first.alternateID)
        #expect(first.tabManager.pendingFocusTabID == first.alternateID)
        #expect(
            first.tabManager.pendingFocusRequestID == organicFocusRequest
        )
        #expect(second.manager.isGlobalTabSwitcherActive)
    }

    @Test("Losing every project target discards the pinned owner")
    func missingTargetDiscardsOwner() throws {
        let fixture = try makeFixture(prefix: "controller-no-target")
        let center = NotificationCenter()
        let (controller, delegate) = makeController(
            target: GlobalTabSwitcherTarget(
                window: fixture.window,
                paneManager: fixture.manager
            ),
            center: center
        )
        defer { withExtendedLifetime(delegate) {} }

        fixture.tabManager.pendingFocusTabID = fixture.originalID
        let originalFocusRequest = try #require(
            fixture.tabManager.pendingFocusRequestID
        )
        #expect(controller.handleControlTab(reverse: false))
        delegate.globalTabSwitcherTarget = nil
        #expect(!controller.handleControlTab(reverse: false))

        #expect(!fixture.manager.isGlobalTabSwitcherActive)
        #expect(fixture.tabManager.activeTabID == fixture.originalID)
        #expect(fixture.tabManager.pendingFocusTabID == fixture.originalID)
        #expect(
            fixture.tabManager.pendingFocusRequestID == originalFocusRequest
        )
    }

    @Test("Control release commits the original owner after target changes")
    func releaseUsesPinnedOwner() throws {
        let first = try makeFixture(prefix: "controller-pinned")
        let second = try makeFixture(prefix: "controller-other")
        let center = NotificationCenter()
        let (controller, delegate) = makeController(
            target: GlobalTabSwitcherTarget(
                window: first.window,
                paneManager: first.manager
            ),
            center: center
        )
        defer { withExtendedLifetime(delegate) {} }

        #expect(controller.handleControlTab(reverse: false))
        delegate.globalTabSwitcherTarget = GlobalTabSwitcherTarget(
            window: second.window,
            paneManager: second.manager
        )
        #expect(controller.handleModifierFlagsChanged([]))

        #expect(first.tabManager.activeTabID == first.alternateID)
        #expect(!second.manager.isGlobalTabSwitcherActive)
    }

    @Test("Owner-window lifecycle discards without changing focus")
    func windowLifecycleCancellation() throws {
        let notifications: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ]
        for (index, name) in notifications.enumerated() {
            let fixture = try makeFixture(
                prefix: "controller-window-\(index)"
            )
            let center = NotificationCenter()
            let (controller, delegate) = makeController(
                target: GlobalTabSwitcherTarget(
                    window: fixture.window,
                    paneManager: fixture.manager
                ),
                center: center
            )
            fixture.tabManager.pendingFocusTabID = fixture.originalID
            let originalFocusRequest = try #require(
                fixture.tabManager.pendingFocusRequestID
            )

            #expect(controller.handleControlTab(reverse: false))
            center.post(name: name, object: NSWindow())
            #expect(fixture.manager.isGlobalTabSwitcherActive)

            center.post(name: name, object: fixture.window)
            #expect(!fixture.manager.isGlobalTabSwitcherActive)
            #expect(fixture.tabManager.activeTabID == fixture.originalID)
            #expect(
                fixture.tabManager.pendingFocusTabID == fixture.originalID
            )
            #expect(
                fixture.tabManager.pendingFocusRequestID
                    == originalFocusRequest
            )
            withExtendedLifetime(delegate) {}
        }
    }

    @Test("Application deactivation discards without restoring focus")
    func applicationLifecycleCancellation() throws {
        let fixture = try makeFixture(prefix: "controller-app")
        let center = NotificationCenter()
        let (controller, delegate) = makeController(
            target: GlobalTabSwitcherTarget(
                window: fixture.window,
                paneManager: fixture.manager
            ),
            center: center
        )
        defer { withExtendedLifetime(delegate) {} }

        fixture.tabManager.pendingFocusTabID = fixture.originalID
        #expect(controller.handleControlTab(reverse: false))
        #expect(fixture.manager.selectEditorTab(
            fixture.alternateID,
            in: fixture.manager.activePaneID
        ))
        let organicFocusRequest = try #require(
            fixture.tabManager.pendingFocusRequestID
        )
        center.post(
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        #expect(!fixture.manager.isGlobalTabSwitcherActive)
        #expect(fixture.tabManager.activeTabID == fixture.alternateID)
        #expect(fixture.tabManager.pendingFocusTabID == fixture.alternateID)
        #expect(
            fixture.tabManager.pendingFocusRequestID == organicFocusRequest
        )
    }

    @Test(
        "Physical Control-Tab ignores incidental flags but rejects logical extras"
    )
    func exactKeyDownRouting() throws {
        let fixture = try makeFixture(
            prefix: "controller-event",
            tabCount: 3
        )
        let center = NotificationCenter()
        let (controller, delegate) = makeController(
            target: GlobalTabSwitcherTarget(
                window: fixture.window,
                paneManager: fixture.manager
            ),
            center: center
        )
        defer { withExtendedLifetime(delegate) {} }
        let extraModifierEvent = try keyEvent(
            keyCode: UInt16(KeyboardShortcutMatcher.PhysicalKey.tab),
            modifiers: [.control, .option],
            characters: "\t"
        )
        #expect(!controller.handleKeyDownEvent(extraModifierEvent))
        #expect(!fixture.manager.isGlobalTabSwitcherActive)

        let incidental: NSEvent.ModifierFlags = [
            .capsLock,
            .numericPad,
            .function,
            .help,
        ]
        let controlTab = try keyEvent(
            keyCode: UInt16(KeyboardShortcutMatcher.PhysicalKey.tab),
            modifiers: NSEvent.ModifierFlags.control.union(incidental),
            characters: "\t"
        )
        #expect(controller.handleKeyDownEvent(controlTab))
        #expect(fixture.manager.isGlobalTabSwitcherActive)
        #expect(
            fixture.manager.globalTabSwitcherSession?.selectedIdentity?.tabID
                == fixture.alternateID
        )

        fixture.manager.discardGlobalTabSwitcherSession()
        let reverseControlTab = try keyEvent(
            keyCode: UInt16(KeyboardShortcutMatcher.PhysicalKey.tab),
            modifiers: NSEvent.ModifierFlags([.control, .shift])
                .union(incidental),
            characters: "\t"
        )
        #expect(controller.handleKeyDownEvent(reverseControlTab))
        #expect(
            fixture.manager.globalTabSwitcherSession?.selectedIdentity?.tabID
                == fixture.tabManager.tabs[0].id
        )
    }

    @Test("Escape is consumed only while the pinned gesture is active")
    func escapeRouting() throws {
        let fixture = try makeFixture(prefix: "controller-escape")
        let center = NotificationCenter()
        let (controller, delegate) = makeController(
            target: GlobalTabSwitcherTarget(
                window: fixture.window,
                paneManager: fixture.manager
            ),
            center: center
        )
        defer { withExtendedLifetime(delegate) {} }
        let escape = try keyEvent(
            keyCode: 53,
            modifiers: [],
            characters: "\u{1B}"
        )

        fixture.tabManager.pendingFocusTabID = fixture.originalID
        let originalFocusRequest = try #require(
            fixture.tabManager.pendingFocusRequestID
        )
        #expect(!controller.handleKeyDownEvent(escape))
        #expect(controller.handleControlTab(reverse: false))
        #expect(controller.handleKeyDownEvent(escape))
        #expect(!fixture.manager.isGlobalTabSwitcherActive)
        #expect(fixture.tabManager.activeTabID == fixture.originalID)
        #expect(fixture.tabManager.pendingFocusTabID == fixture.originalID)
        #expect(
            fixture.tabManager.pendingFocusRequestID == originalFocusRequest
        )

        #expect(controller.handleControlTab(reverse: false))
        #expect(fixture.manager.selectEditorTab(
            fixture.alternateID,
            in: fixture.manager.activePaneID
        ))
        let organicFocusRequest = try #require(
            fixture.tabManager.pendingFocusRequestID
        )
        #expect(controller.handleKeyDownEvent(escape))
        #expect(fixture.tabManager.activeTabID == fixture.originalID)
        #expect(fixture.tabManager.pendingFocusTabID == fixture.originalID)
        #expect(
            fixture.tabManager.pendingFocusRequestID != organicFocusRequest
        )
        #expect(!controller.handleKeyDownEvent(escape))
    }
}
