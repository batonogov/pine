//
//  QuickTerminalWindowTests.swift
//  PineTests
//
//  Window chrome tests for the quick terminal panel (#1648): the panel
//  must be closable and resizable, and a user-initiated close must hide
//  the keep-alive session instead of tearing it down.
//

import Testing
import AppKit
import Carbon.HIToolbox
@testable import Pine

@MainActor
struct QuickTerminalWindowTests {

    private func makeWindow() -> QuickTerminalWindow {
        QuickTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 320)
        )
    }

    @Test("Panel is closable and resizable")
    func panelIsClosableAndResizable() {
        let window = makeWindow()
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(window.standardWindowButton(.closeButton)?.isEnabled == true)
    }

    @Test("Close button hides the panel without destroying the window")
    func performCloseHidesWithoutClosing() {
        let window = makeWindow()
        var hideCalls = 0
        window.onHide = { hideCalls += 1 }
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.isVisible)

        window.performClose(nil)

        #expect(hideCalls == 1)
        // Hidden by the owner, not closed: the panel itself stays on screen
        // and alive so the keep-alive session can be re-shown.
        #expect(window.isVisible)
    }

    @Test("Programmatic close still tears the window down")
    func programmaticCloseDoesNotHide() {
        let window = makeWindow()
        var hideCalls = 0
        window.onHide = { hideCalls += 1 }

        window.close()

        #expect(hideCalls == 0)
    }

    @Test("Zoom and full-screen stay disabled on the drop-down panel")
    func zoomStaysDisabled() {
        let window = makeWindow()
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == false)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary) == false)
        #expect(window.contentMinSize == NSSize(width: 480, height: 160))

        // `zoom(_:)` is a deliberate no-op (titlebar double-click path).
        let frame = window.frame
        window.zoom(nil)
        #expect(window.frame == frame)
    }

    @Test("Escape hides the panel via keyDown")
    func escapeHides() throws {
        let window = makeWindow()
        var hideCalls = 0
        window.onHide = { hideCalls += 1 }

        window.keyDown(with: try keyEvent(keyCode: UInt16(kVK_Escape)))

        #expect(hideCalls == 1)
    }

    @Test("⌘W hides the panel via keyDown")
    func commandWHides() throws {
        let window = makeWindow()
        var hideCalls = 0
        window.onHide = { hideCalls += 1 }

        window.keyDown(with: try keyEvent(
            keyCode: UInt16(kVK_ANSI_W),
            modifiers: .command,
            characters: "w"
        ))

        #expect(hideCalls == 1)
    }

    @Test("Live-resize end persists the dragged height into settings")
    func liveResizePersistsHeightFraction() async throws {
        let fixture = try QuickTerminalWindowControllerFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.show()
        let panel = try #require(controller.windowForTesting)
        let screenFrame = try #require(panel.screen?.visibleFrame)
        let targetHeight = (screenFrame.height * 0.5).rounded()
        panel.setFrame(
            NSRect(
                x: screenFrame.minX,
                y: screenFrame.maxY - targetHeight,
                width: screenFrame.width,
                height: targetHeight
            ),
            display: false
        )

        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification,
            object: panel
        )
        // The observer hops through OperationQueue.main + a MainActor task;
        // awaiting yields the main actor so the write-back can land.
        let persisted = await waitForCondition {
            fixture.settings.heightFraction != 0.4
        }

        #expect(persisted)
        #expect(abs(fixture.settings.heightFraction - 0.5) < 0.001)
        #expect(
            abs(
                fixture.defaults.double(
                    forKey: "quickTerminal.heightFraction"
                ) - 0.5
            ) < 0.001
        )

        // The next show reproduces the dragged size from settings.
        controller.hide()
        controller.show()
        #expect(controller.presentedFrame?.height == targetHeight)
    }

    @Test("Live-resize write-back is clamped to the supported range")
    func liveResizeWriteBackIsClamped() async throws {
        let fixture = try QuickTerminalWindowControllerFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.show()
        let panel = try #require(controller.windowForTesting)
        let screenFrame = try #require(panel.screen?.visibleFrame)
        let tinyHeight = (screenFrame.height * 0.05).rounded()
        panel.setFrame(
            NSRect(
                x: screenFrame.minX,
                y: screenFrame.maxY - tinyHeight,
                width: screenFrame.width,
                height: tinyHeight
            ),
            display: false
        )

        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification,
            object: panel
        )
        let persisted = await waitForCondition {
            fixture.settings.heightFraction != 0.4
        }

        // 5 % is below the supported floor; settings clamp to 0.2.
        #expect(persisted)
        #expect(fixture.settings.heightFraction == 0.2)

        controller.hide()
        controller.show()
        #expect(
            controller.presentedFrame?.height
                == (screenFrame.height * 0.2).rounded()
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String = "\u{1b}"
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

    private func waitForCondition(
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 where !predicate() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    @Test("Closing the visible panel keeps the keep-alive session")
    func closeButtonHidesButKeepsSession() throws {
        let fixture = try QuickTerminalWindowControllerFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.show()
        let panel = try #require(controller.windowForTesting)
        let firstTabID = try #require(controller.paneState.activeTab?.id)
        #expect(controller.isVisible)

        panel.performClose(nil)

        #expect(controller.isVisible == false)
        #expect(controller.paneState.terminalTabs.count == 1)

        controller.show()
        #expect(controller.isVisible)
        #expect(controller.paneState.activeTab?.id == firstTabID)
    }
}

@MainActor
private struct QuickTerminalWindowControllerFixture {
    let suiteName: String
    let defaults: UserDefaults
    let settings: QuickTerminalSettings
    let controller: QuickTerminalController

    init() throws {
        suiteName = "QuickTerminalWindowTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let settings = QuickTerminalSettings(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )
        settings.enabled = true
        settings.hideOnFocusLoss = false
        self.settings = settings
        controller = QuickTerminalController(settings: settings)
    }

    func cleanUp() {
        controller.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
    }
}
