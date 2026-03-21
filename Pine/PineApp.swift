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
    @AppStorage(TabManager.autoSaveKey) private var autoSaveEnabled = false

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
                Button {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                } label: {
                    Label(Strings.menuOpenFolder, systemImage: MenuIcons.openFolder)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
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
                    pm.terminal.isTerminalVisible.toggle()
                } label: {
                    Label(Strings.toggleTerminal, systemImage: MenuIcons.toggleTerminal)
                }
                .keyboardShortcut("`", modifiers: .command)

                Button {
                    guard let pm = focusedProject else { return }
                    pm.tabManager.togglePreviewMode()
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

                Divider()

                Button {
                    guard let pm = focusedProject,
                          let url = pm.tabManager.activeTab?.url else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(Strings.menuRevealFileInFinder, systemImage: MenuIcons.revealFileInFinder)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    guard let pm = focusedProject,
                          let rootURL = pm.workspace.rootURL else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([rootURL])
                } label: {
                    Label(Strings.menuRevealProjectInFinder, systemImage: MenuIcons.revealProjectInFinder)
                }
                .disabled(focusedProject?.workspace.rootURL == nil)
            }
            // Terminal menu: New Tab (Cmd+T)
            CommandMenu(Strings.menuTerminal) {
                Button {
                    guard let pm = focusedProject else { return }
                    if !pm.terminal.isTerminalVisible {
                        pm.terminal.isTerminalVisible = true
                    }
                    pm.addTerminalTab()
                } label: {
                    Label(Strings.menuNewTerminalTab, systemImage: MenuIcons.newTerminalTab)
                }
                .keyboardShortcut("t", modifiers: .command)
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
                    NotificationCenter.default.post(name: .selectNextOccurrence, object: nil)
                } label: {
                    Label(Strings.menuSelectNextOccurrence, systemImage: MenuIcons.selectNextOccurrence)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    NotificationCenter.default.post(name: .splitIntoLineCursors, object: nil)
                } label: {
                    Label(Strings.menuSplitIntoLineCursors, systemImage: MenuIcons.splitIntoLineCursors)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Divider()

                Button {
                    NotificationCenter.default.post(name: .findInFile, object: nil)
                } label: {
                    Label(Strings.menuFind, systemImage: MenuIcons.find)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    NotificationCenter.default.post(name: .findAndReplace, object: nil)
                } label: {
                    Label(Strings.menuFindAndReplace, systemImage: MenuIcons.findAndReplace)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    NotificationCenter.default.post(name: .findNext, object: nil)
                } label: {
                    Label(Strings.menuFindNext, systemImage: MenuIcons.nextChange)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    NotificationCenter.default.post(name: .findPrevious, object: nil)
                } label: {
                    Label(Strings.menuFindPrevious, systemImage: MenuIcons.previousChange)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    NotificationCenter.default.post(name: .useSelectionForFind, object: nil)
                } label: {
                    Label(Strings.menuUseSelectionForFind, systemImage: MenuIcons.find)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Divider()

                Button {
                    NotificationCenter.default.post(name: .showProjectSearch, object: nil)
                } label: {
                    Label(Strings.menuFindInProject, systemImage: MenuIcons.findInProject)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

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
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    NotificationCenter.default.post(
                        name: .navigateChange, object: nil,
                        userInfo: ["direction": "previous"]
                    )
                } label: {
                    Label(Strings.menuPreviousChange, systemImage: MenuIcons.previousChange)
                }
                .keyboardShortcut(.upArrow, modifiers: [.control, .option])
                .disabled(focusedProject?.tabManager.activeTab == nil)

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
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    NotificationCenter.default.post(
                        name: .foldCode, object: nil,
                        userInfo: ["action": "unfold"]
                    )
                } label: {
                    Label(Strings.menuUnfoldCode, systemImage: MenuIcons.unfoldCode)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    NotificationCenter.default.post(
                        name: .foldCode, object: nil,
                        userInfo: ["action": "foldAll"]
                    )
                } label: {
                    Label(Strings.menuFoldAll, systemImage: MenuIcons.foldAll)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
                .disabled(focusedProject?.tabManager.activeTab == nil)

                Button {
                    NotificationCenter.default.post(
                        name: .foldCode, object: nil,
                        userInfo: ["action": "unfoldAll"]
                    )
                } label: {
                    Label(Strings.menuUnfoldAll, systemImage: MenuIcons.unfoldAll)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
                .disabled(focusedProject?.tabManager.activeTab == nil)
            }
            // File menu: Save, Save All, Save As, Duplicate
            CommandGroup(replacing: .saveItem) {
                Button {
                    guard let pm = focusedProject else { return }
                    if pm.tabManager.saveActiveTab() {
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
                    if pm.tabManager.saveAllTabs() {
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
                    pm.tabManager.duplicateActiveTab(projectRoot: pm.workspace.rootURL)
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

    func makeNSView(context: Context) -> InterceptorView {
        let view = InterceptorView()
        let coordinator = context.coordinator
        view.onMovedToWindow = { [weak coordinator] window in
            coordinator?.installDelegate(
                on: window,
                projectManager: projectManager,
                registry: registry,
                projectURL: projectURL,
                appDelegate: appDelegate
            )
        }
        return view
    }

    func updateNSView(_ nsView: InterceptorView, context: Context) {
        // Install delegate if makeNSView's viewDidMoveToWindow fired before
        // the coordinator was fully wired (defensive — belt and suspenders).
        if context.coordinator.closeDelegate == nil, let window = nsView.window {
            context.coordinator.installDelegate(
                on: window,
                projectManager: projectManager,
                registry: registry,
                projectURL: projectURL,
                appDelegate: appDelegate
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Custom NSView that fires a callback synchronously when added to a window.
    /// Replaces the previous DispatchQueue.main.async approach that could race
    /// with fast window closes in XCUITest (#138).
    class InterceptorView: NSView {
        var onMovedToWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onMovedToWindow?(window)
            }
        }
    }

    class Coordinator {
        // Strong reference to keep our delegate alive (NSWindow.delegate is weak)
        var closeDelegate: CloseDelegate?
        // Strong reference to keep the original delegate alive
        var originalDelegate: (any NSWindowDelegate)?

        func installDelegate(
            on window: NSWindow,
            projectManager: ProjectManager,
            registry: ProjectRegistry,
            projectURL: URL,
            appDelegate: AppDelegate
        ) {
            // Guard against double installation
            guard closeDelegate == nil else { return }
            let original = window.delegate
            let delegate = CloseDelegate(
                projectManager: projectManager,
                registry: registry,
                projectURL: projectURL,
                appDelegate: appDelegate,
                original: original
            )
            closeDelegate = delegate
            originalDelegate = original
            window.delegate = delegate
            // Fallback: observe willCloseNotification in case SwiftUI
            // replaces the window delegate after our installation (#138).
            delegate.observeWindowClose(window)
        }
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

    /// Tracks whether windowWillClose has already been handled, to prevent
    /// the NotificationCenter fallback from double-firing.
    private var didHandleClose = false

    /// NotificationCenter observer token for the willClose fallback.
    private var closeObserver: Any?

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
        super.init()
    }

    /// Installs a NotificationCenter observer as a fallback for windowWillClose.
    /// If SwiftUI later replaces the window delegate, the notification still fires.
    func observeWindowClose(_ window: NSWindow) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            self?.handleClose(notification)
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
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
        handleClose(notification)
    }

    /// Shared close handler used by both the delegate method and the
    /// NotificationCenter fallback. Guarded by `didHandleClose` to run once.
    private func handleClose(_ notification: Notification) {
        guard !didHandleClose else { return }
        didHandleClose = true
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
        // Default blame to ON for first launch
        if UserDefaults.standard.object(forKey: BlameConstants.storageKey) == nil {
            UserDefaults.standard.set(true, forKey: BlameConstants.storageKey)
        }

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

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let projects = Array(registry.recentProjects.prefix(10))
        guard !projects.isEmpty else { return nil }
        for url in projects {
            let title = "\(url.lastPathComponent) — \(url.abbreviatedPath)"
            let item = NSMenuItem(title: title, action: #selector(dockMenuOpenProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        return menu
    }

    @objc func dockMenuOpenProject(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let canonical = url.resolvingSymlinksInPath()
        // If the project is already open with a visible window, just bring it front
        if registry.isWindowOpen(canonical),
           let window = NSApp.windows.first(where: {
               $0.isVisible && (($0.delegate as? CloseDelegate)?.projectURL.resolvingSymlinksInPath() == canonical)
           }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        // Close background project to recreate fresh
        if registry.isProjectOpen(canonical) {
            registry.openProjects[canonical]?.saveSession()
            registry.closeProject(canonical)
        }
        guard registry.projectManager(for: canonical) != nil else { return }
        openProjectWindow?(canonical)
        // Hide Welcome window if visible
        welcomeWindow?.orderOut(nil)
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
    static let showProjectSearch = Notification.Name("showProjectSearch")
    /// userInfo: ["direction": "next" | "previous"]
    static let navigateChange = Notification.Name("navigateChange")
    /// userInfo: ["action": "fold" | "unfold" | "foldAll" | "unfoldAll"]
    static let foldCode = Notification.Name("foldCode")
    // Find & Replace (issue #275)
    static let findInFile = Notification.Name("findInFile")
    static let findAndReplace = Notification.Name("findAndReplace")
    static let findNext = Notification.Name("findNext")
    static let findPrevious = Notification.Name("findPrevious")
    static let useSelectionForFind = Notification.Name("useSelectionForFind")
    // Multiple cursors (issue #333)
    static let selectNextOccurrence = Notification.Name("selectNextOccurrence")
    static let splitIntoLineCursors = Notification.Name("splitIntoLineCursors")
}
