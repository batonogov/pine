//
//  EditorTab.swift
//  Pine
//
//  Created by Claude on 12.03.2026.
//

import Foundation

/// Represents a single open editor tab with its file URL and content state.
struct EditorTab: Identifiable, Hashable {

    /// Whether this tab shows an editable text file or a Quick Look preview.
    enum TabKind { case text, preview }

    let id: UUID
    var url: URL
    var content: String {
        didSet { contentVersion &+= 1 }
    }
    var savedContent: String
    var kind: TabKind

    /// Monotonic counter incremented on every content mutation.
    /// Used for O(1) change detection instead of O(n) string comparison.
    private(set) var contentVersion: UInt64 = 0

    // Per-tab editor state — preserved across tab switches.
    var cursorPosition: Int = 0
    var scrollOffset: CGFloat = 0

    /// Cached cursor line/column — updated by TabManager.updateEditorState().
    var cursorLine: Int = 1
    var cursorColumn: Int = 1

    /// Cached file size in bytes — set on open and after save.
    var fileSizeBytes: Int?

    /// Cached indentation style — recomputed by `recomputeContentCaches()`.
    private(set) var cachedIndentation: IndentationStyle = .spaces(4)
    /// Cached line ending style — recomputed by `recomputeContentCaches()`.
    private(set) var cachedLineEnding: LineEnding = .lf

    /// Recomputes indentation and line ending caches from current content.
    /// Called by TabManager when content changes — keeps reads mutation-free.
    mutating func recomputeContentCaches() {
        cachedIndentation = IndentationStyle.detect(in: content)
        cachedLineEnding = LineEnding.detect(in: content)
    }

    /// Last known modification date of the file on disk.
    /// Used to detect external changes by comparing with the current stat.
    var lastModDate: Date?

    /// Состояние свёрнутых регионов кода.
    var foldState: FoldState = FoldState()

    /// Markdown preview mode (source/preview/split). Only meaningful for markdown files.
    var previewMode: MarkdownPreviewMode = .source

    /// Whether syntax highlighting is disabled for this tab (e.g. large files).
    var syntaxHighlightingDisabled: Bool = false

    /// The detected file encoding. Used for saving the file in its original encoding.
    var encoding: String.Encoding = .utf8

    var isDirty: Bool { kind == .text && content != savedContent }

    /// Whether this tab's file is a Markdown file (.md or .markdown).
    var isMarkdownFile: Bool {
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    var fileName: String { url.lastPathComponent }

    var language: String {
        (url.lastPathComponent as NSString).pathExtension.lowercased()
    }

    init(url: URL, content: String = "", savedContent: String = "", kind: TabKind = .text) {
        self.id = UUID()
        self.url = url
        self.content = content
        self.savedContent = savedContent
        self.kind = kind
    }

    // Hashable by id only — content/state changes shouldn't affect identity.
    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
