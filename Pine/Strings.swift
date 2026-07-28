import Foundation
import SwiftUI

/// Centralized UI strings for Pine.
/// Keys use stable dot-separated identifiers; English values live in
/// Localizable.xcstrings so renaming copy never breaks translation memory.
enum Strings {
    // MARK: - Settings

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
    static var agentActivityAttributionSessionLinked: String {
        String(
            localized: "agentActivity.attribution.sessionLinked",
            defaultValue: "Session-linked"
        )
    }
    static var agentActivityAttributionAmbiguous: String {
        String(localized: "agentActivity.attribution.ambiguous", defaultValue: "Ambiguous")
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
    static func agentActivityPossibleSessions(_ count: Int) -> String {
        String(localized: "agentActivity.possibleSessions \(count)")
    }
    static func agentActivityFileChanged(_ name: String) -> String {
        String(localized: "agentActivity.fileChanged \(name)")
    }

    // MARK: - Agent Attention overlay (#1112)
    static let agentAttentionTitle: LocalizedStringKey = "agentAttention.title"
    static let agentAttentionEmpty: LocalizedStringKey = "agentAttention.empty"

    // MARK: - Agent History & Undo (#1073)
    static let menuAgentHistory: LocalizedStringKey = "menu.agentHistory"
    static let agentHistoryTitle: LocalizedStringKey = "agentHistory.title"
    static let agentHistoryEmptyTitle: LocalizedStringKey = "agentHistory.emptyTitle"
    static let agentHistoryEmptyMessage: LocalizedStringKey = "agentHistory.emptyMessage"
    static let agentHistoryRevertedBadge: LocalizedStringKey = "agentHistory.revertedBadge"
    static let agentHistoryRevertButton: LocalizedStringKey = "agentHistory.revertButton"
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
    static let agentHistoryRecoveryNoticeCorrupt: LocalizedStringKey =
        "agentHistory.recoveryNoticeCorrupt"
    static func agentHistoryRecoveryBackup(_ path: String) -> String {
        String(localized: "agentHistory.recoveryBackup \(path)")
    }
    static func agentHistoryRetainedRecoveryFile(_ path: String) -> String {
        String(localized: "agentHistory.retainedRecoveryFile \(path)")
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

    static let menuAutoSave: LocalizedStringKey = "menu.autoSave"
    static let menuFormatOnSave: LocalizedStringKey = "menu.formatOnSave"
    static let menuSmartListContinuation: LocalizedStringKey = "menu.smartListContinuation"
    static let autoSaving: LocalizedStringKey = "editor.autoSaving"
    static let menuSave: LocalizedStringKey = "menu.save"
    static let menuSaveAll: LocalizedStringKey = "menu.saveAll"
    static let menuSaveAs: LocalizedStringKey = "menu.saveAs"
    static let menuDuplicate: LocalizedStringKey = "menu.duplicate"
    static let menuCloseTab: LocalizedStringKey = "menu.closeTab"

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
    static let tabMoveLeading: LocalizedStringKey = "tab.moveLeading"
    static let tabMoveTrailing: LocalizedStringKey = "tab.moveTrailing"
    static let tabMoveToPreviousPane: LocalizedStringKey = "tab.moveToPreviousPane"
    static let tabMoveToNextPane: LocalizedStringKey = "tab.moveToNextPane"

    // MARK: - Unsaved Changes Dialog (AppKit)

    static var unsavedChangesTitle: String {
        String(localized: "dialog.unsavedChanges.title")
    }

    static var unsavedChangesMessage: String {
        String(localized: "dialog.unsavedChanges.message")
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
    static let recoveryRecoverAll: LocalizedStringKey = "recovery.recoverAll"
    static let recoveryDiscard: LocalizedStringKey = "recovery.discard"

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
}
