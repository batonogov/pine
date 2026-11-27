//
//  AgentRevisionComparisonView.swift
//  Pine
//
//  Before/after result comparison (#1758): the result the user commented on
//  next to the current one, each shown from a real retained artifact or with
//  an honest gap, a "changed since your feedback" summary, and read-only
//  history. This is display data plus explicit user callbacks: opening it
//  never executes a command and never restores older code.
//

import Foundation
import Observation
import SwiftUI

// MARK: - Presentation

/// One real retained artifact: the example's output from one exact run.
nonisolated struct AgentRevisionOutputCapture: Equatable, Sendable {
    /// The code and environment the output was produced against.
    let candidate: AgentVerificationIdentitySnapshot
    let text: String
    let wasTruncated: Bool
    let exitCode: Int32?
}

/// What one side shows: a kept excerpt, or an honest gap. Never a re-run.
nonisolated enum AgentRevisionSideOutput: Equatable, Sendable {
    case excerpt(AgentRevisionOutputCapture)
    case unavailable(AgentRevisionHistoryGap)
}

/// Display-safe comparison state (#1758).
nonisolated struct AgentRevisionComparisonPresentation: Equatable, Sendable {
    enum UnavailableReason: Equatable, Sendable {
        case noTask, noFeedback, noNewerResult, candidateNotRetained
    }

    enum Content: Equatable, Sendable {
        case unavailable(UnavailableReason)
        case ready(
            AgentRevisionComparison,
            beforeLabel: AgentRevisionSideLabel,
            afterLabel: AgentRevisionSideLabel
        )
    }

    let content: Content
    /// Newest first. Selecting an entry only changes what is shown.
    let history: [AgentFeedbackHistoryEntry]
    let selectedSubmissionID: UUID?
    /// The selected feedback's words and location while they are still live
    /// in this session; `nil` after relaunch.
    let selectedText: String?
    let selectedAnchor: AgentFeedbackLocationAnchor?
    let beforeOutput: AgentRevisionSideOutput?
    let afterOutput: AgentRevisionSideOutput?
    /// Where keyboard focus returns when the surface is reopened.
    let focus: AgentComparisonFocusTarget

    /// Pure derivation from the task's durable records, the outputs kept this
    /// session, and the change rows the owning surface supplies.
    @MainActor
    static func build(
        task: AgentTask?,
        captures: [AgentRevisionOutputCapture],
        changes: [AgentRevisionChangeItem],
        live: [AgentFeedbackSubmission],
        selectedSubmissionID: UUID?,
        focus: AgentComparisonFocusTarget = .comparison
    ) -> AgentRevisionComparisonPresentation {
        let records = task?.feedbackSubmissions ?? []
        let history = records.reversed().map { record in
            AgentFeedbackHistoryEntry(
                record: record, text: live.first { $0.id == record.id }?.reference.userText
            )
        }
        // The newest feedback is compared unless the user picked another one.
        let selected = records.first { $0.id == selectedSubmissionID } ?? records.last
        let selectedLive = selected.flatMap { record in live.first { $0.id == record.id } }
        func presentation(
            _ content: Content,
            beforeOutput: AgentRevisionSideOutput? = nil,
            afterOutput: AgentRevisionSideOutput? = nil
        ) -> AgentRevisionComparisonPresentation {
            AgentRevisionComparisonPresentation(
                content: content,
                history: history,
                selectedSubmissionID: selected?.id,
                selectedText: selectedLive?.reference.userText,
                selectedAnchor: selectedLive?.reference.anchor,
                beforeOutput: beforeOutput,
                afterOutput: afterOutput,
                focus: focus
            )
        }
        guard let task else { return presentation(.unavailable(.noTask)) }
        guard let before = selected?.candidate else {
            return presentation(.unavailable(.noFeedback))
        }
        // The commented result stays identifiable even after its run left the task.
        guard task.runs.contains(where: { $0.id == before.runID }) else {
            return presentation(.unavailable(.candidateNotRetained))
        }
        guard let after = task.feedbackCandidate, after != before else {
            return presentation(.unavailable(.noNewerResult))
        }
        func output(_ candidate: AgentTaskResultSnapshot) -> AgentRevisionSideOutput {
            let kept = candidate.codeState.flatMap { code in
                captures.last {
                    $0.candidate.code == code
                        && $0.candidate.environment == candidate.environment
                }
            }
            // Nothing kept for this exact revision is disclosed, never re-run.
            if let kept {
                return .excerpt(kept)
            }
            return .unavailable(.captureNeverTaken)
        }
        func evidence(_ output: AgentRevisionSideOutput) -> AgentRevisionComparisonEvidence {
            switch output {
            case .excerpt(let capture):
                return .retainedCapture(
                    sha256: AgentHistoryContentHash.sha256Hex(Data(capture.text.utf8)),
                    byteCount: UInt64(capture.text.utf8.count)
                )
            case .unavailable(let gap):
                return .unavailable(gap)
            }
        }
        let beforeOutput = output(before)
        let afterOutput = output(after)
        guard let beforeSide = AgentRevisionComparisonSide(
            candidate: before, evidence: evidence(beforeOutput)
        ), let afterSide = AgentRevisionComparisonSide(
            candidate: after, evidence: evidence(afterOutput)
        ) else {
            return presentation(.unavailable(.noNewerResult))
        }
        let summary = AgentRevisionChangeSummary(
            agentSummary: nil,
            items: Array(changes.prefix(AgentRevisionChangeSummary.maximumItems))
        )
        guard case .success(let comparison) = AgentRevisionComparisonBuilder.build(
            taskID: task.id,
            before: beforeSide,
            after: afterSide,
            feedbackSubmissionID: selected?.id,
            changesSinceFeedback: summary,
            in: task
        ) else {
            return presentation(.unavailable(.noNewerResult))
        }
        return presentation(
            .ready(
                comparison,
                beforeLabel: beforeSide.label(in: task),
                afterLabel: afterSide.label(in: task)
            ),
            beforeOutput: beforeOutput,
            afterOutput: afterOutput
        )
    }
}

// MARK: - Model

/// Owns what the comparison keeps for one task: the outputs retained this
/// session, the read-only history selection, and the place to return to.
@MainActor
@Observable
final class AgentRevisionComparisonModel {
    static let maximumCaptures = 16

    /// The result example's observable run state. A host retains the output
    /// each time it changes, so both sides of a later comparison are real.
    struct OutputSignal: Equatable {
        let identity: AgentVerificationIdentitySnapshot
        let attempts: Int
        let outcome: UserTaskOutcome?

        init?(_ driver: AgentTaskResultActionDriver?) {
            guard let driver else { return nil }
            identity = driver.state.binding.snapshot
            attempts = driver.state.attempts
            outcome = driver.lastOutcome
        }
    }

    private let registry: AgentTaskRegistry
    private let taskID: UUID
    private let changes: [AgentRevisionChangeItem]

    private(set) var outputCaptures: [AgentRevisionOutputCapture] = []
    private(set) var selectedSubmissionID: UUID?
    /// The place to return to when the surface is reopened.
    private(set) var focus: AgentComparisonFocusTarget = .comparison
    @ObservationIgnored private var retainedRuns: [OutputSignal] = []

    init(registry: AgentTaskRegistry, taskID: UUID, changes: [AgentRevisionChangeItem] = []) {
        self.registry = registry
        self.taskID = taskID
        self.changes = changes
    }

    var outputSignal: OutputSignal? { OutputSignal(registry.resultActionDriver(for: taskID)) }

    var presentation: AgentRevisionComparisonPresentation {
        AgentRevisionComparisonPresentation.build(
            task: registry.task(for: taskID),
            captures: outputCaptures,
            changes: changes,
            live: registry.liveFeedbackSubmissions(for: taskID),
            selectedSubmissionID: selectedSubmissionID,
            focus: focus
        )
    }

    /// Read-only history selection: which feedback the comparison is about.
    func select(submissionID: UUID) {
        selectedSubmissionID = submissionID
    }

    /// Records where the user was, so a reopened surface returns there.
    func noteFocus(_ target: AgentComparisonFocusTarget) {
        focus = target
    }

    func retainOutput(_ capture: AgentRevisionOutputCapture) {
        outputCaptures.removeAll { $0.candidate == capture.candidate }
        outputCaptures.append(capture)
        if outputCaptures.count > Self.maximumCaptures {
            outputCaptures.removeFirst()
        }
    }

    /// Retains the example's last output for the exact candidate it ran
    /// against. One entry per run of each revision.
    func retainResultOutput() {
        guard let signal = outputSignal, let outcome = signal.outcome,
              !retainedRuns.contains(signal) else { return }
        retainedRuns.append(signal)
        if retainedRuns.count > Self.maximumCaptures {
            retainedRuns.removeFirst()
        }
        retainOutput(AgentRevisionOutputCapture(
            candidate: signal.identity,
            text: outcome.outputPreview.text,
            wasTruncated: outcome.outputPreview.wasTruncated,
            exitCode: outcome.processExitCode
        ))
    }
}

// MARK: - View

struct AgentRevisionComparisonView: View {
    @Environment(\.locale) private var locale
    @FocusState private var focusedBlock: Block?

    private enum Block: Hashable { case feedback, before, after, changes }

    let model: AgentRevisionComparisonPresentation
    var onSelectFeedback: (UUID) -> Void = { _ in }
    /// Reveals a changed file outside this surface. Pine has no built-in
    /// source viewer; without a handler the row stays descriptive.
    var onInspectChange: ((String) -> Void)?
    var onFocus: (AgentComparisonFocusTarget) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.history.count > 1 { feedbackPicker }
                switch model.content {
                case .unavailable(let reason):
                    Text(verbatim: unavailableText(reason))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AccessibilityID.agentRevisionComparisonUnavailable)
                case .ready(let comparison, let beforeLabel, let afterLabel):
                    feedbackBlock
                    HStack(alignment: .top, spacing: 12) {
                        side(
                            .before,
                            label: beforeLabel,
                            candidate: comparison.before.candidate,
                            output: model.beforeOutput
                        )
                        side(
                            .after,
                            label: afterLabel,
                            candidate: comparison.after.candidate,
                            output: model.afterOutput
                        )
                    }
                    if let summary = comparison.changesSinceFeedback {
                        changesSection(summary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier(AccessibilityID.agentRevisionComparison)
        .onAppear(perform: restoreFocus)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: copy(.comparisonTitle))
                .font(.headline)
            Text(verbatim: copy(.comparisonReadOnly))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var feedbackPicker: some View {
        Picker(copy(.comparisonPickFeedback), selection: Binding(
            get: { model.selectedSubmissionID },
            set: { if let id = $0 { onSelectFeedback(id) } }
        )) {
            ForEach(model.history) { entry in
                Text(verbatim: revisionLabel(entry.candidate))
                    .tag(Optional(entry.id))
            }
        }
        .accessibilityIdentifier(AccessibilityID.agentRevisionComparisonPicker)
    }

    private var feedbackBlock: some View {
        block(.feedback, identifier: AccessibilityID.agentRevisionComparisonFeedback) {
            Text(verbatim: copy(.comparisonFeedbackTitle))
                .font(.subheadline.weight(.semibold))
            if let text = model.selectedText, !text.isEmpty {
                Text(verbatim: text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: copy(.comparisonFeedbackNotRetained))
                    .foregroundStyle(.secondary)
            }
            if let anchor = model.selectedAnchor {
                Text(verbatim: copy(.previewLocation, [anchorLabel(anchor)]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One side of the comparison: its title, label, revision identity, and
    /// either the kept output or the honest gap.
    private func side(
        _ role: Block,
        label: AgentRevisionSideLabel,
        candidate: AgentTaskResultSnapshot?,
        output: AgentRevisionSideOutput?
    ) -> some View {
        block(role, identifier: role == .before
            ? AccessibilityID.agentRevisionComparisonBefore
            : AccessibilityID.agentRevisionComparisonAfter
        ) {
            Text(verbatim: copy(role == .before ? .beforeTitle : .afterTitle))
                .font(.subheadline.weight(.semibold))
            Text(verbatim: labelText(label))
                .font(.caption.weight(.medium))
                .foregroundStyle(label.isReady ? Color.green : Color.secondary)
            Text(verbatim: revisionLabel(candidate))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            outputView(output)
            DisclosureGroup(copy(.identityTitle)) {
                Text(verbatim: identityText(candidate))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func outputView(_ output: AgentRevisionSideOutput?) -> some View {
        switch output {
        case .excerpt(let capture):
            Text(verbatim: copy(.outputCaption, [String(capture.exitCode ?? -1)]))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !capture.text.isEmpty {
                Text(verbatim: capture.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if capture.wasTruncated {
                Text(verbatim: Strings.agentResult(.outputTruncated, locale: locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let gap):
            Text(verbatim: copy(gap == .captureNeverTaken ? .gapCaptureNeverTaken : .gapOther))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.agentRevisionComparisonGap)
        case nil:
            EmptyView()
        }
    }

    private func changesSection(_ summary: AgentRevisionChangeSummary) -> some View {
        block(.changes, identifier: AccessibilityID.agentRevisionComparisonChanges) {
            Text(verbatim: copy(.changesTitle))
                .font(.headline)
            if let agentSummary = summary.agentSummary {
                // An agent-authored summary is a claim; it is never evidence.
                Label(
                    Strings.agentResult(.agentReportedSummary, locale: locale),
                    systemImage: "sparkles"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(verbatim: agentSummary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if summary.items.isEmpty {
                Text(verbatim: copy(.changesNone))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(summary.items.enumerated()), id: \.offset) { _, item in
                    changeRow(item)
                }
            }
        }
    }

    private func changeRow(_ item: AgentRevisionChangeItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: item.relativePath)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            if let statistics = item.statistics {
                Text(verbatim: "+\(statistics.addedLineCount) −\(statistics.removedLineCount)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(verbatim: copy(item.attribution == .verified ? .attributionVerified : .attributionAgentReported))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let onInspectChange {
                Button(copy(.inspectChange)) { onInspectChange(item.relativePath) }
                    .accessibilityIdentifier(
                        AccessibilityID.agentRevisionComparisonInspect(item.relativePath)
                    )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func block<Content: View>(
        _ value: Block,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .focusable()
        .focused($focusedBlock, equals: value)
        .onChange(of: focusedBlock) { _, current in
            guard current == value else { return }
            onFocus(focusTarget(value))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func focusTarget(_ value: Block) -> AgentComparisonFocusTarget {
        switch value {
        case .feedback:
            model.selectedAnchor.map { .feedbackTarget($0) } ?? .comparison
        case .before, .after, .changes:
            .comparison
        }
    }

    /// Keyboard place is restored only when the user left it on the feedback
    /// target; a first open leaves focus to the owning surface.
    private func restoreFocus() {
        if case .feedbackTarget = model.focus {
            focusedBlock = .feedback
        }
    }

    private func copy(_ value: Strings.AgentFeedbackCopy, _ arguments: [String] = []) -> String {
        Strings.agentFeedback(value, arguments: arguments, locale: locale)
    }

    private func unavailableText(
        _ reason: AgentRevisionComparisonPresentation.UnavailableReason
    ) -> String {
        switch reason {
        case .noTask: copy(.comparisonNoTask)
        case .noFeedback: copy(.comparisonNoFeedback)
        case .noNewerResult: copy(.comparisonNoNewer)
        case .candidateNotRetained: copy(.comparisonCandidateGone)
        }
    }

    private func labelText(_ label: AgentRevisionSideLabel) -> String {
        switch label {
        case .checked: Strings.agentResult(.readyTitle, locale: locale)
        case .unverified: Strings.agentResult(.unverifiedTitle, locale: locale)
        case .uncheckedPreview: copy(.sideUncheckedPreview)
        case .unavailable: copy(.sideUnavailable)
        }
    }

    /// Short, stable identity of one revision; see `agentFeedbackRevisionLabel`.
    private func revisionLabel(_ candidate: AgentTaskResultSnapshot?) -> String {
        guard let candidate else { return Strings.agentResult(.unknown, locale: locale) }
        return agentFeedbackRevisionLabel(candidate, locale: locale)
    }

    private func identityText(_ candidate: AgentTaskResultSnapshot?) -> String {
        let unknown = Strings.agentResult(.unknown, locale: locale)
        let code = candidate?.codeState
        return copy(.sideIdentity, [
            code?.headCommit ?? unknown,
            code?.trackedFingerprint ?? unknown,
            code?.untrackedFingerprint ?? unknown,
            code?.ignoredRelevantFingerprint ?? unknown,
        ])
    }

    private func anchorLabel(_ anchor: AgentFeedbackLocationAnchor) -> String {
        switch anchor {
        case let .lineRange(path, start, end): "\(path):\(start)–\(end)"
        case let .outputLines(command, start, end): "\(command):\(start)–\(end)"
        case let .documentSelection(path, _, _): path
        case let .semanticElement(_, identifier): identifier
        case .capturedRegion, .plainText, .unsupported: copy(.locationInText)
        }
    }
}

// MARK: - Host

/// Embeddable comparison for one task. Opening it runs nothing.
///
/// Interaction is implemented end-to-end at contract level; app-surface
/// integration is owned by the Pine 3 workspace composition (#1735/#1760)
/// — no shipped-surface entry point exists yet by design of the stream
/// split.
@MainActor
struct AgentRevisionComparisonHost: View {
    private let taskID: UUID
    private let registry: ProjectRegistry
    private let changes: [AgentRevisionChangeItem]
    private let onInspectChange: ((String) -> Void)?
    @State private var model: AgentRevisionComparisonModel?

    init(
        taskID: UUID,
        registry: ProjectRegistry,
        changes: [AgentRevisionChangeItem] = [],
        onInspectChange: ((String) -> Void)? = nil
    ) {
        self.taskID = taskID
        self.registry = registry
        self.changes = changes
        self.onInspectChange = onInspectChange
    }

    var body: some View {
        Group {
            if let model {
                AgentRevisionComparisonView(
                    model: model.presentation,
                    onSelectFeedback: { model.select(submissionID: $0) },
                    onInspectChange: onInspectChange,
                    onFocus: { model.noteFocus($0) }
                )
                // The example's output is retained as it appears, so a later
                // "before" side is the real output and not a re-run.
                .onChange(of: model.outputSignal, initial: true) { _, _ in
                    model.retainResultOutput()
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if model == nil {
                model = AgentRevisionComparisonModel(
                    registry: registry.agentTasks, taskID: taskID, changes: changes
                )
            }
        }
    }
}
