//
//  VerifiedDiffPreviewView.swift
//  Pine
//
//  Renders verified before/after diff previews for Agent History entries
//  (vision #933 §2 — Reviewable changes). The models exist in
//  VerifiedPatchModels.swift but no UI renders them — this view closes that gap.
//
//  Follows the value-type-projection pattern from AgentHistoryRow /
//  AgentActivityRow: display projections decode raw Data bytes to String so
//  the view and its snapshot tests need no live store or disk access.
//

import SwiftUI

// MARK: - Value-type projections

/// Display projection of a single diff preview line. Decodes the raw UTF-8
/// bytes from `VerifiedInversePreviewLine` into a display-ready String.
nonisolated struct VerifiedDiffPreviewLineRow:
    Sendable,
    Equatable,
    Identifiable {
    let id: Int
    let kind: VerifiedInversePreviewLineKind
    let text: String

    init(id: Int, from line: VerifiedInversePreviewLine) {
        self.id = id
        self.kind = line.kind
        if let decoded = String(data: line.bytes, encoding: .utf8) {
            self.text = decoded.trimmingCharacters(in: .newlines)
        } else {
            self.text = ""
        }
    }
}

/// Display projection of a hunk: the `@@ ... @@` header plus decoded lines.
nonisolated struct VerifiedDiffHunkRow:
    Sendable,
    Equatable,
    Identifiable {
    let id: Int
    let header: String
    let lines: [VerifiedDiffPreviewLineRow]

    init(index: Int, from hunk: VerifiedInverseHunkPreview) {
        self.id = index
        self.header = hunk.header
        self.lines = hunk.lines.enumerated().map { offset, line in
            VerifiedDiffPreviewLineRow(id: offset, from: line)
        }
    }
}

/// Value-type projection wrapping `VerifiedInverseOperationPreview` for
/// display. Extracts Decodable Data lines to String and provides a stable
/// identifier for SwiftUI `ForEach` / `LazyVStack` usage.
nonisolated struct VerifiedDiffPreviewRow:
    Identifiable,
    Equatable,
    Sendable {
    let id: String
    let kind: VerifiedInversePreviewKind
    let sourcePath: String
    let destinationPath: String?
    let hunks: [VerifiedDiffHunkRow]

    /// Path shown in the operation header — destination for renames,
    /// source for everything else.
    var displayPath: String {
        destinationPath ?? sourcePath
    }

    var addedLineCount: Int {
        hunks.reduce(0) { total, hunk in
            total + hunk.lines.filter { $0.kind == .add }.count
        }
    }

    var removedLineCount: Int {
        hunks.reduce(0) { total, hunk in
            total + hunk.lines.filter { $0.kind == .remove }.count
        }
    }

    init(from preview: VerifiedInverseOperationPreview) {
        let patchID = preview.operationID.patchID
        if let firstTransition = preview.operationID.transitionIDs.first {
            self.id = "\(patchID)_\(firstTransition.envelopeID)_\(firstTransition.ordinal)"
        } else {
            self.id = "\(patchID)"
        }
        self.kind = preview.kind
        self.sourcePath = preview.sourcePath
        self.destinationPath = preview.destinationPath
        self.hunks = preview.hunks.enumerated().map { offset, hunk in
            VerifiedDiffHunkRow(index: offset, from: hunk)
        }
    }
}

// MARK: - Kind presentation

nonisolated extension VerifiedInversePreviewKind {
    /// SF Symbol name for the operation kind.
    var systemImage: String {
        switch self {
        case .applyTextHunks: "doc.text"
        case .restoreExactFile: "arrow.uturn.backward"
        case .removeCreatedFile: "trash"
        case .restoreDeletedFile: "arrow.uturn.backward.circle"
        case .simulateRenamedFile: "rectangle.portrait.and.arrow.right"
        }
    }

    /// Short localized label for the operation kind.
    var displayName: String {
        switch self {
        case .applyTextHunks:
            String(
                localized: "verifiedDiff.kind.applyTextHunks",
                defaultValue: "Edit"
            )
        case .restoreExactFile:
            String(
                localized: "verifiedDiff.kind.restoreExactFile",
                defaultValue: "Restore"
            )
        case .removeCreatedFile:
            String(
                localized: "verifiedDiff.kind.removeCreatedFile",
                defaultValue: "Remove"
            )
        case .restoreDeletedFile:
            String(
                localized: "verifiedDiff.kind.restoreDeletedFile",
                defaultValue: "Restore"
            )
        case .simulateRenamedFile:
            String(
                localized: "verifiedDiff.kind.simulateRenamedFile",
                defaultValue: "Rename"
            )
        }
    }
}

// MARK: - Line view

/// Renders a single diff line colored by kind with the standard prefix:
/// context = space, remove = `-`, add = `+`.
private struct VerifiedDiffLineView: View {
    let line: VerifiedDiffPreviewLineRow

    private var prefix: String {
        switch line.kind {
        case .context: " "
        case .remove: "-"
        case .add: "+"
        }
    }

    private var color: Color {
        switch line.kind {
        case .context: .secondary
        case .remove: .red
        case .add: .green
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: prefix)
                .foregroundStyle(color)
            Text(verbatim: line.text)
                .foregroundStyle(color)
        }
        .font(.system(size: 12, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

// MARK: - Hunk view

/// Renders one `VerifiedInverseHunkPreview`: the `@@ ... @@` header line,
/// then lines colored by kind — context = secondary, remove = red with `-`
/// prefix, add = green with `+` prefix. Monospace font (system size 12).
struct VerifiedDiffHunkView: View {
    let hunk: VerifiedDiffHunkRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: hunk.header)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(hunk.lines) { line in
                VerifiedDiffLineView(line: line)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Operation view

/// Shows the operation kind icon + file path header, then the list of hunk
/// views for a single `VerifiedInverseOperationPreview`.
struct VerifiedDiffOperationView: View {
    let row: VerifiedDiffPreviewRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(row.hunks) { hunk in
                VerifiedDiffHunkView(hunk: hunk)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: row.kind.systemImage)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            Text(verbatim: row.displayPath)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if !changeSummary.isEmpty {
                Text(verbatim: changeSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var changeSummary: String {
        guard row.addedLineCount > 0 || row.removedLineCount > 0 else {
            return ""
        }
        return "+\(row.addedLineCount) -\(row.removedLineCount)"
    }
}

// MARK: - Top-level preview

/// Scrollable diff preview for a set of verified inverse operations.
///
/// Renders a `ScrollView` + `LazyVStack` of `VerifiedDiffOperationView`,
/// with a summary header showing the affected file count and total added /
/// removed line counts.
struct VerifiedDiffPreviewView: View {
    let rows: [VerifiedDiffPreviewRow]

    init(rows: [VerifiedDiffPreviewRow]) {
        self.rows = rows
    }

    /// Convenience initializer that projects raw preview models.
    init(previews: [VerifiedInverseOperationPreview]) {
        self.rows = previews.map { VerifiedDiffPreviewRow(from: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        VerifiedDiffOperationView(row: row)
                        if row.id != rows.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
        .accessibilityIdentifier("verifiedDiffPreview")
    }

    // MARK: - Summary

    private var summaryHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            Text(
                String(
                    localized: "verifiedDiff.title",
                    defaultValue: "Verified Changes"
                )
            )
            .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Text(verbatim: summaryText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summaryText: String {
        let fileCount = rows.count
        let added = totalAdded
        let removed = totalRemoved
        return "\(fileCount) files  +\(added) -\(removed)"
    }

    private var totalAdded: Int {
        rows.reduce(0) { $0 + $1.addedLineCount }
    }

    private var totalRemoved: Int {
        rows.reduce(0) { $0 + $1.removedLineCount }
    }
}
