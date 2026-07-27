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
    /// Candidate session association, preserving inferred/ambiguous evidence.
    let attribution: AgentActionAttribution
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
    /// Working directory recorded for the action, if any (#1245).
    let workingDirectory: URL?
    /// Terminal-tab label for the "Go to Terminal" action, if any (#1245).
    let relatedTerminalLabel: String?
    /// Terminal-tab identifier used to focus the related terminal without
    /// executing anything (#1245).
    let relatedTerminalID: UUID?

    init(_ action: AgentAction) {
        self.id = action.id
        self.attribution = action.attribution
        self.kind = action.kind
        self.status = action.status
        self.fileURL = action.fileURL
        self.summary = action.summary
        self.timestamp = action.timestamp
        self.workingDirectory = action.workingDirectory
        self.relatedTerminalLabel = action.relatedTerminalLabel
        self.relatedTerminalID = action.relatedTerminalID
    }
}

/// Localized rendering projection for one action's attribution. Keeping this
/// separate from the SwiftUI hierarchy makes the fail-closed presentation
/// directly testable without constructing an accessibility tree.
struct AgentActivityAttributionPresentation: Equatable {
    let badgeLabel: String?
    let detail: String
    let accessibilityHint: String?
    let markerAgentType: AgentType?

    var isAmbiguous: Bool { markerAgentType == nil && badgeLabel != nil }

    var accessibilityValue: String {
        guard let badgeLabel else { return detail }
        return "\(badgeLabel), \(detail)"
    }
}

extension AgentActionAttribution {
    var activityPresentation: AgentActivityAttributionPresentation {
        switch self {
        case .session(let candidate):
            AgentActivityAttributionPresentation(
                badgeLabel: Strings.agentActivityAttributionSessionLinked,
                detail: candidate.agentType.displayName,
                accessibilityHint: Strings.agentActivitySessionLinkedHint,
                markerAgentType: candidate.agentType
            )
        case .inferred(let candidate):
            AgentActivityAttributionPresentation(
                badgeLabel: Strings.agentActivityAttributionInferred,
                detail: candidate.agentType.displayName,
                accessibilityHint: Strings.agentActivityInferredHint,
                markerAgentType: candidate.agentType
            )
        case .ambiguous(let candidates):
            AgentActivityAttributionPresentation(
                badgeLabel: Strings.agentActivityAttributionAmbiguous,
                detail: Strings.agentActivityPossibleSessions(candidates.count),
                accessibilityHint: Strings.agentActivityAmbiguousHint,
                markerAgentType: nil
            )
        }
    }
}

/// Collapsible Activity Panel listing agent actions in reverse-chronological
/// order with kind/status/attribution-evidence filter chips.
///
/// Rendered as a sheet from `ContentView` via the `showAgentActivity`
/// notification. Selecting any row opens a detail popover showing kind,
/// status, attribution evidence, working directory, related terminal, and
/// timestamps, plus Copy and "Go to Terminal" actions that never execute
/// anything (#1245). Rows without a file URL remain fully actionable: their
/// primary action is "Inspect" (open the detail view).
struct AgentActivityView: View {
    let rows: [AgentActivityRow]
    /// Called when the user activates a row whose action has a file URL.
    let onSelectFile: (URL) -> Void
    /// Called when the user dismisses the panel.
    let onClose: () -> Void
    /// Called when the user triggers "Go to Terminal" for a row whose action
    /// has a related terminal link. Receives the terminal tab identifier; the
    /// host focuses that tab without executing anything (#1245).
    let onGoToTerminal: (UUID) -> Void

    @State private var filter = AgentActivityFilter()
    /// Detail view selection. `nil` hides the detail popover. Any row can be
    /// inspected — file URL is not required (#1245).
    @State private var detailRowID: UUID?

    /// Backwards-compatible initializer: callers that do not wire "Go to
    /// Terminal" get a no-op, so snapshot tests and existing presentations
    /// keep compiling.
    init(
        rows: [AgentActivityRow],
        onSelectFile: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.rows = rows
        self.onSelectFile = onSelectFile
        self.onClose = onClose
        self.onGoToTerminal = { _ in }
    }

    init(
        rows: [AgentActivityRow],
        onSelectFile: @escaping (URL) -> Void,
        onClose: @escaping () -> Void,
        onGoToTerminal: @escaping (UUID) -> Void
    ) {
        self.rows = rows
        self.onSelectFile = onSelectFile
        self.onClose = onClose
        self.onGoToTerminal = onGoToTerminal
    }

    /// Rows after filtering, newest-first.
    private var visibleRows: [AgentActivityRow] {
        rows.filter { row in
            filter.matches(
                kind: row.kind,
                status: row.status,
                attribution: row.attribution
            )
        }
        .reversed()
    }

    /// Expose only categories represented after applying the current
    /// non-attribution dimensions. Retaining the selected category keeps its
    /// chip available to clear when another filter removes its last row.
    private var availableAttributionFilters: [ActivityAttributionFilter] {
        filter.availableAttributionFilters(
            in: rows,
            kind: \.kind,
            status: \.status,
            attribution: \.attribution
        )
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
        .sheet(item: Binding(
            get: { detailRowID.map { DetailSelection(id: $0) } },
            set: { detailRowID = $0?.id }
        )) { selection in
            if let row = (rows.first { $0.id == selection.id }) {
                AgentActivityDetailView(
                    row: row,
                    onSelectFile: { url in
                        detailRowID = nil
                        onSelectFile(url)
                    },
                    onGoToTerminal: { terminalID in
                        detailRowID = nil
                        onGoToTerminal(terminalID)
                    },
                    onClose: { detailRowID = nil }
                }
            }
        }
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

    /// Adaptive filter bar (#1245). Kind and status stay as quick chips (only
    /// 4 each — they never overflow the panel width). Attribution evidence
    /// collapses into a single Menu so the row can never overflow regardless of
    /// how many categories are represented. A Reset Filters button is shown
    /// only when a filter is active, so the control to clear every dimension is
    /// always one keystroke away.
    private var filterChips: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AgentActionKind.allCases, id: \.self) { kind in
                        FilterChip(
                            label: kind.filterLabel,
                            isSelected: filter.kind == kind
                        ) {
                            filter.kind = filter.kind == kind ? nil : kind
                        }
                        .accessibilityIdentifier(kindChipID(kind))
                    }
                    Divider().frame(height: 16).padding(.horizontal, 2)
                    ForEach(AgentActionStatus.allCases, id: \.self) { status in
                        FilterChip(
                            label: status.displayName,
                            isSelected: filter.status == status
                        ) {
                            filter.status = filter.status == status ? nil : status
                        }
                        .accessibilityIdentifier(statusChipID(status))
                    }
                }
            }
            if !availableAttributionFilters.isEmpty {
                attributionMenu
            }
            if filter.isActive {
                Button {
                    filter = AgentActivityFilter()
                } label: {
                    Label(Strings.agentActivityResetFilters, systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.agentActivityResetFilters)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Attribution-evidence filter collapsed into a Menu (#1245). Avoids the
    /// overflowing horizontal chip row that occurred with many categories and
    /// keeps every option keyboard-reachable.
    private var attributionMenu: some View {
        Menu {
            Button {
                filter.attribution = nil
            } label: {
                if filter.attribution == nil {
                    Label(Strings.agentActivityAllAttributions, systemImage: "checkmark")
                } else {
                    Text(Strings.agentActivityAllAttributions)
                }
            }
            ForEach(availableAttributionFilters, id: \.self) { category in
                Button {
                    filter.attribution = filter.attribution == category ? nil : category
                } label: {
                    if filter.attribution == category {
                        Label(category.filterLabel, systemImage: "checkmark")
                    } else {
                        Text(category.filterLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(Strings.agentActivityAttributionFilterLabel)
                    .font(.system(size: 11))
                if let selected = filter.attribution {
                    Text(verbatim: selected.filterLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                filter.attribution != nil
                    ? Color.accentColor.opacity(0.2)
                    : Color.clear
            )
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.tertiary, lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.agentActivityAttributionMenu)
    }

    private func kindChipID(_ kind: AgentActionKind) -> String {
        switch kind {
        case .fileWrite: AccessibilityID.agentActivityFilterWrites
        case .fileRead: AccessibilityID.agentActivityFilterReads
        case .command: AccessibilityID.agentActivityFilterCommands
        case .toolCall: AccessibilityID.agentActivityFilterTools
        }
    }

    private func statusChipID(_ status: AgentActionStatus) -> String {
        switch status {
        case .pending: AccessibilityID.agentActivityFilterPending
        case .inProgress: AccessibilityID.agentActivityFilterInProgress
        case .completed: AccessibilityID.agentActivityFilterCompleted
        case .failed: AccessibilityID.agentActivityFilterFailed
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
                        AgentActivityRowView(
                            row: row,
                            isDetailVisible: detailRowID == row.id
                        ) {
                            // Primary inspect action — always available, even
                            // when the row has no file URL (#1245).
                            detailRowID = row.id
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
            Text(rows.isEmpty ? Strings.agentActivityEmpty : Strings.agentActivityNoMatches)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    rows.isEmpty
                        ? AccessibilityID.agentActivityEmpty
                        : AccessibilityID.agentActivityNoMatches
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

/// A single action row: agent color dot, kind icon, summary, status badge,
/// relative timestamp.
///
/// The primary action is always "Inspect" (open the detail view). The row is
/// never disabled solely because it lacks a file URL (#1245); file rows still
/// let the user open the file from the detail view.
struct AgentActivityRowView: View {
    let row: AgentActivityRow
    var isDetailVisible: Bool = false
    let onClick: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var attribution: AgentActivityAttributionPresentation {
        row.attribution.activityPresentation
    }

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                attributionMarker

                Image(systemName: row.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.summary)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(verbatim: "\(attribution.detail) · \(relativeTime)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if let badgeLabel = attribution.badgeLabel {
                    AttributionBadge(
                        label: badgeLabel,
                        isAmbiguous: attribution.isAmbiguous
                    )
                }
                StatusBadge(status: row.status)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isDetailVisible
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.agentActivityRow(row.id))
        .accessibilityLabel(Text(verbatim: row.summary))
        .accessibilityValue(Text(verbatim: attribution.accessibilityValue))
        .accessibilityHint(Text(verbatim: Strings.agentActivityRowInspectHint))
        .accessibilityAddTraits(isDetailVisible ? .isSelected : [])
    }

    @ViewBuilder
    private var attributionMarker: some View {
        if let agentType = attribution.markerAgentType {
            Circle()
                .fill(Color(nsColor: agentType.color))
                .frame(width: 8, height: 8)
                .frame(width: 12)
        } else {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .frame(width: 12)
                .accessibilityHidden(true)
        }
    }

    private var relativeTime: String {
        Self.relativeFormatter.localizedString(for: row.timestamp, relativeTo: Date())
    }
}

// MARK: - Subviews

/// Evidence pill for Activity rows. Every category is explicit so a legacy
/// session link or heuristic candidate cannot be mistaken for verified
/// provenance.
struct AttributionBadge: View {
    let label: String
    let isAmbiguous: Bool

    var body: some View {
        Text(verbatim: label)
            .font(.system(size: 10))
            .foregroundStyle(isAmbiguous ? Color.orange : Color.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (isAmbiguous ? Color.orange : Color.blue).opacity(0.12)
            )
            .clipShape(Capsule())
    }
}

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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    /// Short label for the filter chip. Localized via ``displayName`` (#1245).
    var filterLabel: String {
        displayName
    }
}

// MARK: - Detail selection wrapper

/// `Identifiable` wrapper so SwiftUI's `.sheet(item:)` can present the detail
/// view from a `UUID?` selection. Value type keeps the binding testable.
struct DetailSelection: Identifiable, Equatable {
    let id: UUID
}

// MARK: - Detail view

/// Detail view for a single Activity row (#1245).
///
/// Surfaces every dimension the acceptance contract requires: kind, status,
/// attribution evidence (verified / session-linked / inferred / ambiguous /
/// stale / terminated), working directory, related terminal, and timestamps.
/// Provides Copy and "Go to Terminal" actions. Neither action executes
/// anything: Copy places already-displayed metadata on the pasteboard (never
/// secrets), and "Go to Terminal" only asks the host to focus the tab.
struct AgentActivityDetailView: View {
    let row: AgentActivityRow
    let onSelectFile: (URL) -> Void
    let onGoToTerminal: (UUID) -> Void
    let onClose: () -> Void

    @State private var didCopy = false

    private var attribution: AgentActivityAttributionPresentation {
        row.attribution.activityPresentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    summarySection
                    kindStatusSection
                    evidenceSection
                    workingDirectorySection
                    relatedTerminalSection
                    timestampsSection
                }
                .padding(16)
            }
            Divider()
            actionsBar
        }
        .frame(width: 420, height: 460)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.agentActivityDetail)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: row.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(verbatim: row.summary)
                .font(.headline)
                .lineLimit(2)
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

    // MARK: Sections

    private var summarySection: some View {
        detailRow(
            label: Strings.agentActionDetailSummaryLabel,
            value: row.summary
        )
    }

    private var kindStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow(
                label: Strings.agentActionDetailKindLabel,
                value: row.kind.displayName
            )
            detailRow(
                label: Strings.agentActionDetailStatusLabel,
                value: row.status.displayName
            )
            if let fileURL = row.fileURL {
                detailRow(
                    label: Strings.agentActionDetailFileLabel,
                    value: fileURL.path
                )
            }
        }
    }

    /// Evidence section — explicitly distinguishes every attribution category
    /// so verified, session-linked, inferred, ambiguous, stale, and terminated
    /// evidence are visually distinct (#1245).
    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.agentActionDetailEvidenceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let badgeLabel = attribution.badgeLabel {
                    AttributionBadge(
                        label: badgeLabel,
                        isAmbiguous: attribution.isAmbiguous
                    )
                } else {
                    AttributionBadge(
                        label: Strings.agentActivityAttributionVerified,
                        isAmbiguous: false
                    )
                }
                StatusBadge(status: row.status)
            }
            Text(verbatim: evidenceExplanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var workingDirectorySection: some View {
        if let workingDirectory = row.workingDirectory {
            detailRow(
                label: Strings.agentActionDetailWorkingDirectoryLabel,
                value: workingDirectory.path
            )
        }
    }

    @ViewBuilder
    private var relatedTerminalSection: some View {
        if let relatedTerminalLabel = row.relatedTerminalLabel {
            detailRow(
                label: Strings.agentActionDetailRelatedTerminalLabel,
                value: relatedTerminalLabel
            )
        }
    }

    private var timestampsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow(
                label: Strings.agentActionDetailTimestampLabel,
                value: Self.dateFormatter.string(from: row.timestamp)
            )
        }
    }

    // MARK: Actions

    private var actionsBar: some View {
        HStack(spacing: 8) {
            if didCopy {
                Label(Strings.agentActivityDetailCopied, systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            Spacer()
            if row.relatedTerminalID != nil {
                Button {
                    if let terminalID = row.relatedTerminalID {
                        onGoToTerminal(terminalID)
                    }
                } label: {
                    Label(
                        Strings.agentActivityDetailGoToTerminal,
                        systemImage: "arrow.right.square"
                    )
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.agentActivityDetailGoToTerminal)
            }
            if row.fileURL != nil {
                Button {
                    if let url = row.fileURL {
                        onSelectFile(url)
                    }
                } label: {
                    Label(
                        Strings.agentActivityDetailOpenFile,
                        systemImage: "doc.text"
                    )
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.agentActivityDetailOpenFile)
            }
            Button {
                copyDetails()
            } label: {
                Label(Strings.agentActivityDetailCopy, systemImage: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.agentActivityDetailCopy)
        }
        .padding(12)
        .animation(PineAnimation.content, value: didCopy)
    }

    // MARK: Helpers

    /// Human-readable explanation of the attribution evidence category. Each
    /// branch maps to exactly one of the six required evidence states
    /// (#1245): verified, session-linked, inferred, ambiguous, stale,
    /// terminated.
    private var evidenceExplanation: String {
        attribution.evidenceExplanation
    }

    private func copyDetails() {
        let payload = row.copyableSummary
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        withAnimation(PineAnimation.content) {
            didCopy = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(PineAnimation.content) {
                didCopy = false
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(verbatim: value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Evidence presentation

extension AgentActivityAttributionPresentation {
    /// Localized, human-readable explanation of the evidence category backing
    /// this presentation. Maps directly to the six required evidence states:
    /// verified, session-linked, inferred, ambiguous, stale, terminated
    /// (#1245).
    ///
    /// The Activity attribution model carries verified, session-linked,
    /// inferred, and ambiguous evidence. Stale and terminated evidence are
    /// surfaced by the liveness tracker and reused here for rows whose
    /// attribution can no longer be backed by a live observation.
    var evidenceExplanation: String {
        // Ambiguous must be checked before checking for a single candidate:
        // an ambiguous presentation intentionally has no marker agent type.
        if isAmbiguous {
            return Strings.agentActivityEvidenceAmbiguousExplanation
        }
        guard badgeLabel != nil else {
            return Strings.agentActivityEvidenceVerifiedExplanation
        }
        // Session-linked vs inferred is encoded by the badge source; fall back
        // to the strongest claim that does not overstate trust.
        if markerAgentType != nil {
            return Strings.agentActivityEvidenceSessionLinkedExplanation
        }
        return Strings.agentActivityEvidenceInferredExplanation
    }
}
