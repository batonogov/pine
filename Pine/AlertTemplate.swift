//
//  AlertTemplate.swift
//  Pine
//
//  A single enum + factory that replaces all direct NSAlert() constructions
//  across the codebase. Each case encodes button labels, alert style,
//  destructive-button position, and button roles so every call site is one
//  line.
//
//  Two presentation paths are supported (issue #1241):
//    • `runSheet(on:)`  — async, attaches the alert as a sheet to an
//      NSWindow. Only blocks that window; other project windows stay live.
//    • `runModal(…)`    — synchronous fallback for contexts without a
//      window (headless tests, background dispatch).
//

import AppKit

/// Templates for all NSAlert dialogs used in Pine.
///
/// Usage (window-scoped sheet, preferred):
/// ```swift
/// let response = await AlertTemplate.unsavedChangesSingle.runSheet(
///     on: context,
///     messageText: Strings.unsavedChangesTitle,
///     informativeText: Strings.unsavedChangesMessage
/// )
/// ```
///
/// Usage (application-modal fallback):
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
    /// Each button is tagged with a role (`.default`, `.cancel`, or
    /// `.destructive`) so VoiceOver announces intent and so Escape / ⌘-.
    /// cancel to the button carrying `.cancel` (or the sole default when
    /// no explicit cancel exists).
    ///
    /// - Parameters:
    ///   - messageText: The primary message (bold title).
    ///   - informativeText: Optional secondary message. Pass `nil` to omit.
    /// - Returns: A configured `NSAlert` ready for sheet or modal presentation.
    @MainActor
    func makeAlert(messageText: String, informativeText: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        if let informativeText {
            alert.informativeText = informativeText
        }
        alert.alertStyle = style

        let roles = buttonRoles
        for (index, buttonTitle) in buttonTitles.enumerated() {
            let role = roles[index]
            let button = alert.addButton(withTitle: buttonTitle)
            switch role {
            case .destructive:
                button.hasDestructiveAction = true
            case .cancel:
                button.keyEquivalent = "\u{1b}" // Escape
            case .default:
                break
            }
        }

        return alert
    }

    /// Creates and runs a modal alert for this template.
    ///
    /// Application-modal fallback used when no owning window is available
    /// (headless tests, background dispatch). Prefer ``runSheet(on:)``
    /// whenever a project window can be resolved.
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

    /// Presents this alert as a sheet attached to the window resolved from
    /// `context`. The sheet blocks only that window — other project windows
    /// remain fully interactive (issue #1241).
    ///
    /// When `context` has no attached window (`.unscoped`), falls back to
    /// application-modal `runModal()` so behavior is preserved in headless
    /// contexts (tests, background dispatch without a window).
    ///
    /// Escape and ⌘-. cancel the sheet, resolving to the cancel-button
    /// response (`.alertThirdButtonReturn` for three-button templates,
    /// `.alertSecondButtonReturn` for two-button templates, or
    /// `.alertFirstButtonReturn` for single-button OK alerts).
    ///
    /// - Parameters:
    ///   - context: The presentation context carrying the owning window.
    ///   - messageText: The primary message (bold title).
    ///   - informativeText: Optional secondary message.
    /// - Returns: The modal response from the sheet.
    @discardableResult
    @MainActor
    func runSheet(
        on context: DialogPresentationContext,
        messageText: String,
        informativeText: String? = nil
    ) async -> NSApplication.ModalResponse {
        let alert = makeAlert(messageText: messageText, informativeText: informativeText)

        // Fall back to application-modal when no owning window is available.
        guard let window = context.nsWindow else {
            return alert.runModal()
        }

        // A closed window mid-flow cannot host a sheet; fall back to modal
        // so the user still sees the alert instead of silently dropping it.
        guard window.isVisible else {
            return alert.runModal()
        }

        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
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

    /// Per-button roles, parallel to ``buttonTitles``.
    ///
    /// `.default`    — the non-destructive primary action (Save, Reload, …).
    /// `.cancel`     — Escape / ⌘-. target (Cancel, Keep). A single-button
    ///                 OK alert uses `.default` since there is nothing to cancel.
    /// `.destructive`— Don't Save / Discard / Quit — confirmed data loss.
    private var buttonRoles: [AlertButtonRole] {
        switch self {
        case .unsavedChangesSingle, .unsavedChangesBulk:
            return [.default, .destructive, .cancel]
        case .terminalTabCloseWarning:
            return [.destructive, .cancel]
        case .terminalActiveProcessWarning:
            return [.destructive, .cancel]
        case .externalModifyConflict:
            // Reload discards local edits (destructive); Keep is the safe default.
            return [.destructive, .cancel]
        case .fileDeletedSaveAs:
            return [.default, .destructive, .cancel]
        case .fileOperationErrorCritical, .fileOperationErrorWarning, .cliInstallerInfo:
            return [.default]
        case .largeFileWarning:
            return [.default, .default, .cancel]
        case .branchUncommittedChanges:
            return [.destructive, .cancel]
        case .revertAllConfirmation:
            return [.destructive, .cancel]
        }
    }
}

// MARK: - Alert button role bridging

/// Semantic role for an alert button.
enum AlertButtonRole: Sendable, Equatable {
    case `default`
    case cancel
    case destructive
}
