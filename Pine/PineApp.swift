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
import os

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
            PineAppMenuCommands(
                checkForUpdatesViewModel:
                    appDelegate.checkForUpdatesViewModel,
                toggleQuickTerminal: { [weak appDelegate] in
                    appDelegate?.quickTerminalCoordinator.toggle()
                },
                recentProjects: { [weak appDelegate] in
                    appDelegate?.registry.recentProjects ?? []
                },
                showAgentInbox: { [weak appDelegate] in
                    appDelegate?.showAgentInbox()
                }
            )
        }

        Window(Strings.agentInboxTitle, id: "agent-inbox") {
            AgentInboxView(registry: registry)
                .environment(registry)
                .background {
                    AppDelegateBridge(
                        appDelegate: appDelegate,
                        registry: registry
                    )
                }
        }
        .defaultSize(width: 720, height: 560)
        .defaultLaunchBehavior(.suppressed)

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
                notificationController: appDelegate.agentNotifications,
                agentTasks: registry.agentTasks,
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
            if let pm = registry.openProjects[
                registry.canonicalProjectURL(projectURL)
            ] ?? {
                // Fallback: the project may have been opened through a path
                // that canonicalizes differently (e.g. before the AppDelegate
                // bridge wired openProjectWindow). Try a direct registry lookup
                // as a last resort so the window always shows content.
                registry.projectManager(
                    for: registry.canonicalProjectURL(projectURL)
                )
            }() {
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

    static func dismantleNSView(
        _ nsView: InterceptorView,
        coordinator: Coordinator
    ) {
        nsView.onMovedToWindow = nil
        coordinator.detach()
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
                if closeDelegate.didCompleteWindowLifecycle,
                   registry.isWindowOpen(projectURL),
                   registry.openProjects[
                       registry.canonicalProjectURL(projectURL)
                   ] === projectManager {
                    closeDelegate.beginNewWindowLifecycle(on: window)
                }
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
                    if existing.didCompleteWindowLifecycle,
                       registry.isWindowOpen(projectURL),
                       registry.openProjects[
                           registry.canonicalProjectURL(projectURL)
                       ] === projectManager {
                        existing.beginNewWindowLifecycle(on: window)
                    } else if !existing.didCompleteWindowLifecycle {
                        existing.observeWindowClose(window)
                    }
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
                    ) { [weak self, weak window, weak projectManager, weak registry, weak appDelegate] _ in
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

        /// Retires the live representable installation while its NSWindow may
        /// remain alive. This is intentionally idempotent because SwiftUI
        /// teardown and coordinator destruction can occur back-to-back.
        func detach() {
            retireCurrentInstallation(restoringOriginal: true)
        }

        isolated deinit {
            retireCurrentInstallation(restoringOriginal: true)
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
    var didCompleteWindowLifecycle: Bool { didHandleClose }

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

    /// Closes the exact focused tab with its native safeguards.
    ///
    /// - Returns: `true` when a close workflow was started. Pinned or missing
    ///   tabs return `false` and remain untouched.
    @discardableResult
    func closeActiveTab(
        expectedTarget: NativeTabCloseTarget? = nil
    ) -> Bool {
        let pane = projectManager.paneManager
        let state = NativeMenuCommandState(projectManager: projectManager)
        guard let target = state.closeTarget,
              expectedTarget == nil || expectedTarget == target else {
            return false
        }

        switch target {
        case .terminal(let paneID, let tabID):
            guard let terminalState = pane.terminalState(for: paneID),
                  let tab = terminalState.terminalTabs.first(where: {
                      $0.id == tabID
                  }) else {
                return false
            }
            let context = dialogContext
            Task { @MainActor in
                guard await TabCloseHelper.confirmTerminalProcessStop(
                    tabs: [tab],
                    context: context
                ) else { return }
                guard terminalState.terminalTabs.contains(where: {
                    $0 === tab
                }) else {
                    return
                }
                terminalState.removeTab(id: tab.id)
                if terminalState.terminalTabs.isEmpty {
                    pane.removePane(paneID)
                }
            }
            return true

        case .editor(let paneID, let tabID):
            guard let activeTM = pane.tabManager(for: paneID),
                  let tab = activeTM.tabs.first(where: {
                      $0.id == tabID && !$0.isPinned
                  }) else {
                return false
            }
            let context = dialogContext
            Task { @MainActor in
                let closed = await TabCloseHelper.closeTab(
                    tab,
                    in: activeTM,
                    gitProvider: projectManager.workspace.gitProvider,
                    context: context,
                    saveTab: { index in
                        guard activeTM.tabs.indices.contains(index) else {
                            return false
                        }
                        return await self.projectManager.saveTab(
                            tabID: activeTM.tabs[index].id,
                            in: activeTM,
                            forceSaveAs: false,
                            context: context
                        )
                    }
                )
                if closed && activeTM.tabs.isEmpty {
                    pane.removePane(paneID)
                }
            }
            return true
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

        // Authorize by stable identity, never by the volatile foreground pgid:
        // an agent tab churns process groups on nearly every poll, so a pgid
        // snapshot taken before the sheet is already stale when the user
        // answers it, and the close would silently abort (#1335, #1348).
        let terminalAuthorization = TerminalTabCloseAuthorization.authorizing(
            tabs: projectManager.terminal.allTerminalTabs
        )
        if terminalAuthorization.requiresConfirmation {
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
        guard terminalAuthorization.stillCovers(
            projectManager.terminal.allTerminalTabs
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

    /// Re-arms a retained delegate only after ProjectRegistry has explicitly
    /// moved the same project out of its background state. Repeated
    /// representable updates during one live window generation must never
    /// reset the once-only close guard.
    func beginNewWindowLifecycle(on window: NSWindow) {
        guard didHandleClose else { return }
        didHandleClose = false
        observeWindowClose(window)
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

nonisolated private final class TerminationDeadlineResolver<Value: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ value: Value?) -> Bool {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return false }
        continuation.resume(returning: value)
        return true
    }
}

nonisolated private enum TerminationDeadlineTimer {
    /// A Swift-executor sleep can be delayed badly when the app or test host
    /// is saturated. Quit's hard deadline is a wall-clock contract.
    static let queue = DispatchQueue(
        label: "com.pine.termination-deadline",
        qos: .userInteractive
    )
}

class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate,
                   GlobalTabSwitcherKeyControllerDelegate {
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

    /// Pure feed configuration shared by the Sparkle delegate callback and
    /// tests. Keeping this seam independent from `updaterController` prevents
    /// tests from starting a second Sparkle runtime inside the app host.
    nonisolated static let configuredFeedURLString =
        SparkleConstants.appcastURLString

    /// Pine's single app-scoped update runtime. The nil custom-user-driver
    /// delegate is intentional: Sparkle's standard driver owns permission,
    /// update, cancellation, and relaunch UI instead of silently accepting
    /// first-run update-check consent.
    ///
    /// `startingUpdater: true` enables background checks only according to
    /// the preference established through Sparkle's standard permission flow.
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )

    /// ViewModel for CheckForUpdatesView — created once, shared across menu rebuilds.
    lazy var checkForUpdatesViewModel = CheckForUpdatesViewModel(
        updater: updaterController.updater
    )

    /// Central project registry — created early so it's available for AppKit fallback.
    var registry = ProjectRegistry()

    /// Application-wide, permission-gated agent notification coordinator.
    lazy var agentNotifications = AgentNotificationController(
        registry: registry.agentTasks,
        settings: .shared,
        isPresented: { [weak self] taskID in
            self?.registry.isAgentTaskPresented(taskID) ?? false
        },
        openTask: { [weak self] identity in
            self?.openAgentTaskFromNotification(identity)
        }
    )

    /// Application-wide visibility for background agent work: the Dock badge
    /// and a balanced sudden-termination guard (#1355). Driven from the same
    /// `AgentTaskRegistry` stream as the per-window Inbox badge (#1337), so
    /// the count includes backgrounded projects whose windows have closed.
    lazy var agentPresence = AgentPresenceController(
        registry: registry.agentTasks
    )

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
        Self.configuredFeedURLString
    }

    /// Set to true once applicationShouldTerminate is called, so onDisappear
    /// handlers know not to clear the saved session during app quit.
    private(set) var isTerminating = false
    private var terminationDecisionTask: Task<Void, Never>?
    private var welcomeVisibilityGeneration = 0
    private var pendingWelcomeEnsureTask: Task<Void, Never>?

    /// Closure to open a named SwiftUI window, set by PineApp on launch.
    var openNamedWindow: ((String) -> Void)?
    /// Closure to open a project SwiftUI window by URL, set by PineApp on launch.
    var openProjectWindow: ((URL) -> Void)?

    func showAgentInbox() {
        openNamedWindow?("agent-inbox")
        NSApp.activate()
    }

    private func openAgentTaskFromNotification(
        _ identity: AgentNotificationRouteIdentity
    ) {
        guard registry.agentTasks.matchesNotificationRoute(identity) else {
            showAgentInbox()
            return
        }
        guard openProjectWindow != nil else {
            showAgentInbox()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await registry.navigateToAgentTaskFromInbox(
                identity.taskID,
                openProjectWindow: { [weak self] url in
                    self?.openProjectWindow?(url)
                },
                expectedNotificationRoute: identity
            )
            guard case .focused = result else {
                // The explicit user action still lands on truthful durable
                // history when the exact process generation is gone.
                showAgentInbox()
                return
            }
        }
    }

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
        let canonical = registry.canonicalProjectURL(projectURL)
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

    func showWelcome(
        waitBeforeEnsure: (@MainActor () async -> Void)? = nil,
        ensureVisible: (@MainActor () -> Void)? = nil
    ) {
        welcomeVisibilityGeneration &+= 1
        let generation = welcomeVisibilityGeneration
        pendingWelcomeEnsureTask?.cancel()

        // Try SwiftUI first — may silently fail after repeated dismiss cycles
        // because the captured @Environment(\.openWindow) closure becomes stale.
        openNamedWindow?("welcome")

        // Give SwiftUI a moment to process, then verify and fallback via AppKit.
        let wait = waitBeforeEnsure ?? {
            try? await Task.sleep(for: .seconds(UITimings.Delay.short))
        }
        pendingWelcomeEnsureTask = Task { @MainActor [weak self] in
            await wait()
            guard let self,
                  !Task.isCancelled,
                  self.welcomeVisibilityGeneration == generation else {
                return
            }
            if let ensureVisible {
                ensureVisible()
            } else {
                self.ensureWelcomeVisible()
            }
            if self.welcomeVisibilityGeneration == generation {
                self.pendingWelcomeEnsureTask = nil
            }
        }
    }

    /// Cancels every stale Welcome visibility request before hiding all live
    /// SwiftUI- and AppKit-owned Welcome windows. All successful project-open
    /// paths use this helper so a delayed `showWelcome()` fallback cannot
    /// resurrect the Welcome window over the new project.
    func hideWelcome() {
        welcomeVisibilityGeneration &+= 1
        pendingWelcomeEnsureTask?.cancel()
        pendingWelcomeEnsureTask = nil

        welcomeWindow?.orderOut(nil)
        for window in NSApp.windows
            where window.identifier?.rawValue == "welcome" && window.isVisible {
            window.orderOut(nil)
        }
    }

    /// Waits for SwiftUI/AppKit to capture a real visible Welcome owner.
    /// This follows multiple lifecycle turns with a strict bound instead of
    /// assuming one fixed delay is sufficient on every macOS/CI machine.
    func awaitVisibleWelcomeWindow(
        maximumAttempts: Int = 40,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil,
        resolveVisibleWindow: (@MainActor () -> NSWindow?)? = nil
    ) async -> NSWindow? {
        let wait = waitForNextAttempt ?? {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let resolve = resolveVisibleWindow ?? {
            self.visibleWelcomeWindow()
        }
        for _ in 0..<max(0, maximumAttempts) {
            guard !Task.isCancelled else { return nil }
            if let window = resolve() {
                return window
            }
            await wait()
        }
        guard !Task.isCancelled else { return nil }
        return resolve()
    }

    /// No-window Open Folder path. A missing Welcome owner fails closed and
    /// returns false; the panel is never promoted to an application-modal UI.
    @discardableResult
    func openFolderFromWelcomeOwner(
        maximumAttempts: Int = 40,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil,
        resolveVisibleWindow: (@MainActor () -> NSWindow?)? = nil,
        presentPanel: (@MainActor (DialogPresentationContext) async -> URL?)? = nil
    ) async -> Bool {
        showWelcome()
        guard let window = await awaitVisibleWelcomeWindow(
            maximumAttempts: maximumAttempts,
            waitForNextAttempt: waitForNextAttempt,
            resolveVisibleWindow: resolveVisibleWindow
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
        guard let openProjectWindow else { return false }
        openProjectWindow(selectedURL)
        hideWelcome()
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
        let ownerStates = windows.map {
            DialogPresenter.applicationOwnerState(
                isVisible: $0.isVisible,
                isMiniaturized: $0.isMiniaturized
            )
        }
        switch DialogPresenter.applicationOwnerPlan(for: ownerStates) {
        case .keepExisting:
            return
        case let .restore(index):
            guard windows.indices.contains(index) else {
                ensureWelcomeVisible()
                return
            }
            let miniaturized = windows[index]
            miniaturized.deminiaturize(nil)
            miniaturized.makeKeyAndOrderFront(nil)
            NSApp.activate()
        case .showWelcome:
            ensureWelcomeVisible()
        }
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
        agentNotifications.start()
        agentPresence.start()

        // The key-down half is routed through the single precedence monitor
        // below; this installs Control-release and owner-window cancellation.
        tabSwitcherKeyController.delegate = self
        tabSwitcherKeyController.install()

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
                dispatchBuiltIn: { [weak self] event in
                    self?.handleBuiltInKeyDown(event) ?? false
                }
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

        installNativeCommandObservers()
    }

    /// Handles Pine shortcuts that require physical key codes or focused
    /// AppKit state. Called only after user overrides decline the event.
    /// Returns `true` when the event was consumed.
    private func handleBuiltInKeyDown(_ event: NSEvent) -> Bool {
        if tabSwitcherKeyController.handleKeyDownEvent(event) {
            return true
        }
        let documentWindow = CommandOverlayOwnerResolver.documentWindow(
            for: NSApp.keyWindow
        )

        // Cmd+W always means Close Tab. A pinned or absent tab consumes the
        // chord without falling through to NSWindow's close responder.
        if KeyboardShortcutMatcher.matches(
            keyCode: KeyboardShortcutMatcher.PhysicalKey.w,
            modifiers: .command,
            in: event
        ),
           let window = documentWindow,
           let closeDelegate = window.delegate as? CloseDelegate {
            _ = closeDelegate.closeActiveTab()
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
           let window = documentWindow,
           let closeDelegate = window.delegate as? CloseDelegate,
           closeDelegate.projectManager.workspace.gitProvider.isGitRepository {
            NotificationCenter.default.post(
                name: .showBranchSwitcher,
                object: closeDelegate.projectManager
            )
            return true
        }

        // Immediate fallback retained for call paths where the visual
        // controller is not installed (notably synthetic test harnesses that
        // invoke the built-in dispatcher directly).
        if event.keyCode == 48,
           let window = documentWindow,
           let closeDelegate = window.delegate as? CloseDelegate {
            let modifiers = KeyboardShortcutMatcher.normalizedModifiers(
                event.modifierFlags
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
           let window = documentWindow,
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

    /// Atomically resolves the project that owns the current key window.
    var globalTabSwitcherTarget: GlobalTabSwitcherTarget? {
        guard let window = CommandOverlayOwnerResolver.documentWindow(
            for: NSApp.keyWindow
        ),
              let closeDelegate = window.delegate as? CloseDelegate else {
            return nil
        }
        return GlobalTabSwitcherTarget(
            window: window,
            paneManager: closeDelegate.projectManager.paneManager
        )
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
            hideWelcome()
        }

        // Open files: if a project window is active, add as tabs; otherwise open parent as project
        if !classified.files.isEmpty {
            if let activeProject = activeProjectManager() {
                for file in classified.files {
                    activeProject.paneManager.openFileInActiveEditor(url: file)
                }
            } else if let firstFile = classified.files.first {
                let projectDir = firstFile.deletingLastPathComponent().resolvingSymlinksInPath()
                guard let projectManager = registry.projectManager(for: projectDir) else { return }
                openProjectWindow?(projectDir)
                hideWelcome()
                Task { @MainActor [weak self, weak projectManager] in
                    guard let self, let projectManager else { return }
                    guard let owner = await projectManager.awaitDialogOwnerWindow(),
                          projectManager.dialogOwnerWindow === owner,
                          self.registry.openProjects[
                              self.registry.canonicalProjectURL(projectDir)
                          ] === projectManager else {
                        return
                    }
                    for file in classified.files {
                        projectManager.paneManager.openFileInActiveEditor(url: file)
                    }
                }
            }
        }
    }

    /// Returns the ProjectManager for the currently active project window, if any.
    private func activeProjectManager() -> ProjectManager? {
        guard let window = CommandOverlayOwnerResolver.documentWindow(
            for: NSApp.keyWindow
        ),
              let closeDelegate = window.delegate as? CloseDelegate else { return nil }
        let canonical = registry.canonicalProjectURL(
            closeDelegate.projectURL
        )
        return registry.openProjects[canonical]
    }

    // MARK: - Native File / Window command routing

    private func installNativeCommandObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleNativeMenuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        for name in [
            Notification.Name.newFile,
            .openFile,
            .closeTab,
            .closeWindow,
            .openRecentProject,
            .clearRecentProjects,
            .showAgentInbox,
        ] {
            center.addObserver(
                self,
                selector: #selector(handleNativeCommand(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc private func handleNativeMenuDidBeginTracking(
        _ notification: Notification
    ) {
        guard let menu = notification.object as? NSMenu else { return }
        NativeRecentProjectsMenu.synchronize(
            mainMenu: menu,
            projects: registry.recentProjects,
            target: self,
            openAction: #selector(openRecentProjectFromNativeMenu(_:)),
            clearAction: #selector(clearRecentProjectsFromNativeMenu(_:))
        )
    }

    @objc private func handleNativeCommand(_ notification: Notification) {
        precondition(Thread.isMainThread)
        switch notification.name {
        case .showAgentInbox:
            showAgentInbox()

        case .openRecentProject:
            guard let url = notification.userInfo?["url"] as? URL else {
                return
            }
            requestOpenRecentProject(url)

        case .clearRecentProjects:
            NativeCommandDelivery.deferToNextMainRunLoop { [weak self] in
                self?.registry.clearRecentProjects()
            }

        case .newFile, .openFile, .closeTab, .closeWindow:
            guard let initialRoute = nativeCommandDestination(
                requestedProject: notification.object as? ProjectManager
            ) else {
                return
            }

            let project = initialRoute.project
            let initiatingPaneID = project.nativeFileCommandPaneID()
            let expectedCloseTarget =
                NativeMenuCommandState(projectManager: project).closeTarget
            if notification.name == .closeTab,
               expectedCloseTarget == nil {
                return
            }
            let commandName = notification.name
            let originatingWindow = initialRoute.window
            NativeCommandDelivery.deferToNextMainRunLoop { [weak self, weak project, weak originatingWindow] in
                guard let self,
                      let project,
                      let routed = self.nativeCommandDestination(
                          requestedProject: project
                      ),
                      routed.project === project else {
                    return
                }

                switch commandName {
                case .newFile:
                    _ = project.createUntitledFile(
                        in: initiatingPaneID
                    )
                case .openFile:
                    project.openFileFromMenu(
                        initiatingPaneID: initiatingPaneID
                    )
                case .closeTab:
                    _ = routed.delegate.closeActiveTab(
                        expectedTarget: expectedCloseTarget
                    )
                case .closeWindow:
                    guard routed.window === originatingWindow else {
                        return
                    }
                    routed.window.performClose(nil)
                default:
                    break
                }
            }

        default:
            break
        }
    }

    @objc private func openRecentProjectFromNativeMenu(
        _ sender: NSMenuItem
    ) {
        guard let projectURL = sender.representedObject as? URL else {
            return
        }
        requestOpenRecentProject(projectURL)
    }

    @objc private func clearRecentProjectsFromNativeMenu(
        _: NSMenuItem
    ) {
        NativeCommandDelivery.deferToNextMainRunLoop { [weak self] in
            self?.registry.clearRecentProjects()
        }
    }

    private func nativeCommandDestination(
        requestedProject: ProjectManager?
    ) -> (
        project: ProjectManager,
        window: NSWindow,
        delegate: CloseDelegate
    )? {
        let candidates: [(ProjectManager, NSWindow, CloseDelegate)] =
            NSApp.windows.compactMap { window in
            guard let delegate = window.delegate as? CloseDelegate else {
                return nil
            }
            return (delegate.projectManager, window, delegate)
        }
        let routingCandidates = candidates.map { candidate in
            let (project, window, delegate) = candidate
            let isRegisteredProject =
                registry.openProjects.values.contains(where: {
                    $0 === project
                })
            return NativeCommandRoutingCandidate(
                projectManager: project,
                isKeyWindow: window === NSApp.keyWindow,
                isEligibleWindow:
                    !delegate.didCompleteWindowLifecycle
                    && window.isVisible
                    && registry.isWindowOpen(delegate.projectURL)
                    && isRegisteredProject
            )
        }
        guard let destinationIndex = NativeCommandRouting.destinationIndex(
            requestedProject: requestedProject,
            candidates: routingCandidates
        ),
        candidates.indices.contains(destinationIndex) else {
            return nil
        }
        let match = candidates[destinationIndex]
        guard
              registry.openProjects.values.contains(where: {
                  $0 === match.0
              }) else {
            return nil
        }
        return (
            project: match.0,
            window: match.1,
            delegate: match.2
        )
    }

    /// Opens a recent project from File, Welcome, or Dock through one path.
    func requestOpenRecentProject(
        _ url: URL,
        fallbackOpenProjectWindow: ((URL) -> Void)? = nil
    ) {
        NativeCommandDelivery.deferToNextMainRunLoop { [weak self] in
            _ = self?.openRecentProject(
                url,
                fallbackOpenProjectWindow: fallbackOpenProjectWindow
            )
        }
    }

    /// Executes the shared Open Recent transition after its initiating
    /// SwiftUI/AppKit action stack has unwound.
    @discardableResult
    func openRecentProject(
        _ url: URL,
        fallbackOpenProjectWindow: ((URL) -> Void)? = nil
    ) -> Bool {
        let canonical = registry.canonicalProjectURL(url)
        if registry.isWindowOpen(canonical),
           let project = registry.openProjects[canonical],
           let window = liveProjectWindow(
               for: project,
               canonicalURL: canonical
           ) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            // Touch the registered project manager (no-op side effect; result
            // intentionally unused) so the Open Recent path mirrors the normal
            // open path that resolves the manager for the canonical URL.
            _ = registry.projectManager(for: canonical)
            hideWelcome()
            return true
        }

        // A registry entry can briefly claim an open window after AppKit has
        // already hidden or retired its delegate. Move that model back to the
        // retained-background state before asking SwiftUI for a replacement.
        if registry.isWindowOpen(canonical) {
            registry.closeProjectWindow(canonical)
        }
        guard registry.projectManager(for: canonical) != nil else {
            return false
        }
        guard let openProjectWindow =
                self.openProjectWindow ?? fallbackOpenProjectWindow else {
            registry.closeProjectWindow(canonical)
            return false
        }
        openProjectWindow(canonical)
        hideWelcome()
        return true
    }

    private func liveProjectWindow(
        for project: ProjectManager,
        canonicalURL: URL
    ) -> NSWindow? {
        guard registry.isWindowOpen(canonicalURL),
              registry.openProjects[canonicalURL] === project else {
            return nil
        }
        return NSApp.windows.first(where: { window in
            guard window.isVisible,
                  let delegate = window.delegate as? CloseDelegate,
                  !delegate.didCompleteWindowLifecycle else {
                return false
            }
            return delegate.projectManager === project
                && registry.canonicalProjectURL(delegate.projectURL)
                    == canonicalURL
        })
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        // Live agent runs are reachable with no window open (#1355). Each
        // entry opens the Agent Inbox, the single surface that resumes,
        // navigates, and dismisses a backgrounded task. Per-task terminal
        // focus from the Dock is a follow-up.
        let liveTasks = AgentPresenceController.liveTasks(for: registry.agentTasks.tasks)
        for task in liveTasks {
            let item = NSMenuItem(
                title: AgentPresenceController.dockMenuAgentTitle(for: task),
                action: #selector(dockMenuOpenAgentTask(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = task.id
            menu.addItem(item)
        }
        if !liveTasks.isEmpty {
            menu.addItem(.separator())
        }

        let projects = Array(registry.recentProjects.prefix(10))
        for url in projects {
            let title = ProjectRegistry.recentProjectDisplayTitle(for: url)
            let item = NSMenuItem(title: title, action: #selector(dockMenuOpenProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc func dockMenuOpenProject(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        requestOpenRecentProject(url)
    }

    @objc func dockMenuOpenAgentTask(_ sender: NSMenuItem) {
        // The represented taskID is captured for a future per-task focus
        // path; today every entry routes to the Inbox so a background agent
        // is reachable the instant Pine has no open window.
        showAgentInbox()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentNotifications.stop()
        agentPresence.stop()
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
        // `applicationShouldTerminate` already completed task shutdown before
        // replying to AppKit. Fail closed if lifecycle wiring ever regresses:
        // project teardown must not discard live cancellation handles.
        if !registry.destroyAllProjects() {
            Logger.task.critical(
                "Application termination reached teardown with live user tasks"
            )
        }

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
            if shouldTerminate {
                agentNotifications.stop()
                agentPresence.stop()
            }
            reply(shouldTerminate)
        }
        return .terminateLater
    }

    private func remainingTerminationDuration(
        until deadline: DispatchTime
    ) -> Duration? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return nil }
        return .nanoseconds(
            Int64(clamping: deadline.uptimeNanoseconds - now)
        )
    }

    /// Captures the test override as a duration, then rebases it after the
    /// final user decision. Human deliberation must never consume Quit's
    /// bounded machine-work budget (#1354).
    private func terminationWorkBudgetNanoseconds(
        overriding deadline: DispatchTime?
    ) -> UInt64 {
        guard let deadline else { return 30_000_000_000 }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return 0 }
        return deadline.uptimeNanoseconds - now
    }

    /// Reserves a durable rollback slice before any termination mutation.
    /// Long budgets retain the existing 28s/2s policy; short budgets split in
    /// half instead of silently proceeding with no rollback barrier.
    nonisolated static func terminationBudgetSplit(
        availableNanoseconds: UInt64
    ) -> (forwardNanoseconds: UInt64, rollbackNanoseconds: UInt64)? {
        guard availableNanoseconds >= 2 else { return nil }
        let rollbackNanoseconds = min(
            2_000_000_000,
            availableNanoseconds / 2
        )
        guard rollbackNanoseconds > 0 else { return nil }
        return (
            availableNanoseconds - rollbackNanoseconds,
            rollbackNanoseconds
        )
    }

    private func valueBeforeTerminationDeadline<Value: Sendable>(
        _ deadline: DispatchTime,
        deadlineObserver: @escaping @Sendable () -> Void,
        onTimeout: @escaping @MainActor () -> Void,
        operation: @escaping @MainActor () async -> Value
    ) async -> Value? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else {
            deadlineObserver()
            onTimeout()
            return nil
        }
        return await withCheckedContinuation { continuation in
            let resolver = TerminationDeadlineResolver<Value>(continuation)
            let operationTask = Task { @MainActor in
                let value = await operation()
                resolver.resolve(value)
            }
            TerminationDeadlineTimer.queue.asyncAfter(
                deadline: deadline
            ) {
                if resolver.resolve(nil) {
                    deadlineObserver()
                    operationTask.cancel()
                    Task { @MainActor in
                        onTimeout()
                    }
                }
            }
        }
    }

    /// Presents one application-wide Quit summary. The safe Review path walks
    /// project-owned sheets only after the user opts in; Quit Anyway captures
    /// stable discard/process authorizations in one step. The 30-second clock
    /// starts after all human decisions and bounds only machine work.
    func confirmApplicationTermination(
        presentAlert: TerminationAlertPresenter? = nil,
        saveAll: TerminationSaveAll? = nil,
        applicationContext: DialogPresentationContext? = nil,
        terminationFailureContext: (@MainActor () -> DialogPresentationContext)? = nil,
        terminationDeadlineOverride: DispatchTime? = nil,
        terminationDeadlineObserver: @escaping @Sendable () -> Void = {}
    ) async -> Bool {
        let workBudgetNanoseconds = terminationWorkBudgetNanoseconds(
            overriding: terminationDeadlineOverride
        )
        let projects = registry.openProjects
            .sorted { $0.key.path.localizedStandardCompare($1.key.path) == .orderedAscending }
            .map(\.value)
        var terminationCommitted = false
        registry.freezeAutoSaveForTermination()
        defer {
            if terminationCommitted {
                registry.finishAutoSaveTerminationFreeze()
            } else {
                registry.cancelAutoSaveTerminationFreeze()
            }
        }
        let preflightTerminalAuthorizations = Dictionary(
            uniqueKeysWithValues: projects.map {
                (
                    ObjectIdentifier($0),
                    TerminalTabCloseAuthorization.authorizing(
                        tabs: $0.terminal.allTerminalTabs
                    )
                )
            }
        )
        let preflightAgentLaunchAuthorizations = Dictionary(
            uniqueKeysWithValues: projects.map {
                (
                    ObjectIdentifier($0),
                    $0.terminal.capturePineAgentLaunchAuthorization()
                )
            }
        )
        let preflightDiscardAuthorizations: [
            ObjectIdentifier: DirtyEditorContentAuthorization
        ] = Dictionary(
            uniqueKeysWithValues: projects.compactMap { projectManager in
                let dirty = projectManager.allDirtyTabs
                guard !dirty.isEmpty else { return nil }
                return (
                    ObjectIdentifier(projectManager),
                    DirtyEditorContentAuthorization(tabs: dirty)
                )
            }
        )
        let preflightUserTaskAuthorization =
            registry.captureUserTaskShutdownAuthorization()
        let attentionProjectCount = projects.filter {
            !$0.allDirtyTabs.isEmpty
                || preflightTerminalAuthorizations[
                    ObjectIdentifier($0)
                ]?.requiresConfirmation == true
                || preflightAgentLaunchAuthorizations[
                    ObjectIdentifier($0)
                ]?.requiresConfirmation == true
                || $0.hasOutstandingUserTaskExecution
        }.count
        let requiresAttention = attentionProjectCount > 0
            || preflightUserTaskAuthorization.requiresConfirmation
        let needsNativeDecision = presentAlert == nil
            && requiresAttention
        if applicationContext == nil, needsNativeDecision {
            // Quit can arrive from the Dock while Pine is hidden or every
            // project is miniaturized. Restore/create a discoverable owner
            // before capturing the fallback context.
            prepareApplicationDialogOwner()
        }
        let fallbackContext = applicationContext
            ?? DialogPresenter.forApplicationWindow()

        func hasEligibleOwner(
            _ context: DialogPresentationContext
        ) -> Bool {
            context.nsWindow.map {
                DialogPresenter.isEligibleApplicationOwner($0)
            } ?? false
        }

        func resolveFreshApplicationContext() -> DialogPresentationContext {
            if let applicationContext {
                // An injected presenter may intentionally use an off-screen
                // synthetic owner. Native sheets still require live eligibility.
                if presentAlert != nil || hasEligibleOwner(applicationContext) {
                    return applicationContext
                }
            }
            let currentContext = DialogPresenter.forApplicationWindow()
            if hasEligibleOwner(currentContext) {
                return currentContext
            }
            if presentAlert == nil {
                // The previously captured owner may have closed while another
                // project sheet was up. Restore/create a discoverable owner at
                // the point of use rather than reusing that stale authority.
                prepareApplicationDialogOwner()
                return DialogPresenter.forApplicationWindow()
            }
            // Injected presenters do not require a native owner. Preserve their
            // explicit context while still preferring a live replacement above.
            return applicationContext ?? fallbackContext
        }

        func resolveFreshDecisionContext(
            preferredProject: ProjectManager? = nil
        ) -> DialogPresentationContext {
            if let preferredProject {
                let projectContext = DialogPresenter.forProject(
                    preferredProject
                )
                if hasEligibleOwner(projectContext) {
                    return projectContext
                }
            }
            return resolveFreshApplicationContext()
        }

        func presentTerminationAlert(
            _ template: AlertTemplate,
            context: DialogPresentationContext,
            title: String,
            message: String
        ) async -> NSApplication.ModalResponse {
            if let presentAlert {
                return await presentAlert(template, context, title, message)
            }
            return await template.runSheet(
                on: context,
                messageText: title,
                informativeText: message
            )
        }

        func resolveTerminationFailureContext(
            preferredProject: ProjectManager? = nil
        ) -> DialogPresentationContext {
            if let preferredProject {
                let projectContext = DialogPresenter.forProject(
                    preferredProject
                )
                if let window = projectContext.nsWindow,
                   DialogPresenter.isEligibleApplicationOwner(window) {
                    return projectContext
                }
            }
            if let terminationFailureContext {
                return terminationFailureContext()
            }
            if presentAlert == nil {
                // A clean preflight may never have created or restored an
                // owner. Resolve one lazily only after machine work fails.
                prepareApplicationDialogOwner()
                return DialogPresenter.forApplicationWindow()
            }
            return fallbackContext
        }

        func presentTerminationFailure() async {
            _ = await presentTerminationAlert(
                .applicationQuitFailure,
                context: resolveTerminationFailureContext(),
                title: Strings.applicationQuitFailureTitle,
                message: Strings.applicationQuitFailureMessage
            )
        }

        func presentTerminationDecision(
            _ template: AlertTemplate,
            preferredProject: ProjectManager? = nil,
            title: String,
            message: String
        ) async -> NSApplication.ModalResponse? {
            let context = resolveFreshDecisionContext(
                preferredProject: preferredProject
            )
            guard presentAlert != nil || hasEligibleOwner(context) else {
                await presentTerminationFailure()
                return nil
            }
            let response = await presentTerminationAlert(
                template,
                context: context,
                title: title,
                message: message
            )
            // Native `.abort` means the sheet lost its captured owner; Cancel
            // has its own button response and must remain the only silent exit.
            if presentAlert == nil, response == .abort {
                await presentTerminationFailure()
                return nil
            }
            return response
        }

        var discardAuthorizations: [
            ObjectIdentifier: DirtyEditorContentAuthorization
        ] = [:]
        // Keyed by project. Authorization is by stable identity (agent session
        // id / process-group generation), never by a raw pgid snapshot, so an
        // agent spawning children while the sheet is up cannot invalidate the
        // Quit the user just confirmed (#1335, #1348).
        var terminalAuthorizations: [
            ObjectIdentifier: TerminalTabCloseAuthorization
        ] = [:]
        var agentLaunchAuthorizations: [
            ObjectIdentifier: PineAgentLaunchAuthorization
        ] = [:]
        var saveRequests: [ProjectManager] = []
        var preparedSavePlans: [
            ObjectIdentifier: ProjectManager.PreparedPaneSavePlan
        ] = [:]
        var preparedTerminationSavePlans: [
            ObjectIdentifier: ProjectManager.PreparedTerminationPaneSavePlan
        ] = [:]
        var quitAnyway = false
        var reviewIndividually = false
        var userTaskAuthorization = preflightUserTaskAuthorization

        if requiresAttention {
            guard let response = await presentTerminationDecision(
                .applicationQuitSummary,
                title: Strings.applicationQuitSummaryTitle,
                message: Strings.applicationQuitSummaryMessage(
                    max(attentionProjectCount, 1)
                )
            ) else { return false }
            switch response {
            case .alertFirstButtonReturn:
                reviewIndividually = true
            case .alertSecondButtonReturn:
                quitAnyway = true
            default:
                return false
            }
        }

        if quitAnyway {
            // The summary authorizes exactly the state that caused it to be
            // presented. New dirty content or process generations that appear
            // while the sheet is open still fail closed during revalidation.
            discardAuthorizations = preflightDiscardAuthorizations
            terminalAuthorizations = preflightTerminalAuthorizations
            agentLaunchAuthorizations = preflightAgentLaunchAuthorizations
        } else if reviewIndividually {
            for projectManager in projects {
                guard registry.openProjects.values.contains(where: {
                    $0 === projectManager
                }) else {
                    continue
                }
                let dirty = projectManager.allDirtyTabs
                guard !dirty.isEmpty else { continue }

                let fileList = dirty.map { "  • \($0.fileName)" }
                    .joined(separator: "\n")
                guard let response = await presentTerminationDecision(
                    .unsavedChangesBulk,
                    preferredProject: projectManager,
                    title: Strings.unsavedChangesTitle,
                    message: Strings.unsavedChangesListMessage(fileList)
                ) else { return false }
                switch response {
                case .alertFirstButtonReturn:
                    saveRequests.append(projectManager)
                case .alertSecondButtonReturn:
                    discardAuthorizations[ObjectIdentifier(projectManager)] =
                        DirtyEditorContentAuthorization(tabs: dirty)
                default:
                    return false
                }
            }

            for projectManager in projects {
                guard registry.openProjects.values.contains(where: {
                    $0 === projectManager
                }) else {
                    continue
                }
                let identifier = ObjectIdentifier(projectManager)
                let authorization = TerminalTabCloseAuthorization.authorizing(
                    tabs: projectManager.terminal.allTerminalTabs
                )
                terminalAuthorizations[identifier] = authorization
                let launchAuthorization = projectManager.terminal
                    .capturePineAgentLaunchAuthorization()
                agentLaunchAuthorizations[identifier] = launchAuthorization
                guard authorization.requiresConfirmation
                        || launchAuthorization.requiresConfirmation else {
                    continue
                }
                guard let response = await presentTerminationDecision(
                    .terminalActiveProcessWarning,
                    preferredProject: projectManager,
                    title: Strings.terminalActiveProcessWarningTitle,
                    message: Strings.terminalActiveProcessWarningMessage
                ) else { return false }
                guard response == .alertFirstButtonReturn else {
                    return false
                }
            }

            let displayedUserTaskAuthorization =
                registry.captureUserTaskShutdownAuthorization()
            if displayedUserTaskAuthorization.requiresConfirmation {
                guard let response = await presentTerminationDecision(
                    .activeUserTasksPreventQuit,
                    title: Strings.activeUserTasksPreventQuitTitle,
                    message: Strings.activeUserTasksPreventQuitMessage
                ) else { return false }
                guard response == .alertFirstButtonReturn else {
                    return false
                }
            }
            userTaskAuthorization = displayedUserTaskAuthorization
        } else {
            // No suspension point occurred after the empty preflight, so this
            // captures the same idle baseline for final revalidation.
            for projectManager in projects {
                terminalAuthorizations[ObjectIdentifier(projectManager)] =
                    TerminalTabCloseAuthorization.authorizing(
                        tabs: projectManager.terminal.allTerminalTabs
                    )
                agentLaunchAuthorizations[ObjectIdentifier(projectManager)] =
                    projectManager.terminal
                        .capturePineAgentLaunchAuthorization()
            }
        }

        // Collect every Save-As destination before rebasing the duration.
        // These native panels are human decisions, not bounded machine work.
        if saveAll == nil {
            for projectManager in saveRequests {
                let context = resolveFreshDecisionContext(
                    preferredProject: projectManager
                )
                guard presentAlert != nil || hasEligibleOwner(context) else {
                    await presentTerminationFailure()
                    return false
                }
                switch await projectManager.prepareSaveAllPaneTabs(
                    context: context
                ) {
                case .ready(let plan):
                    preparedSavePlans[ObjectIdentifier(projectManager)] = plan
                case .cancelledByUser:
                    if presentAlert == nil, !hasEligibleOwner(context) {
                        await presentTerminationFailure()
                    }
                    return false
                case .invalidated:
                    await presentTerminationFailure()
                    return false
                }
            }

            // Save All is one application-wide transaction. A destination
            // chosen in one project must not alias another prepared save or a
            // clean/open tab in any project, otherwise two clean buffers can
            // claim one final on-disk value.
            let destinationURLs = preparedSavePlans.values.flatMap(
                \.standardizedDestinationURLs
            )
            let plannedTabIDs = preparedSavePlans.values.reduce(
                into: Set<UUID>()
            ) { result, plan in
                result.formUnion(plan.plannedTabIDs)
            }
            let unplannedOpenURLs = Set(
                registry.openProjects.values.flatMap(\.allTabs).compactMap {
                    plannedTabIDs.contains($0.id)
                        ? nil
                        : $0.fileURL?.standardizedFileURL
                }
            )
            guard destinationURLs.count == Set(destinationURLs).count,
                  destinationURLs.allSatisfy({
                      !unplannedOpenURLs.contains($0)
                  }) else {
                await presentTerminationFailure()
                return false
            }
        }

        // Rebase the captured duration only after the final human response.
        let terminationDeadline = DispatchTime.now() + .nanoseconds(
            Int(clamping: workBudgetNanoseconds)
        )

        func cleanupPreparedTerminationSaves() {
            for (identifier, plan) in preparedTerminationSavePlans {
                guard let projectManager = projects.first(where: {
                    ObjectIdentifier($0) == identifier
                }) else { continue }
                projectManager.cleanupTerminationSavePlan(plan)
            }
            preparedTerminationSavePlans.removeAll()
        }

        if let saveAll {
            for projectManager in saveRequests {
                let context = resolveFreshDecisionContext(
                    preferredProject: projectManager
                )
                let saveResult = await valueBeforeTerminationDeadline(
                    terminationDeadline,
                    deadlineObserver: terminationDeadlineObserver,
                    onTimeout: {},
                    operation: {
                        await saveAll(projectManager, context)
                            ? PreparedPaneSaveCommitResult.saved
                            : PreparedPaneSaveCommitResult.invalidated
                    }
                )
                guard saveResult == .saved else {
                    await presentTerminationFailure()
                    return false
                }
            }
        } else {
            for projectManager in saveRequests {
                guard let plan = preparedSavePlans[
                    ObjectIdentifier(projectManager)
                ] else {
                    cleanupPreparedTerminationSaves()
                    await presentTerminationFailure()
                    return false
                }
                let (stageResult, stagedPlan) = await projectManager
                    .stagePreparedSaveAllPaneTabsForTermination(
                        plan,
                        until: terminationDeadline
                    )
                switch stageResult {
                case .ready:
                    guard let stagedPlan else {
                        cleanupPreparedTerminationSaves()
                        await presentTerminationFailure()
                        return false
                    }
                    preparedTerminationSavePlans[
                        ObjectIdentifier(projectManager)
                    ] = stagedPlan
                case .failed(let message):
                    cleanupPreparedTerminationSaves()
                    _ = await presentTerminationAlert(
                        .fileOperationErrorCritical,
                        context: resolveTerminationFailureContext(
                            preferredProject: projectManager
                        ),
                        title: Strings.fileOperationErrorTitle,
                        message: message
                    )
                    return false
                case .invalidated:
                    cleanupPreparedTerminationSaves()
                    await presentTerminationFailure()
                    return false
                case .timedOut:
                    terminationDeadlineObserver()
                    cleanupPreparedTerminationSaves()
                    await presentTerminationFailure()
                    return false
                }
            }

            // Validate every target before the first destructive install. The
            // atomic installer repeats the check and displaces existing files
            // with RENAME_SWAP to close the remaining pathname race.
            for projectManager in saveRequests {
                guard let plan = preparedTerminationSavePlans[
                    ObjectIdentifier(projectManager)
                ],
                      await projectManager
                        .terminationSaveDestinationsStillMatch(plan) else {
                    cleanupPreparedTerminationSaves()
                    await presentTerminationFailure()
                    return false
                }
            }

            for projectManager in saveRequests {
                guard let plan = preparedTerminationSavePlans[
                    ObjectIdentifier(projectManager)
                ] else {
                    cleanupPreparedTerminationSaves()
                    await presentTerminationFailure()
                    return false
                }
                switch await projectManager
                    .commitStagedSaveAllPaneTabsForTermination(
                        plan,
                        until: terminationDeadline
                    ) {
                case .saved:
                    preparedTerminationSavePlans.removeValue(
                        forKey: ObjectIdentifier(projectManager)
                    )
                case .failed(let message):
                    cleanupPreparedTerminationSaves()
                    _ = await presentTerminationAlert(
                        .fileOperationErrorCritical,
                        context: resolveTerminationFailureContext(
                            preferredProject: projectManager
                        ),
                        title: Strings.fileOperationErrorTitle,
                        message: message
                    )
                    return false
                case .invalidated:
                    cleanupPreparedTerminationSaves()
                    await presentTerminationFailure()
                    return false
                case .timedOut:
                    terminationDeadlineObserver()
                    cleanupPreparedTerminationSaves()
                    await presentTerminationFailure()
                    return false
                }
            }
        }

        // Runtime pane/tab IDs cannot be trusted across relaunch. Reserve a
        // rollback slice before freezing so every failed Quit can durably
        // restore the pre-handshake snapshot within the same absolute budget.
        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard nowNanoseconds < terminationDeadline.uptimeNanoseconds,
              let budgetSplit = Self.terminationBudgetSplit(
                  availableNanoseconds:
                      terminationDeadline.uptimeNanoseconds - nowNanoseconds
              ) else {
            terminationDeadlineObserver()
            await presentTerminationFailure()
            return false
        }
        let forwardDeadline = DispatchTime(
            uptimeNanoseconds:
                terminationDeadline.uptimeNanoseconds
                    - budgetSplit.rollbackNanoseconds
        )

        guard registry.userTaskShutdownAuthorizationStillCovers(
            userTaskAuthorization
        ) else {
            await presentTerminationFailure()
            return false
        }
        registry.freezeAgentTasksForTermination()
        registry.agentTasks.prepareForApplicationTermination()
        func rollbackAgentTasks() async {
            guard await registry.cancelAgentTaskTermination(
                until: terminationDeadline
            ) else {
                Logger.app.error(
                    "Agent task rollback did not reach a clean persistence barrier"
                )
                return
            }
        }
        guard let persistenceBudget = remainingTerminationDuration(
            until: forwardDeadline
        ) else {
            await rollbackAgentTasks()
            await presentTerminationFailure()
            return false
        }
        guard await registry.agentTasks.flushPersistence(
            maximumDuration: persistenceBudget
        ) == .saved else {
            Logger.app.error(
                "Agent task metadata did not reach a clean persistence barrier"
            )
            await rollbackAgentTasks()
            await presentTerminationFailure()
            return false
        }

        func destructiveAuthorizationsStillCoverCurrentState() -> Bool {
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

                // A project that appeared after the snapshot was never
                // presented. An idle one is safe; running work is not.
                guard let authorization = terminalAuthorizations[identifier]
                else {
                    let currentTerminalAuthorization =
                        TerminalTabCloseAuthorization.authorizing(
                        tabs: projectManager.terminal.allTerminalTabs
                    )
                    let currentLaunchAuthorization = projectManager.terminal
                        .capturePineAgentLaunchAuthorization()
                    guard !currentTerminalAuthorization.requiresConfirmation,
                          !currentLaunchAuthorization.requiresConfirmation else {
                        Logger.app.error(
                            "Quit aborted: project with running processes opened during the termination handshake"
                        )
                        return false
                    }
                    continue
                }
                guard authorization.stillCovers(
                    projectManager.terminal.allTerminalTabs
                ) else {
                    Logger.app.error(
                        "Quit aborted: terminal authorization no longer covers the project"
                    )
                    return false
                }
                guard let launchAuthorization =
                        agentLaunchAuthorizations[identifier],
                      launchAuthorization.stillCovers(
                          projectManager.terminal
                              .capturePineAgentLaunchAuthorization()
                      ) else {
                    Logger.app.error(
                        "Quit aborted: Pine agent-launch authorization no longer covers the project"
                    )
                    return false
                }
            }
            return registry.userTaskShutdownAuthorizationStillCovers(
                userTaskAuthorization
            )
        }

        guard destructiveAuthorizationsStillCoverCurrentState() else {
            await rollbackAgentTasks()
            await presentTerminationFailure()
            return false
        }

        var preparedUserTaskShutdown = false
        if registry.hasOutstandingUserTaskExecution {
            guard await registry.shutdownUserTasks(
                authorizedBy: userTaskAuthorization,
                until: forwardDeadline
            ) else {
                await rollbackAgentTasks()
                await presentTerminationFailure()
                return false
            }
            preparedUserTaskShutdown = true
        }

        // Task cleanup suspends off-main. Revalidate destructive state once
        // more before committing any editor discard.
        guard destructiveAuthorizationsStillCoverCurrentState() else {
            await rollbackAgentTasks()
            await presentTerminationFailure()
            return false
        }

        guard !preparedUserTaskShutdown
                || registry.userTaskShutdownIsPreparedForCommit(
                    userTaskAuthorization
                ) else {
            await rollbackAgentTasks()
            await presentTerminationFailure()
            return false
        }

        // Two-phase destructive commit: no project is mutated until every
        // project/terminal/task and editor authorization above passes.
        for projectManager in registry.openProjects.values {
            let identifier = ObjectIdentifier(projectManager)
            if let authorization = discardAuthorizations[identifier],
               !projectManager.canCommitDiscard(authorization) {
                await rollbackAgentTasks()
                await presentTerminationFailure()
                return false
            }
        }
        for projectManager in registry.openProjects.values {
            let identifier = ObjectIdentifier(projectManager)
            if let authorization = discardAuthorizations[identifier],
               !projectManager.commitDiscard(
                   authorization,
                   postReloadNotifications: false
                ) {
                await rollbackAgentTasks()
                await presentTerminationFailure()
                return false
            }
        }
        if preparedUserTaskShutdown,
           !registry.commitPreparedUserTaskShutdown(
                userTaskAuthorization
           ) {
            Logger.app.critical(
                "Prepared user-task shutdown changed during synchronous commit"
            )
            await rollbackAgentTasks()
            await presentTerminationFailure()
            return false
        }

        terminationCommitted = true
        return true
    }
}
