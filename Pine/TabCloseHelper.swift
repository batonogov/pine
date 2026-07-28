//
//  TabCloseHelper.swift
//  Pine
//
//  Shared tab close confirmation dialogs used by both ContentView and PaneLeafView.
//  Also provides the shared terminal foreground-process confirmation used by
//  the status bar toggle, window close, tab close, and pane close paths.
//
//  Dialogs attach to the owning project window as sheets (issue #1241) so a
//  close confirmation in one project does not block unrelated project windows.
//  When no window context is supplied the application-modal `runModal()`
//  fallback is used, preserving behavior in headless/test contexts.
//

import AppKit

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
        context: DialogPresentationContext = DialogPresenter.forKeyProject()
    ) -> Bool {
        guard tab.isDirty else {
            tabManager.closeTab(id: tab.id)
            return true
        }

        Task { @MainActor in
            let response = await AlertTemplate.unsavedChangesSingle.runSheet(
                on: context,
                messageText: Strings.unsavedChangesTitle,
                informativeText: Strings.unsavedChangesMessage
            )
            switch response {
            case .alertFirstButtonReturn:
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                guard tabManager.saveTabSync(at: index) else { return }
                Task { await gitProvider.refreshAsync() }
                tabManager.closeTab(id: tab.id)
            case .alertSecondButtonReturn:
                tabManager.closeTab(id: tab.id)
            default:
                return
            }
        }
        return true
    }

    /// Shows a confirmation dialog for bulk close operations when there are dirty tabs.
    ///
    /// `presentAlert` is invoked to produce the modal response. Production
    /// callers pass a closure that runs the window-scoped sheet; tests inject
    /// a synchronous stub. Returns `true` if the operation should proceed.
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
        context: DialogPresentationContext = DialogPresenter.forKeyProject(),
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: ((Int) -> Bool)? = nil
    ) async -> Bool {
        guard !dirtyTabs.isEmpty else { return true }

        let fileList = dirtyTabs.map { "  \u{2022} \($0.fileName)" }.joined(separator: "\n")
        let response: NSApplication.ModalResponse
        if let presentAlert {
            response = await presentAlert()
        } else {
            response = await AlertTemplate.unsavedChangesBulk.runSheet(
                on: context,
                messageText: Strings.unsavedChangesTitle,
                informativeText: Strings.unsavedChangesListMessage(fileList)
            )
        }
        switch response {
        case .alertFirstButtonReturn:
            for tab in dirtyTabs {
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { continue }
                let didSave = saveTab?(index) ?? tabManager.saveTabSync(at: index)
                guard didSave else { return false }
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
    /// Returns `true` only when the close operation completed.
    @discardableResult
    static func closeOtherTabs(
        keeping tabID: UUID,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = DialogPresenter.forKeyProject(),
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: ((Int) -> Bool)? = nil
    ) async -> Bool {
        let dirty = tabManager.dirtyTabsForCloseOthers(keeping: tabID)
        guard await confirmBulkClose(
            dirtyTabs: dirty,
            in: tabManager,
            gitProvider: gitProvider,
            context: context,
            presentAlert: presentAlert,
            saveTab: saveTab
        ) else { return false }
        tabManager.closeOtherTabs(keeping: tabID, force: true)
        return true
    }

    /// Closes all tabs to the right of the given tab, with unsaved-changes protection.
    /// Returns `true` only when the close operation completed.
    @discardableResult
    static func closeTabsToTheRight(
        of tabID: UUID,
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = DialogPresenter.forKeyProject(),
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: ((Int) -> Bool)? = nil
    ) async -> Bool {
        let dirty = tabManager.dirtyTabsForCloseRight(of: tabID)
        guard await confirmBulkClose(
            dirtyTabs: dirty,
            in: tabManager,
            gitProvider: gitProvider,
            context: context,
            presentAlert: presentAlert,
            saveTab: saveTab
        ) else { return false }
        tabManager.closeTabsToTheRight(of: tabID, force: true)
        return true
    }

    /// Closes all tabs with unsaved-changes protection.
    /// Returns `true` only when the close operation completed.
    @discardableResult
    static func closeAllTabs(
        in tabManager: TabManager,
        gitProvider: GitStatusProvider,
        context: DialogPresentationContext = DialogPresenter.forKeyProject(),
        presentAlert: (@MainActor () async -> NSApplication.ModalResponse)? = nil,
        saveTab: ((Int) -> Bool)? = nil
    ) async -> Bool {
        let dirty = tabManager.dirtyTabsForCloseAll()
        guard await confirmBulkClose(
            dirtyTabs: dirty,
            in: tabManager,
            gitProvider: gitProvider,
            context: context,
            presentAlert: presentAlert,
            saveTab: saveTab
        ) else { return false }
        tabManager.closeAllTabs(force: true)
        return true
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
        context: DialogPresentationContext = DialogPresenter.forKeyProject(),
        presentAlert: @MainActor () async -> NSApplication.ModalResponse = {
            await AlertTemplate.terminalTabCloseWarning.runSheet(
                on: DialogPresenter.forKeyProject(),
                messageText: Strings.terminalTabCloseWarningTitle,
                informativeText: Strings.terminalTabCloseWarningMessage
            )
        }
    ) async -> Bool {
        guard hasForegroundProcess else { return true }
        return await presentAlert() == .alertFirstButtonReturn
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
        context: DialogPresentationContext = DialogPresenter.forKeyProject(),
        presentAlert: @MainActor () async -> NSApplication.ModalResponse = {
            await AlertTemplate.terminalTabCloseWarning.runSheet(
                on: DialogPresenter.forKeyProject(),
                messageText: Strings.terminalTabCloseWarningTitle,
                informativeText: Strings.terminalTabCloseWarningMessage
            )
        }
    ) async -> Bool {
        await confirmTerminalStop(
            hasForegroundProcess: tabs.contains { $0.hasForegroundProcess },
            context: context,
            presentAlert: presentAlert
        )
    }
}
