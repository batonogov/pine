//
//  TerminalBufferSearch.swift
//  Pine
//
//  Pure helper that scans terminal buffer text for search matches.
//
//  Extracted verbatim from `TerminalTab.search(for:)` (TerminalSession.swift)
//  so the match-finding algorithm can be unit-tested directly, without a
//  live SwiftTerm `LocalProcessTerminalView`, a `Task.detached` hop, or
//  `getBufferAsData()`. The behaviour is identical to the previously
//  inlined implementation — only the call site changed.
//

import Foundation

/// Scans newline-delimited terminal buffer text for occurrences of a query,
/// returning one ``TerminalSearchMatch`` per occurrence together with the
/// total number of rows scanned.
///
/// This is the pure, AppKit/SwiftTerm-free core of the terminal find bar.
/// `TerminalTab.search(for:)` feeds it the buffer text it extracts via
/// SwiftTerm's public `getBufferAsData()` API.
///
/// - Note: `query` must be non-empty. The call site (`TerminalTab.search`)
///   short-circuits on an empty query before reaching this helper; passing an
///   empty query here would loop forever on every position (matching the
///   historical inlined behaviour), so callers are expected to guard first.
nonisolated enum TerminalBufferSearch {

    /// Scans `bufferText` (rows separated by `\n`) for `query`.
    ///
    /// - Parameters:
    ///   - bufferText: Full buffer contents as decoded from
    ///     `Terminal.getBufferAsData()`. Rows are separated by `\n`; empty
    ///     rows are preserved (so the row index of each match matches what the
    ///     user sees in the terminal).
    ///   - query: The non-empty search needle.
    ///   - caseSensitive: When `false`, both the needle and each haystack row
    ///     are lowercased before matching (the default terminal-search
    ///     behaviour).
    /// - Returns: A tuple of the matches in reading order and the total number
    ///   of rows (`totalRows`), used by `TerminalTab` for scroll positioning.
    static func scan(
        bufferText: String,
        query: String,
        caseSensitive: Bool
    ) -> (matches: [TerminalSearchMatch], totalRows: Int) {
        let lines = bufferText.split(separator: "\n", omittingEmptySubsequences: false)
        let needle = caseSensitive ? query : query.lowercased()
        var result: [TerminalSearchMatch] = []
        for (row, line) in lines.enumerated() {
            let haystack = caseSensitive ? String(line) : String(line).lowercased()
            var searchStart = haystack.startIndex
            while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
                let col = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                let length = haystack.distance(from: range.lowerBound, to: range.upperBound)
                result.append(TerminalSearchMatch(row: row, col: col, length: length))
                searchStart = range.upperBound
            }
        }
        return (result, lines.count)
    }
}
