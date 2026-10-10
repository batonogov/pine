//
//  AgentInboxPopoverPresentationState.swift
//  Pine
//
//  Reconciliation rules for the Agent Inbox popover's three truths (#1491).
//

import Foundation

/// Reconciles the three independent truths about Agent Inbox popover
/// visibility so they converge on one visible state:
///
/// - the SwiftUI `isPresented` binding driven by the toolbar and Welcome
///   buttons;
/// - a router request, which can arrive before the anchor has a window;
/// - AppKit's own popover, which a transient dismissal — an outside click or
///   Escape — closes without telling SwiftUI.
///
/// Holding the rule in a value type is what makes duplicate-request,
/// detached-anchor, and outside-dismiss behavior verifiable without a window
/// server, and keeps the anchor coordinator free of ad-hoc boolean juggling.
struct AgentInboxPopoverPresentationState: Equatable {
    /// What the anchor must do to its AppKit popover.
    enum Effect: Equatable {
        case present
        case close
        /// Neither AppKit nor SwiftUI needs to change.
        case inert
    }

    struct Resolution: Equatable {
        let effect: Effect
        /// Non-nil when the SwiftUI binding has to be written to converge.
        let bindingIsPresented: Bool?

        static let unchanged = Resolution(
            effect: .inert,
            bindingIsPresented: nil
        )
    }

    /// A router request this anchor accepted but has not yet turned into a
    /// visible popover, because its window had not mounted yet or because the
    /// previous popover was still closing.
    private(set) var hasUnservedRouterRequest = false

    /// True from the moment a close of the popover begins until its close
    /// notification arrives.
    ///
    /// `NSPopover.performClose` animates unless Reduce Motion is on, so there
    /// is a real window in which the popover is neither usable nor gone. A
    /// second `show` inside it would orphan the one still leaving.
    ///
    /// Closes this anchor did not start count too. The popover is `.transient`,
    /// so Escape and a click outside are handled by AppKit alone; the anchor
    /// learns about them from `popoverWillClose`, and without that the whole
    /// animation would run with this flag down.
    private(set) var isClosing = false

    /// A request delivered by `AgentInboxPopoverRouter`.
    ///
    /// A repeated request while the popover is already shown is absorbed: a
    /// second `show` would orphan the first popover's hosting controller and
    /// leave an Inbox nobody can dismiss. Absorbed means *served*, so no
    /// unserved marker is left behind — leaving one would make the next
    /// SwiftUI update pass override a binding the user just lowered, and the
    /// toolbar button would refuse to close the Inbox it opened.
    mutating func routerRequestedPresentation(
        bindingIsPresented: Bool,
        isPopoverShown: Bool
    ) -> Resolution {
        hasUnservedRouterRequest = !isPopoverShown || isClosing
        return Resolution(
            effect: isPopoverShown || isClosing ? .inert : .present,
            // The binding lags the router, so converge it here; the toolbar
            // button's own highlight reads from it.
            bindingIsPresented: bindingIsPresented ? nil : true
        )
    }

    /// The toolbar button was clicked (#1665).
    ///
    /// The button must not toggle the binding blindly: while a transient
    /// dismissal's close animation is still running, the binding still reads
    /// `true`, so `toggle()` would write `false` and the reopen the user
    /// asked for is swallowed. Resolving the click against the authoritative
    /// popover state instead: on screen or on its way out means *close*;
    /// anything else means *present*.
    ///
    /// `dismissedBySameGesture` covers the Reduce Motion case: with the
    /// close animation off, AppKit's transient dismissal retires the whole
    /// popover synchronously inside the mouseDown of the very click on the
    /// button, so by action time the state reads "closed, settled" — and a
    /// plain state read would reopen the Inbox the user just clicked away.
    /// The coordinator sets the flag only when the dismissal's own mouse
    /// event landed on the button, so a fast reopen after an *outside-click*
    /// dismissal still presents.
    ///
    /// The present half is deliberately the router request's: it leaves the
    /// unserved marker behind, so a present that cannot complete right away —
    /// the anchor has not mounted yet on a cold launch (#1665's flaky
    /// help-button probe hit this) — is retried by the next update pass or
    /// anchor reattachment instead of vanishing.
    mutating func toolbarButtonToggled(
        bindingIsPresented: Bool,
        isPopoverShown: Bool,
        dismissedBySameGesture: Bool
    ) -> Resolution {
        guard !isPopoverShown, !isClosing, !dismissedBySameGesture else {
            return Resolution(
                effect: .close,
                bindingIsPresented: bindingIsPresented ? false : nil
            )
        }
        hasUnservedRouterRequest = true
        return Resolution(
            effect: .present,
            bindingIsPresented: bindingIsPresented ? nil : true
        )
    }

    /// A SwiftUI update pass. This is the only entry point that may close the
    /// popover on its own, because it is the only one that observes the
    /// binding turning false.
    func viewDidUpdate(
        bindingIsPresented: Bool,
        isPopoverShown: Bool
    ) -> Resolution {
        guard bindingIsPresented || hasUnservedRouterRequest else {
            return Resolution(effect: .close, bindingIsPresented: nil)
        }
        return Resolution(
            effect: isPopoverShown || isClosing ? .inert : .present,
            bindingIsPresented:
                hasUnservedRouterRequest && !bindingIsPresented ? true : nil
        )
    }

    /// The anchor moved into — or between — windows.
    ///
    /// Deliberately never writes the binding: this runs inside AppKit's
    /// `viewDidMoveToWindow`, and SwiftUI state written there would re-enter
    /// the live view update.
    func anchorWindowDidChange(
        bindingIsPresented: Bool,
        isPopoverShown: Bool
    ) -> Resolution {
        guard bindingIsPresented || hasUnservedRouterRequest else {
            return .unchanged
        }
        return Resolution(
            effect: isPopoverShown || isClosing ? .inert : .present,
            bindingIsPresented: nil
        )
    }

    /// The anchor created and showed a popover, serving the outstanding
    /// request.
    mutating func popoverWillShow() {
        hasUnservedRouterRequest = false
        isClosing = false
    }

    /// A close of the popover has begun — either because the anchor asked for
    /// one, or because AppKit dismissed the `.transient` popover itself.
    /// Nothing may be shown in this window until the close notification
    /// confirms it is gone.
    mutating func popoverWillClose() {
        isClosing = true
    }

    /// The Inbox content dismissed itself after a successful navigation or
    /// recovery.
    mutating func contentRequestedDismiss(
        bindingIsPresented: Bool
    ) -> Resolution {
        hasUnservedRouterRequest = false
        return Resolution(
            effect: .close,
            bindingIsPresented: bindingIsPresented ? false : nil
        )
    }

    /// AppKit finished closing the popover — an outside click, Escape, or a
    /// programmatic close.
    ///
    /// The window is free the moment this arrives, so the in-flight close is
    /// retired **here**, synchronously, and never together with the SwiftUI
    /// half below. `isClosing` is the flag that makes every entry point inert;
    /// leaving it armed for even one more hop means a request that lands in
    /// that gap is held against a close that is already over, with nothing
    /// left to release it.
    ///
    /// A request that arrived during a close this anchor announced survives
    /// it: it was deliberately held back rather than dropped, so the window
    /// can open the Inbox now. A request queued against an anchor that never
    /// showed anything is stale and goes with the close.
    mutating func popoverDidClose() {
        hasUnservedRouterRequest = isClosing && hasUnservedRouterRequest
        isClosing = false
    }

    /// What a finished close means for SwiftUI, derived at the moment that
    /// write actually reaches it.
    ///
    /// ``popoverDidClose()`` runs inside AppKit's own close notification, so
    /// the `@State` write it implies has to land a runloop turn later. A whole
    /// turn is enough for a newer request to open a new popover; replaying the
    /// verdict that was true when the old one vanished would lower the binding
    /// under a visible Inbox, and the next update pass would close it.
    func settledClose(
        bindingIsPresented: Bool,
        isPopoverShown: Bool
    ) -> Resolution {
        // Something newer already owns the popover and wrote its own binding.
        guard !isPopoverShown, !isClosing else { return .unchanged }
        guard hasUnservedRouterRequest else {
            return Resolution(
                effect: .inert,
                bindingIsPresented: bindingIsPresented ? false : nil
            )
        }
        return Resolution(
            effect: .present,
            bindingIsPresented: bindingIsPresented ? nil : true
        )
    }

    /// The anchor left the view hierarchy. A detached anchor must not keep a
    /// request that its replacement would then serve a second time.
    mutating func anchorDidDetach() -> Resolution {
        hasUnservedRouterRequest = false
        isClosing = false
        return Resolution(effect: .close, bindingIsPresented: nil)
    }
}
