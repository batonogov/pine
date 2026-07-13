//
//  AgentAttentionOverlay.swift
//  Pine
//
//  Attention-list overlay: surfaces only non-idle agent sessions across all
//  terminal panes, so the user can tell at a glance which running agent is
//  blocked / active / done (#1112, cf. agterm's attention list).
//

import SwiftUI

/// Flat list of agent sessions that need the user's eye, presented inside a
/// `CommandOverlayView`. Rows are sorted blocked → active → done; clicking a
/// row navigates to its terminal tab (pane + tab selection) and dismisses the
/// overlay. Idle sessions are hidden.
///
/// Built from value-type `AgentStatusSummary` snapshots (see
/// `AgentStatusSummary.activeSummaries(in:)`) so the overlay renders without a
/// live terminal process and stays snapshot-testable. Keyboard arrow/Enter
/// navigation is intentionally out of scope for this first cut — rows are
/// mouse-clickable; full keyboard-nav parity with Quick Open is tracked as a
/// follow-up.
struct AgentAttentionOverlay: View {
    let summaries: [AgentStatusSummary]
    let onNavigate: (PaneID, UUID) -> Void

    /// Blocked first, then active, then done; idle last (normally hidden
    /// upstream, but kept defensive).
    private var ranked: [AgentStatusSummary] {
        summaries.sorted { Self.rank($0.state) < Self.rank($1.state) }
    }

    private static func rank(_ state: AgentState) -> Int {
        switch state {
        case .waitingInput: 0
        case .thinking, .executing: 1
        case .done: 2
        case .idle: 3
        }
    }

    /// SF Symbol for a row's state.
    private func glyph(_ state: AgentState) -> String {
        switch state {
        case .waitingInput: "exclamationmark.circle.fill"
        case .thinking, .executing: "ellipsis.circle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        }
    }

    /// Tint for a row's state. Active states keep the agent's own color so
    /// the per-agent identity (Claude Code orange, Codex green, …) is still
    /// readable inside the attention list.
    private func color(for summary: AgentStatusSummary) -> Color {
        switch summary.state {
        case .waitingInput: .orange
        case .done: .green
        case .idle: .secondary
        case .thinking, .executing: Color(nsColor: summary.agentType.color)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Strings.agentAttentionTitle)
                .font(.headline)
                .padding(.bottom, 8)

            Divider()

            if ranked.isEmpty {
                Text(Strings.agentAttentionEmpty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(ranked) { summary in
                            Button {
                                onNavigate(summary.paneID, summary.tabID)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: glyph(summary.state))
                                        .foregroundStyle(color(for: summary))
                                        .frame(width: 16)
                                    Text(verbatim: summary.agentType.displayName)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(verbatim: summary.state.displayName)
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(16)
        .frame(width: 380, height: 320)
        .accessibilityIdentifier(AccessibilityID.agentAttentionOverlay)
    }
}
