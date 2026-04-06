//
//  InlineDiffNavigator.swift
//  Pine
//
//  Pure navigation logic for jumping between diff hunks in the inline diff
//  toolbar (#689). Navigation is bounded by the file — no wrap-around.
//

import Foundation

enum InlineDiffNavigator {

    /// Returns the hunk that follows the one identified by `currentID`.
    /// If `currentID` is nil or unknown, returns the first hunk.
    /// Returns `nil` when there is nothing after the current hunk (no wrap).
    static func nextHunk(after currentID: UUID?, in hunks: [DiffHunk]) -> DiffHunk? {
        guard !hunks.isEmpty else { return nil }
        guard let currentID,
              let idx = hunks.firstIndex(where: { $0.id == currentID }) else {
            return hunks.first
        }
        let nextIdx = idx + 1
        return nextIdx < hunks.count ? hunks[nextIdx] : nil
    }

    /// Returns the hunk that precedes the one identified by `currentID`.
    /// If `currentID` is nil or unknown, returns the last hunk.
    /// Returns `nil` when there is nothing before the current hunk (no wrap).
    static func previousHunk(before currentID: UUID?, in hunks: [DiffHunk]) -> DiffHunk? {
        guard !hunks.isEmpty else { return nil }
        guard let currentID,
              let idx = hunks.firstIndex(where: { $0.id == currentID }) else {
            return hunks.last
        }
        let prevIdx = idx - 1
        return prevIdx >= 0 ? hunks[prevIdx] : nil
    }

    /// Whether the next button should be enabled.
    static func canGoNext(from currentID: UUID?, in hunks: [DiffHunk]) -> Bool {
        nextHunk(after: currentID, in: hunks) != nil
    }

    /// Whether the previous button should be enabled.
    static func canGoPrevious(from currentID: UUID?, in hunks: [DiffHunk]) -> Bool {
        previousHunk(before: currentID, in: hunks) != nil
    }
}
