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
}

// MARK: - Problems panel

/// A collapsible panel listing all active diagnostics grouped by file.
///
/// Driven by `LSPManager.allDiagnostics`. Each row is clickable; the callback
/// resolves the file URL and line number so the caller can open the tab and
/// jump to the location.
struct ProblemsPanelView: View {
    /// Diagnostics grouped by URI, pre-sorted by file path.
    let groups: [(uri: String, diagnostics: [ValidationDiagnostic])]

    /// Called when the user selects a diagnostic. The arguments are the file
    /// URL and the 1-based line number to navigate to.
    var onSelect: ((URL, Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                Text(Strings.problemsNoIssues)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier(AccessibilityID.problemsEmptyState)
            } else {
                List {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        ProblemsFileSection(
                            uri: group.uri,
                            diagnostics: group.diagnostics,
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
    let diagnostics: [ValidationDiagnostic]
    let onSelect: ((URL, Int) -> Void)?

    @State private var isExpanded = true

    private var displayName: String {
        URL(string: uri)?.lastPathComponent ?? uri
    }

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diag in
                ProblemsDiagnosticRow(diagnostic: diag) {
                    if let url = URL(string: uri) {
                        onSelect?(url, diag.line)
                    }
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
    }
}
