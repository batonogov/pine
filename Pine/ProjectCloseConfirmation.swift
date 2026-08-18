//
//  ProjectCloseConfirmation.swift
//  Pine
//
//  Deciding what happens to unsaved files when a project goes away.
//

import AppKit

/// The unsaved-changes decision made before a project leaves the screen.
///
/// Two paths reach it: closing the window, and closing one project inside a
/// window that holds several. Both take a project out of view while leaving
/// its `ProjectManager` alive in the background, and a user who has edits in
/// flight deserves the same question either way — which is the whole reason
/// this lives apart from the window delegate that used to own it.
enum ProjectCloseConfirmation {
    /// Presents the alert. Injected by tests; production goes to `AlertTemplate`.
    typealias AlertPresenter = @MainActor (
        AlertTemplate,
        DialogPresentationContext,
        String,
        String
    ) async -> NSApplication.ModalResponse

    /// Saves every dirty tab, reporting whether all of them made it to disk.
    typealias SaveAll = @MainActor (
        ProjectManager,
        DialogPresentationContext
    ) async -> Bool

    enum Decision: Equatable {
        case cancel
        /// Proceed. A non-nil authorization must be committed with
        /// ``ProjectManager/commitDiscard(_:postReloadNotifications:)`` before
        /// anything destructive happens.
        case approve(discard: DirtyEditorContentAuthorization?)
    }

    /// Asks about unsaved work in `projectManager` and returns what to do.
    ///
    /// The answer is re-checked against the live dirty tabs before it is
    /// returned: the sheet is asynchronous, and a tab that became dirty while
    /// it was up was never covered by what the user agreed to. That case
    /// cancels rather than silently discarding an edit nobody saw.
    static func confirm(
        projectManager: ProjectManager,
        context: DialogPresentationContext,
        presentAlert: AlertPresenter? = nil,
        saveAll: SaveAll? = nil
    ) async -> Decision {
        var discardAuthorization: DirtyEditorContentAuthorization?
        let dirty = projectManager.allDirtyTabs
        if !dirty.isEmpty {
            let fileList = dirty
                .map { "  • \($0.fileName)" }
                .joined(separator: "\n")
            let message = Strings.unsavedChangesListMessage(fileList)
            let response = if let presentAlert {
                await presentAlert(
                    .unsavedChangesBulk,
                    context,
                    Strings.unsavedChangesTitle,
                    message
                )
            } else {
                await AlertTemplate.unsavedChangesBulk.runSheet(
                    on: context,
                    messageText: Strings.unsavedChangesTitle,
                    informativeText: message
                )
            }
            switch response {
            case .alertFirstButtonReturn:
                let didSave = if let saveAll {
                    await saveAll(projectManager, context)
                } else {
                    await projectManager.saveAllPaneTabs(context: context)
                }
                guard didSave else {
                    return .cancel
                }
            case .alertSecondButtonReturn:
                discardAuthorization = DirtyEditorContentAuthorization(
                    tabs: dirty
                )
            default:
                return .cancel
            }
        }

        let currentDirtyTabs = projectManager.allDirtyTabs
        if let discardAuthorization {
            guard discardAuthorization.covers(currentDirtyTabs) else {
                return .cancel
            }
            return .approve(discard: discardAuthorization)
        }
        return currentDirtyTabs.isEmpty
            ? .approve(discard: nil)
            : .cancel
    }
}
