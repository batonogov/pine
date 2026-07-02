//
//  CompletionEndpoint.swift
//  Pine
//
//  Phase 3 of LSP support (issue #1012, parent #994).
//
//  Bridges the AppKit `CodeEditorView.Coordinator` (which drives completion
//  scheduling, popup positioning, and keyboard navigation) to the
//  `@MainActor @Observable` `LSPManager` (which owns the language-server
//  connections and issues `textDocument/completion`).
//
//  The coordinator cannot reach `ProjectManager.lspManager` directly — it lives
//  several SwiftUI layers above the `NSViewRepresentable` — so
//  `PaneLeafView` installs a `CompletionEndpoint` closure on the
//  `CodeEditorView` and the coordinator routes requests through it.
//
//  This file also hosts the pure helpers the coordinator needs:
//    • `CompletionTrigger` — decides whether/when to fire a request based on
//      the edited character and the trigger-character set.
//    • `CompletionInsertion` — expands an `LSPSnippet` (or plain text) into
//      the final inserted text + the offset where the cursor should land.
//

import Foundation

// MARK: - Endpoint

/// `@MainActor` singleton bridge from the editor coordinator to the active
/// project's `LSPManager`.
///
/// `PaneLeafView` sets `CompletionEndpoint.shared.handler` when the active
/// editor pane appears (and clears it on disappear) so the coordinator can
/// issue completion requests without holding a reference to the project.
///
/// A single shared endpoint is sufficient because Pine is a document-based app
/// where only one editor pane is first-responder at a time; the pane sets the
/// handler as it gains focus.
@MainActor
final class CompletionEndpoint {

    /// The shared endpoint. There is exactly one per process.
    static let shared = CompletionEndpoint()

    /// Called by the coordinator with the file URL, UTF-16 offset, and full
    /// document text. Returns the server's completion list (empty on failure).
    ///
    /// Installed by `PaneLeafView` via `projectManager.lspManager.completion`.
    var handler: ((URL, Int, String) async -> LSPCompletionList)?

    /// Convenience wrapper that no-ops (returns an empty list) when no handler
    /// is installed.
    func completion(url: URL, offset: Int, text: String) async -> LSPCompletionList {
        guard let handler else { return LSPCompletionList(items: []) }
        return await handler(url, offset, text)
    }

    private init() {}
}

// MARK: - Trigger evaluation

/// Pure logic that decides whether a freshly-typed character should trigger a
/// completion request, and whether the request should fire immediately (trigger
/// character) or be debounced (identifier character).
///
/// `nonisolated` + `Sendable` because the evaluation is pure data work invoked
/// from the main-actor typing path; it holds no state.
nonisolated enum CompletionTrigger {

    /// The default trigger characters used when the server does not advertise
    /// its own (`CompletionOptions.triggerCharacters`). These are the common
    /// member-access sigils across the languages Pine supports.
    static let defaultTriggerCharacters: Set<String> = [".", "->", "::", ":"]
    static let defaultTriggerCharsScalar: Set<Character> = [".", "-", ">", ":"]

    /// Result of evaluating whether the last edit should trigger completion.
    struct Decision: Sendable {
        /// `true` when a completion request should be scheduled.
        let shouldTrigger: Bool
        /// `true` when the request should fire immediately (no debounce).
        let fireImmediately: Bool
        /// The word prefix to filter against.
        let prefix: String
    }

    /// Inspects the edited range and returns a trigger decision.
    ///
    /// - Parameters:
    ///   - editedRange: The `NSTextStorage` edited range (may be nil).
    ///   - cursor: The current caret location (UTF-16 offset).
    ///   - source: The full document as an `NSString`.
    static func evaluate(
        editedRange: NSRange?,
        cursor: Int,
        source: NSString
    ) -> Decision {
        // Determine the character(s) just inserted.
        let inserted: String
        if let range = editedRange, range.length == 0, range.location < source.length {
            // An insertion: range.length == 0, the new char is at range.location.
            let scalar = Unicode.Scalar(source.character(at: range.location))
            inserted = scalar.map { String($0) } ?? ""
        } else if let range = editedRange, range.length > 0,
                  NSMaxRange(range) <= source.length {
            inserted = source.substring(with: range)
        } else {
            inserted = ""
        }

        let lastChar = inserted.last

        // Trigger character → immediate.
        if let char = lastChar, defaultTriggerCharsScalar.contains(char) {
            let prefix = wordPrefix(at: cursor, in: source)
            return Decision(shouldTrigger: true, fireImmediately: true, prefix: prefix)
        }

        // Identifier character → debounced.
        if let char = lastChar, isIdentifierChar(char) {
            let prefix = wordPrefix(at: cursor, in: source)
            // Don't trigger when the prefix is empty (e.g. the identifier char
            // started a new token but nothing is typed yet after a space —
            // servers usually return noise). Allow a single char so the popup
            // opens promptly.
            return Decision(shouldTrigger: !prefix.isEmpty, fireImmediately: false, prefix: prefix)
        }

        // Non-trigger, non-identifier (space, newline, punctuation) → cancel.
        return Decision(shouldTrigger: false, fireImmediately: false, prefix: "")
    }

    /// Extracts the word prefix ending at `offset` (the token being typed).
    /// Scans backwards over identifier characters (letters, digits, underscore).
    static func wordPrefix(at offset: Int, in source: NSString) -> String {
        let clamped = min(max(0, offset), source.length)
        var start = clamped
        while start > 0 {
            let unit = source.character(at: start - 1)
            guard let scalar = Unicode.Scalar(unit) else { break }
            let char = Character(scalar)
            if isIdentifierChar(char) {
                start -= 1
            } else {
                break
            }
        }
        if start >= clamped { return "" }
        return source.substring(with: NSRange(location: start, length: clamped - start))
    }

    /// `true` for letters, digits, and underscore — the characters that form a
    /// completion prefix.
    static func isIdentifierChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_"
    }
}

// MARK: - Insertion

/// The result of preparing a completion item for insertion: the plain text to
/// put into the buffer and the offset (relative to the insertion start) where
/// the cursor should land.
///
/// `nonisolated` + `Sendable` because this is pure data produced by the
/// snippet expander and consumed on the main actor.
nonisolated struct CompletionInsertion: Sendable, Equatable {

    /// The text to insert (snippet placeholders already expanded).
    let text: String

    /// The offset (in UTF-16 code units, relative to the insertion start)
    /// where the cursor should land after insertion. For plain text this is
    /// `text.utf16.count`; for snippets it is the first tab stop (or the final
    /// `$0` position).
    let finalCursorOffset: Int

    /// Builds a `CompletionInsertion` from an expanded snippet, placing the
    /// cursor at the first tab stop (or the end when there are none).
    static func fromSnippet(_ snippet: LSPSnippet) -> CompletionInsertion {
        let total = snippet.text.utf16.count
        guard let firstStop = snippet.tabStops.first else {
            return CompletionInsertion(text: snippet.text, finalCursorOffset: total)
        }
        // Land at the start of the first tab stop's range.
        let offset = min(firstStop.range.lowerBound, total)
        return CompletionInsertion(text: snippet.text, finalCursorOffset: offset)
    }

    /// Computes the `NSRange` of the identifier word ending at `cursor`, for
    /// replacing the partially-typed token with the accepted completion.
    static func wordRange(endingAt cursor: Int, in source: NSString) -> NSRange {
        let clamped = min(max(0, cursor), source.length)
        var start = clamped
        while start > 0 {
            let unit = source.character(at: start - 1)
            guard let scalar = Unicode.Scalar(unit) else { break }
            let char = Character(scalar)
            if CompletionTrigger.isIdentifierChar(char) {
                start -= 1
            } else {
                break
            }
        }
        let length = max(0, clamped - start)
        return NSRange(location: start, length: length)
    }
}
