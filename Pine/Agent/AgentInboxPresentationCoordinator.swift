//
//  AgentInboxPresentationCoordinator.swift
//  Pine
//
//  The application-level Agent Inbox presentation workflow (#1491).
//

import AppKit

/// One window that can own the Agent Inbox popover, reduced to the operations
/// the presentation workflow performs on it.
///
/// `NSWindow` conforms directly, so production routes through the very object
/// `AgentInboxPopoverRouter` keys presentation by. Tests substitute a
/// deterministic double, which is what makes restore-then-focus ordering
/// observable without a window server.
@MainActor
protocol AgentInboxHosting: AnyObject {
    var isHostMiniaturized: Bool { get }
    func restoreHostFromMiniaturized()
    func focusHost()
}

extension NSWindow: AgentInboxHosting {
    var isHostMiniaturized: Bool { isMiniaturized }

    func restoreHostFromMiniaturized() {
        deminiaturize(nil)
    }

    func focusHost() {
        makeKeyAndOrderFront(nil)
    }
}

/// One Agent Inbox host candidate paired with the window a winning decision
/// routes to.
///
/// The pair is produced in a single pass so the pure rule in
/// ``AgentInboxHostRouting`` and the window it selects can never disagree
/// about the window list they were derived from. The host is expressed as
/// ``AgentInboxHosting`` rather than `NSWindow` so the restore-then-focus
/// ordering the workflow performs on it is observable without a window
/// server; `NSWindow` conforms, so production still routes through the very
/// object `AgentInboxPopoverRouter` keys presentation by.
struct AgentInboxHostOption {
    let candidate: AgentInboxHostCandidate
    let host: any AgentInboxHosting
}

/// The window-system facts and effects the Agent Inbox presentation workflow
/// depends on. `AppDelegate` implements it over `NSApp` and `ProjectRegistry`.
@MainActor
protocol AgentInboxHostEnvironment: AnyObject {
    /// Every window that could own the popover, in `NSApp.windows` order.
    func agentInboxHostOptions() -> [AgentInboxHostOption]
    /// Brings the application forward before any window work.
    func activateApplicationForAgentInbox()
    /// Starts creating the Welcome window. Synchronous, because the request
    /// that needs it has already been accepted.
    func createAgentInboxWelcomeHost()
    /// Waits, bounded, for the created Welcome window's live visible owner.
    func awaitAgentInboxWelcomeHost() async -> (any AgentInboxHosting)?
    /// Breaks synchronous menu / notification / SwiftUI-button delivery before
    /// the popover is asked to present.
    func deliverAgentInboxRequest(
        _ operation: @escaping @MainActor () -> Void
    )
    /// Waits one polling interval before the workflow re-checks whether a
    /// queued request's host has mounted the anchor it is addressed to.
    func waitForAgentInboxAnchor() async
}

/// Runs one Agent Inbox request end to end: choose a host window, restore and
/// focus it, and hand exactly one presentation request to the popover router.
///
/// The workflow owns the policy — selection order, restore-before-present, and
/// the single-in-flight rule for a Welcome window that is still mounting. The
/// environment owns only the AppKit facts.
@MainActor
final class AgentInboxPresentationCoordinator {
    enum Outcome: Equatable {
        /// The request was handed to an already-existing host window.
        case routedToExistingHost
        /// No window could host the Inbox, so Welcome was created and this
        /// single request waits for its anchor to mount.
        case awaitingCreatedWelcomeHost
        /// The environment was released before a host could be chosen.
        case unavailable
    }

    /// How many times a request handed to an *existing* host re-checks whether
    /// that host has mounted its anchor before the workflow gives up on it.
    /// Paired with ``AgentInboxHostEnvironment/waitForAgentInboxAnchor()``'s
    /// interval this is the same order of wait `awaitVisibleWelcomeWindow()`
    /// already spends on a window that is being created.
    private static let queuedAnchorAttempts = 40

    private let router: AgentInboxPopoverRouter
    private weak var environment: (any AgentInboxHostEnvironment)?
    private var pendingWelcomeHostTask: Task<Void, Never>?
    private var welcomeHostGeneration = 0
    private var pendingAnchorTask: Task<Void, Never>?
    private var anchorGeneration = 0

    init(
        router: AgentInboxPopoverRouter = .shared,
        environment: any AgentInboxHostEnvironment
    ) {
        self.router = router
        self.environment = environment
    }

    /// True while a created-Welcome request is still waiting for its host.
    var isAwaitingCreatedWelcomeHost: Bool {
        pendingWelcomeHostTask != nil
    }

    @discardableResult
    func present() -> Outcome {
        present(retriesRemaining: 1)
    }

    /// - Parameter retriesRemaining: how many times a request whose chosen
    ///   window vanished, or produced no anchor, may re-run selection. Bounded
    ///   so a desktop that keeps losing its host cannot spin.
    @discardableResult
    private func present(retriesRemaining: Int) -> Outcome {
        guard let environment else { return .unavailable }
        environment.activateApplicationForAgentInbox()
        // A newer request supersedes the one before it — the Welcome window
        // still mounting, the existing host still being waited on, and any
        // request already sitting on the router's queue — so at most one is
        // ever in flight.
        pendingWelcomeHostTask?.cancel()
        pendingWelcomeHostTask = nil
        pendingAnchorTask?.cancel()
        pendingAnchorTask = nil
        router.cancelQueuedRequest()

        let options = environment.agentInboxHostOptions()
        let decision = AgentInboxHostRouting.decision(
            among: options.map(\.candidate)
        )
        if case .existingHost(let index) = decision,
           options.indices.contains(index) {
            let host = options[index].host
            prepare(host, in: environment)
            // The host is held weakly across the deferral: delivery happens a
            // whole runloop turn later, and keeping a closing `NSWindow` alive
            // for that turn is precisely the lifetime this workflow must not
            // extend. A host that does not answer is retried, never dropped.
            environment.deliverAgentInboxRequest { [weak self, weak host] in
                guard let self else { return }
                guard let host else {
                    // The chosen window died between selection and delivery.
                    // There is nothing left to wait for, so selection re-runs.
                    guard retriesRemaining > 0 else { return }
                    self.present(retriesRemaining: retriesRemaining - 1)
                    return
                }
                guard self.router.requestPresentation(in: host) == .queued
                else { return }
                self.awaitQueuedAnchor(on: host)
            }
            return .routedToExistingHost
        }

        return createWelcomeHost(in: environment)
    }

    /// Waits, bounded, for an existing host to mount the anchor a queued
    /// request is addressed to.
    ///
    /// `.queued` is a healthy answer for a window that is alive but has not run
    /// `updateNSView` yet — one that was just deminiaturized or raised — and
    /// the router hands the request over the moment that anchor appears.
    /// Re-running selection on the spot would activate the app and raise a
    /// window again unasked, and because `makeKeyAndOrderFront` is asynchronous
    /// the second pass can still read a pre-focus key window and land the Inbox
    /// somewhere else entirely. So the request stays where it is and the host
    /// is simply given time.
    ///
    /// Only the created-Welcome path may wait without end, because it is the
    /// one path that *knows* its anchor is still on its way. An existing host
    /// does not. The anchor lives in a `ToolbarItem`, registration is keyed by
    /// `anchor.window`, and AppKit takes that view out of its window whenever
    /// the toolbar is collapsed, whenever it overflows on a narrow window, and
    /// when full screen moves the toolbar container into
    /// `NSToolbarFullScreenWindow` — which carries no `CloseDelegate` and can
    /// never become a candidate at all. In each of those the anchor mounts
    /// *never*, and an unbounded wait costs twice over: ⇧⌘I, View > Agent
    /// Inbox and the Dock do nothing whatsoever, and the request stays armed on
    /// the shared router to be delivered whenever that window next mounts an
    /// anchor — the Inbox opening by itself minutes later, which is the exact
    /// hazard ``AgentInboxPopoverRouter/cancelQueuedRequest()`` documents.
    ///
    /// When the budget is spent the request is retired and Welcome is created
    /// instead: the same answer the workflow already gives when no window can
    /// host the Inbox (#1486), and a visible Inbox rather than a dead
    /// keystroke.
    private func awaitQueuedAnchor(on host: any AgentInboxHosting) {
        anchorGeneration &+= 1
        let generation = anchorGeneration
        pendingAnchorTask = Task { @MainActor [weak self, weak host] in
            defer { self?.finishAnchorTask(generation: generation) }
            for _ in 0..<Self.queuedAnchorAttempts {
                guard let self,
                      let environment = self.environment else { return }
                await environment.waitForAgentInboxAnchor()
                // Served, or retired by a newer request: either ending leaves
                // this wait nothing to do, and re-arming would be the fan-out
                // the single-in-flight rule exists to prevent.
                guard !Task.isCancelled,
                      self.anchorGeneration == generation,
                      let host,
                      self.router.hasQueuedRequest(for: host) else { return }
            }
            guard let self, let environment = self.environment else { return }
            // Retired *before* Welcome is created: a request still pointing at
            // the anchorless window would otherwise be delivered there the next
            // time it does mount one, on top of the Inbox this fallback opens.
            self.router.cancelQueuedRequest()
            self.createWelcomeHost(in: environment)
        }
    }

    /// The answer when no existing window can host the Inbox: create Welcome
    /// first, so the Inbox still has a stable, discoverable anchor (#1486), and
    /// hold this one request until that window mounts it.
    @discardableResult
    private func createWelcomeHost(
        in environment: any AgentInboxHostEnvironment
    ) -> Outcome {
        environment.createAgentInboxWelcomeHost()
        welcomeHostGeneration &+= 1
        let generation = welcomeHostGeneration
        pendingWelcomeHostTask = Task { @MainActor [weak self] in
            defer { self?.finishWelcomeHostTask(generation: generation) }
            guard let self, let environment = self.environment else { return }
            let host = await environment.awaitAgentInboxWelcomeHost()
            guard !Task.isCancelled, let host else { return }
            self.prepare(host, in: environment)
            // One more turn so the freshly raised Welcome window's SwiftUI
            // anchor can mount before the request reaches the router.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self.router.requestPresentation(in: host)
        }
        return .awaitingCreatedWelcomeHost
    }

    /// Clears the anchor wait's marker only for the wait that still owns it.
    private func finishAnchorTask(generation: Int) {
        guard anchorGeneration == generation else { return }
        pendingAnchorTask = nil
    }

    /// Clears the in-flight marker only for the task that still owns it, so a
    /// superseded task cannot erase its successor's pending request.
    private func finishWelcomeHostTask(generation: Int) {
        guard welcomeHostGeneration == generation else { return }
        pendingWelcomeHostTask = nil
    }

    /// Restores a miniaturized host before raising it: an `NSPopover` shown
    /// relative to an anchor inside a miniaturized window has nowhere to draw.
    ///
    /// The restore branch is a protocol guarantee, not a reachable production
    /// path today. `AppDelegate` projects project-window eligibility through
    /// `NSWindow.isVisible`, which reads `false` while a window is in the
    /// Dock, so a miniaturized *project* window is never selected: the request
    /// silently falls through to Welcome instead of returning the user to the
    /// project they minimized. A minimized *Welcome* window is restored today,
    /// but by `ensureWelcomeVisible()` on the create path rather than here.
    /// #1491's "minimized hosts are restored before presentation" is therefore
    /// unmet for project windows, and no test here claims otherwise; widening
    /// eligibility changes where ⇧⌘I lands and belongs in its own change (#1507).
    private func prepare(
        _ host: any AgentInboxHosting,
        in environment: any AgentInboxHostEnvironment
    ) {
        if host.isHostMiniaturized {
            host.restoreHostFromMiniaturized()
        }
        host.focusHost()
        environment.activateApplicationForAgentInbox()
    }
}
