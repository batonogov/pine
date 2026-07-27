//
//  SidebarTreeNavigation.swift
//  Pine
//
//  Finder-style keyboard navigation and type-to-select for the sidebar
//  file tree (#1238). Provides a single selection model that both the
//  SwiftUI `.onKeyPress` handlers and the AppKit responder route through,
//  eliminating the parallel-state divergence that previously left arrow,
//  Home/End, Page Up/Down, and type-ahead unimplemented.
//

import Foundation

// MARK: - Flattened visible rows

/// A visible row in the sidebar tree, annotated with its nesting depth.
///
/// Depth is used to find a row's parent during Left-arrow navigation
/// without depending on URL path normalisation (which is unreliable
/// across symlinked directories and trailing-slash variants).
struct SidebarVisibleRow: Equatable {
    let node: FileNode
    let depth: Int
}

/// Flattens the recursive sidebar file tree into the ordered list of
/// currently-visible rows (respecting folder expansion state).
enum SidebarTreeFlattener {
    /// Returns the depth-first list of visible rows. A folder's children
    /// are included only when the folder is expanded and has loaded children.
    static func visibleRows(
        rootNodes: [FileNode],
        expansion: SidebarExpansionState
    ) -> [SidebarVisibleRow] {
        var rows: [SidebarVisibleRow] = []
        appendVisible(rootNodes, depth: 0, expansion: expansion, into: &rows)
        return rows
    }

    private static func appendVisible(
        _ nodes: [FileNode],
        depth: Int,
        expansion: SidebarExpansionState,
        into rows: inout [SidebarVisibleRow]
    ) {
        for node in nodes {
            rows.append(SidebarVisibleRow(node: node, depth: depth))
            if node.isDirectory,
               expansion.isExpanded(node.url),
               let children = node.children {
                appendVisible(children, depth: depth + 1, expansion: expansion, into: &rows)
            }
        }
    }
}

// MARK: - Type-ahead

/// Finder-style type-to-select with repeated-character cycling.
///
/// Behaviour mirrors macOS Finder:
/// - A single character selects the first visible row whose name begins
///   with that character (case-insensitive, Unicode-aware).
/// - Typing the same character again within the reset interval cycles
///   through all matching rows.
/// - Typing a different character within the interval builds a prefix.
///   If no row matches the full prefix, the buffer resets to the new
///   character alone.
/// - After ``resetInterval`` seconds of inactivity the buffer clears.
struct SidebarTypeAhead {
    /// Current search buffer (lowercased).
    private(set) var buffer = ""
    private var lastTypedAt: TimeInterval = 0
    private static let resetInterval: TimeInterval = 0.5

    /// Processes a typed character and returns the index of the row to
    /// select, or `nil` if no row matches.
    mutating func handle(
        character: String,
        rows: [SidebarVisibleRow],
        currentIndex: Int?
    ) -> Int? {
        guard !rows.isEmpty else { return nil }
        let now = Date().timeIntervalSinceReferenceDate
        let timedOut = now - lastTypedAt > Self.resetInterval
        defer { lastTypedAt = now }

        let lowered = character.lowercased()
        guard !lowered.isEmpty else { return nil }

        if timedOut {
            buffer = lowered
            return firstMatch(for: lowered, rows: rows, searchOrigin: 0)
        }

        // Same single character repeated → cycle through matches.
        if buffer.count == 1, lowered == buffer {
            let origin = ((currentIndex ?? -1) + 1) % rows.count
            return firstMatch(for: lowered, rows: rows, searchOrigin: max(0, origin))
        }

        // Build prefix and try to match.
        let candidate = buffer + lowered
        if let match = firstMatch(for: candidate, rows: rows, searchOrigin: 0) {
            buffer = candidate
            return match
        }

        // Multi-char prefix has no match: fall back to the new char alone.
        buffer = lowered
        return firstMatch(for: lowered, rows: rows, searchOrigin: 0)
    }

    /// Finds the first row (cycling from ``searchOrigin``) whose name
    /// starts with ``prefix``. The comparison is case-insensitive and
    /// works with any Unicode filename (Cyrillic, CJK, etc.).
    private func firstMatch(
        for prefix: String,
        rows: [SidebarVisibleRow],
        searchOrigin: Int
    ) -> Int? {
        guard !prefix.isEmpty, !rows.isEmpty else { return nil }
        let count = rows.count
        let origin = ((searchOrigin % count) + count) % count
        let loweredPrefix = prefix.lowercased()
        for offset in 0..<count {
            let index = (origin + offset) % count
            if rows[index].node.name.lowercased().hasPrefix(loweredPrefix) {
                return index
            }
        }
        return nil
    }

    mutating func reset() {
        buffer = ""
        lastTypedAt = 0
    }
}

// MARK: - Navigation model

/// Single selection model for sidebar keyboard navigation.
///
/// Owns type-ahead state and routes all keyboard-driven selection
/// changes through one place so the SwiftUI `.onKeyPress` handlers and
/// the AppKit ``SidebarKeyboardResponderView`` never diverge (#1238).
///
/// The model is **stateless** with respect to the tree contents: every
/// navigation method receives the current flattened row list as a
/// parameter and returns the new selection. Only the type-ahead buffer
/// and the optional scroll callback are stored.
@MainActor
@Observable
final class SidebarTreeNavigation {
    private(set) var typeAhead = SidebarTypeAhead()

    /// Scroll callback invoked after selection changes to keep the
    /// selected row visible. Set by ``SidebarView`` via the
    /// ``ScrollViewProxy`` captured inside ``ScrollViewReader``.
    var scrollToNode: ((URL) -> Void)?

    /// Viewport height of the sidebar scroll area, used to estimate page
    /// size for Page Up / Page Down.
    var viewportHeight: Double = 400

    /// Estimated number of visible rows per page, derived from the
    /// viewport height and the minimum row height.
    var estimatedPageSize: Int {
        max(1, Int(viewportHeight / SidebarRowMetrics.minRowHeight))
    }

    // MARK: - Linear movement (Up / Down / Home / End / Page)

    func moveDown(current: FileNode?, rows: [SidebarVisibleRow]) -> FileNode? {
        move(by: 1, current: current, rows: rows)
    }

    func moveUp(current: FileNode?, rows: [SidebarVisibleRow]) -> FileNode? {
        move(by: -1, current: current, rows: rows)
    }

    func firstRow(rows: [SidebarVisibleRow]) -> FileNode? {
        rows.first?.node
    }

    func lastRow(rows: [SidebarVisibleRow]) -> FileNode? {
        rows.last?.node
    }

    func pageDown(current: FileNode?, rows: [SidebarVisibleRow]) -> FileNode? {
        move(by: estimatedPageSize, current: current, rows: rows)
    }

    func pageUp(current: FileNode?, rows: [SidebarVisibleRow]) -> FileNode? {
        move(by: -estimatedPageSize, current: current, rows: rows)
    }

    /// Moves the selection by ``delta`` rows, clamping to the visible bounds.
    /// When there is no current selection, Down picks the first row and Up
    /// picks the last row.
    func move(
        by delta: Int,
        current: FileNode?,
        rows: [SidebarVisibleRow]
    ) -> FileNode? {
        guard !rows.isEmpty else { return nil }
        let currentIndex = indexOf(current, in: rows)
        let resolvedIndex: Int
        if let currentIndex {
            resolvedIndex = currentIndex
        } else {
            resolvedIndex = delta > 0 ? -1 : rows.count
        }
        let nextIndex = max(0, min(rows.count - 1, resolvedIndex + delta))
        return rows[nextIndex].node
    }

    // MARK: - Expand / collapse (Left / Right)

    /// Left collapses an expanded folder or moves selection to the parent.
    /// Returns the node that should be selected (which may be the same as
    /// `current` when only a collapse occurred), or `nil` if there is no
    /// current selection.
    @discardableResult
    func handleLeftArrow(
        current: FileNode?,
        rows: [SidebarVisibleRow],
        expansion: SidebarExpansionState
    ) -> FileNode? {
        guard let current else { return nil }
        if current.isDirectory, expansion.isExpanded(current.url) {
            expansion.setExpanded(current.url, false)
            return current
        }
        // Collapsed folder or file → move to parent.
        return parent(of: current, in: rows)
    }

    /// Right expands a collapsed folder or enters the first child of an
    /// already-expanded folder. Returns the node that should be selected
    /// (which may be the same as `current` when only an expansion
    /// occurred), or `nil` for files or folders with no children.
    @discardableResult
    func handleRightArrow(
        current: FileNode?,
        rows: [SidebarVisibleRow],
        expansion: SidebarExpansionState
    ) -> FileNode? {
        guard let current, current.isDirectory else { return nil }
        if !expansion.isExpanded(current.url) {
            expansion.setExpanded(current.url, true)
            return current
        }
        // Already expanded → move to first child.
        if let firstChild = current.children?.first {
            return firstChild
        }
        return nil
    }

    // MARK: - Type-ahead

    func typeSelect(
        character: String,
        current: FileNode?,
        rows: [SidebarVisibleRow]
    ) -> FileNode? {
        let currentIndex = indexOf(current, in: rows)
        guard let index = typeAhead.handle(
            character: character,
            rows: rows,
            currentIndex: currentIndex
        ) else {
            return nil
        }
        return rows[index].node
    }

    func resetTypeAhead() {
        typeAhead.reset()
    }

    // MARK: - Helpers

    func scroll(to node: FileNode) {
        scrollToNode?(node.id)
    }

    private func indexOf(_ node: FileNode?, in rows: [SidebarVisibleRow]) -> Int? {
        guard let node else { return nil }
        return rows.firstIndex { $0.node.id == node.id }
    }

    /// Finds the parent of ``node`` by searching backwards for the nearest
    /// visible row at depth ``node.depth - 1``.
    private func parent(of node: FileNode, in rows: [SidebarVisibleRow]) -> FileNode? {
        guard let nodeIndex = rows.firstIndex(where: { $0.node.id == node.id }) else {
            return nil
        }
        let targetDepth = rows[nodeIndex].depth - 1
        guard targetDepth >= 0 else { return nil }
        for index in stride(from: nodeIndex - 1, through: 0, by: -1) {
            if rows[index].depth == targetDepth {
                return rows[index].node
            }
        }
        return nil
    }
}
