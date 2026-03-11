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
    @State private var projectManager = ProjectManager()

    var body: some Scene {
        WindowGroup(for: URL.self) { $fileURL in
            ContentView(fileURL: $fileURL)
                .environment(projectManager)
                .environment(projectManager.workspace)
                .environment(projectManager.terminal)
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
                    NotificationCenter.default.post(name: .toggleTerminal, object: nil)
                }
                .keyboardShortcut("`", modifiers: .command)
            }
            // Cmd+Shift+B — переключение веток
            CommandMenu(Strings.menuGit) {
                Button(Strings.menuSwitchBranch) {
                    NotificationCenter.default.post(name: .switchBranch, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            // Cmd+S — сохранить файл
            CommandGroup(replacing: .saveItem) {
                Button(Strings.menuSave) {
                    NotificationCenter.default.post(name: .saveFile, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            // Cmd+W — закрыть таб
            CommandGroup(after: .saveItem) {
                Button(Strings.menuCloseTab) {
                    NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}

// MARK: - AppDelegate для настройки нативных табов

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true

        // Устанавливаем tabbingMode для каждого нового окна
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                window.tabbingMode = .preferred
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Собираем открытые файлы из всех окон
        let openFileURLs = NSApplication.shared.windows.compactMap(\.representedURL)
        // Ищем projectURL через WorkspaceManager
        // ProjectManager передаётся через environment, но AppDelegate не имеет к нему доступа —
        // берём rootURL из UserDefaults-сохранённого состояния или из окон.
        // Вместо этого используем уведомление, которое ProjectManager слушает.
        NotificationCenter.default.post(
            name: .saveSession,
            object: nil,
            userInfo: ["openFileURLs": openFileURLs]
        )
    }
}

// MARK: - Уведомления для команд меню

extension Notification.Name {
    static let saveFile = Notification.Name("saveFile")
    static let openFolder = Notification.Name("openFolder")
    static let toggleTerminal = Notification.Name("toggleTerminal")
    static let switchBranch = Notification.Name("switchBranch")
    /// userInfo: ["oldURL": URL, "newURL": URL]
    static let fileRenamed = Notification.Name("fileRenamed")
    /// userInfo: ["url": URL]
    static let fileDeleted = Notification.Name("fileDeleted")
    /// Sent on app termination; userInfo: ["openFileURLs": [URL]]
    static let saveSession = Notification.Name("saveSession")
}
