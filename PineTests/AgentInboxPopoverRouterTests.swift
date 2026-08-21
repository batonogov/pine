//
//  AgentInboxPopoverRouterTests.swift
//  PineTests
//
//  Window-identity and late-anchor coverage for Agent Inbox presentation.
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Inbox popover router", .serialized)
@MainActor
struct AgentInboxPopoverRouterTests {
    @Test("a registered anchor receives its window's request")
    func registeredAnchorPresents() {
        let router = AgentInboxPopoverRouter()
        let host = Host()
        let presenter = Presenter()

        router.register(presenter, for: host)

        #expect(router.requestPresentation(in: host) == .presented)
        #expect(presenter.presentationCount == 1)
    }

    @Test("a request waits for a newly mounted window anchor")
    func requestWaitsForAnchor() {
        let (router, deliveries) = makeRouter()
        let host = Host()
        let presenter = Presenter()

        #expect(router.requestPresentation(in: host) == .queued)
        #expect(presenter.presentationCount == 0)

        router.register(presenter, for: host)
        deliveries.flush()

        #expect(presenter.presentationCount == 1)
    }

    @Test("registering never presents inside the caller's own frame")
    func queuedRequestIsHandedOffOutOfBand() {
        let (router, deliveries) = makeRouter()
        let host = Host()
        let presenter = Presenter()

        #expect(router.requestPresentation(in: host) == .queued)
        router.register(presenter, for: host)

        // Anchors register from `viewDidMoveToWindow` and `updateNSView`.
        // Presenting there writes SwiftUI state inside a live update pass and
        // shows the popover before layout has sized the anchor.
        #expect(presenter.presentationCount == 0)
        #expect(deliveries.count == 1)

        deliveries.flush()
        #expect(presenter.presentationCount == 1)
    }

    @Test("the production router defers the hand-off by one runloop turn")
    func productionRouterDefersHandOff() async {
        // The injected deliverer above is only a lens. This asserts the real
        // default, so the deferral cannot be lost while the tests stay green.
        let router = AgentInboxPopoverRouter()
        let host = Host()
        let presenter = Presenter()

        #expect(router.requestPresentation(in: host) == .queued)
        router.register(presenter, for: host)
        #expect(presenter.presentationCount == 0)

        await nextMainRunLoopTurn()

        #expect(presenter.presentationCount == 1)
    }

    @Test("an anchor released during the deferral re-queues, never resurrects")
    func anchorReleasedDuringDeferralRequeuesTheRequest() {
        let (router, deliveries) = makeRouter()
        let host = Host()

        #expect(router.requestPresentation(in: host) == .queued)
        do {
            let doomed = Presenter()
            router.register(doomed, for: host)
        }

        // The anchor died in the turn between registering and delivery. The
        // router holds it weakly, so nothing is resurrected and nothing traps
        // — and because delivery re-resolves the window rather than replaying
        // a captured anchor, the user's request goes back on the queue for
        // whichever anchor this window mounts next.
        deliveries.flush()

        let replacement = Presenter()
        router.register(replacement, for: host)
        deliveries.flush()
        #expect(replacement.presentationCount == 1)
    }

    @Test("a request never leaks into another window")
    func requestTargetsExactWindow() {
        let (router, deliveries) = makeRouter()
        let requestedHost = Host()
        let otherHost = Host()
        let otherPresenter = Presenter()
        let requestedPresenter = Presenter()

        router.register(otherPresenter, for: otherHost)
        #expect(router.requestPresentation(in: requestedHost) == .queued)
        #expect(otherPresenter.presentationCount == 0)

        router.register(requestedPresenter, for: requestedHost)
        deliveries.flush()
        #expect(requestedPresenter.presentationCount == 1)
        #expect(otherPresenter.presentationCount == 0)
    }

    @Test("stale unregistration cannot remove a replacement anchor")
    func staleUnregistrationPreservesReplacement() {
        let router = AgentInboxPopoverRouter()
        let host = Host()
        let stalePresenter = Presenter()
        let replacementPresenter = Presenter()

        router.register(stalePresenter, for: host)
        router.register(replacementPresenter, for: host)
        router.unregister(stalePresenter, from: host)

        #expect(router.requestPresentation(in: host) == .presented)
        #expect(stalePresenter.presentationCount == 0)
        #expect(replacementPresenter.presentationCount == 1)
    }

    @Test("a stale unregistration from another host changes nothing")
    func unregistrationIsScopedToItsHost() {
        let router = AgentInboxPopoverRouter()
        let host = Host()
        let otherHost = Host()
        let presenter = Presenter()

        router.register(presenter, for: host)
        router.unregister(presenter, from: otherHost)

        #expect(router.requestPresentation(in: host) == .presented)
        #expect(presenter.presentationCount == 1)
    }

    @Test("an unregistered anchor stops receiving its window's requests")
    func unregisteredAnchorStopsReceivingRequests() {
        let router = AgentInboxPopoverRouter()
        let host = Host()
        let presenter = Presenter()

        router.register(presenter, for: host)
        router.unregister(presenter, from: host)

        #expect(router.requestPresentation(in: host) == .queued)
        #expect(presenter.presentationCount == 0)
    }

    @Test("a released anchor cannot serve a queued request")
    func releasedAnchorCannotServeQueuedRequest() {
        let (router, deliveries) = makeRouter()
        let host = Host()

        do {
            let doomedPresenter = Presenter()
            router.register(doomedPresenter, for: host)
        }

        // The window's SwiftUI anchor was torn down without unregistering.
        // Its slot must not answer for the window that outlived it.
        #expect(router.requestPresentation(in: host) == .queued)

        let replacement = Presenter()
        router.register(replacement, for: host)
        deliveries.flush()
        #expect(replacement.presentationCount == 1)
    }

    @Test("a queued request dies with the window it was queued for")
    func queuedRequestDiesWithItsHost() {
        let (router, deliveries) = makeRouter()

        do {
            let doomedHost = Host()
            #expect(router.requestPresentation(in: doomedHost) == .queued)
        }

        // A different window mounting later must not inherit the request.
        let survivingHost = Host()
        let presenter = Presenter()
        router.register(presenter, for: survivingHost)
        deliveries.flush()

        #expect(presenter.presentationCount == 0)
    }

    @Test("a queued request can be retired before its window ever mounts")
    func queuedRequestCanBeCancelled() {
        let (router, deliveries) = makeRouter()
        let host = Host()

        #expect(router.requestPresentation(in: host) == .queued)
        // Nothing else expires a queued request. Left armed on this shared
        // object it waits for the singleton Welcome window's next anchor,
        // which can be minutes later and reads as the Inbox opening by itself.
        router.cancelQueuedRequest()

        let presenter = Presenter()
        router.register(presenter, for: host)
        deliveries.flush()
        #expect(presenter.presentationCount == 0)
        // The window is still perfectly usable for a request made later.
        #expect(router.requestPresentation(in: host) == .presented)
        #expect(presenter.presentationCount == 1)
    }

    @Test("retiring a queued request is safe when nothing is queued")
    func cancellingWithNothingQueuedIsHarmless() {
        let (router, deliveries) = makeRouter()
        let host = Host()
        let presenter = Presenter()

        router.register(presenter, for: host)
        router.cancelQueuedRequest()
        router.cancelQueuedRequest()

        #expect(router.requestPresentation(in: host) == .presented)
        deliveries.flush()
        #expect(presenter.presentationCount == 1)
    }

    @Test("a stray teardown never cancels a window's queued request")
    func unregisteringAnUnknownAnchorKeepsTheQueuedRequest() {
        let (router, deliveries) = makeRouter()
        let host = Host()
        let strayPresenter = Presenter()

        #expect(router.requestPresentation(in: host) == .queued)
        // Nothing was ever registered for this window: this is exactly the
        // created-Welcome case the queue exists for, and a teardown from an
        // anchor that never owned it must not cancel the user's request.
        router.unregister(strayPresenter, from: host)

        let presenter = Presenter()
        router.register(presenter, for: host)
        deliveries.flush()
        #expect(presenter.presentationCount == 1)
    }

    @Test("unregistering one window leaves another window's request armed")
    func unregisteringIsScopedToItsOwnWindow() {
        let (router, deliveries) = makeRouter()
        let host = Host()
        let otherHost = Host()
        let otherPresenter = Presenter()

        router.register(otherPresenter, for: otherHost)
        #expect(router.requestPresentation(in: host) == .queued)
        router.unregister(otherPresenter, from: otherHost)

        let presenter = Presenter()
        router.register(presenter, for: host)
        deliveries.flush()
        #expect(presenter.presentationCount == 1)
    }

    @Test("a newer queued request supersedes the one before it")
    func newerQueuedRequestSupersedesTheOlder() {
        let (router, deliveries) = makeRouter()
        let firstHost = Host()
        let secondHost = Host()
        let firstPresenter = Presenter()
        let secondPresenter = Presenter()

        #expect(router.requestPresentation(in: firstHost) == .queued)
        #expect(router.requestPresentation(in: secondHost) == .queued)

        router.register(firstPresenter, for: firstHost)
        router.register(secondPresenter, for: secondHost)
        deliveries.flush()

        #expect(firstPresenter.presentationCount == 0)
        #expect(secondPresenter.presentationCount == 1)
    }

    @Test("a request reaches only its own window when both are registered")
    func registeredWindowsDoNotSharePresentations() {
        let router = AgentInboxPopoverRouter()
        let firstHost = Host()
        let secondHost = Host()
        let firstPresenter = Presenter()
        let secondPresenter = Presenter()

        router.register(firstPresenter, for: firstHost)
        router.register(secondPresenter, for: secondHost)

        #expect(router.requestPresentation(in: secondHost) == .presented)

        #expect(firstPresenter.presentationCount == 0)
        #expect(secondPresenter.presentationCount == 1)
    }

    @Test("a rebuilt anchor inherits the request exactly once, never twice")
    func queuedRequestIsDeliveredOnceToTheLiveAnchor() {
        let (router, deliveries) = makeRouter()
        let host = Host()
        let superseded = Presenter()

        #expect(router.requestPresentation(in: host) == .queued)
        router.register(superseded, for: host)

        // SwiftUI rebuilt the anchor's coordinator inside the deferral. The
        // superseded one is already detached — it owns no popover and would
        // drop the request on the floor — so delivery has to resolve the
        // window's *current* anchor. Delivering to both would open two
        // popovers on one anchor.
        let replacement = Presenter()
        router.register(replacement, for: host)
        deliveries.flush()

        #expect(superseded.presentationCount == 0)
        #expect(replacement.presentationCount == 1)
        #expect(deliveries.isEmpty)
    }

    @Test("retiring a request also retires the hand-off already scheduled")
    func cancellingRetiresAnInFlightHandOff() {
        let (router, deliveries) = makeRouter()
        let welcome = Host()
        let welcomeAnchor = Presenter()

        #expect(router.requestPresentation(in: welcome) == .queued)
        // The window mounts its anchor, so the request leaves the queue and
        // becomes a scheduled closure — unreachable through the queue alone
        // for a whole runloop turn.
        router.register(welcomeAnchor, for: welcome)
        router.cancelQueuedRequest()

        deliveries.flush()
        #expect(welcomeAnchor.presentationCount == 0)
    }

    @Test("a newer request retires the hand-off already scheduled for the old")
    func newerRequestRetiresAnInFlightHandOff() {
        let (router, deliveries) = makeRouter()
        let welcome = Host()
        let project = Host()
        let welcomeAnchor = Presenter()
        let projectAnchor = Presenter()
        router.register(projectAnchor, for: project)

        #expect(router.requestPresentation(in: welcome) == .queued)
        router.register(welcomeAnchor, for: welcome)
        // One ⇧⌘I, superseded inside the deferral by a second one that finds
        // a mounted project window. Without a delivery token the first lands a
        // turn later and the single request opens the Inbox in two windows.
        #expect(router.requestPresentation(in: project) == .presented)

        deliveries.flush()
        #expect(welcomeAnchor.presentationCount == 0)
        #expect(projectAnchor.presentationCount == 1)
    }

    @Test("every repeated request reaches the anchor exactly once")
    func repeatedRequestsAreForwardedOneForOne() {
        let router = AgentInboxPopoverRouter()
        let host = Host()
        let otherHost = Host()
        let presenter = Presenter()
        let otherPresenter = Presenter()

        router.register(presenter, for: host)
        router.register(otherPresenter, for: otherHost)

        for _ in 0..<5 {
            #expect(router.requestPresentation(in: host) == .presented)
        }

        // Dropping duplicates is the anchor's decision, not the router's;
        // leaking them into another window is never allowed.
        #expect(presenter.presentationCount == 5)
        #expect(otherPresenter.presentationCount == 0)
    }

    @Test("re-registering the same anchor keeps exactly one live slot")
    func repeatedRegistrationIsIdempotent() {
        let router = AgentInboxPopoverRouter()
        let host = Host()
        let presenter = Presenter()

        for _ in 0..<4 {
            router.register(presenter, for: host)
        }
        #expect(presenter.presentationCount == 0)

        router.unregister(presenter, from: host)
        #expect(router.requestPresentation(in: host) == .queued)
    }

    @Test("a superseded anchor cannot unregister its replacement's window")
    func supersededAnchorCannotUnregisterReplacement() {
        let router = AgentInboxPopoverRouter()
        let host = Host()
        let stalePresenter = Presenter()
        let replacementPresenter = Presenter()

        router.register(stalePresenter, for: host)
        router.register(replacementPresenter, for: host)
        for _ in 0..<3 {
            router.unregister(stalePresenter, from: host)
        }

        #expect(router.requestPresentation(in: host) == .presented)
        #expect(replacementPresenter.presentationCount == 1)
        #expect(stalePresenter.presentationCount == 0)
    }

    // MARK: - Fixture

    /// Captures the router's deferred hand-off so a test can observe the
    /// moment before and after it instead of guessing at runloop timing.
    @MainActor
    private final class Deliveries {
        private var pending: [@MainActor () -> Void] = []

        var count: Int { pending.count }

        var isEmpty: Bool { pending.isEmpty }

        func enqueue(_ operation: @escaping @MainActor () -> Void) {
            pending.append(operation)
        }

        func flush() {
            let operations = pending
            pending.removeAll()
            for operation in operations { operation() }
        }
    }

    private func makeRouter() -> (AgentInboxPopoverRouter, Deliveries) {
        let deliveries = Deliveries()
        return (
            AgentInboxPopoverRouter { operation in
                deliveries.enqueue(operation)
            },
            deliveries
        )
    }

    private func nextMainRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class Host {}

    private final class Presenter: AgentInboxPopoverPresenting {
        private(set) var presentationCount = 0

        func presentAgentInbox() {
            presentationCount += 1
        }
    }
}
