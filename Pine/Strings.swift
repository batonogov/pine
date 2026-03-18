import SwiftUI

/// Centralized UI strings for Pine.
/// Keys use stable dot-separated identifiers; English values live in
/// Localizable.xcstrings so renaming copy never breaks translation memory.
enum Strings {
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

    // MARK: - Menu Commands

    static let menuIncreaseFontSize: LocalizedStringKey = "menu.increaseFontSize"
    static let menuDecreaseFontSize: LocalizedStringKey = "menu.decreaseFontSize"
    static let menuResetFontSize: LocalizedStringKey = "menu.resetFontSize"
    static let menuTerminal: LocalizedStringKey = "menu.terminal"
    static let menuNewTerminalTab: LocalizedStringKey = "menu.newTerminalTab"
    static let menuTogglePreview: LocalizedStringKey = "menu.togglePreview"
    static let menuView: LocalizedStringKey = "menu.view"
    static let menuGit: LocalizedStringKey = "menu.git"
    static let menuOpenFolder: LocalizedStringKey = "menu.openFolder"
    static let menuSwitchBranch: LocalizedStringKey = "menu.switchBranch"
    static let menuRevealFileInFinder: LocalizedStringKey = "menu.revealFileInFinder"
    static let menuRevealProjectInFinder: LocalizedStringKey = "menu.revealProjectInFinder"

    // MARK: - Branch Switcher

    static let branchFilterPlaceholder: LocalizedStringKey = "branch.filterPlaceholder"

    static var branchSwitchErrorTitle: String {
        String(localized: "branch.switchError.title")
    }

    static let menuCheckForUpdates: LocalizedStringKey = "menu.checkForUpdates"
    static let menuToggleComment: LocalizedStringKey = "menu.toggleComment"
    static let menuToggleMinimap: LocalizedStringKey = "menu.toggleMinimap"

    static var branchUncommittedChangesTitle: String {
        String(localized: "branch.uncommittedChanges.title")
    }

    static func branchUncommittedChangesMessage(_ branch: String) -> String {
        String(localized: "branch.uncommittedChanges.message \(branch)")
    }

    static var branchUncommittedChangesSwitch: String {
        String(localized: "branch.uncommittedChanges.switch")
    }

    static let menuSave: LocalizedStringKey = "menu.save"
    static let menuSaveAll: LocalizedStringKey = "menu.saveAll"
    static let menuSaveAs: LocalizedStringKey = "menu.saveAs"
    static let menuDuplicate: LocalizedStringKey = "menu.duplicate"
    static let menuCloseTab: LocalizedStringKey = "menu.closeTab"

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

    // MARK: - Welcome Window

    static let welcomeTitle: LocalizedStringKey = "welcome.title"
    static let welcomeSubtitle: LocalizedStringKey = "welcome.subtitle"
    static let welcomeRecentProjects: LocalizedStringKey = "welcome.recentProjects"
    static let welcomeNoRecent: LocalizedStringKey = "welcome.noRecent"

    // MARK: - Terminal Tab Names (runtime)

    static var terminalDefaultName: String {
        String(localized: "terminal.defaultName")
    }

    static func terminalNumberedName(_ number: Int) -> String {
        String(localized: "terminal.numberedName \(number)")
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
}
