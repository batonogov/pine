//
//  AgentCompletionBriefView.swift
//  Pine
//
//  Read-only evidence summary for a completed agent session (#1308).
//

import SwiftUI

struct AgentCompletionBriefView: View {
    @Environment(\.locale) private var locale
    let brief: AgentCompletionBrief
    let onReviewChanges: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    changesSection
                    verificationSection
                    commandsSection
                    gapsSection
                    narrativeSection
                }
                .padding(16)
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420)
        .accessibilityIdentifier(AccessibilityID.agentCompletionBrief)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.agentCompletionTitle)
                    .font(.headline)
                Text(verbatim: brief.agentTypeRaw)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.dialogCancel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var changesSection: some View {
        briefSection(Strings.agentCompletionChanges) {
            if brief.changes.isEmpty {
                Text(Strings.agentCompletionNoChanges)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(brief.changes) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: changeIcon(change.kind))
                            .frame(width: 14)
                            .foregroundStyle(.secondary)
                        Text(verbatim: change.relativePath)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        if let statistics = change.statistics {
                            Text(verbatim:
                                "+\(statistics.addedLineCount) −\(statistics.removedLineCount)"
                            )
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }
                        evidenceBadge(change.attribution)
                    }
                    if change.hasOverlappingEdits {
                        Label(
                            Strings.agentCompletionOverlap,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
            if !brief.links.diffPaths.isEmpty, let onReviewChanges {
                Button(Strings.agentHistoryReviewChangesButton) {
                    onReviewChanges()
                }
                .accessibilityIdentifier(
                    AccessibilityID.agentCompletionReviewChanges
                )
            }
        }
    }

    private var verificationSection: some View {
        briefSection(Strings.agentCompletionVerification) {
            Label {
                Text(verbatim: Strings.agentCompletionVerifiedTests(
                    brief.verifiedTestCount,
                    locale: locale
                ))
            } icon: {
                Image(systemName: brief.verifiedTestCount > 0
                    ? "checkmark.circle.fill"
                    : "questionmark.circle")
            }
            .foregroundStyle(brief.verifiedTestCount > 0 ? .green : .secondary)
        }
    }

    private var commandsSection: some View {
        briefSection(Strings.agentCompletionCommands) {
            if brief.commands.isEmpty {
                Text(Strings.agentCompletionNoCommands)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(brief.commands) { command in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: outcomeIcon(command.outcome))
                            .foregroundStyle(outcomeColor(command.outcome))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: command.command)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            HStack(spacing: 6) {
                                evidenceBadge(command.attribution)
                                Text(verbatim: command.source)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var gapsSection: some View {
        if !brief.gaps.isEmpty {
            briefSection(Strings.agentCompletionGaps) {
                ForEach(Array(brief.gaps.enumerated()), id: \.offset) { _, gap in
                    Label {
                        Text(verbatim: gapText(gap))
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var narrativeSection: some View {
        if let narrative = brief.narrative {
            briefSection(Strings.agentCompletionAgentReport) {
                evidenceBadge(narrative.attribution)
                Text(verbatim: narrative.text)
                    .textSelection(.enabled)
            }
        }
    }

    private func briefSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func evidenceBadge(
        _ level: AgentCompletionEvidenceLevel
    ) -> some View {
        Text(verbatim: evidenceText(level))
            .font(.caption2.weight(.medium))
            .foregroundStyle(level == .verified ? .green : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private func evidenceText(_ level: AgentCompletionEvidenceLevel) -> String {
        switch level {
        case .verified: Strings.agentActivityAttributionVerified
        case .inferred: Strings.agentActivityAttributionInferred
        case .ambiguous: Strings.agentActivityAttributionAmbiguous
        case .observed: Strings.agentCompletionObserved(locale: locale)
        case .agentReported: Strings.agentCompletionAgentReported(locale: locale)
        }
    }

    private func gapText(_ gap: AgentCompletionGap) -> String {
        switch gap {
        case .provenanceUnavailable:
            Strings.agentCompletionGapProvenance(locale: locale)
        case .provenanceRecoveredWithLoss:
            Strings.agentCompletionGapRecovered(locale: locale)
        case .noVerifiedChanges:
            Strings.agentCompletionGapChanges(locale: locale)
        case .noStructuredCommands:
            Strings.agentCompletionGapCommands(locale: locale)
        case .noVerifiedTests:
            Strings.agentCompletionGapTests(locale: locale)
        case .diffStatisticsUnavailable(let paths):
            Strings.agentCompletionGapStatistics(paths.count, locale: locale)
        case .overlappingEdits(let paths):
            Strings.agentCompletionGapOverlaps(paths.count, locale: locale)
        }
    }

    private func changeIcon(_ kind: AgentCompletionChangeKind) -> String {
        switch kind {
        case .modified: "pencil"
        case .created: "plus.circle"
        case .deleted: "minus.circle"
        case .renamed: "arrow.right"
        case .unknown: "questionmark.circle"
        }
    }

    private func outcomeIcon(_ outcome: AgentCompletionCommandOutcome) -> String {
        switch outcome {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func outcomeColor(
        _ outcome: AgentCompletionCommandOutcome
    ) -> Color {
        switch outcome {
        case .succeeded: .green
        case .failed: .red
        case .unknown: .secondary
        }
    }
}
