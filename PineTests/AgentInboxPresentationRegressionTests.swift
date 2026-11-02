import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Inbox presentation regressions", .serialized)
@MainActor
struct AgentInboxPresentationRegressionTests {
    @Test("a later close intent cancels an unserved reopen", arguments: [false, true])
    func laterCloseCancelsReopen(visibleDuringClose: Bool) {
        var state = AgentInboxPopoverPresentationState()
        state.popoverWillShow()
        state.popoverWillClose()
        _ = state.routerRequestedPresentation(bindingIsPresented: true, isPopoverShown: visibleDuringClose)
        _ = state.toggleButtonToggled(bindingIsPresented: true, isPopoverShown: visibleDuringClose,
                                      dismissedBySameGesture: false)
        state.popoverDidClose()
        #expect(!state.hasUnservedRouterRequest)
        #expect(state.settledClose(bindingIsPresented: false, isPopoverShown: false).effect == .inert)
    }

    @Test("an auxiliary anchor registers under its project owner")
    func auxiliaryRegistration() {
        let owner = makeWindow()
        let auxiliary = makeWindow()
        owner.addChildWindow(auxiliary, ordered: .above)
        defer {
            owner.removeChildWindow(auxiliary)
            auxiliary.orderOut(nil)
            owner.orderOut(nil)
        }
        let anchor = AgentInboxPopoverAnchorView()
        auxiliary.contentView?.addSubview(anchor)
        let router = AgentInboxPopoverRouter()
        let popover = Popover()
        let coordinator = AgentInboxPopoverCoordinator(router: router, makePopover: { _, _ in popover })
        coordinator.attach(to: anchor)
        defer { coordinator.detach() }

        #expect(router.requestPresentation(in: owner) == .presented)
        #expect(popover.isPopoverVisible)
    }

    @Test("a dismissal click choosing another window or control does not restore old focus",
          arguments: [false, true])
    func dismissalClickDoesNotRestore(sameWindow: Bool) async throws {
        let owner = makeWindow()
        let other = makeWindow()
        defer { owner.orderOut(nil); other.orderOut(nil) }
        let anchor = AgentInboxPopoverAnchorView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        owner.contentView?.addSubview(anchor)
        let focus = FocusHost()
        let popover = Popover()
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100),
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: (sameWindow ? owner : other).windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 0)
        let coordinator = AgentInboxPopoverCoordinator(
            router: AgentInboxPopoverRouter(), makePopover: { _, _ in popover },
            resolveFocusHost: { _ in focus }, isApplicationActive: { true }, currentEvent: { event }
        )
        coordinator.attach(to: anchor)
        defer { coordinator.detach() }

        coordinator.presentAgentInbox()

        coordinator.popoverWillClose(sender: popover)
        popover.isPopoverVisible = false
        coordinator.popoverDidClose(sender: popover)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(focus.returns == 0)
    }

    @Test("toolbar ownership composes with responder restoration", arguments: [false, true])
    func toolbarOwnerAndResponder(useParent: Bool) async throws {
        let owner = makeWindow()
        let auxiliary = makeWindow()
        let editor = FocusableView()
        owner.contentView?.addSubview(editor)
        #expect(owner.makeFirstResponder(editor))
        let anchor = AgentInboxPopoverAnchorView()
        let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("inbox"))
        item.view = anchor

        if useParent {
            owner.addChildWindow(auxiliary, ordered: .above)
        } else {
            // Keep the public ownership facts stable without AppKit laying the
            // item back into the normal titlebar during the deferred close.
            let toolbar = ItemToolbar(identifier: "inbox-regression")
            toolbar.testItems = [item]
            owner.toolbar = toolbar
        }
        auxiliary.contentView?.addSubview(anchor)
        defer {
            owner.removeChildWindow(auxiliary)
            auxiliary.orderOut(nil)
            owner.orderOut(nil)
        }
        let focus = FocusHost()
        let popover = Popover()
        let resolved = WindowChoices()
        let router = AgentInboxPopoverRouter()
        let coordinator = AgentInboxPopoverCoordinator(
            router: router, makePopover: { _, _ in popover },
            resolveFocusHost: { window in resolved.windows.append(window); return focus },
            isApplicationActive: { true }, windows: { [owner, auxiliary] }, keyWindow: { auxiliary }
        )
        coordinator.attach(to: anchor)
        defer { coordinator.detach() }
        #expect(router.requestPresentation(in: owner) == .presented)
        #expect(resolved.windows.first === owner)
        #expect(owner.captureFocusedResponder() === editor)
        #expect(!AgentInboxFocusRestoration.hasNewerFocusChoice(
            host: owner, responder: editor, keyWindow: auxiliary, windows: [owner, auxiliary]
        ))
        coordinator.popoverWillClose(sender: popover)
        popover.isPopoverVisible = false
        coordinator.popoverDidClose(sender: popover)
        await settle()
        #expect(focus.returns == 1)
        #expect(resolved.windows.last === owner)
    }

    enum FocusChoice { case otherWindow, changedResponder, unchangedResponder }

    @Test("deferred focus choices override restoration, but unchanged focus does not",
          arguments: [FocusChoice.otherWindow, .changedResponder, .unchangedResponder])
    func deferredFocusChoice(selection: FocusChoice) async {
        let owner = makeWindow()
        let other = makeWindow()
        defer { owner.orderOut(nil); other.orderOut(nil) }
        let editor = FocusableView()
        let control = FocusableView()
        owner.contentView?.addSubview(editor)
        owner.contentView?.addSubview(control)
        #expect(owner.makeFirstResponder(editor))
        let anchor = AgentInboxPopoverAnchorView()
        owner.contentView?.addSubview(anchor)
        let focus = FocusHost()
        focus.responder = editor
        let popover = Popover()
        let choice = WindowChoices()
        let coordinator = AgentInboxPopoverCoordinator(
            router: AgentInboxPopoverRouter(), makePopover: { _, _ in popover },
            resolveFocusHost: { _ in focus }, isApplicationActive: { true },
            keyWindow: { choice.windows.last }
        )
        coordinator.attach(to: anchor)
        defer { coordinator.detach() }
        coordinator.presentAgentInbox()
        coordinator.popoverWillClose(sender: popover)
        popover.isPopoverVisible = false
        coordinator.popoverDidClose(sender: popover)
        if selection == .changedResponder { #expect(owner.makeFirstResponder(control)) }
        choice.windows = [selection == .otherWindow ? other : owner]
        await settle()
        #expect(focus.returns == (selection == .unchangedResponder ? 1 : 0))
        if selection == .unchangedResponder { #expect(focus.returnedResponder === editor) }
    }

    @Test("only successful Inbox navigation closes Welcome")
    func welcomeClosesOnlyOnSuccess() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let anchor = AgentInboxPopoverAnchorView()
        window.contentView?.addSubview(anchor)
        let choices = WindowChoices()
        let popover = Popover()
        let content = ContentCallbacks()
        let coordinator = AgentInboxPopoverCoordinator(
            router: AgentInboxPopoverRouter(),
            makePopover: { _, context in content.dismiss = context.onDismiss; return popover },
            onSuccessfulNavigation: { choices.windows.append(window) }
        )
        coordinator.attach(to: anchor)
        defer { coordinator.detach() }
        coordinator.presentAgentInbox()
        coordinator.toggleButtonToggled()
        coordinator.popoverDidClose(sender: popover)
        await settle()
        #expect(choices.windows.isEmpty)
        coordinator.presentAgentInbox()
        let dismiss = try #require(content.dismiss)
        dismiss()
        #expect(choices.windows.count == 1)
    }

    @Test("an old deferred close cannot consume a newer closing presentation's focus")
    func oldCloseCannotConsumeNewFocus() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let anchor = AgentInboxPopoverAnchorView()
        window.contentView?.addSubview(anchor)
        let focus = FocusHost()
        let handles = Handles()
        let coordinator = AgentInboxPopoverCoordinator(
            router: AgentInboxPopoverRouter(), makePopover: { _, _ in
                let handle = Popover()
                handles.values.append(handle)
                return handle
            }, resolveFocusHost: { _ in focus }, isApplicationActive: { true }, keyWindow: { nil }
        )
        coordinator.attach(to: anchor)
        defer { coordinator.detach() }
        coordinator.presentAgentInbox()
        let first = try #require(handles.values.last)
        coordinator.popoverWillClose(sender: first)
        first.isPopoverVisible = false
        coordinator.popoverDidClose(sender: first)
        let newEditor = NSResponder()
        focus.responder = newEditor
        coordinator.presentAgentInbox()
        let second = try #require(handles.values.last)
        coordinator.popoverWillClose(sender: second)
        second.isPopoverVisible = false
        await settle()
        #expect(focus.returns == 0)
        coordinator.popoverDidClose(sender: second)
        await settle()
        #expect(focus.returns == 1)
        #expect(focus.returnedResponder === newEditor)
    }

    private final class Handles { var values: [Popover] = [] }

    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class ContentCallbacks { var dismiss: (@MainActor () -> Void)? }
    private final class WindowChoices { var windows: [NSWindow] = [] }
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
    private final class OwnerWindow: NSWindow {
        var testToolbar: NSToolbar?
        override var toolbar: NSToolbar? {
            get { testToolbar }
            set { testToolbar = newValue }
        }
    }
    private final class ItemToolbar: NSToolbar {
        var testItems: [NSToolbarItem] = []
        override var items: [NSToolbarItem] { testItems }
    }

    private func makeWindow() -> NSWindow {
        let window = OwnerWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private final class FocusHost: AgentInboxFocusHost {
        var canTakeFocus = true
        var responder = NSResponder()
        var returns = 0
        var returnedResponder: NSResponder?
        func captureFocusedResponder() -> NSResponder? { responder }
        func returnFocus(to responder: NSResponder?) {
            returns += 1
            returnedResponder = responder
        }
    }

    private final class Popover: AgentInboxPopoverHandle {
        var isPopoverVisible = false
        func showPopover(from anchor: NSView) { isPopoverVisible = true }
        func closePopover() { isPopoverVisible = false }
    }
}
