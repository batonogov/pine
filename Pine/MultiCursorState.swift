//
//  MultiCursorState.swift
//  Pine
//
//  Tracks multiple insertion points / selections for multi-cursor editing.
//  NSTextView only supports a single selection natively, so this model
//  maintains extra cursors as an overlay and applies edits to all of them.
//

import AppKit

/// A single cursor: either an insertion point (length == 0) or a selection.
struct CursorSelection: Equatable, Comparable {
    var range: NSRange

    var location: Int { range.location }
    var length: Int { range.length }

    /// Sorts cursors by document position (earlier first).
    static func < (lhs: CursorSelection, rhs: CursorSelection) -> Bool {
        lhs.range.location < rhs.range.location
    }
}

/// Manages multiple cursor positions for a GutterTextView.
///
/// When `cursors` has a single element, the text view behaves normally.
/// With multiple elements, edits (insert, delete) are applied to all
/// cursor positions from last to first (reverse order) so earlier
/// positions remain valid while later ones are being modified.
struct MultiCursorState {
    /// All active cursors, always sorted by location ascending.
    /// Invariant: never empty — at least one cursor always exists.
    private(set) var cursors: [CursorSelection] = [CursorSelection(range: NSRange(location: 0, length: 0))]

    /// True when there are multiple active cursors.
    var isMultiCursor: Bool { cursors.count > 1 }

    /// The primary cursor (first one or the one matching NSTextView's selection).
    var primary: CursorSelection { cursors[0] }

    // MARK: - Mutation

    /// Replaces all cursors with a single one at the given range.
    mutating func setSingle(_ range: NSRange) {
        cursors = [CursorSelection(range: range)]
    }

    /// Adds a cursor at the given range if not already present.
    /// Returns true if cursor was added.
    @discardableResult
    mutating func addCursor(at range: NSRange) -> Bool {
        let newCursor = CursorSelection(range: range)
        // Don't add duplicate
        guard !cursors.contains(newCursor) else { return false }
        cursors.append(newCursor)
        cursors.sort()
        mergeOverlapping()
        return true
    }

    /// Removes all cursors except the first (primary).
    mutating func collapseToSingle() {
        guard cursors.count > 1 else { return }
        cursors = [cursors[0]]
    }

    /// Adjusts all cursor positions after an edit operation.
    /// `editLocation` is where the edit happened, `oldLength` is how many
    /// characters were replaced, `newLength` is how many characters were inserted.
    mutating func adjustAfterEdit(at editLocation: Int, oldLength: Int, newLength: Int) {
        let delta = newLength - oldLength
        for i in 0..<cursors.count {
            let loc = cursors[i].range.location
            if loc > editLocation {
                cursors[i].range.location = max(editLocation, loc + delta)
                // If cursor had a selection, adjust its length
                if cursors[i].range.length > 0 && loc + delta < editLocation {
                    cursors[i].range.length = max(0, cursors[i].range.length + delta)
                }
            } else if loc == editLocation && cursors[i].range.length > 0 {
                // Selection starting at edit point — adjust length
                cursors[i].range.length = max(0, cursors[i].range.length + delta)
            }
        }
        mergeOverlapping()
    }

    /// Merges any overlapping or adjacent cursors.
    mutating func mergeOverlapping() {
        guard cursors.count > 1 else { return }
        cursors.sort()
        var merged: [CursorSelection] = [cursors[0]]
        for i in 1..<cursors.count {
            let last = merged[merged.count - 1]
            let current = cursors[i]
            let lastEnd = NSMaxRange(last.range)
            if current.range.location <= lastEnd {
                // Overlapping or adjacent — merge
                let newEnd = max(lastEnd, NSMaxRange(current.range))
                merged[merged.count - 1].range = NSRange(
                    location: last.range.location,
                    length: newEnd - last.range.location
                )
            } else {
                merged.append(current)
            }
        }
        cursors = merged
    }

    // MARK: - Cmd+D: Select Next Occurrence

    /// Finds the next occurrence of `word` in `text` after `searchFrom` position.
    /// If not found, wraps around from the beginning.
    /// Returns the range of the match, or nil if `word` is not found.
    static func findNextOccurrence(
        of word: String,
        in text: NSString,
        searchFrom: Int,
        existingRanges: [NSRange]
    ) -> NSRange? {
        let wordLength = (word as NSString).length
        guard wordLength > 0 else { return nil }

        // Search forward from searchFrom
        let forwardRange = NSRange(location: searchFrom, length: text.length - searchFrom)
        var result = text.range(of: word, options: [], range: forwardRange)

        if result.location == NSNotFound {
            // Wrap around — search from beginning
            let wrapRange = NSRange(location: 0, length: searchFrom)
            result = text.range(of: word, options: [], range: wrapRange)
        }

        guard result.location != NSNotFound else { return nil }

        // Skip if already selected
        if existingRanges.contains(where: { $0.location == result.location && $0.length == result.length }) {
            // Try to find the next one after this match
            let nextStart = result.location + 1
            guard nextStart < text.length else { return nil }
            let retryRange = NSRange(location: nextStart, length: text.length - nextStart)
            let retry = text.range(of: word, options: [], range: retryRange)
            if retry.location != NSNotFound
                && !existingRanges.contains(where: { $0.location == retry.location && $0.length == retry.length }) {
                return retry
            }
            // Also try wrapping
            if nextStart > 0 {
                let wrapRetry = NSRange(location: 0, length: nextStart)
                let wrapResult = text.range(of: word, options: [], range: wrapRetry)
                if wrapResult.location != NSNotFound
                    && !existingRanges.contains(where: {
                        $0.location == wrapResult.location && $0.length == wrapResult.length
                    }) {
                    return wrapResult
                }
            }
            return nil
        }

        return result
    }

    /// Selects the word under the primary cursor's insertion point.
    /// Returns the selected word, or nil if cursor is in whitespace.
    static func wordAtCursor(in text: NSString, cursorLocation: Int) -> NSRange? {
        guard cursorLocation <= text.length else { return nil }
        guard text.length > 0 else { return nil }

        // Use NSString's word boundary detection
        let loc = min(cursorLocation, text.length - 1)
        guard loc >= 0 else { return nil }

        // Find word boundaries
        var wordStart = loc
        var wordEnd = loc

        let isWordChar: (Int) -> Bool = { pos in
            guard pos >= 0, pos < text.length else { return false }
            let char = text.character(at: pos)
            // Letters, digits, underscore
            guard let scalar = Unicode.Scalar(char) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
                || char == 0x5F // underscore
        }

        guard isWordChar(loc) else { return nil }

        while wordStart > 0 && isWordChar(wordStart - 1) {
            wordStart -= 1
        }
        while wordEnd < text.length - 1 && isWordChar(wordEnd + 1) {
            wordEnd += 1
        }

        let range = NSRange(location: wordStart, length: wordEnd - wordStart + 1)
        guard range.length > 0 else { return nil }
        return range
    }
}
