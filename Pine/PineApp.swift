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
                Button("Open Folder...") {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            // Cmd+` — показать/скрыть терминал
            CommandMenu("View") {
                Button("Toggle Terminal") {
                    NotificationCenter.default.post(name: .toggleTerminal, object: nil)
                }
                .keyboardShortcut("`", modifiers: .command)
            }
            // Cmd+Shift+B — переключение веток
            CommandMenu("Git") {
                Button("Switch Branch...") {
                    NotificationCenter.default.post(name: .switchBranch, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            // Cmd+S — сохранить файл
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .saveFile, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            // Cmd+W — закрыть таб
            CommandGroup(after: .saveItem) {
                Button("Close Tab") {
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
}

// MARK: - Уведомления для команд меню

extension Notification.Name {
    static let saveFile = Notification.Name("saveFile")
    static let openFolder = Notification.Name("openFolder")
    static let toggleTerminal = Notification.Name("toggleTerminal")
    static let switchBranch = Notification.Name("switchBranch")
}
