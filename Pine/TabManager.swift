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
        didSet { if activeTabID != oldValue { onEditorContextChanged?() } }
    }
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

    typealias LargeFileAlertResult = TabPersistence.LargeFileAlertResult

    // MARK: - Close

    func closeTab(id: UUID, force: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].isPinned && !force { return }
        cancelAutoSave()
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
        cancelAutoSave()
        tabs.filter { $0.id != tabID && !$0.isPinned && (force || !$0.isDirty) }
            .map(\.id).forEach { closeTab(id: $0, force: true) }
        activeTabID = tabID
    }

    func dirtyTabsForCloseRight(of tabID: UUID) -> [EditorTab] {
        TabCollection.dirtyTabsForCloseRight(of: tabID, in: tabs)
    }

    func closeTabsToTheRight(of tabID: UUID, force: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        cancelAutoSave()
        tabs[(index + 1)...].filter { !$0.isPinned && (force || !$0.isDirty) }
            .reversed().forEach { closeTab(id: $0.id, force: true) }
    }

    func dirtyTabsForCloseAll() -> [EditorTab] { TabCollection.dirtyTabsForCloseAll(in: tabs) }

    func closeAllTabs(force: Bool) {
        cancelAutoSave()
        tabs.filter { force || !$0.isDirty }.map(\.id).forEach { closeTab(id: $0, force: true) }
    }

    // MARK: - Content updates

    func updateContent(_ newContent: String) {
        guard let index = activeTabIndex, tabs[index].kind == .text else { return }
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
        cancelAutoSave()
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

    func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    func reorderTab(draggedID: UUID, targetID: UUID) {
        TabCollection.reorderTab(draggedID: draggedID, targetID: targetID, in: &tabs)
    }

    func togglePin(id: UUID) { TabPinning.togglePin(id: id, in: &tabs) }

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
        guard let index = activeTabIndex,
              FileManager.default.isWritableFile(atPath: tabs[index].url.path) else { return }
        let tabID = tabs[index].id
        autoSaveCoordinator.schedule(
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
    var hasScheduledAutoSave: Bool { autoSaveCoordinator.hasScheduledSave }

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
