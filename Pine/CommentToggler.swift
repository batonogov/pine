//
//  CommentToggler.swift
//  Pine
//

import Foundation

/// Pure logic for toggling line comments. No AppKit dependencies — easy to unit test.
enum CommentToggler {
    struct Result {
        let newText: String
        let newRange: NSRange
    }

    /// Toggles line comments for lines touched by `selectedRange`.
    ///
    /// - If all non-empty affected lines are commented → uncomment.
    /// - Otherwise → comment all non-empty lines.
    /// - Empty lines are never modified.
    static func toggle(text: String, selectedRange: NSRange, lineComment: String) -> Result {
        let nsText = text as NSString
        let totalLength = nsText.length

        // Determine affected line range (expands to full lines)
        let affectedRange = nsText.lineRange(for: selectedRange)

        // Split into lines (preserving line endings)
        var lines: [(content: String, range: NSRange)] = []
        var pos = affectedRange.location
        let end = NSMaxRange(affectedRange)
        while pos < end {
            let lineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))
            let clipped = NSIntersectionRange(lineRange, NSRange(location: 0, length: totalLength))
            lines.append((nsText.substring(with: clipped), clipped))
            pos = NSMaxRange(lineRange)
            if pos == lineRange.location { break } // safety
        }

        // Determine if all non-empty lines are commented
        let nonEmptyLines = lines.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !nonEmptyLines.isEmpty else {
            return Result(newText: text, newRange: selectedRange)
        }

        let allCommented = nonEmptyLines.allSatisfy { line in
            let trimmed = line.content.drop(while: { $0 == " " || $0 == "\t" })
            return trimmed.hasPrefix(lineComment)
        }

        // Build new text
        var newText = text
        var offset = 0 // cumulative offset from insertions/deletions

        for line in lines {
            let lineContent = line.content
            let stripped = lineContent.replacingOccurrences(of: "\n", with: "")

            // Skip empty lines
            guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let leadingWhitespace = String(lineContent.prefix(while: { $0 == " " || $0 == "\t" }))
            let afterWhitespace = String(lineContent.dropFirst(leadingWhitespace.count))

            let adjustedLocation = line.range.location + offset
            let nsNew = newText as NSString

            if allCommented {
                // Uncomment: remove lineComment (+ optional space)
                if afterWhitespace.hasPrefix(lineComment + " ") {
                    let removeCount = (lineComment + " ").utf16.count
                    let removeStart = adjustedLocation + leadingWhitespace.utf16.count
                    let removeRange = NSRange(location: removeStart, length: removeCount)
                    newText = nsNew.replacingCharacters(in: removeRange, with: "")
                    offset -= removeCount
                } else if afterWhitespace.hasPrefix(lineComment) {
                    let removeCount = lineComment.utf16.count
                    let removeStart = adjustedLocation + leadingWhitespace.utf16.count
                    let removeRange = NSRange(location: removeStart, length: removeCount)
                    newText = nsNew.replacingCharacters(in: removeRange, with: "")
                    offset -= removeCount
                }
            } else {
                // Comment: insert lineComment + " " after leading whitespace
                let insertPos = adjustedLocation + leadingWhitespace.utf16.count
                let insertion = lineComment + " "
                newText = nsNew.replacingCharacters(
                    in: NSRange(location: insertPos, length: 0),
                    with: insertion
                )
                offset += insertion.utf16.count
            }
        }

        // Adjust selectedRange
        let newRange: NSRange
        if selectedRange.length == 0 {
            // Cursor: shift location by offset
            let newLocation = max(0, selectedRange.location + offset)
            newRange = NSRange(location: newLocation, length: 0)
        } else {
            // Selection: keep start, adjust length
            let newLength = max(0, selectedRange.length + offset)
            newRange = NSRange(location: selectedRange.location, length: newLength)
        }

        return Result(newText: newText, newRange: newRange)
    }
}
