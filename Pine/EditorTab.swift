//
//  EditorTab.swift
//  Pine
//
//  Created by Claude on 12.03.2026.
//

import Foundation

/// Payload pushed back into the editor view after a disk read/write that
/// changed the on-disk text and must be resynced into the NSTextView.
///
/// Carried (NOT posted synchronously) out of any `inout tabs` scope: the
/// caller posts `.tabReloadedFromDisk` AFTER the exclusive `&tabs` access
/// has ended. Posting inside that scope delivered the synchronous observer
/// back into `TabManager.tabs` (`updateHighlightCache`) → Swift runtime
/// exclusivity abort (#1066). Shared by the save path
/// (`TabPersistence.SaveOutcome.reload`) and the external-change path
/// (`TabExternalChangeDetector` reloads), which both need the same
/// url + text to resync the view.
struct ReloadedTab: Sendable {
    let url: URL
    let text: String
}

/// Represents a single open editor tab with its file URL and content state.
struct EditorTab: Identifiable, Hashable {

    /// Whether this tab shows an editable text file or a Quick Look preview.
    enum TabKind: Sendable { case text, preview }

    /// A buffer may exist before it has a filesystem destination. Keeping that
    /// state explicit prevents New File from fabricating a writable path and
    /// lets Save route the first write through a native Save panel.
    enum Backing: Hashable, Sendable {
        case file(URL)
        case untitled(displayName: String)
    }

    let id: UUID
    private(set) var backing: Backing
    /// Compatibility URL for identity-only call sites. Untitled buffers use a
    /// private non-file scheme; code that performs filesystem work must use
    /// ``fileURL`` and handle `nil`.
    var url: URL {
        get {
            switch backing {
            case .file(let url):
                return url
            case .untitled:
                return URL(string: "pine-untitled:///\(id.uuidString)")
                    ?? URL(fileURLWithPath: "/.pine-untitled/\(id.uuidString)")
            }
        }
        set {
            backing = .file(newValue)
        }
    }
    var fileURL: URL? {
        guard case .file(let url) = backing else { return nil }
        return url
    }
    var isUntitled: Bool {
        if case .untitled = backing { return true }
        return false
    }
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

    /// Whether this tab's content was truncated on load (huge file partial load).
    var isTruncated: Bool = false

    /// Whether this tab is pinned (always visible at the left, protected from close).
    var isPinned: Bool = false

    /// Whether this tab is a transient preview opened via single-click navigation.
    /// A transient preview is replaced (not stacked) when another file is opened
    /// as a preview in the same pane. It is promoted to a permanent tab on
    /// edit, pin, explicit open, or move.
    ///
    /// Unrelated to `kind == .preview` (Quick Look binary preview), which is a
    /// permanent read-only representation of non-text files.
    var isTransientPreview: Bool = false

    /// Cached syntax highlight matches — applied synchronously on tab switch
    /// to eliminate the flash of unhighlighted text.
    /// Not included in Hashable/Equatable (which use id only).
    var cachedHighlightResult: HighlightMatchResult?

    /// The detected file encoding. Used for saving the file in its original encoding.
    var encoding: String.Encoding = .utf8

    var isDirty: Bool { kind == .text && content != savedContent }

    /// Whether this tab's file is a Markdown file (.md or .markdown).
    var isMarkdownFile: Bool {
        guard let fileURL else { return false }
        let ext = (fileURL.lastPathComponent as NSString)
            .pathExtension
            .lowercased()
        return ext == "md" || ext == "markdown"
    }

    var fileName: String {
        switch backing {
        case .file(let url):
            url.lastPathComponent
        case .untitled(let displayName):
            displayName
        }
    }

    var language: String {
        guard let fileURL else { return "" }
        return (fileURL.lastPathComponent as NSString)
            .pathExtension
            .lowercased()
    }

    init(url: URL, content: String = "", savedContent: String = "", kind: TabKind = .text) {
        self.id = UUID()
        self.backing = .file(url)
        self.content = content
        self.savedContent = savedContent
        self.kind = kind
    }

    init(
        untitledName: String,
        content: String = "",
        savedContent: String = ""
    ) {
        self.id = UUID()
        self.backing = .untitled(displayName: untitledName)
        self.content = content
        self.savedContent = savedContent
        self.kind = .text
    }

    /// Creates a copy of a tab with a fresh UUID, preserving all content and editor state.
    /// Used when moving tabs between panes to avoid identity collisions.
    static func reidentified(from source: EditorTab) -> EditorTab {
        var copy: EditorTab
        switch source.backing {
        case .file(let url):
            copy = EditorTab(
                url: url,
                content: source.content,
                savedContent: source.savedContent,
                kind: source.kind
            )
        case .untitled(let displayName):
            copy = EditorTab(
                untitledName: displayName,
                content: source.content,
                savedContent: source.savedContent
            )
        }
        copy.cursorPosition = source.cursorPosition
        copy.scrollOffset = source.scrollOffset
        copy.cursorLine = source.cursorLine
        copy.cursorColumn = source.cursorColumn
        copy.fileSizeBytes = source.fileSizeBytes
        copy.lastModDate = source.lastModDate
        copy.foldState = source.foldState
        copy.previewMode = source.previewMode
        copy.syntaxHighlightingDisabled = source.syntaxHighlightingDisabled
        copy.isTruncated = source.isTruncated
        copy.isPinned = source.isPinned
        copy.cachedHighlightResult = source.cachedHighlightResult
        copy.encoding = source.encoding
        copy.recomputeContentCaches()
        return copy
    }

    // Hashable by id only — content/state changes shouldn't affect identity.
    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
