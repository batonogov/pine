//
//  AgentInboxPopoverPresenter.swift
//  Pine
//
//  Window-targeted AppKit popover presentation for Agent Inbox (#1486).
//

import AppKit
import SwiftUI

/// Minimal presentation seam used by the router and its unit tests.
@MainActor
protocol AgentInboxPopoverPresenting: AnyObject {
    func presentAgentInbox()
}

/// Routes one application-level Inbox request to the anchor owned by the
/// selected host window. Requests made while a newly-created Welcome window
/// is still mounting are retained until its anchor registers.
@MainActor
final class AgentInboxPopoverRouter {
    enum RequestResult: Equatable {
        case presented
        case queued
    }

    /// How a request queued for a not-yet-mounted anchor reaches that anchor
    /// once it registers.
    typealias QueuedDelivery =
        @MainActor (@escaping @MainActor () -> Void) -> Void

    static let shared = AgentInboxPopoverRouter()

    /// Both sides are held weakly. `ObjectIdentifier` is unique only among
    /// live objects, so a released window's address can be handed to a new
    /// one; the host is re-checked by identity before its anchor is used.
    private final class Registration {
        weak var host: AnyObject?
        weak var presenter: AgentInboxPopoverPresenting?

        init(host: AnyObject, presenter: AgentInboxPopoverPresenting) {
            self.host = host
            self.presenter = presenter
        }
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private weak var pendingHost: AnyObject?
    /// Retires a hand-off that has already been scheduled.
    ///
    /// `register` turns a queued request into a closure on the next runloop
    /// turn and clears `pendingHost` in the same breath, so for a whole turn
    /// the request is in flight and no longer reachable through `pendingHost`.
    /// A workflow that retires the old request and starts a new one inside
    /// that turn would otherwise open the Inbox in two windows at once.
    private var deliveryGeneration = 0
    private let deliverQueuedRequest: QueuedDelivery

    /// - Parameter deliverQueuedRequest: escape hatch used by tests to make
    ///   the hand-off observable in one turn. Production always defers.
    init(
        deliverQueuedRequest: @escaping QueuedDelivery = { operation in
            NativeCommandDelivery.deferToNextMainRunLoop(operation)
        }
    ) {
        self.deliverQueuedRequest = deliverQueuedRequest
    }

    func register(
        _ presenter: AgentInboxPopoverPresenting,
        for host: AnyObject
    ) {
        removeReleasedRegistrations()
        registrations[ObjectIdentifier(host)] = Registration(
            host: host,
            presenter: presenter
        )
        guard pendingHost === host else { return }
        pendingHost = nil
        let generation = deliveryGeneration
        // Anchors register from `viewDidMoveToWindow` and `updateNSView`.
        // Presenting synchronously there writes SwiftUI state inside a live
        // update pass — the mutation AGENTS.md requires observers to defer —
        // and shows the popover before layout has given the anchor a non-zero
        // `bounds`, which would pin it to the window's origin.
        deliverQueuedRequest { [weak self, weak host] in
            guard let self,
                  let host,
                  self.deliveryGeneration == generation else { return }
            // The hand-off is bound to the *window*, not to the coordinator
            // that owned its anchor when it was scheduled. SwiftUI may rebuild
            // that coordinator inside the deferral, and a request captured
            // against the demounted one has nobody left to re-send it: this
            // resolves the window's current anchor instead, and re-queues the
            // request when there is none.
            self.requestPresentation(in: host)
        }
    }

    func unregister(
        _ presenter: AgentInboxPopoverPresenting,
        from host: AnyObject
    ) {
        let key = ObjectIdentifier(host)
        guard let registration = registrations[key],
              registration.host === host,
              registration.presenter === presenter else { return }
        registrations.removeValue(forKey: key)
    }

    /// Retires a request that is still waiting for its window's anchor.
    ///
    /// A queued request has no expiry of its own. Nothing else ever clears it,
    /// so a request left over for the singleton Welcome window stays armed on
    /// this shared object until that window next mounts an anchor — which can
    /// be minutes later and reads to the user as the Inbox opening by itself.
    /// The presentation workflow retires the previous request before starting
    /// a new one, which is what keeps exactly one in flight.
    func cancelQueuedRequest() {
        pendingHost = nil
        // A request that `register` already scheduled is past `pendingHost`.
        // Retiring only the queue would let it land a turn later, in a second
        // window, on behalf of a request the caller has just superseded.
        deliveryGeneration &+= 1
    }

    /// True while a request addressed to `host` is still waiting for that
    /// host's anchor to register.
    ///
    /// A queued request has no expiry of its own, so the presentation workflow
    /// polls this to bound how long it waits for a host whose anchor may never
    /// mount at all. `false` covers both endings that retire a wait: the anchor
    /// registered and the hand-off is under way, or a newer request superseded
    /// this one.
    func hasQueuedRequest(for host: AnyObject) -> Bool {
        pendingHost === host
    }

    @discardableResult
    func requestPresentation(in host: AnyObject) -> RequestResult {
        removeReleasedRegistrations()
        // A newer request supersedes any hand-off still in flight for the one
        // before it, whichever window that one was addressed to.
        deliveryGeneration &+= 1
        let key = ObjectIdentifier(host)
        guard let registration = registrations[key],
              registration.host === host,
              let presenter = registration.presenter else {
            pendingHost = host
            return .queued
        }
        pendingHost = nil
        presenter.presentAgentInbox()
        return .presented
    }

    private func removeReleasedRegistrations() {
        registrations = registrations.filter {
            $0.value.host != nil && $0.value.presenter != nil
        }
    }
}

/// An inert AppKit view that occupies the SwiftUI button's bounds and gives
/// `NSPopover` a stable attachment point in both regular content and a
/// Liquid Glass toolbar on macOS 26.
@MainActor
final class AgentInboxPopoverAnchorView: NSView {
    var onWindowChange: ((AgentInboxPopoverAnchorView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(self)
    }
}

@MainActor
private struct AgentInboxPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let registry: ProjectRegistry
    let explicitOpenProjectWindow: ((URL) -> Void)?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> AgentInboxPopoverCoordinator {
        AgentInboxPopoverCoordinator(router: .shared)
    }

    func makeNSView(context: Context) -> AgentInboxPopoverAnchorView {
        let view = AgentInboxPopoverAnchorView(frame: .zero)
        view.setAccessibilityElement(false)
        view.onWindowChange = { [weak coordinator = context.coordinator] anchor in
            coordinator?.anchorWindowDidChange(anchor)
        }
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(
        _ nsView: AgentInboxPopoverAnchorView,
        context: Context
    ) {
        let environmentOpenWindow = openWindow
        context.coordinator.update(
            anchor: nsView,
            isPresented: $isPresented,
            registry: registry,
            openProjectWindow: explicitOpenProjectWindow ?? { url in
                environmentOpenWindow(value: url)
            },
            reduceMotion: reduceMotion
        )
    }

    static func dismantleNSView(
        _ nsView: AgentInboxPopoverAnchorView,
        coordinator: AgentInboxPopoverCoordinator
    ) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }
}

private struct AgentInboxPopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let registry: ProjectRegistry
    let openProjectWindow: ((URL) -> Void)?

    func body(content: Content) -> some View {
        content.background {
            AgentInboxPopoverAnchor(
                isPresented: $isPresented,
                registry: registry,
                explicitOpenProjectWindow: openProjectWindow
            )
        }
    }
}

extension View {
    func agentInboxPopover(
        isPresented: Binding<Bool>,
        registry: ProjectRegistry,
        openProjectWindow: ((URL) -> Void)? = nil
    ) -> some View {
        modifier(AgentInboxPopoverModifier(
            isPresented: isPresented,
            registry: registry,
            openProjectWindow: openProjectWindow
        ))
    }
}
