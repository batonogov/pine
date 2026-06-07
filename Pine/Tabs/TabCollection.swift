//
//  TabCollection.swift
//  Pine
//
//  Extracted from TabManager.swift — pure tab collection operations.
//

import SwiftUI

/// Pure data operations on tab collections: lookup, reorder, close helpers.
/// All methods are stateless and operate on `[EditorTab]` directly.
enum TabCollection {
    // MARK: - Lookup

    /// Returns the tab matching the given URL, if any.
    static func tab(for url: URL, in tabs: [EditorTab]) -> EditorTab? {
        tabs.first { $0.url == url }
    }

    /// Returns the tab matching the given ID, if any.
    static func tab(for id: UUID, in tabs: [EditorTab]) -> EditorTab? {
        tabs.first { $0.id == id }
    }

    /// Returns the index of the tab matching the given ID.
    static func index(of id: UUID, in tabs: [EditorTab]) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    // MARK: - Dirty tabs

    /// Whether any open tab has unsaved changes.
    static func hasUnsavedChanges(in tabs: [EditorTab]) -> Bool {
        tabs.contains { $0.isDirty }
    }

    /// Returns all tabs with unsaved changes.
    static func dirtyTabs(in tabs: [EditorTab]) -> [EditorTab] {
        tabs.filter(\.isDirty)
    }

    // MARK: - Reorder

    /// Reorders a tab by moving the dragged tab to the target tab's position.
    /// Pinned tabs can only reorder within the pinned group; unpinned within unpinned.
    static func reorderTab(draggedID: UUID, targetID: UUID, in tabs: inout [EditorTab]) {
        guard draggedID != targetID else { return }
        guard let fromIndex = tabs.firstIndex(where: { $0.id == draggedID }),
              let toIndex = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        // Prevent dragging between pinned and unpinned groups
        guard tabs[fromIndex].isPinned == tabs[toIndex].isPinned else { return }
        tabs.move(
            fromOffsets: IndexSet(integer: fromIndex),
            toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
        )
    }

    // MARK: - Close helpers

    /// Returns the dirty (unsaved) tabs that would be closed by `closeOtherTabs`.
    /// Pinned tabs and the kept tab are excluded.
    static func dirtyTabsForCloseOthers(keeping tabID: UUID, in tabs: [EditorTab]) -> [EditorTab] {
        tabs.filter { $0.id != tabID && !$0.isPinned && $0.isDirty }
    }

    /// Returns the dirty (unsaved) tabs that would be closed by `closeTabsToTheRight`.
    static func dirtyTabsForCloseRight(of tabID: UUID, in tabs: [EditorTab]) -> [EditorTab] {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return [] }
        return Array(tabs[(index + 1)...].filter { !$0.isPinned && $0.isDirty })
    }

    /// Returns the dirty (unsaved) tabs that would be closed by `closeAllTabs`.
    static func dirtyTabsForCloseAll(in tabs: [EditorTab]) -> [EditorTab] {
        tabs.filter(\.isDirty)
    }

    // MARK: - File operations

    /// Handles a file being renamed — updates URL in-place to preserve tab identity.
    static func handleFileRenamed(oldURL: URL, newURL: URL, in tabs: inout [EditorTab]) {
        for index in tabs.indices {
            let tabURL = tabs[index].url
            if tabURL == oldURL {
                tabs[index].url = newURL
            } else if tabURL.path.hasPrefix(oldURL.path + "/") {
                let relativePath = String(tabURL.path.dropFirst(oldURL.path.count + 1))
                tabs[index].url = newURL.appendingPathComponent(relativePath)
            }
        }
    }

    /// Returns tabs affected by a file deletion.
    static func tabsAffectedByDeletion(url: URL, in tabs: [EditorTab]) -> [EditorTab] {
        tabs.filter { tab in
            tab.url == url || tab.url.path.hasPrefix(url.path + "/")
        }
    }

    // MARK: - Navigation

    /// Next tab index with wrap-around.
    static func nextTabIndex(current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return (current + 1) % count
    }

    /// Previous tab index with wrap-around.
    static func previousTabIndex(current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return count - 1 }
        return (current - 1 + count) % count
    }
}
