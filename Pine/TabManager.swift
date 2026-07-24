//
//  TabManager.swift
//  Pine
//
//  Created by Pine Team on 12.03.2026.
//

import os
import SwiftUI

/// Manages the set of open editor tabs and the active selection.
///
/// Thin facade that delegates to focused helpers in `Pine/Tabs/`:
/// - ``TabPersistence`` — file I/O, encoding, large-file handling
/// - ``TabCollection`` — pure array operations, lookup, reorder
/// - ``TabFormatter`` — save-time content transformations
/// - ``TabAutoSave`` — debounced auto-save scheduling
/// - ``TabPinning`` — pin/unpin and pin-state restoration
/// - ``TabDuplicator`` — Finder-style tab duplication
/// - ``TabExternalChangeDetector`` — external file change detection and reload
@MainActor
@Observable
final class TabManager {
    private static let logger = Logger.editor

    nonisolated static let maxTabs = 1_000
    static let largeFileThreshold = TabPersistence.largeFileThreshold
    static let hugeFileThreshold = TabPersistence.hugeFileThreshold
    static let hugeFilePartialLoadSize = TabPersistence.hugeFilePartialLoadSize

    var tabs: [EditorTab] = []
    var activeTabID: UUID? {
        didSet {
            guard activeTabID != oldValue else { return }
            if pendingFocusTabID != activeTabID {
                pendingFocusTabID = nil
            }
            onEditorContextChanged?()
        }
    }
    /// Set when destination content should explicitly become first responder.
    /// It remains pending until the bounded AppKit request finishes.
    var pendingFocusTabID: UUID? {
        didSet {
            pendingFocusRequestID = pendingFocusTabID.map { _ in UUID() }
        }
    }
    /// Unique generation for the current request. A repeated request for the
    /// same tab receives a fresh identity, so a queued completion from an
    /// earlier drag cannot consume it.
    private(set) var pendingFocusRequestID: UUID?
    var pendingGoToLine: Int?
    var recoveryManager: RecoveryManager?
    var onEditorContextChanged: (() -> Void)?
    var editorSettings: EditorSettings = .shared
    var fileFormatters: FileFormatterRegistry = .default

    // MARK: - Computed

    static func contentPreparedForSave(
        _ content: String, url: URL, settings: EditorSettings, formatters: FileFormatterRegistry
    ) -> String {
        TabFormatter.contentPreparedForSave(content, url: url, settings: settings, formatters: formatters)
    }

    var activeTab: EditorTab? {
        guard let id = activeTabID else { return nil }
        return TabCollection.tab(for: id, in: tabs)
    }

    private var activeTabIndex: Int? {
        guard let id = activeTabID else { return nil }
        return TabCollection.index(of: id, in: tabs)
    }

    var hasUnsavedChanges: Bool { TabCollection.hasUnsavedChanges(in: tabs) }
    var dirtyTabs: [EditorTab] { TabCollection.dirtyTabs(in: tabs) }
    var isAutoSaveEnabled: Bool { UserDefaults.standard.bool(forKey: Self.autoSaveKey) }
    var pinnedTabCount: Int { TabPinning.pinnedTabCount(in: tabs) }

    /// Consumes the terminal result of a bounded AppKit focus request.
    ///
    /// Retryable lifecycle states are retained inside
    /// `AppKitFocusRequestCoordinator` and do not call this method. A `false`
    /// result therefore means the request was cancelled or exhausted.
    @discardableResult
    func acknowledgeFocusRequest(
        requestID: UUID,
        for tabID: UUID,
        succeeded: Bool
    ) -> Bool {
        guard pendingFocusTabID == tabID else { return false }
        guard pendingFocusRequestID == requestID else { return false }
        guard activeTabID == tabID else {
            pendingFocusTabID = nil
            return false
        }
        pendingFocusTabID = nil
        return succeeded
    }

    /// A tab temporarily detached from this manager while it is transferred
    /// to another editor pane. The original position and selection make a
    /// failed transfer exactly reversible without invoking close/discard
    /// cleanup (in particular, recovery files remain intact).
    struct ExtractedTab {
        let tab: EditorTab
        fileprivate let originalIndex: Int
        fileprivate let previousActiveTabID: UUID?
        fileprivate let shouldResumeAutoSave: Bool
    }

    // MARK: - Open

    func openTab(url: URL) {
        applyOpenDecision(TabPersistence.resolveOpen(url: url, existingTabs: tabs, syntaxHighlightingDisabled: nil))
    }

    func openTabAndGoToLine(url: URL, line: Int) {
        openTab(url: url)
        pendingGoToLine = line
    }

    func openTab(url: URL, syntaxHighlightingDisabled: Bool) {
        applyOpenDecision(TabPersistence.resolveOpen(url: url, existingTabs: tabs, syntaxHighlightingDisabled: syntaxHighlightingDisabled))
    }

    private func applyOpenDecision(_ decision: TabPersistence.OpenDecision) {
        switch decision {
        case .activateExisting(let id): activeTabID = id
        case .openNew(let tab): tabs.append(tab); activeTabID = tab.id
        case .cancel: break
        }
    }

    // MARK: - Transient preview tabs

    /// Opens a file as a transient preview. If the currently active tab is an
    /// un-promoted transient preview, it is replaced in place instead of
    /// stacking a second preview — so a pane holds at most one transient
    /// preview at a time. If the same file is already open as a permanent
    /// tab, it is simply activated without creating a preview.
    ///
    /// Promotion triggers (defined in ``promoteTransientPreview``) upgrade a
    /// transient preview to a permanent tab.
    func openTabAsPreview(url: URL) {
        // If the file is already open as a permanent tab, just activate it.
        if let existing = tabs.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
           !existing.isTransientPreview {
            activeTabID = existing.id
            return
        }

        let decision = TabPersistence.resolveOpen(url: url, existingTabs: tabs, syntaxHighlightingDisabled: nil)
        switch decision {
        case .activateExisting(let id):
            activeTabID = id
        case .cancel:
            break
        case .openNew(var tab):
            tab.isTransientPreview = true
            // Replace the active un-promoted transient preview in place.
            if let activeID = activeTabID,
               let activeIndex = tabs.firstIndex(where: { $0.id == activeID }),
               tabs[activeIndex].isTransientPreview {
                tabs[activeIndex] = tab
            } else {
                tabs.append(tab)
            }
            activeTabID = tab.id
        }
    }

    /// Promotes a transient preview tab to a permanent tab by clearing the
    /// transient flag. This is the single transition point; every promotion
    /// trigger funnels through here so the rules are centralized and testable.
    ///
    /// Promotion triggers:
    ///   - **edit**: `updateContent` promotes the active tab.
    ///   - **pin**: `togglePin` promotes the pinned tab.
    ///   - **explicit open**: a double-click or menu "Open" promotes the tab.
    ///   - **move**: `extractTab` promotes the moved tab before transfer.
    func promoteTransientPreview(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isTransientPreview = false
    }

    /// Convenience: promotes the active tab if it is a transient preview.
    func promoteActiveTransientPreview() {
        guard let activeID = activeTabID else { return }
        promoteTransientPreview(tabID: activeID)
    }

    typealias LargeFileAlertResult = TabPersistence.LargeFileAlertResult

    // MARK: - Close

    func closeTab(id: UUID, force: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].isPinned && !force { return }
        cancelAutoSave(for: id)
        recoveryManager?.deleteRecoveryFile(for: id)
        let wasActive = activeTabID == id
        tabs.remove(at: index)
        if wasActive {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func dirtyTabsForCloseOthers(keeping tabID: UUID) -> [EditorTab] {
        TabCollection.dirtyTabsForCloseOthers(keeping: tabID, in: tabs)
    }

    func closeOtherTabs(keeping tabID: UUID, force: Bool) {
        tabs.filter { $0.id != tabID && !$0.isPinned && (force || !$0.isDirty) }
            .map(\.id).forEach { closeTab(id: $0, force: true) }
        activeTabID = tabID
    }

    func dirtyTabsForCloseRight(of tabID: UUID) -> [EditorTab] {
        TabCollection.dirtyTabsForCloseRight(of: tabID, in: tabs)
    }

    func closeTabsToTheRight(of tabID: UUID, force: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[(index + 1)...].filter { !$0.isPinned && (force || !$0.isDirty) }
            .reversed().forEach { closeTab(id: $0.id, force: true) }
    }

    func dirtyTabsForCloseAll() -> [EditorTab] { TabCollection.dirtyTabsForCloseAll(in: tabs) }

    func closeAllTabs(force: Bool) {
        tabs.filter { force || !$0.isDirty }.map(\.id).forEach { closeTab(id: $0, force: true) }
    }

    // MARK: - Content updates

    func updateContent(_ newContent: String) {
        guard let index = activeTabIndex, tabs[index].kind == .text else { return }
        // Promotion trigger: edit. Any content change promotes a transient
        // preview to a permanent tab.
        if tabs[index].isTransientPreview {
            tabs[index].isTransientPreview = false
        }
        tabs[index].content = newContent
        tabs[index].cachedHighlightResult = nil
        tabs[index].recomputeContentCaches()
        if isAutoSaveEnabled { scheduleAutoSave() }
        recoveryManager?.scheduleSnapshot()
    }

    func updateEditorState(cursorPosition: Int, scrollOffset: CGFloat) {
        guard let index = activeTabIndex else { return }
        tabs[index].cursorPosition = cursorPosition
        tabs[index].scrollOffset = scrollOffset
        let loc = CursorLocation(position: cursorPosition, in: tabs[index].content)
        tabs[index].cursorLine = loc.line
        tabs[index].cursorColumn = loc.column
        onEditorContextChanged?()
    }

    func convertActiveTabLineEndings(to target: LineEnding) {
        guard let index = activeTabIndex, tabs[index].kind == .text else { return }
        let converted = target.convert(tabs[index].content)
        guard converted != tabs[index].content else { return }
        tabs[index].content = converted
        tabs[index].cachedHighlightResult = nil
        tabs[index].recomputeContentCaches()
        if isAutoSaveEnabled { scheduleAutoSave() }
        recoveryManager?.scheduleSnapshot()
    }

    func updateFoldState(_ state: FoldState) {
        guard let index = activeTabIndex else { return }
        tabs[index].foldState = state
    }

    func updateHighlightCache(_ result: HighlightMatchResult) {
        guard let index = activeTabIndex else { return }
        tabs[index].cachedHighlightResult = result
    }

    // MARK: - Save

    @discardableResult
    func saveActiveTab() -> Bool {
        guard let index = activeTabIndex else { return false }
        cancelAutoSave(for: tabs[index].id)
        return saveTab(at: index)
    }

    @discardableResult
    func trySaveTab(at index: Int) throws -> Bool {
        assert(tabs.indices.contains(index), "trySaveTab: index \(index) out of bounds, count \(tabs.count)")
        let tabID = tabs[index].id
        let outcome = try TabPersistence.saveTabContent(
            at: index, tabs: &tabs,
            config: .init(editorSettings: editorSettings, formatters: fileFormatters),
            providers: .init(
                modDate: { [weak self] url in self?.modDate(for: url) },
                fileSize: { [weak self] url in self?.fileSize(url: url) }
            )
        )
        if outcome.saved { recoveryManager?.deleteRecoveryFile(for: tabID) }
        // Post AFTER saveTabContent returns so its `inout tabs` exclusive
        // access has ended. The synchronous .tabReloadedFromDisk observer
        // re-enters TabManager.tabs via updateHighlightCache; posting under
        // the live inout was a Swift runtime exclusivity abort (#1066).
        if let reload = outcome.reload {
            NotificationCenter.default.post(
                name: .tabReloadedFromDisk,
                object: nil,
                userInfo: ["url": reload.url, "text": reload.text]
            )
        }
        return outcome.saved
    }

    @discardableResult
    func saveTab(at index: Int) -> Bool {
        assert(tabs.indices.contains(index), "saveTab: index \(index) out of bounds, count \(tabs.count)")
        do {
            return try trySaveTab(at: index)
        } catch {
            AlertTemplate.fileOperationErrorCritical.runModal(
                messageText: Strings.fileOperationErrorTitle, informativeText: error.localizedDescription
            )
            return false
        }
    }

    func trySaveAllTabs() throws {
        cancelAutoSave()
        for index in tabs.indices where tabs[index].isDirty { try trySaveTab(at: index) }
    }

    @discardableResult
    func saveAllTabs() -> Bool {
        do { try trySaveAllTabs(); return true } catch {
            AlertTemplate.fileOperationErrorCritical.runModal(
                messageText: Strings.fileOperationErrorTitle, informativeText: error.localizedDescription
            )
            return false
        }
    }

    @discardableResult
    func saveActiveTabAs(to newURL: URL) throws -> Bool {
        guard let index = activeTabIndex else { return false }
        let outcome = try TabPersistence.saveTabAs(
            at: index, tabs: &tabs, newURL: newURL,
            config: .init(editorSettings: editorSettings, formatters: fileFormatters),
            providers: .init(
                modDate: { [weak self] url in self?.modDate(for: url) },
                fileSize: { _ in nil }
            )
        )
        // Same reentrancy rationale as trySaveTab (#1066): post after the
        // saveTabAs `inout tabs` scope ends, not inside it.
        if let reload = outcome.reload {
            NotificationCenter.default.post(
                name: .tabReloadedFromDisk,
                object: nil,
                userInfo: ["url": reload.url, "text": reload.text]
            )
        }
        return outcome.saved
    }

    // MARK: - Reorder & Pin

    /// Removes a tab for an in-window pane transfer.
    ///
    /// Unlike ``closeTab(id:force:)``, extraction does not delete recovery
    /// data or otherwise treat the tab as discarded. Callers must either
    /// insert the returned value into another manager or restore it here.
    func extractTab(id: UUID) -> ExtractedTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }

        let previousActiveTabID = activeTabID
        let shouldResumeAutoSave = hasScheduledAutoSave(for: id)
        if shouldResumeAutoSave {
            cancelAutoSave(for: id)
        }

        // Promotion trigger: move. A transient preview that is dragged or
        // transferred to another pane is promoted to a permanent tab before
        // it leaves this manager.
        var tab = tabs.remove(at: index)
        tab.isTransientPreview = false
        if activeTabID == id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }

        return ExtractedTab(
            tab: tab,
            originalIndex: index,
            previousActiveTabID: previousActiveTabID,
            shouldResumeAutoSave: shouldResumeAutoSave
        )
    }

    /// Whether this manager can accept the exact tab from another pane.
    /// Duplicate identities and file URLs are rejected so each pane keeps
    /// the same one-file/one-tab invariant as ``openTab(url:)``.
    func canInsertTransferredTab(_ tab: EditorTab) -> Bool {
        canInsertTransferredTab(tab, at: tab.isPinned ? pinnedTabCount : tabs.count)
    }

    /// Validates an exact destination gap without changing either manager.
    /// Pinned tabs may only enter the pinned prefix; regular tabs may only
    /// enter at or after the shared pinned/unpinned boundary.
    func canInsertTransferredTab(_ tab: EditorTab, at insertionIndex: Int) -> Bool {
        guard (0...tabs.count).contains(insertionIndex) else { return false }
        let respectsPinnedBoundary = tab.isPinned
            ? insertionIndex <= pinnedTabCount
            : insertionIndex >= pinnedTabCount
        guard respectsPinnedBoundary else { return false }
        return !tabs.contains { existing in
            existing.id == tab.id
                || existing.url.standardizedFileURL == tab.url.standardizedFileURL
        }
    }

    /// Inserts a transferred tab and activates it. Pinned tabs join the end
    /// of the pinned prefix; regular tabs are appended after that prefix.
    @discardableResult
    func insertTransferredTab(_ tab: EditorTab) -> Bool {
        let insertionIndex = tab.isPinned ? pinnedTabCount : tabs.count
        return insertTransferredTab(tab, at: insertionIndex)
    }

    /// Inserts at an exact N+1 gap and activates/focuses the transferred tab.
    @discardableResult
    func insertTransferredTab(_ tab: EditorTab, at insertionIndex: Int) -> Bool {
        guard canInsertTransferredTab(tab, at: insertionIndex) else { return false }
        tabs.insert(tab, at: insertionIndex)
        activeTabID = tab.id
        pendingFocusTabID = tab.id
        return true
    }

    /// Inserts a detached tab and resumes any auto-save that was pending in
    /// its source manager. The destination owns the timer after the move, so
    /// the callback resolves the tab in the manager that now contains it.
    @discardableResult
    func insertTransferredTab(_ extraction: ExtractedTab) -> Bool {
        let insertionIndex = extraction.tab.isPinned ? pinnedTabCount : tabs.count
        return insertTransferredTab(extraction, at: insertionIndex)
    }

    /// Indexed counterpart used by cross-pane strip drops.
    @discardableResult
    func insertTransferredTab(_ extraction: ExtractedTab, at insertionIndex: Int) -> Bool {
        guard insertTransferredTab(extraction.tab, at: insertionIndex) else { return false }
        if extraction.shouldResumeAutoSave {
            scheduleAutoSave(for: extraction.tab.id)
        }
        return true
    }

    /// Restores a failed extraction at its exact previous position and
    /// selection. This is intentionally separate from normal insertion,
    /// whose pinned-prefix policy is destination-oriented.
    func restoreExtractedTab(_ extraction: ExtractedTab) {
        guard !tabs.contains(where: { $0.id == extraction.tab.id }) else { return }
        let index = min(extraction.originalIndex, tabs.count)
        tabs.insert(extraction.tab, at: index)
        activeTabID = extraction.previousActiveTabID
        if extraction.shouldResumeAutoSave {
            scheduleAutoSave(for: extraction.tab.id)
        }
    }

    func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    func reorderTab(draggedID: UUID, targetID: UUID) {
        TabCollection.reorderTab(draggedID: draggedID, targetID: targetID, in: &tabs)
    }

    /// Moves a tab to one of the strip's N+1 pre-removal gaps.
    ///
    /// Gaps immediately before and after the dragged tab are both no-ops.
    /// Invalid indices and pinned-boundary crossings are rejected.
    func canMoveTab(id: UUID, toInsertionIndex insertionIndex: Int) -> TabInsertionResult {
        guard (0...tabs.count).contains(insertionIndex),
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else {
            return .rejected
        }

        let tab = tabs[sourceIndex]
        let respectsPinnedBoundary = tab.isPinned
            ? insertionIndex <= pinnedTabCount
            : insertionIndex >= pinnedTabCount
        guard respectsPinnedBoundary else { return .rejected }

        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        return destinationIndex == sourceIndex ? .noOp : .moved
    }

    @discardableResult
    func moveTab(id: UUID, toInsertionIndex insertionIndex: Int) -> TabInsertionResult {
        let validation = canMoveTab(id: id, toInsertionIndex: insertionIndex)
        guard validation != .rejected,
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else {
            return .rejected
        }
        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        guard validation == .moved else {
            activeTabID = id
            pendingFocusTabID = id
            return .noOp
        }

        let movedTab = tabs.remove(at: sourceIndex)
        tabs.insert(movedTab, at: destinationIndex)
        activeTabID = id
        pendingFocusTabID = id
        return .moved
    }

    func togglePin(id: UUID) {
        TabPinning.togglePin(id: id, in: &tabs)
        // Promotion trigger: pin. Pinning a transient preview promotes it.
        // Called after the `inout` scope of `TabPinning.togglePin` has ended
        // so no exclusivity conflict arises.
        promoteTransientPreview(tabID: id)
    }

    func restorePinnedState(pinnedPaths: Set<String>) {
        TabPinning.restorePinnedState(pinnedPaths: pinnedPaths, in: &tabs)
    }

    // MARK: - Navigation

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabID = tabs[index].id
    }

    func selectLastTab() { if let last = tabs.last { activeTabID = last.id } }

    func selectNextTab() {
        guard let next = TabCollection.nextTabIndex(current: activeTabIndex, count: tabs.count),
              tabs.indices.contains(next) else { return }
        activeTabID = tabs[next].id
    }

    func selectPreviousTab() {
        guard let prev = TabCollection.previousTabIndex(current: activeTabIndex, count: tabs.count),
              tabs.indices.contains(prev) else { return }
        activeTabID = tabs[prev].id
    }

    // MARK: - Duplicate

    @discardableResult
    func tryDuplicateActiveTab(projectRoot: URL? = nil) throws -> Bool {
        guard let index = activeTabIndex else { return false }
        let newID = try TabDuplicator.duplicateTab(
            atIndex: index, in: &tabs,
            editorSettings: editorSettings, fileFormatters: fileFormatters,
            projectRoot: projectRoot
        )
        if let newID { activeTabID = newID }
        return newID != nil
    }

    @discardableResult
    func duplicateActiveTab(projectRoot: URL? = nil) -> Bool {
        do { return try tryDuplicateActiveTab(projectRoot: projectRoot) } catch {
            AlertTemplate.fileOperationErrorCritical.runModal(
                messageText: Strings.fileOperationErrorTitle, informativeText: error.localizedDescription
            )
            return false
        }
    }

    // MARK: - Lookup

    func tab(for url: URL) -> EditorTab? { TabCollection.tab(for: url, in: tabs) }

    func handleFileRenamed(oldURL: URL, newURL: URL) {
        TabCollection.handleFileRenamed(oldURL: oldURL, newURL: newURL, in: &tabs)
    }

    func tabsAffectedByDeletion(url: URL) -> [EditorTab] {
        TabCollection.tabsAffectedByDeletion(url: url, in: tabs)
    }

    func closeTabsForDeletedFile(url: URL) {
        tabs.filter { $0.url == url || $0.url.path.hasPrefix(url.path + "/") }
            .forEach { closeTab(id: $0.id) }
    }

    // MARK: - Auto-save

    private let autoSaveCoordinator = TabAutoSave()
    nonisolated static let autoSaveKey = TabAutoSave.autoSaveKey
    var isAutoSaving: Bool { autoSaveCoordinator.isSaving }
    var autoSaveDelay: TimeInterval { autoSaveCoordinator.delay }

    func setAutoSaveDelay(_ delay: TimeInterval) { autoSaveCoordinator.delay = delay }

    func scheduleAutoSave() {
        guard let tabID = activeTabID else { return }
        scheduleAutoSave(for: tabID)
    }

    private func scheduleAutoSave(for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              FileManager.default.isWritableFile(atPath: tabs[index].url.path) else { return }
        autoSaveCoordinator.schedule(
            for: tabID,
            isStillDirty: { [weak self] in
                guard let self, let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else { return false }
                return self.tabs[idx].isDirty
            },
            saveAction: { [weak self] in
                guard let self, let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                try self.trySaveTab(at: idx)
            }
        )
    }

    func cancelAutoSave() { autoSaveCoordinator.cancel() }
    private func cancelAutoSave(for tabID: UUID) { autoSaveCoordinator.cancel(for: tabID) }
    var hasScheduledAutoSave: Bool { autoSaveCoordinator.hasScheduledSave }
    func hasScheduledAutoSave(for tabID: UUID) -> Bool {
        autoSaveCoordinator.hasScheduledSave(for: tabID)
    }

    // MARK: - Markdown preview

    func togglePreviewMode() {
        guard let index = activeTabIndex, tabs[index].isMarkdownFile else { return }
        tabs[index].previewMode = tabs[index].previewMode.next
    }

    // MARK: - External change detection

    typealias ExternalConflict = TabExternalChangeDetector.ExternalConflict
    typealias ExternalChangeResult = TabExternalChangeDetector.ExternalChangeResult

    func checkExternalChanges() -> ExternalChangeResult {
        let providers = FileProviders(
            modDate: { [weak self] url in self?.modDate(for: url) },
            fileSize: { [weak self] url in self?.fileSize(url: url) }
        )
        let result = TabExternalChangeDetector.checkExternalChanges(tabs: &tabs, providers: providers)
        for id in result.cleanDeletedIDs { closeTab(id: id) }
        postReloadNotifications(result.reloadedTabs)
        return result
    }

    func reloadTab(url: URL) {
        let reloaded = TabExternalChangeDetector.reloadTab(
            url: url, tabs: &tabs,
            providers: .init(
                modDate: { [weak self] url in self?.modDate(for: url) },
                fileSize: { [weak self] url in self?.fileSize(url: url) }
            )
        )
        if let reloaded {
            postReloadNotifications([reloaded])
        }
    }

    private func postReloadNotifications(_ reloadedTabs: [ReloadedTab]) {
        for reloaded in reloadedTabs {
            NotificationCenter.default.post(
                name: .tabReloadedFromDisk,
                object: nil,
                userInfo: ["url": reloaded.url, "text": reloaded.text]
            )
        }
    }

    @discardableResult
    func reopenActiveTab(withEncoding encoding: String.Encoding) -> Bool {
        guard let index = activeTabIndex, !tabs[index].isDirty else { return false }
        let tab = tabs[index]
        guard let data = try? Data(contentsOf: tab.url),
              let content = String(data: data, encoding: encoding) else { return false }
        tabs[index].content = content
        tabs[index].savedContent = content
        tabs[index].encoding = encoding
        tabs[index].lastModDate = modDate(for: tab.url)
        return true
    }

    // MARK: - File helpers

    private func modDate(for url: URL) -> Date? { TabPersistence.modDate(for: url) }
    func fileSize(url: URL) -> Int? { TabPersistence.fileSize(url: url) }
    func isLargeFile(url: URL) -> Bool { TabPersistence.isLargeFile(url: url) }
    func isPreviewFile(url: URL) -> Bool { TabPersistence.isPreviewFile(url: url) }
}
