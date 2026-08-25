import Foundation
import SwiftUI

/// Centralized UI strings for Pine.
/// Keys use stable dot-separated identifiers; English values live in
/// Localizable.xcstrings so renaming copy never breaks translation memory.
enum Strings {
    // MARK: - Settings

    static let settingsTabGeneral: LocalizedStringKey =
        "settings.tab.general"
    static let settingsTabTerminal: LocalizedStringKey =
        "settings.tab.terminal"
    static let settingsTabKeyBindings: LocalizedStringKey =
        "settings.tab.keyBindings"

    static let settingsGeneralTitle: LocalizedStringKey =
        "settings.general.title"
    static let settingsGeneralFormatting: LocalizedStringKey =
        "settings.general.formatting"
    static let settingsGeneralDisplay: LocalizedStringKey =
        "settings.general.display"
    static let settingsGeneralInsertFinalNewline: LocalizedStringKey =
        "settings.general.insertFinalNewline"
    static let settingsGeneralStripTrailingWhitespace: LocalizedStringKey =
        "settings.general.stripTrailingWhitespace"
    static let settingsGeneralAutoSave: LocalizedStringKey =
        "settings.general.autoSave"
    static let settingsGeneralFormatOnSave: LocalizedStringKey =
        "settings.general.formatOnSave"
    static let settingsGeneralSmartListContinuation: LocalizedStringKey =
        "settings.general.smartListContinuation"
    static let settingsGeneralWordWrap: LocalizedStringKey =
        "settings.general.wordWrap"
    static let settingsGeneralMinimap: LocalizedStringKey =
        "settings.general.minimap"
    static let settingsGeneralFontSize: LocalizedStringKey =
        "settings.general.fontSize"

    static let settingsTerminalTitle: LocalizedStringKey =
        "settings.terminal.title"
    static let settingsTerminalShell: LocalizedStringKey =
        "settings.terminal.shell"
    static let settingsTerminalShellPicker: LocalizedStringKey =
        "settings.terminal.shellPicker"
    static let settingsTerminalShellOther: LocalizedStringKey =
        "settings.terminal.shellOther"
    static let settingsTerminalShellPathPlaceholder: LocalizedStringKey =
        "settings.terminal.shellPathPlaceholder"
    static let settingsTerminalResolvedPrefix: LocalizedStringKey =
        "settings.terminal.resolvedPrefix"
    static let settingsTerminalArguments: LocalizedStringKey =
        "settings.terminal.arguments"
    static let settingsTerminalArgumentsHelp: LocalizedStringKey =
        "settings.terminal.argumentsHelp"
    static let settingsTerminalResetArgs: LocalizedStringKey =
        "settings.terminal.resetArgs"
    static let settingsTerminalQuickTerminal: LocalizedStringKey =
        "settings.terminal.quickTerminal"
    static let terminalCursorTitle: LocalizedStringKey =
        "settings.terminal.cursor.title"
    static let terminalCursorShape: LocalizedStringKey =
        "settings.terminal.cursor.shape"
    static let terminalCursorBlink: LocalizedStringKey =
        "settings.terminal.cursor.blink"
    static let terminalCursorHelp: LocalizedStringKey =
        "settings.terminal.cursor.help"

    static let settingsKeyBindingsTitle: LocalizedStringKey =
        "settings.keyBindings.title"
    static let settingsKeyBindingsKeybindings: LocalizedStringKey =
        "settings.keyBindings.keybindings"
    static let settingsKeyBindingsTasks: LocalizedStringKey =
        "settings.keyBindings.tasks"
    static let settingsKeyBindingsOpenFile: LocalizedStringKey =
        "settings.keyBindings.openFile"
    static let settingsKeyBindingsReload: LocalizedStringKey =
        "settings.keyBindings.reload"
    static let settingsKeyBindingsEffective: LocalizedStringKey =
        "settings.keyBindings.effective"
    static let settingsKeyBindingsNoOverrides: LocalizedStringKey =
        "settings.keyBindings.noOverrides"

    static func settingsKeyBindingsActiveCount(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        localizedPluralString(
            forKey: "settings.keyBindings.activeCount %lld",
            fallback: "%lld active entries",
            count: count,
            locale: locale
        )
    }

    static func settingsKeyBindingsReloadSummary(
        tasks: Int,
        keybindings: Int,
        locale: Locale = .current
    ) -> String {
        let taskCount = localizedPluralString(
            forKey: "settings.keyBindings.reload.taskCount %lld",
            fallback: "%lld tasks",
            count: tasks,
            locale: locale
        )
        let keybindingCount = localizedPluralString(
            forKey: "settings.keyBindings.reload.keybindingCount %lld",
            fallback: "%lld key bindings",
            count: keybindings,
            locale: locale
        )
        let format = localizedString(
            forKey: "settings.keyBindings.reload.success %@ %@",
            fallback: "Reloaded: %1$@, %2$@.",
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            arguments: [taskCount, keybindingCount]
        )
    }

    static func settingsKeyBindingsReloadProblems(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        localizedPluralString(
            forKey: "settings.keyBindings.reload.problemCount %lld",
            fallback: "Reloaded with %lld problems.",
            count: count,
            locale: locale
        )
    }

    static let settingsLanguageServersTab: LocalizedStringKey =
        "settings.tab.languageServers"
    static let settingsAgentHandoffTab: LocalizedStringKey =
        "settings.tab.agentHandoff"
    static let settingsTerminalTab: LocalizedStringKey =
        "settings.tab.terminal"
    static let agentHandoffSettingsTitle: LocalizedStringKey =
        "settings.agentHandoff.title"
    static let agentHandoffReadOnlyContext: LocalizedStringKey =
        "settings.agentHandoff.readOnlyContext"
    static let agentHandoffReadOnlyContextHelp: LocalizedStringKey =
        "settings.agentHandoff.readOnlyContext.help"
    static let agentHandoffSecurityBoundary: LocalizedStringKey =
        "settings.agentHandoff.securityBoundary"
    static let agentHandoffMetadataOnly: LocalizedStringKey =
        "settings.agentHandoff.metadataOnly"
    static let agentHandoffNoMutation: LocalizedStringKey =
        "settings.agentHandoff.noMutation"
    static let agentHandoffNewTerminals: LocalizedStringKey =
        "settings.agentHandoff.newTerminals"
    static let agentHandoffStatusEnabled: LocalizedStringKey =
        "settings.agentHandoff.status.enabled"
    static let agentHandoffStatusDisabled: LocalizedStringKey =
        "settings.agentHandoff.status.disabled"

    static let lspSettingsTitle: LocalizedStringKey =
        "settings.lsp.title"
    static let lspEnabled: LocalizedStringKey =
        "settings.lsp.enabled"
    static let lspEnabledHelp: LocalizedStringKey =
        "settings.lsp.enabled.help"
    static let lspLanguages: LocalizedStringKey =
        "settings.lsp.languages"
    static let lspExecutablePlaceholder: LocalizedStringKey =
        "settings.lsp.executable.placeholder"
    static let lspCustomArguments: LocalizedStringKey =
        "settings.lsp.arguments.custom"
    static let lspArgumentsHelp: LocalizedStringKey =
        "settings.lsp.arguments.help"
    static let lspDirectLaunchHelp: LocalizedStringKey =
        "settings.lsp.directLaunch.help"
    static let lspChooseExecutable: LocalizedStringKey =
        "settings.lsp.executable.choose"
    static var lspChooseExecutablePrompt: String {
        lspChooseExecutablePrompt(locale: .current)
    }

    static func lspChooseExecutablePrompt(locale: Locale) -> String {
        localizedString(
            forKey: "settings.lsp.executable.prompt",
            fallback: "Choose",
            locale: locale
        )
    }
    static let lspReset: LocalizedStringKey =
        "settings.lsp.reset"

    // MARK: - Quick Terminal settings (#1243)

    static let settingsQuickTerminalTab: LocalizedStringKey =
        "settings.tab.quickTerminal"
    static let quickTerminalSettingsTitle: LocalizedStringKey =
        "settings.quickTerminal.title"
    static let quickTerminalEnabled: LocalizedStringKey =
        "settings.quickTerminal.enabled"
    static let quickTerminalEnabledHelp: LocalizedStringKey =
        "settings.quickTerminal.enabled.help"
    static let quickTerminalHotkey: LocalizedStringKey =
        "settings.quickTerminal.hotkey"
    static let quickTerminalHotkeyHelp: LocalizedStringKey =
        "settings.quickTerminal.hotkey.help"
    static let quickTerminalRecordingHotkey: LocalizedStringKey =
        "settings.quickTerminal.hotkey.recording"
    static let quickTerminalHotkeyModifierRequired: LocalizedStringKey =
        "settings.quickTerminal.hotkey.modifierRequired"
    static let quickTerminalScreenEdge: LocalizedStringKey =
        "settings.quickTerminal.screenEdge"
    static let quickTerminalEdgeTop: LocalizedStringKey =
        "settings.quickTerminal.edge.top"
    static let quickTerminalEdgeBottom: LocalizedStringKey =
        "settings.quickTerminal.edge.bottom"
    static let quickTerminalEdgeLeft: LocalizedStringKey =
        "settings.quickTerminal.edge.left"
    static let quickTerminalEdgeRight: LocalizedStringKey =
        "settings.quickTerminal.edge.right"
    static let quickTerminalSize: LocalizedStringKey =
        "settings.quickTerminal.size"
    static let quickTerminalTargetDisplay: LocalizedStringKey =
        "settings.quickTerminal.targetDisplay"
    static let quickTerminalDisplayActive: LocalizedStringKey =
        "settings.quickTerminal.display.active"
    static let quickTerminalDisplayMain: LocalizedStringKey =
        "settings.quickTerminal.display.main"
    static let quickTerminalHideOnFocusLoss: LocalizedStringKey =
        "settings.quickTerminal.hideOnFocusLoss"
    static let quickTerminalHideOnFocusLossHelp: LocalizedStringKey =
        "settings.quickTerminal.hideOnFocusLoss.help"
    static let quickTerminalReset: LocalizedStringKey =
        "settings.quickTerminal.reset"

    // MARK: - Editor

    static let noFileSelected: LocalizedStringKey = "editor.noFileSelected"
    static let selectFilePrompt: LocalizedStringKey = "editor.selectFilePrompt"

    // MARK: - Sidebar

    static let noFolderOpen: LocalizedStringKey = "sidebar.noFolderOpen"
    static let openFolderPrompt: LocalizedStringKey = "sidebar.openFolderPrompt"
    static let openFolderButton: LocalizedStringKey = "sidebar.openFolderButton"
    static let filesTitle: LocalizedStringKey = "sidebar.filesTitle"
    static let openFolderTooltip: LocalizedStringKey = "sidebar.openFolderTooltip"

    // MARK: - Context Menu

    static let contextNewFile: LocalizedStringKey = "context.newFile"
    static let contextNewFolder: LocalizedStringKey = "context.newFolder"
    static let contextDuplicate: LocalizedStringKey = "context.duplicate"
    static let contextRename: LocalizedStringKey = "context.rename"
    static let contextDelete: LocalizedStringKey = "context.delete"
    static let contextRevealInFinder: LocalizedStringKey = "context.revealInFinder"

    static var contextNewFileTitle: String {
        String(localized: "context.newFile.title")
    }

    static var contextNewFolderTitle: String {
        String(localized: "context.newFolder.title")
    }

    static var contextRenameTitle: String {
        String(localized: "context.rename.title")
    }

    static var contextDeleteConfirmTitle: String {
        String(localized: "context.delete.confirmTitle")
    }

    static func contextDeleteConfirmMessage(_ name: String) -> String {
        String(localized: "context.delete.confirmMessage \(name)")
    }

    static var contextNamePlaceholder: String {
        String(localized: "context.namePlaceholder")
    }

    static var contextDeleteButton: String {
        String(localized: "context.delete")
    }

    // MARK: - File Operation Errors / Prompts

    static var fileOperationErrorTitle: String {
        String(localized: "fileOperation.error.title")
    }

    static func fileCreateError(_ name: String) -> String {
        String(localized: "fileOperation.createError \(name)")
    }

    static var undoDelete: String {
        String(localized: "undo.delete")
    }

    static var undoRename: String {
        String(localized: "undo.rename")
    }

    static var undoCreate: String {
        String(localized: "undo.create")
    }

    static var operationOutsideProject: String {
        String(localized: "fileOperation.outsideProject")
    }

    static var renameErrorEmpty: String {
        String(localized: "rename.error.empty")
    }

    static var renameErrorInvalidCharacters: String {
        String(localized: "rename.error.invalidCharacters")
    }

    static func renameErrorDuplicate(_ name: String) -> String {
        String(localized: "rename.error.duplicate \(name)")
    }

    static var fileDeletedTitle: String {
        String(localized: "fileOperation.deleted.title")
    }

    static var fileDeletedMessage: String {
        String(localized: "fileOperation.deleted.message")
    }

    static var fileDeletedSaveAs: String {
        String(localized: "fileOperation.deleted.saveAs")
    }

    // MARK: - External Change Conflicts

    static var externalModifyTitle: String {
        String(localized: "conflict.externalModify.title")
    }

    static func externalModifyMessage(_ name: String) -> String {
        String(localized: "conflict.externalModify.message \(name)")
    }

    static var externalModifyReload: String {
        String(localized: "conflict.externalModify.reload")
    }

    static var externalModifyKeep: String {
        String(localized: "conflict.externalModify.keep")
    }

    // MARK: - Terminal UI

    static let terminalLabel: LocalizedStringKey = "terminal.label"

    static func terminalLabelText(locale: Locale = .current) -> String {
        localizedString(
            forKey: "terminal.label",
            fallback: "Terminal",
            locale: locale
        )
    }

    static let newTerminal: LocalizedStringKey = "terminal.new"
    static let hideTerminal: LocalizedStringKey = "terminal.hide"
    static let restoreTerminal: LocalizedStringKey = "terminal.restore"
    static let maximizeTerminal: LocalizedStringKey = "terminal.maximize"
    static let hideTerminalShortcut: LocalizedStringKey = "terminal.hideShortcut"
    static let showTerminalShortcut: LocalizedStringKey = "terminal.showShortcut"
    static let toggleTerminal: LocalizedStringKey = "terminal.toggle"

    // MARK: - Terminal theme settings (#1244)

    static let terminalThemeSettingsTitle: LocalizedStringKey =
        "settings.terminal.theme.title"
    static let terminalThemeSettingsSubtitle: LocalizedStringKey =
        "settings.terminal.theme.subtitle"
    static let terminalThemeSelectionLabel: LocalizedStringKey =
        "settings.terminal.theme.selectionLabel"
    static let terminalAppearanceLabel: LocalizedStringKey =
        "settings.terminal.appearance.label"
    static let terminalAppearanceHelp: LocalizedStringKey =
        "settings.terminal.appearance.help"
    static let terminalThemePreviewLabel: LocalizedStringKey =
        "settings.terminal.theme.previewLabel"

    // MARK: - Status bar (agent awareness, #952)

    static func statusbarActiveAgentCount(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        localizedPluralString(
            forKey: "statusbar.activeAgentCount %lld",
            fallback: "%lld agents active",
            count: count,
            locale: locale
        )
    }

    static func statusbarAgentSessionCount(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        localizedPluralString(
            forKey: "statusbar.agentSessionCount %lld",
            fallback: "%lld agent sessions",
            count: count,
            locale: locale
        )
    }

    // MARK: - Agent liveness (#933)

    static var agentLivenessLive: String {
        agentLivenessLive(locale: .current)
    }

    static var agentLivenessStale: String {
        agentLivenessStale(locale: .current)
    }

    static var agentLivenessTerminated: String {
        agentLivenessTerminated(locale: .current)
    }

    static func agentLivenessLive(locale: Locale) -> String {
        localizedString(
            forKey: "agent.liveness.live",
            fallback: "Live",
            locale: locale
        )
    }

    static func agentLivenessStale(locale: Locale) -> String {
        localizedString(
            forKey: "agent.liveness.stale",
            fallback: "Stale",
            locale: locale
        )
    }

    static func agentLivenessTerminated(locale: Locale) -> String {
        localizedString(
            forKey: "agent.liveness.terminated",
            fallback: "Terminated",
            locale: locale
        )
    }

    // MARK: - Agent Activity Panel (#1072)
    static let menuAgentActivity: LocalizedStringKey = "menu.agentActivity"
    static let agentActivityTitle: LocalizedStringKey = "agentActivity.title"
    static let agentActivityClose: LocalizedStringKey = "agentActivity.close"
    static let agentActivityEmpty: LocalizedStringKey = "agentActivity.empty"
    static let agentActivityNoMatches: LocalizedStringKey =
        "agentActivity.noMatches"
    static let agentActivityAttributionFilterLabel: LocalizedStringKey =
        "agentActivity.attribution.filterLabel"
    static var agentActivityAttributionInferred: String {
        String(localized: "agentActivity.attribution.inferred", defaultValue: "Inferred")
    }
    static var agentActivityAttributionVerified: String {
        String(localized: "agentActivity.attribution.verified", defaultValue: "Verified")
    }
    static var agentActivityAttributionSessionLinked: String {
        String(
            localized: "agentActivity.attribution.sessionLinked",
            defaultValue: "Session-linked"
        )
    }
    static var agentActivityAttributionAmbiguous: String {
        String(localized: "agentActivity.attribution.ambiguous", defaultValue: "Ambiguous")
    }
    static var agentActivityAttributionStale: String {
        String(localized: "agentActivity.attribution.stale", defaultValue: "Stale")
    }
    static var agentActivityAttributionTerminated: String {
        String(
            localized: "agentActivity.attribution.terminated",
            defaultValue: "Terminated"
        )
    }
    static var agentActivityVerifiedHint: String {
        String(
            localized: "agentActivity.attribution.verifiedHint",
            defaultValue: "Validated by Pine's trusted structured event pipeline"
        )
    }
    static var agentActivitySessionLinkedHint: String {
        String(
            localized: "agentActivity.attribution.sessionLinkedHint",
            defaultValue: """
            Linked to a session by legacy activity data; this is not a verified agent event
            """
        )
    }
    static var agentActivityInferredHint: String {
        String(
            localized: "agentActivity.attribution.inferredHint",
            defaultValue: "Inferred from file-system timing; no verified agent event is available"
        )
    }
    static var agentActivityAmbiguousHint: String {
        String(
            localized: "agentActivity.attribution.ambiguousHint",
            defaultValue: "Multiple active sessions could match; no agent is identified as the owner"
        )
    }
    static var agentActivityStaleHint: String {
        String(
            localized: "agentActivity.attribution.staleHint",
            defaultValue: "The associated process has not been observed successfully recently"
        )
    }
    static var agentActivityTerminatedHint: String {
        String(
            localized: "agentActivity.attribution.terminatedHint",
            defaultValue: "The associated process is no longer running"
        )
    }
    static func agentActivityPossibleSessions(_ count: Int) -> String {
        String(localized: "agentActivity.possibleSessions \(count)")
    }
    static func agentActivityFileChanged(_ name: String) -> String {
        String(localized: "agentActivity.fileChanged \(name)")
    }
    static let agentActivityResetFilters: LocalizedStringKey = "agentActivity.resetFilters"
    static var agentActivityAllAttributions: String {
        String(
            localized: "agentActivity.allAttributions",
            defaultValue: "All evidence"
        )
    }
    static var agentActivityAllKinds: String {
        String(localized: "agentActivity.allKinds", defaultValue: "All kinds")
    }
    static var agentActivityAllStatuses: String {
        String(localized: "agentActivity.allStatuses", defaultValue: "All statuses")
    }
    static var agentActivityDetailCopied: LocalizedStringKey { "agentActivity.detail.copied" }
    static var agentActivityDetailCopy: LocalizedStringKey { "agentActivity.detail.copy" }
    static var agentActivityDetailGoToTerminal: LocalizedStringKey { "agentActivity.detail.goToTerminal" }
    static var agentActivityDetailOpenFile: LocalizedStringKey { "agentActivity.detail.openFile" }
    static var agentActivityRowInspectHint: String {
        String(localized: "agentActivity.rowInspectHint", defaultValue: "Inspect this action")
    }

    // MARK: - Agent Action kinds, statuses & detail labels (#1245)
    static var agentActionKindFileWrite: String {
        String(localized: "agentAction.kind.fileWrite", defaultValue: "File write")
    }
    static var agentActionKindFileRead: String {
        String(localized: "agentAction.kind.fileRead", defaultValue: "File read")
    }
    static var agentActionKindCommand: String {
        String(localized: "agentAction.kind.command", defaultValue: "Command")
    }
    static var agentActionKindToolCall: String {
        String(localized: "agentAction.kind.toolCall", defaultValue: "Tool call")
    }
    static var agentActionStatusPending: String {
        String(localized: "agentAction.status.pending", defaultValue: "Pending")
    }
    static var agentActionStatusInProgress: String {
        String(localized: "agentAction.status.inProgress", defaultValue: "In progress")
    }
    static var agentActionStatusCompleted: String {
        String(localized: "agentAction.status.completed", defaultValue: "Completed")
    }
    static var agentActionStatusFailed: String {
        String(localized: "agentAction.status.failed", defaultValue: "Failed")
    }
    static var agentActionDetailSummaryLabel: String {
        String(localized: "agentAction.detail.summaryLabel", defaultValue: "Summary")
    }
    static var agentActionDetailKindLabel: String {
        String(localized: "agentAction.detail.kindLabel", defaultValue: "Kind")
    }
    static var agentActionDetailStatusLabel: String {
        String(localized: "agentAction.detail.statusLabel", defaultValue: "Status")
    }
    static var agentActionDetailFileLabel: String {
        String(localized: "agentAction.detail.fileLabel", defaultValue: "File")
    }
    static var agentActionDetailEvidenceLabel: String {
        String(localized: "agentAction.detail.evidenceLabel", defaultValue: "Evidence")
    }
    static var agentActionDetailWorkingDirectoryLabel: String {
        String(localized: "agentAction.detail.workingDirectoryLabel", defaultValue: "Working directory")
    }
    static var agentActionDetailRelatedTerminalLabel: String {
        String(localized: "agentAction.detail.relatedTerminalLabel", defaultValue: "Related terminal")
    }
    static var agentActionDetailTimestampLabel: String {
        String(localized: "agentAction.detail.timestampLabel", defaultValue: "Timestamp")
    }

    // MARK: - Agent state labels (#1245)
    static func agentStateIdle(locale: Locale = .current) -> String {
        localizedString(forKey: "agentState.idle", fallback: "Idle", locale: locale)
    }
    static func agentStateThinking(locale: Locale = .current) -> String {
        localizedString(forKey: "agentState.thinking", fallback: "Thinking", locale: locale)
    }
    static func agentStateExecuting(locale: Locale = .current) -> String {
        localizedString(forKey: "agentState.executing", fallback: "Executing", locale: locale)
    }
    static func agentStateWaitingInput(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentState.waitingInput",
            fallback: "Waiting for input",
            locale: locale
        )
    }
    static func agentStateDone(locale: Locale = .current) -> String {
        localizedString(forKey: "agentState.done", fallback: "Done", locale: locale)
    }

    // MARK: - Agent Attention overlay (#1112)
    static let agentAttentionTitle: LocalizedStringKey = "agentAttention.title"
    static let agentAttentionEmpty: LocalizedStringKey = "agentAttention.empty"

    // MARK: - Cross-project Agent Inbox (#1305)
    static let menuAgentInbox: LocalizedStringKey = "menu.agentInbox"
    static let agentInboxTitle: LocalizedStringKey = "menu.agentInbox"
    static let agentInboxEmpty: LocalizedStringKey = "agentInbox.empty"
    static let agentInboxNeedsAttention: LocalizedStringKey =
        "agentInbox.section.needsAttention"
    static let agentInboxFailed: LocalizedStringKey =
        "agentInbox.section.failed"
    static let agentInboxCompletedUnread: LocalizedStringKey =
        "agentInbox.section.completedUnread"
    static let agentInboxWorking: LocalizedStringKey =
        "agentInbox.section.working"
    static let agentInboxHistory: LocalizedStringKey =
        "agentInbox.section.history"
    static let agentInboxLastVerified: LocalizedStringKey =
        "agentInbox.lastVerified"
    static let agentInboxOpen: LocalizedStringKey = "agentInbox.open"
    static let agentInboxMarkRead: LocalizedStringKey =
        "agentInbox.markRead"
    static let agentInboxMarkUnread: LocalizedStringKey =
        "agentInbox.markUnread"
    static func agentInboxUnread(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentInbox.unread",
            fallback: "Unread",
            locale: locale
        )
    }
    static let agentInboxDismiss: LocalizedStringKey = "agentInbox.dismiss"
    static let agentInboxRouteUnavailable: LocalizedStringKey =
        "agentInbox.routeUnavailable"
    static let agentInboxResumeSession: LocalizedStringKey =
        "agentInbox.resumeSession"
    static let agentInboxNewSession: LocalizedStringKey =
        "agentInbox.newSession"
    static let agentInboxCopyObjective: LocalizedStringKey =
        "agentInbox.copyObjective"
    static let agentInboxOpenedNewSession: LocalizedStringKey =
        "agentInbox.openedNewSession"
    static let agentInboxResumedSession: LocalizedStringKey =
        "agentInbox.resumedSession"
    static let agentInboxRouteUnavailableNextStep: LocalizedStringKey =
        "agentInbox.routeUnavailable.nextStep"

    /// Resolved `String` forms of the two Inbox action failures, for the
    /// VoiceOver announcement that accompanies the on-screen status. An
    /// 11-point caption at the bottom of a 540-point popover is not feedback
    /// a screen-reader user receives on its own.
    static func agentInboxRouteUnavailableText(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentInbox.routeUnavailable",
            fallback: "Exact session is no longer available",
            locale: locale
        )
    }

    static func agentInboxRouteUnavailableNextStepText(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentInbox.routeUnavailable.nextStep",
            fallback:
                "Recover the task to start a new session in the same worktree",
            locale: locale
        )
    }

    // MARK: - Agent recovery failures (#1541)

    /// The sentence naming what stopped one recovery attempt.
    ///
    /// Keyed off ``AgentRecoveryFailure`` instead of written out as thirteen
    /// stored properties, so a case added to that enum reaches the catalog
    /// through one place and the enum's own test can walk every case.
    static func agentRecoveryCause(
        _ failure: AgentRecoveryFailure
    ) -> LocalizedStringKey {
        LocalizedStringKey(failure.causeKey)
    }

    /// Resolved form of ``agentRecoveryCause(_:)``, for the VoiceOver
    /// announcement that accompanies the on-screen caption.
    static func agentRecoveryCauseText(
        _ failure: AgentRecoveryFailure,
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: failure.causeKey,
            fallback: agentRecoveryCauseFallback(failure),
            locale: locale
        )
    }

    /// The sentence telling the user what to do about that failure.
    static func agentRecoveryNextStep(
        _ failure: AgentRecoveryFailure
    ) -> LocalizedStringKey {
        LocalizedStringKey(failure.nextStepKey)
    }

    /// Resolved form of ``agentRecoveryNextStep(_:)``.
    static func agentRecoveryNextStepText(
        _ failure: AgentRecoveryFailure,
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: failure.nextStepKey,
            fallback: agentRecoveryNextStepFallback(failure),
            locale: locale
        )
    }

    private static func agentRecoveryCauseFallback(
        _ failure: AgentRecoveryFailure
    ) -> String {
        switch failure {
        case .taskGone:
            "This task is no longer in the Inbox"
        case .projectWindowUnavailable:
            "Pine could not open this task\u{2019}s project window"
        case .changedWhilePreparing:
            "The task changed while Pine was preparing to recover it"
        case .launchRejected:
            "The terminal refused to start the recovery session"
        case .notRecoverable:
            "This task is not in a state Pine can recover"
        case .projectFolderMissing:
            "The project folder recorded for this task no longer exists"
        case .worktreeMissing:
            "The worktree recorded for this task no longer exists"
        case .agentExecutableMissing:
            "The agent\u{2019}s command line tool is no longer installed"
        case .adapterUnavailable:
            "Pine has no reviewed way to resume this agent\u{2019}s session"
        case .sessionIdentityMissing:
            "This run recorded no session to resume"
        case .sessionIdentityInvalid:
            "The recorded session identifier failed validation"
        case .versionProbeFailed:
            "Pine could not read the agent\u{2019}s version"
        case .versionChanged:
            "The agent\u{2019}s version changed since this task ran"
        }
    }

    private static func agentRecoveryNextStepFallback(
        _ failure: AgentRecoveryFailure
    ) -> String {
        switch failure {
        case .taskGone:
            "It was dismissed or removed, so nothing is left to recover"
        case .projectWindowUnavailable, .projectFolderMissing:
            "Open the project folder again, then retry from the Inbox"
        case .changedWhilePreparing:
            "Try the same action again from the Inbox"
        case .launchRejected:
            "Open a terminal in the project and start the agent yourself"
        case .notRecoverable:
            "Use Open to go to the session that is still running"
        case .worktreeMissing:
            "Restore the worktree, or start the agent in the project folder"
        case .agentExecutableMissing, .adapterUnavailable,
             .sessionIdentityMissing, .sessionIdentityInvalid,
             .versionProbeFailed, .versionChanged:
            "Start a new session in the same worktree instead"
        }
    }

    static let agentInboxRecoveryActions: LocalizedStringKey =
        "agentInbox.recoveryActions"
    static let agentInboxShowRecoveryActions: LocalizedStringKey =
        "agentInbox.showRecoveryActions"
    static func agentInboxRecoveryActionsShown(
        defaultAction: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "agentInbox.recoveryActionsShown",
            fallback: "Recovery actions shown. Default action: %@",
            locale: locale
        )
        return String(format: format, locale: locale, defaultAction)
    }

    // MARK: - Agent Inbox toolbar button (#1337)
    static let agentInboxToolbarTooltip: LocalizedStringKey =
        "agentInbox.toolbar.tooltip"

    /// Resolved `String` form of ``agentInboxToolbarTooltip``.
    static func agentInboxToolbarTooltipText(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentInbox.toolbar.tooltip",
            fallback: "Open the Agent Inbox",
            locale: locale
        )
    }

    /// Resolved `String` form of ``agentInboxTitle``, for composing VoiceOver
    /// labels — a `LocalizedStringKey` cannot be interpolated into one.
    static func agentInboxTitleText(locale: Locale = .current) -> String {
        localizedString(
            forKey: "menu.agentInbox",
            fallback: "Agent Inbox",
            locale: locale
        )
    }

    static func agentInboxToolbarAttentionCount(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        localizedPluralString(
            forKey: "agentInbox.toolbar.attentionCount %lld",
            fallback: "%lld tasks need attention",
            count: count,
            locale: locale
        )
    }

    /// Joins a lead phrase (the Inbox name, or the tooltip) with the
    /// pluralized attention phrase. Kept as a localizable format rather than a
    /// hardcoded `", "` so languages that order the two parts differently can
    /// swap `%1$@` and `%2$@`.
    static func agentInboxToolbarJoined(
        lead: String,
        attention: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "agentInbox.toolbar.joined %@ %@",
            fallback: "%1$@, %2$@",
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            arguments: [lead, attention]
        )
    }

    // MARK: - Project switcher
    static let projectSwitcherTooltip: LocalizedStringKey =
        "projectSwitcher.tooltip"
    static let projectSwitcherNewAgent: LocalizedStringKey =
        "projectSwitcher.newAgent"
    static let projectSwitcherNoAgents: LocalizedStringKey =
        "projectSwitcher.noAgents"

    /// Names the project being closed, so the menu item is unambiguous in a
    /// window holding several.
    static func projectSwitcherCloseProjectTitle(
        _ projectName: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "projectSwitcher.closeProject %@",
            fallback: "Close “%@”",
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            arguments: [projectName]
        )
    }
    static let projectSwitcherErrorTitle: LocalizedStringKey =
        "projectSwitcher.error.title"
    static var projectSwitcherAlreadyOpenText: String {
        String(
            localized: "projectSwitcher.error.alreadyOpen",
            defaultValue: "This project is already open in another window."
        )
    }

    static func projectSwitcherOpenFailureText(
        _ projectName: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "projectSwitcher.error.open %@",
            fallback: "Pine couldn’t open “%@”.",
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            arguments: [projectName]
        )
    }

    static func projectSwitcherAgentMissingText(
        _ agentName: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "projectSwitcher.error.agentMissing %@",
            fallback: "%@ is no longer available on this Mac.",
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            arguments: [agentName]
        )
    }

    static func projectSwitcherWorktreeFailureText(
        _ reason: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "projectSwitcher.error.worktree %@",
            fallback: "Pine couldn’t create an isolated worktree. %@",
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            arguments: [reason]
        )
    }

    static func projectSwitcherAgentLaunchFailureText(
        _ agentName: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "projectSwitcher.error.launch %@",
            fallback: "Pine created the worktree, but couldn’t start %@.",
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            arguments: [agentName]
        )
    }

    // MARK: - Agent notifications (#1306)
    static let agentNotificationsSettingsTitle: LocalizedStringKey =
        "agentNotifications.settings.title"
    static let agentNotificationsPermissionExplanation: LocalizedStringKey =
        "agentNotifications.permission.explanation"
    static let agentNotificationsEnable: LocalizedStringKey =
        "agentNotifications.permission.enable"
    static let agentNotificationsDenied: LocalizedStringKey =
        "agentNotifications.permission.denied"
    static let agentNotificationsOpenSystemSettings: LocalizedStringKey =
        "agentNotifications.permission.openSettings"
    static let agentNotificationsMainToggle: LocalizedStringKey =
        "agentNotifications.master"
    static let agentNotificationsEvents: LocalizedStringKey =
        "agentNotifications.events"
    static let agentNotificationsWaiting: LocalizedStringKey =
        "agentNotifications.event.waiting"
    static let agentNotificationsFailed: LocalizedStringKey =
        "agentNotifications.event.failed"
    static let agentNotificationsCompleted: LocalizedStringKey =
        "agentNotifications.event.completed"
    static let agentNotificationsProcessEnded: LocalizedStringKey =
        "agentNotifications.event.processEnded"
    static let agentNotificationsAgents: LocalizedStringKey =
        "agentNotifications.agents"
    static let agentNotificationsProjects: LocalizedStringKey =
        "agentNotifications.projects"
    static let agentNotificationsTasks: LocalizedStringKey =
        "agentNotifications.tasks"
    static let agentNotificationsFocusHelp: LocalizedStringKey =
        "agentNotifications.focusHelp"

    // MARK: - Agent History & Undo (#1073)
    static let menuAgentHistory: LocalizedStringKey = "menu.agentHistory"
    static let agentHistoryTitle: LocalizedStringKey = "agentHistory.title"
    static let agentHistoryEmptyTitle: LocalizedStringKey = "agentHistory.emptyTitle"
    static let agentHistoryEmptyMessage: LocalizedStringKey = "agentHistory.emptyMessage"
    static let agentHistoryRevertedBadge: LocalizedStringKey = "agentHistory.revertedBadge"
    static let agentHistoryRevertButton: LocalizedStringKey = "agentHistory.revertButton"
    static let agentHistoryReviewChangesButton: LocalizedStringKey =
        "agentHistory.reviewChangesButton"
    static let agentCompletionTitle: LocalizedStringKey =
        "agentCompletion.title"
    static let agentCompletionShowButton: LocalizedStringKey =
        "agentCompletion.showButton"
    static let agentCompletionChanges: LocalizedStringKey =
        "agentCompletion.changes"
    static let agentCompletionVerification: LocalizedStringKey =
        "agentCompletion.verification"
    static let agentCompletionCommands: LocalizedStringKey =
        "agentCompletion.commands"
    static let agentCompletionGaps: LocalizedStringKey =
        "agentCompletion.gaps"
    static let agentCompletionAgentReport: LocalizedStringKey =
        "agentCompletion.agentReport"
    static let agentCompletionNoChanges: LocalizedStringKey =
        "agentCompletion.noChanges"
    static let agentCompletionNoCommands: LocalizedStringKey =
        "agentCompletion.noCommands"
    static let agentCompletionOverlap: LocalizedStringKey =
        "agentCompletion.overlap"

    static func agentCompletionVerifiedTests(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "agentCompletion.verifiedTests %lld",
            fallback: "%lld verified test runs",
            locale: locale
        )
        return String(format: format, locale: locale, Int64(count))
    }

    static func agentCompletionObserved(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentCompletion.evidence.observed",
            fallback: "Observed",
            locale: locale
        )
    }

    static func agentCompletionAgentReported(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentCompletion.evidence.agentReported",
            fallback: "Agent-reported",
            locale: locale
        )
    }

    static func agentCompletionGapProvenance(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentCompletion.gap.provenance",
            fallback: "Structured provenance is unavailable.",
            locale: locale
        )
    }

    static func agentCompletionGapRecovered(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentCompletion.gap.recovered",
            fallback: "Provenance was recovered and may be incomplete.",
            locale: locale
        )
    }

    static func agentCompletionGapChanges(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentCompletion.gap.changes",
            fallback: "No file changes have verified attribution.",
            locale: locale
        )
    }

    static func agentCompletionGapCommands(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentCompletion.gap.commands",
            fallback: "No commands have structured evidence.",
            locale: locale
        )
    }

    static func agentCompletionGapTests(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentCompletion.gap.tests",
            fallback: "No successful test run has verified evidence.",
            locale: locale
        )
    }

    static func agentCompletionGapStatistics(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "agentCompletion.gap.statistics %lld",
            fallback: "Exact diff statistics are unavailable for %lld files.",
            locale: locale
        )
        return String(format: format, locale: locale, Int64(count))
    }

    static func agentCompletionGapOverlaps(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "agentCompletion.gap.overlaps %lld",
            fallback: "%lld files have overlapping or ambiguous edits.",
            locale: locale
        )
        return String(format: format, locale: locale, Int64(count))
    }
    static let agentHistoryUndoUnavailable: LocalizedStringKey = "agentHistory.undoUnavailable"
    static let agentHistoryUndoUnavailableReason: LocalizedStringKey = "agentHistory.undoUnavailableReason"
    static let agentHistoryRevertConfirmTitle: LocalizedStringKey = "agentHistory.revertConfirmTitle"
    static let agentHistoryRevertConfirmAction: LocalizedStringKey = "agentHistory.revertConfirmAction"
    static let agentHistoryRevertConfirmMessage: LocalizedStringKey = "agentHistory.revertConfirmMessage"
    static let agentHistoryRevertSuccess: LocalizedStringKey = "agentHistory.revertSuccess"
    static let agentHistoryRevertPartialFailure: LocalizedStringKey = "agentHistory.revertPartialFailure"
    // Checked (verified) undo — #1183.
    static let agentHistoryCheckedRevertConfirmMessage: LocalizedStringKey = "agentHistory.checkedRevertConfirmMessage"
    static let agentHistoryCheckedRevertSuccess: LocalizedStringKey = "agentHistory.checkedRevertSuccess"
    static let agentHistoryRecoveryNoticeTitle: LocalizedStringKey =
        "agentHistory.recoveryNoticeTitle"
    static let agentHistoryRecoveryNoticeInstruction: LocalizedStringKey =
        "agentHistory.recoveryNoticeInstruction"
    static let agentHistoryRecoveryNoticePrepared: LocalizedStringKey =
        "agentHistory.recoveryNoticePrepared"
    static let agentHistoryRecoveryAuthorityConsumed: LocalizedStringKey =
        "agentHistory.recoveryNoticeAuthorityConsumed"
    static let agentHistoryRecoveryNoticeFinalized: LocalizedStringKey =
        "agentHistory.recoveryNoticeFinalized"
    /// The status line for a recovery record that failed validation.
    ///
    /// One key per corruption reason. All seven used to render as a single
    /// "Corrupt or untrusted recovery data", which told the user nothing
    /// about whether the folder had moved, failed its ownership checks, or
    /// simply carried a manifest this build cannot read (#1541).
    static func agentHistoryRecoveryCorruption(
        _ corruption: AgentHistoryRecoveryCorruption
    ) -> LocalizedStringKey {
        // Through a `String` binding on purpose: writing the interpolation
        // inside `LocalizedStringKey(...)` picks the interpolation
        // initializer, which builds the key "…Corrupt.%@" plus an argument
        // and looks up a key the catalog does not contain.
        let key = corruption.noticeKey
        return LocalizedStringKey(key)
    }

    /// Resolved form of ``agentHistoryRecoveryCorruption(_:)``.
    static func agentHistoryRecoveryCorruptionText(
        _ corruption: AgentHistoryRecoveryCorruption,
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: corruption.noticeKey,
            fallback: agentHistoryRecoveryCorruptionFallback(corruption),
            locale: locale
        )
    }

    private static func agentHistoryRecoveryCorruptionFallback(
        _ corruption: AgentHistoryRecoveryCorruption
    ) -> String {
        switch corruption {
        case .invalidRecoveryRoot:
            "Recovery folder is not in its expected location"
        case .enumerationLimitExceeded:
            "Recovery folder exceeds the safe scan limit"
        case .untrustedDirectory:
            "Recovery folder failed its ownership checks"
        case .invalidManifest:
            "Recovery manifest could not be read"
        case .invalidPhaseMarkers:
            "Recovery phase markers are inconsistent"
        case .invalidRecoveryMetadata:
            "Recovery metadata could not be read"
        case .invalidWorkspaceArtifacts:
            "Retained workspace files could not be verified"
        }
    }
    static func agentHistoryRecoveryBackup(
        _ path: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "agentHistory.recoveryBackup %@",
            fallback: "Recovery backup: %@",
            locale: locale
        )
        return String(format: format, locale: locale, path)
    }
    static func agentHistoryRetainedRecoveryFile(
        _ path: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "agentHistory.retainedRecoveryFile %@",
            fallback: "Retained recovery file: %@",
            locale: locale
        )
        return String(format: format, locale: locale, path)
    }

    // Verified undo review — #1237.
    static let agentHistoryUndoReviewTitle: LocalizedStringKey =
        "agentHistory.undoReview.title"
    static let agentHistoryUndoReviewPreparing: LocalizedStringKey =
        "agentHistory.undoReview.preparing"
    static let agentHistoryUndoReviewVerified: LocalizedStringKey =
        "agentHistory.undoReview.verified"
    static let agentHistoryUndoReviewTechnicalDetails: LocalizedStringKey =
        "agentHistory.undoReview.technicalDetails"
    static let agentHistoryUndoReviewApply: LocalizedStringKey =
        "agentHistory.undoReview.apply"
    /// VoiceOver hint for Apply. `ButtonRole.destructive` only recolors a
    /// SwiftUI button; it does not set AppKit's `hasDestructiveAction`, which
    /// is the trait a screen reader announces — the same gap
    /// ``recoveryDiscardHint`` covers on the crash-recovery sheet.
    static let agentHistoryUndoReviewApplyHint: LocalizedStringKey =
        "agentHistory.undoReview.applyHint"
    static let agentHistoryUndoReviewRevalidated: LocalizedStringKey =
        "agentHistory.undoReview.revalidated"
    static let agentHistoryUndoReviewStaleTitle: LocalizedStringKey =
        "agentHistory.undoReview.staleTitle"
    static func agentHistoryUndoReviewBinary(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.content.binary",
            fallback: "Binary content — line preview unavailable",
            locale: locale
        )
    }
    static func agentHistoryUndoReviewOmitted(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.content.omitted",
            fallback: "Text preview omitted because the file is too large",
            locale: locale
        )
    }
    static func undoFailEntryNotFound(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.entryNotFound",
            fallback: "This history entry no longer exists.",
            locale: locale
        )
    }

    static func undoFailAlreadyReverted(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.alreadyReverted",
            fallback: "This entry has already been undone.",
            locale: locale
        )
    }

    static func undoFailNotEligible(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.notEligible",
            fallback: "This entry does not contain an eligible verified undo.",
            locale: locale
        )
    }

    static func undoFailAuthorityMissing(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.authorityMissing",
            fallback: "The private undo authority is missing.",
            locale: locale
        )
    }

    static func undoFailAuthorityConsumed(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.authorityConsumed",
            fallback: "This undo authority has already been used.",
            locale: locale
        )
    }

    static func undoFailWorkspaceChanged(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.workspaceChanged",
            fallback:
                "The workspace root, HEAD, or Git index changed after capture.",
            locale: locale
        )
    }

    static func undoFailProjectionTampered(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.projectionTampered",
            fallback:
                "The history projection no longer matches its private authority.",
            locale: locale
        )
    }

    static func undoFailPayloadMissing(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.payloadMissing",
            fallback:
                "The private inverse payload is missing or failed integrity validation.",
            locale: locale
        )
    }

    static func undoFailPayloadInvalid(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.payloadInvalid",
            fallback:
                "The inverse payload does not exactly match the verified change set.",
            locale: locale
        )
    }

    static func undoFailPreviewFailed(locale: Locale = .current) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.failure.previewFailed",
            fallback:
                "Pine could not construct a truthful preview from the verified data.",
            locale: locale
        )
    }

    static func agentHistoryUndoReviewNextClose(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.next.close",
            fallback: "Close this review.",
            locale: locale
        )
    }

    static func agentHistoryUndoReviewNextNoAction(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.next.noAction",
            fallback:
                "No files were changed. Keep the current workspace and close this review.",
            locale: locale
        )
    }

    static func agentHistoryUndoReviewNextRefresh(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.next.refresh",
            fallback:
                "Close this review and inspect the current workspace state.",
            locale: locale
        )
    }

    static func agentHistoryUndoReviewNextManualReview(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "agentHistory.undoReview.next.manualReview",
            fallback: "Keep the current file and review its changes manually.",
            locale: locale
        )
    }

    static func undoFailContentDiverged(
        _ path: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "agentHistory.undoReview.failure.contentDiverged %@",
            fallback: "The current file no longer matches the verified snapshot: %@",
            locale: locale
        )
        return String(format: format, locale: locale, path)
    }

    static func agentHistoryUndoReviewSummary(
        fileCount: Int,
        addedLineCount: Int,
        removedLineCount: Int,
        locale: Locale = .current
    ) -> String {
        let operations = verifiedDiffOperationCount(
            fileCount,
            locale: locale
        )
        return "\(operations) · +\(addedLineCount) −\(removedLineCount)"
    }

    // MARK: - Prepared inverse review (#933)

    static func verifiedDiffTitle(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.title",
            fallback: "Prepared Undo Preview",
            locale: locale
        )
    }
    static func verifiedDiffStalenessNotice(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.stalenessNotice",
            fallback: """
            Checked against one workspace snapshot. Pine must revalidate \
            authority and current files immediately before applying.
            """,
            locale: locale
        )
    }
    static func verifiedDiffSummary(
        operationCount: Int,
        addedLineCount: Int,
        removedLineCount: Int,
        locale: Locale = .current
    ) -> String {
        let operations = verifiedDiffOperationCount(
            operationCount,
            locale: locale
        )
        return "\(operations) · +\(addedLineCount) −\(removedLineCount)"
    }

    static func verifiedDiffOperationCount(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        localizedPluralString(
            forKey: "verifiedDiff.operationCount %lld",
            fallback: count == 1 ? "%lld operation" : "%lld operations",
            count: count,
            locale: locale
        )
    }

    static func verifiedDiffByteCount(
        _ count: Int,
        locale: Locale = .current
    ) -> String {
        localizedPluralString(
            forKey: "verifiedDiff.byteCount %lld",
            fallback: count == 1 ? "%lld byte" : "%lld bytes",
            count: count,
            locale: locale
        )
    }

    static func verifiedDiffKindApplyTextHunks(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.kind.applyTextHunks",
            fallback: "Checked hunks",
            locale: locale
        )
    }
    static func verifiedDiffKindRestoreExactFile(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.kind.restoreExactFile",
            fallback: "Exact restore",
            locale: locale
        )
    }
    static func verifiedDiffKindRemoveCreatedFile(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.kind.removeCreatedFile",
            fallback: "Remove created file",
            locale: locale
        )
    }
    static func verifiedDiffKindRestoreDeletedFile(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.kind.restoreDeletedFile",
            fallback: "Restore deleted file",
            locale: locale
        )
    }
    static func verifiedDiffKindSimulateRenamedFile(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.kind.simulateRenamedFile",
            fallback: "Rename simulation",
            locale: locale
        )
    }
    static func verifiedDiffDetailApplyTextHunks(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.detail.applyTextHunks",
            fallback: "Applies only the resolved inverse hunks.",
            locale: locale
        )
    }
    static func verifiedDiffDetailRestoreExactFile(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.detail.restoreExactFile",
            fallback: "Restores the complete captured file state.",
            locale: locale
        )
    }
    static func verifiedDiffDetailRemoveCreatedFile(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.detail.removeCreatedFile",
            fallback: "Deletes the file created by the prepared change.",
            locale: locale
        )
    }
    static func verifiedDiffDetailRestoreDeletedFile(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.detail.restoreDeletedFile",
            fallback: "Recreates the file with captured contents.",
            locale: locale
        )
    }
    static func verifiedDiffDetailSimulateRenamedFile(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.detail.simulateRenamedFile",
            fallback: """
            Shows a rename simulation; applying rename is unsupported.
            """,
            locale: locale
        )
    }
    static func verifiedDiffExpectedCurrent(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.expectedCurrent",
            fallback: "Expected current",
            locale: locale
        )
    }
    static func verifiedDiffResult(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.result",
            fallback: "Result",
            locale: locale
        )
    }
    static func verifiedDiffMetadataOnly(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.metadataOnly",
            fallback: "Metadata-only change",
            locale: locale
        )
    }
    static func verifiedDiffMetadataAlsoChanges(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.metadataAlsoChanges",
            fallback: "File metadata also changes",
            locale: locale
        )
    }
    static func verifiedDiffLineEndingLF(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.lineEnding.lf",
            fallback: "[LF]",
            locale: locale
        )
    }
    static func verifiedDiffLineEndingCRLF(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.lineEnding.crlf",
            fallback: "[CRLF]",
            locale: locale
        )
    }
    static func verifiedDiffNoFinalNewline(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "verifiedDiff.lineEnding.noFinalNewline",
            fallback: "[No final newline]",
            locale: locale
        )
    }
    static func verifiedDiffFileKind(
        _ kind: VerifiedPatchFileKind,
        locale: Locale = .current
    ) -> String {
        switch kind {
        case .regularFile:
            localizedString(
                forKey: "verifiedDiff.fileKind.regularFile",
                fallback: "regular file",
                locale: locale
            )
        case .symbolicLink:
            localizedString(
                forKey: "verifiedDiff.fileKind.symbolicLink",
                fallback: "symbolic link",
                locale: locale
            )
        }
    }
    static func verifiedDiffIdentity(
        label: String,
        path: String,
        identity: VerifiedPatchStateIdentity,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "verifiedDiff.identity %@ %@ %@ %@ %@ %@",
            fallback: """
            %@ · %@ · %@ · mode %@ · %@ · SHA-256 %@
            """,
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            label,
            path,
            verifiedDiffFileKind(identity.kind, locale: locale),
            String(format: "%04o", Int(identity.posixMode)),
            verifiedDiffByteCount(
                identity.contentIdentity.byteCount,
                locale: locale
            ),
            identity.contentIdentity.sha256Hex
        )
    }
    static func verifiedDiffAbsentIdentity(
        label: String,
        path: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "verifiedDiff.identity.absent %@ %@",
            fallback: "%@ · %@ · absent",
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            label,
            path
        )
    }

    // MARK: - Menu Commands

    static let menuIncreaseFontSize: LocalizedStringKey = "menu.increaseFontSize"
    static let menuDecreaseFontSize: LocalizedStringKey = "menu.decreaseFontSize"
    static let menuResetFontSize: LocalizedStringKey = "menu.resetFontSize"
    static let menuTerminal: LocalizedStringKey = "menu.terminal"
    static let menuNewTerminalTab: LocalizedStringKey = "menu.newTerminalTab"
    static let menuQuickTerminal: LocalizedStringKey = "menu.quickTerminal"
    static func quickTerminalText(locale: Locale = .current) -> String {
        localizedString(
            forKey: "menu.quickTerminal",
            fallback: "Quick Terminal",
            locale: locale
        )
    }
    static let menuTogglePreview: LocalizedStringKey = "menu.togglePreview"
    static let menuView: LocalizedStringKey = "menu.view"
    static let menuGit: LocalizedStringKey = "menu.git"
    static let menuOpenFolder: LocalizedStringKey = "menu.openFolder"
    static let menuSwitchBranch: LocalizedStringKey = "menu.switchBranch"
    static let menuRevealFileInFinder: LocalizedStringKey = "menu.revealFileInFinder"
    static let menuRevealProjectInFinder: LocalizedStringKey = "menu.revealProjectInFinder"
    static let menuTasks: LocalizedStringKey = "menu.tasks"
    static let menuTasksEmpty: LocalizedStringKey = "menu.tasksEmpty"
    static let menuCommandPalette: LocalizedStringKey = "menu.commandPalette"
    static var commandPaletteRequiresProject: String {
        String(localized: "commandPalette.unavailable.project")
    }
    static var commandPaletteRequiresActiveFile: String {
        String(localized: "commandPalette.unavailable.activeFile")
    }
    static var commandPaletteRequiresGitRepository: String {
        String(localized: "commandPalette.unavailable.gitRepository")
    }
    static var commandPaletteRequiresTerminal: String {
        String(localized: "commandPalette.unavailable.terminal")
    }
    static var commandPaletteNeedsFileAndTerminal: String {
        String(localized: "commandPalette.unavailable.activeFileAndTerminal")
    }
    static let menuEditKeybindings: LocalizedStringKey = "menu.editKeybindings"
    static let menuEditTasks: LocalizedStringKey = "menu.editTasks"
    static let menuReloadUserConfiguration: LocalizedStringKey = "menu.reloadUserConfiguration"

    static func userTaskConfirmationTitle(_ label: String) -> String {
        String(
            localized: "userTask.confirmation.title",
            defaultValue: "Run task “\(label)”?"
        )
    }

    static func userTaskConfirmationMessage(_ command: String) -> String {
        String(
            localized: "userTask.confirmation.message",
            defaultValue: "This task will execute the following command:\n\(command)"
        )
    }

    static var userTaskRun: String {
        String(localized: "userTask.run")
    }

    static var userTaskOutputConflictTitle: String {
        String(localized: "userTask.outputConflict.title")
    }

    static var userTaskOutputConflictMessage: String {
        String(localized: "userTask.outputConflict.message")
    }

    static var userTaskMissingFileTitle: String {
        String(localized: "userTask.missingFile.title")
    }

    static var userTaskMissingFileMessage: String {
        String(localized: "userTask.missingFile.message")
    }

    static var userTaskReplacementUnavailableTitle: String {
        String(
            localized: "userTask.replacementUnavailable.title",
            defaultValue: "Task Cannot Replace This Editor"
        )
    }

    static var userTaskReplacementUnavailableMessage: String {
        String(
            localized: "userTask.replacementUnavailable.message",
            defaultValue: """
            Replacement tasks require an active, fully loaded text file and \
            cannot run with project scope or a preview tab.
            """
        )
    }

    /// Toast shown when a user task completes successfully (issue #1246).
    static func userTaskToastSucceeded(_ label: String) -> String {
        String(
            localized: "userTask.toast.succeeded",
            defaultValue: "Task “\(label)” completed"
        )
    }

    /// Copy captured task output to the pasteboard (issue #1246).
    static var userTaskCopyOutput: String {
        String(localized: "userTask.copyOutput", defaultValue: "Copy Output")
    }

    /// Reveal the task output surface for inspection (issue #1246).
    static var userTaskOpenOutput: String {
        String(localized: "userTask.openOutput", defaultValue: "Open Output")
    }

    /// Short status summaries for a task run (issue #1246).
    nonisolated static let userTaskRunStatusPending: String =
        String(localized: "userTask.run.status.pending", defaultValue: "Pending")
    nonisolated static let userTaskRunStatusRunning: String =
        String(localized: "userTask.run.status.running", defaultValue: "Running")
    nonisolated static let userTaskRunStatusCancelling: String =
        String(
            localized: "userTask.run.status.cancelling",
            defaultValue: "Cancelling"
        )
    nonisolated static let userTaskRunStatusSucceeded: String =
        String(localized: "userTask.run.status.succeeded", defaultValue: "Succeeded")
    nonisolated static let userTaskRunStatusTimedOut: String =
        String(localized: "userTask.run.status.timedOut", defaultValue: "Timed out")
    nonisolated static let userTaskRunStatusFailed: String =
        String(localized: "userTask.run.status.failed", defaultValue: "Failed")
    nonisolated static let userTaskRunStatusCancelled: String =
        String(localized: "userTask.run.status.cancelled", defaultValue: "Cancelled")

    nonisolated static func userTaskRunStatusExitCode(_ code: Int) -> String {
        String(
            localized: "userTask.run.status.exitCode",
            defaultValue: "Exit \(code)"
        )
    }

    /// Live or final elapsed duration for a task run (issue #1246).
    nonisolated static func userTaskElapsed(_ duration: String) -> String {
        String(
            localized: "userTask.run.elapsed",
            defaultValue: "Elapsed \(duration)"
        )
    }

    static var userTaskOutputTitle: String {
        String(localized: "userTask.output.title", defaultValue: "Task Output")
    }

    static var userTaskOutputEmpty: String {
        String(
            localized: "userTask.output.empty",
            defaultValue: "No task history"
        )
    }

    static var userTaskOutputPreviewTruncated: String {
        String(
            localized: "userTask.output.previewTruncated",
            defaultValue: """
            Preview truncated. Copy Output includes the complete captured output.
            """
        )
    }

    static var userTaskClearFinished: String {
        String(
            localized: "userTask.output.clearFinished",
            defaultValue: "Clear Finished"
        )
    }

    static var userTaskCloseOutput: String {
        String(
            localized: "userTask.output.close",
            defaultValue: "Close Task Output"
        )
    }

    static var userTaskShowOutput: String {
        String(
            localized: "userTask.output.show",
            defaultValue: "Task Output"
        )
    }

    static var userTaskCancel: String {
        String(localized: "userTask.cancel", defaultValue: "Cancel")
    }

    nonisolated static let userTaskBlocked = String(
        localized: "userTask.diagnostic.blocked",
        defaultValue: "Task blocked by Pine’s safety policy."
    )

    nonisolated static func userTaskLaunchFailed(_ reason: String) -> String {
        String(
            localized: "userTask.diagnostic.launchFailed",
            defaultValue: "Task failed to launch: \(reason)"
        )
    }

    nonisolated static let userTaskDiagnosticBackgroundReaper = String(
        localized: "userTask.diagnostic.backgroundReaper",
        defaultValue: "Pine handed the task shell to its background reaper."
    )
    nonisolated static let userTaskDiagnosticSubprocessCleanup = String(
        localized: "userTask.diagnostic.subprocessCleanup",
        defaultValue: "Pine could not terminate every observed task subprocess."
    )
    nonisolated static let userTaskDiagnosticOutputDeadline = String(
        localized: "userTask.diagnostic.outputDeadline",
        defaultValue: "Pine stopped waiting for task output at its hard deadline."
    )
    nonisolated static let userTaskDiagnosticOutputTruncated = String(
        localized: "userTask.diagnostic.outputTruncated",
        defaultValue: "Task output exceeded Pine's capture limit and was truncated."
    )
    nonisolated static let userTaskDiagnosticInvalidUTF8 = String(
        localized: "userTask.diagnostic.invalidUTF8",
        defaultValue: "Task output contained invalid UTF-8 and was rejected."
    )
    nonisolated static let userTaskDiagnosticInputIncomplete = String(
        localized: "userTask.diagnostic.inputIncomplete",
        defaultValue: "The task stopped before Pine finished writing standard input."
    )

    // MARK: - Quick Open

    static let menuQuickOpen: LocalizedStringKey = "menu.quickOpen"
    static let quickOpenPlaceholder: LocalizedStringKey = "quickOpen.placeholder"
    static let quickOpenNoResults: LocalizedStringKey = "quickOpen.noResults"
    static let quickOpenRecentEmpty: LocalizedStringKey = "quickOpen.recentEmpty"

    // MARK: - Symbol Navigator

    static let menuSymbolNavigator: LocalizedStringKey = "menu.symbolNavigator"
    static let symbolNavigatorEmpty: LocalizedStringKey = "symbolNavigator.empty"
    static let symbolNavigatorNoResults: LocalizedStringKey = "symbolNavigator.noResults"
    static let symbolNavigatorPlaceholder: LocalizedStringKey = "symbolNavigator.placeholder"

    static func symbolKindName(
        _ kind: SymbolKind,
        locale: Locale = .current
    ) -> String {
        let localization: (key: String, fallback: String)
        switch kind {
        case .class:
            localization = ("symbolKind.class", "Class")
        case .struct:
            localization = ("symbolKind.struct", "Struct")
        case .enum:
            localization = ("symbolKind.enum", "Enum")
        case .interface:
            localization = ("symbolKind.interface", "Interface")
        case .namespace:
            localization = ("symbolKind.namespace", "Namespace")
        case .function:
            localization = ("symbolKind.function", "Function")
        case .property:
            localization = ("symbolKind.property", "Property")
        case .variable:
            localization = ("symbolKind.variable", "Variable")
        case .other:
            localization = ("symbolKind.symbol", "Symbol")
        }
        return localizedString(
            forKey: localization.key,
            fallback: localization.fallback,
            locale: locale
        )
    }

    private static func localizedString(
        forKey key: String,
        fallback: String,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        // `String(localized:locale:)` uses `locale` only to format
        // interpolated values; it does not select a localized resource.
        // Resolve the requested language explicitly, then look up the key in
        // that language's sub-bundle so previews and tests are deterministic.
        let localeIdentifier = locale.identifier
            .split(separator: "@", maxSplits: 1)
            .first
            .map(String.init) ?? locale.identifier
        let requestedLocalization = localeIdentifier
            .replacingOccurrences(of: "_", with: "-")
        let developmentLocalization = bundle.developmentLocalization ?? "en"
        let preferredLocalization = Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: [
                requestedLocalization,
                developmentLocalization,
            ]
        ).first ?? developmentLocalization

        func languageBundle(for localization: String) -> Bundle? {
            guard let path = bundle.path(
                forResource: localization,
                ofType: "lproj"
            ) else {
                return nil
            }
            return Bundle(path: path)
        }

        let developmentValue = languageBundle(
            for: developmentLocalization
        )?.localizedString(
            forKey: key,
            value: fallback,
            table: nil
        ) ?? fallback
        guard let preferredBundle = languageBundle(
            for: preferredLocalization
        ) else {
            return developmentValue
        }
        return preferredBundle.localizedString(
            forKey: key,
            value: developmentValue,
            table: nil
        )
    }

    /// Resolves a plural format from the requested language's `.lproj`, then
    /// applies that locale's numeric and plural formatting rules.
    ///
    /// `String(localized:locale:)` cannot be used for deterministic language
    /// selection: its `locale` parameter formats substitutions but resource
    /// lookup still follows the process's preferred application language.
    private static func localizedPluralString(
        forKey key: String,
        fallback: String,
        count: Int,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        let format = localizedString(
            forKey: key,
            fallback: fallback,
            locale: locale,
            bundle: bundle
        )
        return String(
            format: format,
            locale: locale,
            arguments: [count]
        )
    }

    // MARK: - Branch Switcher

    static let branchFilterPlaceholder: LocalizedStringKey = "branch.filterPlaceholder"

    static var branchSwitchErrorTitle: String {
        String(localized: "branch.switchError.title")
    }

    static let menuCheckForUpdates: LocalizedStringKey = "menu.checkForUpdates"
    static let menuToggleComment: LocalizedStringKey = "menu.toggleComment"
    static let menuToggleMinimap: LocalizedStringKey = "menu.toggleMinimap"
    static let menuToggleBlame: LocalizedStringKey = "menu.toggleBlame"
    static let menuToggleWordWrap: LocalizedStringKey = "menu.toggleWordWrap"

    static var branchUncommittedChangesTitle: String {
        String(localized: "branch.uncommittedChanges.title")
    }

    static func branchUncommittedChangesMessage(_ branch: String) -> String {
        String(localized: "branch.uncommittedChanges.message \(branch)")
    }

    static var branchUncommittedChangesSwitch: String {
        String(localized: "branch.uncommittedChanges.switch")
    }

    static let autoSaving: LocalizedStringKey = "editor.autoSaving"
    static let menuSave: LocalizedStringKey = "menu.save"
    static let menuSaveAll: LocalizedStringKey = "menu.saveAll"
    static let menuSaveAs: LocalizedStringKey = "menu.saveAs"
    static let menuDuplicate: LocalizedStringKey = "menu.duplicate"
    static let menuNewFile: LocalizedStringKey = "menu.newFile"
    static let menuOpenFile: LocalizedStringKey = "menu.open"
    static let menuOpenRecent: LocalizedStringKey = "menu.openRecent"
    static let menuClearMenu: LocalizedStringKey = "menu.clearMenu"
    static let menuCloseTab: LocalizedStringKey = "menu.closeTab"
    static let menuCloseWindow: LocalizedStringKey = "menu.closeWindow"
    static let menuCloseProject: LocalizedStringKey = "menu.closeProject"

    // MARK: - Affordance / Accessibility Help

    static let statusbarEncodingDisabledDirty: LocalizedStringKey = "statusbar.encodingDisabledDirty"
    static let breadcrumbShowHiddenSegments: LocalizedStringKey = "breadcrumb.showHiddenSegments"

    // MARK: - Tab Pinning

    static let tabPin: LocalizedStringKey = "tab.pin"
    static let tabUnpin: LocalizedStringKey = "tab.unpin"

    // MARK: - Tab Context Menu

    static let tabCloseOtherTabs: LocalizedStringKey = "tab.closeOtherTabs"
    static let tabCloseTabsToTheRight: LocalizedStringKey = "tab.closeTabsToTheRight"
    static let tabCloseAllTabs: LocalizedStringKey = "tab.closeAllTabs"
    static let tabCopyPath: LocalizedStringKey = "tab.copyPath"
    static let tabCopyRelativePath: LocalizedStringKey = "tab.copyRelativePath"
    static let tabRevealInSidebar: LocalizedStringKey = "tab.revealInSidebar"
    static let tabRevealInFinder: LocalizedStringKey = "tab.revealInFinder"
    static let tabCloseTabDisabledPinned: LocalizedStringKey = "tab.closeTabDisabledPinned"
    static let agentResumeTask: LocalizedStringKey = "agent.resumeTask"
    static let tabMoveLeading: LocalizedStringKey = "tab.moveLeading"
    static let tabMoveTrailing: LocalizedStringKey = "tab.moveTrailing"
    static let tabMoveToPreviousPane: LocalizedStringKey = "tab.moveToPreviousPane"
    static let tabMoveToNextPane: LocalizedStringKey = "tab.moveToNextPane"
    static let tabSwitchNext: LocalizedStringKey = "tab.switchNext"
    static let tabSwitchPrevious: LocalizedStringKey = "tab.switchPrevious"

    // MARK: - Unsaved Changes Dialog (AppKit)

    /// The close question for one named file.
    ///
    /// The question is the alert's *message* text and the consequence is the
    /// informative text, which is the order the HIG asks for and the reverse
    /// of what Pine used to do: a noun-phrase title ("Unsaved Changes") with
    /// the question demoted into the body. Naming the file is the other half
    /// — the tab is known at the call site, and "unsaved changes" without a
    /// filename does not tell the user what they are about to lose (#1541).
    static func unsavedChangesQuestion(_ fileName: String) -> String {
        String(localized: "dialog.unsavedChanges.question \(fileName)")
    }

    static func unsavedChangesQuestion(
        _ fileName: String,
        locale: Locale
    ) -> String {
        let format = localizedString(
            forKey: "dialog.unsavedChanges.question %@",
            fallback: "Do you want to save the changes you made to \u{201C}%@\u{201D}?",
            locale: locale
        )
        return String(format: format, locale: locale, fileName)
    }

    /// The informative half of every close question: what is lost, said once.
    static var unsavedChangesConsequence: String {
        String(localized: "dialog.unsavedChanges.consequence")
    }

    /// The close question for two or more files.
    ///
    /// Count-free, and only ever asked about two or more: the list of names
    /// sits directly underneath it, and a window close or Quit review with a
    /// single dirty tab asks ``unsavedChangesQuestion(_:)`` about that file by
    /// name instead. That keeps "these files" always grammatical without a
    /// plural entry, and names the file in the one case where there is a name
    /// to give.
    static var unsavedChangesBulkQuestion: String {
        String(localized: "dialog.unsavedChanges.bulkQuestion")
    }

    static var dialogSave: String {
        String(localized: "dialog.unsavedChanges.save")
    }

    static var dialogDontSave: String {
        String(localized: "dialog.unsavedChanges.dontSave")
    }

    static var dialogCancel: String {
        String(localized: "dialog.unsavedChanges.cancel")
    }

    static func dialogCancel(locale: Locale) -> String {
        localizedString(
            forKey: "dialog.unsavedChanges.cancel",
            fallback: "Cancel",
            locale: locale
        )
    }

    static var dialogClose: String {
        String(localized: "dialog.close", defaultValue: "Close")
    }

    static func dialogClose(locale: Locale) -> String {
        localizedString(
            forKey: "dialog.close",
            fallback: "Close",
            locale: locale
        )
    }

    static var dialogSaveAll: String {
        String(localized: "dialog.unsavedChanges.saveAll")
    }

    static func unsavedChangesListMessage(_ fileNames: String) -> String {
        String(localized: "dialog.unsavedChanges.listMessage \(fileNames)")
    }

    static var dialogOK: String {
        String(localized: "dialog.ok")
    }

    // MARK: - Revert All Confirmation

    static var revertAllTitle: String {
        String(localized: "revertAll.title", defaultValue: "Revert All Changes?")
    }

    static func revertAllMessage(_ fileName: String) -> String {
        String(
            localized: "revertAll.message",
            defaultValue: "All changes in \"\(fileName)\" will be permanently lost. This action cannot be undone."
        )
    }

    static var revertAllButton: String {
        String(localized: "revertAll.button", defaultValue: "Revert All")
    }

    // MARK: - Save As Panel (AppKit)

    static var saveAsPanelTitle: String {
        String(localized: "saveAsPanel.title")
    }

    // MARK: - Open Panel (AppKit)

    static var openPanelMessage: String {
        String(localized: "openPanel.message")
    }

    static var openPanelPrompt: String {
        String(localized: "openPanel.prompt")
    }

    static var openFilePanelMessage: String {
        String(localized: "openFilePanel.message")
    }

    static var openFilePanelPrompt: String {
        String(localized: "openFilePanel.prompt")
    }

    // MARK: - Large File Warning

    static var largeFileWarningTitle: String {
        String(localized: "largeFile.warning.title")
    }

    static func largeFileWarningMessage(_ fileName: String, _ sizeMB: Double) -> String {
        let formatted = String(format: "%.1f", sizeMB)
        return String(localized: "largeFile.warning.message \(fileName) \(formatted)")
    }

    static var largeFileOpenWithHighlighting: String {
        String(localized: "largeFile.openWithHighlighting")
    }

    static var largeFileOpenWithoutHighlighting: String {
        String(localized: "largeFile.openWithoutHighlighting")
    }

    static func fileTruncatedNotice(_ totalSize: String) -> String {
        "\n\n⚠️ File truncated at 1 MB (total: \(totalSize)). Editing is read-only."
    }

    // MARK: - Welcome Window

    static let welcomeTitle: LocalizedStringKey = "welcome.title"
    static let welcomeSubtitle: LocalizedStringKey = "welcome.subtitle"
    static let welcomeRecentProjects: LocalizedStringKey = "welcome.recentProjects"
    static let welcomeNoRecent: LocalizedStringKey = "welcome.noRecent"
    static let welcomeOpenProject: LocalizedStringKey = "openPanel.prompt"
    static let welcomeRemoveFromRecent: LocalizedStringKey = "welcome.removeFromRecent"
    static let welcomeRevealInFinder: LocalizedStringKey = "welcome.revealInFinder"
    static let welcomeSearchPlaceholder: LocalizedStringKey = "welcome.searchPlaceholder"
    static var welcomeSearchPlaceholderString: String {
        String(localized: "welcome.searchPlaceholder")
    }
    static let welcomeNoSearchResults: LocalizedStringKey = "welcome.noSearchResults"

    // MARK: - Project Search

    static let searchPlaceholder: LocalizedStringKey = "search.placeholder"
    static let searchNoResults: LocalizedStringKey = "search.noResults"
    static let searchInitialPrompt: LocalizedStringKey = "search.initialPrompt"
    static let searchInitialDescription: LocalizedStringKey = "search.initialDescription"
    static let searchCaseSensitive: LocalizedStringKey = "search.caseSensitive"
    static let searchClose: LocalizedStringKey = "search.close"

    static func searchTruncatedTotal(shown: Int, max: Int) -> String {
        String(localized: "search.truncatedTotal \(shown) \(max)")
    }
    static func searchTruncatedPerFile(_ max: Int) -> String {
        String(localized: "search.truncatedPerFile \(max)")
    }
    static let menuFind: LocalizedStringKey = "menu.find"
    static let menuFindAndReplace: LocalizedStringKey = "menu.findAndReplace"
    static let menuFindNext: LocalizedStringKey = "menu.findNext"
    static let menuFindPrevious: LocalizedStringKey = "menu.findPrevious"
    static let menuUseSelectionForFind: LocalizedStringKey = "menu.useSelectionForFind"
    static let menuFindInProject: LocalizedStringKey = "menu.findInProject"
    static let menuGoToLine: LocalizedStringKey = "menu.goToLine"
    static let menuNextChange: LocalizedStringKey = "menu.nextChange"
    static let menuPreviousChange: LocalizedStringKey = "menu.previousChange"
    static let menuAcceptChange: LocalizedStringKey = "menu.acceptChange"
    static let menuRevertChange: LocalizedStringKey = "menu.revertChange"
    static let menuAcceptAllChanges: LocalizedStringKey = "menu.acceptAllChanges"
    static let menuRevertAllChanges: LocalizedStringKey = "menu.revertAllChanges"
    static let menuFoldCode: LocalizedStringKey = "menu.foldCode"
    static let menuUnfoldCode: LocalizedStringKey = "menu.unfoldCode"
    static let menuFoldAll: LocalizedStringKey = "menu.foldAll"
    static let menuUnfoldAll: LocalizedStringKey = "menu.unfoldAll"
    static let sidebarFiles: LocalizedStringKey = "sidebar.files"
    static let sidebarSearch: LocalizedStringKey = "sidebar.search"

    // MARK: - Terminal Search

    static let terminalSearchPlaceholder: LocalizedStringKey = "terminal.search.placeholder"
    static let menuFindInTerminal: LocalizedStringKey = "menu.findInTerminal"
    static let menuSendToTerminal: LocalizedStringKey = "menu.sendToTerminal"
    static let menuToggleTerminalZoom: LocalizedStringKey = "menu.toggleTerminalZoom"
    static let menuRecoverTerminalDisplay: LocalizedStringKey =
        "menu.recoverTerminalDisplay"

    static var terminalSearchPreviousTooltip: String {
        String(localized: "terminal.search.previousTooltip")
    }

    static var terminalSearchNextTooltip: String {
        String(localized: "terminal.search.nextTooltip")
    }

    static var terminalSearchCloseTooltip: String {
        String(localized: "terminal.search.closeTooltip")
    }

    static var terminalSearchCaseSensitiveTooltip: String {
        String(localized: "terminal.search.caseSensitiveTooltip")
    }

    static var terminalSearchNoMatches: String {
        String(localized: "terminal.search.noMatches")
    }

    static func terminalSearchMatchCount(current: Int, total: Int) -> String {
        String(localized: "terminal.search.matchCount \(current) \(total)")
    }

    // MARK: - Terminal Tab Names (runtime)

    static var terminalDefaultName: String {
        String(localized: "terminal.defaultName")
    }

    static func terminalNumberedName(_ number: Int) -> String {
        String(localized: "terminal.numberedName \(number)")
    }

    // MARK: - Crash Recovery Dialog

    static let recoveryTitle: LocalizedStringKey = "recovery.title"
    static let recoveryMessage: LocalizedStringKey = "recovery.message"
    /// Shown when the sheet returns carrying the snapshots a restore attempt
    /// handed back. Without it the second appearance is indistinguishable
    /// from the first, and the user is asked the same question with no word
    /// about the attempt that just failed (#1541).
    static let recoveryPartialFailureMessage: LocalizedStringKey =
        "recovery.partialFailureMessage"
    static let recoveryRecoverAll: LocalizedStringKey = "recovery.recoverAll"
    static let recoveryDiscard: LocalizedStringKey = "recovery.discard"
    static let recoveryLater: LocalizedStringKey = "recovery.later"
    static let recoveryDiscardHint: LocalizedStringKey = "recovery.discardHint"

    /// How long snapshots nobody decided about are kept.
    ///
    /// Returns a `LocalizedStringKey` rather than a resolved `String` because
    /// it is rendered inside the recovery sheet: only the key form follows the
    /// SwiftUI environment locale, which is what lets the sheet be measured in
    /// every supported locale.
    static func recoveryRetentionNotice(days: Int) -> LocalizedStringKey {
        "recovery.retentionNotice \(days)"
    }

    static var recoveryUntitled: String {
        String(localized: "recovery.untitled")
    }

    // MARK: - Terminal Process Warnings

    static var terminalActiveProcessWarningTitle: String {
        String(localized: "terminal.activeProcessWarning.title")
    }

    static var terminalActiveProcessWarningMessage: String {
        String(localized: "terminal.activeProcessWarning.message")
    }

    static var terminalActiveProcessWarningQuit: String {
        String(localized: "terminal.activeProcessWarning.quit")
    }

    static var activeUserTasksPreventQuitTitle: String {
        String(localized: "task.activePreventQuit.title")
    }

    static var activeUserTasksPreventQuitMessage: String {
        String(localized: "task.activePreventQuit.message")
    }

    static var applicationQuitSummaryTitle: String {
        String(localized: "quit.summary.title")
    }

    static func applicationQuitSummaryMessage(_ itemCount: Int) -> String {
        String(localized: "quit.summary.message \(itemCount)")
    }

    static var applicationQuitReview: String {
        String(localized: "quit.summary.review")
    }

    static var applicationQuitAnyway: String {
        String(localized: "quit.summary.quitAnyway")
    }

    static var applicationQuitFailureTitle: String {
        String(localized: "quit.failure.title")
    }

    static var applicationQuitFailureMessage: String {
        String(localized: "quit.failure.message")
    }

    static var terminalTabCloseWarningTitle: String {
        String(localized: "terminal.tabCloseWarning.title")
    }

    static var terminalTabCloseWarningMessage: String {
        String(localized: "terminal.tabCloseWarning.message")
    }

    static var terminalTabCloseWarningClose: String {
        String(localized: "terminal.tabCloseWarning.close")
    }

    // MARK: - Config Validation

    static let menuToggleValidation: LocalizedStringKey = "menu.toggleValidation"

    static var validationErrorCount: (Int) -> String = { count in
        String(localized: "validation.errorCount \(count)")
    }

    static var validationWarningCount: (Int) -> String = { count in
        String(localized: "validation.warningCount \(count)")
    }

    static var validationToolNotInstalled: (String) -> String = { tool in
        String(localized: "validation.toolNotInstalled \(tool)")
    }

    static var validationPassed: String {
        String(localized: "validation.passed")
    }

    // MARK: - Toast Notifications

    static func toastFileReloaded(_ name: String) -> String {
        String(localized: "toast.fileReloaded \(name)")
    }

    static func toastFilesReloaded(count: Int, names: String) -> String {
        String(localized: "toast.filesReloaded \(count) \(names)")
    }

    static func toastFilesReloadedMore(count: Int, names: String, remaining: Int) -> String {
        String(localized: "toast.filesReloaded.more \(count) \(names) \(remaining)")
    }

    /// VoiceOver label for the toast dismiss (✕) button. Localized into all 9
    /// supported languages (issue #1247).
    static var a11yToastDismissLabel: String {
        String(localized: "a11y.toast.dismiss.label", defaultValue: "Dismiss")
    }

    /// Prefix spoken by VoiceOver before the toast message when an
    /// announcement is posted. Localized into all 9 supported languages
    /// (issue #1247).
    static var a11yToastAnnouncementPrefix: String {
        String(localized: "a11y.toast.announcement.prefix", defaultValue: "Notification:")
    }

    // MARK: - Progress Indicators

    static var progressLoadingProject: String {
        String(localized: "progress.loadingProject")
    }

    static var progressGitStatus: String {
        String(localized: "progress.gitStatus")
    }

    static var progressGitCheckout: String {
        String(localized: "progress.gitCheckout")
    }

    static var progressLoadingFile: String {
        String(localized: "progress.loadingFile")
    }

    // MARK: - Diagnostics (#679)

    static var diagnosticSeverityError: String {
        String(localized: "diagnostic.severity.error", defaultValue: "Error")
    }

    static var diagnosticSeverityWarning: String {
        String(localized: "diagnostic.severity.warning", defaultValue: "Warning")
    }

    static var diagnosticSeverityInfo: String {
        String(localized: "diagnostic.severity.info", defaultValue: "Info")
    }

    static func diagnosticLineLabel(line: Int) -> String {
        let format = String(localized: "diagnostic.line", defaultValue: "Line %lld")
        return String(format: format, locale: .current, line)
    }

    static func diagnosticLineColumnLabel(line: Int, column: Int) -> String {
        let format = String(
            localized: "diagnostic.lineColumn",
            defaultValue: "Line %1$lld, column %2$lld"
        )
        return String(format: format, locale: .current, line, column)
    }

    // MARK: - LSP / Problems panel (#1010)

    static var problemsNoIssues: String {
        String(localized: "problems.noIssues", defaultValue: "No problems detected")
    }

    static var problemsNoFilterMatches: String {
        String(
            localized: "problems.noFilterMatches",
            defaultValue: "No problems match the current filters"
        )
    }

    // Problems panel chrome wiring (#1236)

    static var problemsPanelTitle: String {
        String(localized: "problems.panelTitle", defaultValue: "Problems")
    }

    static var problemsClose: String {
        String(localized: "problems.close", defaultValue: "Close panel")
    }

    static var menuProblems: String {
        String(localized: "menu.problems", defaultValue: "Problems")
    }

    static var menuNextDiagnostic: String {
        String(localized: "menu.nextDiagnostic", defaultValue: "Next Diagnostic")
    }

    static var menuPreviousDiagnostic: String {
        String(localized: "menu.previousDiagnostic", defaultValue: "Previous Diagnostic")
    }

    static func problemsErrorCount(_ count: Int) -> String {
        guard count == 1 else { return validationErrorCount(count) }
        return String(
            localized: "problems.errorCount.one",
            defaultValue: "1 error"
        )
    }

    static func problemsWarningCount(_ count: Int) -> String {
        guard count == 1 else { return validationWarningCount(count) }
        return String(
            localized: "problems.warningCount.one",
            defaultValue: "1 warning"
        )
    }

    static var problemsSeverityFilter: String {
        String(
            localized: "problems.filter.severity",
            defaultValue: "Severity"
        )
    }

    static var problemsSourceFilter: String {
        String(localized: "problems.filter.source", defaultValue: "Source")
    }

    static var problemsAllSeverities: String {
        String(
            localized: "problems.filter.allSeverities",
            defaultValue: "All Severities"
        )
    }

    static var problemsAllSources: String {
        String(
            localized: "problems.filter.allSources",
            defaultValue: "All Sources"
        )
    }

    static var problemsDisabled: String {
        String(
            localized: "problems.state.disabled",
            defaultValue: "Language servers are disabled"
        )
    }

    static var problemsUnsupported: String {
        String(
            localized: "problems.state.unsupported",
            defaultValue: "No diagnostics are available for this language"
        )
    }

    static var problemsLoading: String {
        String(
            localized: "problems.state.loading",
            defaultValue: "Loading diagnostics…"
        )
    }

    static var problemsUnavailable: String {
        String(
            localized: "problems.state.unavailable",
            defaultValue: "The language server is unavailable"
        )
    }

    // MARK: - Accessibility (#1003)
    //
    // VoiceOver labels / hints for custom controls. These are resolved into
    // Localizable.xcstrings by Xcode's string catalog extraction and are
    // translated into the 9 supported languages (de, en, es, fr, ja, ko,
    // pt-BR, ru, zh-Hans).

    // Editor tab bar
    static let a11yCloseTabLabel: String =
        String(localized: "a11y.editorTab.close.label", defaultValue: "Close tab")
    static let a11yCloseTabHint: String =
        String(localized: "a11y.editorTab.close.hint", defaultValue: "Closes this editor tab")
    static let a11yTransientPreviewTab: String =
        String(localized: "a11y.editorTab.preview.value", defaultValue: "Preview")

    // Sidebar file activation
    static let a11ySidebarFileOpenHint: String =
        String(
            localized: "a11y.sidebar.file.open.hint",
            defaultValue: "Double-click or press Command-Return to keep this file open"
        )
    static let a11ySidebarOpenPreview: String =
        String(localized: "a11y.sidebar.file.preview.action", defaultValue: "Open Preview")

    // Sidebar folder disclosure (VoiceOver) — #1238
    static let a11ySidebarDisclosureExpanded: String =
        String(localized: "a11y.sidebar.disclosure.expanded", defaultValue: "expanded")
    static let a11ySidebarDisclosureCollapsed: String =
        String(localized: "a11y.sidebar.disclosure.collapsed", defaultValue: "collapsed")
    static let a11ySidebarFolderHint: String =
        String(
            localized: "a11y.sidebar.folder.hint",
            defaultValue: "Folder. Press Left or Right arrow to collapse or expand."
        )
    static let a11ySidebarExpandAction: String =
        String(localized: "a11y.sidebar.expand.action", defaultValue: "Expand")
    static let a11ySidebarCollapseAction: String =
        String(localized: "a11y.sidebar.collapse.action", defaultValue: "Collapse")

    // Pane divider
    static let a11yPaneDividerLabel: String =
        String(localized: "a11y.paneDivider.label", defaultValue: "Pane divider")
    static let a11yPaneDividerHint: String =
        String(localized: "a11y.paneDivider.hint", defaultValue: "Drag to resize the panes")

    // Minimap
    static let a11yMinimapLabel: String =
        String(localized: "a11y.minimap.label", defaultValue: "Minimap")
    static let a11yMinimapHint: String =
        String(localized: "a11y.minimap.hint", defaultValue: "Code overview. Click to jump to a line.")

    // Terminal pane controls
    static let a11yNewTerminalLabel: String =
        String(localized: "a11y.terminal.new.label", defaultValue: "New terminal tab")
    static let a11yMaximizeTerminalLabel: String =
        String(localized: "a11y.terminal.maximize.label", defaultValue: "Maximize terminal pane")
    static let a11yRestoreTerminalLabel: String =
        String(localized: "a11y.terminal.restore.label", defaultValue: "Restore terminal pane")
    static let a11yCloseTerminalLabel: String =
        String(localized: "a11y.terminal.close.label", defaultValue: "Close terminal pane")
    static let a11yCloseTerminalHint: String =
        String(localized: "a11y.terminal.close.hint", defaultValue: "Closes this terminal pane")

    // Branch switcher
    static let a11yBranchSwitcherHint: String =
        String(localized: "a11y.branchSwitcher.hint", defaultValue: "Switches to this git branch")

    // Quick open
    static let a11yQuickOpenItemHint: String =
        String(localized: "a11y.quickOpen.item.hint", defaultValue: "Opens this file")

    // Symbol navigator
    static let a11ySymbolItemHint: String =
        String(localized: "a11y.symbolNavigator.item.hint", defaultValue: "Jumps to this symbol")

    // Status bar
    static let a11yStatusBarLabel: String =
        String(localized: "a11y.statusBar.label", defaultValue: "Status bar")
    static let a11yTerminalToggleHint: String =
        String(localized: "a11y.statusBar.terminalToggle.hint", defaultValue: "Shows or hides the terminal")

    // Git status differentiate-without-color labels
    static let a11yGitStatusModified: String =
        String(localized: "a11y.gitStatus.modified", defaultValue: "Modified")
    static let a11yGitStatusAdded: String =
        String(localized: "a11y.gitStatus.added", defaultValue: "Added")
    static let a11yGitStatusUntracked: String =
        String(localized: "a11y.gitStatus.untracked", defaultValue: "Untracked")

    // MARK: - Global Tab Switcher overlay (#1239)

    /// Title shown at the top of the Control-Tab overlay.
    static var globalTabSwitcherTitle: String {
        globalTabSwitcherTitle(locale: .current)
    }

    static func globalTabSwitcherTitle(locale: Locale) -> String {
        localizedString(
            forKey: "globalTabSwitcher.title",
            fallback: "Switch Tab",
            locale: locale
        )
    }

    /// Footnote hint beneath the list, e.g. "Tab to cycle, release Control to switch".
    static var globalTabSwitcherHint: String {
        globalTabSwitcherHint(locale: .current)
    }

    static func globalTabSwitcherHint(locale: Locale) -> String {
        localizedString(
            forKey: "globalTabSwitcher.hint",
            fallback: "Tab cycles · Release Control to switch · Esc cancels",
            locale: locale
        )
    }

    /// Generic pane label fallback used when a pane position cannot be derived.
    static var paneGenericLabel: String {
        paneGenericLabel(locale: .current)
    }

    static func paneGenericLabel(locale: Locale) -> String {
        localizedString(
            forKey: "pane.genericLabel",
            fallback: "Pane",
            locale: locale
        )
    }

    /// 1-based pane position label, e.g. "Pane 2".
    static func panePositionLabel(
        _ position: Int,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "pane.positionLabel",
            fallback: "Pane %lld",
            locale: locale
        )
        return String(format: format, locale: locale, position)
    }

    /// VoiceOver description for the currently highlighted row.
    static func globalTabSwitcherAnnouncement(
        title: String,
        paneContext: String,
        position: Int,
        total: Int,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "globalTabSwitcher.announcement",
            fallback: "%1$@, %2$@, %3$lld of %4$lld",
            locale: locale
        )
        return String(
            format: format,
            locale: locale,
            title,
            paneContext,
            position,
            total
        )
    }

    // MARK: - Searchable command overlay announcements (#1497)

    static func commandOverlayNoResults(
        locale: Locale = .current
    ) -> String {
        localizedString(
            forKey: "commandOverlay.announcement.noResults",
            fallback: "No results",
            locale: locale
        )
    }

    static func commandOverlayOneResult(
        selectedRow: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "commandOverlay.announcement.oneResult",
            fallback: "1 result. Selected: %@",
            locale: locale
        )
        return String(format: format, locale: locale, selectedRow)
    }

    static func commandOverlayManyResults(
        count: Int,
        selectedRow: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "commandOverlay.announcement.manyResults",
            fallback: "%1$lld results. Selected: %2$@",
            locale: locale
        )
        return String(format: format, locale: locale, count, selectedRow)
    }

    static func commandOverlayShortcut(
        _ shortcut: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "commandOverlay.announcement.shortcut",
            fallback: "Shortcut: %@",
            locale: locale
        )
        return String(format: format, locale: locale, shortcut)
    }

    static func commandOverlayUnavailable(
        _ reason: String,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "commandOverlay.announcement.unavailable",
            fallback: "Unavailable: %@",
            locale: locale
        )
        return String(format: format, locale: locale, reason)
    }

    static func commandOverlaySymbol(
        kind: String,
        name: String,
        line: Int,
        locale: Locale = .current
    ) -> String {
        let format = localizedString(
            forKey: "commandOverlay.announcement.symbol",
            fallback: "%1$@, %2$@, line %3$lld",
            locale: locale
        )
        return String(format: format, locale: locale, kind, name, line)
    }
}
