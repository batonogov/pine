//
//  AgentInboxPopoverRouterTests.swift
//  PineTests
//
//  Window-identity and late-anchor coverage for Agent Inbox presentation.
//

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
        let router = AgentInboxPopoverRouter()
        let host = Host()
        let presenter = Presenter()

        #expect(router.requestPresentation(in: host) == .queued)
        #expect(presenter.presentationCount == 0)

        router.register(presenter, for: host)

        #expect(presenter.presentationCount == 1)
    }

    @Test("a request never leaks into another window")
    func requestTargetsExactWindow() {
        let router = AgentInboxPopoverRouter()
        let requestedHost = Host()
        let otherHost = Host()
        let otherPresenter = Presenter()
        let requestedPresenter = Presenter()

        router.register(otherPresenter, for: otherHost)
        #expect(router.requestPresentation(in: requestedHost) == .queued)
        #expect(otherPresenter.presentationCount == 0)

        router.register(requestedPresenter, for: requestedHost)
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

    private final class Host {}

    private final class Presenter: AgentInboxPopoverPresenting {
        private(set) var presentationCount = 0

        func presentAgentInbox() {
            presentationCount += 1
        }
    }
}
