//
//  BracketFoldProvider.swift
//  Pine
//
//  Issue #1008 — the universal structural fallback behind the
//  `FoldRangeProviding` seam.
//
//  Wraps the existing `FoldRangeCalculator` (bracket-pair folding) so the
//  LSP-first orchestrator (`FoldingCoordinator`) treats every provider
//  uniformly. This is the behaviour Pine ships when no richer provider claims
//  the document, and the deterministic fallback for every LSP failure mode.
//

import Foundation

/// Bracket-pair folding exposed through ``FoldRangeProviding``. Always
/// available — no capability gate — so it is the terminal fallback in the
/// provider chain.
///
/// Computation runs off the main thread: the calculator is pure and
/// thread-safe (it never touches `NSTextStorage`), so dispatching it keeps the
/// main thread free for the 120 Hz scroll budget.
nonisolated final class BracketFoldProvider: FoldRangeProviding, @unchecked Sendable {

    /// Supplies comment/string skip ranges for the snapshot text so brackets
    /// inside strings and comments are ignored. Captured at request time
    /// against the snapshot's immutable text.
    private let skipRangesProvider: (String) -> [NSRange]

    /// - Parameter skipRanges: Returns the comment/string `NSRange`s to skip
    ///   for a given text. Defaults to no skip ranges.
    init(skipRanges: @escaping (String) -> [NSRange] = { _ in [] }) {
        self.skipRangesProvider = skipRanges
    }

    func canProvide(for snapshot: DocumentSnapshot) -> Bool {
        // The bracket calculator is the universal fallback: it is always
        // available regardless of language or server capability.
        true
    }

    func foldRanges(for snapshot: DocumentSnapshot) async -> [FoldableRange]? {
        let text = snapshot.text
        let skipRanges = skipRangesProvider(text)
        // Pure, thread-safe computation — run off the main thread.
        return await Task.detached(priority: .userInitiated) {
            FoldRangeCalculator.calculate(text: text, skipRanges: skipRanges)
        }.value
    }
}
