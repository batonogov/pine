//
//  AgentInboxHostRoutingTests.swift
//  PineTests
//
//  The host-selection contract for one Agent Inbox request (#1491).
//

import Testing

@testable import Pine

@Suite("Agent Inbox host routing")
struct AgentInboxHostRoutingTests {
    // MARK: - Preference order

    @Test("the key eligible project window wins")
    func keyProjectWindowWins() {
        let decision = AgentInboxHostRouting.decision(among: [
            .project(isKey: false),
            .project(isKey: true),
            .welcome(isKey: false),
        ])

        #expect(decision == .existingHost(index: 1))
    }

    @Test("the key project window wins over a key Welcome window")
    func keyProjectBeatsKeyWelcome() {
        // Both flags cannot be true on a real desktop, but the rule must not
        // depend on that: a stale key flag has to lose to the project window.
        let decision = AgentInboxHostRouting.decision(among: [
            .welcome(isKey: true),
            .project(isKey: true),
        ])

        #expect(decision == .existingHost(index: 1))
    }

    @Test("the key project window wins over the most recently active one")
    func keyProjectBeatsMostRecentProject() {
        let decision = AgentInboxHostRouting.decision(among: [
            .project(isKey: false, showsMostRecentlyActiveProject: true),
            .project(isKey: true),
        ])

        #expect(decision == .existingHost(index: 1))
    }

    @Test("the key Welcome window wins when no project is eligible")
    func keyWelcomeWinsWithoutAnEligibleProject() {
        let decision = AgentInboxHostRouting.decision(among: [
            .project(
                isKey: true,
                isEligible: false,
                showsMostRecentlyActiveProject: true
            ),
            .welcome(isKey: true),
        ])

        #expect(decision == .existingHost(index: 1))
    }

    @Test("an auxiliary key window routes to the most recent project")
    func auxiliaryKeyWindowRoutesToMostRecentProject() {
        // Settings, About, and panels carry no candidate at all, so "an
        // auxiliary window is key" is exactly "no candidate is key".
        let decision = AgentInboxHostRouting.decision(among: [
            .project(isKey: false),
            .project(isKey: false, showsMostRecentlyActiveProject: true),
            .welcome(isKey: false),
        ])

        #expect(decision == .existingHost(index: 1))
    }

    @Test("the most recent project outranks a visible Welcome window")
    func mostRecentProjectBeatsVisibleWelcome() {
        let decision = AgentInboxHostRouting.decision(among: [
            .welcome(isKey: false),
            .project(isKey: false, showsMostRecentlyActiveProject: true),
        ])

        #expect(decision == .existingHost(index: 1))
    }

    @Test("a visible Welcome window is the final existing-window fallback")
    func visibleWelcomeIsTheFinalFallback() {
        let decision = AgentInboxHostRouting.decision(among: [
            .project(isKey: false),
            .welcome(isKey: false),
        ])

        #expect(decision == .existingHost(index: 1))
    }

    // MARK: - Eligibility

    @Test("an ineligible key project window never hosts the Inbox")
    func ineligibleKeyProjectIsSkipped() {
        // A window whose close already completed is still in NSApp.windows.
        let decision = AgentInboxHostRouting.decision(among: [
            .project(isKey: true, isEligible: false),
            .welcome(isKey: false),
        ])

        #expect(decision == .existingHost(index: 1))
    }

    @Test("an ineligible most-recent project window never hosts the Inbox")
    func ineligibleMostRecentProjectIsSkipped() {
        let decision = AgentInboxHostRouting.decision(among: [
            .project(
                isKey: false,
                isEligible: false,
                showsMostRecentlyActiveProject: true
            ),
            .welcome(isKey: false),
        ])

        #expect(decision == .existingHost(index: 1))
    }

    @Test("a project window with no claim at all is never chosen")
    func unrelatedProjectWindowIsNeverChosen() {
        // Neither key nor the most recent project: routing into it would drop
        // the Inbox onto a window the user has not touched.
        let decision = AgentInboxHostRouting.decision(among: [
            .project(isKey: false),
            .project(isKey: false),
        ])

        #expect(decision == .createWelcomeHost)
    }

    // MARK: - Creating Welcome

    @Test("no window at all creates Welcome")
    func emptyDesktopCreatesWelcome() {
        #expect(
            AgentInboxHostRouting.decision(among: []) == .createWelcomeHost
        )
    }

    /// Also the only coverage of the eligibility conjunct on the two Welcome
    /// preferences: the ineligible Welcome candidate below is refused by both
    /// of them. That input is unreachable from production —
    /// `AppDelegate.agentInboxHostOptions` builds a Welcome candidate only out
    /// of `visibleWelcomeWindow()` and always marks it eligible — so it is
    /// pinned here as a forward contract, not claimed as behavior coverage.
    @Test("only ineligible windows create Welcome")
    func allIneligibleCreatesWelcome() {
        let decision = AgentInboxHostRouting.decision(among: [
            .project(
                isKey: true,
                isEligible: false,
                showsMostRecentlyActiveProject: true
            ),
            .project(isKey: false, isEligible: false),
            .welcome(isKey: true, isEligible: false),
        ])

        #expect(decision == .createWelcomeHost)
    }

    // MARK: - Determinism

    @Test("the first candidate wins each tie, so one request has one host")
    func tiesResolveToTheFirstCandidate() {
        let keyProjects = AgentInboxHostRouting.decision(among: [
            .project(isKey: true),
            .project(isKey: true),
        ])
        let welcomes = AgentInboxHostRouting.decision(among: [
            .welcome(isKey: false),
            .welcome(isKey: false),
        ])
        let recents = AgentInboxHostRouting.decision(among: [
            .project(isKey: false, showsMostRecentlyActiveProject: true),
            .project(isKey: false, showsMostRecentlyActiveProject: true),
        ])

        #expect(keyProjects == .existingHost(index: 0))
        #expect(welcomes == .existingHost(index: 0))
        #expect(recents == .existingHost(index: 0))
    }

    @Test("a very long window list still resolves to one index")
    func manyWindowsResolveToOneIndex() {
        var candidates = (0..<200).map { _ in
            AgentInboxHostCandidate.project(isKey: false)
        }
        candidates.append(.project(isKey: true))
        candidates.append(contentsOf: (0..<50).map { _ in
            AgentInboxHostCandidate.welcome(isKey: true)
        })

        #expect(
            AgentInboxHostRouting.decision(among: candidates)
                == .existingHost(index: 200)
        )
    }
}

// MARK: - Fixture

extension AgentInboxHostCandidate {
    fileprivate static func project(
        isKey: Bool,
        isEligible: Bool = true,
        showsMostRecentlyActiveProject: Bool = false
    ) -> AgentInboxHostCandidate {
        AgentInboxHostCandidate(
            kind: .project,
            isKeyWindow: isKey,
            isEligibleWindow: isEligible,
            showsMostRecentlyActiveProject: showsMostRecentlyActiveProject
        )
    }

    fileprivate static func welcome(
        isKey: Bool,
        isEligible: Bool = true
    ) -> AgentInboxHostCandidate {
        AgentInboxHostCandidate(
            kind: .welcome,
            isKeyWindow: isKey,
            isEligibleWindow: isEligible
        )
    }
}
