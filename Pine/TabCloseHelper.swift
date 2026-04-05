//
//  TabCloseHelper.swift
//  Pine
//
//  Shared tab close confirmation dialogs used by both ContentView and PaneLeafView.
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
            let alert = NSAlert()
            alert.messageText = Strings.unsavedChangesTitle
            alert.informativeText = Strings.unsavedChangesMessage
            alert.addButton(withTitle: Strings.dialogSave)
            alert.addButton(withTitle: Strings.dialogDontSave)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            let response = alert.runModal()
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
        let alert = NSAlert()
        alert.messageText = Strings.unsavedChangesTitle
        alert.informativeText = Strings.unsavedChangesListMessage(fileList)
        alert.addButton(withTitle: Strings.dialogSaveAll)
        alert.addButton(withTitle: Strings.dialogDontSave)
        alert.addButton(withTitle: Strings.dialogCancel)
        alert.alertStyle = .warning

        let response = alert.runModal()
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
}
