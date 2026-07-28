//
//  PineApp.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//
//  Entry point for the Pine app. Only the @main struct, the main Scene
//  wiring, and the AppDelegate / window close glue live here. Menu command
//  definitions are in PineAppMenuCommands.swift, notification names are in
//  PineAppNotifications.swift.
//

import Sparkle
import SwiftUI

@main
struct PineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
            PineAppMenuCommands(appDelegate: appDelegate)
        }

        Window(Strings.welcomeTitle, id: "welcome") {
            WelcomeView(registry: registry, appDelegate: appDelegate)
                .background { AppDelegateBridge(appDelegate: appDelegate, registry: registry) }
                .background { WelcomeWindowCapture(appDelegate: appDelegate) }
        }
        .defaultSize(width: 600, height: 400)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        Settings {
            PineSettingsView(
                lspSettings: registry.lspSettings,
                handoffSettings: .shared,
                shellSettings: .shared,
                editorSettings: .shared
            )
        }
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
                    .environment(pm.primaryTabManager)
                    .environment(pm.paneManager)
                    .environment(pm.toastManager)
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
struct WindowCloseInterceptor: NSViewRepresentable {
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
        // SwiftUI may replace NSWindow.delegate while keeping the same
        // representable, or move this sentinel to a replacement NSWindow.
        // Reconcile identity on every update instead of treating the first
        // installation as permanent.
        if let window = nsView.window {
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
        weak var installedWindow: NSWindow?
        private var lifecycleObservers: [Any] = []

        func installDelegate(
            on window: NSWindow,
            projectManager: ProjectManager,
            registry: ProjectRegistry,
            projectURL: URL,
            appDelegate: AppDelegate,
            presentAlert: CloseDelegate.CloseAlertPresenter? = nil,
            saveAll: CloseDelegate.CloseSaveAll? = nil
        ) {
            if installedWindow !== window {
                retireCurrentInstallation(restoringOriginal: true)
                installedWindow = window
                observeDelegateLifecycle(
                    on: window,
                    projectManager: projectManager,
                    registry: registry,
                    projectURL: projectURL,
                    appDelegate: appDelegate
                )
            } else if let closeDelegate,
                      window.delegate === closeDelegate {
                return
            } else if closeDelegate != nil {
                // Same owner, new delegate generation. Do not restore the old
                // original over SwiftUI's replacement; retire only our stale
                // observer/dialog authority before wrapping the live delegate.
                retireCurrentInstallation(restoringOriginal: false)
                installedWindow = window
                observeDelegateLifecycle(
                    on: window,
                    projectManager: projectManager,
                    registry: registry,
                    projectURL: projectURL,
                    appDelegate: appDelegate
                )
            }

            var original = window.delegate
            if let existing = original as? CloseDelegate {
                if existing.projectManager === projectManager {
                    closeDelegate = existing
                    originalDelegate = existing.original
                    existing.observeWindowClose(window)
                    return
                }
                let existingOriginal = existing.original
                existing.detachFromWindow()
                original = existingOriginal
            }
            let delegate = CloseDelegate(
                projectManager: projectManager,
                registry: registry,
                projectURL: projectURL,
                appDelegate: appDelegate,
                original: original,
                presentAlert: presentAlert,
                saveAll: saveAll
            )
            closeDelegate = delegate
            originalDelegate = original
            window.delegate = delegate
            // Fallback: observe willCloseNotification in case SwiftUI
            // replaces the window delegate after our installation (#138).
            delegate.observeWindowClose(window)
        }

        private func observeDelegateLifecycle(
            on window: NSWindow,
            projectManager: ProjectManager,
            registry: ProjectRegistry,
            projectURL: URL,
            appDelegate: AppDelegate
        ) {
            removeLifecycleObservers()
            for name in [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didUpdateNotification,
            ] {
                lifecycleObservers.append(
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { [weak self, weak window, weak projectManager,
                         weak registry, weak appDelegate] _ in
                        MainActor.assumeIsolated {
                            guard let self,
                                  let window,
                                  let projectManager,
                                  let registry,
                                  let appDelegate else {
                                return
                            }
                            self.installDelegate(
                                on: window,
                                projectManager: projectManager,
                                registry: registry,
                                projectURL: projectURL,
                                appDelegate: appDelegate
                            )
                        }
                    }
                )
            }
        }

        private func retireCurrentInstallation(restoringOriginal: Bool) {
            removeLifecycleObservers()
            if restoringOriginal,
               let installedWindow,
               let closeDelegate,
               installedWindow.delegate === closeDelegate {
                installedWindow.delegate = originalDelegate
            }
            closeDelegate?.detachFromWindow()
            closeDelegate = nil
            originalDelegate = nil
            installedWindow = nil
        }

        private func removeLifecycleObservers() {
            for observer in lifecycleObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            lifecycleObservers.removeAll()
        }

        deinit {
            for observer in lifecycleObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    /// Proxy NSWindowDelegate that intercepts windowShouldClose and windowWillClose.
    /// Uses the top-level CloseDelegate class (internal for testability).
}

/// NSWindowDelegate proxy that intercepts windowShouldClose and windowWillClose.
/// windowShouldClose always closes the entire window (red close button path).
/// Cmd+W is intercepted earlier by AppDelegate's local event monitor.
class CloseDelegate: NSObject, NSWindowDelegate {
    typealias CloseAlertPresenter = @MainActor (
        AlertTemplate,
        DialogPresentationContext,
        String,
        String
    ) async -> NSApplication.ModalResponse
    typealias CloseSaveAll = @MainActor (
        ProjectManager,
        DialogPresentationContext
    ) async -> Bool

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
    /// nonisolated(unsafe): accessed from deinit (nonisolated) to remove observer.
    /// CloseDelegate is always deallocated on the main thread.
    nonisolated(unsafe) private var closeObserver: Any?
    private weak var ownerWindow: NSWindow?
    private(set) var dialogContext = DialogPresentationContext.unscoped
    private var closeDecisionTask: Task<Void, Never>?
    private weak var approvedCloseWindow: NSWindow?
    private let closeAlertPresenter: CloseAlertPresenter?
    private let closeSaveAll: CloseSaveAll?

    private enum WindowCloseDecision {
        case cancel
        case approve(discard: DirtyEditorContentAuthorization?)
    }

    init(
        projectManager: ProjectManager,
        registry: ProjectRegistry,
        projectURL: URL,
        appDelegate: AppDelegate,
        original: (any NSWindowDelegate)?,
        presentAlert: CloseAlertPresenter? = nil,
        saveAll: CloseSaveAll? = nil
    ) {
        self.projectManager = projectManager
        self.registry = registry
        self.projectURL = projectURL
        self.appDelegate = appDelegate
        self.original = original
        self.closeAlertPresenter = presentAlert
        self.closeSaveAll = saveAll
        super.init()
    }

    /// Installs a NotificationCenter observer as a fallback for windowWillClose.
    /// If SwiftUI later replaces the window delegate, the notification still fires.
    func observeWindowClose(_ window: NSWindow) {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if let previousWindow = ownerWindow, previousWindow !== window {
            closeDecisionTask?.cancel()
            closeDecisionTask = nil
            approvedCloseWindow = nil
            DialogPresenter.ownerDidClose(previousWindow)
        }
        ownerWindow = window
        dialogContext = DialogPresenter.register(
            window: window,
            projectManager: projectManager
        )
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWindowClose()
            }
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// Closes the active tab with unsaved-changes dialog. Called by the Cmd+W event monitor.
    func closeActiveTab() {
        let pane = projectManager.paneManager
        let activePaneID = pane.activePaneID
        let content = pane.root.content(for: activePaneID)

        switch content {
        case .terminal:
            guard let state = pane.terminalState(for: activePaneID),
                  let tab = state.activeTab else { return }
            let context = dialogContext
            Task { @MainActor in
                guard await TabCloseHelper.confirmTerminalProcessStop(
                    tabs: [tab],
                    context: context
                ) else { return }
                guard state.terminalTabs.contains(where: { $0 === tab }) else {
                    return
                }
                state.removeTab(id: tab.id)
                if state.terminalTabs.isEmpty {
                    pane.removePane(activePaneID)
                }
            }

        case .editor, nil:
            let activeTM = projectManager.activeTabManager
            guard let tab = activeTM.activeTab else { return }
            let context = dialogContext
            Task { @MainActor in
                let closed = await TabCloseHelper.closeTab(
                    tab,
                    in: activeTM,
                    gitProvider: projectManager.workspace.gitProvider,
                    context: context
                )
                if closed && activeTM.tabs.isEmpty {
                    pane.removePane(activePaneID)
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Application-level termination already completed the same dirty-tab
        // and terminal decisions before setting `isTerminating`.
        if appDelegate?.isTerminating == true {
            return true
        }
        if approvedCloseWindow === sender {
            approvedCloseWindow = nil
            return true
        }

        guard closeDecisionTask == nil else { return false }

        // Forward to original delegate first — respect its veto if any
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            guard original.windowShouldClose?(sender) != false else { return false }
        }

        let context = DialogPresenter.context(for: sender)
        closeDecisionTask = Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let decision = await confirmWindowClose(context: context)
            closeDecisionTask = nil
            guard !Task.isCancelled,
                  let sender,
                  !didHandleClose else { return }
            let discardAuthorization: DirtyEditorContentAuthorization?
            switch decision {
            case .cancel:
                return
            case .approve(let discard):
                discardAuthorization = discard
            }
            // Commit destructive editor mutation only after every prompt and
            // terminal revalidation has succeeded.
            if let discardAuthorization,
               !projectManager.commitDiscard(
                   discardAuthorization,
                   postReloadNotifications: false
               ) {
                return
            }
            approvedCloseWindow = sender
            sender.performClose(nil)
            // `performClose` normally re-enters `windowShouldClose`
            // synchronously and consumes this approval. If the window became
            // non-closable while the decision was pending, do not leak an
            // approval into a later close attempt.
            if approvedCloseWindow === sender {
                approvedCloseWindow = nil
            }
        }
        return false
    }

    private func confirmWindowClose(
        context: DialogPresentationContext
    ) async -> WindowCloseDecision {
        var discardAuthorization: DirtyEditorContentAuthorization?
        let dirty = projectManager.allDirtyTabs
        if !dirty.isEmpty {
            let fileList = dirty.map { "  • \($0.fileName)" }.joined(separator: "\n")
            let message = Strings.unsavedChangesListMessage(fileList)
            let response = if let closeAlertPresenter {
                await closeAlertPresenter(
                    .unsavedChangesBulk,
                    context,
                    Strings.unsavedChangesTitle,
                    message
                )
            } else {
                await AlertTemplate.unsavedChangesBulk.runSheet(
                    on: context,
                    messageText: Strings.unsavedChangesTitle,
                    informativeText: message
                )
            }
            switch response {
            case .alertFirstButtonReturn:
                let didSave = if let closeSaveAll {
                    await closeSaveAll(projectManager, context)
                } else {
                    await projectManager.saveAllPaneTabs(context: context)
                }
                guard didSave else {
                    return .cancel
                }
            case .alertSecondButtonReturn:
                discardAuthorization = DirtyEditorContentAuthorization(
                    tabs: dirty
                )
            default:
                return .cancel
            }
        }

        let authorizedTerminalProcesses =
            TabCloseHelper.foregroundProcessSnapshot(
                for: projectManager.terminal.allTerminalTabs
            )
        if !authorizedTerminalProcesses.isEmpty {
            let terminalResponse = if let closeAlertPresenter {
                await closeAlertPresenter(
                    .terminalTabCloseWarning,
                    context,
                    Strings.terminalTabCloseWarningTitle,
                    Strings.terminalTabCloseWarningMessage
                )
            } else {
                await AlertTemplate.terminalTabCloseWarning.runSheet(
                    on: context,
                    messageText: Strings.terminalTabCloseWarningTitle,
                    informativeText: Strings.terminalTabCloseWarningMessage
                )
            }
            guard terminalResponse == .alertFirstButtonReturn else {
                return .cancel
            }
        }

        let currentDirtyTabs = projectManager.allDirtyTabs
        let currentTerminalProcesses =
            TabCloseHelper.foregroundProcessSnapshot(
                for: projectManager.terminal.allTerminalTabs
            )
        guard TabCloseHelper.foregroundProcessSnapshotIsAuthorized(
            currentTerminalProcesses,
            by: authorizedTerminalProcesses
        ) else {
            return .cancel
        }
        if let discardAuthorization {
            guard discardAuthorization.covers(currentDirtyTabs) else {
                return .cancel
            }
            return .approve(discard: discardAuthorization)
        }
        return currentDirtyTabs.isEmpty
            ? .approve(discard: nil)
            : .cancel
    }

    // Forward other delegate calls to the original
    func windowWillClose(_ notification: Notification) {
        original?.windowWillClose?(notification)
        handleWindowClose()
    }

    /// Shared close handler used by both the delegate method and the
    /// NotificationCenter fallback. Guarded by `didHandleClose` to run once.
    private func handleWindowClose() {
        guard !didHandleClose else { return }
        didHandleClose = true
        closeDecisionTask?.cancel()
        closeDecisionTask = nil
        approvedCloseWindow = nil
        if let ownerWindow {
            DialogPresenter.ownerDidClose(ownerWindow)
        }
        appDelegate?.handleProjectWindowDisappear(
            projectURL: projectURL, registry: registry
        )
    }

    /// Retires interception without treating the owner as user-closed. Used
    /// when SwiftUI replaces the delegate or moves the representable.
    func detachFromWindow() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        closeDecisionTask?.cancel()
        closeDecisionTask = nil
        approvedCloseWindow = nil
        if let ownerWindow {
            DialogPresenter.ownerDidClose(ownerWindow)
        }
        ownerWindow = nil
        dialogContext = .unscoped
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
    typealias TerminationAlertPresenter = @MainActor (
        AlertTemplate,
        DialogPresentationContext,
        String,
        String
    ) async -> NSApplication.ModalResponse
    typealias TerminationSaveAll = @MainActor (
        ProjectManager,
        DialogPresentationContext
    ) async -> Bool
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

    // MARK: - Quick terminal (#1113)

    /// Owner of the global drop-down terminal session + its system-wide hotkey.
    /// Created early so the hotkey is armed in `applicationDidFinishLaunching`
    /// before any window opens.
    let quickTerminalCoordinator = QuickTerminalController()
    private let hotkeyManager = GlobalHotkeyManager()
    private var hotkeySettingsBinding: QuickTerminalSettingsRuntimeBinding?

    /// `true` when the quick-terminal hotkey is explicitly disabled via the
    /// `--disable-quick-terminal` launch argument or `PINE_DISABLE_QUICK_TERMINAL`
    /// environment variable. Used by UI tests to avoid the global hotkey
    /// grabbing key events on CI, and as a production opt-out.
    private static var isQuickTerminalDisabled: Bool {
        CommandLine.arguments.contains("--disable-quick-terminal")
            || ProcessInfo.processInfo.environment["PINE_DISABLE_QUICK_TERMINAL"] != nil
    }

    // MARK: - Visual MRU tab switcher (#1239)

    /// Owns the Control-Tab / flags-changed monitors driving the visual MRU
    /// switcher overlay. Installed once in `applicationDidFinishLaunching`.
    private let tabSwitcherKeyController = GlobalTabSwitcherKeyController()

    // MARK: - SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        SparkleConstants.appcastURLString
    }

    /// Set to true once applicationShouldTerminate is called, so onDisappear
    /// handlers know not to clear the saved session during app quit.
    private(set) var isTerminating = false
    private var terminationDecisionTask: Task<Void, Never>?

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
        registry.openProjects[canonical]?.cleanupEditorContext()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + UITimings.Delay.short) { [weak self] in
            guard let self else { return }
            self.ensureWelcomeVisible()
        }
    }

    /// Waits for SwiftUI/AppKit to capture a real visible Welcome owner.
    /// This follows multiple lifecycle turns with a strict bound instead of
    /// assuming one fixed delay is sufficient on every macOS/CI machine.
    func awaitVisibleWelcomeWindow(
        maximumAttempts: Int = 40,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil
    ) async -> NSWindow? {
        let wait = waitForNextAttempt ?? {
            try? await Task.sleep(for: .milliseconds(25))
        }
        for _ in 0..<maximumAttempts {
            if let window = visibleWelcomeWindow() {
                return window
            }
            guard !Task.isCancelled else { return nil }
            await wait()
        }
        return visibleWelcomeWindow()
    }

    /// No-window Open Folder path. A missing Welcome owner fails closed and
    /// returns false; the panel is never promoted to an application-modal UI.
    @discardableResult
    func openFolderFromWelcomeOwner(
        maximumAttempts: Int = 40,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil,
        presentPanel: (@MainActor (DialogPresentationContext) async -> URL?)? = nil
    ) async -> Bool {
        showWelcome()
        guard let window = await awaitVisibleWelcomeWindow(
            maximumAttempts: maximumAttempts,
            waitForNextAttempt: waitForNextAttempt
        ) else {
            return false
        }
        let context = DialogPresenter.context(for: window)
        let selectedURL: URL?
        if let presentPanel {
            selectedURL = await presentPanel(context)
        } else {
            selectedURL = await registry.openProjectViaPanel(context: context)
        }
        guard let selectedURL else { return false }
        openProjectWindow?(selectedURL)
        return true
    }

    private func visibleWelcomeWindow() -> NSWindow? {
        if let welcomeWindow,
           welcomeWindow.isVisible,
           !welcomeWindow.isMiniaturized {
            return welcomeWindow
        }
        guard let liveWindow = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "welcome"
                && $0.contentView != nil
                && $0.isVisible
                && !$0.isMiniaturized
        }) else {
            return nil
        }
        welcomeWindow = liveWindow
        return liveWindow
    }

    /// Guarantees the Welcome window is visible, creating it via AppKit if needed.
    private func ensureWelcomeVisible() {
        // Check if any welcome window is already on screen
        if let window = welcomeWindow, window.isVisible {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        // welcomeWindow ref may point to a closed/deallocated window — find a live one
        if let liveWindow = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "welcome" && $0.contentView != nil
        }) {
            welcomeWindow = liveWindow
            if liveWindow.isMiniaturized {
                liveWindow.deminiaturize(nil)
            }
            liveWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        // Nothing worked — create from scratch via AppKit
        createWelcomeWindowViaAppKit()
    }

    /// Makes one app-owned window suitable for a native Quit sheet. A
    /// miniaturized window is visible according to AppKit but cannot provide
    /// discoverable sheet UI from the Dock, so restore it first.
    func prepareApplicationDialogOwner(
        windows suppliedWindows: [NSWindow]? = nil
    ) {
        let windows = suppliedWindows ?? NSApp.windows
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        if windows.contains(where: {
            DialogPresenter.isEligibleApplicationOwner($0)
        }) {
            return
        }
        if let miniaturized = windows.first(where: {
            $0.isVisible && $0.isMiniaturized
        }) {
            miniaturized.deminiaturize(nil)
            miniaturized.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        ensureWelcomeVisible()
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

        // Run data migrations before any other UserDefaults access
        MigrationManager.withDefaultMigrations().runMigrations()

        // Default blame to ON for first launch
        if UserDefaults.standard.object(forKey: BlameConstants.storageKey) == nil {
            UserDefaults.standard.set(true, forKey: BlameConstants.storageKey)
        }

        // Preload syntax grammars at startup instead of lazily on first tab open
        _ = SyntaxHighlighter.shared

        // Preload user-supplied tasks + keybindings (issue #1009). User
        // grammars are loaded by SyntaxHighlighter.shared above.
        let extensibilityManager = ExtensibilityManager.shared
        Task { @MainActor in
            await extensibilityManager.reload()
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

        // Clean up stale recovery files older than 7 days across all projects
        RecoveryManager.cleanupAllStaleEntries(olderThan: 7)

        // Arm the global quick-terminal hotkey (#1113). Carbon hotkeys work
        // in the App Sandbox without Accessibility permission; disabled by
        // launch flag for UI tests / opt-out.
        if !Self.isQuickTerminalDisabled {
            quickTerminalCoordinator.registry = registry
            hotkeyManager.onTrigger = { @Sendable [weak self] in
                // Hop to MainActor: toggle touches @MainActor coordinator state.
                Task { @MainActor in self?.quickTerminalCoordinator.toggle() }
            }
            // Apply the persisted shortcut immediately and retain the exact
            // production subscription that re-arms it after every atomic
            // settings change.
            hotkeySettingsBinding = QuickTerminalSettingsRuntimeBinding(
                settings: QuickTerminalSettings.shared
            ) { [weak self] settings in
                self?.hotkeyManager.applyQuickTerminalSettings(settings)
            }
        }

        // A single key-down monitor owns precedence. User overrides are routed
        // first, followed by Pine's physical-key handlers; NSMenu and the
        // responder chain see only events neither layer consumed. Keeping this
        // in one monitor avoids AppKit's unspecified ordering among monitors.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if QuickTerminalHotkeyCaptureRouter.shared.route(event) {
                return nil
            }
            let registry = ExtensibilityManager.shared.keybindings
            return UserKeybindingDispatcher.route(
                event,
                registry: registry,
                dispatchUserCommand: { command in
                    UserCommandInvocationRouter.dispatch(
                        command,
                        projectManager: self?.activeProjectManager()
                    )
                },
                dispatchBuiltIn: Self.handleBuiltInKeyDown
            )
        }

        // Ensure Welcome is visible if SwiftUI didn't present it automatically
        // (e.g. when window restoration state interferes with defaultLaunchBehavior)
        DispatchQueue.main.asyncAfter(deadline: .now() + UITimings.Delay.long) { [weak self] in
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && !$0.title.isEmpty }
            if !hasVisibleWindow {
                self?.showWelcome()
            }
        }

        // Fallback: when no visible windows exist, Cmd+Shift+O opens a folder picker
        NotificationCenter.default.addObserver(
            forName: .openFolder, object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees main-thread delivery; assert main
            // actor isolation to cross the @Sendable observer boundary.
            MainActor.assumeIsolated {
                guard NSApp.windows.allSatisfy({ !$0.isVisible }) else { return }
                guard let self else { return }
                Task { @MainActor [weak self] in
                    _ = await self?.openFolderFromWelcomeOwner()
                }
            }
        }
    }

    /// Handles Pine shortcuts that require physical key codes or focused
    /// AppKit state. Called only after user overrides decline the event.
    /// Returns `true` when the event was consumed.
    private static func handleBuiltInKeyDown(_ event: NSEvent) -> Bool {
        // Cmd+W closes the active editor tab (or the project window when no
        // editor tab remains). The physical key code is layout-independent.
        if KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.w,
            modifiers: .command,
            in: event
        ),
           let window = NSApp.keyWindow,
           let closeDelegate = window.delegate as? CloseDelegate {
            if closeDelegate.projectManager.activeTabManager.activeTab != nil {
                closeDelegate.closeActiveTab()
            } else {
                window.performClose(nil)
            }
            return true
        }

        // Cmd+F opens terminal search while a terminal owns first responder.
        if KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.f,
            modifiers: .command,
            in: event
        ),
           let responder = NSApp.keyWindow?.firstResponder as? NSView,
           responder.className.contains("TerminalView") {
            NotificationCenter.default.post(name: .findInTerminal, object: nil)
            return true
        }

        // Cmd+Shift+B opens branch switching only for Git projects.
        if KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.b,
            modifiers: [.command, .shift],
            in: event
        ),
           let window = NSApp.keyWindow,
           let closeDelegate = window.delegate as? CloseDelegate,
           closeDelegate.projectManager.workspace.gitProvider.isGitRepository {
            NotificationCenter.default.post(
                name: .showBranchSwitcher,
                object: closeDelegate.projectManager
            )
            return true
        }

        // Ctrl+Tab / Ctrl+Shift+Tab cycle editor tabs.
        if event.keyCode == 48,
           let window = NSApp.keyWindow,
           let closeDelegate = window.delegate as? CloseDelegate {
            let modifiers = event.modifierFlags.intersection(
                .deviceIndependentFlagsMask
            )
            if modifiers == .control {
                closeDelegate.projectManager.paneManager.switchToNextTabGlobally()
                return true
            }
            if modifiers == [.control, .shift] {
                closeDelegate.projectManager.paneManager.switchToPreviousTabGlobally()
                return true
            }
        }

        // Cmd+1...8 select a tab by index; Cmd+9 selects the last tab.
        if let digit = KeyboardShortcutMatcher.digit(
            from: event,
            modifiers: .command
        ),
           let window = NSApp.keyWindow,
           let closeDelegate = window.delegate as? CloseDelegate {
            let activeTabManager = closeDelegate.projectManager.activeTabManager
            guard !activeTabManager.tabs.isEmpty else { return false }
            if digit == 9 {
                activeTabManager.selectLastTab()
            } else {
                activeTabManager.selectTab(at: digit - 1)
            }
            return true
        }

        return false
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

    // MARK: - Open URLs (Dock icon drop, Finder "Open With")

    /// Called when files/folders are dropped onto the Dock icon or opened via Finder "Open With".
    ///
    /// Note: This method only receives file/folder URLs. CLI arguments like `--line`
    /// are not available here — Finder and LaunchServices pass only URLs to the app.
    /// Line number navigation works only when Pine is launched from the command line.
    func application(_ sender: NSApplication, open urls: [URL]) {
        let classified = DropHandler.classifyURLs(urls)

        // Open directories as projects
        for dir in classified.directories {
            let canonical = dir.resolvingSymlinksInPath()
            guard registry.projectManager(for: canonical) != nil else { continue }
            openProjectWindow?(canonical)
            welcomeWindow?.orderOut(nil)
        }

        // Open files: if a project window is active, add as tabs; otherwise open parent as project
        if !classified.files.isEmpty {
            if let activeProject = activeProjectManager() {
                DropHandler.openFilesAsTabs(classified.files, in: activeProject.activeTabManager)
            } else if let firstFile = classified.files.first {
                let projectDir = firstFile.deletingLastPathComponent().resolvingSymlinksInPath()
                guard registry.projectManager(for: projectDir) != nil else { return }
                openProjectWindow?(projectDir)
                welcomeWindow?.orderOut(nil)
                // Open files after project initializes
                DispatchQueue.main.asyncAfter(deadline: .now() + UITimings.Delay.standard) { [weak self] in
                    guard let pm = self?.registry.openProjects[projectDir] else { return }
                    DropHandler.openFilesAsTabs(classified.files, in: pm.activeTabManager)
                }
            }
        }
    }

    /// Returns the ProjectManager for the currently active project window, if any.
    private func activeProjectManager() -> ProjectManager? {
        guard let window = NSApp.keyWindow,
              let closeDelegate = window.delegate as? CloseDelegate else { return nil }
        let canonical = closeDelegate.projectURL.resolvingSymlinksInPath()
        return registry.openProjects[canonical]
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
            pm.finalizeAgentSessionsForHistory()
            // Flush the agent-history log synchronously so a session finalized
            // above is guaranteed to reach `.pine/agent-log.json` before the OS
            // reclaims the process — the feature's durability promise.
            pm.agentHistory.flush()
            pm.saveSession()
            pm.cleanupEditorContext()
            // Shut down language servers so no orphan process survives (#1010).
            pm.shutdownLanguageServers()
            // Clean up recovery files if all tabs are saved
            if !pm.hasUnsavedChanges {
                pm.recoveryManager?.deleteAllRecoveryFiles()
            }
            pm.recoveryManager?.stopPeriodicSnapshots()
        }
        registry.destroyAllProjects()

        // Stop the global quick-terminal session so its PTY does not outlive
        // Pine (#1113 review). The session is keep-alive across toggles but
        // not across app launches.
        quickTerminalCoordinator.shutdown()

        // Settings UI tests write only to their namespaced suite. Remove it
        // from inside the app sandbox after the test runner terminates Pine.
        PineSettingsDefaults.cleanUpUITestSuite()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginApplicationTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    /// Starts the asynchronous AppKit termination handshake. Kept as a
    /// separate, internal seam so the `.terminateLater`/single-reply contract
    /// can be tested without constructing a second `NSApplication` singleton.
    func beginApplicationTermination(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }
        guard terminationDecisionTask == nil else { return .terminateLater }
        terminationDecisionTask = Task { @MainActor [weak self] in
            guard let self else {
                reply(false)
                return
            }
            let shouldTerminate = await confirmApplicationTermination()
            terminationDecisionTask = nil
            isTerminating = shouldTerminate
            reply(shouldTerminate)
        }
        return .terminateLater
    }

    /// Runs all quit decisions asynchronously on their owning project
    /// windows. Background projects fall back to one captured visible
    /// application window (normally Welcome); with no live owner, native
    /// presentation returns `.abort` and cancels Quit. Save failures also
    /// cancel Quit.
    func confirmApplicationTermination(
        presentAlert: TerminationAlertPresenter? = nil,
        saveAll: TerminationSaveAll? = nil,
        applicationContext: DialogPresentationContext? = nil
    ) async -> Bool {
        let projects = registry.openProjects
            .sorted { $0.key.path.localizedStandardCompare($1.key.path) == .orderedAscending }
            .map(\.value)
        let needsNativeDecision = presentAlert == nil
            && projects.contains {
                !$0.allDirtyTabs.isEmpty || $0.terminal.hasActiveProcesses
            }
        if applicationContext == nil, needsNativeDecision {
            // Quit can arrive from the Dock while Pine is hidden or every
            // project is miniaturized. Restore/create a discoverable owner
            // before capturing the fallback context.
            prepareApplicationDialogOwner()
        }
        let fallbackContext = applicationContext
            ?? DialogPresenter.forApplicationWindow()
        var discardAuthorizations: [
            ObjectIdentifier: DirtyEditorContentAuthorization
        ] = [:]
        var authorizedTerminalProcesses: [
            ObjectIdentifier: Set<TerminalForegroundProcessIdentity>
        ] = [:]

        for projectManager in projects {
            guard registry.openProjects.values.contains(where: {
                $0 === projectManager
            }) else {
                continue
            }
            let projectContext = DialogPresenter.forProject(projectManager)
            let hasEligibleProjectOwner = projectContext.nsWindow.map {
                DialogPresenter.isEligibleApplicationOwner($0)
            } ?? false
            let context = hasEligibleProjectOwner
                ? projectContext
                : fallbackContext
            let dirty = projectManager.allDirtyTabs
            guard !dirty.isEmpty else { continue }

            let fileList = dirty.map { "  • \($0.fileName)" }.joined(separator: "\n")
            let message = Strings.unsavedChangesListMessage(fileList)
            let response = if let presentAlert {
                await presentAlert(
                    .unsavedChangesBulk,
                    context,
                    Strings.unsavedChangesTitle,
                    message
                )
            } else {
                await AlertTemplate.unsavedChangesBulk.runSheet(
                    on: context,
                    messageText: Strings.unsavedChangesTitle,
                    informativeText: message
                )
            }
            switch response {
            case .alertFirstButtonReturn:
                let didSave = if let saveAll {
                    await saveAll(projectManager, context)
                } else {
                    await projectManager.saveAllPaneTabs(context: context)
                }
                guard didSave else {
                    return false
                }
            case .alertSecondButtonReturn:
                discardAuthorizations[ObjectIdentifier(projectManager)] =
                    DirtyEditorContentAuthorization(tabs: dirty)
                continue
            default:
                return false
            }
        }

        for projectManager in projects where projectManager.terminal.hasActiveProcesses {
            guard registry.openProjects.values.contains(where: {
                $0 === projectManager
            }) else {
                continue
            }
            let activeTerminalProcesses =
                TabCloseHelper.foregroundProcessSnapshot(
                    for: projectManager.terminal.allTerminalTabs
            )
            let projectContext = DialogPresenter.forProject(projectManager)
            let hasEligibleProjectOwner = projectContext.nsWindow.map {
                DialogPresenter.isEligibleApplicationOwner($0)
            } ?? false
            let context = hasEligibleProjectOwner
                ? projectContext
                : fallbackContext
            let response = if let presentAlert {
                await presentAlert(
                    .terminalActiveProcessWarning,
                    context,
                    Strings.terminalActiveProcessWarningTitle,
                    Strings.terminalActiveProcessWarningMessage
                )
            } else {
                await AlertTemplate.terminalActiveProcessWarning.runSheet(
                    on: context,
                    messageText: Strings.terminalActiveProcessWarningTitle,
                    informativeText: Strings.terminalActiveProcessWarningMessage
                )
            }
            guard response == .alertFirstButtonReturn else {
                return false
            }
            authorizedTerminalProcesses[ObjectIdentifier(projectManager)] =
                activeTerminalProcesses
        }

        // Other project windows stay interactive while each sheet is open.
        // Revalidate every destructive authorization immediately before
        // committing Quit so no new buffer edit or foreground process is
        // silently covered by an earlier answer.
        for projectManager in registry.openProjects.values {
            let identifier = ObjectIdentifier(projectManager)
            let currentDirtyTabs = projectManager.allDirtyTabs
            if let authorization = discardAuthorizations[identifier] {
                guard authorization.covers(currentDirtyTabs) else {
                    return false
                }
            } else if !currentDirtyTabs.isEmpty {
                return false
            }

            let allowedTerminalProcesses =
                authorizedTerminalProcesses[identifier] ?? []
            let currentTerminalProcesses =
                TabCloseHelper.foregroundProcessSnapshot(
                    for: projectManager.terminal.allTerminalTabs
                )
            guard TabCloseHelper.foregroundProcessSnapshotIsAuthorized(
                currentTerminalProcesses,
                by: allowedTerminalProcesses
            ) else {
                return false
            }
        }

        // Two-phase destructive commit: no project is mutated until every
        // project and terminal authorization above has passed.
        for projectManager in registry.openProjects.values {
            let identifier = ObjectIdentifier(projectManager)
            if let authorization = discardAuthorizations[identifier],
               !projectManager.commitDiscard(
                   authorization,
                   postReloadNotifications: false
               ) {
                return false
            }
        }

        return true
    }
}
