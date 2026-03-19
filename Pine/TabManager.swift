//
//  TabManager.swift
//  Pine
//
//  Created by Claude on 12.03.2026.
//

import SwiftUI
import UniformTypeIdentifiers

/// Manages the set of open editor tabs and the active selection.
@Observable
final class TabManager: TabContainer {
    /// File size threshold (in bytes) above which a warning is shown before opening.
    static let largeFileThreshold = 1_048_576 // 1 MB

    var tabs: [EditorTab] = []
    var activeTabID: UUID?
    /// Line number to scroll to after opening a tab (1-based). Consumed by the editor view.
    var pendingGoToLine: Int?

    /// Opens a file in a new tab, or activates the existing tab if already open.
    func openTab(url: URL) {
        // Dedup: if already open, just activate
        if let existing = tabs.first(where: { $0.url == url }) {
            activeTabID = existing.id
            return
        }

        if isPreviewFile(url: url) {
            var tab = EditorTab(url: url, kind: .preview)
            tab.lastModDate = modDate(for: url)
            tabs.append(tab)
            activeTabID = tab.id
            return
        }

        // Large file warning
        if let size = fileSize(url: url), size >= Self.largeFileThreshold {
            let sizeMB = Double(size) / 1_048_576.0
            let result = showLargeFileAlert(fileName: url.lastPathComponent, sizeMB: sizeMB)
            switch result {
            case .cancel:
                return
            case .openWithHighlighting:
                break
            case .openWithoutHighlighting:
                openTabInternal(url: url, syntaxHighlightingDisabled: true)
                return
            }
        }

        openTabInternal(url: url, syntaxHighlightingDisabled: false)
    }

    /// Opens a file and scrolls to a specific line.
    func openTabAndGoToLine(url: URL, line: Int) {
        openTab(url: url)
        pendingGoToLine = line
    }

    /// Opens a file with an explicit syntax highlighting override (skips the large file alert).
    /// Used by session restoration to reopen files in their saved state.
    func openTab(url: URL, syntaxHighlightingDisabled: Bool) {
        if let existing = tabs.first(where: { $0.url == url }) {
            activeTabID = existing.id
            return
        }

        if isPreviewFile(url: url) {
            var tab = EditorTab(url: url, kind: .preview)
            tab.lastModDate = modDate(for: url)
            tabs.append(tab)
            activeTabID = tab.id
            return
        }

        openTabInternal(url: url, syntaxHighlightingDisabled: syntaxHighlightingDisabled)
    }

    /// Internal method to create and append a text tab.
    private func openTabInternal(url: URL, syntaxHighlightingDisabled: Bool) {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            content = "// Error: \(error.localizedDescription)"
        }

        var tab = EditorTab(url: url, content: content, savedContent: content)
        tab.lastModDate = modDate(for: url)
        tab.syntaxHighlightingDisabled = syntaxHighlightingDisabled
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// Result of the large file warning alert.
    enum LargeFileAlertResult {
        case openWithHighlighting
        case openWithoutHighlighting
        case cancel
    }

    /// Shows a warning alert for large files. Returns the user's choice.
    private func showLargeFileAlert(fileName: String, sizeMB: Double) -> LargeFileAlertResult {
        let alert = NSAlert()
        alert.messageText = Strings.largeFileWarningTitle
        alert.informativeText = Strings.largeFileWarningMessage(fileName, sizeMB)
        alert.alertStyle = .warning
        alert.addButton(withTitle: Strings.largeFileOpenWithoutHighlighting)
        alert.addButton(withTitle: Strings.largeFileOpenWithHighlighting)
        alert.addButton(withTitle: Strings.dialogCancel)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .openWithoutHighlighting
        case .alertSecondButtonReturn:
            return .openWithHighlighting
        default:
            return .cancel
        }
    }

    // closeTab, updateContent, updateEditorState, saveActiveTab, trySaveTab,
    // saveTab, moveTab, hasUnsavedChanges, dirtyTabs, trySaveAllTabs
    // are provided by the TabContainer protocol extension.

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

    /// Duplicates the active tab without UI. Throws on write failure.
    /// If `projectRoot` is provided, blocks duplication of files outside the project root.
    @discardableResult
    func tryDuplicateActiveTab(projectRoot: URL? = nil) throws -> Bool {
        guard let index = activeTabIndex else { return false }
        let tab = tabs[index]
        let originalURL = tab.url

        if let root = projectRoot, !FileNode.isWithinProjectRoot(originalURL, projectRoot: root) {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: Strings.operationOutsideProject
            ])
        }

        guard let duplicateURL = finderCopyURL(for: originalURL) else { return false }

        try tab.content.write(to: duplicateURL, atomically: true, encoding: .utf8)

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

    /// Duplicates the active tab with Finder-like naming ("file copy.ext",
    /// "file copy 2.ext", etc.). Returns true on success, shows alert on failure.
    /// If `projectRoot` is provided, blocks duplication of files outside the project root.
    @discardableResult
    func duplicateActiveTab(projectRoot: URL? = nil) -> Bool {
        do {
            return try tryDuplicateActiveTab(projectRoot: projectRoot)
        } catch {
            let alert = NSAlert()
            alert.messageText = Strings.fileOperationErrorTitle
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            return false
        }
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

    // tab(for:), handleFileRenamed, tabsAffectedByDeletion, closeTabsForDeletedFile
    // are provided by the TabContainer protocol extension.

    // MARK: - Split editor

    /// Secondary pane for split view. Nil when not in split mode.
    var splitPane: SplitPane?

    /// Which pane currently has keyboard focus.
    var focusedSide: SplitSide = .leading

    /// Whether split view is active.
    var isSplitActive: Bool { splitPane != nil }

    /// Creates a split pane. By default, duplicates the active tab into the
    /// new pane (like VS Code's "Split Editor Right"). If `duplicateActiveTab`
    /// is false, creates an empty pane (used by session restore and openInSplit).
    func splitRight(duplicateActiveTab: Bool = true) {
        guard splitPane == nil else { return }
        let pane = SplitPane()

        if duplicateActiveTab, let tab = activeTab {
            pane.openTab(url: tab.url)
        }

        splitPane = pane
        if duplicateActiveTab && pane.activeTab != nil {
            focusedSide = .trailing
        }
    }

    /// Closes the split, merging any remaining trailing tabs into the primary pane.
    func closeSplit() {
        guard let pane = splitPane else { return }
        for tab in pane.tabs where !tabs.contains(where: { $0.url == tab.url }) {
            tabs.append(tab)
        }
        if tabs.contains(where: { $0.id == pane.activeTabID }) {
            activeTabID = pane.activeTabID
        }
        splitPane = nil
        focusedSide = .leading
    }

    /// Moves the active tab from the focused pane to the other pane.
    func moveTabToOtherPane() {
        guard let pane = splitPane else { return }

        switch focusedSide {
        case .leading:
            guard let tab = activeTab else { return }
            // Don't move if already open in the other pane
            guard !pane.tabs.contains(where: { $0.url == tab.url }) else { return }
            pane.tabs.append(tab)
            pane.activeTabID = tab.id
            closeTab(id: tab.id)
            focusedSide = .trailing
            autoCloseSplitIfEmpty()

        case .trailing:
            guard let tab = pane.activeTab else { return }
            guard !tabs.contains(where: { $0.url == tab.url }) else { return }
            tabs.append(tab)
            activeTabID = tab.id
            pane.closeTab(id: tab.id)
            focusedSide = .leading
            autoCloseSplitIfEmpty()
        }
    }

    /// Opens a file in the split pane (trailing side), creating split if needed.
    func openInSplit(url: URL) {
        if splitPane == nil {
            splitRight(duplicateActiveTab: false)
        }
        splitPane?.openTab(url: url)
        focusedSide = .trailing
    }

    /// Auto-closes split if the trailing pane has no tabs.
    func autoCloseSplitIfEmpty() {
        guard let pane = splitPane, pane.tabs.isEmpty else { return }
        splitPane = nil
        focusedSide = .leading
    }

    // MARK: - Focused pane routing

    /// The active tab in whichever pane is focused.
    var focusedActiveTab: EditorTab? {
        if isSplitActive && focusedSide == .trailing {
            return splitPane?.activeTab
        }
        return activeTab
    }

    /// Updates content in the focused pane's active tab.
    func updateFocusedContent(_ newContent: String) {
        if isSplitActive && focusedSide == .trailing {
            splitPane?.updateContent(newContent)
        } else {
            updateContent(newContent)
        }
    }

    /// Updates editor state in the focused pane's active tab.
    func updateFocusedEditorState(cursorPosition: Int, scrollOffset: CGFloat) {
        if isSplitActive && focusedSide == .trailing {
            splitPane?.updateEditorState(cursorPosition: cursorPosition, scrollOffset: scrollOffset)
        } else {
            updateEditorState(cursorPosition: cursorPosition, scrollOffset: scrollOffset)
        }
    }

    /// Saves the active tab in the focused pane.
    @discardableResult
    func saveFocusedActiveTab() -> Bool {
        if isSplitActive && focusedSide == .trailing {
            return splitPane?.saveActiveTab() ?? false
        }
        return saveActiveTab()
    }

    /// Closes the active tab in the focused pane.
    /// Returns the tab that was closed, or nil if nothing to close.
    func closeFocusedActiveTab() -> EditorTab? {
        if isSplitActive && focusedSide == .trailing {
            guard let tab = splitPane?.activeTab else { return nil }
            splitPane?.closeTab(id: tab.id)
            autoCloseSplitIfEmpty()
            return tab
        }
        guard let tab = activeTab else { return nil }
        closeTab(id: tab.id)
        return tab
    }

    // MARK: - Aggregate properties (including split pane)

    /// Whether any tab (in either pane) has unsaved changes.
    var hasAnyUnsavedChanges: Bool {
        hasUnsavedChanges || (splitPane?.hasUnsavedChanges ?? false)
    }

    /// All dirty tabs across both panes.
    var allDirtyTabs: [EditorTab] {
        var result = dirtyTabs
        if let pane = splitPane {
            result.append(contentsOf: pane.dirtyTabs)
        }
        return result
    }

    /// Saves all dirty tabs in both panes. Throws on first failure.
    func trySaveAllTabsIncludingSplit() throws {
        try trySaveAllTabs()
        try splitPane?.trySaveAllTabs()
    }

    /// Saves all dirty tabs in both panes. Returns true if all succeeded.
    @discardableResult
    func saveAllTabsIncludingSplit() -> Bool {
        do {
            try trySaveAllTabsIncludingSplit()
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

    /// Handles file rename across both panes.
    func handleFileRenamedIncludingSplit(oldURL: URL, newURL: URL) {
        handleFileRenamed(oldURL: oldURL, newURL: newURL)
        splitPane?.handleFileRenamed(oldURL: oldURL, newURL: newURL)
    }

    /// Closes tabs for deleted file in both panes.
    func closeTabsForDeletedFileIncludingSplit(url: URL) {
        closeTabsForDeletedFile(url: url)
        splitPane?.closeTabsForDeletedFile(url: url)
        autoCloseSplitIfEmpty()
    }

    /// Checks external changes in both panes.
    func checkExternalChangesIncludingSplit() -> [ExternalConflict] {
        var conflicts = checkExternalChanges()
        if let pane = splitPane {
            conflicts.append(contentsOf: pane.checkExternalChanges())
        }
        autoCloseSplitIfEmpty()
        return conflicts
    }

    // togglePreviewMode, checkExternalChanges, reloadTab, modDate
    // are provided by the TabContainer protocol extension.

    /// Describes an external change that requires user action (dirty tab conflict).
    struct ExternalConflict {
        let tabID: UUID
        let url: URL
        let kind: Kind
        enum Kind: Equatable { case modified, deleted }
    }

    // MARK: - Large file detection

    /// Returns the file size in bytes, or nil on error.
    func fileSize(url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return nil }
        return size
    }

    /// Returns true if the file at the given URL is larger than `largeFileThreshold`.
    func isLargeFile(url: URL) -> Bool {
        guard let size = fileSize(url: url) else { return false }
        return size >= Self.largeFileThreshold
    }

    // MARK: - Preview file detection

    /// Determines if a file should be opened as a Quick Look preview
    /// rather than in the text editor.
    ///
    /// Uses a whitelist approach: only known binary types (images, audio,
    /// video, PDF, fonts) get a preview. Everything else opens as text,
    /// which is the expected behavior for a code editor.
    func isPreviewFile(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
            || type.conforms(to: .audiovisualContent)
            || type.conforms(to: .pdf)
            || type.conforms(to: .font)
    }
}
