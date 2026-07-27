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
/// live terminal process and stays snapshot-testable.
///
/// Keyboard navigation (#1245): arrow keys move the selection, Return
/// activates the focused row (same as clicking it — pane + tab selection and
/// dismiss), and Escape restores the previous first responder via the host's
/// `onDismiss`. The selection is shared, testable logic in
/// `AgentKeyboardSelection`.
struct AgentAttentionOverlay: View {
    let summaries: [AgentStatusSummary]
    let onNavigate: (PaneID, UUID) -> Void
    /// Called when the user dismisses the overlay without choosing a row
    /// (Escape). The host restores the previous first responder (#1245).
    let onDismiss: () -> Void

    /// Current keyboard selection index into `ranked`. `nil` while the list is
    /// empty; otherwise seeded to the first row so Return is operable
    /// immediately.
    @State private var selectedIndex: Int? = 0

    /// Live blocked sessions come first, then live active work. Uncertain and
    /// terminated evidence is demoted below actionable rows so stale logical
    /// state never masquerades as a current request for attention.
    private var ranked: [AgentStatusSummary] {
        summaries.sorted { Self.rank($0) < Self.rank($1) }
    }

    private static func rank(_ summary: AgentStatusSummary) -> Int {
        switch summary.liveness {
        case .stale: return 2
        case .terminated: return 3
        case .live: break
        }
        switch summary.state {
        case .waitingInput: return 0
        case .thinking, .executing: return 1
        case .done: return 3
        case .idle: return 4
        }
    }

    /// SF Symbol for the freshest available evidence, falling back to the
    /// logical activity state only while process presence is established.
    private func glyph(_ summary: AgentStatusSummary) -> String {
        switch summary.liveness {
        case .stale: return "clock"
        case .terminated: return "xmark.circle.fill"
        case .live: break
        }
        switch summary.state {
        case .waitingInput: return "exclamationmark.circle.fill"
        case .thinking, .executing: return "ellipsis.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .idle: return "circle"
        }
    }

    /// Tint for a row's state. Active states keep the agent's own color so
    /// the per-agent identity (Claude Code orange, Codex green, …) is still
    /// readable inside the attention list.
    private func color(for summary: AgentStatusSummary) -> Color {
        switch summary.liveness {
        case .stale: return .orange
        case .terminated: return .secondary
        case .live: break
        }
        switch summary.state {
        case .waitingInput: return .orange
        case .done: return .green
        case .idle: return .secondary
        case .thinking, .executing:
            return Color(nsColor: summary.agentType.color)
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
                                    Image(systemName: glyph(summary))
                                        .foregroundStyle(color(for: summary))
                                        .frame(width: 16)
                                    Text(verbatim: summary.agentType.displayName)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(verbatim: detailText(for: summary))
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

    private func detailText(for summary: AgentStatusSummary) -> String {
        summary.liveness == .live
            ? summary.state.displayName
            : summary.liveness.displayName
    }
}
