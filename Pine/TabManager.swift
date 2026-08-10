//
//  TabManager.swift
//  Pine
//
//  Created by Pine Team on 12.03.2026.
//

import AppKit
import os
import SwiftUI

/// One-based editor destination. Keeping line and column in one value prevents
/// a route from observing a new line with a stale column (or vice versa).
nonisolated struct EditorNavigationLocation: Equatable, Sendable {
    let line: Int
    let column: Int?
}

/// Exact authorization captured by a dialog that displayed dirty editor
/// buffers. It deliberately records only buffers that were dirty at capture
/// time: a formerly clean tab that becomes dirty while a sheet is visible is
/// therefore absent and fails validation.
struct DirtyEditorContentAuthorization: Equatable {
    private(set) var contentByTabID: [UUID: String]

    init(tabs: [EditorTab]) {
        contentByTabID = Dictionary(
            tabs.lazy
                .filter(\.isDirty)
                .map { ($0.id, $0.content) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    func covers(_ currentDirtyTabs: [EditorTab]) -> Bool {
        currentDirtyTabs.allSatisfy {
            contentByTabID[$0.id] == $0.content
        }
    }

    var isEmpty: Bool {
        contentByTabID.isEmpty
    }
}

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
    typealias LargeFileAlertPresenter = @MainActor (
        _ context: DialogPresentationContext,
        _ messageText: String,
        _ informativeText: String
    ) async -> NSApplication.ModalResponse
    typealias ExternalConflictAlertPresenter = @MainActor (
        _ context: DialogPresentationContext,
        _ messageText: String,
        _ informativeText: String
    ) async -> NSApplication.ModalResponse
    typealias OpenCompletion = @MainActor (OpenRequestResult) -> Void

    /// Immediate state returned by an open request. Large-file decisions are
    /// reported as ``pending`` and later deliver one terminal result through
    /// `OpenCompletion`; ordinary opens deliver their terminal result both
    /// synchronously and through the completion.
    enum OpenRequestResult: Equatable {
        case opened(tabID: UUID)
        case pending
        case cancelled

        var wasAccepted: Bool {
            self != .cancelled
        }
    }

    /// Result of the deliberately narrow crash-recovery append path.
    ///
    /// Normal opens preserve the pane-local one-file/one-tab invariant.
    /// Recovery is the sole exception: it must keep an already-open buffer
    /// untouched while exposing a second, independently identified buffer
    /// for the same URL.
    enum RecoveryAppendResult: Equatable {
        case appended(tabID: UUID)
        case capacityReached
        case sourceMissing
    }

    /// Exact result of a close request. Callers must not report success when a
    /// pinned tab rejected the operation.
    enum CloseTabOutcome: Equatable {
        case closed
        case pinned
        case missing
    }

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
            onActiveTabChanged?(activeTabID)
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
    var pendingGoToLocation: EditorNavigationLocation?
    /// Compatibility facade for existing line-only navigation call sites.
    var pendingGoToLine: Int? {
        get { pendingGoToLocation?.line }
        set {
            pendingGoToLocation = newValue.map {
                EditorNavigationLocation(line: $0, column: nil)
            }
        }
    }
    var recoveryManager: RecoveryManager?
    var onEditorContextChanged: (() -> Void)?
    var onActiveTabChanged: ((UUID?) -> Void)?
    /// Called after the set of tab identities changes. PaneManager uses this
    /// to reconcile a live global switcher without depending on a SwiftUI
    /// render pass noticing the mutation.
    var onTabInventoryChanged: (() -> Void)?
    var editorSettings: EditorSettings = .shared
    var fileFormatters: FileFormatterRegistry = .default
    /// Injectable preference lookup keeps independent project/test contexts
    /// from inheriting a concurrently mutated process-wide UserDefaults key.
    @ObservationIgnored
    var autoSavePreferenceProvider: @MainActor () -> Bool = {
        UserDefaults.standard.bool(forKey: TabAutoSave.autoSaveKey)
    }
    /// Project wiring replaces this fallback for every pane-owned manager,
    /// so model-triggered large-file and error flows do not depend on which
    /// unrelated window happens to be key.
    @ObservationIgnored
    var dialogContextProvider: @MainActor () -> DialogPresentationContext = {
        .unscoped
    }
    @ObservationIgnored
    var largeFileAlertPresenter: LargeFileAlertPresenter = { context, messageText, informativeText in
        await AlertTemplate.largeFileWarning.runSheet(
            on: context,
            messageText: messageText,
            informativeText: informativeText
        )
    }
    @ObservationIgnored
    var externalConflictAlertPresenter: ExternalConflictAlertPresenter = { context, messageText, informativeText in
        await AlertTemplate.externalModifyConflict.runSheet(
            on: context,
            messageText: messageText,
            informativeText: informativeText
        )
    }
    @ObservationIgnored
    private var pendingLargeFileOpens: [URL: PendingLargeFileOpen] = [:]

    private final class PendingLargeFileOpen {
        var intent: LargeFileOpenIntent
        var completions: [OpenCompletion]
        private var didComplete = false

        init(
            intent: LargeFileOpenIntent,
            completions: [OpenCompletion]
        ) {
            self.intent = intent
            self.completions = completions
        }

        func merge(
            intent newerIntent: LargeFileOpenIntent,
            completion: OpenCompletion?
        ) {
            intent = intent.merging(newerIntent)
            if let completion {
                completions.append(completion)
            }
        }

        func complete(with result: OpenRequestResult) {
            guard !didComplete else { return }
            didComplete = true
            let completions = completions
            self.completions.removeAll()
            for completion in completions {
                completion(result)
            }
        }
    }

    private enum LargeFileOpenIntent {
        case regular(location: EditorNavigationLocation?)
        case preview

        func merging(_ newer: LargeFileOpenIntent) -> LargeFileOpenIntent {
            switch (self, newer) {
            case (.regular(let existingLocation), .regular(let newerLocation)):
                return .regular(location: newerLocation ?? existingLocation)
            case (.preview, .regular):
                return newer
            case (.regular, .preview):
                return self
            case (.preview, .preview):
                return .preview
            }
        }
    }

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
    var isAutoSaveEnabled: Bool { autoSavePreferenceProvider() }
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

    @discardableResult
    func openTab(
        url: URL,
        context: DialogPresentationContext? = nil,
        completion: OpenCompletion? = nil
    ) -> OpenRequestResult {
        return openTab(
            url: url,
            location: nil,
            context: context ?? dialogContextProvider(),
            completion: completion
        )
    }

    @discardableResult
    func openTabAndGoToLine(
        url: URL,
        line: Int,
        context: DialogPresentationContext? = nil,
        completion: OpenCompletion? = nil
    ) -> OpenRequestResult {
        return openTabAndGoToLocation(
            url: url,
            line: line,
            column: nil,
            context: context,
            completion: completion
        )
    }

    @discardableResult
    func openTabAndGoToLocation(
        url: URL,
        line: Int,
        column: Int?,
        context: DialogPresentationContext? = nil,
        completion: OpenCompletion? = nil
    ) -> OpenRequestResult {
        // A new navigation request supersedes any not-yet-consumed route for
        // the currently active tab. Install the destination only after the
        // file actually opens, including after a large-file decision.
        pendingGoToLocation = nil
        return openTab(
            url: url,
            location: EditorNavigationLocation(
                line: line,
                column: column
            ),
            context: context ?? dialogContextProvider(),
            completion: completion
        )
    }

    @discardableResult
    private func openTab(
        url: URL,
        location: EditorNavigationLocation?,
        context: DialogPresentationContext,
        completion: OpenCompletion?
    ) -> OpenRequestResult {
        guard TabPersistence.requiresLargeFileDecision(
            url: url,
            existingTabs: tabs,
            syntaxHighlightingDisabled: nil
        ) else {
            let result = applyOpenDecision(TabPersistence.resolveOpen(
                url: url,
                existingTabs: tabs,
                syntaxHighlightingDisabled: nil
            ))
            if case .opened = result, let location {
                pendingGoToLocation = location
            }
            completion?(result)
            return result
        }

        return requestLargeFileOpen(
            url: url,
            intent: .regular(location: location),
            context: context,
            completion: completion
        )
    }

    func openTab(url: URL, syntaxHighlightingDisabled: Bool) {
        applyOpenDecision(TabPersistence.resolveOpen(url: url, existingTabs: tabs, syntaxHighlightingDisabled: syntaxHighlightingDisabled))
    }

    @discardableResult
    private func applyOpenDecision(
        _ decision: TabPersistence.OpenDecision
    ) -> OpenRequestResult {
        switch decision {
        case .activateExisting(let id):
            // A normal open is explicit. If the file was previously shown as
            // a transient preview, opening it normally promotes it in place.
            promoteTransientPreview(tabID: id)
            activeTabID = id
            return .opened(tabID: id)
        case .openNew(let tab):
            tabs.append(tab)
            activeTabID = tab.id
            onTabInventoryChanged?()
            return .opened(tabID: tab.id)
        case .cancel:
            return .cancelled
        }
    }

    /// Creates an editable buffer with no filesystem destination.
    @discardableResult
    func createUntitledTab(displayName: String) -> UUID? {
        guard tabs.count < Self.maxTabs else { return nil }
        let tab = EditorTab(untitledName: displayName)
        tabs.append(tab)
        activeTabID = tab.id
        pendingFocusTabID = tab.id
        onTabInventoryChanged?()
        return tab.id
    }

    /// Whether recovery can keep the disk/current buffer and append a
    /// separately identified recovered buffer without exceeding `maxTabs`.
    ///
    /// A URL that is not open yet needs two slots: the ordinary open supplies
    /// the baseline buffer and ``appendRecoveredTab`` supplies the crash
    /// buffer. An already-open URL needs only the latter.
    func canRestoreRecoveryEntry(for url: URL) -> Bool {
        let hasBaseline = tabs.contains(where: { $0.fileURL == url })
        let requiredSlots = hasBaseline ? 1 : 2
        return tabs.count <= Self.maxTabs - requiredSlots
    }

    /// Appends recovered content as a new tab while preserving the source tab
    /// exactly as it was. This is intentionally not part of the ordinary open
    /// path: duplicate URLs inside one pane are allowed only when retaining
    /// divergent crash-recovery buffers would otherwise lose user data.
    ///
    /// `savedContent` and file metadata come from the source tab, so dirty
    /// state is computed against the same baseline that the user can inspect
    /// in the separately retained source tab.
    func appendRecoveredTab(
        basedOn sourceTabID: UUID,
        content: String,
        encoding: String.Encoding
    ) -> RecoveryAppendResult {
        guard tabs.count < Self.maxTabs else {
            return .capacityReached
        }
        guard let source = tabs.first(where: { $0.id == sourceTabID }) else {
            return .sourceMissing
        }

        var recovered = EditorTab.reidentified(from: source)
        recovered.kind = .text
        recovered.content = content
        recovered.encoding = encoding
        recovered.cachedHighlightResult = nil
        recovered.isPinned = false
        recovered.isTransientPreview = false
        recovered.recomputeContentCaches()
        tabs.append(recovered)
        activeTabID = recovered.id
        onTabInventoryChanged?()
        return .appended(tabID: recovered.id)
    }

    /// Restores a crash snapshot that never had an on-disk destination.
    func appendRecoveredUntitledTab(
        displayName: String,
        content: String,
        encoding: String.Encoding
    ) -> RecoveryAppendResult {
        guard tabs.count < Self.maxTabs else {
            return .capacityReached
        }
        var recovered = EditorTab(
            untitledName: displayName,
            content: content,
            savedContent: ""
        )
        recovered.encoding = encoding
        recovered.recomputeContentCaches()
        tabs.append(recovered)
        activeTabID = recovered.id
        onTabInventoryChanged?()
        return .appended(tabID: recovered.id)
    }

    // MARK: - Transient preview tabs

    /// Opens a file as a transient preview. If the pane already contains an
    /// un-promoted transient preview, it is replaced in place even when a
    /// different permanent tab is currently active. A pane therefore holds
    /// at most one transient preview at a time. If the same file is already
    /// open as a permanent tab, it is simply activated without duplication.
    ///
    /// Promotion triggers (defined in ``promoteTransientPreview``) upgrade a
    /// transient preview to a permanent tab.
    @discardableResult
    func openTabAsPreview(
        url: URL,
        context: DialogPresentationContext? = nil,
        completion: OpenCompletion? = nil
    ) -> OpenRequestResult {
        let context = context ?? dialogContextProvider()
        // If the file is already open as a permanent tab, just activate it.
        if let existing = tabs.first(where: {
            $0.fileURL?.standardizedFileURL == url.standardizedFileURL
        }),
           !existing.isTransientPreview {
            activeTabID = existing.id
            let result = OpenRequestResult.opened(tabID: existing.id)
            completion?(result)
            return result
        }

        guard TabPersistence.requiresLargeFileDecision(
            url: url,
            existingTabs: tabs,
            syntaxHighlightingDisabled: nil
        ) else {
            let result = applyPreviewOpenDecision(TabPersistence.resolveOpen(
                url: url,
                existingTabs: tabs,
                syntaxHighlightingDisabled: nil
            ))
            completion?(result)
            return result
        }

        return requestLargeFileOpen(
            url: url,
            intent: .preview,
            context: context,
            completion: completion
        )
    }

    @discardableResult
    private func requestLargeFileOpen(
        url: URL,
        intent: LargeFileOpenIntent,
        context: DialogPresentationContext,
        completion: OpenCompletion?
    ) -> OpenRequestResult {
        let requestURL = url.standardizedFileURL
        if let pendingOpen = pendingLargeFileOpens[requestURL] {
            pendingOpen.merge(intent: intent, completion: completion)
            return .pending
        }
        let pendingOpen = PendingLargeFileOpen(
            intent: intent,
            completions: completion.map { [$0] } ?? []
        )
        pendingLargeFileOpens[requestURL] = pendingOpen

        let sizeMB = Double(TabPersistence.fileSize(url: url) ?? 0)
            / Double(FileSizeConstants.oneMB)
        let presentAlert = largeFileAlertPresenter
        Task { @MainActor [weak self, pendingOpen] in
            let response = await presentAlert(
                context,
                Strings.largeFileWarningTitle,
                Strings.largeFileWarningMessage(
                    url.lastPathComponent,
                    sizeMB
                )
            )
            guard let self else {
                pendingOpen.complete(with: .cancelled)
                return
            }
            guard pendingLargeFileOpens[requestURL] === pendingOpen else {
                pendingOpen.complete(with: .cancelled)
                return
            }
            pendingLargeFileOpens.removeValue(forKey: requestURL)
            let decision = TabPersistence.resolveOpen(
                url: url,
                existingTabs: tabs,
                syntaxHighlightingDisabled: nil,
                largeFileDecision: TabPersistence.largeFileDecision(for: response)
            )
            let result: OpenRequestResult
            switch pendingOpen.intent {
            case .regular(let location):
                result = applyOpenDecision(decision)
                if case .opened = result, let location {
                    pendingGoToLocation = location
                }
            case .preview:
                result = applyPreviewOpenDecision(decision)
            }
            pendingOpen.complete(with: result)
        }
        return .pending
    }

    private func applyPreviewOpenDecision(
        _ decision: TabPersistence.OpenDecision
    ) -> OpenRequestResult {
        switch decision {
        case .activateExisting(let id):
            activeTabID = id
            return .opened(tabID: id)
        case .cancel:
            return .cancelled
        case .openNew(var tab):
            tab.isTransientPreview = true
            // Replacement is pane-scoped, not selection-scoped. A user may
            // leave the preview, select a permanent tab, then preview another
            // file; that must still reuse the existing preview slot.
            if let previewIndex = tabs.firstIndex(where: \.isTransientPreview) {
                tabs[previewIndex] = tab
            } else {
                tabs.append(tab)
            }
            activeTabID = tab.id
            onTabInventoryChanged?()
            return .opened(tabID: tab.id)
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

    @discardableResult
    func closeTab(id: UUID, force: Bool = false) -> CloseTabOutcome {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return .missing
        }
        if tabs[index].isPinned && !force {
            return .pinned
        }
        cancelAutoSave(for: id)
        recoveryManager?.deleteRecoveryFile(for: id)
        let wasActive = activeTabID == id
        tabs.remove(at: index)
        if wasActive {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        onTabInventoryChanged?()
        return .closed
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

    /// Commits a previously authorized "Don't Save" decision without doing
    /// file I/O. Validation happens before the first mutation so a new/edited
    /// dirty buffer leaves the entire manager untouched.
    @discardableResult
    func discardChanges(
        authorizedBy authorization: DirtyEditorContentAuthorization,
        postReloads: Bool = true
    ) -> Bool {
        let currentDirtyTabs = tabs.filter(\.isDirty)
        guard authorization.covers(currentDirtyTabs) else { return false }

        var reloads: [ReloadedTab] = []
        let authorizedExistingIDs = tabs.compactMap { tab in
            authorization.contentByTabID[tab.id] == nil ? nil : tab.id
        }
        for index in tabs.indices where tabs[index].isDirty {
            let tabID = tabs[index].id
            cancelAutoSave(for: tabID)
            tabs[index].content = tabs[index].savedContent
            tabs[index].cachedHighlightResult = nil
            tabs[index].recomputeContentCaches()
            reloads.append(.init(
                url: tabs[index].url,
                text: tabs[index].savedContent
            ))
        }
        for tabID in authorizedExistingIDs {
            cancelAutoSave(for: tabID)
            recoveryManager?.deleteRecoveryFile(for: tabID)
        }
        if postReloads {
            postReloadNotifications(reloads)
        }
        return true
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
        guard tabs[index].fileURL != nil else { return false }
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

    /// Synchronous, UI-free save primitive used by autosave and tests.
    ///
    /// Errors are reported by the async window-scoped overload at user
    /// interaction boundaries. Keeping this primitive UI-free prevents a
    /// background/autosave failure from creating detached modal UI.
    @discardableResult
    func saveTab(at index: Int) -> Bool {
        assert(tabs.indices.contains(index), "saveTab: index \(index) out of bounds, count \(tabs.count)")
        do {
            return try trySaveTab(at: index)
        } catch {
            return false
        }
    }

    /// Saves and presents any failure on the captured project window.
    @discardableResult
    func saveTab(
        at index: Int,
        context: DialogPresentationContext
    ) async -> Bool {
        assert(tabs.indices.contains(index), "saveTab: index \(index) out of bounds, count \(tabs.count)")
        do {
            return try trySaveTab(at: index)
        } catch {
            if let saveError = error as? TabPersistence.SaveError,
               case .externalChange(let conflict) = saveError,
               await resolveExternalSaveConflict(
                   conflict,
                   context: context
               ) {
                return false
            }
            _ = await AlertTemplate.fileOperationErrorCritical.runSheet(
                on: context,
                messageText: Strings.fileOperationErrorTitle,
                informativeText: error.localizedDescription
            )
            return false
        }
    }

    func trySaveAllTabs() throws {
        cancelAutoSave()
        for index in tabs.indices where tabs[index].isDirty { try trySaveTab(at: index) }
    }

    /// Synchronous, UI-free save-all primitive.
    @discardableResult
    func saveAllTabs() -> Bool {
        do { try trySaveAllTabs(); return true } catch { return false }
    }

    /// Save-all variant for close/termination flows. The first error is
    /// presented as a sheet owned by the initiating project window.
    @discardableResult
    func saveAllTabs(context: DialogPresentationContext) async -> Bool {
        do {
            try trySaveAllTabs()
            return true
        } catch {
            if let saveError = error as? TabPersistence.SaveError,
               case .externalChange(let conflict) = saveError,
               await resolveExternalSaveConflict(
                   conflict,
                   context: context
               ) {
                return false
            }
            _ = await AlertTemplate.fileOperationErrorCritical.runSheet(
                on: context,
                messageText: Strings.fileOperationErrorTitle,
                informativeText: error.localizedDescription
            )
            return false
        }
    }

    @discardableResult
    func saveActiveTabAs(to newURL: URL) throws -> Bool {
        guard let activeTabID else { return false }
        return try saveTabAs(tabID: activeTabID, to: newURL)
    }

    /// Saves one exact tab to a new destination without depending on focus.
    /// Close-window Save All uses this for untitled buffers while preserving
    /// the tab identity captured before the native panel was shown.
    @discardableResult
    func saveTabAs(tabID: UUID, to newURL: URL) throws -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return false
        }
        let outcome = try TabPersistence.saveTabAs(
            at: index, tabs: &tabs, newURL: newURL,
            config: .init(editorSettings: editorSettings, formatters: fileFormatters),
            providers: .init(
                modDate: { [weak self] url in self?.modDate(for: url) },
                fileSize: { _ in nil }
            )
        )
        if outcome.saved {
            recoveryManager?.deleteRecoveryFile(for: tabID)
            onTabInventoryChanged?()
        }
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

    /// Applies the model half of a termination save after its destination was
    /// atomically replaced from an off-main staged file. No formatter or file
    /// write is performed here, so Quit never waits for those operations on
    /// the main actor.
    @discardableResult
    func applyTerminationStagedSave(
        request: TerminationSaveRequest,
        savedContent: String,
        metadata: TerminationInstalledFileMetadata
    ) -> Bool {
        guard let index = tabs.firstIndex(where: {
            $0.id == request.tabID
        }),
              tabs[index].isDirty,
              tabs[index].kind == .text,
              !tabs[index].isTruncated,
              tabs[index].contentVersion == request.contentVersion,
              tabs[index].persistenceGeneration
                == request.persistenceGeneration,
              tabs[index].content == request.content,
              tabs[index].fileURL == request.originalURL else {
            return false
        }
        let contentChanged = savedContent != tabs[index].content
        let backingChanged = tabs[index].fileURL != request.destination
        tabs[index].content = savedContent
        tabs[index].url = request.destination
        tabs[index].savedContent = savedContent
        tabs[index].lastModDate = metadata.modificationDate
        tabs[index].fileSizeBytes = metadata.size
        tabs[index].backingFileRevision = BackingFileRevision(
            contentDigest: metadata.contentDigest
        )
        tabs[index].pendingExternalFileState = nil
        if contentChanged {
            tabs[index].cachedHighlightResult = nil
            tabs[index].recomputeContentCaches()
        }
        recoveryManager?.deleteRecoveryFile(for: request.tabID)
        if backingChanged {
            onTabInventoryChanged?()
        }
        if contentChanged {
            NotificationCenter.default.post(
                name: .tabReloadedFromDisk,
                object: nil,
                userInfo: [
                    "url": request.destination,
                    "text": savedContent,
                ]
            )
        }
        return true
    }

    /// Reconciles a staged save whose atomic install ran off-main. If the
    /// buffer was edited while the syscall was in flight, the new edit stays
    /// visible and dirty while `savedContent` becomes the truthful disk base.
    @discardableResult
    func reconcileTerminationStagedSave(
        request: TerminationSaveRequest,
        savedContent: String,
        metadata: TerminationInstalledFileMetadata
    ) -> Bool {
        guard let index = tabs.firstIndex(where: {
            $0.id == request.tabID
        }),
              tabs[index].kind == .text,
              !tabs[index].isTruncated,
              tabs[index].persistenceGeneration
                == request.persistenceGeneration,
              tabs[index].fileURL == request.originalURL else {
            return false
        }
        let requestIsStillCurrent =
            tabs[index].contentVersion == request.contentVersion
            && tabs[index].content == request.content
        let backingChanged = tabs[index].fileURL != request.destination
        if requestIsStillCurrent {
            tabs[index].content = savedContent
            tabs[index].cachedHighlightResult = nil
            tabs[index].recomputeContentCaches()
        }
        tabs[index].url = request.destination
        tabs[index].savedContent = savedContent
        tabs[index].lastModDate = metadata.modificationDate
        tabs[index].fileSizeBytes = metadata.size
        tabs[index].backingFileRevision = BackingFileRevision(
            contentDigest: metadata.contentDigest
        )
        tabs[index].pendingExternalFileState = nil
        if !requestIsStillCurrent {
            tabs[index].recomputeContentCaches()
        }
        if tabs[index].isDirty {
            recoveryManager?.scheduleSnapshot()
        } else {
            recoveryManager?.deleteRecoveryFile(for: request.tabID)
        }
        if backingChanged {
            onTabInventoryChanged?()
        }
        if requestIsStillCurrent && savedContent != request.content {
            NotificationCenter.default.post(
                name: .tabReloadedFromDisk,
                object: nil,
                userInfo: [
                    "url": request.destination,
                    "text": savedContent,
                ]
            )
        }
        return true
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
        onTabInventoryChanged?()

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
            if existing.id == tab.id {
                return true
            }
            guard let existingURL = existing.fileURL,
                  let incomingURL = tab.fileURL else {
                return false
            }
            return existingURL.standardizedFileURL
                == incomingURL.standardizedFileURL
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
        onTabInventoryChanged?()
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
        onTabInventoryChanged?()
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
        guard tabs[index].fileURL != nil else { return false }
        let newID = try TabDuplicator.duplicateTab(
            atIndex: index, in: &tabs,
            editorSettings: editorSettings, fileFormatters: fileFormatters,
            projectRoot: projectRoot
        )
        if let newID {
            activeTabID = newID
            onTabInventoryChanged?()
        }
        return newID != nil
    }

    @discardableResult
    func duplicateActiveTab(
        projectRoot: URL? = nil,
        context: DialogPresentationContext? = nil
    ) -> Bool {
        let context = context ?? dialogContextProvider()
        do { return try tryDuplicateActiveTab(projectRoot: projectRoot) } catch {
            Task { @MainActor in
                _ = await AlertTemplate.fileOperationErrorCritical.runSheet(
                    on: context,
                    messageText: Strings.fileOperationErrorTitle,
                    informativeText: error.localizedDescription
                )
            }
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
        tabs.filter {
            guard let fileURL = $0.fileURL else { return false }
            return fileURL == url
                || fileURL.path.hasPrefix(url.path + "/")
        }
            .forEach { closeTab(id: $0.id) }
    }

    // MARK: - Auto-save

    private let autoSaveCoordinator = TabAutoSave()
    private var autoSaveFrozenForTermination = false
    nonisolated static let autoSaveKey = TabAutoSave.autoSaveKey
    var isAutoSaving: Bool { autoSaveCoordinator.isSaving }
    var autoSaveDelay: TimeInterval { autoSaveCoordinator.delay }

    func setAutoSaveDelay(_ delay: TimeInterval) { autoSaveCoordinator.delay = delay }

    func scheduleAutoSave() {
        guard let tabID = activeTabID else { return }
        scheduleAutoSave(for: tabID)
    }

    private func scheduleAutoSave(for tabID: UUID) {
        guard !autoSaveFrozenForTermination,
              let index = tabs.firstIndex(where: { $0.id == tabID }),
              let fileURL = tabs[index].fileURL,
              FileManager.default.isWritableFile(atPath: fileURL.path) else {
            return
        }
        autoSaveCoordinator.schedule(
            for: tabID,
            isStillDirty: { [weak self] in
                guard let self, let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else { return false }
                return self.tabs[idx].isDirty
            },
            saveAction: { [weak self] in
                guard let self, let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                do {
                    try self.trySaveTab(at: idx)
                } catch let error as TabPersistence.SaveError {
                    if case .externalChange(let conflict) = error {
                        let context = self.dialogContextProvider()
                        Task { @MainActor [weak self] in
                            _ = await self?.resolveExternalSaveConflict(
                                conflict,
                                context: context
                            )
                        }
                    }
                    throw error
                }
            }
        )
    }

    func cancelAutoSave() { autoSaveCoordinator.cancel() }
    private func cancelAutoSave(for tabID: UUID) { autoSaveCoordinator.cancel(for: tabID) }
    var hasScheduledAutoSave: Bool { autoSaveCoordinator.hasScheduledSave }
    func hasScheduledAutoSave(for tabID: UUID) -> Bool {
        autoSaveCoordinator.hasScheduledSave(for: tabID)
    }

    /// Prevents a pending or newly scheduled debounce from turning a user's
    /// explicit Quit/Don't Save decision into an implicit save while the
    /// asynchronous termination handshake is in progress.
    func freezeAutoSaveForTermination() {
        autoSaveFrozenForTermination = true
        autoSaveCoordinator.cancel()
    }

    func cancelAutoSaveTerminationFreeze() {
        guard autoSaveFrozenForTermination else { return }
        autoSaveFrozenForTermination = false
        guard isAutoSaveEnabled else { return }
        for tab in tabs where tab.isDirty {
            scheduleAutoSave(for: tab.id)
        }
    }

    func finishAutoSaveTerminationFreeze() {
        autoSaveFrozenForTermination = false
        autoSaveCoordinator.cancel()
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

    func reloadTab(conflict: ExternalConflict) {
        let reloaded = TabExternalChangeDetector.reloadTab(
            url: conflict.url,
            tabs: &tabs,
            providers: fileProviders,
            expectedState: conflict.observedState
        )
        if let reloaded {
            postReloadNotifications([reloaded])
        }
    }

    @discardableResult
    func authorizeExternalChange(_ conflict: ExternalConflict) -> Bool {
        TabExternalChangeDetector.authorizeExternalChange(
            conflict,
            tabs: &tabs,
            providers: fileProviders
        )
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

    private func resolveExternalSaveConflict(
        _ conflict: ExternalConflict,
        context: DialogPresentationContext
    ) async -> Bool {
        guard conflict.kind == .modified,
              let displayedTab = tabs.first(where: {
                  $0.id == conflict.tabID && $0.isDirty
              }) else {
            return false
        }
        let authorization = DirtyEditorContentAuthorization(
            tabs: [displayedTab]
        )
        let response = await externalConflictAlertPresenter(
            context,
            Strings.externalModifyTitle,
            Strings.externalModifyMessage(conflict.url.lastPathComponent)
        )
        guard let currentTab = tabs.first(where: {
            $0.id == conflict.tabID && $0.isDirty
        }),
        authorization.covers([currentTab]) else {
            return true
        }
        switch response {
        case .alertFirstButtonReturn:
            reloadTab(conflict: conflict)
        case .alertSecondButtonReturn:
            authorizeExternalChange(conflict)
        default:
            break
        }
        return true
    }

    @discardableResult
    func reopenActiveTab(withEncoding encoding: String.Encoding) -> Bool {
        guard let index = activeTabIndex, !tabs[index].isDirty else { return false }
        let tab = tabs[index]
        guard let fileURL = tab.fileURL,
              let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: encoding) else { return false }
        tabs[index].content = content
        tabs[index].savedContent = content
        tabs[index].encoding = encoding
        tabs[index].lastModDate = modDate(for: fileURL)
        tabs[index].backingFileRevision = BackingFileRevision(
            data: data,
            fileIdentity: try? BackingFileIdentity.capture(at: fileURL)
        )
        tabs[index].pendingExternalFileState = nil
        return true
    }

    // MARK: - File helpers

    private var fileProviders: FileProviders {
        .init(
            modDate: { [weak self] url in self?.modDate(for: url) },
            fileSize: { [weak self] url in self?.fileSize(url: url) }
        )
    }

    private func modDate(for url: URL) -> Date? { TabPersistence.modDate(for: url) }
    func fileSize(url: URL) -> Int? { TabPersistence.fileSize(url: url) }
    func isLargeFile(url: URL) -> Bool { TabPersistence.isLargeFile(url: url) }
    func isPreviewFile(url: URL) -> Bool { TabPersistence.isPreviewFile(url: url) }
}
