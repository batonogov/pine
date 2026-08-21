//
//  AgentInboxPopoverCoordinatorTests.swift
//  PineTests
//
//  The anchor-side glue: which AppKit notification belongs to which popover,
//  when a resolution may touch SwiftUI, and what happens across the runloop
//  turn a close takes (#1491).
//
//  `AgentInboxPopoverPresentationState` is verified as a value and
//  `AgentInboxPopoverRouter` in isolation. Neither can see the failures that
//  live only in the seam between them — an anchor that ends up holding a
//  close nothing can clear, or a second popover built on top of one that is
//  still leaving.
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Agent Inbox popover coordinator", .serialized)
@MainActor
struct AgentInboxPopoverCoordinatorTests {
    // MARK: - A close that never reports back

    /// The regression this suite exists for.
    ///
    /// `NSPopover.performClose` animates, and AppKit answers `isShown == false`
    /// well before it posts the close notification. SwiftUI re-renders
    /// constantly, and `viewDidUpdate` returns `.close` for every pass with the
    /// binding down — so a second `closePopover()` inside that animation is not
    /// a race, it is the normal case. If it drops the popover reference, the
    /// close notification has no sender to match, the in-flight close is never
    /// retired, and every entry point resolves to `.inert`: this window can
    /// never open the Inbox again — not the toolbar button, not ⇧⌘I, not the
    /// View menu, not the Dock — until it is closed.
    @Test(
        "a second close during the animation cannot lock the window out",
        arguments: [false, true]
    )
    func repeatedCloseDuringTheAnimationKeepsTheWindowUsable(
        appKitReportsVisibleWhileClosing: Bool
    ) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.reportsVisibleWhileClosing = appKitReportsVisibleWhileClosing
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let first = try #require(fixture.popovers.last)
        #expect(fixture.popovers.count == 1)
        #expect(fixture.isPresented)

        // The user closes the Inbox from the toolbar button.
        fixture.isPresented = false
        fixture.update()
        #expect(first.closeCount == 1)

        // AppKit is still animating; SwiftUI updates again in the meantime.
        fixture.update()
        fixture.update()

        // The close finally reports back, addressed to the popover that
        // started it.
        fixture.coordinator.popoverDidClose(sender: first)

        // ⇧⌘I must open the Inbox in this window again.
        fixture.coordinator.presentAgentInbox()

        #expect(fixture.popovers.count == 2)
        #expect(fixture.popovers.last?.showCount == 1)
        #expect(fixture.isPresented)
    }

    /// The other edge of the same rule.
    ///
    /// `isClosing` is retired by exactly one thing — the close notification —
    /// and while it stands every entry point is inert. Not dropping the
    /// reference mid-animation is right, but unbounded it leaves a single point
    /// of failure with no exit: a notification AppKit never posts costs this
    /// window its Inbox for as long as it stays open.
    ///
    /// No production path was found where AppKit skips that notification, so
    /// this covers a guard against a latent failure rather than a reproduced
    /// one. The tolerance is deliberately far above what a real animated close
    /// produces, which is what
    /// `repeatedCloseDuringTheAnimationKeepsTheWindowUsable` above pins from
    /// the other side.
    @Test("a close that never reports back cannot park the window forever")
    func anUnreportedCloseIsEventuallyRetired() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let first = try #require(fixture.popovers.last)

        // The user closes it and AppKit starts the animation — but the close
        // notification never arrives.
        fixture.isPresented = false
        fixture.update()
        #expect(first.closeCount == 1)

        // Every later SwiftUI pass resolves to `.close` on an invisible
        // popover, which is the only signal the anchor is given.
        for _ in 0..<64 { fixture.update() }

        fixture.coordinator.presentAgentInbox()

        #expect(
            fixture.popovers.count == 2,
            "A notification AppKit never sent must not cost the Inbox"
        )
        #expect(fixture.popovers.last?.showCount == 1)
        #expect(fixture.isPresented)
    }

    // MARK: - Closes AppKit starts on its own

    /// The popover is `.transient`: Escape and a click outside are handled by
    /// AppKit without asking. Without `popoverWillClose`, the entire close
    /// animation runs with the state machine believing nothing is closing, and
    /// a request that lands inside it builds a second popover on the same
    /// anchor — overwriting the only strong reference to the one still
    /// leaving.
    @Test("a request during an AppKit-started close never builds a second one")
    func requestDuringAnAppKitCloseIsHeld() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let first = try #require(fixture.popovers.last)

        // Escape: AppKit announces the close and already answers `isShown`
        // with `false` while the animation runs.
        fixture.coordinator.popoverWillClose(sender: first)
        first.isPopoverVisible = false

        fixture.coordinator.presentAgentInbox()
        #expect(
            fixture.popovers.count == 1,
            "A second popover would orphan the one still animating out"
        )

        // Held, not swallowed: the close serves it — one turn later, because
        // the request comes back through SwiftUI rather than out of AppKit's
        // own notification.
        fixture.coordinator.popoverDidClose(sender: first)
        await fixture.nextRunLoopTurn()
        #expect(fixture.popovers.count == 2)
        #expect(fixture.popovers.last?.showCount == 1)
        #expect(fixture.isPresented)
    }

    @Test("a close announced for another popover is ignored")
    func foreignWillCloseIsIgnored() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let first = try #require(fixture.popovers.last)
        // This popover is gone without ever reporting it.
        first.isPopoverVisible = false

        fixture.coordinator.popoverWillClose(sender: FakePopover())

        // A stranger's close must not park this anchor: the request opens.
        fixture.coordinator.presentAgentInbox()
        #expect(fixture.popovers.count == 2)
    }

    @Test("a replaced popover's close never drops the live one")
    func replacedPopoverCloseIsIgnored() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let live = try #require(fixture.popovers.last)

        fixture.coordinator.popoverDidClose(sender: FakePopover())

        // Acting on it would drop the reference to the live popover, leaving
        // an Inbox that nothing can close.
        fixture.isPresented = false
        fixture.update()
        #expect(live.closeCount == 1)
    }

    // MARK: - The runloop turn a close takes

    /// The SwiftUI half of a close lands a turn after AppKit's notification —
    /// it cannot be written inside it. That turn is long enough for a newer
    /// request to open a new popover, and replaying the verdict computed for
    /// the old one lowers the binding under a visible Inbox: it blinks open
    /// and shuts, and the keystroke that opened it reads as swallowed.
    @Test("a settled close never closes the popover that replaced it")
    func settledCloseLeavesANewerPopoverAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let first = try #require(fixture.popovers.last)

        // The user clicks outside; AppKit closes the popover.
        fixture.coordinator.popoverWillClose(sender: first)
        first.isPopoverVisible = false
        fixture.coordinator.popoverDidClose(sender: first)

        // ⇧⌘I in the same turn opens a new one.
        fixture.coordinator.presentAgentInbox()
        let second = try #require(fixture.popovers.last)
        #expect(fixture.popovers.count == 2)

        await fixture.nextRunLoopTurn()

        #expect(fixture.isPresented)
        #expect(second.closeCount == 0)
        #expect(second.isPopoverVisible)
    }

    @Test("a settled close with nothing behind it lowers the binding")
    func settledCloseLowersTheBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let first = try #require(fixture.popovers.last)
        #expect(fixture.isPresented)

        fixture.coordinator.popoverWillClose(sender: first)
        first.isPopoverVisible = false
        fixture.coordinator.popoverDidClose(sender: first)

        // Until SwiftUI is told, the toolbar button still reads as active and
        // the anchor would refuse the next request as a duplicate.
        await fixture.nextRunLoopTurn()
        #expect(!fixture.isPresented)
    }

    // MARK: - Moving between windows

    /// `viewDidMoveToWindow` fires before layout, so the anchor's `bounds` is
    /// still zero and a popover shown from it hangs off the window's origin
    /// rather than the toolbar button. The router defers its own hand-off for
    /// precisely this reason; a show the anchor starts for itself has to wait
    /// the same turn.
    @Test("a window change never shows the popover before layout")
    func anchorWindowChangeDefersItsPresentation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // The binding is up while the anchor has no window: the state a
        // toolbar item is in while AppKit is re-parenting its view.
        fixture.isPresented = true
        fixture.update()
        #expect(fixture.popovers.isEmpty)

        fixture.attachToWindow()
        fixture.coordinator.anchorWindowDidChange(fixture.anchor)
        #expect(
            fixture.popovers.isEmpty,
            "Shown inside viewDidMoveToWindow, before the anchor has bounds"
        )

        await fixture.nextRunLoopTurn()
        #expect(fixture.popovers.count == 1)
        #expect(fixture.popovers.last?.showCount == 1)
    }

    /// The other half of that turn: it is long enough for the reason to
    /// disappear, so the verdict is re-derived on arrival rather than replayed.
    @Test("a window change that stops being wanted presents nothing")
    func staleAnchorWindowChangeIsAbandoned() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.isPresented = true
        fixture.update()

        fixture.attachToWindow()
        fixture.coordinator.anchorWindowDidChange(fixture.anchor)
        // The user closes the Inbox inside that same turn, and SwiftUI's pass
        // for it lands before the deferred show does.
        fixture.isPresented = false
        fixture.update()

        await fixture.nextRunLoopTurn()
        #expect(fixture.popovers.isEmpty)
    }

    // MARK: - Writing SwiftUI state from an update pass

    /// `update` runs inside SwiftUI's live view update, so the `@State` write
    /// this resolution carries has to be deferred — the exact mutation
    /// AGENTS.md requires observers to move off the pass.
    @Test("an update pass never writes the binding inside itself")
    func updateDefersItsBindingWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // No window: the request is accepted but cannot be shown, so it stays
        // outstanding and outranks the binding on the next pass.
        fixture.update()
        fixture.coordinator.presentAgentInbox()
        #expect(fixture.popovers.isEmpty)

        fixture.isPresented = false
        fixture.update()
        #expect(
            !fixture.isPresented,
            "The binding was written inside the update pass"
        )

        await fixture.nextRunLoopTurn()
        #expect(fixture.isPresented)
    }

    /// The write that closes the Inbox the instant it opens.
    ///
    /// `viewDidUpdate` defers exactly one binding write, and it defers it in
    /// exactly one situation: an outstanding router request outranking a
    /// lowered binding. The `.present` that comes with it runs *synchronously*,
    /// and a show that succeeds calls `popoverWillShow()`, which clears the
    /// very request the write was derived from. A deferred block that asks the
    /// rule again therefore reads "binding down, nothing pending", answers
    /// `.close`, and writes nothing — so the lift is lost precisely when the
    /// show *worked*, and survives only when it failed.
    ///
    /// The window is left showing an Inbox with `isPresented == false`, and the
    /// next SwiftUI pass closes it: the Inbox blinks and vanishes, and the
    /// keystroke reads as swallowed.
    ///
    /// The anchor is mounted here on purpose. `updateDefersItsBindingWrite`
    /// below uses an unmounted one, which is the branch where the show fails —
    /// the only branch in which the naive re-derivation is correct.
    @Test("a request served by an update pass keeps the binding it raised")
    func servedUpdateRequestKeepsItsRaisedBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let first = try #require(fixture.popovers.last)

        // Escape, or a click outside: AppKit announces the close and already
        // answers `isShown` with `false` while the animation runs.
        fixture.coordinator.popoverWillClose(sender: first)
        first.isPopoverVisible = false

        // ⇧⌘I inside the animation. It is held, not served — so it is still
        // outstanding when the close finishes.
        fixture.coordinator.presentAgentInbox()
        #expect(fixture.popovers.count == 1)

        // The user lowers the binding from the toolbar button, and the close
        // reports back in the same turn.
        fixture.isPresented = false
        fixture.coordinator.popoverDidClose(sender: first)

        // SwiftUI's pass arrives in that same turn and serves the held request.
        fixture.update()
        let second = try #require(fixture.popovers.last)
        #expect(fixture.popovers.count == 2)
        #expect(second.isPopoverVisible)

        await fixture.nextRunLoopTurn()

        #expect(
            fixture.isPresented,
            "The Inbox is on screen; SwiftUI must not be told it is closed"
        )

        // What the lost write costs: the very next pass closes the popover the
        // user just asked for.
        fixture.update()
        #expect(second.closeCount == 0)
        #expect(fixture.popovers.count == 2)
    }

    // MARK: - The content's own dismissal

    /// #1491's "successful task navigation or recovery dismisses the popover".
    ///
    /// `AgentInboxView` is handed a closure and calls it; that the view calls
    /// what it was given is covered where the view is. What is only observable
    /// here is what that closure was *bound to* — and nothing else in this
    /// suite looks at it, so `onDismiss: {}` would leave the Inbox standing
    /// over the window the user was just navigated to with every test green.
    @Test("the content's own dismissal closes the popover it was built for")
    func contentDismissClosesThePopoverItWasBuiltFor() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.coordinator.presentAgentInbox()
        let popover = try #require(fixture.popovers.last)
        let context = try #require(fixture.contexts.last)
        #expect(fixture.isPresented)

        context.onDismiss()

        #expect(
            popover.closeCount == 1,
            "A successful route must take the Inbox down with it"
        )
        #expect(!fixture.isPresented)
    }

    // MARK: - The turn a retired close owes SwiftUI its write

    /// The regression #1514's UI coverage caught.
    ///
    /// `popoverDidClose` retires the close synchronously — dropping the
    /// popover and clearing `isClosing` is what frees the window for the next
    /// request — but the `@State` write it implies cannot be made inside
    /// AppKit's notification and lands a runloop turn later. For that one turn
    /// the anchor holds no popover, no in-flight close, and a binding SwiftUI
    /// still reads as `true`: `viewDidUpdate` answers `.present` and rebuilds
    /// the Inbox the user has just dismissed.
    ///
    /// What makes it worse than a blink is `settledClose`. It re-derives, sees
    /// a visible popover, and declines to write — so the binding is never
    /// lowered, the rebuilt popover is exactly what every later pass wants, and
    /// nothing is left that can take it down. The Inbox is latched open:
    /// Escape and the outside click go dead in that window.
    ///
    /// Replaying it unconditionally instead is not the fix — that is the
    /// regression ``settledCloseLeavesANewerPopoverAlone()`` pins.
    @Test("an update pass inside a settling close cannot relatch the Inbox")
    func updateInsideASettlingCloseCannotRelatchTheInbox() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        // The toolbar button raises the binding; the anchor opens the Inbox.
        fixture.isPresented = true
        fixture.update()
        let popover = try #require(fixture.popovers.last)

        // Escape. AppKit closes the popover behind SwiftUI's back and reports
        // both halves of the close before the binding has been touched.
        fixture.coordinator.popoverWillClose(sender: popover)
        popover.isPopoverVisible = false
        fixture.coordinator.popoverDidClose(sender: popover)

        // Anything at all re-renders the window inside that turn — a toolbar
        // item redisplayed as the popover gives key focus back is enough.
        fixture.update()
        #expect(
            fixture.popovers.count == 1,
            """
            A dismissed Inbox must not be rebuilt by the pass that still reads \
            the binding the close is on its way to lower
            """
        )

        await fixture.nextRunLoopTurn()
        #expect(
            !fixture.isPresented,
            "The close still owes SwiftUI its write once the turn is over"
        )

        // And it stays down: the next pass has nothing left to present.
        fixture.update()
        await fixture.nextRunLoopTurn()
        #expect(fixture.popovers.count == 1)
        #expect(!fixture.isPresented)
    }

    /// The guard above must not swallow a real request that lands in the same
    /// turn. ⇧⌘I, the View menu and the Dock all arrive through the router,
    /// and a turn is easily long enough to hold one.
    @Test("a router request inside a settling close still opens the Inbox")
    func routerRequestInsideASettlingCloseIsServed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        fixture.isPresented = true
        fixture.update()
        let first = try #require(fixture.popovers.last)

        fixture.coordinator.popoverWillClose(sender: first)
        first.isPopoverVisible = false
        fixture.coordinator.popoverDidClose(sender: first)

        fixture.coordinator.presentAgentInbox()
        let second = try #require(fixture.popovers.last)
        #expect(fixture.popovers.count == 2)
        #expect(fixture.isPresented)

        // A pass in the same turn must leave the newer popover alone: the
        // close stopped speaking for this anchor the moment it was replaced.
        fixture.update()
        #expect(
            second.closeCount == 0,
            "The settling close must not close the Inbox that replaced it"
        )

        await fixture.nextRunLoopTurn()
        #expect(fixture.isPresented)
        #expect(second.isPopoverVisible)
        #expect(fixture.popovers.count == 2)
    }

    /// The exact end-to-end shape #1514's UI test walks: open, dismiss by
    /// clicking outside, reopen from the toolbar, dismiss with Escape. The
    /// second dismissal is the one that latched.
    @Test("two dismissal cycles leave the window with no Inbox and no binding")
    func twoDismissalCyclesConverge() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.mount()

        for cycle in 0..<2 {
            fixture.isPresented = true
            fixture.update()
            let popover = try #require(fixture.popovers.last)
            #expect(fixture.popovers.count == cycle + 1)

            fixture.coordinator.popoverWillClose(sender: popover)
            popover.isPopoverVisible = false
            fixture.coordinator.popoverDidClose(sender: popover)
            // The window re-renders while the close still owes its write.
            fixture.update()
            await fixture.nextRunLoopTurn()

            #expect(
                !fixture.isPresented,
                "Cycle \(cycle) left the binding raised"
            )
            #expect(
                fixture.popovers.count == cycle + 1,
                "Cycle \(cycle) rebuilt the popover it had just dismissed"
            )
            fixture.update()
        }
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let router = AgentInboxPopoverRouter { operation in operation() }
        let registry: ProjectRegistry
        private(set) var popovers: [FakePopover] = []
        /// The `Context` each popover was built from.
        ///
        /// Kept because it is the only place the anchor's own callbacks are
        /// observable. A factory that drops the argument makes every wiring
        /// mistake inside it invisible: `onDismiss: {}` would leave the popover
        /// open over the window the user was just moved to, and every test
        /// here would still be green.
        private(set) var contexts: [AgentInboxPopoverCoordinator.Context] = []
        var reportsVisibleWhileClosing = false
        /// The value SwiftUI's `@State` itself holds.
        var isPresented = false
        /// What the binding captured on the last `update()` reads back.
        ///
        /// SwiftUI hands `updateNSView` a `Binding` over the snapshot taken for
        /// that pass, so a read between passes answers from the snapshot rather
        /// than from a write made since. A plain `Binding` over a stored `Bool`
        /// reads back whatever was last written and hides every decision that
        /// turns on the difference — and every deferred hop in the coordinator
        /// is exactly such a decision.
        private var snapshot = false
        let anchor = AgentInboxPopoverAnchorView(frame: .zero)
        private let window: NSWindow
        private let suiteName: String
        private let defaults: UserDefaults
        private var openedProjectWindows: [URL] = []
        lazy var coordinator = AgentInboxPopoverCoordinator(
            router: router,
            makePopover: { [weak self] _, context in
                guard let self else { return nil }
                let popover = FakePopover()
                popover.reportsVisibleWhileClosing =
                    self.reportsVisibleWhileClosing
                self.popovers.append(popover)
                self.contexts.append(context)
                return popover
            }
        )

        init() throws {
            suiteName = "AgentInboxPopoverCoordinatorTests.\(UUID())"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            registry = ProjectRegistry(
                defaults: defaults,
                agentTasks: AgentTaskRegistry(),
                // No `ps` polling: this suite is about popover lifecycle.
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
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSView(
                frame: window.contentRect(forFrameRect: window.frame)
            )
        }

        /// Puts the anchor in a window, which is what lets it present.
        func mount() {
            attachToWindow()
            update()
        }

        /// The AppKit half of mounting on its own, without the SwiftUI pass —
        /// the order `viewDidMoveToWindow` actually fires in.
        func attachToWindow() {
            window.contentView?.addSubview(anchor)
            coordinator.attach(to: anchor)
        }

        func update() {
            snapshot = isPresented
            coordinator.update(
                anchor: anchor,
                isPresented: Binding(
                    get: { [weak self] in self?.snapshot ?? false },
                    set: { [weak self] value in self?.isPresented = value }
                ),
                registry: registry,
                openProjectWindow: { [weak self] url in
                    self?.openedProjectWindows.append(url)
                },
                reduceMotion: true
            )
        }

        func nextRunLoopTurn() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        func cleanup() {
            coordinator.detach()
            anchor.removeFromSuperview()
            window.orderOut(nil)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// Stands in for `NSPopover`, including its most dangerous habit:
    /// answering `isShown` with `false` long before the close notification
    /// that retires it.
    @MainActor
    private final class FakePopover: AgentInboxPopoverHandle {
        var isPopoverVisible = false
        var reportsVisibleWhileClosing = false
        private(set) var showCount = 0
        private(set) var closeCount = 0

        func showPopover(from anchor: NSView) {
            showCount += 1
            isPopoverVisible = true
        }

        func closePopover() {
            closeCount += 1
            isPopoverVisible = reportsVisibleWhileClosing
        }
    }
}
