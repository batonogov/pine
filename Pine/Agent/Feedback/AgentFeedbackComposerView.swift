//
//  AgentFeedbackComposerView.swift
//  Pine
//
//  Revision-bound feedback composition surface (#1758) and its embeddable
//  host. The view renders a presentation value and reports intent through
//  callbacks; it never sends anything by itself.
//

import AppKit
import Foundation
import SwiftUI

/// Short, stable identity of one revision: the tracked fingerprint's prefix
/// and the time it was recorded.
@MainActor
func agentFeedbackRevisionLabel(_ candidate: AgentTaskResultSnapshot, locale: Locale) -> String {
    let code = candidate.codeState?.trackedFingerprint.prefix(8)
        ?? Substring(Strings.agentResult(.unknown, locale: locale))
    let recorded = candidate.recordedAt.formatted(
        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
    )
    return "\(code) · \(recorded)"
}

extension AgentFeedbackDeliveryState {
    /// The one caption that keeps queued, delivered, failed, cancelled, and
    /// unconfirmed delivery distinguishable.
    var feedbackCopy: Strings.AgentFeedbackCopy {
        switch self {
        case .queued: .stateQueued
        case .delivered: .stateDelivered
        case .failed: .stateFailed
        case .cancelled: .stateCancelled
        case .deliveryUnknown: .stateDeliveryUnknown
        }
    }
}

struct AgentFeedbackComposerView: View {
    @Environment(\.locale) private var locale
    @State private var showsPreview = true

    let model: AgentFeedbackComposerPresentation
    var onTextChange: (String) -> Void = { _ in }
    var onSelectAnchor: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onSendTextOnly: () -> Void = {}
    var onCancelSend: () -> Void = {}
    var onUseLatest: () -> Void = {}
    var onRemoveAttachment: (UUID) -> Void = { _ in }
    var onRetry: ((UUID) -> Void)?
    /// Opens the comparison for one earlier feedback.
    var onCompare: ((UUID) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.availability == .available { composer }
                if let failure = model.failure { failureView(failure) }
                if !model.history.isEmpty { history }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 240)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.agentFeedbackComposer)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: copy(.composerTitle))
                .font(.headline)
            if let candidate = model.candidate {
                Text(verbatim: copy(.aboutRevision, [revisionLabel(candidate)]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.agentFeedbackBoundRevision)
            }
            if !model.recipientName.isEmpty {
                Label(copy(.sendsTo, [model.recipientName]), systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.agentFeedbackRecipient)
            }
            availabilityView
            freshnessView
        }
    }

    @ViewBuilder
    private var availabilityView: some View {
        switch model.availability {
        case .noResult:
            Text(verbatim: copy(.noResult))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .noRoute:
            Text(verbatim: copy(.noRoute))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .available:
            if !model.recipientIsReachable {
                Text(verbatim: copy(.recipientUnreachable, [model.recipientName]))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var freshnessView: some View {
        if case .superseded = model.freshness {
            freshnessCard(.freshnessSuperseded)
        } else if case .historical = model.freshness {
            freshnessCard(.freshnessHistorical)
        }
    }

    private func freshnessCard(_ text: Strings.AgentFeedbackCopy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: copy(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(copy(.useLatest), action: onUseLatest)
                .disabled(model.isSending)
                .accessibilityIdentifier(AccessibilityID.agentFeedbackUseLatest)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.agentFeedbackFreshness)
    }

    // MARK: - Draft

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(copy(.location), selection: Binding(
                get: { model.selectedAnchorPath },
                set: { onSelectAnchor($0) }
            )) {
                ForEach(model.anchorOptions) { option in
                    Text(verbatim: locationLabel(option.path))
                        .tag(option.path)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .disabled(model.isSending)
            .accessibilityIdentifier(AccessibilityID.agentFeedbackLocation)

            if model.anchorResolution == .targetMissing {
                Text(verbatim: copy(.locationMissingDetail))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.attachments) { notice in
                        attachmentRow(notice)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.agentFeedbackAttachments)
            }

            TextField(copy(.textPlaceholder), text: Binding(
                get: { model.text },
                set: { onTextChange($0) }
            ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .disabled(model.isSending)
                .accessibilityIdentifier(AccessibilityID.agentFeedbackText)
            Text(verbatim: copy(.visualUnsupported))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            preview
            buttons
        }
    }

    private func attachmentRow(_ notice: AgentFeedbackComposerPresentation.AttachmentNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.attachment.kind == .image ? "photo" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: attachmentText(notice))
                .font(.caption)
                .foregroundStyle(notice.rejection == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(copy(.removeAttachment)) { onRemoveAttachment(notice.id) }
                .disabled(model.isSending)
                .accessibilityIdentifier(AccessibilityID.agentFeedbackRemoveAttachment(notice.id))
        }
    }

    /// The transmission preview: who receives it, about which revision, and
    /// which location and attachments go with it.
    private var preview: some View {
        DisclosureGroup(isExpanded: $showsPreview) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: copy(.sendsTo, [model.recipientName]))
                if let candidate = model.candidate {
                    Text(verbatim: copy(.aboutRevision, [revisionLabel(candidate)]))
                }
                if !model.selectedAnchorPath.isEmpty {
                    Text(verbatim: copy(.previewLocation, [locationLabel(model.selectedAnchorPath)]))
                }
                Text(verbatim: copy(
                    model.attachments.isEmpty ? .previewAttachmentsNone : .previewAttachmentsCount,
                    model.attachments.isEmpty ? [] : [String(model.attachments.count)]
                ))
                if !model.attachmentsAreSupported {
                    Text(verbatim: copy(.textOnlyNotice))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text(verbatim: copy(.previewTitle))
                .font(.subheadline.weight(.medium))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.agentFeedbackPreview)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .idle:
                // "Send text only" is the default exactly when the gate
                // rejects an attachment; a fully accepted draft sends whole.
                if model.attachmentsAreSupported {
                    Button(copy(.send)) { onSend() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSend)
                        .accessibilityIdentifier(AccessibilityID.agentFeedbackSend)
                } else {
                    Button(copy(.sendTextOnly)) { onSendTextOnly() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSendTextOnly)
                        .accessibilityIdentifier(AccessibilityID.agentFeedbackSendTextOnly)
                }
            case .recording:
                sendingIndicator
                Spacer()
                // Nothing was dispatched yet, so this cancel is confirmed.
                Button(Strings.agentResult(.cancel, locale: locale)) { onCancelSend() }
                    .accessibilityIdentifier(AccessibilityID.agentFeedbackCancel)
            case .dispatching:
                sendingIndicator
            }
        }
    }

    private var sendingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(verbatim: copy(.sending))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func failureView(_ failure: AgentFeedbackComposerPresentation.Failure) -> some View {
        Text(verbatim: copy(failureText(failure)))
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.agentFeedbackFailure)
    }

    // MARK: - History

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: copy(.historyTitle))
                .font(.headline)
            ForEach(model.history) { entry in
                historyRow(entry)
            }
            Text(verbatim: copy(.historyPrivacy))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.agentFeedbackHistory)
    }

    private func historyRow(_ entry: AgentFeedbackHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.submittedAt, format: .dateTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: copy(entry.state.feedbackCopy))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(deliveryColor(entry.state))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                resolutionText(entry.resolution)
            }
            if let detail = deliveryDetail(entry.state) {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if case .failed = entry.state {
                    Button(copy(.retry)) { onRetry?(entry.id) }
                        // A relaunched failed row has no live words to resend;
                        // the failedDetail caption explains why.
                        .disabled(model.isSending || !model.recipientIsReachable
                            || entry.text == nil || onRetry == nil)
                        .accessibilityIdentifier(AccessibilityID.agentFeedbackRetry(entry.id))
                }
                if let onCompare {
                    Button(copy(.compare)) { onCompare(entry.id) }
                        .accessibilityIdentifier(AccessibilityID.agentFeedbackCompare(entry.id))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.agentFeedbackHistoryRow(entry.id))
    }

    /// An agent's "addressed" claim is its own state: it is never shown as a
    /// passing check, a Ready result, or the user's acceptance.
    @ViewBuilder
    private func resolutionText(_ resolution: AgentFeedbackResolution) -> some View {
        switch resolution {
        case .unresolved:
            Text(verbatim: copy(.resolutionUnresolved))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .agentReportedAddressed:
            Label(copy(.resolutionAddressed), systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .acceptedByUser:
            Text(verbatim: copy(.resolutionAccepted))
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    // MARK: - Copy

    private func copy(_ value: Strings.AgentFeedbackCopy, _ arguments: [String] = []) -> String {
        Strings.agentFeedback(value, arguments: arguments, locale: locale)
    }

    private func failureText(_ failure: AgentFeedbackComposerPresentation.Failure) -> Strings.AgentFeedbackCopy {
        switch failure {
        case .duplicate: .failureDuplicate
        case .notReady: .failureNotReady
        case .limitReached: .failureLimit
        case .notDurable: .failureNotDurable
        case .unavailable: .failureUnavailable
        }
    }

    private func deliveryColor(_ state: AgentFeedbackDeliveryState) -> Color {
        switch state {
        case .delivered: .green
        case .failed: .red
        case .queued, .deliveryUnknown: .orange
        case .cancelled: .secondary
        }
    }

    /// Why a delivery stopped, in the state's own words. A green Delivered
    /// chip never overstates delivery: attachments the transport did not
    /// carry are named.
    private func deliveryDetail(_ state: AgentFeedbackDeliveryState) -> String? {
        switch state {
        case .failed(let failure):
            let reason: Strings.AgentFeedbackCopy = failure == .providerRejected
                ? .failureProvider : .failureTransport
            return copy(reason) + " " + copy(.failedDetail)
        case .delivered(let outcome):
            guard !outcome.isComplete else { return nil }
            return copy(.deliveredAttachmentsOmitted, [
                String(outcome.undeliveredAttachmentIDs.count),
            ])
        case .deliveryUnknown:
            return copy(.unknownDetail)
        case .queued, .cancelled:
            return nil
        }
    }

    private func attachmentText(_ notice: AgentFeedbackComposerPresentation.AttachmentNotice) -> String {
        guard let rejection = notice.rejection else {
            return copy(.attachmentWillSend, [notice.attachment.label])
        }
        // A user-chosen omission is never produced by the pre-send gate.
        let reason: Strings.AgentFeedbackCopy = switch rejection {
        case .unsupportedKind, .omittedByUserChoice: .reasonUnsupportedKind
        case .exceedsByteLimit: .reasonExceedsLimit
        case .invalidAttachment: .reasonInvalid
        }
        return copy(.attachmentKept, [notice.attachment.label, copy(reason)])
    }

    private func locationLabel(_ path: String) -> String {
        if path.isEmpty { return copy(.locationInText) }
        if model.anchorOptions.first(where: { $0.path == path })?.isMissing == true {
            return copy(.locationMissing, [path])
        }
        return path
    }

    private func revisionLabel(_ candidate: AgentTaskResultSnapshot) -> String {
        agentFeedbackRevisionLabel(candidate, locale: locale)
    }
}

// MARK: - Host

extension AgentFeedbackRoute {
    /// The task's owning OpenCode session: the channel the Needs-decision
    /// reply already uses. Any other agent has no feedback route yet.
    static func openCode(registry: ProjectRegistry, taskID: UUID) -> AgentFeedbackRoute? {
        guard let task = registry.agentTasks.task(for: taskID),
              task.descriptor.agentType == .openCode else { return nil }
        return AgentFeedbackRoute(
            agentName: task.descriptor.agentType.displayName,
            isReachable: { registry.openCodeRuntime(for: taskID)?.isActive == true },
            dispatch: { request in
                guard let runtime = registry.openCodeRuntime(for: request.taskID) else {
                    throw AgentFeedbackDeliveryFailure.transportUnavailable
                }
                let receipt: AgentFeedbackDeliveryReceipt? =
                    try await runtime.submit(request.instruction) == .acknowledged
                        ? AgentFeedbackDeliveryReceipt(submissionID: request.submissionID)
                        : nil
                return receipt
            }
        )
    }
}

/// Embeddable feedback composer for one task:
/// `AgentFeedbackComposerHost(taskID:registry:)`. Opening it sends nothing.
///
/// Interaction is implemented end-to-end at contract level; app-surface
/// integration is owned by the Pine 3 workspace composition (#1735/#1760)
/// — no shipped-surface entry point exists yet by design of the stream
/// split.
@MainActor
struct AgentFeedbackComposerHost: View {
    @Environment(\.locale) private var locale
    private let taskID: UUID
    private let registry: ProjectRegistry
    private let changes: [AgentRevisionChangeItem]
    private let onCompare: ((UUID) -> Void)?
    @State private var model: AgentFeedbackComposerModel?

    init(
        taskID: UUID,
        registry: ProjectRegistry,
        changes: [AgentRevisionChangeItem] = [],
        onCompare: ((UUID) -> Void)? = nil
    ) {
        self.taskID = taskID
        self.registry = registry
        self.changes = changes
        self.onCompare = onCompare
    }

    var body: some View {
        Group {
            if let model {
                composer(model)
                    .onChange(of: model.signal, initial: true) { _, _ in model.sync() }
                    // VoiceOver hears a delivery settle without hunting for it.
                    .onChange(of: model.presentation.history.first?.state) { _, state in
                        guard let state else { return }
                        NSAccessibility.post(
                            element: NSApp.keyWindow ?? NSApplication.shared,
                            notification: .announcementRequested,
                            userInfo: [
                                .announcement: Strings.agentFeedback(state.feedbackCopy, locale: locale),
                                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                            ]
                        )
                    }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if model == nil {
                model = AgentFeedbackComposerModel(
                    registry: registry.agentTasks,
                    taskID: taskID,
                    route: AgentFeedbackRoute.openCode(registry: registry, taskID: taskID),
                    changes: changes
                )
            }
        }
    }

    private func composer(_ model: AgentFeedbackComposerModel) -> some View {
        AgentFeedbackComposerView(
            model: model.presentation,
            onTextChange: { model.text = $0 },
            onSelectAnchor: { model.selectAnchor(path: $0) },
            onSend: { Task { await model.send(textOnly: false) } },
            onSendTextOnly: { Task { await model.send(textOnly: true) } },
            onCancelSend: { model.cancelSend() },
            onUseLatest: { model.retargetToLatest() },
            onRemoveAttachment: { model.detach(attachmentID: $0) },
            onRetry: { id in
                Task {
                    if let entry = model.presentation.history.first(where: { $0.id == id }) {
                        await model.retry(entry)
                    }
                }
            },
            onCompare: onCompare
        )
    }
}
