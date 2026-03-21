//
//  MultiCursorLogic.swift
//  Pine
//

import Foundation

/// Pure logic for multi-cursor editing operations. No AppKit dependencies.
///
/// Uses UTF-16 offsets (NSRange/NSString) consistent with NSTextView.
enum MultiCursorLogic {

    /// A cursor position with optional selection range.
    struct Cursor: Equatable {
        /// UTF-16 offset — the insertion point (caret position).
        var location: Int
        /// Selected range (nil or zero-length means no selection).
        var selection: NSRange?

        init(location: Int, selection: NSRange? = nil) {
            self.location = location
            self.selection = selection
        }

        var hasSelection: Bool {
            guard let sel = selection else { return false }
            return sel.length > 0
        }

        /// The range affected by this cursor — either the selection or a zero-length range at the location.
        var range: NSRange {
            if let sel = selection, sel.length > 0 {
                return sel
            }
            return NSRange(location: location, length: 0)
        }
    }

    /// A single text replacement in **original** (pre-edit) coordinates.
    struct Replacement {
        /// Range to replace in the original text (location in original UTF-16 offsets).
        let range: NSRange
        /// String to insert.
        let string: String
    }

    /// Result of a multi-cursor text operation.
    struct Result {
        let newText: String
        let newCursors: [Cursor]
        /// Replacements in **original** coordinates, sorted by location ascending.
        /// Apply in reverse order to preserve offsets.
        let replacements: [Replacement]
    }

    // MARK: - Insert

    /// Inserts `string` at every cursor position (replacing selections if any).
    /// Returns new text, adjusted cursors, and per-cursor replacements in original coordinates.
    static func insert(in text: String, cursors: [Cursor], string: String) -> Result {
        let sorted = cursors.sorted { $0.range.location < $1.range.location }
        let insertLength = (string as NSString).length
        var newText = text
        var newCursors: [Cursor] = []
        var replacements: [Replacement] = []
        var cumulativeOffset = 0

        for cursor in sorted {
            let range = cursor.range
            // Record replacement in original coordinates
            replacements.append(Replacement(range: range, string: string))

            let adjustedLocation = range.location + cumulativeOffset
            let adjustedRange = NSRange(location: adjustedLocation, length: range.length)

            let nsNew = newText as NSString
            newText = nsNew.replacingCharacters(in: adjustedRange, with: string)

            let newLocation = adjustedLocation + insertLength
            newCursors.append(Cursor(location: newLocation))

            cumulativeOffset += insertLength - range.length
        }

        return Result(newText: newText, newCursors: mergeCursors(newCursors), replacements: replacements)
    }

    // MARK: - Delete backward

    /// Deletes one character before each cursor (or removes selection).
    static func deleteBackward(in text: String, cursors: [Cursor]) -> Result {
        let sorted = cursors.sorted { $0.range.location < $1.range.location }
        var newText = text
        var newCursors: [Cursor] = []
        var replacements: [Replacement] = []
        var cumulativeOffset = 0

        for cursor in sorted {
            if cursor.hasSelection {
                let range = cursor.range
                replacements.append(Replacement(range: range, string: ""))

                let adjustedRange = NSRange(
                    location: range.location + cumulativeOffset,
                    length: range.length
                )
                let nsNew = newText as NSString
                newText = nsNew.replacingCharacters(in: adjustedRange, with: "")
                newCursors.append(Cursor(location: range.location + cumulativeOffset))
                cumulativeOffset -= range.length
            } else {
                let loc = cursor.location + cumulativeOffset
                guard loc > 0 else {
                    newCursors.append(Cursor(location: 0))
                    continue
                }
                let nsNew = newText as NSString
                let deleteRange = nsNew.rangeOfComposedCharacterSequence(at: loc - 1)
                // Convert back to original coordinates for the replacement
                let origRange = NSRange(
                    location: deleteRange.location - cumulativeOffset,
                    length: deleteRange.length
                )
                replacements.append(Replacement(range: origRange, string: ""))

                newText = nsNew.replacingCharacters(in: deleteRange, with: "")
                newCursors.append(Cursor(location: deleteRange.location))
                cumulativeOffset -= deleteRange.length
            }
        }

        return Result(newText: newText, newCursors: mergeCursors(newCursors), replacements: replacements)
    }

    // MARK: - Delete forward

    /// Deletes one character after each cursor (or removes selection).
    static func deleteForward(in text: String, cursors: [Cursor]) -> Result {
        let sorted = cursors.sorted { $0.range.location < $1.range.location }
        var newText = text
        var newCursors: [Cursor] = []
        var replacements: [Replacement] = []
        var cumulativeOffset = 0

        for cursor in sorted {
            if cursor.hasSelection {
                let range = cursor.range
                replacements.append(Replacement(range: range, string: ""))

                let adjustedRange = NSRange(
                    location: range.location + cumulativeOffset,
                    length: range.length
                )
                let nsNew = newText as NSString
                newText = nsNew.replacingCharacters(in: adjustedRange, with: "")
                newCursors.append(Cursor(location: range.location + cumulativeOffset))
                cumulativeOffset -= range.length
            } else {
                let loc = cursor.location + cumulativeOffset
                let nsNew = newText as NSString
                guard loc < nsNew.length else {
                    newCursors.append(Cursor(location: loc))
                    continue
                }
                let deleteRange = nsNew.rangeOfComposedCharacterSequence(at: loc)
                let origRange = NSRange(
                    location: deleteRange.location - cumulativeOffset,
                    length: deleteRange.length
                )
                replacements.append(Replacement(range: origRange, string: ""))

                newText = nsNew.replacingCharacters(in: deleteRange, with: "")
                newCursors.append(Cursor(location: loc))
                cumulativeOffset -= deleteRange.length
            }
        }

        return Result(newText: newText, newCursors: mergeCursors(newCursors), replacements: replacements)
    }

    // MARK: - Select next occurrence (Cmd+D)

    /// If no cursor has a selection, selects the word under the first cursor.
    /// If cursors have selections, finds the next occurrence of the selected text
    /// after the last cursor and adds a new cursor+selection for it.
    /// Search is case-sensitive and wraps around.
    static func selectNextOccurrence(in text: String, cursors: [Cursor]) -> [Cursor] {
        let source = text as NSString
        guard source.length > 0 else { return cursors }

        // If no selection, select the word under the first cursor
        let firstWithSelection = cursors.first(where: { $0.hasSelection })
        guard let selected = firstWithSelection else {
            guard let first = cursors.first,
                  let wordRange = wordRange(in: text, at: first.location) else {
                return cursors
            }
            return [Cursor(location: NSMaxRange(wordRange), selection: wordRange)]
        }

        guard let selectedSelection = selected.selection else { return cursors }
        let searchText = source.substring(with: selectedSelection)
        let searchLength = (searchText as NSString).length

        // Find all existing selection locations to avoid duplicates
        let existingLocations = Set(cursors.compactMap { $0.selection?.location })

        // Search forward from after the last cursor's selection
        let sorted = cursors.sorted { ($0.selection?.location ?? $0.location) < ($1.selection?.location ?? $1.location) }
        guard let lastCursor = sorted.last else { return cursors }
        let lastSelection = lastCursor.selection ?? NSRange(location: lastCursor.location, length: 0)
        let searchStart = NSMaxRange(lastSelection)

        // Search forward from searchStart
        var searchRange = NSRange(location: searchStart, length: source.length - searchStart)
        var found: NSRange?

        if searchRange.length >= searchLength {
            let range = source.range(of: searchText, range: searchRange)
            if range.location != NSNotFound && !existingLocations.contains(range.location) {
                found = range
            }
        }

        // Wrap around: search from beginning to the first cursor
        if found == nil {
            guard let firstCursor = sorted.first else { return cursors }
            let firstLocation = firstCursor.selection?.location ?? firstCursor.location
            searchRange = NSRange(location: 0, length: firstLocation)
            if searchRange.length >= searchLength {
                let range = source.range(of: searchText, range: searchRange)
                if range.location != NSNotFound && !existingLocations.contains(range.location) {
                    found = range
                }
            }
        }

        guard let newRange = found else { return cursors }

        var newCursors = cursors
        let newCursor = Cursor(location: NSMaxRange(newRange), selection: newRange)
        newCursors.append(newCursor)
        newCursors.sort { ($0.selection?.location ?? $0.location) < ($1.selection?.location ?? $1.location) }

        return mergeCursors(newCursors)
    }

    // MARK: - Split selection into lines (Cmd+Shift+L)

    /// Splits each selected range into one cursor per line.
    /// Cursors without selection are kept as-is.
    static func splitSelectionIntoLines(in text: String, cursors: [Cursor]) -> [Cursor] {
        let source = text as NSString
        var result: [Cursor] = []

        for cursor in cursors {
            guard cursor.hasSelection, let sel = cursor.selection else {
                result.append(cursor)
                continue
            }

            // Count lines in selection
            var lineStarts: [Int] = []
            var pos = sel.location
            let end = NSMaxRange(sel)

            while pos < end {
                lineStarts.append(pos)
                let lineRange = source.lineRange(for: NSRange(location: pos, length: 0))
                let nextLine = NSMaxRange(lineRange)
                if nextLine <= pos { break }
                pos = nextLine
            }

            // Single line → keep original cursor
            if lineStarts.count <= 1 {
                result.append(cursor)
                continue
            }

            // Create cursor at end of each line (clamped to selection end)
            for lineStart in lineStarts {
                let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
                var lineEnd = NSMaxRange(lineRange)

                // Strip trailing newline
                if lineEnd > lineStart && lineEnd <= source.length
                    && source.character(at: lineEnd - 1) == 0x0A {
                    lineEnd -= 1
                }

                // Clamp to selection bounds
                lineEnd = min(lineEnd, end)

                result.append(Cursor(location: lineEnd))
            }
        }

        return mergeCursors(result)
    }

    // MARK: - Add cursor (Option+Click)

    /// Adds a cursor at `position`. If a cursor already exists at that position, removes it
    /// (toggle behavior). Returns sorted cursors.
    static func addCursor(to cursors: [Cursor], at position: Int) -> [Cursor] {
        // Check if cursor already exists at this position
        if let existingIndex = cursors.firstIndex(where: { $0.location == position && !$0.hasSelection }) {
            // Toggle off — but keep at least one cursor
            if cursors.count > 1 {
                var result = cursors
                result.remove(at: existingIndex)
                return result
            }
            return cursors
        }

        var result = cursors.map { Cursor(location: $0.location) } // Drop selections on Option+Click
        result.append(Cursor(location: position))
        result.sort { $0.location < $1.location }
        return mergeCursors(result)
    }

    // MARK: - Merge overlapping cursors

    /// Merges cursors with overlapping or identical positions/selections.
    static func mergeCursors(_ cursors: [Cursor]) -> [Cursor] {
        guard cursors.count > 1 else { return cursors }

        let sorted = cursors.sorted { $0.range.location < $1.range.location }
        var merged: [Cursor] = [sorted[0]]

        for cursor in sorted.dropFirst() {
            let last = merged[merged.count - 1]

            // Check overlap
            let lastEnd = NSMaxRange(last.range)
            let curStart = cursor.range.location

            if curStart <= lastEnd {
                // Merge: extend the selection to cover both
                let mergedStart = min(last.range.location, cursor.range.location)
                let mergedEnd = max(lastEnd, NSMaxRange(cursor.range))
                let mergedLength = mergedEnd - mergedStart

                if mergedLength > 0 {
                    merged[merged.count - 1] = Cursor(
                        location: mergedEnd,
                        selection: NSRange(location: mergedStart, length: mergedLength)
                    )
                } else {
                    merged[merged.count - 1] = Cursor(location: mergedStart)
                }
            } else {
                merged.append(cursor)
            }
        }

        return merged
    }

    // MARK: - Word boundary detection

    /// Returns the range of the word at the given UTF-16 position, or nil if not on a word character.
    /// Handles surrogate pairs by skipping high/low surrogates that are part of emoji or CJK characters.
    static func wordRange(in text: String, at position: Int) -> NSRange? {
        let source = text as NSString
        guard source.length > 0, position <= source.length else { return nil }

        // Find the character at or before the position
        let checkPos: Int
        if position >= source.length {
            checkPos = source.length - 1
        } else {
            checkPos = position
        }

        // Skip surrogate pairs — they are not word characters
        let char = source.character(at: checkPos)
        if CFStringIsSurrogateHighCharacter(char) || CFStringIsSurrogateLowCharacter(char) {
            return nil
        }

        guard isWordCharacter(char) else { return nil }

        // Scan backward to find word start
        var start = checkPos
        while start > 0 {
            let prev = source.character(at: start - 1)
            if CFStringIsSurrogateHighCharacter(prev) || CFStringIsSurrogateLowCharacter(prev) { break }
            if !isWordCharacter(prev) { break }
            start -= 1
        }

        // Scan forward to find word end
        var end = checkPos
        while end < source.length - 1 {
            let next = source.character(at: end + 1)
            if CFStringIsSurrogateHighCharacter(next) || CFStringIsSurrogateLowCharacter(next) { break }
            if !isWordCharacter(next) { break }
            end += 1
        }

        return NSRange(location: start, length: end - start + 1)
    }

    private static func isWordCharacter(_ char: unichar) -> Bool {
        // Skip surrogate pairs entirely — they represent multi-codeunit characters (emoji, etc.)
        if CFStringIsSurrogateHighCharacter(char) || CFStringIsSurrogateLowCharacter(char) {
            return false
        }
        let scalar = Unicode.Scalar(char)
        guard let scalar else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || char == 0x5F // underscore
    }
}
