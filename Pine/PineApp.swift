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
                ProjectWindowView(projectURL: projectURL, registry: registry, appDelegate: appDelegate)
            } else {
                // SwiftUI may instantiate with nil URL — close placeholder and show Welcome
                NilProjectRedirect()
            }
        }
        .restorationBehavior(.disabled)
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
                        NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            // Cmd+W — закрыть таб или окно
            CommandGroup(after: .saveItem) {
                Button(Strings.menuCloseTab) {
                    if let project = focusedProject, project.tabManager.activeTab != nil {
                        NotificationCenter.default.post(name: .closeTab, object: nil)
                    } else {
                        // No active tab or no project (Welcome) — close the key window
                        NSApp.keyWindow?.close()
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }

        Window(Strings.welcomeTitle, id: "welcome") {
            WelcomeView(registry: registry)
                .onAppear { appDelegate.registry = registry }
                .background { AppDelegateBridge(appDelegate: appDelegate) }
        }
        .defaultSize(width: 600, height: 400)
        .windowResizability(.contentSize)
    }
}

// MARK: - Nil-project redirect

/// Closes the placeholder window and opens the Welcome window instead.
/// Uses an NSViewRepresentable to reliably find its own host window.
private struct NilProjectRedirect: NSViewRepresentable {
    @Environment(\.openWindow) var openWindow

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let open = openWindow // capture before async — @Environment may be invalid later
        DispatchQueue.main.async {
            view.window?.close()
            open(id: "welcome")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - AppDelegate bridge (passes SwiftUI openWindow closures to AppDelegate)

/// Invisible view that hands SwiftUI's openWindow actions to AppDelegate
/// so it can open windows when no SwiftUI views are active.
private struct AppDelegateBridge: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Color.clear.onAppear {
            appDelegate.openNamedWindow = { id in openWindow(id: id) }
            appDelegate.openProjectWindow = { url in openWindow(value: url) }
        }
    }
}

// MARK: - Project Window wrapper

/// Resolves a ProjectManager from the registry and injects it into ContentView.
/// Also ensures AppDelegate is wired up even when Welcome window is never shown.
private struct ProjectWindowView: View {
    let projectURL: URL
    let registry: ProjectRegistry
    let appDelegate: AppDelegate
    @Environment(\.openWindow) var openWindow
    @State private var pm: ProjectManager?
    @State private var didAttemptLoad = false

    var body: some View {
        Group {
            if let pm {
                ContentView()
                    .environment(pm)
                    .environment(pm.workspace)
                    .environment(pm.terminal)
                    .environment(pm.tabManager)
                    .environment(registry)
                    .focusedSceneValue(\.projectManager, pm)
                    .background {
                        WindowCloseInterceptor(
                            projectManager: pm,
                            registry: registry,
                            projectURL: projectURL
                        )
                    }
            } else if didAttemptLoad {
                // Directory no longer exists — close this blank window and show Welcome
                NilProjectRedirect()
            }
        }
        .onAppear {
            if pm == nil {
                pm = registry.projectManager(for: projectURL)
                didAttemptLoad = true
            }
            registry.lastActiveProjectURL = projectURL
            appDelegate.registry = registry
        }
        .background { AppDelegateBridge(appDelegate: appDelegate) }
        .onDisappear {
            let isTerminating = (NSApp.delegate as? AppDelegate)?.isTerminating == true
            // Don't remove from registry during quit — applicationWillTerminate needs it for session save
            if !isTerminating {
                // User deliberately closed this project — clear its session so it
                // won't auto-restore on next launch
                SessionState.clear(for: projectURL)
                registry.closeProject(projectURL)
                if registry.openProjects.isEmpty {
                    openWindow(id: "welcome")
                }
            }
        }
    }
}

// MARK: - NSWindowDelegate interceptor for unsaved-changes on close

/// Installs an NSWindowDelegate on the hosting window to intercept close
/// and prompt for unsaved changes before the window actually closes.
private struct WindowCloseInterceptor: NSViewRepresentable {
    let projectManager: ProjectManager
    let registry: ProjectRegistry
    let projectURL: URL

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer to next run loop so the window is set
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let original = window.delegate
            let delegate = CloseDelegate(
                projectManager: projectManager,
                original: original
            )
            context.coordinator.closeDelegate = delegate
            // Coordinator keeps the original alive (NSWindow.delegate is weak)
            context.coordinator.originalDelegate = original
            window.delegate = delegate
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        // Strong reference to keep our delegate alive (NSWindow.delegate is weak)
        var closeDelegate: CloseDelegate?
        // Strong reference to keep the original delegate alive
        var originalDelegate: (any NSWindowDelegate)?
    }

    /// Proxy NSWindowDelegate that intercepts windowShouldClose.
    class CloseDelegate: NSObject, NSWindowDelegate {
        let projectManager: ProjectManager
        /// Weak ref to original — Coordinator holds the strong ref separately
        /// to avoid a potential retain cycle through the delegate chain.
        weak var original: (any NSWindowDelegate)?

        init(projectManager: ProjectManager, original: (any NSWindowDelegate)?) {
            self.projectManager = projectManager
            self.original = original
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // Forward to original delegate first — respect its veto if any
            if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
                guard original.windowShouldClose?(sender) != false else { return false }
            }
            guard projectManager.tabManager.hasUnsavedChanges else { return true }

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
                for index in projectManager.tabManager.tabs.indices
                    where projectManager.tabManager.tabs[index].isDirty {
                    guard projectManager.tabManager.saveTab(at: index) else {
                        return false // Save failed — abort close
                    }
                }
                return true
            case .alertSecondButtonReturn:
                return true // Don't save — allow close
            default:
                return false // Cancel — abort close
            }
        }

        // Forward other delegate calls to the original
        func windowWillClose(_ notification: Notification) {
            original?.windowWillClose?(notification)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            original?.windowDidBecomeKey?(notification)
        }

        func windowDidResignKey(_ notification: Notification) {
            original?.windowDidResignKey?(notification)
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var registry: ProjectRegistry?
    /// Set to true once applicationShouldTerminate is called, so onDisappear
    /// handlers know not to clear the saved session during app quit.
    private(set) var isTerminating = false

    /// Closure to open a named SwiftUI window, set by PineApp on launch.
    var openNamedWindow: ((String) -> Void)?
    /// Closure to open a project SwiftUI window by URL, set by PineApp on launch.
    var openProjectWindow: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        // Fallback: when no visible windows exist, Cmd+Shift+O opens a folder picker
        NotificationCenter.default.addObserver(
            forName: .openFolder, object: nil, queue: .main
        ) { [weak self] _ in
            guard NSApp.windows.allSatisfy({ !$0.isVisible }) else { return }
            guard let self, let registry = self.registry else { return }
            if let url = registry.openProjectViaPanel() {
                self.openProjectWindow?(url)
            }
        }
    }

    /// Called when the user clicks the dock icon with no visible windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Prefer surfacing existing hidden/minimized project windows (filter out
            // internal SwiftUI hosting windows and panels by requiring a non-empty title)
            if let window = NSApp.windows.first(where: {
                !$0.isVisible && !$0.title.isEmpty && $0.contentView != nil
            }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openNamedWindow?("welcome")
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let registry else { return }
        // Save session for every open project and record the open project list
        for (_, pm) in registry.openProjects {
            pm.saveSession()
        }
        SessionState.saveOpenProjects(Array(registry.openProjects.keys))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
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
                        isTerminating = false
                        return .terminateCancel
                    }
                }
            case .alertSecondButtonReturn:
                continue
            default:
                isTerminating = false
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
    static let refreshLineDiffs = Notification.Name("refreshLineDiffs")
    /// userInfo: ["oldURL": URL, "newURL": URL]
    static let fileRenamed = Notification.Name("fileRenamed")
    /// userInfo: ["url": URL]
    static let fileDeleted = Notification.Name("fileDeleted")
}
