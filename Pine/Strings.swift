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

    static let menuView: LocalizedStringKey = "menu.view"
    static let menuGit: LocalizedStringKey = "menu.git"
    static let menuOpenFolder: LocalizedStringKey = "menu.openFolder"
    static let menuSwitchBranch: LocalizedStringKey = "menu.switchBranch"
    static let menuSave: LocalizedStringKey = "menu.save"
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

    // MARK: - Open Panel (AppKit)

    static var openPanelMessage: String {
        String(localized: "openPanel.message")
    }

    static var openPanelPrompt: String {
        String(localized: "openPanel.prompt")
    }

    // MARK: - Terminal Tab Names (runtime)

    static var terminalDefaultName: String {
        String(localized: "terminal.defaultName")
    }

    static func terminalNumberedName(_ number: Int) -> String {
        String(localized: "terminal.numberedName \(number)")
    }
}
