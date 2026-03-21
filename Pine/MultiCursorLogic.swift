//
//  MultiCursorLogic.swift
//  Pine
//
//  Pure, side-effect-free logic for multiple cursor operations.
//  All functions are static to allow direct unit testing without a running NSTextView.
//

import AppKit

/// Pure logic for multiple cursor operations in the editor.
enum MultiCursorLogic {

    // MARK: - Next occurrence

    /// Finds the next occurrence of `text` in `fullText` starting at `searchStart`.
    /// Wraps around to the beginning of the document if not found after `searchStart`.
    /// Returns `nil` if `text` is empty or does not exist anywhere in `fullText`.
    static func findNextOccurrence(of text: String, in fullText: NSString, after searchStart: Int) -> NSRange? {
        guard !text.isEmpty else { return nil }
        let totalLength = fullText.length
        guard totalLength > 0 else { return nil }

        // Search from searchStart to end of document
        if searchStart < totalLength {
            let tailRange = NSRange(location: searchStart, length: totalLength - searchStart)
            let found = fullText.range(of: text, options: [], range: tailRange)
            if found.location != NSNotFound { return found }
        }

        // Wrap around: search from beginning up to just before searchStart + text length
        // (so we can match occurrences that start at 0 when searchStart > 0)
        if searchStart > 0 {
            let headLen = min(searchStart + (text as NSString).length - 1, totalLength)
            if headLen > 0 {
                let headRange = NSRange(location: 0, length: headLen)
                let wrapped = fullText.range(of: text, options: [], range: headRange)
                if wrapped.location != NSNotFound { return wrapped }
            }
        }

        return nil
    }

    // MARK: - Merge overlapping ranges

    /// Merges overlapping or adjacent `NSRange` values.
    /// Returns a new array sorted ascending by location, with no overlapping ranges.
    static func mergeOverlapping(_ ranges: [NSRange]) -> [NSRange] {
        guard ranges.count > 1 else { return ranges }
        let sorted = ranges.sorted { $0.location < $1.location }
        var result = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = result[result.count - 1]
            if range.location <= NSMaxRange(last) {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                result[result.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: - Split selection into line cursors

    /// Splits a selection spanning one or more lines into one zero-length cursor per line,
    /// placed at the end of each line's content (before the line-ending newline character).
    /// If the selection is empty, returns the original range unchanged.
    static func splitSelectionIntoLineRanges(selection: NSRange, in fullText: NSString) -> [NSRange] {
        guard selection.length > 0 else { return [selection] }
        var ranges: [NSRange] = []
        var location = selection.location
        let end = NSMaxRange(selection)

        while location < end {
            let lineRange = fullText.lineRange(for: NSRange(location: location, length: 0))
            // Place cursor at end of line content (before newline character)
            var cursorPos = NSMaxRange(lineRange)
            if cursorPos > lineRange.location &&
               cursorPos <= fullText.length &&
               fullText.character(at: cursorPos - 1) == 0x0A {
                cursorPos -= 1
            }
            cursorPos = min(cursorPos, end)
            ranges.append(NSRange(location: cursorPos, length: 0))
            let nextLocation = NSMaxRange(lineRange)
            guard nextLocation > location else { break } // safety guard against infinite loop
            location = nextLocation
        }

        return ranges.isEmpty ? [selection] : ranges
    }

    // MARK: - New cursor positions after bulk edit

    /// Computes final cursor positions after applying a batch of text substitutions.
    ///
    /// `edits` must be sorted **end-to-start** (largest location first). Each element
    /// is `(replacementRange, replacementLength, cursorOffset)` where:
    /// - `replacementRange` is the range being replaced in the *currently-being-modified* text
    /// - `replacementLength` is the byte-length of the text being inserted (0 for deletion)
    /// - `cursorOffset` is where the cursor lands inside the replacement (0 = start, replacementLength = end)
    ///
    /// Returns cursor positions sorted **ascending**.
    static func newCursorPositions(edits: [(range: NSRange, replacementLength: Int, cursorOffset: Int)]) -> [Int] {
        // Each edit is applied to a partially-modified text. Since edits are ordered end-to-start,
        // each new edit is at a smaller location than all previously processed edits.
        // All previously computed positions come AFTER the current insertion point,
        // so they must be shifted by `delta = replacementLength - range.length`.
        var positions: [Int] = []
        for edit in edits {
            let delta = edit.replacementLength - edit.range.length
            for i in 0..<positions.count {
                positions[i] += delta
            }
            // Insert at front so the smallest position ends up at index 0
            positions.insert(edit.range.location + edit.cursorOffset, at: 0)
        }
        // positions is already sorted ascending (built from end to start, inserted at front)
        return positions
    }
}
