//
//  UserCommand+Palette.swift
//  Pine
//
//  Discoverability metadata shared by user keybindings and the command
//  palette. Keeping the title, category, icon, availability requirement, and
//  default shortcut beside the stable command id prevents the palette and
//  keybinding precedence logic from drifting apart.
//

import Foundation

nonisolated extension UserCommand {
    var localizedTitle: String {
        switch self {
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
        case .findInProject:
            String(localized: "menu.findInProject")
        case .goToLine:
            String(localized: "menu.goToLine")
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
        case .toggleWordWrap:
            String(localized: "menu.toggleWordWrap")
        case .toggleMinimap:
            String(localized: "menu.toggleMinimap")
        case .toggleBlame:
            String(localized: "menu.toggleBlame")
        case .togglePreview:
            String(localized: "menu.togglePreview")
        case .toggleTerminal:
            String(localized: "terminal.toggle")
        case .newTerminalTab:
            String(localized: "menu.newTerminalTab")
        }
    }

    var category: CommandPaletteCategory {
        switch self {
        case .openFolder, .quickOpen, .symbolNavigator, .commandPalette:
            .file
        case .toggleComment, .findInFile, .findAndReplace,
             .findNext, .findPrevious, .findInProject, .goToLine:
            .edit
        case .toggleWordWrap, .toggleMinimap, .toggleBlame, .togglePreview:
            .view
        case .showBranchSwitcher:
            .git
        case .toggleTerminal, .newTerminalTab:
            .terminal
        }
    }

    var iconName: String {
        switch self {
        case .toggleComment:
            MenuIcons.toggleComment
        case .findInFile, .findNext, .findPrevious:
            MenuIcons.find
        case .findAndReplace:
            MenuIcons.findAndReplace
        case .findInProject:
            MenuIcons.findInProject
        case .goToLine:
            MenuIcons.goToLine
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
        case .toggleWordWrap:
            MenuIcons.toggleWordWrap
        case .toggleMinimap:
            MenuIcons.toggleMinimap
        case .toggleBlame:
            MenuIcons.toggleBlame
        case .togglePreview:
            MenuIcons.togglePreview
        case .toggleTerminal:
            MenuIcons.toggleTerminal
        case .newTerminalTab:
            MenuIcons.newTerminalTab
        }
    }

    var availabilityRequirement: CommandAvailabilityRequirement {
        switch self {
        case .openFolder:
            .always
        case .quickOpen, .commandPalette:
            .project
        case .showBranchSwitcher:
            .gitRepository
        case .toggleTerminal, .newTerminalTab:
            .project
        case .toggleMinimap, .toggleBlame, .toggleWordWrap:
            .project
        case .toggleComment, .findInFile, .findAndReplace,
             .findNext, .findPrevious, .findInProject, .goToLine,
             .symbolNavigator, .togglePreview:
            .activeFile
        }
    }

    var defaultChord: ParsedKeyChord? {
        let value: String?
        switch self {
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
        case .findInProject:
            value = "cmd+shift+f"
        case .goToLine:
            value = "cmd+l"
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
        case .toggleWordWrap:
            value = "option+z"
        case .toggleMinimap:
            value = "cmd+shift+m"
        case .toggleBlame:
            value = "cmd+control+b"
        case .togglePreview:
            value = "cmd+shift+p"
        case .toggleTerminal:
            value = "cmd+`"
        case .newTerminalTab:
            value = "cmd+t"
        }
        return value.flatMap(UserKeybindingRegistry.parse)
    }
}
