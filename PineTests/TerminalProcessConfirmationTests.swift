//
//  TerminalProcessConfirmationTests.swift
//  PineTests
//
//  Tests for the shared terminal foreground-process confirmation logic
//  in TabCloseHelper (issue #970).
//

import Testing
import AppKit
@testable import Pine

/// Tests for `TabCloseHelper.confirmTerminalStop` and
/// `TabCloseHelper.confirmTerminalProcessStop` — the shared decision logic
/// that guards every path that stops or removes terminal tabs.
@Suite("Terminal Process Confirmation")
@MainActor
struct TerminalProcessConfirmationTests {

    // MARK: - confirmTerminalStop (pure decision function)

    @Test func noForegroundProcess_doesNotPresentAlert_proceedsImmediately() async {
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalStop(
            hasForegroundProcess: false,
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn
            }
        )
        #expect(result == true)
        #expect(alertCalled == false)
    }

    @Test func foregroundProcess_userConfirms_proceeds() async {
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalStop(
            hasForegroundProcess: true,
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn // "Close Terminal"
            }
        )
        #expect(result == true)
        #expect(alertCalled == true)
    }

    @Test func foregroundProcess_userCancels_aborts() async {
        let result = await TabCloseHelper.confirmTerminalStop(
            hasForegroundProcess: true,
            presentAlert: { .alertSecondButtonReturn } // "Cancel"
        )
        #expect(result == false)
    }

    // MARK: - confirmTerminalProcessStop (tabs-based convenience)

    @Test func emptyTabs_proceedsImmediately() async {
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalProcessStop(
            tabs: [],
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn
            }
        )
        #expect(result == true)
        #expect(alertCalled == false)
    }

    @Test func tabsWithoutForegroundProcess_proceedsImmediately() async {
        // Newly created TerminalTabs have hasForegroundProcess == false
        // because no process has been started. We use this to verify the
        // no-warning fast path with real tab objects.
        let tab = TerminalTab(name: "Test Terminal")
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalProcessStop(
            tabs: [tab],
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn
            }
        )
        #expect(result == true)
        #expect(alertCalled == false)
    }

    // MARK: - Default alert (production path)

    @Test func defaultAlertIsUsedWhenNoInjectionProvided() async {
        // Verify the default parameter compiles and runs without crashing.
        // We can't meaningfully test the modal result in a headless test
        // (it would present a real NSAlert), so we only verify the no-process
        // fast path which never calls the alert.
        let result = await TabCloseHelper.confirmTerminalStop(hasForegroundProcess: false)
        #expect(result == true)
    }

    @Test func defaultAlertIsUsedForTabsOverload_noProcess() async {
        let tab = TerminalTab(name: "Idle Terminal")
        let result = await TabCloseHelper.confirmTerminalProcessStop(tabs: [tab])
        #expect(result == true)
    }

    // MARK: - Multiple tabs aggregation

    @Test func multipleTabs_allIdle_proceedsImmediately() async {
        let tabs = (0..<5).map { TerminalTab(name: "Terminal \($0)") }
        var alertCalled = false
        let result = await TabCloseHelper.confirmTerminalProcessStop(
            tabs: tabs,
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn
            }
        )
        #expect(result == true)
        #expect(alertCalled == false)
    }

    // MARK: - Agent-tab authorization (#1335)
    //
    // An AI-agent tab churns its foreground process group on nearly every
    // poll (the agent spawns git/node/shell children). The close path must
    // authorize such a tab by its stable agent-session identity rather than
    // its volatile pgid, so the normal churn cannot silently abort a
    // confirmation the user already gave.

    @Test func agentTab_requiresConfirmation_evenWithoutForegroundPgid() {
        let tab = TerminalTab(name: "Claude")
        tab.agentSession = AgentSession(agentType: .claudeCode)

        let authorization = TerminalTabCloseAuthorization.authorizing(tabs: [tab])

        #expect(authorization.requiresConfirmation)
    }

    @Test func agentTab_userConfirms_proceeds() async {
        let tab = TerminalTab(name: "Claude")
        tab.agentSession = AgentSession(agentType: .claudeCode)
        var alertCalled = false

        let result = await TabCloseHelper.confirmTerminalProcessStop(
            tabs: [tab],
            presentAlert: {
                alertCalled = true
                return .alertFirstButtonReturn // "Close Terminal"
            }
        )

        #expect(result == true)
        #expect(alertCalled == true)
    }

    @Test func agentTab_userCancels_aborts() async {
        let tab = TerminalTab(name: "Claude")
        tab.agentSession = AgentSession(agentType: .claudeCode)

        let result = await TabCloseHelper.confirmTerminalProcessStop(
            tabs: [tab],
            presentAlert: { .alertSecondButtonReturn } // "Cancel"
        )

        #expect(result == false)
    }

    @Test func agentTab_foregroundPgidChurn_doesNotInvalidateConfirmation() {
        // A test TerminalTab has no real PTY, so foregroundProcessID stays
        // negative regardless — exactly the situation during pgid churn where
        // the foreground group is briefly not the agent's own. The same agent
        // session remains, so the confirmation must still cover the tab.
        let tab = TerminalTab(name: "Claude")
        let session = AgentSession(agentType: .claudeCode)
        tab.agentSession = session

        let authorization = TerminalTabCloseAuthorization.authorizing(tabs: [tab])

        #expect(authorization.stillCovers([tab]))
    }

    @Test func agentTab_differentAgentSession_invalidatesConfirmation() {
        // A genuinely different agent run is a new authorization generation
        // and must not be covered by the previous answer.
        let tab = TerminalTab(name: "Claude")
        tab.agentSession = AgentSession(agentType: .claudeCode)
        let authorization = TerminalTabCloseAuthorization.authorizing(tabs: [tab])

        tab.agentSession = AgentSession(agentType: .claudeCode) // new session id

        #expect(!authorization.stillCovers([tab]))
    }

    @Test func agentTab_agentExited_isStillCovered() {
        // If the agent exited while the sheet was visible, there is nothing
        // left to protect — the tab is safe to close.
        let tab = TerminalTab(name: "Claude")
        tab.agentSession = AgentSession(agentType: .claudeCode)
        let authorization = TerminalTabCloseAuthorization.authorizing(tabs: [tab])

        tab.agentSession = nil

        #expect(authorization.stillCovers([tab]))
    }

    @Test func agentTab_deduplicationKeyIsStableAcrossPgidChurn() {
        // The dedup key for an agent tab carries no volatile foreground pgid,
        // so two close gestures on the same agent tab collapse to one
        // in-flight request even as the pgid churns between them.
        let tab = TerminalTab(name: "Claude")
        tab.agentSession = AgentSession(agentType: .claudeCode)

        let first = TerminalTabCloseAuthorization.authorizing(tabs: [tab])
        let second = TerminalTabCloseAuthorization.authorizing(tabs: [tab])

        #expect(first.deduplicationKey == second.deduplicationKey)
        // No volatile pgid is recorded for an agent tab.
        switch first.deduplicationKey {
        case .terminalTabs(_, let foregroundProcesses):
            #expect(foregroundProcesses.isEmpty)
        default:
            Issue.record("expected terminalTabs dedup key")
        }
    }

    @Test func mixedIdleAndAgentTabs_idleTabDoesNotInvalidateConfirmation() {
        // Bulk close (hide-all toggle / pane close) passes ALL terminal tabs
        // — including idle shells — to `confirmTerminalProcessStop`. An idle
        // tab (no agent session, no foreground process) is absent from
        // `coverage`; it must NOT cause `stillCovers` to abort an otherwise-
        // covered authorization, or every mixed idle+active bulk close would
        // silently no-op right after the user confirmed (#1335 review finding).
        let idleTab = TerminalTab(name: "Shell")
        let agentTab = TerminalTab(name: "Claude")
        agentTab.agentSession = AgentSession(agentType: .claudeCode)

        let authorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [idleTab, agentTab]
        )

        #expect(authorization.requiresConfirmation)
        // The idle tab is skipped; the agent tab is still covered.
        #expect(authorization.stillCovers([idleTab, agentTab]))
        // Tab order in the re-check must not matter.
        #expect(authorization.stillCovers([agentTab, idleTab]))
    }

    @Test func idleTabBecomingAgentInvalidatesAuthorization() {
        let tab = TerminalTab(name: "Shell")
        let authorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [tab]
        )

        tab.agentSession = AgentSession(agentType: .claudeCode)

        #expect(!authorization.stillCovers([tab]))
    }

    @Test func newlyAddedAgentTabInvalidatesAuthorization() {
        let original = TerminalTab(name: "Shell")
        let authorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [original]
        )
        let added = TerminalTab(name: "Claude")
        added.agentSession = AgentSession(agentType: .claudeCode)

        #expect(!authorization.stillCovers([original, added]))
    }
}
