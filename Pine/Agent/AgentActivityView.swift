//
//  AgentActivityView.swift
//  Pine
//
//  Structured, chronological view of AI-agent actions (vision #933,
//  Phase 2 — Visibility, issue #1072). Replaces raw terminal scrollback
//  with a filterable action feed.
//
//  The view consumes value-type `AgentActivityRow` projections (built from
//  `AgentAction`) so that it — and its snapshot tests — need no live
//  terminal, mirroring the `AgentStatusSummary` pattern from the status-bar
//  item (#952).
//

import AppKit
import SwiftUI

/// Value-type projection of an `AgentAction` for rendering. Decouples the view
/// (and its snapshot tests) from the live `AgentActivityStore`.
struct AgentActivityRow: Identifiable, Equatable {
    /// Stable identifier — equal to the underlying `AgentAction.id`.
    let id: UUID
    /// Which agent performed the action (for the color dot).
    let agentType: AgentType
    /// Kind of operation (for the row icon).
    let kind: AgentActionKind
    /// Lifecycle status (for the status badge).
    let status: AgentActionStatus
    /// File touched, if any (clicking opens it in the editor).
    let fileURL: URL?
    /// One-line summary text.
    let summary: String
    /// When the action happened.
    let timestamp: Date

    init(_ action: AgentAction) {
        self.id = action.id
        self.agentType = action.agentType
        self.kind = action.kind
        self.status = action.status
        self.fileURL = action.fileURL
        self.summary = action.summary
        self.timestamp = action.timestamp
    }
}

/// Collapsible Activity Panel listing agent actions in reverse-chronological
/// order with kind/status filter chips.
///
/// Rendered as a sheet from `ContentView` via the `showAgentActivity`
/// notification. Clicking a row whose action has a `fileURL` opens that file
/// in the editor through the provided callback.
struct AgentActivityView: View {
    let rows: [AgentActivityRow]
    /// Called when the user clicks a row with a file URL.
    let onSelectFile: (URL) -> Void
    /// Called when the user dismisses the panel.
    let onClose: () -> Void

    @State private var kindFilter: AgentActionKind?
    @State private var statusFilter: AgentActionStatus?

    /// Rows after filtering, newest-first.
    private var visibleRows: [AgentActivityRow] {
        rows
            .filter { row in
                (kindFilter == nil || row.kind == kindFilter)
                    && (statusFilter == nil || row.status == statusFilter)
            }
            .reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterChips
            Divider()
            list
        }
        .frame(width: 420, height: 480)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.agentActivityPanel)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(Strings.agentActivityTitle)
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.agentActivityClose)
        }
        .padding(12)
    }

    // MARK: - Filters

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AgentActionKind.allCases, id: \.self) { kind in
                    FilterChip(
                        label: kind.filterLabel,
                        isSelected: kindFilter == kind
                    ) {
                        kindFilter = kindFilter == kind ? nil : kind
                    }
                }
                Divider().frame(height: 16).padding(.horizontal, 2)
                ForEach(AgentActionStatus.allCases, id: \.self) { status in
                    FilterChip(
                        label: status.displayName,
                        isSelected: statusFilter == status
                    ) {
                        statusFilter = statusFilter == status ? nil : status
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if visibleRows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRows) { row in
                        AgentActivityRowView(row: row) {
                            if let url = row.fileURL { onSelectFile(url) }
                        }
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(Strings.agentActivityEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

/// A single action row: agent color dot, kind icon, summary, status badge,
/// relative timestamp.
struct AgentActivityRowView: View {
    let row: AgentActivityRow
    let onClick: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(nsColor: row.agentType.color))
                    .frame(width: 8, height: 8)

                Image(systemName: row.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.summary)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(verbatim: "\(row.agentType.displayName) · \(relativeTime)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                StatusBadge(status: row.status)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.fileURL == nil)
        .accessibilityIdentifier("\(AccessibilityID.agentActivityRow)_\(row.id)")
    }

    private var relativeTime: String {
        Self.relativeFormatter.localizedString(for: row.timestamp, relativeTo: Date())
    }
}

// MARK: - Subviews

/// Rounded filter chip with a selected state.
struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(.tertiary, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// Small status pill for an action status.
struct StatusBadge: View {
    let status: AgentActionStatus

    var body: some View {
        Text(verbatim: status.displayName)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .pending: .secondary
        case .inProgress: .blue
        case .completed: .green
        case .failed: .red
        }
    }
}

// MARK: - Helpers

extension AgentActionKind {
    /// Short label for the filter chip.
    var filterLabel: String {
        switch self {
        case .fileWrite: "Writes"
        case .fileRead: "Reads"
        case .command: "Commands"
        case .toolCall: "Tools"
        }
    }
}
