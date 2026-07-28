//
//  ProblemsPanelView.swift
//  Pine
//
//  Phase 1 of LSP support (issue #1010).
//
//  A SwiftUI "Problems" panel that lists every active diagnostic grouped by
//  file. Clicking a diagnostic navigates to its location and focuses the
//  editor. Reuses the existing gutter-icon model (`ValidationDiagnostic`).
//

import SwiftUI

/// Lightweight summary of diagnostic counts for the status bar indicator.
/// Computed from `LSPManager` (and could include config validators).
struct DiagnosticsSummary: Equatable {
    let errorCount: Int
    let warningCount: Int

    var total: Int { errorCount + warningCount }

    init(errorCount: Int, warningCount: Int) {
        self.errorCount = errorCount
        self.warningCount = warningCount
    }

    /// Human-readable summary for the status bar (e.g. "2 errors, 1 warning").
    var description: String {
        switch (errorCount, warningCount) {
        case (0, 0): return ""
        case (let errors, 0):
            return Strings.problemsErrorCount(errors)
        case (0, let warnings):
            return Strings.problemsWarningCount(warnings)
        default:
            return [
                Strings.problemsErrorCount(errorCount),
                Strings.problemsWarningCount(warningCount)
            ].joined(separator: ", ")
        }
    }
}

// MARK: - Problems panel

/// A collapsible panel listing all active diagnostics grouped by file.
///
/// Driven by `LSPManager.allDiagnostics`. Each row is clickable; the callback
/// resolves the file URL and line number so the caller can open the tab and
/// jump to the location.
struct ProblemsPanelView: View {
    /// Diagnostics grouped by URI, pre-sorted by file path.
    let groups: [ProblemsDiagnosticGroup]
    let state: ProblemsPresentationState
    let selectedDiagnosticID: ProblemsDiagnosticID?

    /// Called with the exact project/pane/tab/revision-owned diagnostic.
    var onSelect: ((ProblemsFlatDiagnostic) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text(state.message)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier(AccessibilityID.problemsEmptyState)
            } else {
                List {
                    ForEach(groups) { group in
                        ProblemsFileSection(
                            uri: group.uri,
                            diagnostics: group.diagnostics,
                            selectedDiagnosticID: selectedDiagnosticID,
                            onSelect: onSelect
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier(AccessibilityID.problemsPanel)
    }
}

/// A single file's diagnostics, shown as a collapsible section with a header
/// (file name + count) and a list of diagnostic rows.
private struct ProblemsFileSection: View {
    let uri: String
    let diagnostics: [ProblemsFlatDiagnostic]
    let selectedDiagnosticID: ProblemsDiagnosticID?
    let onSelect: ((ProblemsFlatDiagnostic) -> Void)?

    @State private var isExpanded = true

    private var displayName: String {
        URL(string: uri)?.lastPathComponent ?? uri
    }

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(diagnostics) { entry in
                ProblemsDiagnosticRow(
                    diagnostic: entry.diagnostic,
                    isSelected: entry.id == selectedDiagnosticID
                ) {
                    onSelect?(entry)
                }
            }
        } header: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(displayName)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize, weight: .semibold))
                Text(verbatim: "(\(diagnostics.count))")
                    .font(.system(size: LayoutMetrics.captionFontSize))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A single diagnostic row: severity icon, message, and line:column.
private struct ProblemsDiagnosticRow: View {
    let diagnostic: ValidationDiagnostic
    let isSelected: Bool
    let action: () -> Void

    private var severityColor: Color {
        switch diagnostic.severity {
        case .error: return .red
        case .warning: return .yellow
        case .info: return .blue
        }
    }

    private var severitySymbol: String {
        switch diagnostic.severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var locationLabel: String {
        if let column = diagnostic.column {
            return Strings.diagnosticLineColumnLabel(line: diagnostic.line, column: column)
        }
        return Strings.diagnosticLineLabel(line: diagnostic.line)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: severitySymbol)
                    .foregroundStyle(severityColor)
                    .font(.system(size: LayoutMetrics.captionFontSize))
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnostic.message)
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(locationLabel)
                            .font(.system(size: LayoutMetrics.captionFontSize))
                            .foregroundStyle(.secondary)
                        Text(verbatim: diagnostic.source)
                            .font(.system(size: LayoutMetrics.captionFontSize))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.clear
        )
    }
}

// MARK: - Chrome container (#1236)

/// Editor-chrome wrapper around the existing `ProblemsPanelView`: a header bar
/// (title + diagnostic count + close button) sitting above the panel content.
/// The bottom pane's visibility is driven by `ProblemsPanelController`.
struct ProblemsPanelChrome: View {
    @Bindable var controller: ProblemsPanelController
    /// Called when the user selects an exactly-owned diagnostic row.
    var onSelect: ((ProblemsFlatDiagnostic) -> Void)?
    /// Called when the user clicks the close button.
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ProblemsPanelView(
                groups: controller.groupedDiagnostics,
                state: controller.presentationState,
                selectedDiagnosticID: controller.selectedDiagnosticID,
                onSelect: { diagnostic in
                    controller.select(diagnostic)
                    onSelect?(diagnostic)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.problemsPanel)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: MenuIcons.problems)
                .font(.system(size: LayoutMetrics.bodySmallFontSize))
                .foregroundStyle(.secondary)
            Text(Strings.problemsPanelTitle)
                .font(.system(size: LayoutMetrics.bodySmallFontSize, weight: .semibold))
            Text(verbatim: "(\(controller.diagnosticCount))")
                .font(.system(size: LayoutMetrics.captionFontSize))
                .foregroundStyle(.secondary)
            Picker(
                Strings.problemsSeverityFilter,
                selection: $controller.severityFilter
            ) {
                ForEach(ProblemsSeverityFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Strings.problemsSeverityFilter)
            Picker(
                Strings.problemsSourceFilter,
                selection: $controller.sourceFilter
            ) {
                Text(Strings.problemsAllSources)
                    .tag(nil as String?)
                ForEach(controller.availableSources, id: \.self) { source in
                    Text(verbatim: source).tag(Optional(source))
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Strings.problemsSourceFilter)
            Spacer()
            Button {
                onClose?()
            } label: {
                Image(systemName: MenuIcons.closeProblems)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Strings.problemsClose)
            .accessibilityLabel(Strings.problemsClose)
        }
        .padding(.horizontal, LayoutMetrics.statusBarHorizontalPadding)
        .frame(height: LayoutMetrics.problemsPanelHeaderHeight)
        .background(.bar)
    }
}

private extension ProblemsSeverityFilter {
    var label: String {
        switch self {
        case .all: Strings.problemsAllSeverities
        case .error: Strings.diagnosticSeverityError
        case .warning: Strings.diagnosticSeverityWarning
        case .info: Strings.diagnosticSeverityInfo
        }
    }
}

private extension ProblemsPresentationState {
    var message: String {
        switch self {
        case .diagnostics, .empty: Strings.problemsNoIssues
        case .disabled: Strings.problemsDisabled
        case .unsupported: Strings.problemsUnsupported
        case .loading: Strings.problemsLoading
        case .unavailable: Strings.problemsUnavailable
        }
    }
}
