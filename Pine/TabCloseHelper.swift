//
//  TabCloseHelper.swift
//  Pine
//
//  Shared tab close confirmation dialogs used by both ContentView and PaneLeafView.
//  Also provides the shared terminal foreground-process confirmation used by
//  the status bar toggle, window close, tab close, and pane close paths.
//
//  Dialogs attach to a captured owning window and are queued per window.
//  Missing or closed owners cancel the operation instead of falling back to
//  a detached application-modal alert.
//

import AppKit

/// Exact foreground job identity covered by a destructive terminal prompt.
/// A new process group in the same terminal tab is a new authorization
/// generation and must not be covered by the previous answer.
nonisolated struct TerminalForegroundProcessIdentity: Hashable, Sendable {
    let tabID: UUID
    let processGroupID: Int32
}

@MainActor
enum TabCloseHelper {

    /// Closes a single tab with unsaved-changes protection.
    ///
    /// When `context` resolves a window, the unsaved-changes alert is
    /// presented as a sheet on that window (issue #1241). The save-failure
    /// error alert (if any) is likewise window-scoped.
    ///
    /// - Returns: `true` if the tab was actually closed.
    @discardableResult
    static func closeTab(
        _ tab: EditorTab,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil
    ) async -> Bool {
        // Callers commonly create the Task from a SwiftUI value snapshot.
        // Re-resolve identity at async entry so a clean captured value cannot
        // bypass a prompt after the live tab becomes dirty (and a disappeared
        // tab cannot produce a false "closed" result).
        guard let entryTab = tabManager.tabs.first(where: {
            $0.id == tab.id
        }) else {
            return false
        }
        let tabID = entryTab.id
        let entryContent = entryTab.content
        guard entryTab.isDirty else {
            tabManager.closeTab(id: tabID)
            return true
        }

        let response: NSApplication.ModalResponse
        if let presentAlert {
            response = await presentAlert()
        } else {
            response = await AlertTemplate.unsavedChangesSingle.runSheet(
                on: context,
                deduplicationKey: .editorTabs(
                    tabManager: ObjectIdentifier(tabManager),
                    tabIDs: [tabID]
                ),
                messageText: Strings.unsavedChangesTitle,
                informativeText: Strings.unsavedChangesMessage
            )
        }
        switch response {
        case .alertFirstButtonReturn:
            guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabID }) else {
                return false
            }
            let didSave: Bool
            if let saveTab {
                didSave = await saveTab(index)
            } else {
                didSave = await tabManager.saveTab(at: index, context: context)
            }
            guard didSave else {
                return false
            }
            // An async/injected saver can suspend. Never let the original
            // Save decision close content dirtied after that save completed.
            guard let currentTab = tabManager.tabs.first(where: {
                $0.id == tabID
            }), !currentTab.isDirty else {
                return false
            }
            Task { await gitProvider.refreshAsync() }
            tabManager.closeTab(id: tabID)
            return true
        case .alertSecondButtonReturn:
            guard let currentTab = tabManager.tabs.first(where: { $0.id == tabID }) else {
                return false
            }
            // The sheet suspends this task. If background work changed the
            // dirty buffer while it was visible, the user's earlier discard
            // decision no longer covers the current content.
            guard !currentTab.isDirty || currentTab.content == entryContent else {
                return false
            }
            tabManager.closeTab(id: tabID)
            return true
        default:
            return false
        }
    }

    /// Shows a confirmation dialog for bulk close operations when there are dirty tabs.
    ///
    /// `presentAlert` is invoked to produce the modal response. Production
    /// callers pass a closure that runs the window-scoped sheet; tests inject
    /// an async stub. Returns `true` if the operation should proceed.
    ///
    /// - Parameters:
    ///   - presentAlert: Async closure that presents the confirmation alert
    ///     and returns the modal response. When `nil`, the alert is presented
    ///     as a window-scoped sheet via `context`.
    ///   - saveTab: Optional save override for testing.
    static func confirmBulkClose(
        dirtyTabs: [EditorTab],
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil,
        targetTabIDs: Set<UUID>? = nil
    ) async -> Bool {
        guard !dirtyTabs.isEmpty else { return true }

        let displayedDirtyContent = Dictionary(
            dirtyTabs.map { ($0.id, $0.content) },
            uniquingKeysWith: { _, latest in latest }
        )
        let targetTabIDs = targetTabIDs ?? Set(dirtyTabs.map(\.id))
        let fileList = dirtyTabs.map { "  \u{2022} \($0.fileName)" }.joined(separator: "\n")
        let response: NSApplication.ModalResponse
        if let presentAlert {
            response = await presentAlert()
        } else {
            response = await AlertTemplate.unsavedChangesBulk.runSheet(
                on: context,
                deduplicationKey: .editorTabs(
                    tabManager: ObjectIdentifier(tabManager),
                    tabIDs: targetTabIDs
                ),
                messageText: Strings.unsavedChangesTitle,
                informativeText: Strings.unsavedChangesListMessage(fileList)
            )
        }
        switch response {
        case .alertFirstButtonReturn:
            // Save the latest dirty state, including a tab that became dirty
            // while the sheet was visible. Saving is non-destructive and
            // therefore does not need a second confirmation.
            let currentDirtyTabs = tabManager.tabs.filter {
                targetTabIDs.contains($0.id) && $0.isDirty
            }
            for tab in currentDirtyTabs {
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { continue }
                let didSave: Bool
                if let saveTab {
                    didSave = await saveTab(index)
                } else {
                    didSave = await tabManager.saveTab(at: index, context: context)
                }
                guard didSave else { return false }
            }
            // A previously saved target can be edited again while a later
            // save or error sheet is suspended. Do not force-close it.
            guard !tabManager.tabs.contains(where: {
                targetTabIDs.contains($0.id) && $0.isDirty
            }) else {
                return false
            }
            Task { await gitProvider.refreshAsync() }
            return true
        case .alertSecondButtonReturn:
            // Do not apply "Don't Save" to a new or changed dirty buffer that
            // was not represented by the sheet the user answered.
            let currentDirtyTabs = tabManager.tabs.filter {
                targetTabIDs.contains($0.id) && $0.isDirty
            }
            guard currentDirtyTabs.allSatisfy({
                displayedDirtyContent[$0.id] == $0.content
            }) else {
                return false
            }
            return true
        default:
            return false
        }
    }

    /// Closes all tabs except the one with the given ID, with unsaved-changes protection.
    /// Returns `true` only when the close operation completed.
    @discardableResult
    static func closeOtherTabs(
        keeping tabID: UUID,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil
    ) async -> Bool {
        let targetTabIDs = Set(
            tabManager.tabs
                .filter { $0.id != tabID && !$0.isPinned }
                .map(\.id)
        )
        let dirty = tabManager.dirtyTabsForCloseOthers(keeping: tabID)
        guard await confirmBulkClose(
            dirtyTabs: dirty,
            in: tabManager,
            gitProvider: gitProvider,
            context: context,
            presentAlert: presentAlert,
            saveTab: saveTab,
            targetTabIDs: targetTabIDs
        ) else { return false }
        guard tabManager.tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        closeTabs(withIDs: targetTabIDs, in: tabManager)
        tabManager.activeTabID = tabID
        return true
    }

    /// Closes all tabs to the right of the given tab, with unsaved-changes protection.
    /// Returns `true` only when the close operation completed.
    @discardableResult
    static func closeTabsToTheRight(
        of tabID: UUID,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil
    ) async -> Bool {
        let targetTabIDs: Set<UUID>
        if let index = tabManager.tabs.firstIndex(where: { $0.id == tabID }) {
            targetTabIDs = Set(
                tabManager.tabs[(index + 1)...]
                    .filter { !$0.isPinned }
                    .map(\.id)
            )
        } else {
            targetTabIDs = []
        }
        let dirty = tabManager.dirtyTabsForCloseRight(of: tabID)
        guard await confirmBulkClose(
            dirtyTabs: dirty,
            in: tabManager,
            gitProvider: gitProvider,
            context: context,
            presentAlert: presentAlert,
            saveTab: saveTab,
            targetTabIDs: targetTabIDs
        ) else { return false }
        guard tabManager.tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        closeTabs(withIDs: targetTabIDs, in: tabManager)
        return true
    }

    /// Closes all tabs with unsaved-changes protection.
    /// Returns `true` only when the close operation completed.
    @discardableResult
    static func closeAllTabs(
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: (@MainActor (Int) async -> Bool)? = nil
    ) async -> Bool {
        let targetTabIDs = Set(tabManager.tabs.map(\.id))
        let dirty = tabManager.dirtyTabsForCloseAll()
        guard await confirmBulkClose(
            dirtyTabs: dirty,
            in: tabManager,
            gitProvider: gitProvider,
            context: context,
            presentAlert: presentAlert,
            saveTab: saveTab,
            targetTabIDs: targetTabIDs
        ) else { return false }
        // A tab created while the sheet was visible was not part of this
        // close authorization and must survive.
        closeTabs(withIDs: targetTabIDs, in: tabManager)
        return true
    }

    private static func closeTabs(
        withIDs tabIDs: Set<UUID>,
        in tabManager: TabManager
    ) {
        tabManager.tabs
            .filter { tabIDs.contains($0.id) }
            .map(\.id)
            .forEach { tabManager.closeTab(id: $0, force: true) }
    }

    // MARK: - Terminal foreground-process confirmation

    /// Decides whether a terminal stop/close operation should proceed when
    /// foreground processes are running.
    ///
    /// - Parameters:
    ///   - hasForegroundProcess: Whether any terminal tab in scope has a
    ///     running foreground process.
    ///   - context: Presentation context for the window-scoped sheet.
    ///   - presentAlert: Async closure that presents the confirmation alert
    ///     and returns the modal response. Injected for testing; defaults to
    ///     the standard `terminalTabCloseWarning` sheet.
    /// - Returns: `true` if there is no foreground process (no warning needed)
    ///     or the user confirmed. `false` to abort the stop/close.
    static func confirmTerminalStop(
        hasForegroundProcess: Bool,
        context: DialogPresentationContext = .unscoped,
        deduplicationKey: DialogRequestKey? = nil,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil
    ) async -> Bool {
        guard hasForegroundProcess else { return true }
        let response: NSApplication.ModalResponse
        if let presentAlert {
            response = await presentAlert()
        } else {
            response = await AlertTemplate.terminalTabCloseWarning.runSheet(
                on: context,
                deduplicationKey: deduplicationKey,
                messageText: Strings.terminalTabCloseWarningTitle,
                informativeText: Strings.terminalTabCloseWarningMessage
            )
        }
        return response == .alertFirstButtonReturn
    }

    /// Convenience overload that checks the foreground-process predicate on
    /// a collection of terminal tabs before presenting the shared alert.
    ///
    /// - Parameters:
    ///   - tabs: The terminal tabs to inspect.
    ///   - context: Presentation context for the window-scoped sheet.
    ///   - presentAlert: Async closure that presents the confirmation alert.
    ///     Injected for testing; defaults to the standard sheet.
    /// - Returns: `true` if none of the tabs has a foreground process or the
    ///     user confirmed. `false` to abort.
    static func confirmTerminalProcessStop(
        tabs: [TerminalTab],
        context: DialogPresentationContext = .unscoped,
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil
    ) async -> Bool {
        let authorizedProcesses = foregroundProcessSnapshot(for: tabs)
        guard !authorizedProcesses.isEmpty else { return true }
        guard await confirmTerminalStop(
            hasForegroundProcess: true,
            context: context,
            deduplicationKey: .terminalTabs(
                tabIDs: Set(tabs.map(\.id)),
                foregroundProcesses: authorizedProcesses
            ),
            presentAlert: presentAlert
        ) else {
            return false
        }
        return foregroundProcessSnapshot(for: tabs)
            .isSubset(of: authorizedProcesses)
    }

    static func foregroundProcessSnapshot(
        for tabs: [TerminalTab]
    ) -> Set<TerminalForegroundProcessIdentity> {
        Set(tabs.compactMap { tab in
            let processGroupID = tab.foregroundProcessID
            guard processGroupID > 0 else { return nil }
            return TerminalForegroundProcessIdentity(
                tabID: tab.id,
                processGroupID: processGroupID
            )
        })
    }

    nonisolated static func foregroundProcessSnapshotIsAuthorized(
        _ current: Set<TerminalForegroundProcessIdentity>,
        by authorized: Set<TerminalForegroundProcessIdentity>
    ) -> Bool {
        current.isSubset(of: authorized)
    }
}
