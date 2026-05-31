//
//  AlertTemplate.swift
//  Pine
//
//  A single enum + factory that replaces all direct NSAlert() constructions
//  across the codebase. Each case encodes button labels, alert style,
//  and destructive-button position so every call site is one line.
//

import AppKit

/// Templates for all NSAlert dialogs used in Pine.
///
/// Usage:
/// ```swift
/// let response = AlertTemplate.unsavedChangesSingle.runModal(
///     messageText: Strings.unsavedChangesTitle,
///     informativeText: Strings.unsavedChangesMessage
/// )
/// ```
enum AlertTemplate: Sendable {
    // MARK: - Unsaved changes

    /// Save / Don't Save / Cancel  — single file close confirmation.
    case unsavedChangesSingle

    /// Save All / Don't Save / Cancel  — bulk close / window close / app quit.
    case unsavedChangesBulk

    // MARK: - Terminal

    /// Close / Cancel  — closing a terminal tab with a foreground process.
    case terminalTabCloseWarning

    /// Quit / Cancel  — quitting the app with active terminal processes.
    case terminalActiveProcessWarning

    // MARK: - External changes

    /// Reload / Keep  — file was modified externally.
    case externalModifyConflict

    /// Save As / Don't Save / Cancel  — file was deleted externally.
    case fileDeletedSaveAs

    // MARK: - File operations

    /// OK only, `.critical` style  — save/duplicate/as-error alert.
    case fileOperationErrorCritical

    /// OK only, `.warning` style  — save-as fallback error, sidebar error.
    case fileOperationErrorWarning

    /// Open Without Highlighting / Open With Highlighting / Cancel  — large file warning.
    case largeFileWarning

    // MARK: - Git

    /// Switch Anyway / Cancel  — branch switch with uncommitted changes.
    case branchUncommittedChanges

    // MARK: - Revert

    /// Revert All / Cancel  — confirm reverting all changes in a file.
    case revertAllConfirmation

    // MARK: - CLI Installer

    /// OK only, `.informational` style  — CLI install/uninstall notification.
    case cliInstallerInfo
}

// MARK: - Factory

extension AlertTemplate {
    /// Creates a fully configured `NSAlert` for this template.
    ///
    /// - Parameters:
    ///   - messageText: The primary message (bold title).
    ///   - informativeText: Optional secondary message. Pass `nil` to omit.
    /// - Returns: A configured `NSAlert` ready for `runModal()`.
    @MainActor
    func makeAlert(messageText: String, informativeText: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        if let informativeText {
            alert.informativeText = informativeText
        }
        alert.alertStyle = style

        for buttonTitle in buttonTitles {
            alert.addButton(withTitle: buttonTitle)
        }

        return alert
    }

    /// Creates and runs a modal alert for this template.
    ///
    /// - Parameters:
    ///   - messageText: The primary message (bold title).
    ///   - informativeText: Optional secondary message.
    /// - Returns: The modal response from the alert.
    @discardableResult
    @MainActor
    func runModal(messageText: String, informativeText: String? = nil) -> NSApplication.ModalResponse {
        makeAlert(messageText: messageText, informativeText: informativeText).runModal()
    }
}

// MARK: - Template Configuration

extension AlertTemplate {
    /// The alert style for this template.
    private var style: NSAlert.Style {
        switch self {
        case .fileOperationErrorCritical:
            return .critical
        case .cliInstallerInfo:
            return .informational
        case .unsavedChangesSingle, .unsavedChangesBulk,
             .terminalTabCloseWarning, .terminalActiveProcessWarning,
             .externalModifyConflict, .fileDeletedSaveAs,
             .fileOperationErrorWarning, .largeFileWarning,
             .branchUncommittedChanges, .revertAllConfirmation:
            return .warning
        }
    }

    /// The button titles in order (first button = `.alertFirstButtonReturn`).
    private var buttonTitles: [String] {
        switch self {
        case .unsavedChangesSingle:
            return [Strings.dialogSave, Strings.dialogDontSave, Strings.dialogCancel]
        case .unsavedChangesBulk:
            return [Strings.dialogSaveAll, Strings.dialogDontSave, Strings.dialogCancel]
        case .terminalTabCloseWarning:
            return [Strings.terminalTabCloseWarningClose, Strings.dialogCancel]
        case .terminalActiveProcessWarning:
            return [Strings.terminalActiveProcessWarningQuit, Strings.dialogCancel]
        case .externalModifyConflict:
            return [Strings.externalModifyReload, Strings.externalModifyKeep]
        case .fileDeletedSaveAs:
            return [Strings.fileDeletedSaveAs, Strings.dialogDontSave, Strings.dialogCancel]
        case .fileOperationErrorCritical, .fileOperationErrorWarning:
            return [Strings.dialogOK]
        case .largeFileWarning:
            return [
                Strings.largeFileOpenWithoutHighlighting,
                Strings.largeFileOpenWithHighlighting,
                Strings.dialogCancel,
            ]
        case .branchUncommittedChanges:
            return [Strings.branchUncommittedChangesSwitch, Strings.dialogCancel]
        case .revertAllConfirmation:
            return [Strings.revertAllButton, Strings.dialogCancel]
        case .cliInstallerInfo:
            return [Strings.dialogOK]
        }
    }
}
