//
//  AgentInboxPopoverCoordinator.swift
//  Pine
//
//  The anchor-side glue between SwiftUI, the router, and one NSPopover
//  (#1491).
//

import AppKit
import SwiftUI

/// The single AppKit object an Inbox anchor owns, reduced to what the anchor
/// actually does with it.
///
/// Substituting it is what makes the close orderings verifiable. They are
/// runloop interleavings around an animated close — not window-server
/// behavior — and every one of them can leave the anchor in a state where the
/// window refuses to open the Inbox ever again.
@MainActor
protocol AgentInboxPopoverHandle: AnyObject {
    /// AppKit's own answer. `NSPopover.isShown` already reads `false` part way
    /// through a close animation, so no caller may read it as "gone".
    var isPopoverVisible: Bool { get }
    func showPopover(from anchor: NSView)
    func closePopover()
}

extension NSPopover: AgentInboxPopoverHandle {
    var isPopoverVisible: Bool { isShown }

    func showPopover(from anchor: NSView) {
        show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func closePopover() {
        performClose(nil)
    }
}

/// Reconciles one window's Inbox anchor: the SwiftUI binding, the router's
/// requests, and AppKit's own popover.
///
/// The rule itself lives in `AgentInboxPopoverPresentationState`; this type
/// owns only the wiring — when a resolution may touch SwiftUI, which AppKit
/// notification belongs to which popover, and when a verdict has to be
/// re-derived instead of replayed.
@MainActor
final class AgentInboxPopoverCoordinator: NSObject, NSPopoverDelegate,
        AgentInboxPopoverPresenting {
    /// Everything a popover needs that the anchor learns from SwiftUI.
    struct Context {
        let registry: ProjectRegistry?
        let openProjectWindow: ((URL) -> Void)?
        let reduceMotion: Bool
        let delegate: any NSPopoverDelegate
        let onDismiss: @MainActor () -> Void
    }

    /// Builds — but does not show — the popover for one presentation.
    /// Returning `nil` means the anchor is not ready and nothing is recorded.
    typealias PopoverFactory = @MainActor (
        AgentInboxPopoverAnchorView,
        Context
    ) -> (any AgentInboxPopoverHandle)?

    private typealias State = AgentInboxPopoverPresentationState

    private let router: AgentInboxPopoverRouter
    private let makePopover: PopoverFactory
    private weak var anchor: AgentInboxPopoverAnchorView?
    private weak var registeredWindow: NSWindow?
    private var isPresented: Binding<Bool>?
    private var registry: ProjectRegistry?
    private var openProjectWindow: ((URL) -> Void)?
    private var reduceMotion = false
    private var state = State()
    private var popover: (any AgentInboxPopoverHandle)?
    /// How many `.close` resolutions have landed on an invisible popover while
    /// this anchor still believes AppKit is animating that popover away.
    private var unreportedCloseCount = 0
    /// The last value this anchor wrote into the binding, held only until the
    /// next update pass makes SwiftUI's own value authoritative again.
    private var lastWrittenIsPresented: Bool?
    /// True from the moment a finished close is retired until the SwiftUI
    /// write that close implies has actually been delivered.
    ///
    /// ``retireClosedPopover()`` frees the window synchronously — it drops the
    /// popover and clears the in-flight close, which is what lets the next
    /// request through — but the `@State` write cannot be made inside AppKit's
    /// own notification and lands a runloop turn later. For that one turn the
    /// anchor holds no popover, no close, and a binding SwiftUI still reads as
    /// `true`. An update pass landing there resolves to `.present` and rebuilds
    /// the popover the user has just dismissed; ``settledClose`` then finds a
    /// visible popover, declines to write, and the Inbox is latched open with
    /// nothing left able to lower it. Escape and the outside click stop
    /// working in that window for good.
    ///
    /// Ranking the undelivered write above the stale snapshot for that one
    /// turn is what closes the gap. It is not the same thing as
    /// ``lastWrittenIsPresented``: that one remembers a write SwiftUI has
    /// already been given, this one a write still on its way.
    private var isCloseSettling = false

    /// How many may land before the anchor stops waiting for a close
    /// notification that is not coming.
    ///
    /// ``AgentInboxPopoverPresentationState/isClosing`` is retired by exactly
    /// one thing — `popoverDidClose` — and while it stands every entry point
    /// resolves to `.inert`. Holding the reference through the animation is
    /// deliberate: dropping it leaves that notification with no sender to
    /// match, which is the regression `closePopover()` below is written
    /// against. But it also means one notification AppKit never posts costs
    /// this window its Inbox for as long as it stays open, with nothing left
    /// able to release it — the toolbar button, ⇧⌘I, the View menu and the
    /// Dock all go quiet.
    ///
    /// No production path was found where AppKit skips the notification, so
    /// this bounds a latent single point of failure rather than fixing a
    /// reproduced one. That is why it is generous: a close that is genuinely
    /// still animating is measured in a handful of SwiftUI passes, not dozens.
    private static let unreportedCloseTolerance = 32

    private var isPopoverShown: Bool {
        popover?.isPopoverVisible == true
    }

    /// What the anchor believes SwiftUI's presentation state is right now.
    ///
    /// Its own last write outranks the binding until the next update pass.
    /// SwiftUI hands `updateNSView` a `Binding` over the snapshot taken for
    /// *that* pass; reading it back between passes answers from the snapshot,
    /// not from a write made since. Every deferred hop in this type reads this
    /// property a whole runloop turn after the pass that handed the binding
    /// over, so without the memory a hop can read back the value it just
    /// replaced — `settledClose` would see a binding that is still up, decide
    /// nothing needs writing, and let the next pass reopen the popover the user
    /// dismissed. Escape would read as opening the Inbox again.
    private var bindingIsPresented: Bool {
        // A close that has been retired but whose SwiftUI write has not landed
        // yet has already decided this; every snapshot until it arrives
        // predates it.
        if isCloseSettling { return false }
        return lastWrittenIsPresented ?? (isPresented?.wrappedValue == true)
    }

    init(
        router: AgentInboxPopoverRouter = .shared,
        makePopover: @escaping PopoverFactory = AgentInboxPopoverCoordinator
            .makeSystemPopover
    ) {
        self.router = router
        self.makePopover = makePopover
    }

    /// The production popover: a transient, Liquid-Glass-friendly `NSPopover`
    /// hosting `AgentInboxView`.
    static func makeSystemPopover(
        anchor: AgentInboxPopoverAnchorView,
        context: Context
    ) -> (any AgentInboxPopoverHandle)? {
        guard let registry = context.registry,
              let openProjectWindow = context.openProjectWindow else {
            return nil
        }
        let contentSize = NSSize(width: 520, height: 540)
        let rootView = AgentInboxView(
            registry: registry,
            onDismiss: context.onDismiss,
            openProjectWindow: openProjectWindow
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.preferredContentSize = contentSize

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !context.reduceMotion
        popover.contentSize = contentSize
        popover.contentViewController = hostingController
        popover.delegate = context.delegate
        return popover
    }

    func attach(to anchor: AgentInboxPopoverAnchorView) {
        self.anchor = anchor
        updateRegistration(for: anchor.window)
    }

    func update(
        anchor: AgentInboxPopoverAnchorView,
        isPresented: Binding<Bool>,
        registry: ProjectRegistry,
        openProjectWindow: @escaping (URL) -> Void,
        reduceMotion: Bool
    ) {
        self.anchor = anchor
        self.isPresented = isPresented
        self.registry = registry
        self.openProjectWindow = openProjectWindow
        self.reduceMotion = reduceMotion
        // SwiftUI has just handed over a fresh snapshot, so its value outranks
        // anything this anchor wrote against the previous one.
        lastWrittenIsPresented = nil
        updateRegistration(for: anchor.window)

        let resolution = state.viewDidUpdate(
            // `lastWrittenIsPresented` was just cleared, so this is SwiftUI's
            // own snapshot — except across the turn a retired close still owes
            // SwiftUI its write, where the snapshot is the value that close is
            // on its way to replace.
            bindingIsPresented: bindingIsPresented,
            isPopoverShown: isPopoverShown
        )
        // The AppKit half is safe here: it touches no SwiftUI state, and
        // delaying a close would leave the popover on screen for a whole turn
        // after the binding said it was gone.
        performEffect(resolution.effect)
        guard resolution.bindingIsPresented != nil else { return }
        // The SwiftUI half is not. `update` runs inside a live view update
        // pass, and writing `@State` there re-enters it — the mutation
        // AGENTS.md requires observers to defer.
        NativeCommandDelivery.deferToNextMainRunLoop { [weak self] in
            self?.writeSettledUpdate()
        }
    }

    /// The SwiftUI half of an update pass, one runloop turn later.
    ///
    /// The verdict is not carried across the hop: a turn is long enough for the
    /// user to close the Inbox by hand. But re-deriving it from scratch gets
    /// the *only* case that defers exactly backwards. `viewDidUpdate` returns a
    /// write in one situation — a router request outranking a lowered binding —
    /// and the `.present` that comes with it runs **synchronously**, before
    /// this hop. A show that succeeds consumes the outstanding request that was
    /// the whole premise of the write, so asking the rule again reads "binding
    /// down, nothing pending", answers `.close`, and writes nothing at all. The
    /// Inbox is then visible with `isPresented == false`, and the next pass
    /// closes it: it blinks open and shuts, and the ⇧⌘I that opened it reads as
    /// swallowed. The write survived only when the show *failed*.
    ///
    /// So the popover actually on screen is asked first, and only a hop that
    /// did not leave one behind falls back to the rule.
    private func writeSettledUpdate() {
        guard !isPopoverShown else {
            writeBinding(bindingIsPresented ? nil : true)
            return
        }
        writeBinding(state.viewDidUpdate(
            bindingIsPresented: bindingIsPresented,
            isPopoverShown: false
        ).bindingIsPresented)
    }

    /// The anchor moved into — or between — windows.
    ///
    /// This runs inside AppKit's `viewDidMoveToWindow`, which fires before
    /// layout: the anchor's `bounds` is still zero, and a popover shown
    /// relative to it hangs off the window's origin instead of the toolbar
    /// button. `AgentInboxPopoverRouter` defers its own hand-off for exactly
    /// that reason, and a show started here needs the same turn. The verdict is
    /// re-derived on arrival rather than replayed, because a turn is long
    /// enough for the anchor to move again or for the binding to come down.
    ///
    /// Only `.present` waits. A `.close` cannot arrive from this entry point —
    /// the rule returns `.unchanged` when nothing wants the Inbox — and holding
    /// one back would leave a popover attached to a window the anchor has
    /// already left.
    func anchorWindowDidChange(_ anchor: AgentInboxPopoverAnchorView) {
        self.anchor = anchor
        updateRegistration(for: anchor.window)
        let resolution = state.anchorWindowDidChange(
            bindingIsPresented: bindingIsPresented,
            isPopoverShown: isPopoverShown
        )
        guard resolution.effect == .present else {
            apply(resolution)
            return
        }
        NativeCommandDelivery.deferToNextMainRunLoop { [weak self] in
            guard let self else { return }
            self.apply(self.state.anchorWindowDidChange(
                bindingIsPresented: self.bindingIsPresented,
                isPopoverShown: self.isPopoverShown
            ))
        }
    }

    func presentAgentInbox() {
        apply(state.routerRequestedPresentation(
            bindingIsPresented: bindingIsPresented,
            isPopoverShown: isPopoverShown
        ))
    }

    func detach() {
        if let registeredWindow {
            router.unregister(self, from: registeredWindow)
        }
        registeredWindow = nil
        apply(state.anchorDidDetach())
        anchor = nil
    }

    // MARK: - NSPopoverDelegate

    func popoverWillClose(_ notification: Notification) {
        popoverWillClose(sender: notification.object as AnyObject?)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverDidClose(sender: notification.object as AnyObject?)
    }

    /// A close has begun.
    ///
    /// The popover is `.transient`, so Escape and a click outside are handled
    /// by AppKit without asking the anchor first. Without this callback the
    /// whole close animation runs with the state machine believing nothing is
    /// closing, and a request that lands inside it builds a *second* popover
    /// on the same anchor while the first is still leaving — with only one
    /// strong reference between them.
    func popoverWillClose(sender: AnyObject?) {
        guard let popover, sender === popover else { return }
        state.popoverWillClose()
    }

    /// A close has finished.
    func popoverDidClose(sender: AnyObject?) {
        // A popover this anchor already replaced can still report its own
        // close. Acting on it would drop the reference to the live one,
        // leaving an Inbox that nothing can close.
        guard let current = popover, sender === current else { return }
        retireClosedPopover()
    }

    /// Lets go of a popover whose close is over.
    ///
    /// Retired synchronously, not with the SwiftUI write below: the in-flight
    /// close is what makes every entry point inert, and every extra hop it
    /// stands is a hop in which a request is held against a close that is
    /// already finished.
    private func retireClosedPopover() {
        popover = nil
        unreportedCloseCount = 0
        state.popoverDidClose()
        isCloseSettling = true
        // `@State` written inside AppKit's own notification re-enters the live
        // view update, so the SwiftUI half lands a turn later — and is derived
        // there, because by then a newer request may have opened a new popover
        // that this verdict would lower the binding on.
        NativeCommandDelivery.deferToNextMainRunLoop { [weak self] in
            guard let self else { return }
            self.isCloseSettling = false
            self.apply(self.state.settledClose(
                bindingIsPresented: self.bindingIsPresented,
                isPopoverShown: self.isPopoverShown
            ))
        }
    }

    // MARK: - Applying resolutions

    /// Writes the SwiftUI binding first, then performs the AppKit effect, so
    /// the popover is never created against a binding that still reads
    /// `false`.
    private func apply(_ resolution: State.Resolution) {
        writeBinding(resolution.bindingIsPresented)
        performEffect(resolution.effect)
    }

    private func writeBinding(_ value: Bool?) {
        guard let value else { return }
        lastWrittenIsPresented = value
        isPresented?.wrappedValue = value
    }

    private func performEffect(_ effect: State.Effect) {
        switch effect {
        case .present:
            presentIfReady()
        case .close:
            closePopover()
        case .inert:
            break
        }
    }

    private func updateRegistration(for window: NSWindow?) {
        guard registeredWindow !== window else { return }
        if let registeredWindow {
            router.unregister(self, from: registeredWindow)
        }
        registeredWindow = window
        if let window {
            router.register(self, for: window)
        }
    }

    private func presentIfReady() {
        guard !isPopoverShown,
              let anchor,
              anchor.window != nil,
              let handle = makePopover(anchor, Context(
                  registry: registry,
                  openProjectWindow: openProjectWindow,
                  reduceMotion: reduceMotion,
                  delegate: self,
                  onDismiss: { [weak self] in self?.dismiss() }
              )) else { return }
        popover = handle
        unreportedCloseCount = 0
        // Something newer is on screen, so the close no longer speaks for this
        // anchor: the binding the popover was built against is the live one.
        isCloseSettling = false
        state.popoverWillShow()
        handle.showPopover(from: anchor)
    }

    private func dismiss() {
        apply(state.contentRequestedDismiss(
            bindingIsPresented: bindingIsPresented
        ))
    }

    private func closePopover() {
        guard let popover else { return }
        guard popover.isPopoverVisible else {
            // A close this anchor already started is still animating: AppKit
            // reports `isShown == false` well before it posts the close
            // notification, and SwiftUI re-renders often enough that a second
            // `.close` inside that window is all but guaranteed. Dropping the
            // reference here would leave that notification with no sender to
            // match — and the in-flight close, which only that notification
            // clears, armed forever. Every later request then resolves to
            // `.inert`: the toolbar button, ⇧⌘I, the View menu and the Dock
            // all stop opening the Inbox in this window until it is closed.
            guard state.isClosing else {
                self.popover = nil
                unreportedCloseCount = 0
                return
            }
            // …but the wait cannot be unconditional. Holding the reference is
            // worth something only while a notification can still arrive to
            // match it, and holding the close costs this window the Inbox. Past
            // the tolerance the anchor concludes the notification is not coming
            // and retires the close itself, on exactly the terms the real one
            // would have.
            unreportedCloseCount += 1
            guard unreportedCloseCount >= Self.unreportedCloseTolerance else {
                return
            }
            retireClosedPopover()
            return
        }
        // `performClose` animates, so the window stays busy until the close
        // notification lands. The state machine holds any request that
        // arrives in between rather than racing it.
        state.popoverWillClose()
        popover.closePopover()
    }
}
