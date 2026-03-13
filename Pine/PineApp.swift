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
        }
        .defaultSize(width: 600, height: 400)
        .windowResizability(.contentSize)
    }
}

// MARK: - Nil-project redirect

/// Closes the placeholder window and opens the Welcome window instead.
private struct NilProjectRedirect: View {
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Color.clear.onAppear {
            NSApp.windows
                .first { $0.contentView?.subviews.isEmpty == true || $0.title.isEmpty }?
                .close()
            openWindow(id: "welcome")
        }
    }
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

    var body: some View {
        let pm = registry.projectManager(for: projectURL)
        ContentView()
            .environment(pm)
            .environment(pm.workspace)
            .environment(pm.terminal)
            .environment(pm.tabManager)
            .environment(registry)
            .focusedSceneValue(\.projectManager, pm)
            .onAppear {
                registry.lastActiveProjectURL = projectURL
                // Ensure AppDelegate has registry even if Welcome was never shown
                appDelegate.registry = registry
            }
            .background { AppDelegateBridge(appDelegate: appDelegate) }
            .onDisappear {
                // Cleanup only — unsaved check already handled by WindowCloseInterceptor
                registry.closeProject(projectURL)
                let isTerminating = (NSApp.delegate as? AppDelegate)?.isTerminating == true
                if registry.openProjects.isEmpty && !isTerminating {
                    // User explicitly closed last project — clear session so next launch
                    // shows Welcome instead of reopening a stale project.
                    SessionState.clear()
                    openWindow(id: "welcome")
                }
            }
            .background {
                WindowCloseInterceptor(
                    projectManager: pm,
                    registry: registry,
                    projectURL: projectURL
                )
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
            let delegate = CloseDelegate(
                projectManager: projectManager,
                original: window.delegate
            )
            context.coordinator.closeDelegate = delegate
            window.delegate = delegate
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        // Strong reference to keep delegate alive
        var closeDelegate: CloseDelegate?
    }

    /// Proxy NSWindowDelegate that intercepts windowShouldClose.
    class CloseDelegate: NSObject, NSWindowDelegate {
        let projectManager: ProjectManager
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
            openNamedWindow?("welcome")
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let registry, !registry.openProjects.isEmpty else { return }
        // Save session for the last focused project so it auto-restores on next launch
        if let url = registry.lastActiveProjectURL,
           let pm = registry.openProjects[url] {
            pm.saveSession()
        } else if let (_, pm) = registry.openProjects.first {
            pm.saveSession()
        }
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
