//
//  PineAppMenuCommands.swift
//  Pine
//
//  Created by Федор Батоногов on 09.04.2026.
//
//  Menu command definitions (CommandGroup / CommandMenu) for the main Scene.
//  Extracted from PineApp.swift as part of refactor #756.
//
//  All menu items post NotificationCenter events or call into the
//  currently-focused ProjectManager via @FocusedValue. Notification names
//  live in PineAppNotifications.swift; strings in Strings.swift; icons
//  in MenuIcons.swift.
//
//  Declaration order mirrors the macOS menu bar left-to-right:
//  App (about/CLI) → File (open/save) → Edit (find/fold/diff) →
//  View (font/minimap/reveal) → Git → Terminal.
//

import AppKit
import SwiftUI

/// Top-level `Commands` struct containing every `CommandGroup` / `CommandMenu`
/// that PineApp attaches to its main `WindowGroup`. Keeping this in its own
/// file isolates the high-churn menu definitions from the small
/// `@main` + Scene wiring in `PineApp.swift`.
struct PineAppMenuCommands: Commands {
    /// Needed for `CheckForUpdatesView(viewModel:)` which requires access to
    /// the Sparkle updater view model owned by `AppDelegate`. Strong reference
    /// is safe: `AppDelegate` does not retain this value-type `Commands` struct,
    /// and the struct lives inside `Scene.body` for the app's lifetime.
    let appDelegate: AppDelegate
    @FocusedValue(\.projectManager) private var focusedProject: ProjectManager?
    @AppStorage(TabManager.autoSaveKey) private var autoSaveEnabled = false
    var body: some Commands {
        // MARK: - App menu (About / CLI install)
        CommandGroup(replacing: .appInfo) {
            Button("About Pine") {
                AboutInfo.showAboutPanel()
            }

            CheckForUpdatesView(viewModel: appDelegate.checkForUpdatesViewModel)

            Divider()

            Button {
                if CLIInstaller.isInstalled {
                    CLIInstaller.uninstall(projectManager: focusedProject)
                } else {
                    CLIInstaller.install(projectManager: focusedProject)
                }
            } label: {
                Text(CLIInstaller.isInstalled
                     ? "Uninstall Command Line Tool..."
                     : "Install Command Line Tool...")
            }
        }

        // MARK: - File menu
        // Убираем стандартный "New Window" (Cmd+N) — табы создаются кликом по файлу
        CommandGroup(replacing: .newItem) { }
        // Cmd+Shift+O — Open Folder, Cmd+P — Quick Open, Cmd+R — Symbol Navigator
        CommandGroup(after: .newItem) {
            Button {
                NotificationCenter.default.post(name: .openFolder, object: nil)
            } label: {
                Label(Strings.menuOpenFolder, systemImage: MenuIcons.openFolder)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button {
                NotificationCenter.default.post(
                    name: .showQuickOpen,
                    object: focusedProject
                )
            } label: {
                Label(Strings.menuQuickOpen, systemImage: MenuIcons.quickOpen)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(focusedProject?.workspace.rootURL == nil)

            Button {
                NotificationCenter.default.post(
                    name: .showCommandPalette,
                    object: focusedProject
                )
            } label: {
                Label(
                    Strings.menuCommandPalette,
                    systemImage: MenuIcons.commandPalette
                )
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(focusedProject?.workspace.rootURL == nil)

            Button {
                NotificationCenter.default.post(
                    name: .showSymbolNavigator,
                    object: focusedProject
                )
            } label: {
                Label(Strings.menuSymbolNavigator, systemImage: MenuIcons.symbolNavigator)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(focusedProject?.activeTabManager.activeTab == nil)
        }
        // Save, Save All, Save As, Duplicate, Auto-save toggle
        CommandGroup(replacing: .saveItem) {
            Button {
                guard let pm = focusedProject else { return }
                // Deferred via ProjectManager.saveActiveTabFromMenu() to break
                // reentrancy (#1058): saveActiveTab mutates @Observable tab
                // state synchronously when format-on-save changes content; doing
                // that inside the ButtonAction callstack triggers an exclusivity
                // abort on macOS 26.5.1.
                pm.saveActiveTabFromMenu()
            } label: {
                Label(Strings.menuSave, systemImage: MenuIcons.save)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button {
                guard let pm = focusedProject else { return }
                // Same reentrancy rationale as Save (#1058).
                pm.saveAllTabsFromMenu()
            } label: {
                Label(Strings.menuSaveAll, systemImage: MenuIcons.saveAll)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Divider()

            Button {
                guard let pm = focusedProject else { return }
                UserCommandInvocationRouter.dispatch(
                    .saveAs,
                    projectManager: pm
                )
            } label: {
                Label(Strings.menuSaveAs, systemImage: MenuIcons.saveAs)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                guard let pm = focusedProject else { return }
                pm.activeTabManager.duplicateActiveTab(
                    projectRoot: pm.workspace.rootURL,
                    context: DialogPresenter.forProject(pm)
                )
            } label: {
                Label(Strings.menuDuplicate, systemImage: MenuIcons.duplicate)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Toggle(isOn: $autoSaveEnabled) {
                Label(Strings.menuAutoSave, systemImage: MenuIcons.autoSave)
            }

            Toggle(
                isOn: Bindable(EditorSettings.shared).formatOnSave
            ) {
                Label(Strings.menuFormatOnSave, systemImage: MenuIcons.formatOnSave)
            }

            Toggle(
                isOn: Bindable(EditorSettings.shared).smartListContinuation
            ) {
                Label(Strings.menuSmartListContinuation, systemImage: MenuIcons.smartListContinuation)
            }
        }

        // MARK: - Edit menu
        // Toggle Comment, Find & Replace, Find in Project, Go to Line,
        // inline diff navigation/accept/revert, code folding
        CommandGroup(after: .pasteboard) {
            Button {
                NotificationCenter.default.post(name: .toggleComment, object: nil)
            } label: {
                Label(Strings.menuToggleComment, systemImage: MenuIcons.toggleComment)
            }
            .keyboardShortcut("/", modifiers: .command)

            Divider()

            Button {
                NotificationCenter.default.post(name: .findInFile, object: nil)
            } label: {
                Label(Strings.menuFind, systemImage: MenuIcons.find)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(name: .findAndReplace, object: nil)
            } label: {
                Label(Strings.menuFindAndReplace, systemImage: MenuIcons.findAndReplace)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(name: .findNext, object: nil)
            } label: {
                Label(Strings.menuFindNext, systemImage: MenuIcons.nextChange)
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(name: .findPrevious, object: nil)
            } label: {
                Label(Strings.menuFindPrevious, systemImage: MenuIcons.previousChange)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(name: .useSelectionForFind, object: nil)
            } label: {
                Label(Strings.menuUseSelectionForFind, systemImage: MenuIcons.find)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Divider()

            Button {
                NotificationCenter.default.post(name: .showProjectSearch, object: nil)
            } label: {
                Label(Strings.menuFindInProject, systemImage: MenuIcons.findInProject)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Button {
                NotificationCenter.default.post(
                    name: .goToLine,
                    object: focusedProject
                )
            } label: {
                Label(Strings.menuGoToLine, systemImage: MenuIcons.goToLine)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Divider()

            Button {
                NotificationCenter.default.post(
                    name: .navigateChange, object: nil,
                    userInfo: ["direction": "next"]
                )
            } label: {
                Label(Strings.menuNextChange, systemImage: MenuIcons.nextChange)
            }
            .keyboardShortcut(.downArrow, modifiers: [.control, .option])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .navigateChange, object: nil,
                    userInfo: ["direction": "previous"]
                )
            } label: {
                Label(Strings.menuPreviousChange, systemImage: MenuIcons.previousChange)
            }
            .keyboardShortcut(.upArrow, modifiers: [.control, .option])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .inlineDiffAction, object: nil,
                    userInfo: ["action": InlineDiffAction.accept]
                )
            } label: {
                Label(Strings.menuAcceptChange, systemImage: MenuIcons.acceptChange)
            }
            .keyboardShortcut(.return, modifiers: [.control, .option])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .inlineDiffAction, object: nil,
                    userInfo: ["action": InlineDiffAction.revert]
                )
            } label: {
                Label(Strings.menuRevertChange, systemImage: MenuIcons.revertChange)
            }
            .keyboardShortcut(.delete, modifiers: [.control, .option])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .inlineDiffAction, object: nil,
                    userInfo: ["action": InlineDiffAction.acceptAll]
                )
            } label: {
                Label(Strings.menuAcceptAllChanges, systemImage: MenuIcons.acceptAllChanges)
            }
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .inlineDiffAction, object: nil,
                    userInfo: ["action": InlineDiffAction.revertAll]
                )
            } label: {
                Label(Strings.menuRevertAllChanges, systemImage: MenuIcons.revertAllChanges)
            }
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Divider()

            Button {
                NotificationCenter.default.post(
                    name: .foldCode, object: nil,
                    userInfo: ["action": "fold"]
                )
            } label: {
                Label(Strings.menuFoldCode, systemImage: MenuIcons.foldCode)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .foldCode, object: nil,
                    userInfo: ["action": "unfold"]
                )
            } label: {
                Label(Strings.menuUnfoldCode, systemImage: MenuIcons.unfoldCode)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .foldCode, object: nil,
                    userInfo: ["action": "foldAll"]
                )
            } label: {
                Label(Strings.menuFoldAll, systemImage: MenuIcons.foldAll)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .foldCode, object: nil,
                    userInfo: ["action": "unfoldAll"]
                )
            } label: {
                Label(Strings.menuUnfoldAll, systemImage: MenuIcons.unfoldAll)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)
        }

        // MARK: - View menu
        // Font size, terminal toggle, preview, minimap, blame, word wrap, reveal
        CommandGroup(after: .toolbar) {
            Divider()

            Button {
                FontSizeSettings.shared.increase()
            } label: {
                Label(Strings.menuIncreaseFontSize, systemImage: MenuIcons.increaseFontSize)
            }
            .keyboardShortcut("+", modifiers: .command)

            Button {
                FontSizeSettings.shared.decrease()
            } label: {
                Label(Strings.menuDecreaseFontSize, systemImage: MenuIcons.decreaseFontSize)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button {
                FontSizeSettings.shared.reset()
            } label: {
                Label(Strings.menuResetFontSize, systemImage: MenuIcons.resetFontSize)
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button {
                guard let pm = focusedProject else { return }
                pm.terminal.focusOrCreateTerminal(
                    relativeTo: pm.paneManager.activePaneID,
                    workingDirectory: pm.workspace.rootURL
                )
            } label: {
                Label(Strings.toggleTerminal, systemImage: MenuIcons.toggleTerminal)
            }
            .keyboardShortcut("`", modifiers: .command)

            Button {
                guard let pm = focusedProject else { return }
                pm.activeTabManager.togglePreviewMode()
            } label: {
                Label(Strings.menuTogglePreview, systemImage: MenuIcons.togglePreview)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button {
                MinimapSettings.toggle()
            } label: {
                Label(Strings.menuToggleMinimap, systemImage: MenuIcons.toggleMinimap)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button {
                let key = BlameConstants.storageKey
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
            } label: {
                Label(Strings.menuToggleBlame, systemImage: MenuIcons.toggleBlame)
            }
            .keyboardShortcut("b", modifiers: [.command, .control])

            Button {
                NotificationCenter.default.post(name: .toggleWordWrap, object: nil)
            } label: {
                Label(Strings.menuToggleWordWrap, systemImage: MenuIcons.toggleWordWrap)
            }
            .keyboardShortcut("z", modifiers: .option)

            Divider()

            Button {
                guard let pm = focusedProject else { return }
                UserCommandInvocationRouter.dispatch(
                    .showProblems,
                    projectManager: pm
                )
            } label: {
                Label(Strings.menuProblems, systemImage: MenuIcons.problems)
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(focusedProject == nil)

            Button {
                guard let pm = focusedProject else { return }
                UserCommandInvocationRouter.dispatch(
                    .nextDiagnostic,
                    projectManager: pm
                )
            } label: {
                Label(
                    Strings.menuNextDiagnostic,
                    systemImage: MenuIcons.nextDiagnostic
                )
            }
            .keyboardShortcut(KeyEquivalent("\u{F70B}"), modifiers: [])
            .disabled(focusedProject == nil)

            Button {
                guard let pm = focusedProject else { return }
                UserCommandInvocationRouter.dispatch(
                    .previousDiagnostic,
                    projectManager: pm
                )
            } label: {
                Label(
                    Strings.menuPreviousDiagnostic,
                    systemImage: MenuIcons.previousDiagnostic
                )
            }
            .keyboardShortcut(
                KeyEquivalent("\u{F70B}"),
                modifiers: .shift
            )
            .disabled(focusedProject == nil)

            Divider()

            Button {
                focusedProject?.paneManager.moveActiveTab(.leading)
            } label: {
                Label(Strings.tabMoveLeading, systemImage: "arrow.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
            .disabled(focusedProject?.paneManager.canMoveActiveTab(.leading) != true)

            Button {
                focusedProject?.paneManager.moveActiveTab(.trailing)
            } label: {
                Label(Strings.tabMoveTrailing, systemImage: "arrow.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            .disabled(focusedProject?.paneManager.canMoveActiveTab(.trailing) != true)

            Button {
                focusedProject?.paneManager.moveActiveTab(.previousPane)
            } label: {
                Label(Strings.tabMoveToPreviousPane, systemImage: "rectangle.leadinghalf.inset.filled")
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .control, .shift])
            .disabled(focusedProject?.paneManager.canMoveActiveTab(.previousPane) != true)

            Button {
                focusedProject?.paneManager.moveActiveTab(.nextPane)
            } label: {
                Label(Strings.tabMoveToNextPane, systemImage: "rectangle.trailinghalf.inset.filled")
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .control, .shift])
            .disabled(focusedProject?.paneManager.canMoveActiveTab(.nextPane) != true)

            Divider()

            Button {
                guard let pm = focusedProject,
                      let url = pm.activeTabManager.activeTab?.url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label(Strings.menuRevealFileInFinder, systemImage: MenuIcons.revealFileInFinder)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                guard let pm = focusedProject,
                      let rootURL = pm.workspace.rootURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([rootURL])
            } label: {
                Label(Strings.menuRevealProjectInFinder, systemImage: MenuIcons.revealProjectInFinder)
            }
            .disabled(focusedProject?.workspace.rootURL == nil)

            Divider()

            Button {
                NotificationCenter.default.post(name: .showAgentActivity, object: nil)
            } label: {
                Label(Strings.menuAgentActivity, systemImage: MenuIcons.agentActivity)
            }

            Button {
                NotificationCenter.default.post(name: .showAgentHistory, object: nil)
            } label: {
                Label(Strings.menuAgentHistory, systemImage: MenuIcons.agentHistory)
            }
            .disabled(focusedProject?.workspace.rootURL == nil)
        }

        // MARK: - Git menu
        CommandMenu(Strings.menuGit) {
            Button {
                guard let focusedProject else { return }
                NotificationCenter.default.post(name: .showBranchSwitcher, object: focusedProject)
            } label: {
                Label(Strings.menuSwitchBranch, systemImage: MenuIcons.switchBranch)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(focusedProject?.workspace.gitProvider.isGitRepository != true)
        }

        // MARK: - Terminal menu
        // New Tab (Cmd+T), Find in Terminal (Cmd+F when terminal focused),
        // Quick Terminal (global drop-down, shows current shortcut).
        CommandMenu(Strings.menuTerminal) {
            // Quick Terminal — global drop-down panel toggled by the
            // system-wide hotkey. The menu item mirrors the hotkey so the
            // shortcut is discoverable; the actual key event is handled by
            // the Carbon hotkey, not this menu item. Shows the current
            // shortcut as a trailing hint.
            Button {
                appDelegate.quickTerminalCoordinator.toggle()
            } label: {
                Label {
                    if QuickTerminalSettings.shared.enabled {
                        // Append the live shortcut so users can see/learn it,
                        // e.g. "Quick Terminal    ⌃⌥Space".
                        HStack(spacing: 4) {
                            Text(Strings.menuQuickTerminal)
                            Text(QuickTerminalSettings.shared.hotkeyLabel)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(Strings.menuQuickTerminal)
                    }
                } icon: {
                    Image(systemName: MenuIcons.toggleTerminal)
                }
            }
            .disabled(QuickTerminalSettings.shared.enabled == false)

            Divider()

            Button {
                guard let pm = focusedProject else { return }
                pm.terminal.createTerminalTab(
                    relativeTo: pm.paneManager.activePaneID,
                    workingDirectory: pm.workspace.rootURL
                )
            } label: {
                Label(Strings.menuNewTerminalTab, systemImage: MenuIcons.newTerminalTab)
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            Button {
                NotificationCenter.default.post(name: .findInTerminal, object: nil)
            } label: {
                Label(Strings.menuFindInTerminal, systemImage: MenuIcons.find)
            }
            .disabled(focusedProject?.hasTerminalPanes != true)

            Divider()

            Button {
                NotificationCenter.default.post(name: .sendToTerminal, object: nil)
            } label: {
                Label(Strings.menuSendToTerminal, systemImage: MenuIcons.sendToTerminal)
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Divider()

            // Zoom the focused terminal pane to fill the detail area
            // (tmux-style). Cmd+Shift+Return is taken by Send to Terminal,
            // so zoom uses Cmd+Option+Return (#1115). Auto-collapsing the
            // sidebar from this shortcut is tracked as a follow-up — v1 ships
            // the pane-level zoom + shortcut, matching the existing tab-bar
            // maximize button (#1048).
            Button {
                guard let pm = focusedProject else { return }
                pm.paneManager.toggleMaximizeOnActiveTerminalPane()
            } label: {
                Label(Strings.menuToggleTerminalZoom, systemImage: MenuIcons.maximizeTerminal)
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(focusedProject?.hasTerminalPanes != true)
        }

        // MARK: - Tasks menu (issue #1009)
        // User-defined external commands loaded from tasks.json. Dynamically
        // populated from ExtensibilityManager; each item runs its task via
        // the shared safety-preserving invocation controller.
        CommandMenu(Strings.menuTasks) {
            let taskList = ExtensibilityManager.shared.tasks.tasks
            if taskList.isEmpty {
                Text(Strings.menuTasksEmpty)
                    .foregroundStyle(.secondary)
            }
            ForEach(taskList) { task in
                Button {
                    guard let pm = focusedProject else { return }
                    UserTaskInvocationController.invoke(
                        task,
                        projectManager: pm
                    )
                } label: {
                    Label(task.label, systemImage: MenuIcons.tasks)
                }
                .disabled(
                    focusedProject == nil
                        || (
                            task.scope == .activeFile
                                && focusedProject?.activeTabManager.activeTab == nil
                        )
                )
            }

            Divider()

            // Issue #1117: edit and reload user configuration (keybindings.json
            // and tasks.json) without restarting Pine. Starter files are
            // created on first open; reload surfaces validation errors.
            Button {
                let context = if let focusedProject {
                    DialogPresenter.forProject(focusedProject)
                } else {
                    DialogPresenter.forKeyWindow()
                }
                let presenter = AppKitUserConfigurationAlertPresenter(
                    context: context
                )
                Task { @MainActor in
                    await UserConfigurationEditor.openKeybindings(
                        alertPresenter: presenter
                    )
                }
            } label: {
                Label(Strings.menuEditKeybindings, systemImage: MenuIcons.editKeybindings)
            }
            Button {
                let context = if let focusedProject {
                    DialogPresenter.forProject(focusedProject)
                } else {
                    DialogPresenter.forKeyWindow()
                }
                let presenter = AppKitUserConfigurationAlertPresenter(
                    context: context
                )
                Task { @MainActor in
                    await UserConfigurationEditor.openTasks(
                        alertPresenter: presenter
                    )
                }
            } label: {
                Label(Strings.menuEditTasks, systemImage: MenuIcons.editTasks)
            }
            Button {
                let context = if let focusedProject {
                    DialogPresenter.forProject(focusedProject)
                } else {
                    DialogPresenter.forKeyWindow()
                }
                let presenter = AppKitUserConfigurationAlertPresenter(
                    context: context
                )
                Task { @MainActor in
                    await Self.reloadAndPresentConfigurationDiagnostics(
                        alertPresenter: presenter
                    )
                }
            } label: {
                Label(Strings.menuReloadUserConfiguration, systemImage: MenuIcons.reloadUserConfiguration)
            }
        }

        // AppDelegate's single key-down router handles physical shortcuts
        // after consulting user overrides.
    }

    // MARK: - Task outcome presentation

    /// Issue #1117: reloads user configuration (keybindings.json + tasks.json)
    /// and presents any validation diagnostics. A clean reload confirms
    /// success; a rejected file keeps the last valid registry (atomic) and
    /// lists every problem with file, entry, and localized reason so the
    /// user can fix the file and reload again — all without restarting Pine.
    @MainActor
    static func reloadAndPresentConfigurationDiagnostics(
        manager: ExtensibilityManager = .shared,
        alertPresenter: any UserConfigurationAlertPresenting =
            AppKitUserConfigurationAlertPresenter()
    ) async {
        let report = await manager.reload()
        guard let report else { return }
        await alertPresenter.present(reloadAlert(for: report))
    }

    static func reloadAlert(
        for report: ExtensibilityReloadReport
    ) -> UserConfigurationAlertDescriptor {
        let buttonTitle = NSLocalizedString(
            "userConfig.ok",
            value: "OK",
            comment: "Dismiss button"
        )
        guard !report.diagnostics.isEmpty else {
            return UserConfigurationAlertDescriptor(
                style: .informational,
                messageText: String(
                    localized: "userConfig.reloadSuccess.title",
                    defaultValue: "Configuration reloaded"
                ),
                informativeText: String(
                    localized: "userConfig.reloadSuccess.message",
                    defaultValue: "\(report.tasks.activeEntryCount) tasks and \(report.keybindings.activeEntryCount) keybindings active."
                ),
                buttonTitle: buttonTitle
            )
        }

        // Atomic reload is per file: every rejected file keeps its previous
        // valid registry while valid sibling files may still be applied.
        let header = String(
            localized: "userConfig.reloadRejected.header",
            defaultValue: "Some entries were rejected. Each rejected file kept its previous valid configuration. Fix the file and reload again."
        )
        let details = report.diagnostics
            .map { "• \($0.fileURL.lastPathComponent): \($0.localizedMessage)" }
            .joined(separator: "\n")
        return UserConfigurationAlertDescriptor(
            style: .warning,
            messageText: String(
                localized: "userConfig.reloadRejected.title",
                defaultValue: "Configuration problems found"
            ),
            informativeText: header + "\n\n" + details,
            buttonTitle: buttonTitle
        )
    }

}
