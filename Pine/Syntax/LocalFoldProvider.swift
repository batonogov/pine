//
//  LocalFoldProvider.swift
//  Pine
//
//  Issue #1008 — the universal local fallback behind FoldRangeProviding.
//
//  One local provider owns the complete fallback result for a revision:
//  bracket-pair folding for every language, plus indentation suites for
//  Python (whose configured Pyright server has no foldingRange capability).
//

import Foundation

/// Pine's universal local folding provider.
///
/// The provider is always available. Non-Python languages retain exactly the
/// existing bracket-pair fallback. Python keeps those bracket folds and adds
/// declaration/control-flow suites derived from indentation. Combining the
/// two local algorithms happens inside this single provider, so LSP/local
/// ownership remains deterministic and provider results are never merged.
///
/// Syntax extraction and all scanning run on a detached task against an
/// immutable snapshot, so the local fallback never blocks AppKit.
nonisolated struct LocalFoldProvider: FoldRangeProviding {
    private let language: String

    /// Supplies comment/string skip ranges for the snapshot text so brackets
    /// inside strings and comments are ignored. Captured at request time
    /// against the snapshot's immutable text.
    private let skipRangesProvider:
        @Sendable (String) -> [NSRange]

    /// - Parameter skipRanges: Returns the comment/string `NSRange`s to skip
    ///   for a given text. Defaults to no skip ranges.
    init(
        language: String,
        skipRanges:
            @Sendable @escaping (String) -> [NSRange] = { _ in [] }
    ) {
        self.language = language.lowercased()
        self.skipRangesProvider = skipRanges
    }

    func canProvide(for snapshot: DocumentSnapshot) -> Bool {
        // The bracket calculator is the universal fallback: it is always
        // available regardless of language or server capability.
        true
    }

    func foldRanges(for snapshot: DocumentSnapshot) async -> [FoldableRange]? {
        let text = snapshot.text
        let language = language
        let skipRangesProvider = skipRangesProvider
        let task = Task.detached(priority: .userInitiated) {
            () -> [FoldableRange]? in
            guard !Task.isCancelled else { return nil }
            let syntaxSkipRanges = skipRangesProvider(text)
            guard !Task.isCancelled else { return nil }

            let isPython = language == "python"
                || snapshot.uri.lowercased().hasSuffix(".py")
                || snapshot.uri.lowercased().hasSuffix(".pyw")
            let indentationRanges: [FoldableRange]
            let bracketSkipRanges: [NSRange]
            if isPython {
                let analysis = PythonIndentationFoldCalculator.analyze(
                    text: text,
                    additionalSkipRanges: syntaxSkipRanges
                )
                indentationRanges = analysis.ranges
                bracketSkipRanges = analysis.lexicalSkipRanges
            } else {
                indentationRanges = []
                bracketSkipRanges =
                    PythonIndentationFoldCalculator.normalizedRanges(
                        syntaxSkipRanges,
                        boundedBy: (text as NSString).length
                    )
            }

            guard !Task.isCancelled else { return nil }
            let bracketRanges = FoldRangeCalculator.calculate(
                text: text,
                skipRanges: bracketSkipRanges
            )
            guard !Task.isCancelled else { return nil }
            return Self.combinedRanges(
                bracketRanges,
                indentationRanges
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Deterministic ordering keeps the outer indentation suite last for a
    /// shared start line (the gutter's one-icon map then selects it), while
    /// preserving every distinct bracket fold elsewhere.
    private static func combinedRanges(
        _ bracketRanges: [FoldableRange],
        _ indentationRanges: [FoldableRange]
    ) -> [FoldableRange] {
        let sorted = (bracketRanges + indentationRanges).sorted {
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
        return sorted.enumerated().compactMap { index, range in
            index == 0 || range != sorted[index - 1]
                ? range
                : nil
        }
    }
}
