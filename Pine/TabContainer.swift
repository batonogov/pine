//
//  TabContainer.swift
//  Pine
//
//  Shared tab management logic used by both TabManager (primary pane)
//  and SplitPane (secondary pane). Eliminates duplication of closeTab,
//  updateContent, save, rename, delete, external change detection, etc.
//

import SwiftUI

/// Common interface for any object that manages a collection of editor tabs.
/// Both `TabManager` and `SplitPane` conform to this protocol, and the
/// default implementations in the extension provide all shared behavior.
protocol TabContainer: AnyObject {
    var tabs: [EditorTab] { get set }
    var activeTabID: UUID? { get set }
}

// MARK: - Default implementations

extension TabContainer {

    /// The currently active tab, if any.
    var activeTab: EditorTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    /// Index of the active tab, if any.
    var activeTabIndex: Int? {
        guard let id = activeTabID else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    /// Returns the tab for a given URL, if open.
    func tab(for url: URL) -> EditorTab? {
        tabs.first { $0.url == url }
    }

    // MARK: - Close

    /// Closes a tab by ID. Selects an adjacent tab if the closed tab was active.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        let wasActive = activeTabID == id
        tabs.remove(at: index)

        if wasActive {
            if tabs.isEmpty {
                activeTabID = nil
            } else {
                let newIndex = min(index, tabs.count - 1)
                activeTabID = tabs[newIndex].id
            }
        }
    }

    // MARK: - Content & state

    /// Updates the content of the active tab (text tabs only).
    func updateContent(_ newContent: String) {
        guard let index = activeTabIndex else { return }
        guard tabs[index].kind == .text else { return }
        tabs[index].content = newContent
    }

    /// Updates the saved editor state (cursor, scroll) for the active tab.
    func updateEditorState(cursorPosition: Int, scrollOffset: CGFloat) {
        guard let index = activeTabIndex else { return }
        tabs[index].cursorPosition = cursorPosition
        tabs[index].scrollOffset = scrollOffset
    }

    // MARK: - Save

    /// Saves the active tab to disk. Returns true on success.
    @discardableResult
    func saveActiveTab() -> Bool {
        guard let index = activeTabIndex else { return false }
        return saveTab(at: index)
    }

    /// Writes tab content to disk without UI. Throws on failure.
    @discardableResult
    func trySaveTab(at index: Int) throws -> Bool {
        let tab = tabs[index]
        guard tab.kind == .text else { return false }
        try tab.content.write(to: tab.url, atomically: true, encoding: .utf8)
        tabs[index].savedContent = tab.content
        tabs[index].lastModDate = modDate(for: tab.url)
        return true
    }

    /// Saves a specific tab by index. Returns true on success, shows alert on failure.
    @discardableResult
    func saveTab(at index: Int) -> Bool {
        do {
            return try trySaveTab(at: index)
        } catch {
            let alert = NSAlert()
            alert.messageText = Strings.fileOperationErrorTitle
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            return false
        }
    }

    /// Whether any open tab has unsaved changes.
    var hasUnsavedChanges: Bool {
        tabs.contains { $0.isDirty }
    }

    /// Returns all tabs with unsaved changes.
    var dirtyTabs: [EditorTab] {
        tabs.filter(\.isDirty)
    }

    /// Saves all dirty tabs without showing UI. Throws on first failure.
    func trySaveAllTabs() throws {
        for index in tabs.indices where tabs[index].isDirty {
            try trySaveTab(at: index)
        }
    }

    // MARK: - Reorder

    /// Moves a tab from one position to another (for drag-to-reorder).
    func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - File operations

    /// Updates URLs for renamed files, preserving tab identity.
    func handleFileRenamed(oldURL: URL, newURL: URL) {
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

    /// Returns tabs affected by deletion of a file or directory.
    func tabsAffectedByDeletion(url: URL) -> [EditorTab] {
        tabs.filter { tab in
            tab.url == url || tab.url.path.hasPrefix(url.path + "/")
        }
    }

    /// Force-closes tabs for a deleted file.
    func closeTabsForDeletedFile(url: URL) {
        for tab in tabsAffectedByDeletion(url: url) {
            closeTab(id: tab.id)
        }
    }

    /// Reloads a tab's content from disk.
    func reloadTab(url: URL) {
        guard let index = tabs.firstIndex(where: { $0.url == url }) else { return }
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            tabs[index].content = content
            tabs[index].savedContent = content
            tabs[index].lastModDate = modDate(for: url)
        }
    }

    // MARK: - External change detection

    /// Checks open tabs against disk state. Silently reloads clean tabs that were
    /// modified externally. Closes clean tabs for deleted files. Returns conflicts
    /// for dirty tabs that need user resolution.
    func checkExternalChanges() -> [TabManager.ExternalConflict] {
        var conflicts: [TabManager.ExternalConflict] = []
        var cleanDeletedIDs: [UUID] = []

        for index in tabs.indices {
            let tab = tabs[index]

            if !FileManager.default.fileExists(atPath: tab.url.path) {
                if tab.isDirty {
                    conflicts.append(.init(tabID: tab.id, url: tab.url, kind: .deleted))
                } else {
                    cleanDeletedIDs.append(tab.id)
                }
                continue
            }

            guard let diskMod = modDate(for: tab.url),
                  let lastMod = tab.lastModDate,
                  diskMod > lastMod
            else { continue }

            if tab.kind == .preview {
                tabs[index].lastModDate = diskMod
            } else if tab.isDirty {
                conflicts.append(.init(tabID: tab.id, url: tab.url, kind: .modified))
                tabs[index].lastModDate = diskMod
            } else {
                if let content = try? String(contentsOf: tab.url, encoding: .utf8) {
                    tabs[index].content = content
                    tabs[index].savedContent = content
                    tabs[index].lastModDate = diskMod
                }
            }
        }

        for id in cleanDeletedIDs {
            closeTab(id: id)
        }

        return conflicts
    }

    // MARK: - Markdown preview

    /// Cycles the preview mode for the active tab if it's a Markdown file.
    func togglePreviewMode() {
        guard let index = activeTabIndex, tabs[index].isMarkdownFile else { return }
        tabs[index].previewMode = tabs[index].previewMode.next
    }

    // MARK: - Helpers

    /// Returns the modification date of a file, or nil on error.
    func modDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
