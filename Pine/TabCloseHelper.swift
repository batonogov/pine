//
//  TabCloseHelper.swift
//  Pine
//
//  Shared tab close confirmation dialogs used by both ContentView and PaneLeafView.
//  Also provides the shared terminal foreground-process confirmation used by
//  the status bar toggle, window close, tab close, and pane close paths.
//

import AppKit

@MainActor
enum TabCloseHelper {

    /// Closes a single tab with unsaved-changes protection.
    /// Returns `true` if the tab was actually closed.
    @discardableResult
    static func closeTab(
        _ tab: EditorTab,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider
    ) -> Bool {
        if tab.isDirty {
            let response = AlertTemplate.unsavedChangesSingle.runModal(
                messageText: Strings.unsavedChangesTitle,
                informativeText: Strings.unsavedChangesMessage
            )
            switch response {
            case .alertFirstButtonReturn:
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
                guard tabManager.saveTab(at: index) else { return false }
                Task { await gitProvider.refreshAsync() }
                tabManager.closeTab(id: tab.id)
            case .alertSecondButtonReturn:
                tabManager.closeTab(id: tab.id)
            default:
                return false
            }
        } else {
            tabManager.closeTab(id: tab.id)
        }
        return true
    }

    /// Shows a confirmation dialog for bulk close operations when there are dirty tabs.
    /// Returns `true` if the operation should proceed.
    static func confirmBulkClose(
        dirtyTabs: [EditorTab],
        in tabManager: TabManager,
        gitProvider: GitStatusProvider
    ) -> Bool {
        guard !dirtyTabs.isEmpty else { return true }

        let fileList = dirtyTabs.map { "  \u{2022} \($0.fileName)" }.joined(separator: "\n")
        let response = AlertTemplate.unsavedChangesBulk.runModal(
            messageText: Strings.unsavedChangesTitle,
            informativeText: Strings.unsavedChangesListMessage(fileList)
        )
        switch response {
        case .alertFirstButtonReturn:
            for tab in dirtyTabs {
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { continue }
                guard tabManager.saveTab(at: index) else { return false }
            }
            Task { await gitProvider.refreshAsync() }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Closes all tabs except the one with the given ID, with unsaved-changes protection.
    static func closeOtherTabs(
        keeping tabID: UUID,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider
    ) {
        let dirty = tabManager.dirtyTabsForCloseOthers(keeping: tabID)
        guard confirmBulkClose(dirtyTabs: dirty, in: tabManager, gitProvider: gitProvider) else { return }
        tabManager.closeOtherTabs(keeping: tabID, force: true)
    }

    /// Closes all tabs to the right of the given tab, with unsaved-changes protection.
    static func closeTabsToTheRight(
        of tabID: UUID,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider
    ) {
        let dirty = tabManager.dirtyTabsForCloseRight(of: tabID)
        guard confirmBulkClose(dirtyTabs: dirty, in: tabManager, gitProvider: gitProvider) else { return }
        tabManager.closeTabsToTheRight(of: tabID, force: true)
    }

    /// Closes all tabs with unsaved-changes protection.
    static func closeAllTabs(
        in tabManager: TabManager,
        gitProvider: GitStatusProvider
    ) {
        let dirty = tabManager.dirtyTabsForCloseAll()
        guard confirmBulkClose(dirtyTabs: dirty, in: tabManager, gitProvider: gitProvider) else { return }
        tabManager.closeAllTabs(force: true)
    }

    // MARK: - Terminal foreground-process confirmation

    /// Decides whether a terminal stop/close operation should proceed when
    /// foreground processes are running.
    ///
    /// - Parameters:
    ///   - hasForegroundProcess: Whether any terminal tab in scope has a
    ///     running foreground process.
    ///   - presentAlert: Closure that presents the confirmation alert and
    ///     returns the modal response. Injected for testing; defaults to the
    ///     standard `terminalTabCloseWarning` alert.
    /// - Returns: `true` if there is no foreground process (no warning needed)
    ///     or the user confirmed. `false` to abort the stop/close.
    static func confirmTerminalStop(
        hasForegroundProcess: Bool,
        presentAlert: () -> NSApplication.ModalResponse = {
            AlertTemplate.terminalTabCloseWarning.runModal(
                messageText: Strings.terminalTabCloseWarningTitle,
                informativeText: Strings.terminalTabCloseWarningMessage
            )
        }
    ) -> Bool {
        guard hasForegroundProcess else { return true }
        return presentAlert() == .alertFirstButtonReturn
    }

    /// Convenience overload that checks the foreground-process predicate on
    /// a collection of terminal tabs before presenting the shared alert.
    ///
    /// - Parameters:
    ///   - tabs: The terminal tabs to inspect.
    ///   - presentAlert: Closure that presents the confirmation alert.
    ///     Injected for testing; defaults to the standard alert.
    /// - Returns: `true` if none of the tabs has a foreground process or the
    ///     user confirmed. `false` to abort.
    static func confirmTerminalProcessStop(
        tabs: [TerminalTab],
        presentAlert: () -> NSApplication.ModalResponse = {
            AlertTemplate.terminalTabCloseWarning.runModal(
                messageText: Strings.terminalTabCloseWarningTitle,
                informativeText: Strings.terminalTabCloseWarningMessage
            )
        }
    ) -> Bool {
        confirmTerminalStop(
            hasForegroundProcess: tabs.contains { $0.hasForegroundProcess },
            presentAlert: presentAlert
        )
    }
}
