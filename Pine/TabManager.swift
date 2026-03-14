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

        var tab = EditorTab(url: url, content: content, savedContent: content)
        tab.lastModDate = modDate(for: url)
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

    /// Updates the saved editor state (cursor, scroll) for the active tab.
    func updateEditorState(cursorPosition: Int, scrollOffset: CGFloat) {
        guard let index = activeTabIndex else { return }
        tabs[index].cursorPosition = cursorPosition
        tabs[index].scrollOffset = scrollOffset
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

    /// Moves a tab from one position to another (for drag-to-reorder).
    func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
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

    /// Saves all dirty tabs. Returns true if all succeeded.
    /// Shows an alert on failure.
    @discardableResult
    func saveAllTabs() -> Bool {
        do {
            try trySaveAllTabs()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = Strings.fileOperationErrorTitle
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            return false
        }
    }

    /// Saves the active tab to a new URL. Updates the tab's URL in-place
    /// to keep identity (undo history, cursor, etc.). Throws on write failure.
    @discardableResult
    func saveActiveTabAs(to newURL: URL) throws -> Bool {
        guard let index = activeTabIndex else { return false }
        let tab = tabs[index]
        try tab.content.write(to: newURL, atomically: true, encoding: .utf8)
        tabs[index].url = newURL
        tabs[index].savedContent = tab.content
        tabs[index].lastModDate = modDate(for: newURL)
        return true
    }

    /// Duplicates the active tab with Finder-like naming ("file copy.ext",
    /// "file copy 2.ext", etc.). Returns true on success.
    @discardableResult
    func duplicateActiveTab() -> Bool {
        guard let index = activeTabIndex else { return false }
        let tab = tabs[index]
        let originalURL = tab.url

        guard let duplicateURL = finderCopyURL(for: originalURL) else { return false }

        do {
            try tab.content.write(to: duplicateURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        var newTab = EditorTab(
            url: duplicateURL,
            content: tab.content,
            savedContent: tab.content
        )
        newTab.lastModDate = modDate(for: duplicateURL)
        tabs.insert(newTab, at: index + 1)
        activeTabID = newTab.id
        return true
    }

    /// Generates a Finder-style copy URL: "file copy.ext", "file copy 2.ext", etc.
    private func finderCopyURL(for url: URL) -> URL? {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let baseName = ext.isEmpty
            ? url.lastPathComponent
            : String(url.lastPathComponent.dropLast(ext.count + 1))

        let fm = FileManager.default
        for counter in 0... {
            let copyName: String
            if counter == 0 {
                copyName = ext.isEmpty
                    ? "\(baseName) copy"
                    : "\(baseName) copy.\(ext)"
            } else {
                copyName = ext.isEmpty
                    ? "\(baseName) copy \(counter + 1)"
                    : "\(baseName) copy \(counter + 1).\(ext)"
            }
            let candidate = directory.appendingPathComponent(copyName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Returns the tab for a given URL, if open.
    func tab(for url: URL) -> EditorTab? {
        tabs.first { $0.url == url }
    }

    /// Handles a file being renamed — updates URL in-place to preserve tab identity
    /// (and thus editor state, undo history, cursor position, etc.).
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

    // MARK: - External change detection

    /// Describes an external change that requires user action (dirty tab conflict).
    struct ExternalConflict {
        let tabID: UUID
        let url: URL
        let kind: Kind
        enum Kind: Equatable { case modified, deleted }
    }

    /// Checks open tabs against disk state. Silently reloads clean tabs that were
    /// modified externally. Closes clean tabs for deleted files. Returns conflicts
    /// for dirty tabs that need user resolution.
    func checkExternalChanges() -> [ExternalConflict] {
        var conflicts: [ExternalConflict] = []
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

            if tab.isDirty {
                conflicts.append(.init(tabID: tab.id, url: tab.url, kind: .modified))
                tabs[index].lastModDate = diskMod
            } else {
                // Safe to reload silently
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

    /// Reloads a tab's content from disk (used after user chooses "reload" in conflict dialog).
    func reloadTab(url: URL) {
        guard let index = tabs.firstIndex(where: { $0.url == url }) else { return }
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            tabs[index].content = content
            tabs[index].savedContent = content
            tabs[index].lastModDate = modDate(for: url)
        }
    }

    /// Returns the modification date of a file, or nil on error.
    private func modDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
