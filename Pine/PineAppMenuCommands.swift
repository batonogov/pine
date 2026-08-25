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
@MainActor
struct PineAppMenuCommands: Commands {
    /// Injecting the already-created app-scoped view model keeps menu
    /// construction from reaching through an arbitrary `AppDelegate` and
    /// accidentally starting another Sparkle runtime in hosted tests.
    let checkForUpdatesViewModel: CheckForUpdatesViewModel
    let toggleQuickTerminal: () -> Void
    /// Recovers the quick terminal alongside the focused project's panes: the
    /// panel is a separate window, so a stuck session there is unreachable
    /// through `focusedProject`. Inert when the panel is hidden.
    let recoverQuickTerminalDisplay: () -> Void
    /// Reads the app-scoped registry without coupling Commands back to the
    /// AppDelegate. The closure keeps hosted tests inert while preserving
    /// observation of `ProjectRegistry.recentProjects` in the menu body.
    let recentProjects: () -> [URL]
    let showAgentInbox: () -> Void
    /// The window session behind the focused project scene (#1525). Starting
    /// an agent in a worktree, and moving between the projects one window
    /// holds, are session-scoped commands that used to exist only inside the
    /// toolbar's switcher menu; the menu bar needs the same session to offer
    /// them. `nil` while no project window is key.
    let windowSession: () -> ProjectWindowSession?
    /// Reads the app-scoped registry for the switcher rows, which resolve each
    /// worktree's agent task to a status glyph. Same rationale as
    /// `recentProjects`: a closure keeps Commands off the AppDelegate.
    let projectRegistry: () -> ProjectRegistry?
    @FocusedValue(\.projectManager) private var focusedProject: ProjectManager?
    @AppStorage("minimapVisible") private var minimapVisible = true
    @AppStorage(BlameConstants.storageKey) private var blameVisible = true
    @AppStorage("wordWrapEnabled") private var wordWrapEnabled = true
    private var keybindings: UserKeybindingRegistry {
        ExtensibilityManager.shared.keybindings
    }
    private var nativeState: NativeMenuCommandState {
        NativeMenuCommandState(projectManager: focusedProject)
    }
    /// What the focused window can do with its projects and agents (#1525).
    private var windowAvailability: ProjectWindowCommandAvailability {
        ProjectWindowCommandAvailability(
            session: windowSession(),
            projectManager: focusedProject
        )
    }
    private var agentLaunchOptions: [ProjectAgentLaunchOption] {
        windowSession()?.availableAgentOptions ?? []
    }

    var body: some Commands {
        // MARK: - App menu (About / CLI install)
        CommandGroup(replacing: .appInfo) {
            Button("About Pine") {
                AboutInfo.showAboutPanel()
            }

            CheckForUpdatesView(viewModel: checkForUpdatesViewModel)

            Divider()

            Button {
                if CLIInstaller.isInstalled {
                    CLIInstaller.uninstall(projectManager: focusedProject)
                } else {
                    CLIInstaller.install(projectManager: focusedProject)
                }
            } label: {
                Text(CLIInstaller.isInstalled
                     ? "Uninstall Command Line Tool…"
                     : "Install Command Line Tool…")
            }
        }

        // MARK: - File menu
        CommandGroup(replacing: .newItem) {
            Button {
                UserCommandInvocationRouter.dispatch(
                    .newFile,
                    projectManager: focusedProject
                )
            } label: {
                Label(Strings.menuNewFile, systemImage: MenuIcons.newFile)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .newFile)
            )
            .disabled(focusedProject?.workspace.rootURL == nil)

            Button {
                UserCommandInvocationRouter.dispatch(
                    .openFile,
                    projectManager: focusedProject
                )
            } label: {
                Label(Strings.menuOpenFile, systemImage: MenuIcons.openFile)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .openFile)
            )
            .disabled(focusedProject?.workspace.rootURL == nil)

            Menu {
                ForEach(recentProjects(), id: \.self) { projectURL in
                    Button(
                        ProjectRegistry.recentProjectDisplayTitle(
                            for: projectURL
                        )
                    ) {
                        NotificationCenter.default.post(
                            name: .openRecentProject,
                            object: nil,
                            userInfo: ["url": projectURL]
                        )
                    }
                }

                Divider()

                Button {
                    UserCommandInvocationRouter.dispatch(
                        .clearRecentProjects,
                        projectManager: focusedProject
                    )
                } label: {
                    Label(
                        Strings.menuClearMenu,
                        systemImage: MenuIcons.clearMenu
                    )
                }
            } label: {
                Label(
                    Strings.menuOpenRecent,
                    systemImage: MenuIcons.openFile
                )
            }
            .disabled(recentProjects().isEmpty)

            Divider()

            Button {
                UserCommandInvocationRouter.dispatch(
                    .openFolder,
                    projectManager: focusedProject
                )
            } label: {
                Label(Strings.menuOpenFolder, systemImage: MenuIcons.openFolder)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .openFolder)
            )
        }

        // Quick Open and navigation remain project-specific additions after
        // the conventional native open group.
        CommandGroup(after: .newItem) {

            Button {
                NotificationCenter.default.post(
                    name: .showQuickOpen,
                    object: focusedProject
                )
            } label: {
                Label(Strings.menuQuickOpen, systemImage: MenuIcons.quickOpen)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .quickOpen)
            )
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .commandPalette)
            )
            .disabled(focusedProject?.workspace.rootURL == nil)

            Button {
                NotificationCenter.default.post(
                    name: .showSymbolNavigator,
                    object: focusedProject
                )
            } label: {
                Label(Strings.menuSymbolNavigator, systemImage: MenuIcons.symbolNavigator)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .symbolNavigator)
            )
            .disabled(nativeState.activeEditorTabID == nil)

            Divider()

            Button {
                UserCommandInvocationRouter.dispatch(
                    .closeTab,
                    projectManager: focusedProject
                )
            } label: {
                Label(Strings.menuCloseTab, systemImage: MenuIcons.closeTab)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .closeTab)
            )
            .disabled(!nativeState.canCloseTab)

            Button {
                UserCommandInvocationRouter.dispatch(
                    .closeProject,
                    projectManager: focusedProject
                )
            } label: {
                Label(
                    Strings.menuCloseProject,
                    systemImage: MenuIcons.closeProject
                )
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .closeProject)
            )
            .disabled(focusedProject?.workspace.rootURL == nil)
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .save)
            )
            .disabled(!nativeState.canSave)

            Button {
                guard let pm = focusedProject else { return }
                // Same reentrancy rationale as Save (#1058).
                pm.saveAllTabsFromMenu()
            } label: {
                Label(Strings.menuSaveAll, systemImage: MenuIcons.saveAll)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .saveAll)
            )
            .disabled(!nativeState.canSaveAll)

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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .saveAs)
            )
            .disabled(!nativeState.canSaveAs)

            Button {
                UserCommandInvocationRouter.dispatch(
                    .duplicate,
                    projectManager: focusedProject
                )
            } label: {
                Label(Strings.menuDuplicate, systemImage: MenuIcons.duplicate)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .duplicate)
            )
            .disabled(!nativeState.canDuplicate)

        }

        // MARK: - Window menu
        CommandGroup(before: .windowSize) {
            Button {
                UserCommandInvocationRouter.dispatch(
                    .closeWindow,
                    projectManager: focusedProject
                )
            } label: {
                Label(
                    Strings.menuCloseWindow,
                    systemImage: MenuIcons.closeWindow
                )
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .closeWindow)
            )
            .disabled(!nativeState.canCloseWindow)

            Divider()
        }

        // The local event monitor presents the visual MRU switcher for
        // physical Control-Tab gestures. Native menu equivalents preserve the
        // immediate-switch fallback for Accessibility/XCUITest events, which
        // bypass local NSEvent monitors on macOS 26.
        CommandGroup(after: .windowArrangement) {
            Button {
                focusedProject?.paneManager.switchToNextTabGlobally()
            } label: {
                Text(Strings.tabSwitchNext)
            }
            .keyboardShortcut("\t", modifiers: .control)
            .disabled(
                (focusedProject?.paneManager
                    .validGlobalTabSwitchOrder().count ?? 0) < 2
            )

            Button {
                focusedProject?.paneManager.switchToPreviousTabGlobally()
            } label: {
                Text(Strings.tabSwitchPrevious)
            }
            .keyboardShortcut("\t", modifiers: [.control, .shift])
            .disabled(
                (focusedProject?.paneManager
                    .validGlobalTabSwitchOrder().count ?? 0) < 2
            )

            Divider()

            // The window's projects and agent worktrees, listed where macOS
            // keeps "what this window is showing" (#1525).
            Menu {
                if let session = windowSession(),
                   let registry = projectRegistry() {
                    ProjectSwitcherRows(
                        session: session,
                        registry: registry,
                        carriesIdentifiers: false,
                        onSelect: { url in
                            NotificationCenter.default.post(
                                name: .switchProjectInWindow,
                                object: focusedProject,
                                userInfo: ["url": url]
                            )
                        }
                    )
                }
            } label: {
                Label(
                    Strings.menuSwitchProjectInWindow,
                    systemImage: MenuIcons.switchProjectInWindow
                )
            }
            .disabled(!windowAvailability.canSwitchProject)

            Button {
                UserCommandInvocationRouter.dispatch(
                    .nextProjectInWindow,
                    projectManager: focusedProject,
                    windowAvailability: windowAvailability
                )
            } label: {
                Label(
                    Strings.menuNextProjectInWindow,
                    systemImage: MenuIcons.nextProjectInWindow
                )
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .nextProjectInWindow)
            )
            .disabled(!windowAvailability.canSwitchProject)

            Button {
                UserCommandInvocationRouter.dispatch(
                    .previousProjectInWindow,
                    projectManager: focusedProject,
                    windowAvailability: windowAvailability
                )
            } label: {
                Label(
                    Strings.menuPreviousProjectInWindow,
                    systemImage: MenuIcons.previousProjectInWindow
                )
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .previousProjectInWindow)
            )
            .disabled(!windowAvailability.canSwitchProject)
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .toggleComment)
            )

            Divider()

            Button {
                NotificationCenter.default.post(name: .findInFile, object: nil)
            } label: {
                Label(Strings.menuFind, systemImage: MenuIcons.find)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .findInFile)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(name: .findAndReplace, object: nil)
            } label: {
                Label(Strings.menuFindAndReplace, systemImage: MenuIcons.findAndReplace)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .findAndReplace)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(name: .findNext, object: nil)
            } label: {
                Label(Strings.menuFindNext, systemImage: MenuIcons.nextChange)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .findNext)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(name: .findPrevious, object: nil)
            } label: {
                Label(Strings.menuFindPrevious, systemImage: MenuIcons.previousChange)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .findPrevious)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(name: .useSelectionForFind, object: nil)
            } label: {
                Label(Strings.menuUseSelectionForFind, systemImage: MenuIcons.find)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .useSelectionForFind)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Divider()

            Button {
                NotificationCenter.default.post(name: .showProjectSearch, object: nil)
            } label: {
                Label(Strings.menuFindInProject, systemImage: MenuIcons.findInProject)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .findInProject)
            )

            Divider()

            Button {
                NotificationCenter.default.post(
                    name: .goToLine,
                    object: focusedProject
                )
            } label: {
                Label(Strings.menuGoToLine, systemImage: MenuIcons.goToLine)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .goToLine)
            )
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .nextChange)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .navigateChange, object: nil,
                    userInfo: ["direction": "previous"]
                )
            } label: {
                Label(Strings.menuPreviousChange, systemImage: MenuIcons.previousChange)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .previousChange)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .inlineDiffAction, object: nil,
                    userInfo: ["action": InlineDiffAction.accept]
                )
            } label: {
                Label(Strings.menuAcceptChange, systemImage: MenuIcons.acceptChange)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .acceptChange)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .inlineDiffAction, object: nil,
                    userInfo: ["action": InlineDiffAction.revert]
                )
            } label: {
                Label(Strings.menuRevertChange, systemImage: MenuIcons.revertChange)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .revertChange)
            )
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .foldCode)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .foldCode, object: nil,
                    userInfo: ["action": "unfold"]
                )
            } label: {
                Label(Strings.menuUnfoldCode, systemImage: MenuIcons.unfoldCode)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .unfoldCode)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .foldCode, object: nil,
                    userInfo: ["action": "foldAll"]
                )
            } label: {
                Label(Strings.menuFoldAll, systemImage: MenuIcons.foldAll)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .foldAll)
            )
            .disabled(focusedProject?.activeTabManager.activeTab == nil)

            Button {
                NotificationCenter.default.post(
                    name: .foldCode, object: nil,
                    userInfo: ["action": "unfoldAll"]
                )
            } label: {
                Label(Strings.menuUnfoldAll, systemImage: MenuIcons.unfoldAll)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .unfoldAll)
            )
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .increaseFontSize)
            )

            Button {
                FontSizeSettings.shared.decrease()
            } label: {
                Label(Strings.menuDecreaseFontSize, systemImage: MenuIcons.decreaseFontSize)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .decreaseFontSize)
            )

            Button {
                FontSizeSettings.shared.reset()
            } label: {
                Label(Strings.menuResetFontSize, systemImage: MenuIcons.resetFontSize)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .resetFontSize)
            )

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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .toggleTerminal)
            )

            Button {
                guard let pm = focusedProject else { return }
                pm.activeTabManager.togglePreviewMode()
            } label: {
                Label(Strings.menuTogglePreview, systemImage: MenuIcons.togglePreview)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .togglePreview)
            )

            Divider()

            Toggle(isOn: $minimapVisible) {
                Label(Strings.menuToggleMinimap, systemImage: MenuIcons.toggleMinimap)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .toggleMinimap)
            )

            Toggle(isOn: $blameVisible) {
                Label(Strings.menuToggleBlame, systemImage: MenuIcons.toggleBlame)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .toggleBlame)
            )

            Toggle(isOn: $wordWrapEnabled) {
                Label(Strings.menuToggleWordWrap, systemImage: MenuIcons.toggleWordWrap)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .toggleWordWrap)
            )

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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .showProblems)
            )
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .nextDiagnostic)
            )
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .previousDiagnostic)
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
                      pm.paneManager.root.content(
                          for: pm.paneManager.activePaneID
                      ) == .editor,
                      let url = pm.paneManager.activeTabManager?
                          .activeTab?
                          .fileURL else {
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label(Strings.menuRevealFileInFinder, systemImage: MenuIcons.revealFileInFinder)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .revealFileInFinder)
            )
            .disabled(
                focusedProject?.paneManager.activeTabManager?
                    .activeTab?
                    .fileURL == nil
            )

            Button {
                guard let pm = focusedProject,
                      let rootURL = pm.workspace.rootURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([rootURL])
            } label: {
                Label(Strings.menuRevealProjectInFinder, systemImage: MenuIcons.revealProjectInFinder)
            }
            .disabled(focusedProject?.workspace.rootURL == nil)

            Divider()

            // The switcher's New Agent submenu, in the menu bar where it
            // belongs (#1525). Hiding the toolbar used to delete the feature
            // outright: a toolbar is a convenience layer over commands that
            // live in the menu bar, never their only route.
            Menu {
                let options = agentLaunchOptions
                if options.isEmpty {
                    Text(Strings.projectSwitcherNoAgents)
                } else {
                    ForEach(options) { option in
                        Button(option.displayName) {
                            ProjectAgentLaunchSelection.post(
                                identifier: option.id,
                                projectManager: focusedProject
                            )
                        }
                        // The preferred (last-used) agent carries the
                        // command's chord, because that is exactly what the
                        // palette and a user keybinding launch. Attaching it
                        // to the submenu's own item instead would give the
                        // chord nothing to fire.
                        .effectiveKeyboardShortcut(
                            option.id == options.first?.id
                                ? keybindings.effectiveChord(for: .newAgent)
                                : nil
                        )
                    }
                }
            } label: {
                Label(
                    Strings.projectSwitcherNewAgent,
                    systemImage: MenuIcons.projectSwitcherNewAgent
                )
            }
            .disabled(!windowAvailability.canLaunchAgent)

            Button {
                showAgentInbox()
            } label: {
                Label(Strings.menuAgentInbox, systemImage: MenuIcons.agentInbox)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .showAgentInbox)
            )

            Button {
                AgentActivityPresentationRouter.postRequest(
                    for: focusedProject
                )
            } label: {
                Label(Strings.menuAgentActivity, systemImage: MenuIcons.agentActivity)
            }
            .disabled(focusedProject == nil)

            Button {
                NotificationCenter.default.post(name: .showAgentHistory, object: nil)
            } label: {
                Label(Strings.menuAgentHistory, systemImage: MenuIcons.agentHistory)
            }
            .disabled(focusedProject?.workspace.rootURL == nil)
        }

        // Xcode 26's CommandsBuilder supports at most ten direct children.
        // Keep the custom menus composed as one child so adding a menu does
        // not make the whole app target fail to compile on macOS 26.
        PineCommandCollection {
            // MARK: - Git menu
            CommandMenu(Strings.menuGit) {
            Button {
                guard let focusedProject else { return }
                NotificationCenter.default.post(name: .showBranchSwitcher, object: focusedProject)
            } label: {
                Label(Strings.menuSwitchBranch, systemImage: MenuIcons.switchBranch)
            }
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .showBranchSwitcher)
            )
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
                toggleQuickTerminal()
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .newTerminalTab)
            )

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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .sendToTerminal)
            )
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
            .effectiveKeyboardShortcut(
                keybindings.effectiveChord(for: .toggleTerminalZoom)
            )
            .disabled(focusedProject?.hasTerminalPanes != true)

            Divider()

            // Escape hatch for a terminal that renders nothing while its shell
            // keeps running: SwiftTerm's Metal renderer can drop into a state
            // where every frame request is refused and no repaint recovers it,
            // so this rebuilds the renderer itself (issue #1472).
            //
            // Deliberately never disabled. The quick terminal lives in its own
            // window, where `focusedProject` is nil — gating on project panes
            // would leave exactly the surface a user is staring at unfixable.
            Button {
                focusedProject?.terminal.recoverVisibleTerminalDisplays()
                recoverQuickTerminalDisplay()
            } label: {
                Label(
                    Strings.menuRecoverTerminalDisplay,
                    systemImage: MenuIcons.recoverTerminalDisplay
                )
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
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

@MainActor
private struct PineCommandCollection<Content: Commands>: Commands {
    let content: Content

    init(@CommandsBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some Commands {
        content
    }
}
