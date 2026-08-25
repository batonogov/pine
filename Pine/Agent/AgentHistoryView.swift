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
    let onOpenBrief: ((AgentHistoryRow) -> Void)?
    let onRevert: (AgentHistoryRow) -> Void

    init(
        rows: [AgentHistoryRow],
        onOpenBrief: ((AgentHistoryRow) -> Void)? = nil,
        onRevert: @escaping (AgentHistoryRow) -> Void
    ) {
        self.rows = rows
        self.onOpenBrief = onOpenBrief
        self.onRevert = onRevert
    }

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
                        AgentHistoryRowView(
                            row: row,
                            onOpenBrief: onOpenBrief,
                            onRevert: onRevert
                        )
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
    let onOpenBrief: ((AgentHistoryRow) -> Void)?
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

            if let onOpenBrief {
                Button {
                    onOpenBrief(row)
                } label: {
                    Label(
                        Strings.agentCompletionShowButton,
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .controlSize(.small)
                .accessibilityIdentifier(
                    AccessibilityID.agentCompletionShowButton
                )
            }

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
                        Text(Strings.agentHistoryReviewChangesButton)
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
        .accessibilityElement(children: .contain)
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

/// Sheet wrapper that binds to the live `AgentHistoryStore`, computes rows,
/// and opens the verified undo review before any mutation (#1237).
struct AgentHistoryView: View {
    @Environment(\.locale) private var locale
    @Bindable var store: AgentHistoryStore
    @Binding var isPresented: Bool
    let activities: [AgentAction]?
    @State private var reviewTarget: AgentHistoryEntry?
    @State private var completionBrief: AgentCompletionBrief?
    @State private var revertResult: AgentHistoryRevertResult?

    init(
        store: AgentHistoryStore,
        isPresented: Binding<Bool>,
        activities: [AgentAction]? = nil
    ) {
        self.store = store
        _isPresented = isPresented
        self.activities = activities
    }

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
            AgentHistoryList(
                rows: rows,
                onOpenBrief: activities == nil ? nil : { row in
                    openCompletionBrief(for: row)
                },
                onRevert: { row in
                    openReview(for: row)
                }
            )
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
        .sheet(item: $reviewTarget) { entry in
            AgentHistoryUndoReviewView(
                store: store,
                entry: entry,
                isPresented: Binding(
                    get: { reviewTarget != nil },
                    set: { if !$0 { reviewTarget = nil } }
                )
            ) { result in
                revertResult = result
            }
        }
        .sheet(item: $completionBrief) { brief in
            AgentCompletionBriefView(
                brief: brief,
                onReviewChanges: brief.links.diffPaths.isEmpty ? nil : {
                    openReviewFromCompletionBrief(brief)
                },
                onDismiss: { completionBrief = nil }
            )
        }
    }

    /// Opens the verified undo review sheet for the entry behind a row.
    /// Preparing the preview performs no filesystem mutation; the undo itself
    /// only runs after the user confirms inside the review and a fresh
    /// revalidation passes (#1237).
    private func openReview(for row: AgentHistoryRow) {
        guard let entry = store.entries.first(where: {
            $0.id == row.id
        }) else {
            return
        }
        reviewTarget = entry
    }

    private func openCompletionBrief(for row: AgentHistoryRow) {
        guard let entry = store.entries.first(where: { $0.id == row.id }) else {
            return
        }
        let activities = activities ?? []
        Task { @MainActor in
            let preview = await store.prepareVerifiedUndoPreview(for: entry)
            let previewModel: AgentHistoryUndoPreviewModel? = switch preview {
            case .available(let model): model
            case .unavailable: nil
            }
            guard store.entries.contains(where: { $0.id == entry.id }) else {
                return
            }
            completionBrief = AgentCompletionBriefBuilder.build(
                entry: entry,
                evidence: AgentCompletionBriefEvidence(
                    activities: activities,
                    verifiedUndoPreview: previewModel
                )
            )
        }
    }

    private func openReviewFromCompletionBrief(
        _ brief: AgentCompletionBrief
    ) {
        completionBrief = nil
        guard let entry = store.entries.first(where: { $0.id == brief.id }) else {
            return
        }
        DispatchQueue.main.async {
            reviewTarget = entry
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
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(
                Text(verbatim: AgentReadOnlySheetChrome.closeLabel(
                    locale: locale
                ))
            )
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
                    Text(
                        verbatim: Strings.agentHistoryRecoveryBackup(
                            recoveryBackupPath,
                            locale: locale
                        )
                    )
                        .textSelection(.enabled)
                }
                ForEach(
                    result.recoveryQuarantinePaths,
                    id: \.self
                ) { path in
                    Text(
                        verbatim: Strings.agentHistoryRetainedRecoveryFile(
                            path,
                            locale: locale
                        )
                    )
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
    @Environment(\.locale) private var locale
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
            Text(Self.statusText(for: record.state))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            recoveryPathRow(
                text: Strings.agentHistoryRecoveryBackup(
                    record.directoryPath,
                    locale: locale
                ),
                path: record.directoryPath,
                isValidated: record.validatedPaths.contains(
                    record.directoryPath
                )
            )
            ForEach(record.recoveryPaths.prefix(8), id: \.self) { path in
                recoveryPathRow(
                    text: Strings.agentHistoryRetainedRecoveryFile(
                        path,
                        locale: locale
                    ),
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

    /// Not `private`: the discovery state is the only thing this row says
    /// about *why* a recovery record is being shown, and all seven corruption
    /// reasons used to arrive here as one sentence (#1541). Static and
    /// internal so every reason can be enumerated by a test rather than
    /// inspected on screen.
    static func statusText(
        for state: AgentHistoryRecoveryDiscoveryState
    ) -> LocalizedStringKey {
        switch state {
        case .prepared:
            Strings.agentHistoryRecoveryNoticePrepared
        case .authorityConsumed:
            Strings.agentHistoryRecoveryAuthorityConsumed
        case .finalized:
            Strings.agentHistoryRecoveryNoticeFinalized
        case .corrupt(let corruption):
            Strings.agentHistoryRecoveryCorruption(corruption)
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
