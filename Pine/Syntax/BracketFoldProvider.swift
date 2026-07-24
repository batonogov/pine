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
/// Both syntax-context extraction and bracket scanning run on a detached task
/// against immutable text, so the universal fallback never blocks AppKit.
nonisolated struct BracketFoldProvider: FoldRangeProviding {

    /// Supplies comment/string skip ranges for the snapshot text so brackets
    /// inside strings and comments are ignored. Captured at request time
    /// against the snapshot's immutable text.
    private let skipRangesProvider:
        @Sendable (String) -> [NSRange]

    /// - Parameter skipRanges: Returns the comment/string `NSRange`s to skip
    ///   for a given text. Defaults to no skip ranges.
    init(
        skipRanges:
            @Sendable @escaping (String) -> [NSRange] = { _ in [] }
    ) {
        self.skipRangesProvider = skipRanges
    }

    func canProvide(for snapshot: DocumentSnapshot) -> Bool {
        // The bracket calculator is the universal fallback: it is always
        // available regardless of language or server capability.
        true
    }

    func foldRanges(for snapshot: DocumentSnapshot) async -> [FoldableRange]? {
        let text = snapshot.text
        let skipRangesProvider = skipRangesProvider
        let task = Task.detached(priority: .userInitiated) {
            () -> [FoldableRange]? in
            guard !Task.isCancelled else { return nil }
            let skipRanges = skipRangesProvider(text)
            guard !Task.isCancelled else { return nil }
            return FoldRangeCalculator.calculate(
                text: text,
                skipRanges: skipRanges
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
