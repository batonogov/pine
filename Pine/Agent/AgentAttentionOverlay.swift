//
//  AgentAttentionOverlay.swift
//  Pine
//
//  Attention-list overlay: surfaces only non-idle agent sessions across all
//  terminal panes, so the user can tell at a glance which running agent is
//  blocked / active / done (#1112, cf. agterm's attention list).
//

import AppKit
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
    /// Routes announcements through the same document-scoped overlay router
    /// that owns focus capture. It deliberately has no global key-window
    /// fallback, so another project can never receive this selection.
    let onAnnounce: (String) -> Void
    let onNavigate: (PaneID, UUID) -> Void
    /// Called when the user dismisses the overlay without choosing a row
    /// (Escape). The host restores the previous first responder (#1245).
    let onDismiss: () -> Void

    /// Stable keyboard selection identity. Keeping the UUID instead of an
    /// array offset prevents a liveness update from silently retargeting
    /// Return when `ranked` reorders.
    @State private var selectedID: UUID?
    @FocusState private var hasKeyboardFocus: Bool

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
        switch summary.userFacingState {
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
        switch summary.userFacingState {
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
        switch summary.userFacingState {
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(
                                Array(ranked.enumerated()),
                                id: \.element.id
                            ) { _, summary in
                                row(
                                    summary,
                                    isSelected: selectedID == summary.id
                                )
                                .id(summary.id)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .onChange(of: selectedID) { _, newID in
                        guard let newID else { return }
                        withAnimation(PineAnimation.quick) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380, height: 320)
        .focusable()
        .focused($hasKeyboardFocus)
        .onAppear {
            synchronizeSelection(announce: true)
            hasKeyboardFocus = true
        }
        .onChange(of: ranked.map(\.id)) { _, _ in
            synchronizeSelection(announce: true)
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            activateSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .accessibilityIdentifier(AccessibilityID.agentAttentionOverlay)
    }

    private func row(
        _ summary: AgentStatusSummary,
        isSelected: Bool
    ) -> some View {
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
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear
                    )
            }
        }
        .buttonStyle(.plain)
        // The overlay itself owns keyboard focus so arrows and Return cannot
        // be intercepted by an individual SwiftUI Button.
        .focusable(false)
        .accessibilityIdentifier(
            AccessibilityID.agentAttentionRow(summary.id)
        )
        .accessibilityLabel(
            Text(verbatim: Self.accessibilityAnnouncement(for: summary))
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detailText(for summary: AgentStatusSummary) -> String {
        summary.liveness == .live
            ? summary.userFacingState.displayName
            : summary.liveness.displayName
    }

    private func synchronizeSelection(announce: Bool) {
        let normalizedID = AgentKeyboardSelection.normalizeID(
            selectedID,
            ids: ranked.map(\.id)
        )
        selectedID = normalizedID
        if announce, let normalizedID {
            announceRow(id: normalizedID)
        }
    }

    private func moveSelection(by delta: Int) {
        let nextID = AgentKeyboardSelection.moveID(
            from: selectedID,
            by: delta,
            ids: ranked.map(\.id)
        )
        guard nextID != selectedID else { return }
        selectedID = nextID
        if let nextID {
            announceRow(id: nextID)
        }
    }

    private func activateSelection() {
        guard let selectedID = AgentKeyboardSelection.normalizeID(
            selectedID,
            ids: ranked.map(\.id)
        ), let summary = ranked.first(where: { $0.id == selectedID }) else {
            return
        }
        self.selectedID = selectedID
        onNavigate(summary.paneID, summary.tabID)
    }

    private func announceRow(id: UUID) {
        guard let summary = ranked.first(where: { $0.id == id }) else { return }
        onAnnounce(
            Self.accessibilityAnnouncement(for: summary)
        )
    }

    /// Shared spoken label used by the row and explicit selection
    /// announcements. Keeping it testable ensures VoiceOver identifies the
    /// same request that Return will activate.
    @MainActor
    static func accessibilityAnnouncement(
        for summary: AgentStatusSummary
    ) -> String {
        summary.detailText
    }
}
