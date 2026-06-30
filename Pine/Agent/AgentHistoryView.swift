//
//  AgentHistoryView.swift
//  Pine
//
//  Timeline view of finished AI-agent sessions from the persistent audit log
//  (vision #933, Phase 2 — Visibility, issue #1073). Each row shows the agent,
//  time range, change summary, and either a `Reverted` badge or a Revert
//  button (with confirmation). Toggled via the `showAgentHistory` notification.
//
//  Rendering is split so snapshot tests need no live store: `AgentHistoryList`
//  consumes value-type `AgentHistoryRow`s (the same value-type-projection
//  pattern used by `AgentStatusSummary` / `AgentStatusBarItem`), while
//  `AgentHistoryView` owns the store binding and revert side effects.
//

import AppKit
import SwiftUI

/// Value-type projection of an `AgentHistoryEntry` for display and snapshot
/// testing. Resolves `agentTypeRaw` back to an `AgentType` (falling back to a
/// generic) so the row carries the agent's color and display name without the
/// view needing to touch the store or disk.
struct AgentHistoryRow: Identifiable, Equatable {
    let id: UUID
    let agentType: AgentType
    let startedAt: Date
    let endedAt: Date?
    let summary: String
    let affectedFileCount: Int
    let reverted: Bool

    init(from entry: AgentHistoryEntry) {
        id = entry.id
        agentType = AgentType(stableIdentifier: entry.agentTypeRaw) ?? .generic(name: "Unknown")
        startedAt = entry.startedAt
        endedAt = entry.endedAt
        summary = entry.summary
        affectedFileCount = entry.affectedFiles.count
        reverted = entry.reverted
    }
}

/// Scrollable timeline list of agent-history rows. Pure rendering — no store,
/// no side effects — so it can be snapshotted with stub rows.
struct AgentHistoryList: View {
    let rows: [AgentHistoryRow]
    let onRevert: (AgentHistoryRow) -> Void

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableLikeView(
                title: Strings.agentHistoryEmptyTitle,
                message: Strings.agentHistoryEmptyMessage
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        AgentHistoryRowView(row: row, onRevert: onRevert)
                        if row.id != rows.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// A single timeline row: agent color dot, name, time range, summary, and
/// revert status/action.
struct AgentHistoryRowView: View {
    let row: AgentHistoryRow
    let onRevert: (AgentHistoryRow) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: row.agentType.color))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: row.agentType.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: row.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: timeRangeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if row.reverted {
                Text(Strings.agentHistoryRevertedBadge)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .accessibilityIdentifier(AccessibilityID.agentHistoryRevertedBadge)
            } else if row.affectedFileCount > 0 {
                Button {
                    onRevert(row)
                } label: {
                    Text(Strings.agentHistoryRevertButton)
                }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.agentHistoryRevertButton)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// "HH:mm – HH:mm" range, or a single time when no end is recorded.
    private var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let start = formatter.string(from: row.startedAt)
        if let endedAt = row.endedAt {
            return "\(start) – \(formatter.string(from: endedAt))"
        }
        return start
    }
}

/// Sheet wrapper that binds to the live `AgentHistoryStore`, computes rows, and
/// handles the revert confirmation + side effect.
struct AgentHistoryView: View {
    @Bindable var store: AgentHistoryStore
    @Binding var isPresented: Bool
    @State private var revertTarget: AgentHistoryRow?
    @State private var revertResult: AgentHistoryRevertResult?

    private var rows: [AgentHistoryRow] {
        store.entries.reversed().map(AgentHistoryRow.init(from:))
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            AgentHistoryList(rows: rows) { row in
                revertTarget = row
            }
            if let revertResult {
                Divider()
                resultBanner(revertResult)
            }
        }
        .frame(minWidth: 460, minHeight: 320)
        .alert(
            Strings.agentHistoryRevertConfirmTitle,
            isPresented: Binding(
                get: { revertTarget != nil },
                set: { if !$0 { revertTarget = nil } }
            )
        ) {
            Button(Strings.agentHistoryRevertConfirmAction, role: .destructive) {
                guard let target = revertTarget else { return }
                let entry = store.entries.first { $0.id == target.id }
                revertTarget = nil
                guard let entry else { return }
                // `revert` runs git off-main; wrap in a Task so the result
                // banner reflects the outcome once the revert completes.
                Task { revertResult = await store.revert(entry: entry) }
            }
            Button(Strings.dialogCancel, role: .cancel) {
                revertTarget = nil
            }
        } message: {
            Text(Strings.agentHistoryRevertConfirmMessage)
        }
    }

    private var sheetHeader: some View {
        HStack {
            Text(Strings.agentHistoryTitle)
                .font(.headline)
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.dialogCancel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func resultBanner(_ result: AgentHistoryRevertResult) -> some View {
        HStack {
            Image(systemName: result.allSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.allSucceeded ? .green : .orange)
            Text(result.allSucceeded
                ? Strings.agentHistoryRevertSuccess
                : Strings.agentHistoryRevertPartialFailure
            )
            .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Lightweight empty-state mirroring `ContentUnavailableView`'s look without
/// its macOS-version availability constraints, for stable snapshot rendering.
private struct ContentUnavailableLikeView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}
