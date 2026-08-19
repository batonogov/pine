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

    static let shared = AgentInboxPopoverRouter()

    private final class WeakPresenter {
        weak var value: AgentInboxPopoverPresenting?

        init(_ value: AgentInboxPopoverPresenting) {
            self.value = value
        }
    }

    private var presenters: [ObjectIdentifier: WeakPresenter] = [:]
    private weak var pendingHost: AnyObject?

    func register(
        _ presenter: AgentInboxPopoverPresenting,
        for host: AnyObject
    ) {
        removeReleasedPresenters()
        presenters[ObjectIdentifier(host)] = WeakPresenter(presenter)
        guard pendingHost === host else { return }
        pendingHost = nil
        presenter.presentAgentInbox()
    }

    func unregister(
        _ presenter: AgentInboxPopoverPresenting,
        from host: AnyObject
    ) {
        let key = ObjectIdentifier(host)
        guard presenters[key]?.value === presenter else { return }
        presenters.removeValue(forKey: key)
    }

    @discardableResult
    func requestPresentation(in host: AnyObject) -> RequestResult {
        removeReleasedPresenters()
        let key = ObjectIdentifier(host)
        guard let presenter = presenters[key]?.value else {
            pendingHost = host
            return .queued
        }
        pendingHost = nil
        presenter.presentAgentInbox()
        return .presented
    }

    private func removeReleasedPresenters() {
        presenters = presenters.filter { $0.value.value != nil }
    }
}

/// An inert AppKit view that occupies the SwiftUI button's bounds and gives
/// `NSPopover` a stable attachment point in both regular content and a
/// Liquid Glass toolbar on macOS 26.
@MainActor
private final class AgentInboxPopoverAnchorView: NSView {
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

    func makeCoordinator() -> Coordinator {
        Coordinator(router: .shared)
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
        coordinator: Coordinator
    ) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate,
            AgentInboxPopoverPresenting {
        private let router: AgentInboxPopoverRouter
        private weak var anchor: AgentInboxPopoverAnchorView?
        private weak var registeredWindow: NSWindow?
        private var isPresented: Binding<Bool>?
        private var registry: ProjectRegistry?
        private var openProjectWindow: ((URL) -> Void)?
        private var reduceMotion = false
        private var routerRequestedPresentation = false
        private var popover: NSPopover?

        init(router: AgentInboxPopoverRouter) {
            self.router = router
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
            updateRegistration(for: anchor.window)

            if isPresented.wrappedValue || routerRequestedPresentation {
                if routerRequestedPresentation && !isPresented.wrappedValue {
                    isPresented.wrappedValue = true
                }
                presentIfReady()
            } else {
                closePopover()
            }
        }

        func anchorWindowDidChange(_ anchor: AgentInboxPopoverAnchorView) {
            self.anchor = anchor
            updateRegistration(for: anchor.window)
            if isPresented?.wrappedValue == true
                || routerRequestedPresentation {
                presentIfReady()
            }
        }

        func presentAgentInbox() {
            routerRequestedPresentation = true
            if let isPresented, !isPresented.wrappedValue {
                isPresented.wrappedValue = true
            }
            presentIfReady()
        }

        func detach() {
            if let registeredWindow {
                router.unregister(self, from: registeredWindow)
            }
            registeredWindow = nil
            routerRequestedPresentation = false
            closePopover()
            anchor = nil
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
            guard popover?.isShown != true,
                  let anchor,
                  anchor.window != nil,
                  let registry,
                  let openProjectWindow else { return }

            let contentSize = NSSize(width: 520, height: 540)
            let rootView = AgentInboxView(
                registry: registry,
                onDismiss: { [weak self] in self?.dismiss() },
                openProjectWindow: openProjectWindow
            )
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.preferredContentSize = contentSize

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !reduceMotion
            popover.contentSize = contentSize
            popover.contentViewController = hostingController
            popover.delegate = self
            self.popover = popover
            routerRequestedPresentation = false
            popover.show(
                relativeTo: anchor.bounds,
                of: anchor,
                preferredEdge: .minY
            )
        }

        private func dismiss() {
            routerRequestedPresentation = false
            if isPresented?.wrappedValue == true {
                isPresented?.wrappedValue = false
            }
            closePopover()
        }

        private func closePopover() {
            guard let popover else { return }
            if popover.isShown {
                popover.performClose(nil)
            } else {
                self.popover = nil
            }
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            routerRequestedPresentation = false
            guard isPresented?.wrappedValue == true else { return }
            DispatchQueue.main.async { [weak self] in
                self?.isPresented?.wrappedValue = false
            }
        }
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
