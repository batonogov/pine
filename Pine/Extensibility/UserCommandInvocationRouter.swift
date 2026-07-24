//
//  UserCommandInvocationRouter.swift
//  Pine
//
//  Single execution path for registered commands. User keybindings and the
//  command palette both enter here, so availability checks and side effects
//  cannot drift between the two extensibility surfaces (issue #1117).
//

import Foundation

@MainActor
enum UserCommandInvocationRouter {
    static func dispatch(
        _ command: UserCommand,
        projectManager: ProjectManager?,
        notificationCenter: NotificationCenter = .default
    ) {
        let context = context(for: projectManager)
        guard context.satisfies(command.availabilityRequirement) else {
            return
        }

        switch command {
        case .toggleComment, .findInFile, .findAndReplace,
             .findNext, .findPrevious, .findInProject, .goToLine,
             .symbolNavigator, .quickOpen, .commandPalette, .openFolder,
             .toggleWordWrap:
            notificationCenter.post(
                name: Notification.Name(command.notificationKey),
                object: nil
            )

        case .showBranchSwitcher:
            notificationCenter.post(
                name: .showBranchSwitcher,
                object: projectManager
            )

        case .toggleMinimap:
            MinimapSettings.toggle()

        case .toggleBlame:
            let key = BlameConstants.storageKey
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: key), forKey: key)

        case .togglePreview:
            projectManager?.activeTabManager.togglePreviewMode()

        case .toggleTerminal:
            guard let projectManager else { return }
            projectManager.terminal.focusOrCreateTerminal(
                relativeTo: projectManager.paneManager.activePaneID,
                workingDirectory: projectManager.workspace.rootURL
            )

        case .newTerminalTab:
            guard let projectManager else { return }
            projectManager.terminal.createTerminalTab(
                relativeTo: projectManager.paneManager.activePaneID,
                workingDirectory: projectManager.workspace.rootURL
            )
        }
    }

    static func context(
        for projectManager: ProjectManager?
    ) -> CommandPaletteContext {
        guard let projectManager else {
            return .unavailable
        }
        return CommandPaletteContext(
            hasProject: projectManager.workspace.rootURL != nil,
            hasActiveFile: projectManager.activeTabManager.activeTab != nil,
            isGitRepository: projectManager.workspace.gitProvider.isGitRepository,
            hasTerminal: projectManager.hasTerminalPanes
        )
    }
}
