//
//  AgentStatusSummaryTests.swift
//  PineTests
//
//  Unit tests for AgentStatusSummary.activeSummaries(in:) — the pure
//  aggregator feeding the status-bar agent summary (issue #952).
//

import Testing
import Foundation
@testable import Pine

@Suite("AgentStatusSummary")
@MainActor
struct AgentStatusSummaryTests {

    /// Builds a PaneManager with a single terminal pane at the bottom and
    /// returns it plus that pane's id and state.
    private func makeManagerWithTerminalPane() throws -> (PaneManager, PaneID, TerminalPaneState) {
        let paneManager = PaneManager()
        let paneID = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let state = try #require(paneManager.terminalState(for: paneID))
        return (paneManager, paneID, state)
    }

    // MARK: - Empty cases

    @Test func emptyWhenNoTerminalPanes() {
        let paneManager = PaneManager()
        #expect(AgentStatusSummary.activeSummaries(in: paneManager) == [])
    }

    @Test func emptyWhenNoAgentSessions() throws {
        let (paneManager, _, _) = try makeManagerWithTerminalPane()
        #expect(AgentStatusSummary.activeSummaries(in: paneManager) == [])
    }

    @Test func tabWithoutSessionIsIgnored() throws {
        let (paneManager, _, state) = try makeManagerWithTerminalPane()
        // addTab already created one tab without an agent session; add another.
        _ = state.addTab(workingDirectory: nil)
        #expect(AgentStatusSummary.activeSummaries(in: paneManager) == [])
    }

    // MARK: - Active agents

    @Test func singleActiveAgentProducesOneSummary() throws {
        let (paneManager, paneID, state) = try makeManagerWithTerminalPane()
        let tab = state.terminalTabs[0]
        let session = AgentSession(agentType: .claudeCode, state: .thinking)
        tab.agentSession = session

        let summaries = AgentStatusSummary.activeSummaries(in: paneManager)
        #expect(summaries.count == 1)

        let summary = try #require(summaries.first)
        #expect(summary.id == session.id)
        #expect(summary.agentType == .claudeCode)
        #expect(summary.state == .thinking)
        #expect(summary.liveness == .live)
        #expect(summary.paneID == paneID)
        #expect(summary.tabID == tab.id)
    }

    @Test func doneSessionIsExcluded() throws {
        let (paneManager, _, state) = try makeManagerWithTerminalPane()
        state.terminalTabs[0].agentSession = AgentSession(agentType: .codex, state: .done)
        #expect(AgentStatusSummary.activeSummaries(in: paneManager) == [])
    }

    @Test func idleIsConsideredActive() throws {
        // .idle means the agent process is alive but its activity is unknown —
        // it should still appear in the status bar.
        let (paneManager, _, state) = try makeManagerWithTerminalPane()
        state.terminalTabs[0].agentSession = AgentSession(agentType: .pi, state: .idle)
        #expect(AgentStatusSummary.activeSummaries(in: paneManager).count == 1)
    }

    @Test func staleSessionRemainsVisibleWithoutFalseAttention() throws {
        let (paneManager, _, state) = try makeManagerWithTerminalPane()
        state.terminalTabs[0].agentSession = AgentSession(
            agentType: .codex,
            state: .waitingInput,
            liveness: .stale
        )

        let summary = try #require(
            AgentStatusSummary.activeSummaries(in: paneManager).first
        )

        #expect(summary.liveness == .stale)
        #expect(!summary.needsAttention)
        #expect(!summary.isActivelyWorking)
    }

    @Test func staleExecutingSessionDoesNotPretendToBeActive() {
        let summary = AgentStatusSummary(
            id: UUID(),
            agentType: .claudeCode,
            state: .executing,
            liveness: .stale,
            paneID: PaneID(),
            tabID: UUID()
        )

        #expect(!summary.needsAttention)
        #expect(!summary.isActivelyWorking)
    }

    @Test func liveStateStillDrivesAttentionAndActivity() {
        let paneID = PaneID()
        let waiting = AgentStatusSummary(
            id: UUID(),
            agentType: .claudeCode,
            state: .waitingInput,
            paneID: paneID,
            tabID: UUID()
        )
        let executing = AgentStatusSummary(
            id: UUID(),
            agentType: .codex,
            state: .executing,
            paneID: paneID,
            tabID: UUID()
        )

        #expect(waiting.needsAttention)
        #expect(!waiting.isActivelyWorking)
        #expect(!executing.needsAttention)
        #expect(executing.isActivelyWorking)
    }

    @Test func retainedTerminatedSessionRemainsVisibleForExitFeedback() throws {
        let (paneManager, _, state) = try makeManagerWithTerminalPane()
        state.terminalTabs[0].agentSession = AgentSession(
            agentType: .pi,
            state: .done,
            liveness: .terminated
        )

        let summary = try #require(
            AgentStatusSummary.activeSummaries(in: paneManager).first
        )
        #expect(summary.state == .done)
        #expect(summary.liveness == .terminated)
        #expect(!summary.needsAttention)
        #expect(!summary.isActivelyWorking)
    }

    @Test func multipleAgentsAcrossPanesHaveCorrectLocations() throws {
        let paneManager = PaneManager()
        let editorPane = paneManager.activePaneID

        // Two terminal panes, each with one agent-bearing tab.
        let termPane1 = try #require(
            paneManager.createTerminalPane(relativeTo: editorPane, axis: .vertical, workingDirectory: nil)
        )
        let termPane2 = try #require(
            paneManager.createTerminalPane(relativeTo: editorPane, axis: .horizontal, workingDirectory: nil)
        )
        let state1 = try #require(paneManager.terminalState(for: termPane1))
        let state2 = try #require(paneManager.terminalState(for: termPane2))

        let tab1 = state1.terminalTabs[0]
        let tab2 = state2.terminalTabs[0]
        tab1.agentSession = AgentSession(agentType: .claudeCode, state: .executing)
        tab2.agentSession = AgentSession(agentType: .codex, state: .thinking)

        let summaries = AgentStatusSummary.activeSummaries(in: paneManager)
        #expect(summaries.count == 2)

        let byPane = Dictionary(uniqueKeysWithValues: summaries.map { ($0.paneID, $0) })
        #expect(byPane[termPane1]?.agentType == .claudeCode)
        #expect(byPane[termPane1]?.tabID == tab1.id)
        #expect(byPane[termPane2]?.agentType == .codex)
        #expect(byPane[termPane2]?.tabID == tab2.id)
    }

    @Test func multipleAgentsInSamePaneAreAllListed() throws {
        let (paneManager, paneID, state) = try makeManagerWithTerminalPane()
        let tabA = state.terminalTabs[0]
        let tabB = state.addTab(workingDirectory: nil)
        tabA.agentSession = AgentSession(agentType: .aider, state: .thinking)
        tabB.agentSession = AgentSession(agentType: .copilot, state: .waitingInput)

        let summaries = AgentStatusSummary.activeSummaries(in: paneManager)
        #expect(summaries.count == 2)
        #expect(summaries.allSatisfy { $0.paneID == paneID })
        // Order within a pane follows tab order (documented contract).
        #expect(summaries.map(\.tabID) == [tabA.id, tabB.id])
        let tabIDs = Set(summaries.map(\.tabID))
        #expect(tabIDs == [tabA.id, tabB.id])
    }

    @Test func mixedActiveAndDoneOnlyReturnsActive() throws {
        let (paneManager, _, state) = try makeManagerWithTerminalPane()
        let activeTab = state.terminalTabs[0]
        let doneTab = state.addTab(workingDirectory: nil)
        activeTab.agentSession = AgentSession(agentType: .claudeCode, state: .idle)
        doneTab.agentSession = AgentSession(agentType: .codex, state: .done)

        let summaries = AgentStatusSummary.activeSummaries(in: paneManager)
        #expect(summaries.count == 1)
        #expect(summaries.first?.tabID == activeTab.id)
        #expect(summaries.first?.agentType == .claudeCode)
    }

    @Test func countStringsUseLocaleSpecificPluralForms() {
        let russian = Locale(identifier: "ru")
        #expect(
            Strings.statusbarActiveAgentCount(1, locale: russian)
                == "1 агент активен"
        )
        #expect(
            Strings.statusbarActiveAgentCount(2, locale: russian)
                == "2 агента активны"
        )
        #expect(
            Strings.statusbarActiveAgentCount(5, locale: russian)
                == "5 агентов активны"
        )
        #expect(
            Strings.statusbarAgentSessionCount(21, locale: russian)
                == "21 сессия агента"
        )
        #expect(
            Strings.statusbarAgentSessionCount(22, locale: russian)
                == "22 сессии агентов"
        )
        #expect(
            Strings.statusbarAgentSessionCount(25, locale: russian)
                == "25 сессий агентов"
        )
    }

    @Test func countStringsAreResolvedForEverySupportedLocale() {
        let localeIDs = [
            "en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
        ]
        for localeID in localeIDs {
            let locale = Locale(identifier: localeID)
            let active = Strings.statusbarActiveAgentCount(2, locale: locale)
            let sessions = Strings.statusbarAgentSessionCount(5, locale: locale)
            #expect(active.contains("2"))
            #expect(sessions.contains("5"))
            #expect(!active.contains("statusbar."))
            #expect(!sessions.contains("statusbar."))
        }
    }

    @Test func staleAndTerminatedAccessibilityLabelsStateUncertainty() {
        let stale = statusSummary(
            agentType: .claudeCode,
            state: .waitingInput,
            liveness: .stale
        )
        let terminated = statusSummary(
            agentType: .codex,
            state: .done,
            liveness: .terminated
        )

        let stalePresentation = AgentStatusBarPresentation(summaries: [stale])
        let terminatedPresentation = AgentStatusBarPresentation(
            summaries: [terminated]
        )

        #expect(
            stalePresentation.accessibilityLabel
                .contains(AgentLiveness.stale.displayName)
        )
        #expect(
            terminatedPresentation.accessibilityLabel
                .contains(AgentLiveness.terminated.displayName)
        )
        #expect(
            stalePresentation.accessibilityLabel
                .contains(Strings.statusbarAgentSessionCount(1))
        )
    }

    @Test func mixedAccessibilityLabelAnnouncesCountAndEverySession() {
        let summaries = [
            statusSummary(agentType: .claudeCode, state: .executing),
            statusSummary(
                agentType: .codex,
                state: .waitingInput,
                liveness: .stale
            ),
            statusSummary(
                agentType: .pi,
                state: .done,
                liveness: .terminated
            ),
        ]

        let presentation = AgentStatusBarPresentation(summaries: summaries)

        #expect(
            presentation.accessibilityLabel
                .contains(Strings.statusbarAgentSessionCount(3))
        )
        #expect(presentation.accessibilityLabel.contains("Claude Code"))
        #expect(presentation.accessibilityLabel.contains("Codex"))
        #expect(presentation.accessibilityLabel.contains("Pi"))
        #expect(
            presentation.accessibilityLabel
                .contains(AgentLiveness.stale.displayName)
        )
        #expect(
            presentation.accessibilityLabel
                .contains(AgentLiveness.terminated.displayName)
        )
    }

    private func statusSummary(
        agentType: AgentType,
        state: AgentState,
        liveness: AgentLiveness = .live
    ) -> AgentStatusSummary {
        AgentStatusSummary(
            id: UUID(),
            agentType: agentType,
            state: state,
            liveness: liveness,
            paneID: PaneID(),
            tabID: UUID()
        )
    }
}
