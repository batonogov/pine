//
//  UserCommandInvocationRouter.swift
//  Pine
//
//  Single execution path for registered commands. User keybindings and the
//  command palette both enter here, so availability checks and side effects
//  cannot drift between the two extensibility surfaces (issue #1117).
//

import AppKit
import Foundation

@MainActor
enum UserCommandInvocationRouter {
    static func dispatch(
        _ command: UserCommand,
        projectManager: ProjectManager?,
        windowAvailability: ProjectWindowCommandAvailability = .none,
        notificationCenter: NotificationCenter = .default
    ) {
        let context = context(
            for: projectManager,
            windowAvailability: windowAvailability
        )
        guard context.satisfies(command.availabilityRequirement) else {
            return
        }

        switch command {
        case .save:
            projectManager?.saveActiveTabFromMenu()

        case .saveAll:
            projectManager?.saveAllTabsFromMenu()

        case .saveAs:
            guard let projectManager else { return }
            projectManager.saveActiveTabAsFromMenu()

        case .duplicate:
            guard let projectManager,
                  projectManager.paneManager.root.content(
                      for: projectManager.paneManager.activePaneID
                  ) == .editor,
                  let tabManager = projectManager.paneManager.activeTabManager
            else {
                return
            }
            tabManager.duplicateActiveTab(
                projectRoot: projectManager.workspace.rootURL,
                context: DialogPresenter.forProject(projectManager)
            )

        case .toggleAutoSave:
            let defaults = UserDefaults.standard
            let key = TabManager.autoSaveKey
            defaults.set(!defaults.bool(forKey: key), forKey: key)

        case .toggleFormatOnSave:
            let settings = EditorSettings.shared
            settings.formatOnSave.toggle()

        case .toggleSmartListContinuation:
            let settings = EditorSettings.shared
            settings.smartListContinuation.toggle()

        case .toggleComment, .findInFile, .findAndReplace,
             .findNext, .findPrevious, .useSelectionForFind,
             .findInProject,
             .toggleWordWrap, .showAgentActivity, .showAgentHistory,
             .findInTerminal, .sendToTerminal:
            notificationCenter.post(
                name: Notification.Name(command.notificationKey),
                object: projectManager
            )

        case .openFolder:
            notificationCenter.post(
                name: .openFolder,
                object: projectManager
            )

        case .newFile, .openFile, .closeTab, .closeWindow, .closeProject:
            notificationCenter.post(
                name: Notification.Name(command.notificationKey),
                object: projectManager
            )

        case .clearRecentProjects:
            notificationCenter.post(
                name: .clearRecentProjects,
                object: nil
            )

        case .showAgentInbox:
            notificationCenter.post(
                name: .showAgentInbox,
                object: nil
            )

        case .newAgent:
            // No identifier: the palette and user keybindings mean the
            // preferred (last-used) agent. Only a menu item names one.
            ProjectAgentLaunchSelection.post(
                identifier: nil,
                projectManager: projectManager,
                notificationCenter: notificationCenter
            )

        case .nextProjectInWindow, .previousProjectInWindow:
            let direction: ProjectWindowSwitchOrder.Direction =
                command == .nextProjectInWindow ? .next : .previous
            notificationCenter.post(
                name: .switchProjectInWindow,
                object: projectManager,
                userInfo: ["direction": direction.rawValue]
            )

        case .goToLine, .symbolNavigator, .quickOpen, .commandPalette:
            notificationCenter.post(
                name: Notification.Name(command.notificationKey),
                object: projectManager
            )

        case .nextChange, .previousChange:
            let direction = command == .nextChange ? "next" : "previous"
            notificationCenter.post(
                name: .navigateChange,
                object: projectManager,
                userInfo: ["direction": direction]
            )

        case .acceptChange, .revertChange,
             .acceptAllChanges, .revertAllChanges:
            notificationCenter.post(
                name: .inlineDiffAction,
                object: projectManager,
                userInfo: ["action": command.inlineDiffAction]
            )

        case .foldCode, .unfoldCode, .foldAll, .unfoldAll:
            notificationCenter.post(
                name: .foldCode,
                object: projectManager,
                userInfo: ["action": command.foldAction]
            )

        case .showBranchSwitcher:
            notificationCenter.post(
                name: .showBranchSwitcher,
                object: projectManager
            )

        case .increaseFontSize:
            FontSizeSettings.shared.increase()

        case .decreaseFontSize:
            FontSizeSettings.shared.decrease()

        case .resetFontSize:
            FontSizeSettings.shared.reset()

        case .toggleMinimap:
            MinimapSettings.toggle()

        case .toggleBlame:
            let key = BlameConstants.storageKey
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: key), forKey: key)

        case .togglePreview:
            projectManager?.activeTabManager.togglePreviewMode()

        case .revealFileInFinder:
            guard let projectManager,
                  projectManager.paneManager.root.content(
                      for: projectManager.paneManager.activePaneID
                  ) == .editor,
                  let url = projectManager.paneManager.activeTabManager?
                      .activeTab?
                      .fileURL else {
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])

        case .revealProjectInFinder:
            guard let url = projectManager?.workspace.rootURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])

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

        case .toggleTerminalZoom:
            projectManager?.paneManager.toggleMaximizeOnActiveTerminalPane()

        case .editKeybindings:
            let presentationContext = if let projectManager {
                DialogPresenter.forProject(projectManager)
            } else {
                DialogPresenter.forKeyWindow()
            }
            let presenter = AppKitUserConfigurationAlertPresenter(
                context: presentationContext
            )
            Task { @MainActor in
                await UserConfigurationEditor.openKeybindings(
                    alertPresenter: presenter
                )
            }

        case .editTasks:
            let presentationContext = if let projectManager {
                DialogPresenter.forProject(projectManager)
            } else {
                DialogPresenter.forKeyWindow()
            }
            let presenter = AppKitUserConfigurationAlertPresenter(
                context: presentationContext
            )
            Task { @MainActor in
                await UserConfigurationEditor.openTasks(
                    alertPresenter: presenter
                )
            }

        case .reloadUserConfiguration:
            let presentationContext = if let projectManager {
                DialogPresenter.forProject(projectManager)
            } else {
                DialogPresenter.forKeyWindow()
            }
            let presenter = AppKitUserConfigurationAlertPresenter(
                context: presentationContext
            )
            Task { @MainActor in
                await PineAppMenuCommands
                    .reloadAndPresentConfigurationDiagnostics(
                        alertPresenter: presenter
                    )
            }

        case .showProblems:
            notificationCenter.post(
                name: .showProblems,
                object: projectManager
            )

        case .nextDiagnostic:
            notificationCenter.post(
                name: .nextDiagnostic,
                object: projectManager
            )

        case .previousDiagnostic:
            notificationCenter.post(
                name: .previousDiagnostic,
                object: projectManager
            )
        }
    }

    static func context(
        for projectManager: ProjectManager?,
        windowAvailability: ProjectWindowCommandAvailability = .none
    ) -> CommandPaletteContext {
        guard let projectManager else {
            return .unavailable
        }
        let nativeState = NativeMenuCommandState(
            projectManager: projectManager
        )
        return CommandPaletteContext(
            hasProject: projectManager.workspace.rootURL != nil,
            hasActiveFile: nativeState.activeEditorTabID != nil,
            isGitRepository: projectManager.workspace.gitProvider.isGitRepository,
            hasTerminal: projectManager.hasTerminalPanes,
            canLaunchAgent: windowAvailability.canLaunchAgent,
            canSwitchProjectInWindow: windowAvailability.canSwitchProject
        )
    }

}

nonisolated private extension UserCommand {
    var inlineDiffAction: InlineDiffAction {
        switch self {
        case .acceptChange:
            .accept
        case .revertChange:
            .revert
        case .acceptAllChanges:
            .acceptAll
        case .revertAllChanges:
            .revertAll
        default:
            preconditionFailure("Command does not represent an inline-diff action")
        }
    }

    var foldAction: String {
        switch self {
        case .foldCode:
            "fold"
        case .unfoldCode:
            "unfold"
        case .foldAll:
            "foldAll"
        case .unfoldAll:
            "unfoldAll"
        default:
            preconditionFailure("Command does not represent a fold action")
        }
    }
}
