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
                .task { appDelegate.projectManager = projectManager }
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
    var projectManager: ProjectManager?

    /// Session state cached at launch — immune to saveSession() overwrites during startup.
    /// Cleared after 3s (safety) or after first successful reorder (whichever comes first).
    private var cachedSession: SessionState?
    /// Debounced work item for the next merge attempt.
    private var mergeWorkItem: DispatchWorkItem?
    /// One-shot flag: active-tab restore runs only once,
    /// so subsequent merges don't steal focus from the user.
    private var didRestoreActiveTab = false

    static let editorTabbingID = "pine-editor"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true

        // Cache session BEFORE any saveSession() call can overwrite UserDefaults.
        cachedSession = SessionState.load()

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

        // Сохраняем сессию при закрытии вкладки/окна
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Defer so the closing window is already removed from NSApp.windows
            DispatchQueue.main.async {
                self?.projectManager?.saveSession()
            }
        }

        // Each .editorWindowReady triggers a debounced merge.
        // Merge is idempotent — always safe to call, no phase gate.
        // This handles both startup restoration and runtime tab creation.
        NotificationCenter.default.addObserver(
            forName: .editorWindowReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleMerge()
        }

        // Clear cachedSession after 3s — stops reordering/active-tab restore,
        // but merge itself keeps working for any future windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.cachedSession = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        projectManager?.saveSession()
    }

    // MARK: - Debounced idempotent tab merge

    /// Schedules a debounced merge. No phase gate — always responds.
    /// The 50ms debounce coalesces rapid window appearances.
    private func scheduleMerge() {
        mergeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.mergeEditorWindowsIntoTabs()
        }
        mergeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)

        // Safety fallback: if a window was hidden but merge didn't fire
        // (e.g., guard editorWindows.count > 1 returned early), restore visibility.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for window in NSApplication.shared.windows
            where window.tabbingIdentifier == Self.editorTabbingID && window.alphaValue == 0 {
                window.alphaValue = 1
            }
        }
    }

    /// Idempotent merge: finds editor windows not yet in a tab group
    /// and adds them to the primary window's tab group, then reorders
    /// all tabs to match the saved session order via NSWindowTabGroup.
    /// Safe to call multiple times — already-tabbed windows are skipped,
    /// reorder is skipped when tabs already match session order.
    private func mergeEditorWindowsIntoTabs() {
        let editorWindows = NSApplication.shared.windows.filter {
            $0.isVisible && $0.tabbingIdentifier == Self.editorTabbingID
        }
        guard editorWindows.count > 1 else { return }

        // Phase 1: Add ungrouped windows into a single tab group.
        // Pick primary: prefer a window that already has a tab group.
        // Use tabGroup.windows (not tabbedWindows) — tabbedWindows returns nil
        // when the tab bar is hidden, but tabGroup.windows is always authoritative.
        let primary = editorWindows.first { ($0.tabGroup?.windows.count ?? 0) > 1 }
            ?? editorWindows[0]

        let alreadyTabbed: Set<ObjectIdentifier>
        if let groupWindows = primary.tabGroup?.windows, !groupWindows.isEmpty {
            alreadyTabbed = Set(groupWindows.map { ObjectIdentifier($0) })
        } else {
            alreadyTabbed = [ObjectIdentifier(primary)]
        }

        let ungrouped = editorWindows.filter { !alreadyTabbed.contains(ObjectIdentifier($0)) }
        for window in ungrouped {
            primary.addTabbedWindow(window, ordered: .above)
        }

        // Restore visibility for windows that were hidden to prevent flash.
        for window in ungrouped where window.alphaValue == 0 {
            window.alphaValue = 1
        }

        // Phase 2: Reorder tabs to match saved session order via NSWindowTabGroup.
        // Runs on every merge while cachedSession exists — idempotent, so late
        // windows that arrive after the first merge are also placed correctly.
        if let session = cachedSession, let tabGroup = primary.tabGroup {
            let sessionPaths = session.openFilePaths
            let currentWindows = tabGroup.windows
            let desired = currentWindows.sorted { windowA, windowB in
                let indexA = sessionPaths.firstIndex(of: windowA.representedURL?.path ?? "") ?? Int.max
                let indexB = sessionPaths.firstIndex(of: windowB.representedURL?.path ?? "") ?? Int.max
                return indexA < indexB
            }

            if desired.map(ObjectIdentifier.init) != currentWindows.map(ObjectIdentifier.init) {
                for window in desired.dropFirst().reversed() {
                    tabGroup.removeWindow(window)
                }
                for (index, window) in desired.dropFirst().enumerated() {
                    tabGroup.insertWindow(window, at: index + 1)
                }
            }
        }

        // Phase 3: Restore active tab — one-shot, only when the target window exists.
        // Flag is set only on successful match, so if the active tab window hasn't
        // appeared yet, the next merge will retry.
        if !didRestoreActiveTab, let session = cachedSession,
           let activeURL = session.activeFileURL {
            if let activeWindow = editorWindows.first(where: { $0.representedURL == activeURL }) {
                didRestoreActiveTab = true
                activeWindow.makeKeyAndOrderFront(nil)
            }
            // else: active tab window not yet restored — retry on next merge
        }
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
    /// Posted by WindowBridgeView when an editor window is fully configured.
    static let editorWindowReady = Notification.Name("editorWindowReady")
}
