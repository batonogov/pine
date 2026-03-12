//
//  TabManager.swift
//  Pine
//
//  Created by Claude on 12.03.2026.
//

import SwiftUI

/// Manages the set of open editor tabs and the active selection.
@Observable
final class TabManager {
    var tabs: [EditorTab] = []
    var activeTabID: UUID?

    var activeTab: EditorTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    /// Index of the active tab, if any.
    private var activeTabIndex: Int? {
        guard let id = activeTabID else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    /// Opens a file in a new tab, or activates the existing tab if already open.
    func openTab(url: URL) {
        // Dedup: if already open, just activate
        if let existing = tabs.first(where: { $0.url == url }) {
            activeTabID = existing.id
            return
        }

        // Load file content
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            content = "// Error: \(error.localizedDescription)"
        }

        let tab = EditorTab(url: url, content: content, savedContent: content)
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// Closes a tab by ID. Selects an adjacent tab if the closed tab was active.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        let wasActive = activeTabID == id
        tabs.remove(at: index)

        if wasActive {
            if tabs.isEmpty {
                activeTabID = nil
            } else {
                // Prefer the tab at the same index, or the last one
                let newIndex = min(index, tabs.count - 1)
                activeTabID = tabs[newIndex].id
            }
        }
    }

    /// Updates the content of the active tab.
    func updateContent(_ newContent: String) {
        guard let index = activeTabIndex else { return }
        tabs[index].content = newContent
    }

    /// Saves the active tab to disk. Returns true on success.
    @discardableResult
    func saveActiveTab() -> Bool {
        guard let index = activeTabIndex else { return false }
        return saveTab(at: index)
    }

    /// Writes tab content to disk without UI. Returns true on success.
    /// On failure, throws — callers decide how to present the error.
    @discardableResult
    func trySaveTab(at index: Int) throws -> Bool {
        let tab = tabs[index]
        try tab.content.write(to: tab.url, atomically: true, encoding: .utf8)
        tabs[index].savedContent = tab.content
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

    /// Moves a tab from one position to another (for drag-to-reorder).
    func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    /// Whether any open tab has unsaved changes.
    var hasUnsavedChanges: Bool {
        tabs.contains { $0.isDirty }
    }

    /// Returns the tab for a given URL, if open.
    func tab(for url: URL) -> EditorTab? {
        tabs.first { $0.url == url }
    }

    /// Handles a file being renamed — updates any affected tabs.
    func handleFileRenamed(oldURL: URL, newURL: URL) {
        for index in tabs.indices {
            let tabURL = tabs[index].url
            if tabURL == oldURL {
                let tab = EditorTab(url: newURL, content: tabs[index].content, savedContent: tabs[index].savedContent)
                let wasActive = activeTabID == tabs[index].id
                tabs[index] = tab
                if wasActive { activeTabID = tab.id }
            } else if tabURL.path.hasPrefix(oldURL.path + "/") {
                let relativePath = String(tabURL.path.dropFirst(oldURL.path.count + 1))
                let updatedURL = newURL.appendingPathComponent(relativePath)
                let tab = EditorTab(url: updatedURL, content: tabs[index].content, savedContent: tabs[index].savedContent)
                let wasActive = activeTabID == tabs[index].id
                tabs[index] = tab
                if wasActive { activeTabID = tab.id }
            }
        }
    }

    /// Handles a file being deleted — closes affected tabs (with unsaved changes dialog if needed).
    /// Returns the URLs of tabs that need unsaved-changes prompts before closing.
    func tabsAffectedByDeletion(url: URL) -> [EditorTab] {
        tabs.filter { tab in
            tab.url == url || tab.url.path.hasPrefix(url.path + "/")
        }
    }

    /// Force-closes tabs for a deleted file (after user confirmed or chose not to save).
    func closeTabsForDeletedFile(url: URL) {
        let affected = tabs.filter { tab in
            tab.url == url || tab.url.path.hasPrefix(url.path + "/")
        }
        for tab in affected {
            closeTab(id: tab.id)
        }
    }
}
