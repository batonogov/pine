//
//  PerTabEditorState.swift
//  Pine
//
//  Serializable per-tab editor state for session persistence.
//

import Foundation
import os.log

/// Codable representation of per-tab editor state (cursor, scroll, folds).
/// Stored in SessionState keyed by file path.
struct PerTabEditorState: Codable, Equatable {
    var cursorPosition: Int
    var scrollOffset: CGFloat
    var foldedRanges: [SerializableFoldRange]?

    /// Codable representation of a FoldableRange.
    struct SerializableFoldRange: Codable, Equatable {
        let startLine: Int
        let endLine: Int
        let startCharIndex: Int
        let endCharIndex: Int
        let kind: String
    }

    // MARK: - Capture from EditorTab

    /// Creates a PerTabEditorState snapshot from the current EditorTab state.
    static func capture(from tab: EditorTab) -> PerTabEditorState {
        let folds = serializableFoldRanges(from: tab.foldState)
        return PerTabEditorState(
            cursorPosition: tab.cursorPosition,
            scrollOffset: tab.scrollOffset,
            foldedRanges: folds.isEmpty ? nil : folds
        )
    }

    // MARK: - Apply to EditorTab

    /// Applies the persisted state to an EditorTab (cursor, scroll, folds).
    /// Cursor position is clamped to the content length to avoid out-of-bounds
    /// crashes when the file has been shortened externally.
    func apply(to tab: inout EditorTab) {
        let maxPosition = tab.content.utf16.count
        tab.cursorPosition = min(cursorPosition, maxPosition)
        tab.scrollOffset = scrollOffset
        if let ranges = foldedRanges {
            tab.foldState = Self.restoreFoldState(from: ranges)
        } else {
            tab.foldState = FoldState()
        }
    }

    // MARK: - FoldState conversion

    /// Converts a FoldState's folded ranges to serializable form.
    static func serializableFoldRanges(from foldState: FoldState) -> [SerializableFoldRange] {
        foldState.foldedRanges.map { range in
            SerializableFoldRange(
                startLine: range.startLine,
                endLine: range.endLine,
                startCharIndex: range.startCharIndex,
                endCharIndex: range.endCharIndex,
                kind: kindString(from: range.kind)
            )
        }
    }

    /// Restores a FoldState from serialized fold ranges.
    static func restoreFoldState(from ranges: [SerializableFoldRange]) -> FoldState {
        var foldState = FoldState()
        for range in ranges {
            let foldable = FoldableRange(
                startLine: range.startLine,
                endLine: range.endLine,
                startCharIndex: range.startCharIndex,
                endCharIndex: range.endCharIndex,
                kind: foldKind(from: range.kind)
            )
            foldState.fold(foldable)
        }
        return foldState
    }

    // MARK: - Private helpers

    private static func kindString(from kind: FoldKind) -> String {
        switch kind {
        case .braces: "braces"
        case .brackets: "brackets"
        case .parentheses: "parentheses"
        }
    }

    private static let logger = Logger(subsystem: "com.pine.editor", category: "PerTabEditorState")

    private static func foldKind(from string: String) -> FoldKind {
        switch string {
        case "braces": return .braces
        case "brackets": return .brackets
        case "parentheses": return .parentheses
        default:
            logger.warning("Unknown fold kind '\(string)', defaulting to .braces")
            return .braces
        }
    }
}
