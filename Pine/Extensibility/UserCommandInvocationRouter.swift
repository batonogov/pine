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
        notificationCenter: NotificationCenter = .default
    ) {
        let context = context(for: projectManager)
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
            saveAs(projectManager: projectManager)

        case .duplicate:
            guard let projectManager else { return }
            projectManager.activeTabManager.duplicateActiveTab(
                projectRoot: projectManager.workspace.rootURL
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
             .findInProject, .goToLine,
             .symbolNavigator, .quickOpen, .openFolder,
             .toggleWordWrap, .showAgentActivity, .showAgentHistory,
             .findInTerminal, .sendToTerminal:
            notificationCenter.post(
                name: Notification.Name(command.notificationKey),
                object: nil
            )

        case .commandPalette:
            notificationCenter.post(
                name: .showCommandPalette,
                object: projectManager
            )

        case .nextChange, .previousChange:
            let direction = command == .nextChange ? "next" : "previous"
            notificationCenter.post(
                name: .navigateChange,
                object: nil,
                userInfo: ["direction": direction]
            )

        case .acceptChange, .revertChange,
             .acceptAllChanges, .revertAllChanges:
            notificationCenter.post(
                name: .inlineDiffAction,
                object: nil,
                userInfo: ["action": command.inlineDiffAction]
            )

        case .foldCode, .unfoldCode, .foldAll, .unfoldAll:
            notificationCenter.post(
                name: .foldCode,
                object: nil,
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
            guard let url = projectManager?.activeTabManager.activeTab?.url else {
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
            Task { @MainActor in
                await UserConfigurationEditor.openKeybindings()
            }

        case .editTasks:
            Task { @MainActor in
                await UserConfigurationEditor.openTasks()
            }

        case .reloadUserConfiguration:
            Task { @MainActor in
                await PineAppMenuCommands
                    .reloadAndPresentConfigurationDiagnostics()
            }
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

    private static func saveAs(projectManager: ProjectManager) {
        let tabManager = projectManager.activeTabManager
        guard let activeTab = tabManager.activeTab else { return }

        let panel = NSSavePanel()
        panel.title = Strings.saveAsPanelTitle
        panel.nameFieldStringValue = activeTab.fileName
        panel.directoryURL = activeTab.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Keep the file mutation outside the originating menu/key-event
        // call stack to avoid the #1058 Swift exclusivity-abort family.
        DispatchQueue.main.async {
            do {
                try tabManager.saveActiveTabAs(to: url)
                Task {
                    await projectManager.workspace.gitProvider.refreshAsync()
                    NotificationCenter.default.post(
                        name: .refreshLineDiffs,
                        object: nil
                    )
                }
            } catch {
                AlertTemplate.fileOperationErrorCritical.runModal(
                    messageText: Strings.fileOperationErrorTitle,
                    informativeText: error.localizedDescription
                )
            }
        }
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
