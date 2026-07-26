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
        let review = try VerifiedPatchEngine.preparedPreviewForReview(
            prepared
        )
        patchID = review.patchID
        rows = try review.operations.enumerated().map { operationIndex, operation in
            try VerifiedDiffPreviewRow(
                operationIndex: operationIndex,
                from: operation
            )
        }
    }
}

nonisolated enum VerifiedDiffLineEnding: Sendable, Equatable, Hashable {
    case lf
    case crlf
    case noFinalNewline
}

nonisolated struct VerifiedDiffSanitizedLine: Sendable, Equatable {
    let text: String
    let lineEnding: VerifiedDiffLineEnding
}

nonisolated struct VerifiedDiffPreviewLineRow:
    Sendable,
    Equatable,
    Identifiable {
    let id: Int
    let kind: VerifiedInversePreviewLineKind
    let text: String
    let lineEnding: VerifiedDiffLineEnding

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
        text = decoded.text
        lineEnding = decoded.lineEnding
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

nonisolated struct VerifiedDiffPathStateRow: Sendable, Equatable {
    let path: String
    let identity: VerifiedPatchStateIdentity?

    fileprivate init(from state: VerifiedPreparedReviewPathState) {
        path = VerifiedDiffDisplaySanitizer.escapeUnsafeScalars(
            in: state.path
        )
        identity = state.identity
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
    let operationKind: VerifiedPatchOperationKind
    let preparedMode: VerifiedPatchPreparedMode
    let previewKind: VerifiedInversePreviewKind
    let sourcePath: String
    let destinationPath: String?
    let expectations: [VerifiedDiffPathStateRow]
    let results: [VerifiedDiffPathStateRow]
    let hunks: [VerifiedDiffHunkRow]

    var displayPath: String {
        destinationPath ?? sourcePath
    }

    /// Presentation follows the prepared application mode, not the shape of
    /// the optional visual hunks.
    var presentationKind: VerifiedInversePreviewKind {
        switch preparedMode {
        case .checkedText:
            .applyTextHunks
        case .exactState:
            switch operationKind {
            case .modify:
                .restoreExactFile
            case .create:
                .removeCreatedFile
            case .delete:
                .restoreDeletedFile
            case .rename:
                .simulateRenamedFile
            }
        }
    }

    var isMetadataOnly: Bool {
        guard expectations.count == 1,
              results.count == 1,
              let expected = expectations[0].identity,
              let result = results[0].identity else {
            return false
        }
        return expected.contentIdentity == result.contentIdentity
            && expected != result
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
        from operation: VerifiedPreparedInverseReviewOperation
    ) throws {
        id = RowID(
            operationID: operation.operationID,
            operationIndex: operationIndex
        )
        operationKind = operation.operationKind
        preparedMode = operation.preparedMode
        previewKind = operation.previewKind
        sourcePath = VerifiedDiffDisplaySanitizer.escapeUnsafeScalars(
            in: operation.sourcePath
        )
        destinationPath = operation.destinationPath.map {
            VerifiedDiffDisplaySanitizer.escapeUnsafeScalars(in: $0)
        }
        expectations = operation.expectations.map(
            VerifiedDiffPathStateRow.init
        )
        results = operation.results.map(VerifiedDiffPathStateRow.init)
        hunks = try operation.hunks.enumerated().map { hunkIndex, hunk in
            try VerifiedDiffHunkRow(
                index: hunkIndex,
                operationID: operation.operationID,
                from: hunk
            )
        }
    }
}

nonisolated enum VerifiedDiffDisplaySanitizer {
    /// Planner lines include their terminator bytes. Preserve the exact
    /// terminator as display data instead of trimming it into the same visual
    /// form. A line without a terminator is the final line without a newline.
    static func sanitizedLine(_ bytes: Data) -> VerifiedDiffSanitizedLine? {
        var content = bytes
        let lineEnding: VerifiedDiffLineEnding
        if content.suffix(2).elementsEqual([0x0D, 0x0A]) {
            content.removeLast(2)
            lineEnding = .crlf
        } else if content.last == 0x0A {
            content.removeLast()
            lineEnding = .lf
        } else {
            lineEnding = .noFinalNewline
        }
        guard let decoded = String(data: content, encoding: .utf8) else {
            return nil
        }
        return VerifiedDiffSanitizedLine(
            text: escapeUnsafeScalars(in: decoded),
            lineEnding: lineEnding
        )
    }

    /// Escapes backslashes plus every Unicode control/format scalar and visual
    /// line separator. Escaping the escape introducer makes the mapping
    /// injective: a literal `\u{202E}` cannot collide with an actual U+202E.
    static func escapeUnsafeScalars(in value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            if scalar.value == 0x5C || isUnsafe(scalar) {
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

    func displayName(locale: Locale) -> String {
        switch self {
        case .applyTextHunks:
            Strings.verifiedDiffKindApplyTextHunks(locale: locale)
        case .restoreExactFile:
            Strings.verifiedDiffKindRestoreExactFile(locale: locale)
        case .removeCreatedFile:
            Strings.verifiedDiffKindRemoveCreatedFile(locale: locale)
        case .restoreDeletedFile:
            Strings.verifiedDiffKindRestoreDeletedFile(locale: locale)
        case .simulateRenamedFile:
            Strings.verifiedDiffKindSimulateRenamedFile(locale: locale)
        }
    }

    func operationDetail(locale: Locale) -> String {
        switch self {
        case .applyTextHunks:
            Strings.verifiedDiffDetailApplyTextHunks(locale: locale)
        case .restoreExactFile:
            Strings.verifiedDiffDetailRestoreExactFile(locale: locale)
        case .removeCreatedFile:
            Strings.verifiedDiffDetailRemoveCreatedFile(locale: locale)
        case .restoreDeletedFile:
            Strings.verifiedDiffDetailRestoreDeletedFile(locale: locale)
        case .simulateRenamedFile:
            Strings.verifiedDiffDetailSimulateRenamedFile(locale: locale)
        }
    }
}

private struct VerifiedDiffLineView: View {
    @Environment(\.locale) private var locale
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
            Text(verbatim: lineEndingMarker)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
        }
        .font(.system(size: 12, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityLabel(
            Text(verbatim: prefix + line.text + ", " + lineEndingName)
        )
    }

    private var lineEndingMarker: String {
        switch line.lineEnding {
        case .lf:
            Strings.verifiedDiffLineEndingLF(locale: locale)
        case .crlf:
            Strings.verifiedDiffLineEndingCRLF(locale: locale)
        case .noFinalNewline:
            Strings.verifiedDiffNoFinalNewline(locale: locale)
        }
    }

    private var lineEndingName: String {
        lineEndingMarker
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
    @Environment(\.locale) private var locale
    let row: VerifiedDiffPreviewRow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            operationSummary
            if !row.hunks.isEmpty {
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
            Image(systemName: row.presentationKind.systemImage)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(
                verbatim: row.presentationKind.displayName(locale: locale)
            )
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

    private var operationSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(
                verbatim: row.presentationKind.operationDetail(locale: locale)
            )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if row.isMetadataOnly {
                Text(
                    verbatim: Strings.verifiedDiffMetadataOnly(locale: locale)
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
            }
            ForEach(
                Array(row.expectations.enumerated()),
                id: \.offset
            ) { _, state in
                identityRow(
                    label: Strings.verifiedDiffExpectedCurrent(locale: locale),
                    state: state
                )
            }
            ForEach(
                Array(row.results.enumerated()),
                id: \.offset
            ) { _, state in
                identityRow(
                    label: Strings.verifiedDiffResult(locale: locale),
                    state: state
                )
            }
        }
        .padding(.leading, 18)
    }

    private func identityRow(
        label: String,
        state: VerifiedDiffPathStateRow
    ) -> some View {
        Group {
            if let identity = state.identity {
                Text(verbatim: Strings.verifiedDiffIdentity(
                    label: label,
                    path: state.path,
                    identity: identity,
                    locale: locale
                ))
            } else {
                Text(verbatim: Strings.verifiedDiffAbsentIdentity(
                    label: label,
                    path: state.path,
                    locale: locale
                ))
            }
        }
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
    @Environment(\.locale) private var locale
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
            Text(verbatim: Strings.verifiedDiffTitle(locale: locale))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Text(verbatim: Strings.verifiedDiffSummary(
                operationCount: model.rows.count,
                addedLineCount: totalAdded,
                removedLineCount: totalRemoved,
                locale: locale
            ))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var stalenessNotice: some View {
        Label {
            Text(
                verbatim: Strings.verifiedDiffStalenessNotice(locale: locale)
            )
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
