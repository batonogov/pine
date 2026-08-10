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
    /// Exact live terminal/session owner, if one can be verified (#1245).
    let terminalTarget: AgentActivityTerminalTarget?
    /// Structured copy payload which deliberately excludes free-form output.
    let safeCopyText: String

    init(
        _ action: AgentAction,
        terminalTarget: AgentActivityTerminalTarget? = nil
    ) {
        self.id = action.id
        self.attribution = action.attribution
        self.kind = action.kind
        self.status = action.status
        self.fileURL = action.fileURL
        self.summary = action.summary
        self.timestamp = action.timestamp
        self.workingDirectory =
            action.workingDirectory ?? terminalTarget?.workingDirectory
        self.terminalTarget = terminalTarget
        self.safeCopyText = action.copyableSummary
    }

    var activityPresentation: AgentActivityAttributionPresentation {
        attribution.activityPresentation(liveness: terminalTarget?.liveness)
    }
}

/// Localized rendering projection for one action's attribution. Keeping this
/// separate from the SwiftUI hierarchy makes the fail-closed presentation
/// directly testable without constructing an accessibility tree.
nonisolated enum AgentActivityEvidenceKind: Sendable, Equatable, CaseIterable {
    /// A trusted structured event with a currently live owner.
    case verified
    /// A legacy action record names one session, but carries no trusted event.
    case sessionLinked
    /// File-system timing leaves exactly one possible live session.
    case inferred
    /// File-system timing leaves multiple possible live sessions.
    case ambiguous
    /// The associated process has not been observed successfully recently.
    case stale
    /// A successful observation established that the associated process ended.
    case terminated
}

struct AgentActivityAttributionPresentation: Equatable {
    let evidenceKind: AgentActivityEvidenceKind
    let badgeLabel: String
    let detail: String
    let evidenceExplanation: String
    let markerAgentType: AgentType?

    var isAmbiguous: Bool { evidenceKind == .ambiguous }

    var accessibilityValue: String {
        return "\(badgeLabel), \(detail)"
    }

    /// VoiceOver value for the row. Action lifecycle and attribution evidence
    /// remain separate labels so "Completed" never sounds like "Verified".
    func rowAccessibilityValue(status: AgentActionStatus) -> String {
        """
        \(Strings.agentActionDetailStatusLabel): \(status.displayName). \
        \(Strings.agentActionDetailEvidenceLabel): \(accessibilityValue)
        """
    }

    /// VoiceOver hint for the row uses the exact explanation shown in detail.
    var rowAccessibilityHint: String {
        "\(evidenceExplanation). \(Strings.agentActivityRowInspectHint)"
    }

    /// VoiceOver value for the detail evidence section.
    var detailAccessibilityValue: String {
        "\(accessibilityValue). \(evidenceExplanation)"
    }
}

extension AgentActionAttribution {
    var activityPresentation: AgentActivityAttributionPresentation {
        activityPresentation(liveness: nil)
    }

    func activityPresentation(
        liveness: AgentLiveness?
    ) -> AgentActivityAttributionPresentation {
        if let candidate = unambiguousCandidate {
            switch liveness {
            case .stale:
                return AgentActivityAttributionPresentation(
                    evidenceKind: .stale,
                    badgeLabel: Strings.agentActivityAttributionStale,
                    detail: candidate.agentType.displayName,
                    evidenceExplanation: Strings.agentActivityStaleHint,
                    markerAgentType: candidate.agentType
                )
            case .terminated:
                return AgentActivityAttributionPresentation(
                    evidenceKind: .terminated,
                    badgeLabel: Strings.agentActivityAttributionTerminated,
                    detail: candidate.agentType.displayName,
                    evidenceExplanation: Strings.agentActivityTerminatedHint,
                    markerAgentType: candidate.agentType
                )
            case .live, nil:
                break
            }
        }

        return switch self {
        case .verified(let candidate):
            AgentActivityAttributionPresentation(
                evidenceKind: .verified,
                badgeLabel: Strings.agentActivityAttributionVerified,
                detail: candidate.agentType.displayName,
                evidenceExplanation: Strings.agentActivityVerifiedHint,
                markerAgentType: candidate.agentType
            )
        case .session(let candidate):
            AgentActivityAttributionPresentation(
                evidenceKind: .sessionLinked,
                badgeLabel: Strings.agentActivityAttributionSessionLinked,
                detail: candidate.agentType.displayName,
                evidenceExplanation: Strings.agentActivitySessionLinkedHint,
                markerAgentType: candidate.agentType
            )
        case .inferred(let candidate):
            AgentActivityAttributionPresentation(
                evidenceKind: .inferred,
                badgeLabel: Strings.agentActivityAttributionInferred,
                detail: candidate.agentType.displayName,
                evidenceExplanation: Strings.agentActivityInferredHint,
                markerAgentType: candidate.agentType
            )
        case .ambiguous(let candidates):
            AgentActivityAttributionPresentation(
                evidenceKind: .ambiguous,
                badgeLabel: Strings.agentActivityAttributionAmbiguous,
                detail: Strings.agentActivityPossibleSessions(candidates.count),
                evidenceExplanation: Strings.agentActivityAmbiguousHint,
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
    let panelWidth: CGFloat
    /// Called when the user activates a row whose action has a file URL.
    let onSelectFile: (URL) -> Void
    /// Called when the user dismisses the panel.
    let onClose: () -> Void
    /// Called when the user triggers "Go to Terminal" for a verified target.
    /// Returns whether the exact pane/tab/session target was still valid and
    /// successfully focused without executing anything (#1245).
    let onGoToTerminal: (AgentActivityTerminalTarget) -> Bool

    @State private var filter = AgentActivityFilter()
    /// Detail view selection. `nil` hides the detail popover. Any row can be
    /// inspected — file URL is not required (#1245).
    @State private var detailRowID: UUID?

    init(
        rows: [AgentActivityRow],
        panelWidth: CGFloat = 420,
        onSelectFile: @escaping (URL) -> Void,
        onClose: @escaping () -> Void,
        onGoToTerminal: @escaping (AgentActivityTerminalTarget) -> Bool
    ) {
        self.rows = rows
        self.panelWidth = panelWidth
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
        .frame(width: panelWidth, height: 480)
        .background(.regularMaterial)
        .sheet(item: Binding(
            get: {
                Self.detailSelection(id: detailRowID, rows: rows)
            },
            set: { detailRowID = $0?.id }
        )) { selection in
            if let row = (rows.first { $0.id == selection.id }) {
                AgentActivityDetailView(
                    row: row,
                    onSelectFile: { url in
                        detailRowID = nil
                        onSelectFile(url)
                    },
                    onGoToTerminal: { terminalTarget in
                        let didNavigate = onGoToTerminal(terminalTarget)
                        if didNavigate {
                            detailRowID = nil
                        }
                        return didNavigate
                    },
                    onClose: { detailRowID = nil }
                )
            }
        }
    }

    static func detailSelection(
        id: UUID?,
        rows: [AgentActivityRow]
    ) -> DetailSelection? {
        guard let id, rows.contains(where: { $0.id == id }) else {
            return nil
        }
        return DetailSelection(id: id)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(Strings.agentActivityTitle)
                .font(.headline)
                .accessibilityIdentifier(AccessibilityID.agentActivityPanel)
            Spacer()
            HelpLink(
                anchor: PineHelp.Anchor.agents,
                book: PineHelp.bookName
            )
            .accessibilityIdentifier(
                AccessibilityID.agentActivityHelpButton
            )
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

    /// Adaptive filter bar (#1245). Every dimension is a named menu, so all
    /// options remain keyboard-discoverable without horizontal scrolling.
    /// `ViewThatFits` stacks the controls at narrow widths or under long
    /// translations rather than clipping an indicator-less chip row.
    private var filterChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                kindMenu
                statusMenu
                attributionMenu
                resetFiltersButton
            }
            VStack(alignment: .leading, spacing: 6) {
                kindMenu
                statusMenu
                attributionMenu
                resetFiltersButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var kindMenu: some View {
        Menu {
            filterMenuItem(
                label: Strings.agentActivityAllKinds,
                isSelected: filter.kind == nil
            ) {
                filter.kind = nil
            }
            ForEach(AgentActionKind.allCases, id: \.self) { kind in
                filterMenuItem(
                    label: kind.displayName,
                    isSelected: filter.kind == kind
                ) {
                    filter.kind = kind
                }
            }
        } label: {
            filterMenuLabel(
                title: Strings.agentActionDetailKindLabel,
                selection: filter.kind?.displayName
            )
        }
        .filterMenuAccessibility(
            identifier: AccessibilityID.agentActivityKindMenu,
            value: filter.kind?.displayName ?? Strings.agentActivityAllKinds,
            isSelected: filter.kind != nil
        )
    }

    private var statusMenu: some View {
        Menu {
            filterMenuItem(
                label: Strings.agentActivityAllStatuses,
                isSelected: filter.status == nil
            ) {
                filter.status = nil
            }
            ForEach(AgentActionStatus.allCases, id: \.self) { status in
                filterMenuItem(
                    label: status.displayName,
                    isSelected: filter.status == status
                ) {
                    filter.status = status
                }
            }
        } label: {
            filterMenuLabel(
                title: Strings.agentActionDetailStatusLabel,
                selection: filter.status?.displayName
            )
        }
        .filterMenuAccessibility(
            identifier: AccessibilityID.agentActivityStatusMenu,
            value: filter.status?.displayName
                ?? Strings.agentActivityAllStatuses,
            isSelected: filter.status != nil
        )
    }

    private var attributionMenu: some View {
        Menu {
            filterMenuItem(
                label: Strings.agentActivityAllAttributions,
                isSelected: filter.attribution == nil
            ) {
                filter.attribution = nil
            }
            ForEach(availableAttributionFilters, id: \.self) { category in
                filterMenuItem(
                    label: category.filterLabel,
                    isSelected: filter.attribution == category
                ) {
                    filter.attribution = category
                }
            }
        } label: {
            filterMenuLabel(
                title: String(localized: "agentActivity.attribution.filterLabel"),
                selection: filter.attribution?.filterLabel
            )
        }
        .filterMenuAccessibility(
            identifier: AccessibilityID.agentActivityAttributionMenu,
            value: filter.attribution?.filterLabel
                ?? Strings.agentActivityAllAttributions,
            isSelected: filter.attribution != nil
        )
    }

    @ViewBuilder
    private func filterMenuItem(
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if isSelected {
                Label(label, systemImage: "checkmark")
            } else {
                Text(verbatim: label)
            }
        }
    }

    private func filterMenuLabel(
        title: String,
        selection: String?
    ) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: title)
                .font(.system(size: 11))
            if let selection {
                Text(verbatim: selection)
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
            selection == nil ? Color.clear : Color.accentColor.opacity(0.2)
        )
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.tertiary, lineWidth: 0.5))
    }

    @ViewBuilder
    private var resetFiltersButton: some View {
        if filter.isActive {
            Button {
                filter = AgentActivityFilter()
            } label: {
                Label(
                    Strings.agentActivityResetFilters,
                    systemImage: "arrow.counterclockwise"
                )
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                AccessibilityID.agentActivityResetFilters
            )
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
        row.activityPresentation
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

                AttributionBadge(
                    label: attribution.badgeLabel,
                    evidenceKind: attribution.evidenceKind
                )
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
        .accessibilityValue(
            Text(verbatim: attribution.rowAccessibilityValue(status: row.status))
        )
        .accessibilityHint(Text(verbatim: attribution.rowAccessibilityHint))
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

/// Evidence pill for Activity rows. Every model-backed category is explicit
/// so a legacy session link or heuristic candidate cannot be mistaken for
/// verified provenance.
struct AttributionBadge: View {
    let label: String
    let evidenceKind: AgentActivityEvidenceKind

    var body: some View {
        Text(verbatim: label)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                color.opacity(0.12)
            )
            .clipShape(Capsule())
    }

    private var color: Color {
        switch evidenceKind {
        case .verified: .green
        case .sessionLinked, .inferred: .blue
        case .ambiguous, .stale: .orange
        case .terminated: .secondary
        }
    }
}

private extension View {
    func filterMenuAccessibility(
        identifier: String,
        value: String,
        isSelected: Bool
    ) -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(Text(verbatim: value))
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

// MARK: - Detail selection wrapper

/// `Identifiable` wrapper so SwiftUI's `.sheet(item:)` can present the detail
/// view from a `UUID?` selection. Value type keeps the binding testable.
struct DetailSelection: Identifiable, Equatable {
    let id: UUID
}

// MARK: - Detail view

/// Detail view for a single Activity row (#1245).
///
/// Surfaces kind, action lifecycle status, model-backed attribution evidence
/// (verified / session-linked / inferred / ambiguous) and current session
/// liveness (stale / terminated), working directory, related terminal, and
/// timestamps.
/// Provides Copy and "Go to Terminal" actions. Neither action executes
/// anything: Copy places already-displayed metadata on the pasteboard (never
/// secrets), and "Go to Terminal" only asks the host to focus the tab.
struct AgentActivityDetailView: View {
    let row: AgentActivityRow
    let onSelectFile: (URL) -> Void
    let onGoToTerminal: (AgentActivityTerminalTarget) -> Bool
    let onClose: () -> Void

    @State private var didCopy = false

    private var attribution: AgentActivityAttributionPresentation {
        row.activityPresentation
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
                .accessibilityIdentifier(AccessibilityID.agentActivityDetail)
            Spacer()
            HelpLink(
                anchor: PineHelp.Anchor.agents,
                book: PineHelp.bookName
            )
            .accessibilityIdentifier(
                AccessibilityID.agentActivityDetailHelpButton
            )
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

    /// Evidence is intentionally separate from action lifecycle status.
    /// "Completed" means the recorded action finished; it is never promoted
    /// into a provenance claim such as "Verified".
    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.agentActionDetailEvidenceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            AttributionBadge(
                label: attribution.badgeLabel,
                evidenceKind: attribution.evidenceKind
            )
            Text(verbatim: evidenceExplanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.agentActionDetailEvidenceLabel)
        .accessibilityValue(
            Text(verbatim: attribution.detailAccessibilityValue)
        )
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
        if let terminalTarget = row.terminalTarget {
            detailRow(
                label: Strings.agentActionDetailRelatedTerminalLabel,
                value: terminalTarget.label
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
            if let terminalTarget = row.terminalTarget {
                Button {
                    _ = onGoToTerminal(terminalTarget)
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

    /// Human-readable explanation of the exact model-backed attribution
    /// category. It is also reused verbatim by VoiceOver.
    private var evidenceExplanation: String {
        attribution.evidenceExplanation
    }

    private func copyDetails() {
        let payload = row.safeCopyText
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
