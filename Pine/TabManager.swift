//
//  TabManager.swift
//  Pine
//
//  Created by Pine Team on 12.03.2026.
//

import os
import SwiftUI
import UniformTypeIdentifiers

/// Manages the set of open editor tabs and the active selection.
@MainActor
@Observable
final class TabManager {
    private static let logger = Logger.editor

    /// Maximum number of simultaneously open tabs. Prevents unbounded memory growth.
    nonisolated static let maxTabs = 1_000

    /// File size threshold (in bytes) above which a warning is shown before opening.
    nonisolated static let largeFileThreshold = FileSizeConstants.oneMB

    /// File size threshold (in bytes) above which only a partial load is performed.
    nonisolated static let hugeFileThreshold = FileSizeConstants.tenMB

    /// Number of bytes to load from the beginning of a huge file.
    nonisolated static let hugeFilePartialLoadSize = FileSizeConstants.oneMB

    var tabs: [EditorTab] = []
    var activeTabID: UUID? {
        didSet {
            if activeTabID != oldValue { onEditorContextChanged?() }
        }
    }
    /// Line number to scroll to after opening a tab (1-based). Consumed by the editor view.
    var pendingGoToLine: Int?
    /// Recovery manager for crash recovery snapshots.
    var recoveryManager: RecoveryManager?

    /// Called when active tab or cursor position changes. Set by ProjectManager.
    var onEditorContextChanged: (() -> Void)?

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

        if isPreviewFile(url: url) {
            var tab = EditorTab(url: url, kind: .preview)
            tab.lastModDate = modDate(for: url)
            tabs.append(tab)
            activeTabID = tab.id
            return
        }

        // Huge file: partial load without prompt
        if let size = fileSize(url: url), size >= Self.hugeFileThreshold {
            openHugeFilePartial(url: url, totalSize: size)
            return
        }

        // Large file warning
        if let size = fileSize(url: url), size >= Self.largeFileThreshold {
            let sizeMB = Double(size) / Double(FileSizeConstants.oneMB)
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

        // Huge file: partial load even during session restore
        if let size = fileSize(url: url), size >= Self.hugeFileThreshold {
            openHugeFilePartial(url: url, totalSize: size)
            return
        }

        openTabInternal(url: url, syntaxHighlightingDisabled: syntaxHighlightingDisabled)
    }

    /// Internal method to create and append a text tab.
    private func openTabInternal(url: URL, syntaxHighlightingDisabled: Bool) {
        let content: String
        let encoding: String.Encoding
        do {
            let data = try Data(contentsOf: url)
            (content, encoding) = String.Encoding.detect(from: data)
        } catch {
            content = "// Error: \(error.localizedDescription)"
            encoding = .utf8
        }

        var tab = EditorTab(url: url, content: content, savedContent: content)
        tab.lastModDate = modDate(for: url)
        tab.syntaxHighlightingDisabled = syntaxHighlightingDisabled
        tab.encoding = encoding
        tab.fileSizeBytes = fileSize(url: url)
        tab.recomputeContentCaches()
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// Opens a huge file by loading only the first `hugeFilePartialLoadSize` bytes.
    /// Marks the tab as truncated and disables syntax highlighting.
    private func openHugeFilePartial(url: URL, totalSize: Int) {
        let content: String
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { handle.closeFile() }
            let partialData = handle.readData(ofLength: Self.hugeFilePartialLoadSize)
            let (decoded, _) = String.Encoding.detect(from: partialData)
            let sizeString = ByteCountFormatter.string(
                fromByteCount: Int64(totalSize), countStyle: .file
            )
            content = decoded + Strings.fileTruncatedNotice(sizeString)
        } catch {
            content = "// Error: \(error.localizedDescription)"
        }

        var tab = EditorTab(url: url, content: content, savedContent: content)
        tab.lastModDate = modDate(for: url)
        tab.syntaxHighlightingDisabled = true
        tab.isTruncated = true
        tab.fileSizeBytes = totalSize
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

    /// Closes a tab by ID. Pinned tabs are skipped unless `force` is true.
    /// Selects an adjacent tab if the closed tab was active.
    /// Cancels any pending auto-save for the closed tab.
    func closeTab(id: UUID, force: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        // Pinned tabs resist close unless forced (e.g., explicit unpin + close)
        if tabs[index].isPinned && !force {
            return
        }

        cancelAutoSave()
        recoveryManager?.deleteRecoveryFile(for: id)

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

    /// Whether auto-save is enabled. Bound to UserDefaults by the view layer.
    var isAutoSaveEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoSaveKey)
    }

    /// Updates the content of the active tab (text tabs only).
    /// Also eagerly recomputes indentation/line-ending caches so reads are mutation-free.
    /// When auto-save is enabled, schedules a debounced save.
    func updateContent(_ newContent: String) {
        guard let index = activeTabIndex else { return }
        guard tabs[index].kind == .text else { return }
        tabs[index].content = newContent
        tabs[index].cachedHighlightResult = nil  // Invalidate stale highlight cache
        tabs[index].recomputeContentCaches()

        if isAutoSaveEnabled {
            scheduleAutoSave()
        }

        recoveryManager?.scheduleSnapshot()
    }

    /// Updates the saved editor state (cursor, scroll) for the active tab.
    func updateEditorState(cursorPosition: Int, scrollOffset: CGFloat) {
        guard let index = activeTabIndex else { return }
        tabs[index].cursorPosition = cursorPosition
        tabs[index].scrollOffset = scrollOffset
        let loc = CursorLocation(position: cursorPosition, in: tabs[index].content)
        tabs[index].cursorLine = loc.line
        tabs[index].cursorColumn = loc.column
        onEditorContextChanged?()
    }

    /// Converts the active tab's line endings to the specified style.
    /// Marks the tab as dirty if content actually changed.
    func convertActiveTabLineEndings(to target: LineEnding) {
        guard let index = activeTabIndex else { return }
        guard tabs[index].kind == .text else { return }
        let converted = target.convert(tabs[index].content)
        guard converted != tabs[index].content else { return }
        tabs[index].content = converted
        tabs[index].cachedHighlightResult = nil
        tabs[index].recomputeContentCaches()

        if isAutoSaveEnabled {
            scheduleAutoSave()
        }
        recoveryManager?.scheduleSnapshot()
    }

    /// Updates the fold state for the active tab.
    func updateFoldState(_ state: FoldState) {
        guard let index = activeTabIndex else { return }
        tabs[index].foldState = state
    }

    /// Updates the cached syntax highlight result for the active tab.
    /// Used to apply highlights synchronously on tab switch, eliminating flash.
    func updateHighlightCache(_ result: HighlightMatchResult) {
        guard let index = activeTabIndex else { return }
        tabs[index].cachedHighlightResult = result
    }

    /// Saves the active tab to disk. Returns true on success.
    /// Cancels any pending auto-save since the user saved manually.
    @discardableResult
    func saveActiveTab() -> Bool {
        guard let index = activeTabIndex else { return false }
        cancelAutoSave()
        return saveTab(at: index)
    }

    /// Writes tab content to disk without UI. Returns true on success.
    /// On failure, throws — callers decide how to present the error.
    @discardableResult
    func trySaveTab(at index: Int) throws -> Bool {
        assert(tabs.indices.contains(index), "trySaveTab called with out-of-bounds index \(index), tabs.count = \(tabs.count)")
        let tab = tabs[index]
        guard tab.kind == .text else { return false }
        // Prevent saving truncated files — writing partial content would corrupt the file.
        if tab.isTruncated {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Cannot save: file was partially loaded (truncated). Saving would corrupt the original file."
            ])
        }
        let trimmed = tab.content.trailingWhitespaceStripped()
        try trimmed.write(to: tab.url, atomically: true, encoding: tab.encoding)
        tabs[index].content = trimmed
        tabs[index].savedContent = trimmed
        tabs[index].lastModDate = modDate(for: tab.url)
        tabs[index].fileSizeBytes = fileSize(url: tab.url)
        recoveryManager?.deleteRecoveryFile(for: tab.id)
        return true
    }

    /// Saves a specific tab by index. Returns true on success, shows alert on failure.
    @discardableResult
    func saveTab(at index: Int) -> Bool {
        assert(tabs.indices.contains(index), "saveTab called with out-of-bounds index \(index), tabs.count = \(tabs.count)")
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

    /// Reorders a tab by moving the dragged tab to the target tab's position.
    /// Pinned tabs can only reorder within the pinned group; unpinned within unpinned.
    /// Used by `TabDropDelegate` during drag-and-drop reordering.
    func reorderTab(draggedID: UUID, targetID: UUID) {
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

    // MARK: - Pin tabs

    /// Toggles the pinned state of a tab. Pinned tabs are moved to the left;
    /// unpinned tabs are moved to the right of the pinned group.
    func togglePin(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPinned.toggle()

        if tabs[index].isPinned {
            // Move to the end of the pinned group
            let pinnedCount = tabs.prefix(index).filter(\.isPinned).count
            if index != pinnedCount {
                let tab = tabs.remove(at: index)
                tabs.insert(tab, at: pinnedCount)
            }
        } else {
            // Move to the start of the unpinned group (right after last pinned tab)
            let pinnedCount = tabs.filter(\.isPinned).count
            if index != pinnedCount {
                let tab = tabs.remove(at: index)
                tabs.insert(tab, at: pinnedCount)
            }
        }
    }

    /// Number of currently pinned tabs.
    var pinnedTabCount: Int {
        tabs.filter(\.isPinned).count
    }

    /// Restores pinned state for tabs matching the given file paths.
    /// Called during session restoration.
    func restorePinnedState(pinnedPaths: Set<String>) {
        for index in tabs.indices where pinnedPaths.contains(tabs[index].url.path) {
            tabs[index].isPinned = true
        }
        // Re-sort: pinned tabs first, preserving relative order within each group
        let pinned = tabs.filter(\.isPinned)
        let unpinned = tabs.filter { !$0.isPinned }
        tabs = pinned + unpinned
    }

    // MARK: - Context menu actions

    /// Closes all tabs except the one with the given ID.
    /// Pinned tabs are preserved unless they are the target tab.
    func closeOtherTabs(keeping tabID: UUID) {
        cancelAutoSave()
        let idsToClose = tabs.filter { $0.id != tabID && !$0.isPinned }.map(\.id)
        for id in idsToClose {
            closeTab(id: id, force: true)
        }
        activeTabID = tabID
    }

    /// Closes all tabs to the right of the tab with the given ID.
    /// Pinned tabs are not closed.
    func closeTabsToTheRight(of tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        cancelAutoSave()
        let rightTabs = tabs[(index + 1)...].filter { !$0.isPinned }
        for tab in rightTabs.reversed() {
            closeTab(id: tab.id, force: true)
        }
    }

    /// Closes all tabs. Pinned tabs are force-closed.
    func closeAllTabs() {
        cancelAutoSave()
        let allIDs = tabs.map(\.id)
        for id in allIDs {
            closeTab(id: id, force: true)
        }
    }

    // MARK: - Keyboard tab navigation

    /// Selects the tab at the given 0-based index. No-op if out of bounds.
    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabID = tabs[index].id
    }

    /// Selects the last tab. Used by Cmd+9 (like Safari/Chrome).
    func selectLastTab() {
        guard let last = tabs.last else { return }
        activeTabID = last.id
    }

    /// Selects the next tab, wrapping around to the first. Used by Ctrl+Tab.
    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        guard let currentIndex = activeTabIndex else {
            activeTabID = tabs[0].id
            return
        }
        let nextIndex = (currentIndex + 1) % tabs.count
        activeTabID = tabs[nextIndex].id
    }

    /// Selects the previous tab, wrapping around to the last. Used by Ctrl+Shift+Tab.
    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        guard let currentIndex = activeTabIndex else {
            activeTabID = tabs[tabs.count - 1].id
            return
        }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
        activeTabID = tabs[prevIndex].id
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
    /// Cancels any pending auto-save.
    func trySaveAllTabs() throws {
        cancelAutoSave()
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
        let trimmed = tab.content.trailingWhitespaceStripped()
        try trimmed.write(to: newURL, atomically: true, encoding: tab.encoding)
        tabs[index].content = trimmed
        tabs[index].url = newURL
        tabs[index].savedContent = trimmed
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

        let trimmed = tab.content.trailingWhitespaceStripped()
        try trimmed.write(to: duplicateURL, atomically: true, encoding: tab.encoding)

        var newTab = EditorTab(
            url: duplicateURL,
            content: trimmed,
            savedContent: trimmed
        )
        newTab.lastModDate = modDate(for: duplicateURL)
        newTab.encoding = tab.encoding
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
        FileNameGenerator.finderCopyURL(for: url)
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

    // MARK: - Auto-save

    /// UserDefaults key for the auto-save toggle.
    nonisolated static let autoSaveKey = "autoSaveEnabled"

    /// Whether auto-save is currently in progress (for UI indicator).
    private(set) var isAutoSaving = false

    /// Auto-save delay in seconds. Use `setAutoSaveDelay(_:)` in tests.
    private(set) var autoSaveDelay: TimeInterval = 1.0

    /// Debounce work item for auto-save.
    private var autoSaveWorkItem: DispatchWorkItem?

    /// Sets the auto-save delay. Intended for tests only.
    func setAutoSaveDelay(_ delay: TimeInterval) {
        autoSaveDelay = delay
    }

    /// Schedules a debounced auto-save for the active tab.
    /// The save fires after `autoSaveDelay` seconds of inactivity.
    ///
    /// Note: `checkExternalChanges()` may detect the file we just wrote
    /// and silently reload it. This is harmless — the content matches.
    func scheduleAutoSave() {
        autoSaveWorkItem?.cancel()

        guard let index = activeTabIndex else { return }
        let tabID = tabs[index].id
        let url = tabs[index].url

        // Skip read-only files
        guard FileManager.default.isWritableFile(atPath: url.path) else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let idx = self.tabs.firstIndex(where: { $0.id == tabID }),
                  self.tabs[idx].isDirty else { return }

            self.isAutoSaving = true
            do {
                try self.trySaveTab(at: idx)
            } catch {
                // Silent failure — auto-save should not show alerts
            }
            self.isAutoSaving = false
        }

        autoSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoSaveDelay, execute: workItem)
    }

    /// Cancels any pending auto-save.
    func cancelAutoSave() {
        autoSaveWorkItem?.cancel()
        autoSaveWorkItem = nil
    }

    /// Whether a pending auto-save is scheduled (for testing).
    var hasScheduledAutoSave: Bool {
        autoSaveWorkItem != nil
    }

    // MARK: - Markdown preview

    /// Cycles the preview mode for the active tab if it's a Markdown file.
    func togglePreviewMode() {
        guard let index = activeTabIndex, tabs[index].isMarkdownFile else { return }
        tabs[index].previewMode = tabs[index].previewMode.next
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

            if tab.kind == .preview {
                tabs[index].lastModDate = diskMod
            } else if tab.isDirty {
                conflicts.append(.init(tabID: tab.id, url: tab.url, kind: .modified))
                tabs[index].lastModDate = diskMod
            } else {
                // Safe to reload silently
                do {
                    let content = try String(contentsOf: tab.url, encoding: tab.encoding)
                    tabs[index].content = content
                    tabs[index].savedContent = content
                    tabs[index].lastModDate = diskMod
                } catch {
                    Self.logger.error("Failed to reload tab \(tab.url.lastPathComponent): \(error)")
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
        do {
            let content = try String(contentsOf: url, encoding: tabs[index].encoding)
            tabs[index].content = content
            tabs[index].savedContent = content
            tabs[index].lastModDate = modDate(for: url)
        } catch {
            Self.logger.error("Failed to reload tab from disk \(url.lastPathComponent): \(error)")
        }
    }

    /// Reopens the active tab with a different encoding.
    /// Re-reads the file from disk using the specified encoding.
    /// Refuses to reopen if the tab has unsaved changes (returns false).
    @discardableResult
    func reopenActiveTab(withEncoding encoding: String.Encoding) -> Bool {
        guard let index = activeTabIndex else { return false }
        let tab = tabs[index]
        guard !tab.isDirty else { return false }
        let data: Data
        do {
            data = try Data(contentsOf: tab.url)
        } catch {
            Self.logger.error("Failed to read file for encoding change \(tab.url.lastPathComponent): \(error)")
            return false
        }
        guard let content = String(data: data, encoding: encoding) else { return false }
        tabs[index].content = content
        tabs[index].savedContent = content
        tabs[index].encoding = encoding
        tabs[index].lastModDate = modDate(for: tab.url)
        return true
    }

    /// Returns the modification date of a file, or nil on error.
    private func modDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
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
