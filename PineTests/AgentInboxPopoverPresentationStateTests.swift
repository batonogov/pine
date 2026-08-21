//
//  AgentInboxPopoverPresentationStateTests.swift
//  PineTests
//
//  Reconciliation of the Agent Inbox popover's binding, router request, and
//  AppKit visibility (#1491).
//

import Testing

@testable import Pine

@Suite("Agent Inbox popover presentation state")
struct AgentInboxPopoverPresentationStateTests {
    private typealias State = AgentInboxPopoverPresentationState

    // MARK: - Router requests

    @Test("a request on a hidden popover presents and raises the binding")
    func requestPresentsAndRaisesBinding() {
        var state = State()

        let resolution = state.routerRequestedPresentation(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        #expect(resolution.effect == .present)
        #expect(resolution.bindingIsPresented == true)
        #expect(state.hasUnservedRouterRequest)
    }

    @Test("a request does not rewrite a binding that is already true")
    func requestLeavesRaisedBindingAlone() {
        var state = State()

        let resolution = state.routerRequestedPresentation(
            bindingIsPresented: true,
            isPopoverShown: false
        )

        #expect(resolution.effect == .present)
        #expect(resolution.bindingIsPresented == nil)
    }

    @Test("a request while the popover is shown never presents again")
    func requestWhileShownIsAbsorbed() {
        var state = State()
        state.popoverWillShow()

        let resolution = state.routerRequestedPresentation(
            bindingIsPresented: true,
            isPopoverShown: true
        )

        // A second `show` would orphan the first popover's hosting
        // controller and leave an Inbox nobody can dismiss.
        #expect(resolution.effect == .inert)
        #expect(resolution.bindingIsPresented == nil)
        // Absorbed means served. An unserved marker left here outranks the
        // binding on the next update pass, so the toolbar button that opened
        // the Inbox could no longer close it.
        #expect(!state.hasUnservedRouterRequest)
        #expect(
            state.viewDidUpdate(
                bindingIsPresented: false,
                isPopoverShown: true
            ).effect == .close
        )
    }

    @Test("the toolbar button still closes an Inbox that absorbed a request")
    func absorbedRequestDoesNotBlockTheToolbarToggle() {
        var state = State()
        var binding = true
        state.popoverWillShow()

        // The Inbox is open and the user presses the shortcut again; the
        // request is absorbed. Then they click the toolbar button to close.
        _ = state.routerRequestedPresentation(
            bindingIsPresented: binding,
            isPopoverShown: true
        )
        binding.toggle()
        let update = state.viewDidUpdate(
            bindingIsPresented: binding,
            isPopoverShown: true
        )

        #expect(update.effect == .close)
        #expect(update.bindingIsPresented == nil)
    }

    @Test("a burst of requests while shown produces no extra popover")
    func repeatedRequestsWhileShownProduceNoPresent() {
        var state = State()
        state.popoverWillShow()

        let effects = (0..<25).map { index in
            state.routerRequestedPresentation(
                bindingIsPresented: index.isMultiple(of: 2),
                isPopoverShown: true
            ).effect
        }

        #expect(effects.allSatisfy { $0 == .inert })
    }

    @Test("a request while shown still converges a lagging binding")
    func requestWhileShownConvergesBinding() {
        var state = State()
        state.popoverWillShow()

        let resolution = state.routerRequestedPresentation(
            bindingIsPresented: false,
            isPopoverShown: true
        )

        #expect(resolution.effect == .inert)
        #expect(resolution.bindingIsPresented == true)
    }

    // MARK: - SwiftUI update passes

    @Test("a lowered binding with nothing pending closes the popover")
    func loweredBindingCloses() {
        let state = State()

        let resolution = state.viewDidUpdate(
            bindingIsPresented: false,
            isPopoverShown: true
        )

        #expect(resolution.effect == .close)
        #expect(resolution.bindingIsPresented == nil)
    }

    @Test("an update serves a request that arrived before the anchor")
    func updateServesQueuedRequest() {
        var state = State()
        // The anchor had no window yet, so the request could not be shown.
        _ = state.routerRequestedPresentation(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        let resolution = state.viewDidUpdate(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        #expect(resolution.effect == .present)
        #expect(resolution.bindingIsPresented == true)
    }

    @Test("an update on an already shown popover changes nothing")
    func updateOnShownPopoverIsInert() {
        let state = State()

        let resolution = state.viewDidUpdate(
            bindingIsPresented: true,
            isPopoverShown: true
        )

        #expect(resolution == State.Resolution(
            effect: .inert,
            bindingIsPresented: nil
        ))
    }

    // MARK: - Anchor window changes

    @Test("an anchor window change never writes SwiftUI state")
    func anchorWindowChangeNeverWritesBinding() {
        var state = State()
        _ = state.routerRequestedPresentation(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        let resolution = state.anchorWindowDidChange(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        // This runs inside AppKit's viewDidMoveToWindow; writing @State there
        // re-enters the live SwiftUI update.
        #expect(resolution.effect == .present)
        #expect(resolution.bindingIsPresented == nil)
    }

    @Test("an idle anchor window change never closes a popover")
    func idleAnchorWindowChangeIsUnchanged() {
        let state = State()

        let resolution = state.anchorWindowDidChange(
            bindingIsPresented: false,
            isPopoverShown: true
        )

        #expect(resolution == .unchanged)
    }

    // MARK: - Serving and closing

    @Test("showing the popover consumes the outstanding request")
    func showingConsumesTheRequest() {
        var state = State()
        _ = state.routerRequestedPresentation(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        state.popoverWillShow()

        #expect(!state.hasUnservedRouterRequest)
        // With the request consumed, a lowered binding is authoritative again.
        #expect(
            state.viewDidUpdate(
                bindingIsPresented: false,
                isPopoverShown: true
            ).effect == .close
        )
    }

    @Test("a request during a close is held, then served by the close")
    func requestDuringCloseIsHeldAndThenServed() {
        var state = State()
        state.popoverWillShow()
        state.popoverWillClose()

        // `performClose` animates. AppKit may still answer `isShown` either
        // way during it, so both readings must behave identically.
        for isPopoverShown in [true, false] {
            let request = state.routerRequestedPresentation(
                bindingIsPresented: true,
                isPopoverShown: isPopoverShown
            )
            #expect(request.effect == .inert)
            #expect(state.hasUnservedRouterRequest)
        }

        state.popoverDidClose()
        // The close is retired the instant AppKit reports it, not with the
        // deferred SwiftUI write below.
        #expect(!state.isClosing)
        #expect(state.hasUnservedRouterRequest)

        let closed = state.settledClose(
            bindingIsPresented: true,
            isPopoverShown: false
        )

        // Held, not swallowed: ⇧⌘I during the close animation still opens.
        #expect(closed.effect == .present)
        #expect(closed.bindingIsPresented == nil)
    }

    @Test("a close with no request behind it never reopens the Inbox")
    func closeWithoutRequestStaysClosed() {
        var state = State()
        state.popoverWillShow()
        state.popoverWillClose()

        state.popoverDidClose()
        let closed = state.settledClose(
            bindingIsPresented: true,
            isPopoverShown: false
        )

        #expect(closed.effect == .inert)
        #expect(closed.bindingIsPresented == false)
        #expect(!state.isClosing)
    }

    @Test("a request during a close raises a binding that was left down")
    func requestDuringCloseConvergesLoweredBinding() {
        var state = State()
        state.popoverWillShow()
        state.popoverWillClose()
        _ = state.routerRequestedPresentation(
            bindingIsPresented: false,
            isPopoverShown: true
        )

        state.popoverDidClose()
        let closed = state.settledClose(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        #expect(closed.effect == .present)
        #expect(closed.bindingIsPresented == true)
    }

    @Test("no SwiftUI pass may open a popover that is still closing")
    func updatesDoNotRaceAClose() {
        var state = State()
        state.popoverWillShow()
        state.popoverWillClose()
        _ = state.routerRequestedPresentation(
            bindingIsPresented: true,
            isPopoverShown: false
        )

        // Both observers run freely while AppKit animates the close; neither
        // may create a second popover against the same anchor.
        #expect(
            state.viewDidUpdate(
                bindingIsPresented: true,
                isPopoverShown: false
            ).effect == .inert
        )
        #expect(
            state.anchorWindowDidChange(
                bindingIsPresented: true,
                isPopoverShown: false
            ).effect == .inert
        )
    }

    /// A defensive invariant of the value type only. The anchor cannot
    /// produce this order — it never shows a popover while one is closing —
    /// so this is not coverage of a stuck close. That failure is an anchor
    /// bug, not a rule bug, and lives in
    /// `AgentInboxPopoverCoordinatorTests`.
    @Test("showing a popover clears a close that never reported back")
    func showingClearsAStuckClose() {
        var state = State()
        state.popoverWillClose()
        state.popoverWillShow()

        #expect(!state.isClosing)
        #expect(
            state.routerRequestedPresentation(
                bindingIsPresented: true,
                isPopoverShown: false
            ).effect == .present
        )
    }

    @Test("a close that settles under a newer popover leaves it alone")
    func settledCloseUnderANewerPopoverIsUnchanged() {
        var state = State()
        state.popoverWillShow()
        state.popoverWillClose()
        state.popoverDidClose()

        // The SwiftUI half of that close is still a runloop turn away when a
        // new request opens a new popover.
        _ = state.routerRequestedPresentation(
            bindingIsPresented: true,
            isPopoverShown: false
        )
        state.popoverWillShow()

        // Replaying the old verdict here would lower the binding under a
        // visible Inbox, and the next update pass would close it: the popover
        // blinks open and shuts, and the keystroke reads as swallowed.
        #expect(
            state.settledClose(
                bindingIsPresented: true,
                isPopoverShown: true
            ) == .unchanged
        )
    }

    @Test("a close that settles during a newer close leaves it alone")
    func settledCloseDuringANewerCloseIsUnchanged() {
        var state = State()
        state.popoverWillShow()
        state.popoverWillClose()
        state.popoverDidClose()

        state.popoverWillShow()
        state.popoverWillClose()

        // The newer close owns the binding now; it will settle on its own.
        #expect(
            state.settledClose(
                bindingIsPresented: true,
                isPopoverShown: false
            ) == .unchanged
        )
    }

    @Test("a detached anchor is never left mid-close")
    func detachClearsTheClosingState() {
        var state = State()
        state.popoverWillShow()
        state.popoverWillClose()

        _ = state.anchorDidDetach()

        #expect(!state.isClosing)
        #expect(!state.hasUnservedRouterRequest)
    }

    @Test("an outside click or Escape lowers the SwiftUI binding")
    func appKitCloseLowersBinding() {
        var state = State()
        state.popoverWillShow()

        state.popoverDidClose()
        let resolution = state.settledClose(
            bindingIsPresented: true,
            isPopoverShown: false
        )

        #expect(resolution.effect == .inert)
        #expect(resolution.bindingIsPresented == false)
    }

    @Test("an AppKit close does not rewrite an already lowered binding")
    func appKitCloseLeavesLoweredBindingAlone() {
        var state = State()

        state.popoverDidClose()
        let resolution = state.settledClose(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        #expect(resolution == State.Resolution(
            effect: .inert,
            bindingIsPresented: nil
        ))
    }

    @Test("an AppKit close discards a request that never reached a popover")
    func appKitCloseDiscardsUnservedRequest() {
        var state = State()
        _ = state.routerRequestedPresentation(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        state.popoverDidClose()

        #expect(!state.hasUnservedRouterRequest)
        #expect(
            state.viewDidUpdate(
                bindingIsPresented: false,
                isPopoverShown: false
            ).effect == .close
        )
    }

    @Test("successful navigation or recovery closes and lowers the binding")
    func contentDismissClosesAndLowersBinding() {
        var state = State()
        state.popoverWillShow()

        let resolution = state.contentRequestedDismiss(
            bindingIsPresented: true
        )

        #expect(resolution.effect == .close)
        #expect(resolution.bindingIsPresented == false)
        #expect(!state.hasUnservedRouterRequest)
    }

    @Test("a content dismiss also drops a request queued behind it")
    func contentDismissDropsQueuedRequest() {
        var state = State()
        _ = state.routerRequestedPresentation(
            bindingIsPresented: true,
            isPopoverShown: false
        )

        _ = state.contentRequestedDismiss(bindingIsPresented: true)

        #expect(!state.hasUnservedRouterRequest)
    }

    // MARK: - Detaching

    @Test("a detached anchor closes and abandons its request")
    func detachClosesAndAbandonsRequest() {
        var state = State()
        _ = state.routerRequestedPresentation(
            bindingIsPresented: true,
            isPopoverShown: false
        )

        let resolution = state.anchorDidDetach()

        #expect(resolution.effect == .close)
        #expect(resolution.bindingIsPresented == nil)
        #expect(!state.hasUnservedRouterRequest)
    }

    @Test("a detached anchor cannot resurrect a stale request")
    func detachedAnchorDoesNotResurrectRequest() {
        var state = State()
        _ = state.routerRequestedPresentation(
            bindingIsPresented: false,
            isPopoverShown: false
        )
        _ = state.anchorDidDetach()

        // The window came back — with the binding still false, nothing may
        // reopen the Inbox on its own.
        let reattached = state.anchorWindowDidChange(
            bindingIsPresented: false,
            isPopoverShown: false
        )
        let update = state.viewDidUpdate(
            bindingIsPresented: false,
            isPopoverShown: false
        )

        #expect(reattached == .unchanged)
        #expect(update.effect == .close)
    }

    // MARK: - Sequences

    @Test("a full open, outside-dismiss, reopen cycle converges each time")
    func openDismissReopenCycleConverges() {
        var state = State()
        var binding = false
        var isShown = false

        for _ in 0..<5 {
            let request = state.routerRequestedPresentation(
                bindingIsPresented: binding,
                isPopoverShown: isShown
            )
            if let value = request.bindingIsPresented { binding = value }
            #expect(request.effect == .present)
            state.popoverWillShow()
            isShown = true

            // AppKit dismisses the transient popover behind SwiftUI's back.
            isShown = false
            state.popoverDidClose()
            let closed = state.settledClose(
                bindingIsPresented: binding,
                isPopoverShown: isShown
            )
            if let value = closed.bindingIsPresented { binding = value }

            #expect(!binding)
            #expect(!state.hasUnservedRouterRequest)
        }
    }

    @Test("a request that races an AppKit close still ends visible")
    func requestRacingCloseEndsVisible() {
        var state = State()
        state.popoverWillShow()

        // AppKit closes, and the menu command lands in the same runloop turn
        // before SwiftUI has processed the deferred binding write.
        state.popoverDidClose()
        let closed = state.settledClose(
            bindingIsPresented: true,
            isPopoverShown: false
        )
        let request = state.routerRequestedPresentation(
            bindingIsPresented: true,
            isPopoverShown: false
        )

        #expect(closed.bindingIsPresented == false)
        #expect(request.effect == .present)
        #expect(state.hasUnservedRouterRequest)
    }
}
