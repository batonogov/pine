//
//  AgentStatusBarItem.swift
//  Pine
//
//  Status-bar summary of active AI agents across all terminal panes
//  (vision #933 Phase 1 — Awareness, issue #952).
//
//  This file depends only on value types (`AgentStatusSummary`) and the agent
//  models (`AgentType`/`AgentState`), never on `TerminalTab` or
//  `LocalProcessTerminalView` directly. That keeps the view and its snapshot
//  tests free of a live terminal — unlike the terminal-tab badges (#1048),
//  which render against a real `TerminalTab.agentSession`.
//

import AppKit
import SwiftUI

/// Snapshot of one visible AI-agent session for the status bar.
///
/// A value-type projection of an `AgentSession` plus the terminal location
/// (`paneID` / `tabID`) needed to navigate to it. Built by
/// `activeSummaries(in:)` from the live `PaneManager`; consumed by
/// `AgentStatusBarItem`. Being a value type makes the status-bar item and its
/// snapshot tests independent of a running terminal process.
struct AgentStatusSummary: Identifiable, Equatable {
    /// Stable identifier — equal to the underlying `AgentSession.id`.
    let id: UUID
    /// Which agent this summary represents.
    let agentType: AgentType
    /// Current lifecycle state of the agent session.
    let state: AgentState
    /// Freshness of Pine's process evidence for the session.
    let liveness: AgentLiveness
    /// Terminal pane hosting this agent's tab (for click-to-navigate).
    let paneID: PaneID
    /// Terminal tab hosting this agent (for click-to-navigate).
    let tabID: UUID

    /// A stale waiting-input heuristic must not demand user attention: Pine
    /// no longer has current evidence that the session is still waiting.
    var needsAttention: Bool {
        liveness == .live && state.needsAttention
    }

    /// Active-work indication is likewise gated by fresh process evidence.
    var isActivelyWorking: Bool {
        liveness == .live && state.isActive
    }

    init(
        id: UUID,
        agentType: AgentType,
        state: AgentState,
        liveness: AgentLiveness = .live,
        paneID: PaneID,
        tabID: UUID
    ) {
        self.id = id
        self.agentType = agentType
        self.state = state
        self.liveness = liveness
        self.paneID = paneID
        self.tabID = tabID
    }

    /// Aggregates visible agent sessions from every terminal pane into
    /// value-type summaries.
    ///
    /// Walks `paneManager.terminalPaneIDs` → `terminalState(for:)` →
    /// `terminalTabs`, including live/stale non-done sessions and the bounded
    /// terminated session retained by the coordinator for exit feedback.
    /// Order follows pane order then tab order within a pane.
    ///
    /// `@MainActor` because it reads `PaneManager` / `TerminalPaneState` /
    /// `TerminalTab.agentSession`, all of which are main-actor state.
    @MainActor
    static func activeSummaries(in paneManager: PaneManager) -> [AgentStatusSummary] {
        var summaries: [AgentStatusSummary] = []
        for paneID in paneManager.terminalPaneIDs {
            guard let paneState = paneManager.terminalState(for: paneID) else { continue }
            for tab in paneState.terminalTabs {
                guard let session = tab.agentSession,
                      session.state != .done || session.liveness == .terminated else {
                    continue
                }
                summaries.append(
                    AgentStatusSummary(
                        id: session.id,
                        agentType: session.agentType,
                        state: session.state,
                        liveness: session.liveness,
                        paneID: paneID,
                        tabID: tab.id
                    )
                )
            }
        }
        return summaries
    }
}

/// Status-bar item showing a summary of active AI agents across all terminal
/// panes (#952).
///
/// Renders an agent count plus, per agent, a colored dot (using
/// `AgentType.color`, matching the terminal-tab badge from #1048) and the
/// `AgentType.displayName` / `AgentState.displayName`. Color coding is
/// therefore consistent across the tab bar and the status bar.
///
/// Interaction:
/// - Single active agent → clicking the item navigates to its terminal tab.
/// - Multiple agents → a menu lists each agent for selection.
///
/// The item is always rendered through `StatusBarView`, which hides it when
/// there are no active agents.
struct AgentStatusBarItem: View {
    let summaries: [AgentStatusSummary]
    let onSelect: (PaneID, UUID) -> Void

    var body: some View {
        let presentation = AgentStatusBarPresentation(summaries: summaries)
        if summaries.count == 1, let only = summaries.first {
            Button {
                onSelect(only.paneID, only.tabID)
            } label: {
                label(presentation: presentation)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.agentStatusBarItem)
            .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
        } else {
            Menu {
                ForEach(summaries) { summary in
                    Button {
                        onSelect(summary.paneID, summary.tabID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color(nsColor: summary.agentType.color))
                            Text(verbatim: summary.detailText)
                        }
                    }
                }
            } label: {
                label(presentation: presentation)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.agentStatusBarMenu)
            .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
        }
    }

    /// Shared visual label for both the single-agent button and the
    /// multi-agent menu: count + per-agent colored dot and name/state.
    private func label(
        presentation: AgentStatusBarPresentation
    ) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: presentation.countText)

            ForEach(summaries) { summary in
                divider
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color(nsColor: summary.agentType.color))
                        .frame(width: 7, height: 7)
                    Text(verbatim: summary.detailText)
                }
                .opacity(summary.liveness == .live ? 1 : 0.65)
            }
        }
        .font(.system(size: LayoutMetrics.bodySmallFontSize))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var divider: some View {
        Text(verbatim: "·")
            .font(.system(size: LayoutMetrics.bodySmallFontSize))
            .foregroundStyle(.quaternary)
    }
}

/// Localized, testable text projection used by both rendering and VoiceOver.
struct AgentStatusBarPresentation: Equatable {
    let countText: String
    let detailTexts: [String]

    @MainActor
    init(summaries: [AgentStatusSummary]) {
        let hasUncertainEvidence = summaries.contains {
            $0.liveness != .live
        }
        countText = hasUncertainEvidence
            ? Strings.statusbarAgentSessionCount(summaries.count)
            : Strings.statusbarActiveAgentCount(summaries.count)
        detailTexts = summaries.map(\.detailText)
    }

    var accessibilityLabel: String {
        ([countText] + detailTexts).joined(separator: ", ")
    }
}

extension AgentStatusSummary {
    @MainActor
    var detailText: String {
        let stateText = "\(agentType.displayName): \(state.displayName)"
        guard liveness != .live else { return stateText }
        return "\(stateText) — \(liveness.displayName)"
    }
}
