//
//  AgentHistoryView.swift
//  Pine
//
//  Timeline view of finished AI-agent sessions from persistent history
//  (vision #933, Phase 2 — Visibility, issue #1073). Each row shows the agent,
//  time range, observed-change summary, and safe undo availability. Toggled
//  via the `showAgentHistory` notification.
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
    let undoAvailability: AgentHistoryUndoAvailability
    /// Availability computed by the store after consulting the owner-private
    /// authority. The UI reads this (not the pure `undoAvailability`) to decide
    /// whether the verified Revert button is enabled (#1183).
    var effectiveUndoAvailability: AgentHistoryUndoAvailability

    init(from entry: AgentHistoryEntry) {
        id = entry.id
        agentType = AgentType(stableIdentifier: entry.agentTypeRaw) ?? .generic(name: "Unknown")
        startedAt = entry.startedAt
        endedAt = entry.endedAt
        summary = entry.summary
        affectedFileCount = entry.affectedFiles.count
        reverted = entry.reverted
        undoAvailability = entry.undoAvailability
        effectiveUndoAvailability = entry.undoAvailability
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
                switch row.effectiveUndoAvailability {
                case .available:
                    Button {
                        onRevert(row)
                    } label: {
                        Text(Strings.agentHistoryRevertButton)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.agentHistoryRevertButton)
                case .unavailable:
                    VStack(alignment: .trailing, spacing: 2) {
                        Label {
                            Text(Strings.agentHistoryUndoUnavailable)
                        } icon: {
                            Image(systemName: "lock.fill")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                        Text(Strings.agentHistoryUndoUnavailableReason)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 190, alignment: .trailing)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.agentHistoryUndoUnavailable)
                }
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
        store.entries.reversed().map { entry in
            var row = AgentHistoryRow(from: entry)
            row.effectiveUndoAvailability = store.effectiveUndoAvailability(for: entry)
            return row
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            if !store.recoveryNotices.isEmpty {
                AgentHistoryRecoveryNoticeList(
                    records: store.recoveryNotices
                )
                Divider()
            }
            AgentHistoryList(rows: rows) { row in
                revertTarget = row
            }
            if let revertResult {
                Divider()
                resultBanner(revertResult)
            }
        }
        .frame(minWidth: 460, minHeight: 320)
        .task {
            await store.refreshCheckedUndoAvailability()
            await store.refreshRecoveryNotices()
        }
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
            // For a verified, checked undo, explain the exact inverse rather
            // than the legacy git-checkout wording (#1183).
            let isAvailable = revertTarget?.effectiveUndoAvailability == .available
            Text(isAvailable
                ? Strings.agentHistoryCheckedRevertConfirmMessage
                : Strings.agentHistoryRevertConfirmMessage)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(result.allSucceeded
                    ? (result.checkedOutcomes.isEmpty
                        ? Strings.agentHistoryRevertSuccess
                        : Strings.agentHistoryCheckedRevertSuccess)
                    : Strings.agentHistoryRevertPartialFailure
                )
                if let recoveryBackupPath = result.recoveryBackupPath {
                    Text(Strings.agentHistoryRecoveryBackup(recoveryBackupPath))
                        .textSelection(.enabled)
                }
                ForEach(
                    result.recoveryQuarantinePaths,
                    id: \.self
                ) { path in
                    Text(Strings.agentHistoryRetainedRecoveryFile(path))
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Persistent, read-only warning for durable recovery artifacts found after a
/// checked undo. Deliberately offers no restore action: discovery must never
/// turn stale or corrupt backup data into automatic workspace mutations.
struct AgentHistoryRecoveryNoticeList: View {
    let records: [AgentHistoryRecoveryRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label {
                Text(Strings.agentHistoryRecoveryNoticeTitle)
                    .font(.system(size: 12, weight: .semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)

            Text(Strings.agentHistoryRecoveryNoticeInstruction)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(records) { record in
                        recoveryRecord(record)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09))
        .accessibilityIdentifier(
            AccessibilityID.agentHistoryRecoveryNotice
        )
    }

    private func recoveryRecord(
        _ record: AgentHistoryRecoveryRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(statusText(for: record.state))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            recoveryPathRow(
                text: Strings.agentHistoryRecoveryBackup(
                    record.directoryPath
                ),
                path: record.directoryPath,
                isValidated: record.validatedPaths.contains(
                    record.directoryPath
                )
            )
            ForEach(record.recoveryPaths.prefix(8), id: \.self) { path in
                recoveryPathRow(
                    text: Strings.agentHistoryRetainedRecoveryFile(path),
                    path: path,
                    isValidated: record.validatedPaths.contains(path)
                )
            }
            ForEach(record.affectedPaths.prefix(3), id: \.self) { path in
                Text(verbatim: path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            AccessibilityID.agentHistoryRecoveryRecord(
                record.directoryName
            )
        )
    }

    private func recoveryPathRow(
        text: String,
        path: String,
        isValidated: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if isValidated {
                Button {
                    copyPath(path)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.tabCopyPath)
                .accessibilityValue(Text(verbatim: path))
                .accessibilityIdentifier(
                    AccessibilityID.agentHistoryRecoveryCopyPath(path)
                )

                Button {
                    revealInFinder(path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.contextRevealInFinder)
                .accessibilityValue(Text(verbatim: path))
                .accessibilityIdentifier(
                    AccessibilityID.agentHistoryRecoveryRevealPath(path)
                )
            }
        }
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func revealInFinder(_ path: String) {
        guard path.hasPrefix("/") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: path)
        ])
    }

    private func statusText(
        for state: AgentHistoryRecoveryDiscoveryState
    ) -> LocalizedStringKey {
        switch state {
        case .prepared:
            Strings.agentHistoryRecoveryNoticePrepared
        case .authorityConsumed:
            Strings.agentHistoryRecoveryAuthorityConsumed
        case .finalized:
            Strings.agentHistoryRecoveryNoticeFinalized
        case .corrupt:
            Strings.agentHistoryRecoveryNoticeCorrupt
        }
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
