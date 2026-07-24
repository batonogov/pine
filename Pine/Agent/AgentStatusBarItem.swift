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

/// Snapshot of one active AI agent for the status bar.
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
    /// Terminal pane hosting this agent's tab (for click-to-navigate).
    let paneID: PaneID
    /// Terminal tab hosting this agent (for click-to-navigate).
    let tabID: UUID

    /// Aggregates active (non-`.done`) agent sessions from every terminal pane
    /// into value-type summaries.
    ///
    /// Walks `paneManager.terminalPaneIDs` → `terminalState(for:)` →
    /// `terminalTabs`, including any tab whose `agentSession` is present and
    /// not `.done`. Order follows pane order then tab order within a pane.
    ///
    /// `@MainActor` because it reads `PaneManager` / `TerminalPaneState` /
    /// `TerminalTab.agentSession`, all of which are main-actor state.
    @MainActor
    static func activeSummaries(in paneManager: PaneManager) -> [AgentStatusSummary] {
        var summaries: [AgentStatusSummary] = []
        for paneID in paneManager.terminalPaneIDs {
            guard let paneState = paneManager.terminalState(for: paneID) else { continue }
            for tab in paneState.terminalTabs {
                guard let session = tab.agentSession, session.state != .done else { continue }
                summaries.append(
                    AgentStatusSummary(
                        id: session.id,
                        agentType: session.agentType,
                        state: session.state,
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
        if summaries.count == 1, let only = summaries.first {
            Button {
                onSelect(only.paneID, only.tabID)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.agentStatusBarItem)
        } else {
            Menu {
                ForEach(summaries) { summary in
                    Button {
                        onSelect(summary.paneID, summary.tabID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color(nsColor: summary.agentType.color))
                            Text(verbatim: "\(summary.agentType.displayName): \(summary.state.displayName)")
                        }
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.agentStatusBarMenu)
        }
    }

    /// Shared visual label for both the single-agent button and the
    /// multi-agent menu: count + per-agent colored dot and name/state.
    private var label: some View {
        HStack(spacing: 4) {
            countLabel

            ForEach(summaries) { summary in
                divider
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color(nsColor: summary.agentType.color))
                        .frame(width: 7, height: 7)
                    Text(verbatim: "\(summary.agentType.displayName): \(summary.state.displayName)")
                }
            }
        }
        .font(.system(size: LayoutMetrics.bodySmallFontSize))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// "N agent[s] active" with correct singular/plural form.
    private var countLabel: Text {
        if summaries.count == 1 {
            Text("\(Text(verbatim: "1 "))\(Text(Strings.statusbarAgentActive))")
        } else {
            Text(
                "\(Text(verbatim: "\(summaries.count) "))\(Text(Strings.statusbarAgentsActive))"
            )
        }
    }

    private var divider: some View {
        Text(verbatim: "·")
            .font(.system(size: LayoutMetrics.bodySmallFontSize))
            .foregroundStyle(.quaternary)
    }
}
