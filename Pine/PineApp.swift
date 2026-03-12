//
//  PineApp.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

@main
struct PineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var registry = ProjectRegistry()
    @FocusedValue(\.projectManager) private var focusedProject: ProjectManager?

    var body: some Scene {
        WindowGroup(for: URL.self) { $projectURL in
            if let projectURL {
                ProjectWindowView(projectURL: projectURL, registry: registry)
            }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            // Убираем стандартный "New Window" (Cmd+N) — табы создаются кликом по файлу
            CommandGroup(replacing: .newItem) { }
            // Cmd+Shift+O — открыть папку
            CommandGroup(after: .newItem) {
                Button(Strings.menuOpenFolder) {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            // Cmd+` — показать/скрыть терминал
            CommandMenu(Strings.menuView) {
                Button(Strings.toggleTerminal) {
                    guard let pm = focusedProject else { return }
                    pm.terminal.isTerminalVisible.toggle()
                }
                .keyboardShortcut("`", modifiers: .command)
            }
            // Cmd+Shift+B — переключение веток
            CommandMenu(Strings.menuGit) {
                Button(Strings.menuSwitchBranch) {
                    // Branch switching is handled via toolbarTitleMenu
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            // Cmd+S — сохранить файл
            CommandGroup(replacing: .saveItem) {
                Button(Strings.menuSave) {
                    guard let pm = focusedProject else { return }
                    if pm.tabManager.saveActiveTab() {
                        pm.workspace.gitProvider.refresh()
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            // Cmd+W — закрыть таб
            CommandGroup(after: .saveItem) {
                Button(Strings.menuCloseTab) {
                    NotificationCenter.default.post(name: .closeTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }

        Window(Strings.welcomeTitle, id: "welcome") {
            WelcomeView(registry: registry)
                .task { appDelegate.registry = registry }
        }
        .defaultSize(width: 600, height: 400)
        .windowResizability(.contentSize)
    }
}

// MARK: - Project Window wrapper

/// Resolves a ProjectManager from the registry and injects it into ContentView.
private struct ProjectWindowView: View {
    let projectURL: URL
    let registry: ProjectRegistry
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow

    var body: some View {
        let pm = registry.projectManager(for: projectURL)
        ContentView()
            .environment(pm)
            .environment(pm.workspace)
            .environment(pm.terminal)
            .environment(pm.tabManager)
            .environment(registry)
            .focusedSceneValue(\.projectManager, pm)
            .onDisappear {
                pm.saveSession()
                registry.closeProject(projectURL)
                // Show Welcome window when last project closes
                if registry.openProjects.isEmpty {
                    openWindow(id: "welcome")
                }
            }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var registry: ProjectRegistry?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let registry else { return }
        // Save session for the first open project (single-session model)
        if let (_, pm) = registry.openProjects.first {
            pm.saveSession()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let registry else { return .terminateNow }

        for (_, pm) in registry.openProjects {
            guard pm.tabManager.hasUnsavedChanges else { continue }

            let alert = NSAlert()
            alert.messageText = Strings.unsavedChangesTitle
            alert.informativeText = Strings.unsavedChangesMessage
            alert.addButton(withTitle: Strings.dialogSave)
            alert.addButton(withTitle: Strings.dialogDontSave)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                for index in pm.tabManager.tabs.indices where pm.tabManager.tabs[index].isDirty {
                    guard pm.tabManager.saveTab(at: index) else {
                        return .terminateCancel
                    }
                }
            case .alertSecondButtonReturn:
                continue
            default:
                return .terminateCancel
            }
        }
        return .terminateNow
    }
}

// MARK: - Уведомления для команд меню

extension Notification.Name {
    static let openFolder = Notification.Name("openFolder")
    static let closeTab = Notification.Name("closeTab")
    /// userInfo: ["oldURL": URL, "newURL": URL]
    static let fileRenamed = Notification.Name("fileRenamed")
    /// userInfo: ["url": URL]
    static let fileDeleted = Notification.Name("fileDeleted")
}
