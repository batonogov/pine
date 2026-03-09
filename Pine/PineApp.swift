//
//  PineApp.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

@main
struct PineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 700)
        // .commands — добавляет/заменяет пункты главного меню macOS.
        // CommandGroup(replacing:) заменяет стандартный пункт "Save" (Cmd+S).
        .commands {
            // Cmd+O — открыть папку
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
            // Cmd+S — сохранить файл
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .saveFile, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}

// Кастомное имя уведомления для Cmd+S
extension Notification.Name {
    static let saveFile = Notification.Name("saveFile")
    static let openFolder = Notification.Name("openFolder")
    static let toggleTerminal = Notification.Name("toggleTerminal")
}
