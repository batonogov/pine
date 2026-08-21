//
//  AgentInboxPopoverSystemObjectsTests.swift
//  PineTests
//
//  The production `NSPopover` the anchor builds, and the AppKit conformances
//  every other suite substitutes away (#1491).
//
//  `AgentInboxPopoverCoordinatorTests` proves the orderings against a fake
//  handle, and `AgentInboxPresentationCoordinatorTests` proves host selection
//  against a fake host. That is what makes those orderings observable at all —
//  but it also means the real objects underneath them are reached by nothing:
//  `makeSystemPopover` could return a popover with the wrong behavior, the
//  wrong size, or no delegate, and `showPopover(from:)` could hang the Inbox
//  off the wrong edge of the toolbar button, with every one of those suites
//  green.
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Agent Inbox popover system objects", .serialized)
@MainActor
struct AgentInboxPopoverSystemObjectsTests {
    // MARK: - The popover the anchor builds

    @Test("the production popover is transient, sized, and delegated")
    func systemPopoverIsConfiguredForTheToolbar() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let delegate = Delegate()

        let handle = try #require(
            AgentInboxPopoverCoordinator.makeSystemPopover(
                anchor: fixture.anchor,
                context: fixture.context(delegate: delegate, reduceMotion: false)
            )
        )
        let popover = try #require(handle as? NSPopover)

        // `.transient` is what hands Escape and outside clicks to AppKit —
        // the whole reason the anchor needs `popoverWillClose` at all.
        #expect(popover.behavior == .transient)
        #expect(popover.contentSize == NSSize(width: 520, height: 540))
        #expect(
            popover.delegate === delegate,
            "Without the delegate the anchor never hears a transient close"
        )
        let hosting = try #require(
            popover.contentViewController as? NSHostingController<AgentInboxView>
        )
        #expect(hosting.preferredContentSize == popover.contentSize)
    }

    @Test("Reduce Motion turns the popover's animation off", arguments: [
        false, true,
    ])
    func systemPopoverFollowsReduceMotion(reduceMotion: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let handle = try #require(
            AgentInboxPopoverCoordinator.makeSystemPopover(
                anchor: fixture.anchor,
                context: fixture.context(
                    delegate: Delegate(),
                    reduceMotion: reduceMotion
                )
            )
        )
        let popover = try #require(handle as? NSPopover)

        #expect(popover.animates == !reduceMotion)
    }

    /// An anchor SwiftUI has not finished configuring builds nothing, and
    /// records nothing — the caller must be able to tell "not ready" from
    /// "shown", because it stores the result as the live popover either way.
    @Test("an incompletely configured anchor builds no popover", arguments: [
        (hasRegistry: true, hasOpenWindow: false),
        (hasRegistry: false, hasOpenWindow: true),
        (hasRegistry: false, hasOpenWindow: false),
    ])
    func systemPopoverRefusesAnUnreadyAnchor(
        hasRegistry: Bool,
        hasOpenWindow: Bool
    ) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let handle = AgentInboxPopoverCoordinator.makeSystemPopover(
            anchor: fixture.anchor,
            context: fixture.context(
                delegate: Delegate(),
                reduceMotion: true,
                hasRegistry: hasRegistry,
                hasOpenWindow: hasOpenWindow
            )
        )

        #expect(handle == nil)
    }

    // MARK: - NSPopover's conformance

    /// `isPopoverVisible` exists so no caller reads `NSPopover.isShown`
    /// directly, and the whole close state machine is written over its answer.
    /// A conformance that returned a constant would make every ordering in
    /// `AgentInboxPopoverCoordinatorTests` vacuous.
    @Test("the popover handle reports AppKit's own visibility")
    func popoverHandleTracksAppKitVisibility() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let popover = fixture.makeBarePopover()

        #expect(!popover.isPopoverVisible)
        popover.showPopover(from: fixture.anchor)
        #expect(popover.isPopoverVisible)
        #expect(popover.isShown)

        popover.closePopover()
        #expect(!popover.isPopoverVisible)
    }

    /// The Inbox hangs *below* the toolbar button, which is what
    /// `preferredEdge: .minY` means and the only part of the show call a
    /// caller can observe afterwards. The other edge would put a 540-point
    /// popover above a button that sits in the title bar.
    @Test("the popover is anchored below the button, not above it")
    func popoverHangsBelowItsAnchor() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let popover = fixture.makeBarePopover()

        popover.showPopover(from: fixture.anchor)
        defer { popover.closePopover() }

        let anchorFrame = fixture.anchorFrameInScreen()
        let popoverFrame = try #require(
            popover.contentViewController?.view.window?.frame
        )
        #expect(popoverFrame.maxY <= anchorFrame.minY)
        // Not a tautology about screen geometry: the anchor is placed with
        // room on both sides, so `.maxY` would have put the popover here.
        #expect(anchorFrame.maxY < fixture.windowFrameInScreen().maxY)
    }

    // MARK: - NSWindow's conformance

    /// `NSWindow`'s side of ``AgentInboxHosting``, as far as this host can see
    /// it — which is not all of it.
    ///
    /// **`makeKeyAndOrderFront` versus `orderFront` is not covered and cannot
    /// be covered here.** The unit-test host is a background application:
    /// `NSApp.isActive` is `false`, `makeKeyAndOrderFront` does not confer key
    /// status, and `NSApp.keyWindow` stays `nil` — measured from inside this
    /// host, not assumed. #1513 documents the same limitation for
    /// `AgentInboxWindowSources.keyWindow`. Mutating `focusHost()` to
    /// `orderFront(nil)`, which raises the host without focusing it so the
    /// Inbox opens over a window the user is not typing in, survives this
    /// suite. It is reported rather than papered over.
    ///
    /// `restoreHostFromMiniaturized()` is unreachable for the same reason:
    /// `miniaturize(nil)` does not reach the Dock in a background application,
    /// so `isMiniaturized` never becomes `true` and there is nothing to
    /// restore. What remains reachable is the ordering half below.
    @Test("focusing a host brings it back on screen")
    func focusingAHostBringsItBackOnScreen() {
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { host.orderOut(nil) }
        host.orderFront(nil)
        #expect(!host.isHostMiniaturized)

        host.orderOut(nil)
        #expect(!host.isVisible)

        host.focusHost()

        #expect(
            host.isVisible,
            "A host that is not on screen has nowhere to draw the popover"
        )
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let anchor = AgentInboxPopoverAnchorView(
            frame: NSRect(x: 150, y: 260, width: 40, height: 24)
        )
        private let registry: ProjectRegistry
        private let window: NSWindow
        private let suiteName: String
        private let defaults: UserDefaults

        init() throws {
            suiteName = "AgentInboxPopoverSystemObjectsTests.\(UUID())"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            registry = ProjectRegistry(
                defaults: defaults,
                agentTasks: AgentTaskRegistry(),
                // No `ps` polling: this suite is about AppKit objects.
                agentDetectionProcessRunner: { _, _, _, _ in
                    ProcessRunResult(
                        stdout: "",
                        stderr: "",
                        exitCode: 0,
                        timedOut: false
                    )
                },
                agentDetectionPollInterval: 3_600,
                agentDetectionInitialPollDelay: 3_600
            )
            registry.recentProjects = []
            // Centred, so the edge assertion is about `preferredEdge` and not
            // about which screen corner the window happened to land in.
            let screen = NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
            window = NSWindow(
                contentRect: NSRect(
                    x: screen.midX - 200,
                    y: screen.midY - 200,
                    width: 400,
                    height: 400
                ),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSView(
                frame: NSRect(x: 0, y: 0, width: 400, height: 400)
            )
            window.contentView?.addSubview(anchor)
            window.orderFront(nil)
        }

        func context(
            delegate: any NSPopoverDelegate,
            reduceMotion: Bool,
            hasRegistry: Bool = true,
            hasOpenWindow: Bool = true
        ) -> AgentInboxPopoverCoordinator.Context {
            AgentInboxPopoverCoordinator.Context(
                registry: hasRegistry ? registry : nil,
                openProjectWindow: hasOpenWindow ? { _ in } : nil,
                reduceMotion: reduceMotion,
                delegate: delegate,
                onDismiss: {}
            )
        }

        /// A popover with no SwiftUI content, so showing it exercises the
        /// conformance rather than the Inbox's own view body.
        func makeBarePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.contentSize = NSSize(width: 120, height: 90)
            let controller = NSViewController()
            controller.view = NSView(
                frame: NSRect(x: 0, y: 0, width: 120, height: 90)
            )
            popover.contentViewController = controller
            return popover
        }

        func anchorFrameInScreen() -> NSRect {
            window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        }

        func windowFrameInScreen() -> NSRect {
            window.frame
        }

        func cleanup() {
            anchor.removeFromSuperview()
            window.orderOut(nil)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private final class Delegate: NSObject, NSPopoverDelegate {}
}
