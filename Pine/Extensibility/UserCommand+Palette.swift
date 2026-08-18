//
//  UserCommand+Palette.swift
//  Pine
//
//  Discoverability metadata shared by user keybindings and the command
//  palette. Keeping the title, category, icon, availability requirement, and
//  default shortcut beside the stable command id prevents the palette and
//  keybinding precedence logic from drifting apart.
//

import AppKit
import Foundation

nonisolated extension UserCommand {
    var localizedTitle: String {
        switch self {
        case .newFile:
            String(localized: "menu.newFile")
        case .openFile:
            String(localized: "menu.open")
        case .clearRecentProjects:
            String(localized: "menu.clearMenu")
        case .closeTab:
            String(localized: "menu.closeTab")
        case .closeWindow:
            String(localized: "menu.closeWindow")
        case .closeProject:
            String(localized: "menu.closeProject")
        case .save:
            String(localized: "menu.save")
        case .saveAll:
            String(localized: "menu.saveAll")
        case .saveAs:
            String(localized: "menu.saveAs")
        case .duplicate:
            String(localized: "menu.duplicate")
        case .toggleAutoSave:
            String(localized: "menu.autoSave")
        case .toggleFormatOnSave:
            String(localized: "menu.formatOnSave")
        case .toggleSmartListContinuation:
            String(localized: "menu.smartListContinuation")
        case .toggleComment:
            String(localized: "menu.toggleComment")
        case .findInFile:
            String(localized: "menu.find")
        case .findAndReplace:
            String(localized: "menu.findAndReplace")
        case .findNext:
            String(localized: "menu.findNext")
        case .findPrevious:
            String(localized: "menu.findPrevious")
        case .useSelectionForFind:
            String(localized: "menu.useSelectionForFind")
        case .findInProject:
            String(localized: "menu.findInProject")
        case .goToLine:
            String(localized: "menu.goToLine")
        case .nextChange:
            String(localized: "menu.nextChange")
        case .previousChange:
            String(localized: "menu.previousChange")
        case .acceptChange:
            String(localized: "menu.acceptChange")
        case .revertChange:
            String(localized: "menu.revertChange")
        case .acceptAllChanges:
            String(localized: "menu.acceptAllChanges")
        case .revertAllChanges:
            String(localized: "menu.revertAllChanges")
        case .foldCode:
            String(localized: "menu.foldCode")
        case .unfoldCode:
            String(localized: "menu.unfoldCode")
        case .foldAll:
            String(localized: "menu.foldAll")
        case .unfoldAll:
            String(localized: "menu.unfoldAll")
        case .symbolNavigator:
            String(localized: "menu.symbolNavigator")
        case .quickOpen:
            String(localized: "menu.quickOpen")
        case .commandPalette:
            String(localized: "menu.commandPalette")
        case .openFolder:
            String(localized: "menu.openFolder")
        case .showBranchSwitcher:
            String(localized: "menu.switchBranch")
        case .increaseFontSize:
            String(localized: "menu.increaseFontSize")
        case .decreaseFontSize:
            String(localized: "menu.decreaseFontSize")
        case .resetFontSize:
            String(localized: "menu.resetFontSize")
        case .toggleWordWrap:
            String(localized: "menu.toggleWordWrap")
        case .toggleMinimap:
            String(localized: "menu.toggleMinimap")
        case .toggleBlame:
            String(localized: "menu.toggleBlame")
        case .togglePreview:
            String(localized: "menu.togglePreview")
        case .revealFileInFinder:
            String(localized: "menu.revealFileInFinder")
        case .revealProjectInFinder:
            String(localized: "menu.revealProjectInFinder")
        case .showAgentActivity:
            String(localized: "menu.agentActivity")
        case .showAgentHistory:
            String(localized: "menu.agentHistory")
        case .showAgentInbox:
            String(localized: "menu.agentInbox")
        case .toggleTerminal:
            String(localized: "terminal.toggle")
        case .newTerminalTab:
            String(localized: "menu.newTerminalTab")
        case .findInTerminal:
            String(localized: "menu.findInTerminal")
        case .sendToTerminal:
            String(localized: "menu.sendToTerminal")
        case .toggleTerminalZoom:
            String(localized: "menu.toggleTerminalZoom")
        case .editKeybindings:
            String(localized: "menu.editKeybindings")
        case .editTasks:
            String(localized: "menu.editTasks")
        case .reloadUserConfiguration:
            String(localized: "menu.reloadUserConfiguration")
        case .showProblems:
            String(localized: "menu.problems")
        case .nextDiagnostic:
            String(localized: "menu.nextDiagnostic")
        case .previousDiagnostic:
            String(localized: "menu.previousDiagnostic")
        }
    }

    var category: CommandPaletteCategory {
        switch self {
        case .save, .saveAll, .saveAs, .duplicate, .toggleAutoSave,
             .toggleFormatOnSave, .toggleSmartListContinuation,
             .newFile, .openFile, .clearRecentProjects,
             .closeTab, .closeWindow, .closeProject,
             .openFolder, .quickOpen, .symbolNavigator, .commandPalette:
            .file
        case .toggleComment, .findInFile, .findAndReplace,
             .findNext, .findPrevious, .useSelectionForFind,
             .findInProject, .goToLine, .nextChange, .previousChange,
             .acceptChange, .revertChange, .acceptAllChanges,
             .revertAllChanges, .foldCode, .unfoldCode, .foldAll,
             .unfoldAll:
            .edit
        case .increaseFontSize, .decreaseFontSize, .resetFontSize,
             .toggleWordWrap, .toggleMinimap, .toggleBlame, .togglePreview,
             .revealFileInFinder, .revealProjectInFinder,
             .showAgentActivity, .showAgentHistory, .showAgentInbox,
             .showProblems:
            .view
        case .nextDiagnostic, .previousDiagnostic:
            .edit
        case .showBranchSwitcher:
            .git
        case .toggleTerminal, .newTerminalTab, .findInTerminal,
             .sendToTerminal, .toggleTerminalZoom:
            .terminal
        case .editKeybindings, .editTasks, .reloadUserConfiguration:
            .tasks
        }
    }

    var iconName: String {
        switch self {
        case .newFile:
            MenuIcons.newFile
        case .openFile:
            MenuIcons.openFile
        case .clearRecentProjects:
            MenuIcons.clearMenu
        case .closeTab:
            MenuIcons.closeTab
        case .closeWindow:
            MenuIcons.closeWindow
        case .closeProject:
            MenuIcons.closeProject
        case .save:
            MenuIcons.save
        case .saveAll:
            MenuIcons.saveAll
        case .saveAs:
            MenuIcons.saveAs
        case .duplicate:
            MenuIcons.duplicate
        case .toggleAutoSave:
            MenuIcons.autoSave
        case .toggleFormatOnSave:
            MenuIcons.formatOnSave
        case .toggleSmartListContinuation:
            MenuIcons.smartListContinuation
        case .toggleComment:
            MenuIcons.toggleComment
        case .findInFile, .findNext, .findPrevious:
            MenuIcons.find
        case .findAndReplace:
            MenuIcons.findAndReplace
        case .useSelectionForFind:
            MenuIcons.find
        case .findInProject:
            MenuIcons.findInProject
        case .goToLine:
            MenuIcons.goToLine
        case .nextChange:
            MenuIcons.nextChange
        case .previousChange:
            MenuIcons.previousChange
        case .acceptChange:
            MenuIcons.acceptChange
        case .revertChange:
            MenuIcons.revertChange
        case .acceptAllChanges:
            MenuIcons.acceptAllChanges
        case .revertAllChanges:
            MenuIcons.revertAllChanges
        case .foldCode:
            MenuIcons.foldCode
        case .unfoldCode:
            MenuIcons.unfoldCode
        case .foldAll:
            MenuIcons.foldAll
        case .unfoldAll:
            MenuIcons.unfoldAll
        case .symbolNavigator:
            MenuIcons.symbolNavigator
        case .quickOpen:
            MenuIcons.quickOpen
        case .commandPalette:
            MenuIcons.commandPalette
        case .openFolder:
            MenuIcons.openFolder
        case .showBranchSwitcher:
            MenuIcons.switchBranch
        case .increaseFontSize:
            MenuIcons.increaseFontSize
        case .decreaseFontSize:
            MenuIcons.decreaseFontSize
        case .resetFontSize:
            MenuIcons.resetFontSize
        case .toggleWordWrap:
            MenuIcons.toggleWordWrap
        case .toggleMinimap:
            MenuIcons.toggleMinimap
        case .toggleBlame:
            MenuIcons.toggleBlame
        case .togglePreview:
            MenuIcons.togglePreview
        case .revealFileInFinder:
            MenuIcons.revealFileInFinder
        case .revealProjectInFinder:
            MenuIcons.revealProjectInFinder
        case .showAgentActivity:
            MenuIcons.agentActivity
        case .showAgentHistory:
            MenuIcons.agentHistory
        case .showAgentInbox:
            MenuIcons.agentInbox
        case .toggleTerminal:
            MenuIcons.toggleTerminal
        case .newTerminalTab:
            MenuIcons.newTerminalTab
        case .findInTerminal:
            MenuIcons.find
        case .sendToTerminal:
            MenuIcons.sendToTerminal
        case .toggleTerminalZoom:
            MenuIcons.maximizeTerminal
        case .editKeybindings:
            MenuIcons.editKeybindings
        case .editTasks:
            MenuIcons.editTasks
        case .reloadUserConfiguration:
            MenuIcons.reloadUserConfiguration
        case .showProblems:
            MenuIcons.problems
        case .nextDiagnostic:
            MenuIcons.nextDiagnostic
        case .previousDiagnostic:
            MenuIcons.previousDiagnostic
        }
    }

    var availabilityRequirement: CommandAvailabilityRequirement {
        switch self {
        case .openFolder, .clearRecentProjects,
             .increaseFontSize, .decreaseFontSize,
             .resetFontSize, .showAgentInbox, .editKeybindings, .editTasks,
             .reloadUserConfiguration:
            .always
        case .newFile, .openFile,
             .quickOpen, .commandPalette, .saveAll, .toggleAutoSave,
             .toggleFormatOnSave, .toggleSmartListContinuation,
             .closeTab, .closeWindow, .closeProject,
             .findInProject, .toggleTerminal, .newTerminalTab,
             .toggleMinimap, .toggleBlame, .toggleWordWrap,
             .revealProjectInFinder, .showAgentActivity, .showAgentHistory,
             .showProblems, .nextDiagnostic, .previousDiagnostic:
            .project
        case .showBranchSwitcher:
            .gitRepository
        case .findInTerminal, .toggleTerminalZoom:
            .terminal
        case .sendToTerminal:
            .activeFileAndTerminal
        case .save, .saveAs, .duplicate, .toggleComment, .findInFile,
             .findAndReplace, .findNext, .findPrevious,
             .useSelectionForFind, .goToLine, .nextChange,
             .previousChange, .acceptChange, .revertChange,
             .acceptAllChanges, .revertAllChanges, .foldCode,
             .unfoldCode, .foldAll, .unfoldAll, .symbolNavigator,
             .togglePreview, .revealFileInFinder:
            .activeFile
        }
    }

    var defaultChord: ParsedKeyChord? {
        if self == .increaseFontSize {
            return ParsedKeyChord(modifiers: .command, key: "+")
        }
        let value: String?
        switch self {
        case .save:
            value = "cmd+s"
        case .saveAll:
            value = "cmd+option+s"
        case .saveAs:
            value = "cmd+shift+s"
        case .duplicate:
            value = "cmd+shift+d"
        case .toggleAutoSave, .toggleFormatOnSave,
             .toggleSmartListContinuation:
            value = nil
        case .toggleComment:
            value = "cmd+/"
        case .findInFile:
            value = "cmd+f"
        case .findAndReplace:
            value = "cmd+option+f"
        case .findNext:
            value = "cmd+g"
        case .findPrevious:
            value = "cmd+shift+g"
        case .useSelectionForFind:
            value = "cmd+e"
        case .findInProject:
            value = "cmd+shift+f"
        case .goToLine:
            value = "cmd+l"
        case .nextChange:
            value = "ctrl+option+down"
        case .previousChange:
            value = "ctrl+option+up"
        case .acceptChange:
            value = "ctrl+option+return"
        case .revertChange:
            value = "ctrl+option+delete"
        case .acceptAllChanges, .revertAllChanges:
            value = nil
        case .foldCode:
            value = "cmd+option+left"
        case .unfoldCode:
            value = "cmd+option+right"
        case .foldAll:
            value = "cmd+option+shift+left"
        case .unfoldAll:
            value = "cmd+option+shift+right"
        case .symbolNavigator:
            value = "cmd+r"
        case .quickOpen:
            value = "cmd+p"
        case .commandPalette:
            value = "cmd+option+p"
        case .openFolder:
            value = "cmd+shift+o"
        case .showBranchSwitcher:
            value = "cmd+shift+b"
        case .increaseFontSize:
            value = nil
        case .decreaseFontSize:
            value = "cmd+-"
        case .resetFontSize:
            value = "cmd+0"
        case .toggleWordWrap:
            value = "option+z"
        case .toggleMinimap:
            value = "cmd+shift+m"
        case .toggleBlame:
            value = "cmd+control+b"
        case .togglePreview:
            value = "cmd+shift+p"
        case .revealFileInFinder:
            value = "cmd+shift+r"
        case .revealProjectInFinder, .showAgentActivity,
             .showAgentHistory:
            value = nil
        case .showAgentInbox:
            value = "cmd+shift+i"
        case .toggleTerminal:
            value = "cmd+`"
        case .newTerminalTab:
            value = "cmd+t"
        case .findInTerminal:
            value = nil
        case .sendToTerminal:
            value = "cmd+shift+return"
        case .toggleTerminalZoom:
            value = "cmd+option+return"
        case .editKeybindings, .editTasks, .reloadUserConfiguration:
            value = nil
        case .newFile:
            value = "cmd+n"
        case .openFile:
            value = "cmd+o"
        case .clearRecentProjects:
            value = nil
        case .closeTab:
            value = "cmd+w"
        case .closeWindow:
            value = "cmd+shift+w"
        case .closeProject:
            // cmd+shift+w already closes the window; closing one project
            // inside it is the narrower action and takes the freer chord.
            value = "ctrl+cmd+w"
        case .showProblems:
            value = "cmd+shift+x"
        case .nextDiagnostic:
            value = "f8"
        case .previousDiagnostic:
            value = "shift+f8"
        }
        return value.flatMap(UserKeybindingRegistry.parse)
    }
}
