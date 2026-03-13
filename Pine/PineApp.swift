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
                .background { WelcomeWindowCapture(appDelegate: appDelegate) }
                .background { PendingProjectOpener(appDelegate: appDelegate, registry: registry) }
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

// MARK: - Welcome window capture

/// Captures the Welcome window's NSWindow reference into AppDelegate
/// so it can be shown/hidden reliably via AppKit.
/// Uses viewDidMoveToWindow instead of DispatchQueue.main.async for
/// a guaranteed AppKit lifecycle callback.
private struct WelcomeWindowCapture: NSViewRepresentable {
    let appDelegate: AppDelegate

    func makeNSView(context: Context) -> NSView {
        let view = WindowCaptureSentinel { [weak appDelegate] window in
            appDelegate?.welcomeWindow = window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// NSView subclass that reports its host window via a callback
/// when inserted into the window hierarchy.
private final class WindowCaptureSentinel: NSView {
    var onWindow: ((NSWindow) -> Void)?

    convenience init(onWindow: @escaping (NSWindow) -> Void) {
        self.init(frame: .zero)
        self.onWindow = onWindow
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
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

// MARK: - Pending project opener (UI testing support)

/// Opens a project passed via `--open-project` launch argument once SwiftUI is ready.
private struct PendingProjectOpener: View {
    let appDelegate: AppDelegate
    let registry: ProjectRegistry
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow

    var body: some View {
        Color.clear.onAppear {
            guard let url = appDelegate.pendingProjectURL else { return }
            appDelegate.pendingProjectURL = nil
            _ = registry.projectManager(for: url)
            openWindow(value: url)
            // Defer dismiss so the project window has time to appear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                dismissWindow(id: "welcome")
            }
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
        Group {
            if let pm = registry.projectManager(for: projectURL) {
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
            } else {
                // Directory no longer exists — close this blank window and show Welcome
                NilProjectRedirect()
            }
        }
        .onAppear { appDelegate.registry = registry }
        .background { AppDelegateBridge(appDelegate: appDelegate) }
        .onDisappear {
            (NSApp.delegate as? AppDelegate)?
                .handleProjectWindowDisappear(projectURL: projectURL, registry: registry)
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

    /// Reference to the Welcome NSWindow, captured via WelcomeWindowCapture.
    /// Used for reliable show/hide — SwiftUI's dismissWindow/openWindow breaks
    /// after a few cycles on singleton Window scenes.
    weak var welcomeWindow: NSWindow?

    /// Project URL passed via `--open-project` launch argument (UI testing).
    /// Consumed by PineApp scene on first appearance.
    var pendingProjectURL: URL?

    /// Handles cleanup when a project window disappears: saves session,
    /// removes from registry, and shows Welcome if no projects remain.
    func handleProjectWindowDisappear(projectURL: URL, registry: ProjectRegistry) {
        guard !isTerminating else { return }
        // Save session before closing so it can be restored
        // when the user reopens this project from Welcome or Open Recent.
        let canonical = projectURL.resolvingSymlinksInPath()
        registry.openProjects[canonical]?.saveSession()
        registry.closeProject(projectURL)
        if registry.openProjects.isEmpty {
            showWelcome()
        }
    }

    func showWelcome() {
        // Try SwiftUI first, then force-show via AppKit as fallback —
        // openWindow stops working after a few dismissWindow cycles.
        openNamedWindow?("welcome")
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.welcomeWindow, !window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before applicationDidFinishLaunching — the system runs
        // window restoration between willFinishLaunching and didFinishLaunching.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // UI testing support: clear persisted state for a clean launch
        if CommandLine.arguments.contains("--reset-state") {
            SessionState.removeAll()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        // UI testing support: store project URL for PineApp to open via SwiftUI
        if let idx = CommandLine.arguments.firstIndex(of: "--open-project"),
           idx + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[idx + 1]
            pendingProjectURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }

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
                    && $0 != welcomeWindow
            }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                showWelcome()
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let registry else { return }
        // Save per-project tab state so sessions can be restored from Welcome.
        for (_, pm) in registry.openProjects {
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
