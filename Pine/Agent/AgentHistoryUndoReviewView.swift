//
//  AgentHistoryUndoReviewView.swift
//  Pine
//
//  Read-only, verified undo review sheet for Agent History (#1237).
//
//  Replaces the legacy one-line confirmation alert with a progressive-disclosure
//  preview: the primary area shows each file, its operation type, and a
//  human-readable diff; hashes, file modes, byte counts, and identities live
//  under a collapsed "Technical Details" section. Undo is disabled until a
//  fresh revalidation passes, and Cancel performs no filesystem mutation.
//

import SwiftUI

/// Sheet that prepares a verified undo preview, shows it read-only, and applies
/// the undo only after an immediate revalidation succeeds.
struct AgentHistoryUndoReviewView: View {
    @Bindable var store: AgentHistoryStore
    let entry: AgentHistoryEntry
    @Binding var isPresented: Bool
    var onComplete: (AgentHistoryRevertResult) -> Void

    @State private var preparation: AgentHistoryUndoPreviewResult?
    @State private var isPreparing = true
    @State private var revalidation: AgentHistoryUndoPreviewResult?
    @State private var isRevalidating = false
    @State private var isApplying = false
    @State private var applyResult: AgentHistoryRevertResult?

    private var previewModel: AgentHistoryUndoPreviewModel? {
        if case .available(let model) = preparation {
            return model
        }
        return nil
    }

    private var canApply: Bool {
        guard !isPreparing,
              !isRevalidating,
              !isApplying,
              applyResult == nil,
              case .available = revalidation else {
            return false
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let failure = currentFailure {
                Divider()
                unavailableBanner(failure)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            await loadPreview()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
                .accessibilityHidden(true)
            Text(Strings.agentHistoryUndoReviewTitle)
                .font(.headline)
            Spacer()
            if isPreparing || isRevalidating || isApplying {
                ProgressView()
                    .controlSize(.small)
            }
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isPreparing {
            loadingPlaceholder
        } else if let model = previewModel, applyResult == nil {
            previewBody(model)
        } else if let result = applyResult {
            applyOutcomeView(result)
        } else if let failure = currentFailure {
            unavailableDetailView(failure)
        } else {
            loadingPlaceholder
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(Strings.agentHistoryUndoReviewPreparing)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewBody(
        _ model: AgentHistoryUndoPreviewModel
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                summaryHeader(model)
                Divider().opacity(0.3)
                ForEach(
                    Array(model.operations.enumerated()),
                    id: \.element.id
                ) { index, operation in
                    operationView(operation)
                    if index < model.operations.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Summary

    private func summaryHeader(
        _ model: AgentHistoryUndoPreviewModel
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .accessibilityHidden(true)
            Text(Strings.agentHistoryUndoReviewVerified)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(summaryText(model))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier(
            AccessibilityID.agentHistoryUndoReviewSummary
        )
    }

    private func summaryText(
        _ model: AgentHistoryUndoPreviewModel
    ) -> String {
        let opCount = model.operations.count
        let added = model.totalAddedLines
        let removed = model.totalRemovedLines
        return "\(opCount) \(opCount == 1 ? "file" : "files")  +\(added) −\(removed)"
    }

    // MARK: - Operation

    private func operationView(
        _ operation: AgentHistoryUndoPreviewOperation
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            operationHeader(operation)
            operationSummary(operation)
            if !operation.hunks.isEmpty {
                ForEach(operation.hunks) { hunk in
                    hunkView(hunk)
                }
            }
            DisclosureGroup(
                isExpanded: technicalDetailsBinding(operation.id)
            ) {
                technicalDetails(operation)
            } label: {
                Text(Strings.agentHistoryUndoReviewTechnicalDetails)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            AccessibilityID.agentHistoryUndoReviewOperation(
                operation.relativePath
            )
        )
    }

    private func operationHeader(
        _ operation: AgentHistoryUndoPreviewOperation
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: operation.kind.systemImage)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(operation.kind.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: operation.relativePath)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if operation.addedLineCount > 0 || operation.removedLineCount > 0 {
                Text(verbatim: "+\(operation.addedLineCount) −\(operation.removedLineCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func operationSummary(
        _ operation: AgentHistoryUndoPreviewOperation
    ) -> some View {
        Text(operation.kind.detailText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 18)
    }

    // MARK: - Hunks

    private func hunkView(
        _ hunk: AgentHistoryUndoPreviewHunk
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: hunk.header)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(hunk.lines) { line in
                lineView(line)
            }
        }
        .padding(.leading, 18)
    }

    private func lineView(
        _ line: AgentHistoryUndoPreviewHunk.Line
    ) -> some View {
        let prefix: String
        let color: Color
        switch line.kind {
        case .context: prefix = " "; color = .secondary
        case .remove: prefix = "-"; color = .red
        case .add: prefix = "+"; color = .green
        }
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: prefix)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(verbatim: line.text)
                .foregroundStyle(color)
        }
        .font(.system(size: 12, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityLabel(Text(verbatim: prefix + line.text))
    }

    // MARK: - Technical details

    private func technicalDetails(
        _ operation: AgentHistoryUndoPreviewOperation
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let sha = operation.expectedContentSHA256 {
                identityRow(
                    label: String(localized: "agentHistory.undoReview.expected"),
                    path: operation.relativePath,
                    sha: sha,
                    byteCount: operation.expectedByteCount,
                    permissions: operation.expectedPermissions
                )
            }
            if let sha = operation.resultContentSHA256 {
                identityRow(
                    label: String(localized: "agentHistory.undoReview.result"),
                    path: operation.relativePath,
                    sha: sha,
                    byteCount: operation.resultByteCount,
                    permissions: operation.resultPermissions
                )
            }
        }
        .padding(.leading, 18)
        .padding(.top, 2)
    }

    private func identityRow(
        label: String,
        path: String,
        sha: String,
        byteCount: UInt64?,
        permissions: UInt16?
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(label): \(path)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Text(verbatim: "SHA-256 \(sha)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if let byteCount {
                Text(verbatim: "bytes \(byteCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if let permissions {
                Text(verbatim: "mode \(String(format: "%04o", Int(permissions)))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Unavailable / stale

    private var currentFailure: AgentHistoryUndoPreviewFailure? {
        if let result = revalidation, case .unavailable(let failure) = result {
            return failure
        }
        if let result = preparation, case .unavailable(let failure) = result {
            return failure
        }
        return nil
    }

    private func unavailableBanner(
        _ failure: AgentHistoryUndoPreviewFailure
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.agentHistoryUndoReviewStaleTitle)
                    .font(.system(size: 12, weight: .semibold))
                Text(failure.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
        .accessibilityIdentifier(
            AccessibilityID.agentHistoryUndoReviewStale
        )
    }

    private func unavailableDetailView(
        _ failure: AgentHistoryUndoPreviewFailure
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(Strings.agentHistoryUndoReviewStaleTitle)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(failure.explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(failure.nextAction)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Apply outcome

    private func applyOutcomeView(
        _ result: AgentHistoryRevertResult
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: result.allSucceeded
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(result.allSucceeded ? .green : .orange)
            Text(result.allSucceeded
                ? Strings.agentHistoryCheckedRevertSuccess
                : Strings.agentHistoryRevertPartialFailure)
                .font(.headline)
            if let backup = result.recoveryBackupPath {
                Text(Strings.agentHistoryRecoveryBackup(backup))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case .available = revalidation {
                Label {
                    Text(Strings.agentHistoryUndoReviewRevalidated)
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "checkmark.shield.fill")
                }
                .foregroundStyle(.green)
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Text(applyResult != nil
                    ? Strings.dialogClose : Strings.dialogCancel)
            }
            .keyboardShortcut(.cancelAction)

            if applyResult == nil && previewModel != nil {
                Button {
                    Task { await applyUndo() }
                } label: {
                    Text(Strings.agentHistoryUndoReviewApply)
                }
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
                .accessibilityIdentifier(
                    AccessibilityID.agentHistoryUndoReviewApply
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func loadPreview() async {
        isPreparing = true
        preparation = await store.prepareVerifiedUndoPreview(for: entry)
        isPreparing = false
    }

    private func applyUndo() async {
        guard previewModel != nil else { return }
        isRevalidating = true
        revalidation = await store.revalidateVerifiedUndoPreview(for: entry)
        isRevalidating = false
        guard case .available = revalidation else { return }
        isApplying = true
        let result = await store.revert(entry: entry)
        applyResult = result
        isApplying = false
        onComplete(result)
    }

    // MARK: - Collapsible technical-details state

    @State private var expandedTechnicalDetails: Set<String> = []

    private func technicalDetailsBinding(
        _ id: String
    ) -> Binding<Bool> {
        Binding(
            get: { expandedTechnicalDetails.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedTechnicalDetails.insert(id)
                } else {
                    expandedTechnicalDetails.remove(id)
                }
            }
        )
    }
}

// MARK: - Operation presentation

extension AgentHistoryUndoPreviewOperation.Kind {
    var systemImage: String {
        switch self {
        case .restoreModifiedFile: "arrow.uturn.backward"
        case .removeCreatedFile: "trash"
        case .restoreDeletedFile: "arrow.uturn.backward.circle"
        }
    }

    var displayName: String {
        switch self {
        case .restoreModifiedFile:
            String(localized: "agentHistory.undoReview.kind.restore")
        case .removeCreatedFile:
            String(localized: "agentHistory.undoReview.kind.remove")
        case .restoreDeletedFile:
            String(localized: "agentHistory.undoReview.kind.recreate")
        }
    }

    var detailText: String {
        switch self {
        case .restoreModifiedFile:
            String(localized: "agentHistory.undoReview.detail.restore")
        case .removeCreatedFile:
            String(localized: "agentHistory.undoReview.detail.remove")
        case .restoreDeletedFile:
            String(localized: "agentHistory.undoReview.detail.recreate")
        }
    }
}

// MARK: - Failure presentation

extension AgentHistoryUndoPreviewFailure {
    var explanation: String {
        switch self {
        case .entryNotFound:
            Strings.undoFailEntryNotFound
        case .alreadyReverted:
            Strings.undoFailAlreadyReverted
        case .notEligible:
            Strings.undoFailNotEligible
        case .authorityRecordMissing:
            Strings.undoFailAuthorityMissing
        case .authorityConsumed:
            Strings.undoFailAuthorityConsumed
        case .workspaceChanged:
            Strings.undoFailWorkspaceChanged
        case .projectionTampered:
            Strings.undoFailProjectionTampered
        case .inversePayloadMissing:
            Strings.undoFailPayloadMissing
        case .currentContentDiverged(let path):
            Strings.undoFailContentDiverged(path)
        case .previewEncodingFailed:
            Strings.undoFailPreviewFailed
        }
    }

    var nextAction: String {
        switch self {
        case .entryNotFound, .alreadyReverted, .authorityConsumed:
            Strings.agentHistoryUndoReviewNextClose
        case .notEligible, .projectionTampered, .previewEncodingFailed:
            Strings.agentHistoryUndoReviewNextNoAction
        case .authorityRecordMissing, .inversePayloadMissing:
            Strings.agentHistoryUndoReviewNextNoAction
        case .workspaceChanged:
            Strings.agentHistoryUndoReviewNextRefresh
        case .currentContentDiverged:
            Strings.agentHistoryUndoReviewNextManualReview
        }
    }
}
