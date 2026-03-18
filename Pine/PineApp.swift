//
//  PineApp.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import Sparkle
import SwiftUI

@main
struct PineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.projectManager) private var focusedProject: ProjectManager?

    private var registry: ProjectRegistry { appDelegate.registry }

    var body: some Scene {
        WindowGroup(for: URL.self) { $projectURL in
            if let projectURL {
                ProjectWindowView(projectURL: projectURL, registry: registry, appDelegate: appDelegate)
            }
        }
        .defaultSize(width: 1280, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(viewModel: appDelegate.checkForUpdatesViewModel)
            }
            // Убираем стандартный "New Window" (Cmd+N) — табы создаются кликом по файлу
            CommandGroup(replacing: .newItem) { }
            // Cmd+Shift+O — открыть папку
            CommandGroup(after: .newItem) {
                Button(Strings.menuOpenFolder) {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            // View menu — add items to the existing system View menu
            CommandGroup(after: .toolbar) {
                Divider()

                Button(Strings.menuIncreaseFontSize) {
                    FontSizeSettings.shared.increase()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button(Strings.menuDecreaseFontSize) {
                    FontSizeSettings.shared.decrease()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button(Strings.menuResetFontSize) {
                    FontSizeSettings.shared.reset()
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button(Strings.toggleTerminal) {
                    guard let pm = focusedProject else { return }
                    pm.terminal.isTerminalVisible.toggle()
                }
                .keyboardShortcut("`", modifiers: .command)

                Button(Strings.menuTogglePreview) {
                    guard let pm = focusedProject else { return }
                    pm.tabManager.togglePreviewMode()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button(Strings.menuToggleMinimap) {
                    MinimapSettings.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Button(Strings.menuRevealFileInFinder) {
                    guard let pm = focusedProject,
                          let url = pm.tabManager.activeTab?.url else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button(Strings.menuRevealProjectInFinder) {
                    guard let pm = focusedProject,
                          let rootURL = pm.workspace.rootURL else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([rootURL])
                }
                .disabled(focusedProject?.workspace.rootURL == nil)
            }
            // Terminal menu: New Tab (Cmd+T)
            CommandMenu(Strings.menuTerminal) {
                Button(Strings.menuNewTerminalTab) {
                    guard let pm = focusedProject else { return }
                    if !pm.terminal.isTerminalVisible {
                        pm.terminal.isTerminalVisible = true
                    }
                    pm.addTerminalTab()
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            // Edit menu: Toggle Comment
            CommandGroup(after: .pasteboard) {
                Button(Strings.menuToggleComment) {
                    NotificationCenter.default.post(name: .toggleComment, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
            // File menu: Save, Save All, Save As, Duplicate
            CommandGroup(replacing: .saveItem) {
                Button(Strings.menuSave) {
                    guard let pm = focusedProject else { return }
                    if pm.tabManager.saveActiveTab() {
                        pm.workspace.gitProvider.refresh()
                        NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
                    }
                }
                .keyboardShortcut("s", modifiers: .command)

                Button(Strings.menuSaveAll) {
                    guard let pm = focusedProject else { return }
                    if pm.tabManager.saveAllTabs() {
                        pm.workspace.gitProvider.refresh()
                        NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Divider()

                Button(Strings.menuSaveAs) {
                    guard let pm = focusedProject else { return }
                    guard pm.tabManager.activeTab != nil else { return }
                    let panel = NSSavePanel()
                    panel.title = Strings.saveAsPanelTitle
                    panel.nameFieldStringValue = pm.tabManager.activeTab?.fileName ?? ""
                    if let dir = pm.tabManager.activeTab?.url.deletingLastPathComponent() {
                        panel.directoryURL = dir
                    }
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do {
                        try pm.tabManager.saveActiveTabAs(to: url)
                        pm.workspace.gitProvider.refresh()
                        NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
                    } catch {
                        let alert = NSAlert()
                        alert.messageText = Strings.fileOperationErrorTitle
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .critical
                        alert.runModal()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button(Strings.menuDuplicate) {
                    guard let pm = focusedProject else { return }
                    pm.tabManager.duplicateActiveTab()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            // Cmd+W is intercepted by AppDelegate's local event monitor
            // to close the active tab. The close button goes through
            // windowShouldClose which closes the entire window.
        }

        Window(Strings.welcomeTitle, id: "welcome") {
            WelcomeView(registry: registry, appDelegate: appDelegate)
                .background { AppDelegateBridge(appDelegate: appDelegate, registry: registry) }
                .background { WelcomeWindowCapture(appDelegate: appDelegate) }
        }
        .defaultSize(width: 600, height: 400)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
    }
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

/// Invisible view that hands SwiftUI's openWindow/dismissWindow actions to AppDelegate
/// so it can open windows when no SwiftUI views are active.
/// Also opens a pending project (from `--open-project` launch argument)
/// once the closures are wired up — guaranteeing no race condition.
private struct AppDelegateBridge: View {
    let appDelegate: AppDelegate
    let registry: ProjectRegistry
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow

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
        Group {
            // Use direct dict lookup — NOT projectManager(for:) which auto-creates.
            // Hidden windows from closed projects still get re-rendered by SwiftUI;
            // calling projectManager(for:) would silently re-add the closed project
            // to openProjects, breaking the "show Welcome when last project closes" logic.
            if let pm = registry.openProjects[projectURL.resolvingSymlinksInPath()] {
                ContentView()
                    .id(ObjectIdentifier(pm))
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
                            projectURL: projectURL,
                            appDelegate: appDelegate
                        )
                    }
            }
        }
        .background { AppDelegateBridge(appDelegate: appDelegate, registry: registry) }
        // Note: project cleanup (session save, Welcome restore) is handled by
        // CloseDelegate.windowWillClose — not onDisappear, which doesn't fire
        // reliably when windows are closed via AppKit performClose:.
    }
}

// MARK: - NSWindowDelegate interceptor for unsaved-changes on close

/// Installs an NSWindowDelegate on the hosting window to intercept close
/// and prompt for unsaved changes before the window actually closes.
private struct WindowCloseInterceptor: NSViewRepresentable {
    let projectManager: ProjectManager
    let registry: ProjectRegistry
    let projectURL: URL
    let appDelegate: AppDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer to next run loop so the window is set
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let original = window.delegate
            let delegate = CloseDelegate(
                projectManager: projectManager,
                registry: registry,
                projectURL: projectURL,
                appDelegate: appDelegate,
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

    /// Proxy NSWindowDelegate that intercepts windowShouldClose and windowWillClose.
    /// Uses the top-level CloseDelegate class (internal for testability).
}

/// NSWindowDelegate proxy that intercepts windowShouldClose and windowWillClose.
/// windowShouldClose always closes the entire window (red close button path).
/// Cmd+W is intercepted earlier by AppDelegate's local event monitor.
class CloseDelegate: NSObject, NSWindowDelegate {
    let projectManager: ProjectManager
    let registry: ProjectRegistry
    let projectURL: URL
    weak var appDelegate: AppDelegate?
    /// Weak ref to original — Coordinator holds the strong ref separately
    /// to avoid a potential retain cycle through the delegate chain.
    weak var original: (any NSWindowDelegate)?

    init(
        projectManager: ProjectManager,
        registry: ProjectRegistry,
        projectURL: URL,
        appDelegate: AppDelegate,
        original: (any NSWindowDelegate)?
    ) {
        self.projectManager = projectManager
        self.registry = registry
        self.projectURL = projectURL
        self.appDelegate = appDelegate
        self.original = original
    }

    /// Closes the active tab with unsaved-changes dialog. Called by the Cmd+W event monitor.
    func closeActiveTab() {
        guard let tab = projectManager.tabManager.activeTab else { return }
        if tab.isDirty {
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
                if let idx = projectManager.tabManager.tabs.firstIndex(where: { $0.id == tab.id }) {
                    guard projectManager.tabManager.saveTab(at: idx) else { return }
                }
                projectManager.tabManager.closeTab(id: tab.id)
            case .alertSecondButtonReturn:
                projectManager.tabManager.closeTab(id: tab.id)
            default:
                break
            }
        } else {
            projectManager.tabManager.closeTab(id: tab.id)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Forward to original delegate first — respect its veto if any
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            guard original.windowShouldClose?(sender) != false else { return false }
        }

        // Close button → close the entire window.
        let dirty = projectManager.tabManager.dirtyTabs
        guard !dirty.isEmpty else { return true }

        let fileList = dirty.map { "  • \($0.fileName)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = Strings.unsavedChangesTitle
        alert.informativeText = Strings.unsavedChangesListMessage(fileList)
        alert.addButton(withTitle: Strings.dialogSaveAll)
        alert.addButton(withTitle: Strings.dialogDontSave)
        alert.addButton(withTitle: Strings.dialogCancel)
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            guard projectManager.tabManager.saveAllTabs() else {
                return false // Save failed — abort close
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
        // Trigger Welcome window when last project closes.
        // Using windowWillClose instead of SwiftUI onDisappear
        // because onDisappear may not fire reliably for AppKit-closed windows.
        appDelegate?.handleProjectWindowDisappear(
            projectURL: projectURL, registry: registry
        )
    }

    func windowDidBecomeKey(_ notification: Notification) {
        original?.windowDidBecomeKey?(notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        original?.windowDidResignKey?(notification)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    /// Sparkle updater controller — `startingUpdater: true` enables automatic
    /// background checks respecting `SUScheduledCheckInterval`.
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )

    /// ViewModel for CheckForUpdatesView — created once, shared across menu rebuilds.
    lazy var checkForUpdatesViewModel = CheckForUpdatesViewModel(
        updater: updaterController.updater
    )

    /// Central project registry — created early so it's available for AppKit fallback.
    var registry = ProjectRegistry()

    // MARK: - SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        SparkleConstants.appcastURLString
    }

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
    /// Consumed by AppDelegateBridge once SwiftUI closures are wired up.
    var pendingProjectURL: URL?

    /// Handles cleanup when a project window disappears: saves session,
    /// removes from registry, and shows Welcome if no projects remain.
    func handleProjectWindowDisappear(projectURL: URL, registry: ProjectRegistry) {
        guard !isTerminating else { return }
        // Save session before closing so it can be restored
        // when the user reopens this project from Welcome or Open Recent.
        let canonical = projectURL.resolvingSymlinksInPath()
        registry.openProjects[canonical]?.saveSession()
        registry.closeProjectWindow(projectURL)
        // Show Welcome if no windows are open (check non-background projects)
        let hasOpenWindows = registry.openProjects.keys.contains { url in
            !registry.backgroundProjects.contains(url)
        }
        if !hasOpenWindows {
            showWelcome()
        }
    }

    func showWelcome() {
        // Try SwiftUI first — may silently fail after repeated dismiss cycles
        // because the captured @Environment(\.openWindow) closure becomes stale.
        openNamedWindow?("welcome")

        // Give SwiftUI a moment to process, then verify and fallback via AppKit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.ensureWelcomeVisible()
        }
    }

    /// Guarantees the Welcome window is visible, creating it via AppKit if needed.
    private func ensureWelcomeVisible() {
        // Check if any welcome window is already on screen
        if let window = welcomeWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        // welcomeWindow ref may point to a closed/deallocated window — find a live one
        if let liveWindow = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "welcome" && $0.contentView != nil
        }) {
            welcomeWindow = liveWindow
            liveWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        // Nothing worked — create from scratch via AppKit
        createWelcomeWindowViaAppKit()
    }

    /// Creates the Welcome window via AppKit when SwiftUI's scene lifecycle
    /// fails to instantiate it (known issue on macOS 26 with launches that
    /// bypass LaunchServices, including XCUITest).
    private func createWelcomeWindowViaAppKit() {
        let welcomeView = WelcomeView(registry: registry, appDelegate: self)
        let hostingController = NSHostingController(rootView: welcomeView)
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("welcome")
        window.title = ""
        window.setContentSize(NSSize(width: 600, height: 400))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false
        welcomeWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before applicationDidFinishLaunching — the system runs
        // window restoration between willFinishLaunching and didFinishLaunching.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // UI testing support: clear persisted state for a clean launch
        if CommandLine.arguments.contains("--reset-state") {
            SessionState.removeAll()
            FontSizeSettings.shared.reset()
        }

        // UI testing support: read project path from environment variable.
        // Using env var instead of launch argument because macOS interprets
        // bare file paths in arguments as files to open, suppressing normal window behavior.
        if let path = ProcessInfo.processInfo.environment["PINE_OPEN_PROJECT"] {
            pendingProjectURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        // Intercept Cmd+W before the system "Close" menu item.
        // For project windows: close active tab (or close window if no tabs).
        // For other windows: pass through to default behavior.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "w",
                  let window = NSApp.keyWindow,
                  let closeDelegate = window.delegate as? CloseDelegate else {
                return event
            }
            if closeDelegate.projectManager.tabManager.activeTab != nil {
                closeDelegate.closeActiveTab()
            } else {
                window.performClose(nil)
            }
            return nil // consume event
        }

        // Ensure Welcome is visible if SwiftUI didn't present it automatically
        // (e.g. when window restoration state interferes with defaultLaunchBehavior)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && !$0.title.isEmpty }
            if !hasVisibleWindow {
                self?.showWelcome()
            }
        }

        // Fallback: when no visible windows exist, Cmd+Shift+O opens a folder picker
        NotificationCenter.default.addObserver(
            forName: .openFolder, object: nil, queue: .main
        ) { [weak self] _ in
            guard NSApp.windows.allSatisfy({ !$0.isVisible }) else { return }
            guard let self else { return }
            if let url = self.registry.openProjectViaPanel() {
                self.openProjectWindow?(url)
            }
        }
    }

    /// Called when the user clicks the dock icon with no visible windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let hasOpenWindows = registry.openProjects.keys.contains { url in
                !registry.backgroundProjects.contains(url)
            }
            if !hasOpenWindows {
                // No open project windows — show Welcome
                showWelcome()
            } else if let window = NSApp.windows.first(where: {
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
        // Save sessions before terminating processes.
        for (_, pm) in registry.openProjects {
            pm.saveSession()
        }
        registry.destroyAllProjects()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true

        // Check for unsaved files
        for (_, pm) in registry.openProjects {
            let dirty = pm.tabManager.dirtyTabs
            guard !dirty.isEmpty else { continue }

            let fileList = dirty.map { "  • \($0.fileName)" }.joined(separator: "\n")
            let alert = NSAlert()
            alert.messageText = Strings.unsavedChangesTitle
            alert.informativeText = Strings.unsavedChangesListMessage(fileList)
            alert.addButton(withTitle: Strings.dialogSaveAll)
            alert.addButton(withTitle: Strings.dialogDontSave)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                guard pm.tabManager.saveAllTabs() else {
                    isTerminating = false
                    return .terminateCancel
                }
            case .alertSecondButtonReturn:
                continue
            default:
                isTerminating = false
                return .terminateCancel
            }
        }

        // Check for active terminal processes
        let hasActiveProcesses = registry.openProjects.values.contains { $0.terminal.hasActiveProcesses }
        if hasActiveProcesses {
            let alert = NSAlert()
            alert.messageText = Strings.terminalActiveProcessWarningTitle
            alert.informativeText = Strings.terminalActiveProcessWarningMessage
            alert.addButton(withTitle: Strings.terminalActiveProcessWarningQuit)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            if alert.runModal() != .alertFirstButtonReturn {
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
    static let switchBranch = Notification.Name("switchBranch")
    /// userInfo: ["oldURL": URL, "newURL": URL]
    static let fileRenamed = Notification.Name("fileRenamed")
    /// userInfo: ["url": URL]
    static let fileDeleted = Notification.Name("fileDeleted")
    static let toggleComment = Notification.Name("toggleComment")
}
