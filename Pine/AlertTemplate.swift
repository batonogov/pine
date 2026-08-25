//
//  AlertTemplate.swift
//  Pine
//
//  Shared templates for recurring Pine alerts. Each case encodes button
//  labels, style, destructive-button position, and button roles so call
//  sites stay consistent.
//
//  Alerts are presented only as queued, window-owned sheets. A missing or
//  closed owner returns `.abort`; Pine never falls back to application-modal
//  UI that can block unrelated project windows.
//

import AppKit

/// Templates for recurring `NSAlert` dialogs used in Pine.
///
/// Usage (window-scoped sheet, preferred):
/// ```swift
/// let response = await AlertTemplate.unsavedChangesSingle.runSheet(
///     on: context,
///     messageText: Strings.unsavedChangesQuestion(tab.fileName),
///     informativeText: Strings.unsavedChangesConsequence
/// )
/// ```
///
/// `CaseIterable` so the role table in `AlertTemplateTests` can be checked for
/// completeness: a template added without an entry there would otherwise ship
/// with whatever default, cancel and destructive layout it happened to get.
enum AlertTemplate: Sendable, Equatable, CaseIterable {
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

    /// Review / Quit Anyway / Cancel — one app-wide summary for Quit.
    case applicationQuitSummary

    /// Quit Anyway / Cancel — stopping user tasks after opt-in review.
    case activeUserTasksPreventQuit

    /// OK — machine work could not complete within the Quit budget.
    case applicationQuitFailure

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

    // MARK: - User tasks

    /// Run / Cancel  — confirm running a task's shell command.
    ///
    /// Run carries `.destructive`: this sheet is shown either because the
    /// validator matched a destructive command (`rm`, `dd`, `chmod`, …) or
    /// because the task's author asked for a confirmation, and both mean the
    /// same thing — the command should not fire on a reflex Return.
    case userTaskRunConfirmation

    /// OK / Copy Output / Open Output  — a replacement task finished but the
    /// buffer moved under it, so its stdout was not applied.
    ///
    /// OK leads so it is the rightmost, default, Escape-answering button.
    /// Before this template, Return copied the output to the clipboard —
    /// a side effect nobody asked for — and Escape was bound to nothing at
    /// all, leaving the sheet with no keyboard dismissal (#1541).
    case userTaskOutputConflict

    /// OK — a task could not start, with the reason in the informative text.
    case userTaskNotice

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
    /// - Returns: A configured `NSAlert` ready for queued sheet presentation.
    @MainActor
    func makeAlert(messageText: String, informativeText: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        if let informativeText {
            alert.informativeText = informativeText
        }
        alert.alertStyle = style

        let roles = buttonRoles
        var buttons: [NSButton] = []
        for (index, buttonTitle) in buttonTitles.enumerated() {
            let role = roles[index]
            let button = alert.addButton(withTitle: buttonTitle)
            // `NSAlert` implicitly assigns Return to its first button. Clear
            // every implicit equivalent first; the semantic roles below are
            // the only keyboard authority.
            button.keyEquivalent = ""
            if role.contains(.destructive) {
                button.hasDestructiveAction = true
            }
            buttons.append(button)
        }

        let defaultIndices = roles.indices.filter {
            roles[$0].contains(.default)
        }
        assert(
            defaultIndices.count == 1,
            "Every alert template must declare exactly one default button"
        )
        let cancelIndices = roles.indices.filter {
            roles[$0].contains(.cancel)
        }
        assert(
            cancelIndices.count <= 1,
            "Every alert template may declare at most one cancel button"
        )

        // A single NSButtonCell cannot own both Return and Escape: assigning
        // either key equivalent makes AppKit remove the other. Keep the
        // visible safe button as the native default (including its blue
        // appearance), and install zero-sized semantic proxies for any
        // additional cancellation shortcuts. The proxies forward the exact
        // NSAlert response tag and are excluded from accessibility.
        if let defaultIndex = defaultIndices.first,
           buttons.indices.contains(defaultIndex),
           let defaultCell = buttons[defaultIndex].cell as? NSButtonCell {
            alert.window.defaultButtonCell = defaultCell
        }
        if let cancelIndex = cancelIndices.first,
           buttons.indices.contains(cancelIndex) {
            let cancelButton = buttons[cancelIndex]
            if cancelIndex == defaultIndices.first {
                installShortcutProxy(
                    for: cancelButton,
                    keyEquivalent: "\u{1b}",
                    modifierMask: [],
                    in: alert
                )
            } else {
                cancelButton.keyEquivalent = "\u{1b}"
            }
            installShortcutProxy(
                for: cancelButton,
                keyEquivalent: ".",
                modifierMask: [.command],
                in: alert
            )
        }

        return alert
    }

    /// Adds an invisible keyboard-only button that forwards to an NSAlert
    /// button. Keeping it outside `alert.buttons` preserves response indices,
    /// layout, focus order, and VoiceOver output.
    @MainActor
    private func installShortcutProxy(
        for button: NSButton,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags,
        in alert: NSAlert
    ) {
        let proxy = NSButton(frame: .zero)
        proxy.target = button.target
        proxy.action = button.action
        proxy.tag = button.tag
        proxy.keyEquivalent = keyEquivalent
        proxy.keyEquivalentModifierMask = modifierMask
        proxy.isBordered = false
        proxy.isTransparent = true
        proxy.focusRingType = .none
        proxy.setAccessibilityElement(false)
        alert.window.contentView?.addSubview(proxy)
    }

    /// Presents this alert as a sheet attached to the window resolved from
    /// `context`. The sheet blocks only that window — other project windows
    /// remain fully interactive (issue #1241).
    ///
    /// When `context` has no live owner, the request fails closed with
    /// `.abort` and no detached dialog is shown.
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
        deduplicationKey: DialogRequestKey? = nil,
        messageText: String,
        informativeText: String? = nil
    ) async -> NSApplication.ModalResponse {
        await makeAlert(
            messageText: messageText,
            informativeText: informativeText
        ).runSheet(
            on: context,
            deduplicationKey: deduplicationKey
        )
    }
}

// MARK: - Template Configuration

extension AlertTemplate {
    /// The alert style for this template.
    private var style: NSAlert.Style {
        switch self {
        case .fileOperationErrorCritical:
            return .critical
        case .unsavedChangesSingle, .unsavedChangesBulk,
             .terminalTabCloseWarning, .terminalActiveProcessWarning,
             .applicationQuitSummary, .activeUserTasksPreventQuit,
             .applicationQuitFailure,
             .externalModifyConflict, .fileDeletedSaveAs,
             .fileOperationErrorWarning, .largeFileWarning,
             .branchUncommittedChanges, .revertAllConfirmation,
             .userTaskRunConfirmation, .userTaskOutputConflict,
             .userTaskNotice:
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
        case .applicationQuitSummary:
            return [
                Strings.applicationQuitReview,
                Strings.applicationQuitAnyway,
                Strings.dialogCancel,
            ]
        case .activeUserTasksPreventQuit:
            return [Strings.applicationQuitAnyway, Strings.dialogCancel]
        case .applicationQuitFailure:
            return [Strings.dialogOK]
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
        case .userTaskRunConfirmation:
            return [Strings.userTaskRun, Strings.dialogCancel]
        case .userTaskOutputConflict:
            return [
                Strings.dialogOK,
                Strings.userTaskCopyOutput,
                Strings.userTaskOpenOutput,
            ]
        case .userTaskNotice:
            return [Strings.dialogOK]
        }
    }

    /// Per-button roles, parallel to ``buttonTitles``.
    ///
    /// `.default`    — the Return/Enter action (Save, Keep, Cancel, …).
    /// `.cancel`     — Escape / ⌘-. target (Cancel, Keep). A single-button
    ///                 OK alert uses `.default` since there is nothing to cancel.
    /// `.destructive`— Don't Save / Discard / Quit — confirmed data loss.
    ///
    /// No template ever gives one button both `.destructive` and `.cancel`:
    /// Escape is how people dismiss dialogs without reading them. The
    /// crash-recovery sheet is the one dialog in Pine built in SwiftUI rather
    /// than from these templates, and it restates the same policy in
    /// `RecoveryDialogChoice` (#1503). Change either and check the other.
    private var buttonRoles: [AlertButtonRole] {
        switch self {
        case .unsavedChangesSingle, .unsavedChangesBulk:
            return [.default, .destructive, .cancel]
        case .terminalTabCloseWarning:
            return [.destructive, [.default, .cancel]]
        case .terminalActiveProcessWarning:
            return [.destructive, [.default, .cancel]]
        case .applicationQuitSummary:
            return [.default, .destructive, .cancel]
        case .activeUserTasksPreventQuit:
            return [.destructive, [.default, .cancel]]
        case .applicationQuitFailure:
            return [.default]
        case .externalModifyConflict:
            // Reload discards local edits (destructive); Keep is the safe default.
            return [.destructive, [.default, .cancel]]
        case .fileDeletedSaveAs:
            return [.default, .destructive, .cancel]
        case .fileOperationErrorCritical, .fileOperationErrorWarning:
            return [.default]
        case .largeFileWarning:
            return [.default, [], .cancel]
        case .branchUncommittedChanges:
            return [.destructive, [.default, .cancel]]
        case .revertAllConfirmation:
            return [.destructive, [.default, .cancel]]
        case .userTaskRunConfirmation:
            return [.destructive, [.default, .cancel]]
        case .userTaskOutputConflict:
            // Copy and Open are recovery offers, not the expected answer:
            // dismissing is. Neither is destructive — the buffer is already
            // safe, which is why this sheet exists — but neither should
            // happen because someone pressed Return to make a sheet go away.
            return [[.default, .cancel], [], []]
        case .userTaskNotice:
            return [.default]
        }
    }
}

// MARK: - Alert button role bridging

/// Semantic roles for an alert button. A safe secondary action can be both
/// the Return default and the Escape cancellation target.
struct AlertButtonRole: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    static let `default` = AlertButtonRole(rawValue: 1 << 0)
    static let cancel = AlertButtonRole(rawValue: 1 << 1)
    static let destructive = AlertButtonRole(rawValue: 1 << 2)
}
