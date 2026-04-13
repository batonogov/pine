//
//  SmartListContinuation.swift
//  Pine
//

import Foundation

/// Pure, side-effect-free logic for "smart list continuation" — the editor behaviour
/// where pressing Return inside a Markdown list automatically starts the next bullet
/// (or terminates the list when the current item is empty).
///
/// Why a standalone type? The integration point lives inside `GutterTextView`'s
/// `insertNewline(_:)` override, which is being refactored in #797. Keeping the core
/// logic in a pure function gives us:
///
/// 1. Full unit-test coverage without an NSTextView harness.
/// 2. An easy drop-in for the wiring PR that follows #797.
/// 3. No risk of regressing editor behaviour while #797 is still in flight — this file
///    is referenced by nothing until wiring lands.
///
/// ## Supported list styles
/// - Unordered bullets: `-`, `*`, `+`
/// - Ordered bullets:   `1.`, `42)` (any positive integer followed by `.` or `)`)
/// - GitHub task lists: `- [ ]`, `- [x]`, `* [X]` — the checkbox is reset to `[ ]` on
///   continuation so the new task starts unchecked.
/// - Blockquote prefix: `>` preceding any of the above (common in Markdown)
///
/// ## Termination rule
/// Pressing Return on an "empty" list item (only the bullet, optional checkbox, and
/// whitespace) exits the list: the current line is cleared and a plain newline is
/// inserted. This matches VS Code, iA Writer, and Obsidian.
enum SmartListContinuation {

    /// Result of processing a Return keypress on a line that begins with a list marker.
    enum Outcome: Equatable {
        /// Replace the current line with `replacement` (usually an empty string, to erase
        /// the stray bullet) and then insert a plain newline. Emitted when the user hits
        /// Return on an otherwise-empty list item — signals "exit the list".
        case terminate(replacement: String)

        /// Insert `"\n" + continuation` at the cursor. `continuation` is the indent +
        /// next bullet (ordered lists auto-increment their counter).
        case `continue`(continuation: String)
    }

    /// Attempts to compute a smart-list outcome for a Return keypress.
    ///
    /// - Parameter currentLine: The full text of the line the cursor currently sits on,
    ///   **excluding** the newline character. Trailing whitespace may be present.
    /// - Returns: An `Outcome` describing what the editor should do, or `nil` when the
    ///   line is not a recognised list item (the editor should fall back to its default
    ///   newline behaviour, e.g. auto-indent).
    static func handleReturn(currentLine: String) -> Outcome? {
        guard let item = parse(line: currentLine) else { return nil }

        // Empty-body rule: when the only content after the bullet (and optional
        // checkbox) is whitespace, exit the list by clearing the line.
        if item.body.trimmingCharacters(in: .whitespaces).isEmpty {
            return .terminate(replacement: "")
        }

        // Otherwise continue the list with the incremented counter (if any).
        return .continue(continuation: item.nextPrefix())
    }

    // MARK: - Parsing

    /// Internal representation of a parsed list item. Made visible to tests via
    /// `@testable import`.
    struct ParsedItem: Equatable {
        /// Leading indentation (spaces and tabs) before any list marker.
        let indent: String
        /// Optional `> ` blockquote prefix (including its trailing space, if any).
        let blockquote: String
        /// The bullet marker itself.
        let marker: Marker
        /// Optional GitHub task-list checkbox, including its trailing space.
        /// e.g. `"[ ] "` or `"[x] "`. Empty string when absent.
        let checkbox: String
        /// Everything after the marker (and optional checkbox) on the current line.
        let body: String

        /// The prefix to insert on the next line to continue this list item.
        /// Ordered markers auto-increment; unordered markers are copied verbatim.
        /// Task-list checkboxes are reset to the unchecked state.
        func nextPrefix() -> String {
            let bulletText: String
            switch marker {
            case .unordered(let char):
                bulletText = "\(char) "
            case .ordered(let number, let delimiter):
                bulletText = "\(number + 1)\(delimiter) "
            }
            let checkboxText = checkbox.isEmpty ? "" : "[ ] "
            return indent + blockquote + bulletText + checkboxText
        }
    }

    enum Marker: Equatable {
        case unordered(Character)          // '-', '*', '+'
        case ordered(Int, Character)       // number + '.' or ')'
    }

    /// Parses a line into a `ParsedItem`, or returns `nil` when the line is not a
    /// recognised list item. This is deliberately permissive: it accepts any of the
    /// CommonMark bullet characters and any positive integer counter.
    static func parse(line: String) -> ParsedItem? {
        var scanner = line.startIndex

        // 1. Leading indentation (spaces / tabs).
        let indentStart = scanner
        while scanner < line.endIndex, line[scanner] == " " || line[scanner] == "\t" {
            scanner = line.index(after: scanner)
        }
        let indent = String(line[indentStart..<scanner])

        // 2. Optional blockquote prefix: one or more ">" each optionally followed by a
        //    single space. CommonMark allows `>` or `> ` but not leading spaces inside
        //    the prefix, so we match conservatively.
        let blockquoteStart = scanner
        while scanner < line.endIndex, line[scanner] == ">" {
            scanner = line.index(after: scanner)
            if scanner < line.endIndex, line[scanner] == " " {
                scanner = line.index(after: scanner)
            }
        }
        let blockquote = String(line[blockquoteStart..<scanner])

        // 3. Bullet marker (unordered or ordered). Must be followed by at least one space.
        guard scanner < line.endIndex else { return nil }
        let marker: Marker
        let afterMarkerIndex: String.Index

        let firstChar = line[scanner]
        if firstChar == "-" || firstChar == "*" || firstChar == "+" {
            let next = line.index(after: scanner)
            guard next < line.endIndex, line[next] == " " else { return nil }
            marker = .unordered(firstChar)
            afterMarkerIndex = line.index(after: next)
        } else if firstChar.isASCII, firstChar.isNumber {
            var digitEnd = scanner
            while digitEnd < line.endIndex, line[digitEnd].isNumber {
                digitEnd = line.index(after: digitEnd)
            }
            guard digitEnd < line.endIndex else { return nil }
            let delim = line[digitEnd]
            guard delim == "." || delim == ")" else { return nil }
            let afterDelim = line.index(after: digitEnd)
            guard afterDelim < line.endIndex, line[afterDelim] == " " else { return nil }
            guard let number = Int(line[scanner..<digitEnd]) else { return nil }
            marker = .ordered(number, delim)
            afterMarkerIndex = line.index(after: afterDelim)
        } else {
            return nil
        }

        // 4. Optional task-list checkbox: `[ ]`, `[x]`, `[X]` followed by a space.
        var checkbox = ""
        var bodyStart = afterMarkerIndex
        if afterMarkerIndex < line.endIndex, line[afterMarkerIndex] == "[" {
            let b1 = line.index(after: afterMarkerIndex)
            if b1 < line.endIndex {
                let state = line[b1]
                if state == " " || state == "x" || state == "X" {
                    let b2 = line.index(after: b1)
                    if b2 < line.endIndex, line[b2] == "]" {
                        let b3 = line.index(after: b2)
                        if b3 < line.endIndex, line[b3] == " " {
                            // Include the trailing space so nextPrefix() can copy verbatim.
                            checkbox = String(line[afterMarkerIndex...b3])
                            bodyStart = line.index(after: b3)
                        }
                    }
                }
            }
        }

        let body = String(line[bodyStart..<line.endIndex])
        return ParsedItem(
            indent: indent,
            blockquote: blockquote,
            marker: marker,
            checkbox: checkbox,
            body: body
        )
    }
}
