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
        CommandGroup(replacing: .appInfo) {
            Button("About Pine") {
                AboutInfo.showAboutPanel()
            }

            CheckForUpdatesView(viewModel: appDelegate.checkForUpdatesViewModel)

            Divider()

            Button {
                if CLIInstaller.isInstalled {
                    CLIInstaller.uninstall()
                } else {
                    CLIInstaller.install()
                }
            } label: {
                Text(CLIInstaller.isInstalled
                     ? "Uninstall Command Line Tool..."
                     : "Install Command Line Tool...")
            }
        }
        // Убираем стандартный "New Window" (Cmd+N) — табы создаются кликом по файлу
        CommandGroup(replacing: .newItem) { }
        // Cmd+Shift+O — открыть папку
        CommandGroup(after: .newItem) {
            Button {
                NotificationCenter.default.post(name: .openFolder, object: nil)
            } label: {
                Label(Strings.menuOpenFolder, systemImage: MenuIcons.openFolder)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button {
                NotificationCenter.default.post(name: .showQuickOpen, object: nil)
            } label: {
                Label(Strings.menuQuickOpen, systemImage: MenuIcons.quickOpen)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(focusedProject?.workspace.rootURL == nil)

            Button {
                NotificationCenter.default.post(name: .showSymbolNavigator, object: nil)
            } label: {
                Label(Strings.menuSymbolNavigator, systemImage: MenuIcons.symbolNavigator)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(focusedProject?.activeTabManager.activeTab == nil)
        }
        // View menu — add items to the existing system View menu
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
        }
        // Terminal menu: New Tab (Cmd+T), Find in Terminal (Cmd+F when terminal focused)
        CommandMenu(Strings.menuTerminal) {
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
        }
        // Edit menu: Toggle Comment, Find & Replace, Find in Project
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
                NotificationCenter.default.post(name: .goToLine, object: nil)
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
        // File menu: Save, Save All, Save As, Duplicate
        CommandGroup(replacing: .saveItem) {
            Button {
                guard let pm = focusedProject else { return }
                if pm.activeTabManager.saveActiveTab() {
                    Task {
                        await pm.workspace.gitProvider.refreshAsync()
                        NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
                    }
                }
            } label: {
                Label(Strings.menuSave, systemImage: MenuIcons.save)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button {
                guard let pm = focusedProject else { return }
                if pm.saveAllPaneTabs() {
                    Task {
                        await pm.workspace.gitProvider.refreshAsync()
                        NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
                    }
                }
            } label: {
                Label(Strings.menuSaveAll, systemImage: MenuIcons.saveAll)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Divider()

            Button {
                guard let pm = focusedProject else { return }
                guard pm.activeTabManager.activeTab != nil else { return }
                let panel = NSSavePanel()
                panel.title = Strings.saveAsPanelTitle
                panel.nameFieldStringValue = pm.activeTabManager.activeTab?.fileName ?? ""
                if let dir = pm.activeTabManager.activeTab?.url.deletingLastPathComponent() {
                    panel.directoryURL = dir
                }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try pm.activeTabManager.saveActiveTabAs(to: url)
                    Task {
                        await pm.workspace.gitProvider.refreshAsync()
                        NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
                    }
                } catch {
                    let alert = NSAlert()
                    alert.messageText = Strings.fileOperationErrorTitle
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            } label: {
                Label(Strings.menuSaveAs, systemImage: MenuIcons.saveAs)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                guard let pm = focusedProject else { return }
                pm.activeTabManager.duplicateActiveTab(projectRoot: pm.workspace.rootURL)
            } label: {
                Label(Strings.menuDuplicate, systemImage: MenuIcons.duplicate)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Toggle(isOn: $autoSaveEnabled) {
                Label(Strings.menuAutoSave, systemImage: MenuIcons.autoSave)
            }
        }
        // Cmd+W is intercepted by AppDelegate's local event monitor
        // to close the active tab. The close button goes through
        // windowShouldClose which closes the entire window.
        // Cmd+1..9 and Ctrl+Tab/Ctrl+Shift+Tab are also intercepted
        // via local event monitors in applicationDidFinishLaunching.
    }
}
