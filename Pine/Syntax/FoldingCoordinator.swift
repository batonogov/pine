//
//  FoldingCoordinator.swift
//  Pine
//
//  Issue #1008, steps 1–3 — the LSP-first structural folding orchestrator.
//
//  Enforces the deterministic layered model from ADR 0001 (#1182):
//    • folding: LSP `textDocument/foldingRange`, then the bracket calculator;
//    • one provider owns folding for a single immutable document revision;
//    • successful results are never merged across providers;
//    • empty / unavailable / timed-out / cancelled / invalid / stale LSP
//      results fall back to the bracket calculator.
//
//  The caller shows the bracket ranges immediately (they are always
//  available); `refine` races the LSP request against a 250 ms deadline and
//  returns the LSP result only when it wins and is not stale.
//

import Foundation
import os

/// Orchestrates LSP-first fold resolution with deterministic fallback to the
/// bracket calculator.
///
/// Owns a ``FoldGeneration`` so a stale in-flight LSP reply (computed against
/// older text) is discarded before it can overwrite newer edits. The LSP
/// request is raced against the deadline and cancelled as soon as either the
/// reply or the timeout resolves, bounding main-thread impact.
///
/// Marked `@unchecked Sendable`: the only mutable state is `generation`,
/// which is internally locked. The coordinator and its providers are
/// `nonisolated` so provider queries never need a main-actor hop (the off-main
/// work is the LSP transport I/O handled below this seam).
nonisolated final class FoldingCoordinator: @unchecked Sendable {

    /// Deadline for an LSP folding request before the local bracket fallback
    /// wins. Chosen by ADR 0001 (#1182) as the p95 latency budget; slower
    /// replies are cancelled and discarded.
    static let lspDeadline: Duration = .milliseconds(250)

    private let bracketProvider: BracketFoldProvider
    private let lspProvider: FoldRangeProviding?
    private let generation = FoldGeneration()

    /// - Parameters:
    ///   - bracketProvider: The universal fallback provider.
    ///   - lspProvider: An optional richer provider (LSP `foldingRange`).
    ///     When `nil`, the coordinator resolves to bracket ranges only.
    init(
        bracketProvider: BracketFoldProvider = BracketFoldProvider(),
        lspProvider: FoldRangeProviding? = nil
    ) {
        self.bracketProvider = bracketProvider
        self.lspProvider = lspProvider
    }

    // MARK: - Generation

    /// The current generation token value. Exposed for tests.
    var generationValue: Int { generation.current }

    /// Invalidates every in-flight request: any result issued before this call
    /// is stale and will be discarded by ``refine(snapshot:bracketRanges:)``.
    @discardableResult
    func invalidate() -> Int {
        generation.increment()
    }

    // MARK: - Resolution

    /// Refines fold ranges using the LSP-first layered model.
    ///
    /// `bracketRanges` are the ranges the caller already computed and shows
    /// immediately (the bracket calculator result for the current text). This
    /// method returns:
    ///   - `.resolved(_, .lsp)` — the LSP provider returned valid ranges
    ///     within the deadline and the revision is still current;
    ///   - `.resolved(bracketRanges, .bracket)` — the LSP provider was
    ///     absent, declined, errored, timed out, or returned invalid/empty
    ///     ranges, so the bracket ranges stand;
    ///   - `.stale` — a newer request superseded this revision; the caller
    ///     discards the result and keeps its current display.
    ///
    /// - Parameters:
    ///   - snapshot: The immutable document snapshot to resolve against.
    ///   - bracketRanges: The already-computed bracket fallback for the same
    ///     text. Shown immediately by the caller; returned as the fallback.
    /// - Returns: The resolution for this revision.
    func refine(
        snapshot: DocumentSnapshot,
        bracketRanges: [FoldableRange]
    ) async -> FoldResolution {
        let issuedGeneration = generation.current

        // Fast path: no richer provider installed — bracket ranges stand.
        guard let lsp = lspProvider, lsp.canProvide(for: snapshot) else {
            return .resolved(bracketRanges, source: .bracket)
        }

        // Bind the provider query to a sendable closure before the race so
        // the task-group body never references the protocol existential
        // directly (the type checker cannot always resolve an existential
        // method call inside `addTask`).
        let query: @Sendable () async -> [FoldableRange]? = {
            await lsp.foldRanges(for: snapshot)
        }

        // Race the LSP request against the deadline. The first to complete
        // wins; the other is cancelled.
        let outcome = await raceLSP(query: query)

        // A newer request superseded this revision — discard regardless of
        // the LSP outcome so a stale reply never overwrites newer edits.
        if generation.isStale(issuedGeneration) {
            return .stale
        }

        switch outcome {
        case .completed(let lspRanges):
            // The provider already normalised its result; fall back to
            // bracket on any invalidity/emptiness.
            if let ranges = lspRanges, !ranges.isEmpty {
                return .resolved(ranges, source: .lsp)
            }
            return .resolved(bracketRanges, source: .bracket)
        case .timedOut, .cancelled, .declined:
            return .resolved(bracketRanges, source: .bracket)
        }
    }

    // MARK: - LSP race

    /// The outcome of racing an LSP folding request against the deadline.
    private enum LSPRaceOutcome: Sendable {
        /// The provider returned a (possibly nil/empty) normalised result.
        case completed([FoldableRange]?)
        /// The provider could not serve the document.
        case declined
        /// The deadline elapsed before the provider replied.
        case timedOut
        /// The race was cancelled (should not occur post-invalidation since
        /// staleness is checked separately).
        case cancelled
    }

    /// Runs the provider query and the deadline timer concurrently; the first
    /// to resolve wins and the other is cancelled.
    private func raceLSP(
        query: @escaping @Sendable () async -> [FoldableRange]?
    ) async -> LSPRaceOutcome {
        await withTaskGroup(of: LSPRaceOutcome.self) { group in
            group.addTask {
                let result = await query()
                return .completed(result)
            }
            group.addTask {
                try? await Task.sleep(for: FoldingCoordinator.lspDeadline)
                return .timedOut
            }
            // The first child to finish decides; cancel the sibling.
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    // MARK: - LSP → Pine normalisation

    /// Converts LSP `FoldingRange` values (0-based lines) into Pine's
    /// `FoldableRange` model (1-based lines, UTF-16 char offsets), validating
    /// each against the snapshot text. Returns `nil` when every range is
    /// invalid or the input is empty.
    ///
    /// - Parameters:
    ///   - ranges: The raw LSP folding ranges.
    ///   - snapshot: The immutable snapshot the ranges were computed for.
    static func normalize(
        _ ranges: [LSPFoldingRange],
        snapshot: DocumentSnapshot
    ) -> [FoldableRange]? {
        guard !ranges.isEmpty else { return nil }

        let ns = snapshot.text as NSString
        let lineStarts = Self.lineStartOffsets(in: ns)

        var normalized: [FoldableRange] = []
        normalized.reserveCapacity(ranges.count)

        for range in ranges {
            guard let foldable = convert(range, lineStarts: lineStarts, totalLength: ns.length) else {
                // Skip invalid ranges but keep going — one bad range must not
                // blank all structure.
                continue
            }
            normalized.append(foldable)
        }

        guard !normalized.isEmpty else { return nil }
        normalized.sort { $0.startLine < $1.startLine }
        return normalized
    }

    /// Converts a single LSP folding range to a `FoldableRange`, rejecting
    /// anything that is out of bounds, inverted, or single-line.
    private static func convert(
        _ range: LSPFoldingRange,
        lineStarts: [Int],
        totalLength: Int
    ) -> FoldableRange? {
        let startLine = range.startLine
        let endLine = range.endLine

        // LSP lines are 0-based; Pine lines are 1-based.
        guard startLine >= 0,
              endLine >= startLine,
              endLine < lineStarts.count else {
            return nil
        }

        let startLinePine = startLine + 1
        let endLinePine = endLine + 1

        // Only multi-line regions are foldable.
        guard endLinePine > startLinePine else { return nil }

        let lineStartOffset = lineStarts[startLine]
        let endLineStart = lineStarts[endLine]
        let endLineEnd: Int
        if endLine + 1 < lineStarts.count {
            endLineEnd = lineStarts[endLine + 1]
        } else {
            endLineEnd = totalLength
        }

        // Optional character offsets within their lines; clamp to the line.
        let startCharIndex: Int
        if let startChar = range.startCharacter, startChar >= 0 {
            let lineLen = lineStarts[startLine + 1] - lineStartOffset
            startCharIndex = lineStartOffset + min(startChar, lineLen)
        } else {
            startCharIndex = lineStartOffset
        }

        let endCharIndex: Int
        if let endChar = range.endCharacter, endChar >= 0 {
            let lineLen = endLineEnd - endLineStart
            endCharIndex = endLineStart + min(endChar, lineLen)
        } else {
            // Default the end to the end of the line (before any trailing
            // newline), mirroring how the bracket calculator places the close
            // bracket offset.
            endCharIndex = max(endLineStart, endLineEnd - 1)
        }

        guard startCharIndex >= 0,
              endCharIndex >= startCharIndex,
              endCharIndex <= totalLength else {
            return nil
        }

        return FoldableRange(
            startLine: startLinePine,
            endLine: endLinePine,
            startCharIndex: startCharIndex,
            endCharIndex: endCharIndex,
            kind: Self.kind(for: range.kind)
        )
    }

    /// Maps an LSP folding `kind` string to a `FoldKind`. LSP kinds are
    /// advisory (comment/imports/region); Pine folds them all the same way, so
    /// they default to `.braces` (the most common structural kind).
    private static func kind(for lspKind: String?) -> FoldKind {
        // Pine's FoldKind only distinguishes bracket shapes; LSP regions are
        // not bracket-shaped. Default to `.braces` — fold behaviour is
        // identical for every kind and the field is only used for rendering.
        .braces
    }

    /// Returns the UTF-16 offset of the start of every line (0-based index →
    /// offset). Index `i` is the offset where line `i` begins; the final entry
    /// is `length` for boundary math.
    private static func lineStartOffsets(in source: NSString) -> [Int] {
        var starts: [Int] = [0]
        let length = source.length
        for i in 0..<length where source.character(at: i) == ASCII.newline {
            starts.append(i + 1)
        }
        starts.append(length)
        return starts
    }
}
