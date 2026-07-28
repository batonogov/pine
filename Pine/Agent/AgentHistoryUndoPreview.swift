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
//  3. One activation must call `revalidate` immediately before apply, without
//     an intervening user decision. A race still fails closed in the engine.
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
    case inversePayloadInvalid(
        AgentHistoryPayloadFailure
    )
    case currentContentDiverged(path: String)
    case previewEncodingFailed
}

/// What the review can truthfully show for one inverse operation.
nonisolated enum AgentHistoryUndoContentKind:
    Equatable,
    Sendable {
    /// Both exact byte snapshots are UTF-8 and fit the bounded line diff.
    case textual
    /// At least one exact byte snapshot is not UTF-8.
    case binary
    /// Text was verified, but intentionally omitted from the bounded preview.
    case omitted
    /// Undo removes the complete file created by the agent.
    case wholeFileRemoval
    /// Undo recreates the complete file deleted by the agent.
    case wholeFileRestore
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
    let contentRepresentation: AgentHistoryUndoContentKind
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
    /// Identity of the exact descriptor snapshot rendered by this review.
    /// Revalidation refuses a same-looking path replacement before apply.
    let previewDevice: UInt64?
    let previewInode: UInt64?

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
        let lineEnding: VerifiedDiffLineEnding
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

/// Deterministic seams used to prove preview-time path swaps fail closed.
/// Production uses `.none`.
nonisolated struct AgentHistoryUndoPreviewHooks: Sendable {
    var beforeSnapshot: (@Sendable (String) -> Void)?
    var afterSnapshot: (@Sendable (String) -> Void)?

    static let none = AgentHistoryUndoPreviewHooks()
}

nonisolated struct AgentHistoryUndoPreviewContext: Sendable {
    let root: URL
    let manifest: AgentHistoryAuthorityManifest
}

/// Pure preparation of a verified undo preview from an entry's change set,
/// inverse payload, and the current workspace root. Performs read-only checks
/// only — no filesystem mutation. `nonisolated` so it runs off the main actor.
nonisolated enum AgentHistoryUndoPreview {
    /// Maximum lines per file to include in the line-level diff. Whole-file
    /// create/delete operations are summarized without a diff regardless.
    private static let maximumDiffLines = 2_000
    private static let maximumDiffCells = 4_000_000

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
        context: AgentHistoryUndoPreviewContext,
        hooks: AgentHistoryUndoPreviewHooks = .none
    ) -> AgentHistoryUndoPreviewResult {
        let root = context.root
        let manifest = context.manifest
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
        let validatedPayload: AgentHistoryValidatedInversePayload
        switch AgentHistoryInversePayloadValidator.validate(
            changeSet: changeSet,
            payload: payload
        ) {
        case .success(let payload):
            validatedPayload = payload
        case .failure(let failure):
            return .unavailable(.inversePayloadInvalid(failure))
        }
        let snapshots: [AgentHistorySafeFileSnapshot]
        switch validatedCurrentSnapshots(
            changes: changeSet.changes,
            root: root,
            expectedRootDevice: manifest.rootDevice,
            expectedRootInode: manifest.rootInode,
            hooks: hooks
        ) {
        case .success(let captured):
            snapshots = captured
        case .failure(let failure):
            return .unavailable(failure)
        }
        guard workspaceGitStateMatches(root: root, manifest: manifest) else {
            return .unavailable(.workspaceChanged)
        }
        guard let model = buildModel(
            entry: entry,
            changeSet: changeSet,
            payload: validatedPayload,
            snapshots: snapshots
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
        payload: AgentHistoryInversePayload,
        expectedPreview: AgentHistoryUndoPreviewModel,
        context: AgentHistoryUndoPreviewContext
    ) -> AgentHistoryUndoPreviewResult {
        let root = context.root
        let manifest = context.manifest
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
        if case .failure(let failure) =
            AgentHistoryInversePayloadValidator.validate(
                changeSet: changeSet,
                payload: payload
            ) {
            return .unavailable(.inversePayloadInvalid(failure))
        }
        let snapshots: [AgentHistorySafeFileSnapshot]
        switch validatedCurrentSnapshots(
            changes: changeSet.changes,
            root: root,
            expectedRootDevice: manifest.rootDevice,
            expectedRootInode: manifest.rootInode
        ) {
        case .success(let current):
            snapshots = current
        case .failure(let failure):
            return .unavailable(failure)
        }
        guard workspaceGitStateMatches(root: root, manifest: manifest) else {
            return .unavailable(.workspaceChanged)
        }
        if let failure = previewIdentityFailure(
            entry: entry,
            changes: changeSet.changes,
            snapshots: snapshots,
            expectedPreview: expectedPreview
        ) {
            return .unavailable(failure)
        }
        // Returning an empty display model intentionally grants no mutation
        // authority. The same payload binding and workspace state were checked
        // above, and the engine repeats both checks during authoritative apply.
        return .available(AgentHistoryUndoPreviewModel(
            historyEntryID: entry.id,
            operations: []
        ))
    }

    /// Captures each current file exactly once through `O_NOFOLLOW`
    /// descriptor traversal, validates those exact bytes, and returns the
    /// immutable snapshots used by model construction. No validated path is
    /// reopened by name.
    static func validatedCurrentSnapshots(
        changes: [AgentHistoryRecordedFileChange],
        root: URL,
        expectedRootDevice: UInt64,
        expectedRootInode: UInt64,
        hooks: AgentHistoryUndoPreviewHooks = .none
    ) -> Result<
        [AgentHistorySafeFileSnapshot],
        AgentHistoryUndoPreviewFailure
    > {
        let workspace: AgentHistorySafeWorkspace
        do {
            workspace = try AgentHistorySafeWorkspace(
                root: root,
                expectedDevice: expectedRootDevice,
                expectedInode: expectedRootInode
            )
        } catch {
            return .failure(.workspaceChanged)
        }

        var snapshots: [AgentHistorySafeFileSnapshot] = []
        snapshots.reserveCapacity(changes.count)
        for change in changes {
            do {
                hooks.beforeSnapshot?(change.relativePath)
                let snapshot = try workspace.snapshot(
                    relativePath: change.relativePath
                )
                guard AgentHistoryCheckedUndoEngine.currentSnapshot(
                    snapshot,
                    matches: change
                ) else {
                    return .failure(
                        .currentContentDiverged(path: change.relativePath)
                    )
                }
                snapshots.append(snapshot)
                hooks.afterSnapshot?(change.relativePath)
            } catch {
                return .failure(
                    .currentContentDiverged(path: change.relativePath)
                )
            }
        }
        guard workspace.isStillBoundToCanonicalPath() else {
            return .failure(.workspaceChanged)
        }
        return .success(snapshots)
    }

    // MARK: - Model construction

    static func buildModel(
        entry: AgentHistoryEntry,
        changeSet: VerifiedAgentChangeSet,
        payload: AgentHistoryValidatedInversePayload,
        snapshots: [AgentHistorySafeFileSnapshot]
    ) -> AgentHistoryUndoPreviewModel? {
        guard snapshots.count == changeSet.changes.count else { return nil }
        var operations: [AgentHistoryUndoPreviewOperation] = []
        for (change, snapshot) in zip(changeSet.changes, snapshots) {
            guard snapshot.relativePath == change.relativePath,
                  let entry = payload[change.relativePath] else {
                return nil
            }
            guard let op = buildOperation(
                change: change,
                entry: entry,
                snapshot: snapshot
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
        snapshot: AgentHistorySafeFileSnapshot
    ) -> AgentHistoryUndoPreviewOperation? {
        let path = change.relativePath
        let safePath = sanitize(path)
        switch change.operation {
        case .modify:
            guard let before = change.before,
                  let after = change.after,
                  let beforeContent = entry.beforeContent,
                  let currentContent = snapshot.data else {
                return nil
            }
            let diff = diffPreview(
                before: beforeContent,
                after: currentContent
            )
            return AgentHistoryUndoPreviewOperation(
                id: path,
                relativePath: safePath,
                kind: .restoreModifiedFile,
                contentRepresentation: diff.representation,
                hunks: diff.hunks,
                expectedContentSHA256: after.contentSHA256,
                expectedByteCount: after.byteCount,
                expectedPermissions: after.permissions,
                resultContentSHA256: before.contentSHA256,
                resultByteCount: before.byteCount,
                resultPermissions: entry.permissions,
                previewDevice: snapshot.device,
                previewInode: snapshot.inode
            )
        case .create:
            return AgentHistoryUndoPreviewOperation(
                id: path,
                relativePath: safePath,
                kind: .removeCreatedFile,
                contentRepresentation: .wholeFileRemoval,
                hunks: [],
                expectedContentSHA256: change.after?.contentSHA256,
                expectedByteCount: change.after?.byteCount,
                expectedPermissions: change.after?.permissions,
                resultContentSHA256: nil,
                resultByteCount: nil,
                resultPermissions: nil,
                previewDevice: snapshot.device,
                previewInode: snapshot.inode
            )
        case .delete:
            guard let before = change.before,
                  entry.beforeContent != nil else {
                return nil
            }
            return AgentHistoryUndoPreviewOperation(
                id: path,
                relativePath: safePath,
                kind: .restoreDeletedFile,
                contentRepresentation: .wholeFileRestore,
                hunks: [],
                expectedContentSHA256: nil,
                expectedByteCount: nil,
                expectedPermissions: nil,
                resultContentSHA256: before.contentSHA256,
                resultByteCount: before.byteCount,
                resultPermissions: entry.permissions ?? before.permissions,
                previewDevice: snapshot.device,
                previewInode: snapshot.inode
            )
        case .rename, .symlink, .unsupported:
            return nil
        }
    }

    // MARK: - Diff

    private struct DiffPreview {
        let representation: AgentHistoryUndoContentKind
        let hunks: [AgentHistoryUndoPreviewHunk]
    }

    private struct DiffLine: Equatable {
        let text: String
        let lineEnding: VerifiedDiffLineEnding
    }

    private struct DiffRow {
        let kind: AgentHistoryUndoPreviewHunk.LineKind
        let line: DiffLine
    }

    /// Builds a bounded textual diff without conflating binary, oversized,
    /// and empty textual content. Line terminators participate in equality, so
    /// a CRLF/LF-only change remains visible and truthful.
    private static func diffPreview(
        before: Data,
        after current: Data
    ) -> DiffPreview {
        guard let beforeLines = decodedLines(before),
              let afterLines = decodedLines(current) else {
            return DiffPreview(representation: .binary, hunks: [])
        }
        guard beforeLines.count <= maximumDiffLines,
              afterLines.count <= maximumDiffLines,
              beforeLines.count * afterLines.count
                <= maximumDiffCells else {
            return DiffPreview(representation: .omitted, hunks: [])
        }
        let diff = lineDiff(before: beforeLines, after: afterLines)
        guard !diff.isEmpty else {
            return DiffPreview(representation: .textual, hunks: [])
        }
        let added = diff.lazy.filter { $0.kind == .add }.count
        let removed = diff.lazy.filter { $0.kind == .remove }.count
        let header = "@@ -1,\(afterLines.count) +1,\(beforeLines.count) @@"
        let hunks = [
            AgentHistoryUndoPreviewHunk(
                id: 0,
                header: header,
                lines: zip(0..., diff).map { index, line in
                    AgentHistoryUndoPreviewHunk.Line(
                        id: index,
                        kind: line.kind,
                        text: line.line.text,
                        lineEnding: line.line.lineEnding
                    )
                }
            )
        ].filter { _ in added > 0 || removed > 0 }
        return DiffPreview(representation: .textual, hunks: hunks)
    }

    /// Splits exact UTF-8 bytes on LF while retaining LF, CRLF, and missing
    /// final-newline identity. Empty data is valid text with zero lines.
    private static func decodedLines(_ data: Data) -> [DiffLine]? {
        guard String(data: data, encoding: .utf8) != nil else { return nil }
        var lines: [DiffLine] = []
        var start = data.startIndex
        var index = start
        while index < data.endIndex {
            if data[index] == 0x0A {
                let end = data.index(after: index)
                let bytes = data[start..<end]
                guard let line = VerifiedDiffDisplaySanitizer.sanitizedLine(
                    Data(bytes)
                ) else {
                    return nil
                }
                lines.append(
                    DiffLine(
                        text: line.text,
                        lineEnding: line.lineEnding
                    )
                )
                start = end
            }
            index = data.index(after: index)
        }
        if start < data.endIndex {
            guard let line = VerifiedDiffDisplaySanitizer.sanitizedLine(
                Data(data[start..<data.endIndex])
            ) else {
                return nil
            }
            lines.append(
                DiffLine(text: line.text, lineEnding: line.lineEnding)
            )
        }
        return lines
    }

    /// A minimal longest-common-subsequence line diff. Returns a flat list of
    /// context/remove/add lines. `before` lines that differ become `.add`
    /// (the undo restores them); `after` lines that differ become `.remove`.
    private static func lineDiff(
        before: [DiffLine],
        after: [DiffLine]
    ) -> [DiffRow] {
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
        if m > 0, n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if before[i] == after[j] {
                        lcs[i][j] = lcs[i + 1][j + 1] + 1
                    } else {
                        lcs[i][j] = max(
                            lcs[i + 1][j],
                            lcs[i][j + 1]
                        )
                    }
                }
            }
        }
        var result: [DiffRow] = []
        var i = 0
        var j = 0
        while i < m && j < n {
            if before[i] == after[j] {
                result.append(DiffRow(kind: .context, line: before[i]))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                // `before` line is not in `after` → the undo adds it.
                result.append(DiffRow(kind: .add, line: before[i]))
                i += 1
            } else {
                // `after` line is not in `before` → the undo removes it.
                result.append(DiffRow(kind: .remove, line: after[j]))
                j += 1
            }
        }
        while i < m {
            result.append(DiffRow(kind: .add, line: before[i]))
            i += 1
        }
        while j < n {
            result.append(DiffRow(kind: .remove, line: after[j]))
            j += 1
        }
        return result
    }

    // MARK: - Helpers

    private static func workspaceGitStateMatches(
        root: URL,
        manifest: AgentHistoryAuthorityManifest
    ) -> Bool {
        AgentHistoryContentHash.headOID(in: root)
            == manifest.capturedHeadOID
            && AgentHistoryContentHash.indexSHA256(in: root)
                == manifest.capturedIndexSHA256
    }

    private static func previewIdentityFailure(
        entry: AgentHistoryEntry,
        changes: [AgentHistoryRecordedFileChange],
        snapshots: [AgentHistorySafeFileSnapshot],
        expectedPreview: AgentHistoryUndoPreviewModel
    ) -> AgentHistoryUndoPreviewFailure? {
        guard expectedPreview.historyEntryID == entry.id,
              expectedPreview.operations.count == changes.count,
              snapshots.count == changes.count else {
            return .projectionTampered
        }
        for ((change, snapshot), operation) in zip(
            zip(changes, snapshots),
            expectedPreview.operations
        ) {
            guard operation.id == change.relativePath else {
                return .projectionTampered
            }
            guard operation.previewDevice == snapshot.device,
                  operation.previewInode == snapshot.inode else {
                return .currentContentDiverged(
                    path: change.relativePath
                )
            }
        }
        return nil
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

    static func mapBlock(
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
        case .inversePayloadInvalid(let failure):
            .inversePayloadInvalid(failure)
        case .fileSystemError, .applyFailed:
            .currentContentDiverged(path: "")
        }
    }
}
