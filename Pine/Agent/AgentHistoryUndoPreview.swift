//
//  AgentHistoryUndoPreview.swift
//  Pine
//
//  Read-only, verified preview for a checked Agent History undo (#1237).
//
//  `AgentHistoryCheckedUndoEngine.apply` performs the authoritative
//  revalidation + atomic apply, but until #1237 it was reached through a
//  one-line confirmation alert that showed no diff. This model is the
//  display-only bridge: it loads the owner-private authority and inverse
//  payload, runs the engine's pure preflight + read-only content-divergence
//  check (no filesystem mutation), and projects a human-readable, line-level
//  preview of every file operation the undo will perform.
//
//  Safety contract:
//  1. Preparation never mutates the workspace — it only reads current bytes
//     and compares them to the recorded after-state.
//  2. A stale or unverifiable preview is reported as a structured result; the
//     engine never falls back to a heuristic.
//  3. The UI must call `revalidate` immediately before enabling/applying Undo.
//     A race between preview and apply fails closed inside the engine.
//

import Foundation

/// Why a verified undo preview could not be prepared.
nonisolated enum AgentHistoryUndoPreviewFailure:
    Error,
    Equatable,
    Sendable {
    case entryNotFound
    case alreadyReverted
    case notEligible
    case authorityRecordMissing
    case authorityConsumed
    case workspaceChanged
    case projectionTampered
    case inversePayloadMissing
    case currentContentDiverged(path: String)
    case previewEncodingFailed
}

/// One resolved file operation in a verified undo preview.
nonisolated struct AgentHistoryUndoPreviewOperation:
    Identifiable,
    Equatable,
    Sendable {
    enum Kind: Sendable, Equatable {
        case restoreModifiedFile
        case removeCreatedFile
        case restoreDeletedFile
    }

    /// Stable identity for SwiftUI `ForEach`.
    let id: String
    let relativePath: String
    let kind: Kind
    /// Human-readable, sanitized diff hunks. Empty for whole-file
    /// create/delete operations that have no line-level delta to show.
    let hunks: [AgentHistoryUndoPreviewHunk]
    /// Recorded SHA-256 of the file content the engine expects to find on disk
    /// right now (the captured *after* state for modify/create; absent for
    /// delete). Shown under Technical Details only.
    let expectedContentSHA256: String?
    let expectedByteCount: UInt64?
    let expectedPermissions: UInt16?
    /// Recorded SHA-256 of the content the undo will restore (the captured
    /// *before* state for modify/delete; absent for create). Technical Details.
    let resultContentSHA256: String?
    let resultByteCount: UInt64?
    let resultPermissions: UInt16?

    var addedLineCount: Int {
        hunks.reduce(0) { $0 + $1.addedLineCount }
    }

    var removedLineCount: Int {
        hunks.reduce(0) { $0 + $1.removedLineCount }
    }
}

/// A contiguous run of added/removed/context lines in a preview diff.
nonisolated struct AgentHistoryUndoPreviewHunk:
    Identifiable,
    Equatable,
    Sendable {
    enum LineKind: Sendable, Equatable {
        case context
        case remove
        case add
    }

    struct Line: Identifiable, Equatable, Sendable {
        let id: Int
        let kind: LineKind
        let text: String
    }

    let id: Int
    /// Header like "@@ -10,3 +10,4 @@" describing the before/after ranges.
    let header: String
    let lines: [Line]

    var addedLineCount: Int {
        lines.lazy.filter { $0.kind == .add }.count
    }

    var removedLineCount: Int {
        lines.lazy.filter { $0.kind == .remove }.count
    }
}

/// Result of preparing a verified undo preview. `available` carries a fully
/// revalidated, display-only model; every other case explains why Undo must
/// stay disabled and what the safe next action is.
nonisolated enum AgentHistoryUndoPreviewResult: Sendable, Equatable {
    case available(AgentHistoryUndoPreviewModel)
    case unavailable(AgentHistoryUndoPreviewFailure)
}

/// Display-only projection of a verified undo. Constructed only after the
/// engine's pure preflight and read-only content-divergence check pass.
nonisolated struct AgentHistoryUndoPreviewModel: Equatable, Sendable {
    let historyEntryID: UUID
    let operations: [AgentHistoryUndoPreviewOperation]

    var totalAddedLines: Int {
        operations.reduce(0) { $0 + $1.addedLineCount }
    }

    var totalRemovedLines: Int {
        operations.reduce(0) { $0 + $1.removedLineCount }
    }
}

/// Pure preparation of a verified undo preview from an entry's change set,
/// inverse payload, and the current workspace root. Performs read-only checks
/// only — no filesystem mutation. `nonisolated` so it runs off the main actor.
nonisolated enum AgentHistoryUndoPreview {
    /// Maximum lines per file to include in the line-level diff. Whole-file
    /// create/delete operations are summarized without a diff regardless.
    private static let maximumDiffLines = 2_000

    /// Prepares a verified undo preview for `entry`.
    ///
    /// The caller must guarantee `changeSet` and `payload` belong to `entry`
    /// (the store resolves them). This method re-runs the engine's pure
    /// preflight, loads the owner-private authority, verifies the workspace
    /// root and Git state, and checks every file's current identity against
    /// the recorded after-state — all without writing a byte.
    static func prepare(
        entry: AgentHistoryEntry,
        changeSet: VerifiedAgentChangeSet,
        payload: AgentHistoryInversePayload,
        root: URL,
        manifest: AgentHistoryAuthorityManifest
    ) -> AgentHistoryUndoPreviewResult {
        guard !entry.reverted else {
            return .unavailable(.alreadyReverted)
        }
        guard AgentHistoryUndoPreflight.evaluate(entry)
            == .readyForPrivateAuthorityValidation else {
            return .unavailable(.notEligible)
        }
        if manifest.consumed {
            return .unavailable(.authorityConsumed)
        }
        if let blocked = AgentHistoryCheckedUndoEngine.preflight(
            entry: entry,
            changeSet: changeSet,
            currentRoot: root,
            manifest: manifest
        ) {
            return .unavailable(mapBlock(blocked))
        }
        if let blocked = AgentHistoryCheckedUndoEngine.contentDivergence(
            changeSet: changeSet,
            root: root,
            manifest: manifest
        ) {
            return .unavailable(mapBlock(blocked))
        }
        guard let model = buildModel(
            entry: entry,
            changeSet: changeSet,
            payload: payload,
            root: root
        ) else {
            return .unavailable(.previewEncodingFailed)
        }
        return .available(model)
    }

    /// Revalidates an already-prepared preview immediately before applying
    /// Undo. Returns the same structured result as `prepare`; the UI disables
    /// the Undo button on any non-`available` outcome.
    static func revalidate(
        entry: AgentHistoryEntry,
        changeSet: VerifiedAgentChangeSet,
        root: URL,
        manifest: AgentHistoryAuthorityManifest
    ) -> AgentHistoryUndoPreviewResult {
        guard !entry.reverted else {
            return .unavailable(.alreadyReverted)
        }
        if manifest.consumed {
            return .unavailable(.authorityConsumed)
        }
        if let blocked = AgentHistoryCheckedUndoEngine.preflight(
            entry: entry,
            changeSet: changeSet,
            currentRoot: root,
            manifest: manifest
        ) {
            return .unavailable(mapBlock(blocked))
        }
        if let blocked = AgentHistoryCheckedUndoEngine.contentDivergence(
            changeSet: changeSet,
            root: root,
            manifest: manifest
        ) {
            return .unavailable(mapBlock(blocked))
        }
        // The payload is not needed for revalidation; preflight + divergence
        // are sufficient to prove the workspace still matches. The engine
        // re-checks the payload binding during apply.
        return .available(AgentHistoryUndoPreviewModel(
            historyEntryID: entry.id,
            operations: []
        ))
    }

    // MARK: - Model construction

    private static func buildModel(
        entry: AgentHistoryEntry,
        changeSet: VerifiedAgentChangeSet,
        payload: AgentHistoryInversePayload,
        root: URL
    ) -> AgentHistoryUndoPreviewModel? {
        let entriesByPath = Dictionary(
            payload.entries.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var operations: [AgentHistoryUndoPreviewOperation] = []
        for change in changeSet.changes {
            guard let entry = entriesByPath[change.relativePath] else {
                return nil
            }
            guard let op = buildOperation(
                change: change,
                entry: entry,
                root: root
            ) else {
                return nil
            }
            operations.append(op)
        }
        return AgentHistoryUndoPreviewModel(
            historyEntryID: entry.id,
            operations: operations
        )
    }

    private static func buildOperation(
        change: AgentHistoryRecordedFileChange,
        entry: AgentHistoryInverseFileEntry,
        root: URL
    ) -> AgentHistoryUndoPreviewOperation? {
        let path = change.relativePath
        let safePath = sanitize(path)
        switch change.operation {
        case .modify:
            guard let before = change.before,
                  let after = change.after,
                  let beforeContent = entry.beforeContent else {
                return nil
            }
            let currentContent = readCurrentBytes(
                relativePath: path,
                root: root
            )
            return AgentHistoryUndoPreviewOperation(
                id: path,
                relativePath: safePath,
                kind: .restoreModifiedFile,
                hunks: diffHunks(
                    before: beforeContent,
                    after: currentContent
                ),
                expectedContentSHA256: after.contentSHA256,
                expectedByteCount: after.byteCount,
                expectedPermissions: after.permissions,
                resultContentSHA256: before.contentSHA256,
                resultByteCount: before.byteCount,
                resultPermissions: entry.permissions
            )
        case .create:
            return AgentHistoryUndoPreviewOperation(
                id: path,
                relativePath: safePath,
                kind: .removeCreatedFile,
                hunks: [],
                expectedContentSHA256: change.after?.contentSHA256,
                expectedByteCount: change.after?.byteCount,
                expectedPermissions: change.after?.permissions,
                resultContentSHA256: nil,
                resultByteCount: nil,
                resultPermissions: nil
            )
        case .delete:
            guard let before = change.before,
                  let beforeContent = entry.beforeContent else {
                return nil
            }
            return AgentHistoryUndoPreviewOperation(
                id: path,
                relativePath: safePath,
                kind: .restoreDeletedFile,
                hunks: [],
                expectedContentSHA256: nil,
                expectedByteCount: nil,
                expectedPermissions: nil,
                resultContentSHA256: before.contentSHA256,
                resultByteCount: before.byteCount,
                resultPermissions: entry.permissions ?? before.permissions
            )
        case .rename, .symlink, .unsupported:
            return nil
        }
    }

    // MARK: - Diff

    /// Produces a single hunk with unified-style added/removed/context lines
    /// by diffing the before (restored) bytes against the current (after)
    /// bytes. Bounded to `maximumDiffLines` per side; larger files produce an
    /// empty hunk list and rely on the operation summary instead.
    private static func diffHunks(
        before: Data,
        after current: Data?
    ) -> [AgentHistoryUndoPreviewHunk] {
        let beforeLines = splitLines(before)
        // The undo restores `before`; the current workspace holds `after`.
        // From the undo's perspective, `before` lines are *added* (restored)
        // and `after` lines are *removed`.
        let afterLines = current.map(splitLines) ?? []
        guard beforeLines.count <= maximumDiffLines,
              afterLines.count <= maximumDiffLines else {
            return []
        }
        let diff = lineDiff(before: beforeLines, after: afterLines)
        guard !diff.isEmpty else {
            return []
        }
        let added = diff.lazy.filter { $0.kind == .add }.count
        let removed = diff.lazy.filter { $0.kind == .remove }.count
        let header = "@@ -1,\(afterLines.count) +1,\(beforeLines.count) @@"
        return [
            AgentHistoryUndoPreviewHunk(
                id: 0,
                header: header,
                lines: zip(0..., diff).map { index, line in
                    AgentHistoryUndoPreviewHunk.Line(
                        id: index,
                        kind: line.kind,
                        text: line.text
                    )
                }
            )
        ].filter { added > 0 || removed > 0 }
    }

    /// Splits bytes into lines, preserving the terminator kind for display.
    private static func splitLines(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else {
            // Non-UTF8 file: surface the raw byte count only.
            return []
        }
        return text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { sanitize(String($0)) }
    }

    /// A minimal longest-common-subsequence line diff. Returns a flat list of
    /// context/remove/add lines. `before` lines that differ become `.add`
    /// (the undo restores them); `after` lines that differ become `.remove`.
    private static func lineDiff(
        before: [String],
        after: [String]
    ) -> [(kind: AgentHistoryUndoPreviewHunk.LineKind, text: String)] {
        let m = before.count
        let n = after.count
        if m == 0 && n == 0 {
            return []
        }
        // LCS table. Bounded by maximumDiffLines^2 which is acceptable for
        // the preview's line cap (2_000 → 4M cells worst case, matching the
        // patch engine's per-diff LCS budget).
        var lcs = Array(
            repeating: Array(repeating: 0, count: n + 1),
            count: m + 1
        )
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                if before[i] == after[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var result: [(AgentHistoryUndoPreviewHunk.LineKind, String)] = []
        var i = 0
        var j = 0
        while i < m && j < n {
            if before[i] == after[j] {
                result.append((.context, before[i]))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                // `before` line is not in `after` → the undo adds it.
                result.append((.add, before[i]))
                i += 1
            } else {
                // `after` line is not in `before` → the undo removes it.
                result.append((.remove, after[j]))
                j += 1
            }
        }
        while i < m {
            result.append((.add, before[i]))
            i += 1
        }
        while j < n {
            result.append((.remove, after[j]))
            j += 1
        }
        return result
    }

    // MARK: - Helpers

    private static func readCurrentBytes(
        relativePath: String,
        root: URL
    ) -> Data? {
        let url = root.appendingPathComponent(
            relativePath,
            isDirectory: false
        )
        return try? Data(contentsOf: url)
    }

    /// Escapes control/format scalars and backslashes so the preview can never
    /// smuggle a bidirectional-override or fake a line break. Mirrors the
    /// sanitizer in `VerifiedDiffPreviewView`.
    private static func sanitize(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            if scalar.value == 0x5C || isUnsafe(scalar) {
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result += "\\u{\(hex)}"
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

    private static func mapBlock(
        _ reason: AgentHistoryEngineBlockReason
    ) -> AgentHistoryUndoPreviewFailure {
        switch reason {
        case .authorityRecordMissing: .authorityRecordMissing
        case .authorityConsumed: .authorityConsumed
        case .workspaceRootMismatch, .workspaceGitStateChanged:
            .workspaceChanged
        case .projectionTampered: .projectionTampered
        case .currentContentDiverged(let path):
            .currentContentDiverged(path: path)
        case .inversePayloadMissing: .inversePayloadMissing
        case .fileSystemError, .applyFailed:
            .currentContentDiverged(path: "")
        }
    }
}
