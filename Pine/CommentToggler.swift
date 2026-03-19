//
//  CommentToggler.swift
//  Pine
//

import Foundation

/// Pure logic for toggling line/block comments. No AppKit dependencies — easy to unit test.
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
            let content = line.content.trimmingCharacters(in: .newlines)
            return content.hasPrefix(lineComment)
        }

        // Build new text
        var newText = text
        var offset = 0 // cumulative offset from insertions/deletions

        for line in lines {
            let lineContent = line.content
            let stripped = lineContent.replacingOccurrences(of: "\n", with: "")

            // Skip empty lines
            guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let contentWithoutNewline = lineContent.trimmingCharacters(in: .newlines)

            let adjustedLocation = line.range.location + offset
            let nsNew = newText as NSString

            if allCommented {
                // Uncomment: remove lineComment (+ optional space) from start of line (column 0)
                if contentWithoutNewline.hasPrefix(lineComment + " ") {
                    let removeCount = (lineComment + " ").utf16.count
                    let removeRange = NSRange(location: adjustedLocation, length: removeCount)
                    newText = nsNew.replacingCharacters(in: removeRange, with: "")
                    offset -= removeCount
                } else if contentWithoutNewline.hasPrefix(lineComment) {
                    let removeCount = lineComment.utf16.count
                    let removeRange = NSRange(location: adjustedLocation, length: removeCount)
                    newText = nsNew.replacingCharacters(in: removeRange, with: "")
                    offset -= removeCount
                }
            } else {
                // Comment: insert lineComment + " " at column 0 (before indentation)
                let insertPos = adjustedLocation
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

    /// Toggles block comments for the selected text or current line.
    ///
    /// - If the affected text is wrapped in `open`…`close` → unwrap.
    /// - Otherwise → wrap with `open` + space … space + `close`.
    /// - When there is no selection (cursor), operates on the current line.
    /// - When there is a selection, operates on exactly the selected range (supports partial-line selection).
    static func toggleBlock(text: String, selectedRange: NSRange, open: String, close: String) -> Result {
        let nsText = text as NSString

        // Determine the range to operate on
        let operatingRange: NSRange
        let expandedToLines: Bool

        if selectedRange.length == 0 {
            // No selection — operate on the current line
            operatingRange = nsText.lineRange(for: selectedRange)
            expandedToLines = true
        } else {
            operatingRange = selectedRange
            expandedToLines = false
        }

        let content = nsText.substring(with: operatingRange)

        // For line-expanded ranges, strip trailing newline for processing
        let trailingNewline: String
        if expandedToLines, content.hasSuffix("\n") {
            trailingNewline = "\n"
        } else {
            trailingNewline = ""
        }

        let processContent = trailingNewline.isEmpty ? content : String(content.dropLast())

        // Check if all content is empty/whitespace
        if processContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(newText: text, newRange: selectedRange)
        }

        // Detect leading whitespace (for indented lines)
        let leadingWhitespace = String(processContent.prefix(while: { $0 == " " || $0 == "\t" }))
        let afterWhitespace = String(processContent.dropFirst(leadingWhitespace.count))

        // Check if already block-commented
        let isCommented: Bool
        let openWithSpace = open + " "
        let closeWithSpace = " " + close

        if afterWhitespace.hasPrefix(openWithSpace) && afterWhitespace.hasSuffix(closeWithSpace) {
            isCommented = true
        } else if afterWhitespace.hasPrefix(open) && afterWhitespace.hasSuffix(close) {
            isCommented = true
        } else {
            isCommented = false
        }

        let newContent: String
        if isCommented {
            // Uncomment: remove open/close delimiters
            var inner = afterWhitespace
            if inner.hasPrefix(openWithSpace) {
                inner = String(inner.dropFirst(openWithSpace.count))
            } else {
                inner = String(inner.dropFirst(open.count))
            }
            if inner.hasSuffix(closeWithSpace) {
                inner = String(inner.dropLast(closeWithSpace.count))
            } else {
                inner = String(inner.dropLast(close.count))
            }
            newContent = leadingWhitespace + inner + trailingNewline
        } else {
            // Comment: wrap with open/close delimiters
            newContent = leadingWhitespace + open + " " + afterWhitespace + " " + close + trailingNewline
        }

        // Replace the operating range
        let newText = nsText.replacingCharacters(in: operatingRange, with: newContent)
        let lengthDelta = newContent.utf16.count - operatingRange.length

        // Adjust the selected range
        let newRange: NSRange
        if selectedRange.length == 0 {
            // Cursor: shift by the prefix delta (open+space added or removed before cursor)
            if isCommented {
                let removedPrefix = afterWhitespace.hasPrefix(openWithSpace)
                    ? openWithSpace.utf16.count
                    : open.utf16.count
                let newLocation = max(0, selectedRange.location - removedPrefix)
                newRange = NSRange(location: newLocation, length: 0)
            } else {
                let addedPrefix = (open + " ").utf16.count
                newRange = NSRange(location: selectedRange.location + addedPrefix, length: 0)
            }
        } else {
            let newLength = max(0, selectedRange.length + lengthDelta)
            newRange = NSRange(location: selectedRange.location, length: newLength)
        }

        return Result(newText: newText, newRange: newRange)
    }
}
