//
//  PerTabEditorState.swift
//  Pine
//
//  Serializable per-tab editor state for session persistence.
//

import Foundation

/// Codable representation of per-tab editor state (cursor and scroll).
/// Stored in SessionState keyed by file path.
struct PerTabEditorState: Codable, Equatable, Sendable {
    var cursorPosition: Int
    var scrollOffset: CGFloat

    /// Retired folding state remains decodable so old sessions load, but is ignored.
    var foldedRanges: [SerializableFoldRange]?

    /// Legacy Codable representation of a FoldableRange.
    struct SerializableFoldRange: Codable, Equatable, Sendable {
        let startLine: Int
        let endLine: Int
        let startCharIndex: Int
        let endCharIndex: Int
        let kind: String
    }

    init(
        cursorPosition: Int,
        scrollOffset: CGFloat,
        foldedRanges: [SerializableFoldRange]? = nil
    ) {
        self.cursorPosition = cursorPosition
        self.scrollOffset = scrollOffset
        self.foldedRanges = foldedRanges
    }

    /// Creates a PerTabEditorState snapshot from the current EditorTab state.
    static func capture(from tab: EditorTab) -> PerTabEditorState {
        PerTabEditorState(
            cursorPosition: tab.cursorPosition,
            scrollOffset: tab.scrollOffset
        )
    }

    /// Applies persisted cursor/scroll state. Legacy folded ranges do not alter content.
    func apply(to tab: inout EditorTab) {
        let maxPosition = tab.content.utf16.count
        tab.cursorPosition = min(cursorPosition, maxPosition)
        tab.scrollOffset = scrollOffset
    }
}
