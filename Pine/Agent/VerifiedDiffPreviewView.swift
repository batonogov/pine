//
//  VerifiedDiffPreviewView.swift
//  Pine
//
//  Display-only rendering for checked inverse plans from VerifiedPatchEngine.
//  The component intentionally has no apply/undo action and is not wired to
//  Agent History: a prepared value can become stale, and only the future
//  descriptor coordinator may revalidate authority and mutate the workspace.
//

import Foundation
import SwiftUI

// MARK: - Display projection

nonisolated enum VerifiedDiffPreviewProjectionError:
    Error,
    Equatable,
    Sendable {
    case invalidUTF8Line(
        operationID: VerifiedPatchOperationID,
        hunkIndex: Int,
        lineIndex: Int
    )
}

/// A projection created only after `VerifiedPatchEngine` has revalidated a
/// complete `PreparedInverse`. It is display data, never mutation authority.
nonisolated struct VerifiedDiffPreviewModel: Equatable, Sendable {
    let patchID: UUID
    let rows: [VerifiedDiffPreviewRow]

    init(prepared: PreparedInverse) throws {
        let previews = try VerifiedPatchEngine.preparedPreviewForReview(
            prepared
        )
        patchID = prepared.patchID
        rows = try previews.enumerated().map { operationIndex, preview in
            try VerifiedDiffPreviewRow(
                operationIndex: operationIndex,
                from: preview
            )
        }
    }
}

nonisolated struct VerifiedDiffPreviewLineRow:
    Sendable,
    Equatable,
    Identifiable {
    let id: Int
    let kind: VerifiedInversePreviewLineKind
    let text: String

    fileprivate init(
        id: Int,
        operationID: VerifiedPatchOperationID,
        hunkIndex: Int,
        from line: VerifiedInversePreviewLine
    ) throws {
        self.id = id
        kind = line.kind
        guard let decoded = VerifiedDiffDisplaySanitizer.sanitizedLine(
            line.bytes
        ) else {
            throw VerifiedDiffPreviewProjectionError.invalidUTF8Line(
                operationID: operationID,
                hunkIndex: hunkIndex,
                lineIndex: id
            )
        }
        text = decoded
    }
}

nonisolated struct VerifiedDiffHunkRow:
    Sendable,
    Equatable,
    Identifiable {
    let id: Int
    let header: String
    let lines: [VerifiedDiffPreviewLineRow]

    fileprivate init(
        index: Int,
        operationID: VerifiedPatchOperationID,
        from hunk: VerifiedInverseHunkPreview
    ) throws {
        id = index
        header = VerifiedDiffDisplaySanitizer.escapeUnsafeScalars(
            in: hunk.header
        )
        lines = try hunk.lines.enumerated().map { lineIndex, line in
            try VerifiedDiffPreviewLineRow(
                id: lineIndex,
                operationID: operationID,
                hunkIndex: index,
                from: line
            )
        }
    }
}

nonisolated struct VerifiedDiffPreviewRow:
    Identifiable,
    Equatable,
    Sendable {
    /// The operation index is part of the ID because a verified operation ID
    /// is semantic identity, while SwiftUI also requires uniqueness if a
    /// malformed in-memory value repeats one. Engine revalidation rejects the
    /// malformed value before production projection.
    struct RowID: Hashable, Sendable {
        let operationID: VerifiedPatchOperationID
        let operationIndex: Int
    }

    let id: RowID
    let kind: VerifiedInversePreviewKind
    let sourcePath: String
    let destinationPath: String?
    let expectedCurrent: VerifiedPatchStateIdentity?
    let result: VerifiedPatchStateIdentity?
    let hunks: [VerifiedDiffHunkRow]

    var displayPath: String {
        destinationPath ?? sourcePath
    }

    var addedLineCount: Int {
        hunks.reduce(0) { total, hunk in
            total + hunk.lines.lazy.filter { $0.kind == .add }.count
        }
    }

    var removedLineCount: Int {
        hunks.reduce(0) { total, hunk in
            total + hunk.lines.lazy.filter { $0.kind == .remove }.count
        }
    }

    fileprivate init(
        operationIndex: Int,
        from preview: VerifiedInverseOperationPreview
    ) throws {
        id = RowID(
            operationID: preview.operationID,
            operationIndex: operationIndex
        )
        kind = preview.kind
        sourcePath = VerifiedDiffDisplaySanitizer.escapeUnsafeScalars(
            in: preview.sourcePath
        )
        destinationPath = preview.destinationPath.map {
            VerifiedDiffDisplaySanitizer.escapeUnsafeScalars(in: $0)
        }
        expectedCurrent = preview.expectedCurrent
        result = preview.result
        hunks = try preview.hunks.enumerated().map { hunkIndex, hunk in
            try VerifiedDiffHunkRow(
                index: hunkIndex,
                operationID: preview.operationID,
                from: hunk
            )
        }
    }
}

nonisolated enum VerifiedDiffDisplaySanitizer {
    /// Planner lines include their terminator bytes. Remove exactly one LF
    /// and its optional CR instead of Unicode trimming, which could hide
    /// additional leading/trailing controls from a security review.
    static func sanitizedLine(_ bytes: Data) -> String? {
        var content = bytes
        if content.last == 0x0A {
            content.removeLast()
            if content.last == 0x0D {
                content.removeLast()
            }
        }
        guard let decoded = String(data: content, encoding: .utf8) else {
            return nil
        }
        return escapeUnsafeScalars(in: decoded)
    }

    /// Escapes every Unicode control/format scalar and visual line separator.
    /// This includes tabs, bidi marks/overrides/isolates, zero-width format
    /// characters, BOM, and C0/C1 controls. Review text therefore cannot forge
    /// rows, indentation, or visual ordering.
    static func escapeUnsafeScalars(in value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            if isUnsafe(scalar) {
                let hexadecimal = String(
                    scalar.value,
                    radix: 16,
                    uppercase: true
                )
                result += "\\u{\(hexadecimal)}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            true
        default:
            false
        }
    }
}

// MARK: - Presentation

@MainActor
extension VerifiedInversePreviewKind {
    var systemImage: String {
        switch self {
        case .applyTextHunks: "doc.text"
        case .restoreExactFile: "arrow.uturn.backward"
        case .removeCreatedFile: "trash"
        case .restoreDeletedFile: "arrow.uturn.backward.circle"
        case .simulateRenamedFile: "rectangle.portrait.and.arrow.right"
        }
    }

    var displayName: String {
        switch self {
        case .applyTextHunks:
            Strings.verifiedDiffKindApplyTextHunks
        case .restoreExactFile:
            Strings.verifiedDiffKindRestoreExactFile
        case .removeCreatedFile:
            Strings.verifiedDiffKindRemoveCreatedFile
        case .restoreDeletedFile:
            Strings.verifiedDiffKindRestoreDeletedFile
        case .simulateRenamedFile:
            Strings.verifiedDiffKindSimulateRenamedFile
        }
    }

    var operationDetail: String {
        switch self {
        case .applyTextHunks:
            Strings.verifiedDiffDetailApplyTextHunks
        case .restoreExactFile:
            Strings.verifiedDiffDetailRestoreExactFile
        case .removeCreatedFile:
            Strings.verifiedDiffDetailRemoveCreatedFile
        case .restoreDeletedFile:
            Strings.verifiedDiffDetailRestoreDeletedFile
        case .simulateRenamedFile:
            Strings.verifiedDiffDetailSimulateRenamedFile
        }
    }
}

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
        HStack(alignment: .firstTextBaseline, spacing: 0) {
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
}

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
        .accessibilityElement(children: .contain)
    }
}

struct VerifiedDiffOperationView: View {
    let row: VerifiedDiffPreviewRow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if row.hunks.isEmpty {
                exactOperationSummary
            } else {
                ForEach(row.hunks) { hunk in
                    VerifiedDiffHunkView(hunk: hunk)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            AccessibilityID.verifiedDiffOperation(
                row.id.operationIndex
            )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: row.kind.systemImage)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(verbatim: row.kind.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
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

    private var exactOperationSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.kind.operationDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let expectedCurrent = row.expectedCurrent {
                identityRow(
                    label: Strings.verifiedDiffExpectedCurrent,
                    identity: expectedCurrent
                )
            }
            if let result = row.result {
                identityRow(
                    label: Strings.verifiedDiffResult,
                    identity: result
                )
            }
        }
        .padding(.leading, 18)
    }

    private func identityRow(
        label: String,
        identity: VerifiedPatchStateIdentity
    ) -> some View {
        Text(verbatim: Strings.verifiedDiffIdentity(
            label: label,
            byteCount: identity.contentIdentity.byteCount,
            sha256: identity.contentIdentity.sha256Hex
        ))
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var changeSummary: String {
        guard row.addedLineCount > 0 || row.removedLineCount > 0 else {
            return ""
        }
        return "+\(row.addedLineCount) −\(row.removedLineCount)"
    }
}

/// A read-only view of a prepared checked inverse.
///
/// The view deliberately provides no mutation action. Its warning is part of
/// the safety contract: preparation describes one snapshot and does not prove
/// that the workspace still matches when a future caller chooses to apply.
struct VerifiedDiffPreviewView: View {
    let model: VerifiedDiffPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryHeader
            Divider()
            stalenessNotice
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(model.rows.enumerated()),
                        id: \.element.id
                    ) { index, row in
                        VerifiedDiffOperationView(row: row)
                        if index < model.rows.count - 1 {
                            Divider().opacity(0.3)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
        .accessibilityIdentifier(AccessibilityID.verifiedDiffPreview)
    }

    private var summaryHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .accessibilityHidden(true)
            Text(verbatim: Strings.verifiedDiffTitle)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Text(verbatim: Strings.verifiedDiffSummary(
                operationCount: model.rows.count,
                addedLineCount: totalAdded,
                removedLineCount: totalRemoved
            ))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var stalenessNotice: some View {
        Label {
            Text(verbatim: Strings.verifiedDiffStalenessNotice)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityIdentifier(
            AccessibilityID.verifiedDiffStalenessNotice
        )
    }

    private var totalAdded: Int {
        model.rows.reduce(0) { $0 + $1.addedLineCount }
    }

    private var totalRemoved: Int {
        model.rows.reduce(0) { $0 + $1.removedLineCount }
    }
}
