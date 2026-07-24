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

    /// One-shot continuation gate used by the unstructured deadline race.
    /// A task group cannot enforce a hard deadline when a provider ignores
    /// cancellation because structured concurrency waits for every child
    /// before returning from the group scope.
    nonisolated private final class LSPRaceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: LSPRaceOutcome?
        private var continuation:
            CheckedContinuation<LSPRaceOutcome, Never>?
        private var tasks: [Task<Void, Never>] = []

        func install(
            _ continuation: CheckedContinuation<LSPRaceOutcome, Never>
        ) {
            let completedOutcome: LSPRaceOutcome? = lock.withLock {
                if let outcome {
                    return outcome
                }
                self.continuation = continuation
                return nil
            }
            if let completedOutcome {
                continuation.resume(returning: completedOutcome)
            }
        }

        func install(tasks: [Task<Void, Never>]) {
            let shouldCancel = lock.withLock {
                if outcome != nil {
                    return true
                }
                self.tasks = tasks
                return false
            }
            if shouldCancel {
                tasks.forEach { $0.cancel() }
            }
        }

        func resolve(_ outcome: LSPRaceOutcome) {
            let completion:
                (
                    CheckedContinuation<LSPRaceOutcome, Never>?,
                    [Task<Void, Never>]
                )? = lock.withLock {
                    guard self.outcome == nil else { return nil }
                    self.outcome = outcome
                    let completion = (continuation, tasks)
                    continuation = nil
                    tasks = []
                    return completion
                }
            guard let completion else { return }
            completion.1.forEach { $0.cancel() }
            completion.0?.resume(returning: outcome)
        }
    }

    /// Runs the provider query and the deadline timer concurrently; the first
    /// to resolve wins and the other is cancelled. The continuation gate lets
    /// this method return at the deadline even if a third-party provider does
    /// not cooperate with cancellation.
    private func raceLSP(
        query: @escaping @Sendable () async -> [FoldableRange]?
    ) async -> LSPRaceOutcome {
        let gate = LSPRaceGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let queryTask = Task {
                    let result = await query()
                    gate.resolve(.completed(result))
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(
                            for: FoldingCoordinator.lspDeadline
                        )
                    } catch {
                        return
                    }
                    gate.resolve(.timedOut)
                }
                gate.install(tasks: [queryTask, timeoutTask])
            }
        } onCancel: {
            gate.resolve(.cancelled)
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

        let source = snapshot.text as NSString
        let lines = Self.lineBounds(in: source)

        var normalized: [FoldableRange] = []
        normalized.reserveCapacity(ranges.count)

        for range in ranges {
            guard let foldable = convert(
                range,
                lines: lines,
                source: source
            ) else {
                // Skip invalid ranges but keep going — one bad range must not
                // blank all structure.
                continue
            }
            normalized.append(foldable)
        }

        guard !normalized.isEmpty else { return nil }
        normalized.sort {
            if $0.startLine != $1.startLine {
                return $0.startLine < $1.startLine
            }
            if $0.endLine != $1.endLine {
                return $0.endLine < $1.endLine
            }
            if $0.startCharIndex != $1.startCharIndex {
                return $0.startCharIndex < $1.startCharIndex
            }
            return $0.endCharIndex < $1.endCharIndex
        }
        return normalized.enumerated().compactMap { index, range in
            index == 0 || range != normalized[index - 1] ? range : nil
        }
    }

    private struct LineBounds {
        let start: Int
        /// Offset immediately after the final content code unit, excluding
        /// `\n`, `\r\n`, or `\r`.
        let contentEnd: Int
    }

    /// Converts a single LSP folding range to a `FoldableRange`, rejecting
    /// anything that is out of bounds, inverted, or single-line.
    private static func convert(
        _ range: LSPFoldingRange,
        lines: [LineBounds],
        source: NSString
    ) -> FoldableRange? {
        let startLine = range.startLine
        let endLine = range.endLine

        // LSP lines are 0-based; Pine lines are 1-based.
        guard startLine >= 0,
              endLine >= startLine,
              endLine < lines.count else {
            return nil
        }

        let startLinePine = startLine + 1
        let endLinePine = endLine + 1

        // Only multi-line regions are foldable.
        guard endLinePine > startLinePine else { return nil }

        guard let startCharIndex = characterOffset(
            range.startCharacter,
            in: lines[startLine],
            source: source,
            encoding: range.positionEncoding
        ),
        let endCharIndex = characterOffset(
            range.endCharacter,
            in: lines[endLine],
            source: source,
            encoding: range.positionEncoding
        ) else {
            return nil
        }

        guard startCharIndex >= 0,
              endCharIndex >= startCharIndex,
              endCharIndex <= source.length else {
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

    /// Converts one negotiated LSP line-relative offset to Pine's UTF-16
    /// document offset. Missing offsets default to the content length of the
    /// line as required by `FoldingRange`; invalid, unsupported, or
    /// mid-scalar UTF-8 offsets are rejected.
    private static func characterOffset(
        _ encodedOffset: Int?,
        in line: LineBounds,
        source: NSString,
        encoding: LSPPositionEncoding
    ) -> Int? {
        if case .unknown = encoding {
            return nil
        }

        guard let encodedOffset else { return line.contentEnd }
        guard encodedOffset >= 0 else { return nil }

        let utf16Length = line.contentEnd - line.start
        switch encoding {
        case .utf16:
            guard encodedOffset <= utf16Length else { return nil }
            return line.start + encodedOffset
        case .utf8:
            let lineText = source.substring(
                with: NSRange(location: line.start, length: utf16Length)
            )
            let utf8 = lineText.utf8
            guard encodedOffset <= utf8.count,
                  let utf8Index = utf8.index(
                    utf8.startIndex,
                    offsetBy: encodedOffset,
                    limitedBy: utf8.endIndex
                  ),
                  let utf16Index = utf8Index.samePosition(
                    in: lineText.utf16
                  ) else {
                return nil
            }
            let converted = lineText.utf16.distance(
                from: lineText.utf16.startIndex,
                to: utf16Index
            )
            return line.start + converted
        case .unknown:
            return nil
        }
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

    /// Splits a snapshot using the three LSP line endings. The final empty
    /// line is represented only when the document actually ends in a line
    /// terminator, so a plain document never gains a phantom line at EOF.
    private static func lineBounds(in source: NSString) -> [LineBounds] {
        var lines: [LineBounds] = []
        let length = source.length
        var lineStart = 0
        var index = 0

        while index < length {
            let character = source.character(at: index)
            if character == ASCII.carriageReturn {
                lines.append(
                    LineBounds(start: lineStart, contentEnd: index)
                )
                if index + 1 < length,
                   source.character(at: index + 1) == ASCII.newline {
                    index += 2
                } else {
                    index += 1
                }
                lineStart = index
            } else if character == ASCII.newline {
                lines.append(
                    LineBounds(start: lineStart, contentEnd: index)
                )
                index += 1
                lineStart = index
            } else {
                index += 1
            }
        }

        lines.append(LineBounds(start: lineStart, contentEnd: length))
        return lines
    }
}
