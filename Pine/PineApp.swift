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
        .defaultSize(width: 1440, height: 900)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            PineAppMenuCommands(
                checkForUpdatesViewModel:
                    appDelegate.checkForUpdatesViewModel,
                toggleQuickTerminal: { [weak appDelegate] in
                    appDelegate?.quickTerminalCoordinator.toggle()
                },
                recoverQuickTerminalDisplay: { [weak appDelegate] in
                    appDelegate?.quickTerminalCoordinator.recoverDisplay()
                },
                recentProjects: { [weak appDelegate] in
                    appDelegate?.registry.recentProjects ?? []
                },
                showAgentInbox: { [weak appDelegate] in
                    appDelegate?.showAgentInbox()
                },
                windowSession: { [weak appDelegate] in
                    appDelegate?.registry.keyWindowSession()
                },
                projectRegistry: { [weak appDelegate] in
                    appDelegate?.registry
                }
            )
        }

        Window(Strings.welcomeTitle, id: "welcome") {
            WelcomeView(registry: registry, appDelegate: appDelegate)
                .background { AppDelegateBridge(appDelegate: appDelegate, registry: registry) }
                .background { WelcomeWindowCapture(appDelegate: appDelegate) }
        }
        .defaultSize(
            width: WelcomeWindowMetrics.width,
            height: WelcomeWindowMetrics.height
        )
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
            appDelegate.openProjectWindow = { [registry] url in
                // Every open that names a project funnels through here, so
                // this is the one place the intent can be recorded before the
                // scene reads its persisted "last active project" (#1543).
                registry.noteExplicitProjectOpenRequest(url)
                openWindow(value: url)
            }

        }
    }
}

// MARK: - Project Window wrapper

/// Resolves a ProjectManager from the registry and injects it into ContentView.
/// Also ensures AppDelegate is wired up even when Welcome window is never shown.
///
/// Deliberately **not** `private`. AppKit derives autosave names for the
/// window's `NSSplitView` from `_typeName` of the scene's content type, and a
/// `private` type mangles to `Pine.(unknown context at $<address>).ProjectWindowView`
/// — an address that moves with ASLR on every launch. That made the autosave
/// key unique per launch, so the sidebar width was never restored and the
/// preference domain grew by one dead `NSSplitView Subview Frames …` key per
/// run (#1543). Internal visibility gives the stable name `Pine.ProjectWindowView`.
/// Covered by `WindowSceneAutosaveIdentityTests`.
struct ProjectWindowView: View {
    let projectURL: URL
    let registry: ProjectRegistry
    let appDelegate: AppDelegate
    @State private var windowSession: ProjectWindowSession
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow

    init(
        projectURL: URL,
        registry: ProjectRegistry,
        appDelegate: AppDelegate
    ) {
        self.projectURL = projectURL
        self.registry = registry
        self.appDelegate = appDelegate
        _windowSession = State(initialValue: ProjectWindowSession(
            initialProjectURL: projectURL
        ))
    }

    var body: some View {
        Group {
            // Use direct dict lookup — NOT projectManager(for:) which auto-creates.
            // Hidden windows from closed projects still get re-rendered by SwiftUI;
            // calling projectManager(for:) would silently re-add the closed project
            // to openProjects, breaking the "show Welcome when last project closes" logic.
            if let pm = registry.projectManagerIfAdmitted(
                for: windowSession.activeProjectURL
            ) {
                ContentView()
                    .id(ObjectIdentifier(pm))
                    .environment(pm)
                    .environment(pm.workspace)
                    .environment(pm.terminal)
                    .environment(pm.primaryTabManager)
                    .environment(pm.paneManager)
                    .environment(pm.toastManager)
                    .environment(registry)
                    .environment(windowSession)
                    .focusedSceneValue(\.projectManager, pm)
                    .background {
                        WindowCloseInterceptor(
                            projectManager: pm,
                            registry: registry,
                            projectURL: windowSession.activeProjectURL,
                            appDelegate: appDelegate,
                            windowSession: windowSession
                        )
                    }
            } else {
                // EmptyView does not enter the rendered hierarchy, so a task
                // attached to an otherwise empty Group never gets a chance to
                // admit a cold-restored project. Keep a real view mounted
                // until restoration either supplies ContentView or fails.
                ProgressView(Strings.progressLoadingProject)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Announce the window before restoring it: routing that arrives
            // mid-restore should still find this window rather than open a
            // second one for a project this window is about to show.
            registry.registerWindowSession(windowSession)
            let result = await windowSession.restoreIfNeeded(
                registry: registry
            )
            guard result == .unavailable else { return }
            registry.unregisterWindowSession(windowSession)
            dismissWindow(value: projectURL)
            appDelegate.showWelcome()
        }
        .onDisappear {
            registry.unregisterWindowSession(windowSession)
        }
        .alert(
            Strings.projectSwitcherErrorTitle,
            isPresented: Binding(
                get: { windowSession.alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        windowSession.alertMessage = nil
                    }
                }
            )
        ) {
            Button(Strings.dialogOK, role: .cancel) {}
        } message: {
            Text(windowSession.alertMessage ?? "")
        }
        // Closing a project does not remove the git worktrees it spawned, and
        // before #1524 it did not say so either. Not an error, so it gets its
        // own neutral alert rather than sharing the one above.
        .alert(
            Strings.projectSwitcherWorktreesKeptTitle,
            isPresented: Binding(
                get: { windowSession.retainedWorktreeReport != nil },
                set: { isPresented in
                    if !isPresented {
                        windowSession.acknowledgeRetainedWorktrees()
                    }
                }
            ),
            presenting: windowSession.retainedWorktreeReport
        ) { report in
            Button(Strings.dialogOK, role: .cancel) {}
            Button(Strings.contextRevealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting(
                    Array(report.worktreeRoots)
                )
            }
        } message: { report in
            Text(verbatim: Strings.projectSwitcherWorktreesKeptText(
                report.branchNames.joined(separator: ", "),
                report.managedRoot.path
            ))
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
    var windowSession: ProjectWindowSession? = nil

    func makeNSView(context: Context) -> InterceptorView {
        let view = InterceptorView()
        let coordinator = context.coordinator
        view.onMovedToWindow = { [weak coordinator] window in
            coordinator?.installDelegate(
                on: window,
                projectManager: projectManager,
                registry: registry,
                projectURL: projectURL,
                appDelegate: appDelegate,
                windowSession: windowSession
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
                appDelegate: appDelegate,
                windowSession: windowSession
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
        weak var windowSession: ProjectWindowSession?
        private var lifecycleObservers: [Any] = []
        /// Once a replacement coordinator adopts this installation, SwiftUI
        /// may still deliver a stale update or move callback to the old
        /// representable. Superseded generations can never reclaim ownership.
        private var isSuperseded = false

        func installDelegate(
            on window: NSWindow,
            projectManager: ProjectManager,
            registry: ProjectRegistry,
            projectURL: URL,
            appDelegate: AppDelegate,
            windowSession: ProjectWindowSession? = nil,
            presentAlert: CloseDelegate.CloseAlertPresenter? = nil,
            saveAll: CloseDelegate.CloseSaveAll? = nil
        ) {
            guard !isSuperseded else { return }
            self.windowSession = windowSession
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
                    // A replacement NSViewRepresentable coordinator may be
                    // installed before SwiftUI dismantles the previous one.
                    // Transfer the live delegate explicitly so the old
                    // coordinator's late teardown cannot restore the original
                    // delegate and retire this window's dialog authority
                    // (#1407).
                    // `existing.original` is weak; capture it strongly before
                    // relinquishing the old coordinator, which may hold its
                    // only strong reference.
                    let retainedOriginal = existing.original
                    existing.interceptorOwner?.relinquish(existing)
                    closeDelegate = existing
                    originalDelegate = retainedOriginal
                    existing.interceptorOwner = self
                    existing.windowSession = windowSession
                    if existing.didCompleteWindowLifecycle,
                       registry.isWindowOpen(projectURL),
                       registry.openProjects[
                           registry.canonicalProjectURL(projectURL)
                       ] === projectManager {
                        existing.beginNewWindowLifecycle(on: window)
                    }
                    // An unfinished delegate already observes this exact
                    // window. Re-observing during coordinator transfer would
                    // also renew dialog authorization and could resurrect a
                    // retired A before B binds.
                    return
                }
                let existingOriginal = existing.original
                existing.interceptorOwner?.relinquish(existing)
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
            delegate.windowSession = windowSession
            closeDelegate = delegate
            originalDelegate = original
            delegate.interceptorOwner = self
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
                                appDelegate: appDelegate,
                                windowSession: self.windowSession
                            )
                        }
                    }
                )
            }
        }

        private func retireCurrentInstallation(restoringOriginal: Bool) {
            removeLifecycleObservers()
            guard closeDelegate?.interceptorOwner === self else {
                closeDelegate = nil
                originalDelegate = nil
                installedWindow = nil
                return
            }
            if restoringOriginal,
               let installedWindow,
               let closeDelegate,
               installedWindow.delegate === closeDelegate {
                installedWindow.delegate = originalDelegate
            }
            closeDelegate?.detachFromWindow()
            closeDelegate?.interceptorOwner = nil
            closeDelegate = nil
            originalDelegate = nil
            installedWindow = nil
        }

        /// Transfers ownership to a replacement representable coordinator
        /// without touching the delegate or its project-window binding.
        /// SwiftUI may call the old coordinator's dismantle hook afterwards;
        /// clearing its local installation makes that teardown harmless.
        fileprivate func relinquish(_ delegate: CloseDelegate) {
            guard closeDelegate === delegate else { return }
            isSuperseded = true
            removeLifecycleObservers()
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
    typealias CloseAlertPresenter = ProjectCloseConfirmation.AlertPresenter
    typealias CloseSaveAll = ProjectCloseConfirmation.SaveAll

    let projectManager: ProjectManager
    let registry: ProjectRegistry
    let projectURL: URL
    weak var appDelegate: AppDelegate?
    weak var windowSession: ProjectWindowSession?
    /// Weak ref to original — Coordinator holds the strong ref separately
    /// to avoid a potential retain cycle through the delegate chain.
    weak var original: (any NSWindowDelegate)?
    /// The current representable coordinator generation that owns this proxy.
    /// Weak to avoid a cycle: the coordinator already retains the delegate.
    weak var interceptorOwner: WindowCloseInterceptor.Coordinator?

    /// Tracks whether windowWillClose has already been handled, to prevent
    /// the NotificationCenter fallback from double-firing.
    private var didHandleClose = false
    var didCompleteWindowLifecycle: Bool { didHandleClose }

    /// NotificationCenter observer token for the willClose fallback.
    /// nonisolated(unsafe): accessed from deinit (nonisolated) to remove observer.
    /// CloseDelegate is always deallocated on the main thread.
    nonisolated(unsafe) private var closeObserver: Any?
    private weak var ownerWindow: NSWindow?
    private var ownerWindowGeneration: UUID?
    /// Recovery is intentionally narrower than close handling. A retained
    /// delegate must still report A's eventual close with A's generation, but
    /// once the registry starts presenting B it may no longer restore A as a
    /// dialog owner merely because A remains visible for another run-loop turn.
    private var ownerRecoveryIsAuthorized = false
    private(set) var dialogContext = DialogPresentationContext.unscoped
    private var closeDecisionTask: Task<Void, Never>?
    private weak var approvedCloseWindow: NSWindow?
    private let closeAlertPresenter: CloseAlertPresenter?
    private let closeSaveAll: CloseSaveAll?

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
        if let retiredGeneration = projectManager
            .retiredDialogOwnerGeneration(for: window) {
            // Keep A's close callback armed with A's stale generation, but do
            // not let a transferred or newly wrapped delegate turn A into the
            // current dialog owner again.
            ownerWindowGeneration = retiredGeneration
            ownerRecoveryIsAuthorized = false
            dialogContext = .unscoped
            DialogPresenter.ownerDidClose(window)
            installCloseObserver(for: window)
            return
        }
        dialogContext = DialogPresenter.register(
            window: window,
            projectManager: projectManager
        )
        ownerWindowGeneration = projectManager.dialogOwnerWindowGeneration
        ownerRecoveryIsAuthorized = true
        installCloseObserver(for: window)
    }

    private func installCloseObserver(for window: NSWindow) {
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

    /// Revokes only presentation recovery for the current installation.
    /// Close observation deliberately remains armed so a delayed close still
    /// reaches the registry carrying the now-stale window generation.
    func retirePresentationAuthorization(for window: NSWindow) {
        guard ownerWindow === window else { return }
        ownerRecoveryIsAuthorized = false
        dialogContext = .unscoped
        DialogPresenter.ownerDidClose(window)
    }

    func authorizesOwnerRecovery(
        for window: NSWindow,
        presentationGeneration: UUID
    ) -> Bool {
        ownerRecoveryIsAuthorized
            && !didHandleClose
            && ownerWindow === window
            && ownerWindowGeneration == presentationGeneration
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
        // Application-level termination already completed its aggregate
        // dirty-tab and terminal decisions before setting `isTerminating`.
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
            // Commit destructive editor mutation only after the unsaved-file
            // decision has been revalidated against the current dirty tabs.
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

    /// Same question the project-close menu item asks, so a window and one
    /// project inside it never disagree about unsaved work.
    private func confirmWindowClose(
        context: DialogPresentationContext
    ) async -> ProjectCloseConfirmation.Decision {
        await ProjectCloseConfirmation.confirm(
            projectManager: projectManager,
            context: context,
            presentAlert: closeAlertPresenter,
            saveAll: closeSaveAll
        )
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
        ownerRecoveryIsAuthorized = false
        closeDecisionTask?.cancel()
        closeDecisionTask = nil
        approvedCloseWindow = nil
        let closingGeneration = ownerWindowGeneration
        if let ownerWindow {
            projectManager.recordCompletedDialogOwnerLifecycle(
                ownerWindow,
                generation: closingGeneration
            )
            DialogPresenter.ownerDidClose(ownerWindow)
        }
        windowSession?.windowDidClose(registry: registry)
        appDelegate?.handleProjectWindowDisappear(
            projectURL: projectURL,
            registry: registry,
            expectedManager: projectManager,
            expectedWindowGeneration: closingGeneration
        )
    }

    /// Re-arms a retained delegate only after ProjectRegistry has explicitly
    /// moved the same project out of its background state. Repeated
    /// representable updates during one live window generation must never
    /// reset the once-only close guard.
    func beginNewWindowLifecycle(on window: NSWindow) {
        guard didHandleClose,
              projectManager.authorizeCompletedDialogOwnerLifecycle(
                window,
                generation: ownerWindowGeneration
              ) else { return }
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
        ownerWindowGeneration = nil
        ownerRecoveryIsAuthorized = false
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

/// The three AppKit reads behind `AppDelegate.agentInboxHostOptions()`.
///
/// Grouped and injectable because the wrapper that composes them is otherwise
/// invisible to tests: the unit test host is a background application, so its
/// live windows cannot reproduce key status, Dock state, or on-screen order.
struct AgentInboxWindowSources {
    var windows: () -> [NSWindow]
    var keyWindow: () -> NSWindow?
    var welcomeWindow: () -> NSWindow?
}

class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate,
                   GlobalTabSwitcherKeyControllerDelegate,
                   AgentInboxHostEnvironment {
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
    typealias TerminationAliasCapture = @Sendable (
        [URL],
        DispatchTime
    ) async -> TerminationFileAliasCaptureResult

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
    var registry = ProjectRegistry() {
        didSet {
            if oldValue !== registry {
                oldValue.quickTerminalAgentRouter = nil
            }
            bindQuickTerminalAgentRouting()
        }
    }

    /// Application-wide, permission-gated agent notification coordinator.
    lazy var agentNotifications = AgentNotificationController(
        registry: registry.agentTasks,
        settings: .shared,
        isPresented: { [weak self] taskID in
            self?.registry.isAgentTaskPresented(taskID) ?? false
        },
        openTask: { [weak self] identity in
            self?.openAgentTaskRoute(identity)
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

    private func bindQuickTerminalAgentRouting() {
        quickTerminalCoordinator.registry = registry
        registry.quickTerminalAgentRouter = quickTerminalCoordinator
    }

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
    #if DEBUG
    /// Retained only when a separately launched Debug app process opts into
    /// the lifecycle integration protocol. Normal developer/UI-test launches
    /// never create the driver or replace the production presenters.
    private var applicationLifecycleProcessDriver:
        ApplicationLifecycleProcessDriver?
    var terminationAlertPresenterForProcessTest: TerminationAlertPresenter?
    var terminationSaveAllForProcessTest: TerminationSaveAll?
    var terminationDeadlineForProcessTest: DispatchTime?
    #endif
    /// The AppKit facts ``agentInboxHostOptions()`` reads, as replaceable
    /// closures.
    ///
    /// Production always runs the defaults below; tests substitute them, which
    /// is the only way to see that each fact reaches the parameter it names.
    /// The unit test host is a background application: it has no key window,
    /// `orderedWindows` does not match what is on screen, and a window never
    /// reaches the Dock, so none of those three reads can be established from
    /// live windows.
    lazy var agentInboxWindowSources = AgentInboxWindowSources(
        // Not `orderedWindows`: it omits windows that eligibility must see and
        // refuse itself, which would make the refusal unfalsifiable.
        windows: { NSApp.windows },
        // Not `mainWindow`: main stays on the last project window while an
        // auxiliary panel holds key, which would send ⇧⌘I into a window the
        // user is not typing in. The two agree in every single-window state,
        // so nothing on screen would look wrong.
        keyWindow: { NSApp.keyWindow },
        // `onScreenOrDock`: the presentation workflow deminiaturizes its
        // host before presenting, so a minimized Welcome window is reused
        // rather than bypassed in favour of creating a second one (#1507).
        welcomeWindow: { [weak self] in
            self?.welcomeHostWindow(reach: .onScreenOrDock)
        }
    )

    private var welcomeVisibilityGeneration = 0
    private var pendingWelcomeEnsureTask: Task<Void, Never>?

    /// Owns the application-level Agent Inbox presentation workflow: host
    /// selection, restore-and-focus, and the single-request rule (#1491).
    /// `AppDelegate` supplies only the AppKit facts, through
    /// `AgentInboxHostEnvironment`.
    private(set) lazy var agentInboxPresentation =
        AgentInboxPresentationCoordinator(
            router: .shared,
            environment: self
        )

    /// Closure to open a named SwiftUI window, set by PineApp on launch.
    var openNamedWindow: ((String) -> Void)?
    /// Closure to open a project SwiftUI window by URL, set by PineApp on launch.
    var openProjectWindow: ((URL) -> Void)?

    func showAgentInbox() {
        agentInboxPresentation.present()
    }

    // MARK: - AgentInboxHostEnvironment

    /// Every window that could own the Inbox popover, read through
    /// ``agentInboxWindowSources`` so which fact reaches which parameter is
    /// observable: the unit test host runs as a background application, where
    /// AppKit reports no key window at all.
    func agentInboxHostOptions() -> [AgentInboxHostOption] {
        agentInboxHostOptions(
            windows: agentInboxWindowSources.windows(),
            keyWindow: agentInboxWindowSources.keyWindow(),
            welcomeWindow: agentInboxWindowSources.welcomeWindow()
        )
    }

    /// Every AppKit fact enters as a parameter so the projection itself is
    /// testable: the `CloseDelegate` cast that decides what is a candidate at
    /// all, the eligibility conjunction, and Welcome's fixed last position.
    /// The pure ordering rule cannot catch a mistake made here.
    ///
    /// - Note: a project window in the Dock **is** a candidate (#1507). The
    ///   Inbox workflow restores and focuses its host before presenting, so
    ///   ``WindowRoutingReach/onScreenOrDock`` is the honest reach for it —
    ///   `window.isVisible` alone reads `false` for a miniaturized window and
    ///   would send ⇧⌘I to a new Welcome window while the user's project
    ///   stayed in the Dock. The in-place command paths keep the narrower
    ///   reach; see ``isEligibleRoutingWindow(_:delegate:reach:)``.
    func agentInboxHostOptions(
        windows: [NSWindow],
        keyWindow: NSWindow?,
        welcomeWindow: NSWindow?
    ) -> [AgentInboxHostOption] {
        let mostRecentProject = mostRecentlyActiveProjectManager()
        var options: [AgentInboxHostOption] = windows.compactMap { window in
            guard let delegate = window.delegate as? CloseDelegate else {
                return nil
            }
            let project = delegate.projectManager
            return AgentInboxHostOption(
                candidate: AgentInboxHostCandidate(
                    kind: .project,
                    isKeyWindow: window === keyWindow,
                    isEligibleWindow: isEligibleRoutingWindow(
                        window,
                        delegate: delegate,
                        reach: .onScreenOrDock
                    ),
                    showsMostRecentlyActiveProject: mostRecentProject != nil
                        && project === mostRecentProject
                ),
                host: window
            )
        }
        if let welcomeWindow {
            options.append(AgentInboxHostOption(
                candidate: AgentInboxHostCandidate(
                    kind: .welcome,
                    isKeyWindow: welcomeWindow === keyWindow
                ),
                host: welcomeWindow
            ))
        }
        return options
    }

    func activateApplicationForAgentInbox() {
        NSApp.activate()
    }

    func createAgentInboxWelcomeHost() {
        showWelcome()
    }

    func awaitAgentInboxWelcomeHost() async -> (any AgentInboxHosting)? {
        await awaitVisibleWelcomeWindow()
    }

    func deliverAgentInboxRequest(
        _ operation: @escaping @MainActor () -> Void
    ) {
        NativeCommandDelivery.deferToNextMainRunLoop(operation)
    }

    /// The same 25 ms interval `awaitVisibleWelcomeWindow()` polls on, so the
    /// two waits this workflow can perform are bounded on the same scale.
    func waitForAgentInboxAnchor() async {
        try? await Task.sleep(for: .milliseconds(25))
    }

    /// The project shown by the window that most recently became key. It is
    /// the Inbox destination while an auxiliary window — Settings, About —
    /// holds key and therefore cannot host the popover itself.
    private func mostRecentlyActiveProjectManager() -> ProjectManager? {
        guard let session = registry.keyWindowSession() else { return nil }
        return registry.openProjects[
            registry.canonicalProjectURL(session.activeProjectURL)
        ]
    }

    /// The one definition of "this window may receive a routed command".
    ///
    /// Native command delivery and Agent Inbox host selection both depend on
    /// it. A closing, hidden, or unregistered window can still sit in
    /// `NSApp.windows`; keeping a single copy of the rule is what stops ⇧⌘I
    /// and a delivered notification from disagreeing about which windows are
    /// still alive.
    /// - Parameter reach: whether a window sitting in the Dock counts as
    ///   present. Only callers that restore and focus the host before acting
    ///   pass ``WindowRoutingReach/onScreenOrDock`` (#1507); the in-place
    ///   command paths keep the on-screen requirement so a menu command can
    ///   never mutate a window the user cannot see.
    private func isEligibleRoutingWindow(
        _ window: NSWindow,
        delegate: CloseDelegate,
        reach: WindowRoutingReach = .onScreenOnly
    ) -> Bool {
        !delegate.didCompleteWindowLifecycle
            && reach.admitsWindow(
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized
            )
            && registry.isWindowOpen(delegate.projectURL)
            && isRegisteredProject(delegate.projectManager)
    }

    /// True while the registry still holds this exact project model.
    private func isRegisteredProject(_ project: ProjectManager) -> Bool {
        registry.openProjects.values.contains { $0 === project }
    }

    /// Focuses one exact agent route on behalf of an explicit user action —
    /// a notification response, or a Dock live-task entry (#1492). This is the
    /// single navigation authority for both: every failure mode degrades to
    /// the Agent Inbox rather than to a different session.
    private func openAgentTaskRoute(
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
    func handleProjectWindowDisappear(
        projectURL: URL,
        registry: ProjectRegistry,
        expectedManager: ProjectManager? = nil,
        expectedWindowGeneration: UUID? = nil
    ) {
        guard !isTerminating else { return }
        // Save session before closing so it can be restored
        // when the user reopens this project from Welcome or Open Recent.
        let canonical = registry.canonicalProjectURL(projectURL)
        guard let manager = registry.openProjects[canonical],
              expectedManager == nil || manager === expectedManager,
              expectedWindowGeneration == nil
                || manager.dialogOwnerWindowGeneration
                    == expectedWindowGeneration else {
            return
        }
        manager.saveSession()
        manager.cleanupEditorContext()
        registry.closeProjectWindow(
            projectURL,
            expectedManager: expectedManager,
            expectedWindowGeneration: expectedWindowGeneration
        )
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
        welcomeHostWindow(reach: .onScreenOnly)
    }

    /// The Welcome window a caller with this reach may route to, cached on
    /// ``welcomeWindow`` when a live one is found by identifier.
    ///
    /// The Inbox passes ``WindowRoutingReach/onScreenOrDock`` so a Welcome
    /// window the user minimized is restored and reused instead of a second
    /// one being created behind it (#1507). Every other caller wants a window
    /// that can show UI right now and keeps ``WindowRoutingReach/onScreenOnly``.
    /// - Parameter windows: the window list to scan, defaulting to
    ///   `NSApp.windows`. Injectable because the unit test host accumulates
    ///   windows from every suite that ran before, so identity assertions
    ///   against the live list would answer for someone else's window.
    func welcomeHostWindow(
        reach: WindowRoutingReach,
        windows: [NSWindow]? = nil
    ) -> NSWindow? {
        if let welcomeWindow,
           reach.admitsWindow(
               isVisible: welcomeWindow.isVisible,
               isMiniaturized: welcomeWindow.isMiniaturized
           ) {
            return welcomeWindow
        }
        guard let liveWindow = (windows ?? NSApp.windows).first(where: {
            $0.identifier?.rawValue == "welcome"
                && $0.contentView != nil
                && reach.admitsWindow(
                    isVisible: $0.isVisible,
                    isMiniaturized: $0.isMiniaturized
                )
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
            guard let index = ownerStates.firstIndex(of: .eligible),
                  windows.indices.contains(index) else {
                ensureWelcomeVisible()
                return
            }
            windows[index].makeKeyAndOrderFront(nil)
            NSApp.activate()
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
        window.setContentSize(NSSize(
            width: WelcomeWindowMetrics.width,
            height: WelcomeWindowMetrics.height
        ))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false
        welcomeWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let driver = ApplicationLifecycleProcessDriver.fromEnvironment() {
            applicationLifecycleProcessDriver = driver
            registry = driver.makeRegistry()
            return
        }
        #endif

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
        #if DEBUG
        if let applicationLifecycleProcessDriver {
            applicationLifecycleProcessDriver.start(appDelegate: self)
            return
        }
        #endif

        FocusDiagnosticsProbe.startIfRequested()
        NSWindow.allowsAutomaticWindowTabbing = false
        bindQuickTerminalAgentRouting()
        agentNotifications.start()
        agentPresence.start()

        // The key-down half is routed through the single precedence monitor
        // below; this installs Control-release and owner-window cancellation.
        tabSwitcherKeyController.delegate = self
        tabSwitcherKeyController.install()

        // Clean up stale recovery files across all projects. The recovery
        // sheet states this same window, so a snapshot the user keeps putting
        // off has a published lifetime rather than a silent one (#1503).
        RecoveryManager.cleanupAllStaleEntries(
            olderThan: RecoveryManager.staleEntryRetentionDays
        )

        // Arm the global quick-terminal hotkey (#1113). Carbon hotkeys work
        // in the App Sandbox without Accessibility permission; disabled by
        // launch flag for UI tests / opt-out.
        if !Self.isQuickTerminalDisabled {
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
                        projectManager: self?.activeProjectManager(),
                        windowAvailability: ProjectWindowCommandAvailability(
                            session: self?.registry.keyWindowSession(),
                            projectManager: self?.activeProjectManager()
                        )
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

        // ⌘= mirrors the menu's ⌘+ (Zoom In) and ⇧⌘- mirrors ⌘- (Zoom Out)
        // (#1564). SwiftUI Commands cannot carry a hidden second key
        // equivalent and the chord grammar cannot spell "cmd++", so the
        // aliases ride this physical-key router, matching the exact key
        // position the way the system's own shortcuts do. The key filter
        // runs first so every other keyDown stays free of registry work; a
        // user rebind of the command retires its alias.
        if FontZoomAliasPolicy.handles(keyCode: Int(event.keyCode)) {
            if let zoom = FontZoomAliasPolicy.zoom(
                keyCode: Int(event.keyCode),
                modifiers: KeyboardShortcutMatcher.normalizedModifiers(
                    event.modifierFlags
                ),
                increaseFontSizeRebound:
                    ExtensibilityManager.shared.keybindings
                        .hasOverride(for: .increaseFontSize),
                decreaseFontSizeRebound:
                    ExtensibilityManager.shared.keybindings
                        .hasOverride(for: .decreaseFontSize)
            ) {
                switch zoom {
                case .increase:
                    FontSizeSettings.shared.increase()
                case .decrease:
                    FontSizeSettings.shared.decrease()
                }
                return true
            }
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
            return NativeCommandRoutingCandidate(
                projectManager: project,
                isKeyWindow: window === NSApp.keyWindow,
                isEligibleWindow: isEligibleRoutingWindow(
                    window,
                    delegate: delegate
                )
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
        guard isRegisteredProject(match.0) else {
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
            Task { @MainActor [weak self] in
                _ = await self?.openRecentProject(
                    url,
                    fallbackOpenProjectWindow: fallbackOpenProjectWindow
                )
            }
        }
    }

    /// Executes the shared Open Recent transition after its initiating
    /// SwiftUI/AppKit action stack has unwound.
    @discardableResult
    func openRecentProject(
        _ url: URL,
        fallbackOpenProjectWindow: ((URL) -> Void)? = nil
    ) async -> Bool {
        let targetRegistry = registry
        guard let project = await targetRegistry
                .projectManagerForRecentProject(url),
              !Task.isCancelled,
              registry === targetRegistry,
              let canonical = project.rootURL?.standardizedFileURL,
              targetRegistry.openProjects[canonical] === project else {
            return false
        }
        if targetRegistry.isWindowOpen(canonical),
           let window = liveProjectWindow(
               for: project,
               canonicalURL: canonical
           ) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            hideWelcome()
            return true
        }

        // A cold-restored multi-project scene can own this project before it
        // has installed a CloseDelegate. Raise that scene by its stable anchor
        // instead of opening the active project URL as a second WindowGroup
        // value. Once activated, the restored scene observes the admitted
        // manager and replaces its loading placeholder with ContentView.
        if let windowSession = targetRegistry.windowSession(
            owning: canonical
        ) {
            await windowSession.activate(
                canonical,
                registry: targetRegistry
            )
            guard windowSession.activeProjectURL == canonical,
                  let openProjectWindow = self.openProjectWindow
                    ?? fallbackOpenProjectWindow else {
                return false
            }
            openProjectWindow(windowSession.sceneProjectURL)
            hideWelcome()
            return true
        }

        // File > Open Recent follows the same one-window project flow as the
        // toolbar switcher when a project window is currently eligible. A
        // linked worktree can join only when this exact session already owns
        // its persisted proof; otherwise the existing separate-scene path
        // remains the fail-closed fallback.
        if let destination = nativeCommandDestination(requestedProject: nil),
           let windowSession = destination.delegate.windowSession,
           windowSession.managedWorktrees[canonical] != nil
                || targetRegistry.isOrdinaryProjectScope(canonical) {
            if windowSession.managedWorktrees[canonical] != nil {
                await windowSession.activate(
                    canonical,
                    registry: targetRegistry
                )
            } else {
                await windowSession.openProject(
                    canonical,
                    registry: targetRegistry,
                    allowAlreadyOpenTarget: true
                )
            }
            guard windowSession.activeProjectURL == canonical else {
                return false
            }
            destination.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            hideWelcome()
            return true
        }

        // A registry entry can briefly claim an open window after AppKit has
        // already hidden or retired its delegate. Move that model back to the
        // retained-background state before asking SwiftUI for a replacement.
        if targetRegistry.isWindowOpen(canonical) {
            targetRegistry.closeProjectWindow(canonical)
        }
        guard let openProjectWindow =
                self.openProjectWindow ?? fallbackOpenProjectWindow else {
            targetRegistry.closeProjectWindow(canonical)
            return false
        }
        guard !Task.isCancelled,
              registry === targetRegistry,
              targetRegistry.openProjects[canonical] === project else {
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
        // entry carries the exact task, run, and process generation it was
        // rendered for (#1492), so selecting one focuses that session's own
        // terminal instead of the general Inbox.
        let agentItems = AgentDockMenuRouting.items(
            for: registry.agentTasks.tasks
        )
        for entry in agentItems {
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(dockMenuOpenAgentTask(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.identity
            menu.addItem(item)
        }
        if !agentItems.isEmpty {
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
        routeDockMenuAgentTask(
            representedObject: sender.representedObject,
            presentInbox: { self.showAgentInbox() },
            routeExactTask: { self.openAgentTaskRoute($0) }
        )
    }

    /// Shared body of the Dock agent action (#1492).
    ///
    /// AppKit rebuilds the Dock menu on every open, but a run can still end
    /// between rendering an entry and selecting it. The captured identity is
    /// therefore rebuilt from the current registry snapshot and compared
    /// before anything is activated; ``openAgentTaskRoute(_:)`` then applies
    /// the shared notification-route authority again after every suspension.
    /// A stale, replaced, or unreadable entry never focuses a different
    /// session — it lands on the Inbox's truthful durable history.
    ///
    /// The two effects are parameters rather than direct calls so the
    /// fail-closed decision stays deterministic in tests without presenting
    /// AppKit windows.
    @discardableResult
    func routeDockMenuAgentTask(
        representedObject: Any?,
        presentInbox: @MainActor () -> Void,
        routeExactTask: @MainActor (AgentNotificationRouteIdentity) -> Void
    ) -> AgentDockMenuRoute {
        guard let identity = AgentDockMenuRouting.routeIdentity(
            fromRepresentedObject: representedObject
        ), AgentDockMenuRouting.matchesCurrentRoute(
            identity,
            task: registry.agentTasks.task(for: identity.taskID)
        ) else {
            presentInbox()
            return .inbox
        }
        routeExactTask(identity)
        return .task(identity)
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
            // Clean up the recovery snapshots this session is answerable for:
            // the ones belonging to its open tabs. Emptying the whole
            // directory would also take the crash snapshots nobody has decided
            // about yet — including the ones the recovery sheet is showing on
            // screen at this very moment, which `hasUnsavedChanges` cannot
            // see because recovery snapshots are not tabs (#1503).
            if !pm.hasUnsavedChanges {
                pm.recoveryManager?.deleteSnapshotsOfOpenTabs(
                    pm.allTabs.map(\.id)
                )
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
            #if DEBUG
            let shouldTerminate = await confirmApplicationTermination(
                presentAlert: terminationAlertPresenterForProcessTest,
                saveAll: terminationSaveAllForProcessTest,
                terminationDeadlineOverride:
                    terminationDeadlineForProcessTest
            )
            #else
            let shouldTerminate = await confirmApplicationTermination()
            #endif
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

    private func presentLateTerminationSaveFailure(
        preferredProject: ProjectManager?,
        internalMessage: String,
        retainedArtifacts: [URL]
    ) async {
        Logger.app.error(
            "Late termination save failure: \(internalMessage, privacy: .public)"
        )
        let paths = Array(Set(retainedArtifacts)).sorted {
            $0.path < $1.path
        }.map(\.path).joined(separator: "\n")
        let message = Strings.applicationQuitFailureMessage
            + (paths.isEmpty ? "" : "\n\n" + paths)
        while !Task.isCancelled {
            prepareApplicationDialogOwner()
            let projectContext = preferredProject.map {
                DialogPresenter.forProject($0)
            }
            let context: DialogPresentationContext
            if let projectContext,
               let window = projectContext.nsWindow,
               DialogPresenter.isEligibleApplicationOwner(window) {
                context = projectContext.waitingUntilOwnerAvailable()
            } else {
                context = DialogPresenter.forApplicationWindow()
                    .waitingUntilOwnerAvailable()
            }
            let response = await AlertTemplate.fileOperationErrorCritical
                .runSheet(
                    on: context,
                    messageText: Strings.fileOperationErrorTitle,
                    informativeText: message
                )
            if response == .alertFirstButtonReturn { return }
            try? await Task.sleep(for: .milliseconds(25))
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
        terminationDeadlineObserver: @escaping @Sendable () -> Void = {},
        terminationAliasCapture: @escaping TerminationAliasCapture = { urls, deadline in
            await TerminationFileAliasResolver.capture(
                urls,
                until: deadline
            )
        }
    ) async -> Bool {
        let workBudgetNanoseconds = terminationWorkBudgetNanoseconds(
            overriding: terminationDeadlineOverride
        )
        let projects = registry.openProjects
            .sorted { $0.key.path.localizedStandardCompare($1.key.path) == .orderedAscending }
            .map(\.value)
        for project in projects {
            project.terminationSaveLateFailureHandler = { [weak self, weak project] message, retainedArtifacts in
                Task { @MainActor in
                    await self?.presentLateTerminationSaveFailure(
                        preferredProject: project,
                        internalMessage: message,
                        retainedArtifacts: retainedArtifacts
                    )
                }
            }
        }
        var terminationCommitted = false
        var heldAgentLaunchAuthorizations: [
            (TerminalManager, PineAgentLaunchAuthorization)
        ] = []
        registry.freezeAutoSaveForTermination()
        defer {
            if terminationCommitted {
                registry.finishAutoSaveTerminationFreeze()
            } else {
                for (terminal, authorization) in
                        heldAgentLaunchAuthorizations.reversed() {
                    terminal.cancelAuthorizedAgentLaunchTerminationDecision(
                        authorization
                    )
                }
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
        let preflightQuickTerminalAuthorization =
            TerminalTabCloseAuthorization.authorizing(
                tabs: quickTerminalCoordinator.paneState.terminalTabs
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
        let attentionProjectIDs = Set(projects.compactMap { projectManager in
            let identifier = ObjectIdentifier(projectManager)
            return !projectManager.allDirtyTabs.isEmpty
                || preflightTerminalAuthorizations[
                    identifier
                ]?.requiresConfirmation == true
                || preflightAgentLaunchAuthorizations[
                    identifier
                ]?.requiresConfirmation == true
                || projectManager.hasOutstandingUserTaskExecution
                ? identifier
                : nil
        }).union(preflightUserTaskAuthorization.confirmingOwnerIDs)
        let attentionItemCount = attentionProjectIDs.count
            + (preflightQuickTerminalAuthorization.requiresConfirmation ? 1 : 0)
        let requiresAttention = attentionItemCount > 0
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

        func terminationContext(
            _ context: DialogPresentationContext
        ) -> DialogPresentationContext {
            context.waitingUntilOwnerAvailable()
        }

        func resolveFreshApplicationContext() -> DialogPresentationContext {
            if let applicationContext, applicationContext.nsWindow != nil {
                // An injected presenter may intentionally use an off-screen
                // synthetic owner. Native sheets still require live eligibility.
                if presentAlert != nil || hasEligibleOwner(applicationContext) {
                    return terminationContext(applicationContext)
                }
            }
            let currentContext = DialogPresenter.forApplicationWindow()
            if hasEligibleOwner(currentContext) {
                return terminationContext(currentContext)
            }
            if presentAlert == nil {
                // The previously captured owner may have closed while another
                // project sheet was up. Restore/create a discoverable owner at
                // the point of use rather than reusing that stale authority.
                prepareApplicationDialogOwner()
                return terminationContext(
                    DialogPresenter.forApplicationWindow()
                )
            }
            // Injected presenters do not require a native owner. Preserve their
            // explicit context while still preferring a live replacement above.
            return terminationContext(applicationContext ?? fallbackContext)
        }

        func resolveFreshDecisionContext(
            preferredProject: ProjectManager? = nil
        ) -> DialogPresentationContext {
            if let preferredProject {
                let projectContext = DialogPresenter.forProject(
                    preferredProject
                )
                if hasEligibleOwner(projectContext) {
                    return terminationContext(projectContext)
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
                    return terminationContext(projectContext)
                }
            }
            if let terminationFailureContext {
                let context = terminationFailureContext()
                if presentAlert != nil || hasEligibleOwner(context) {
                    return terminationContext(context)
                }
            }
            if presentAlert == nil {
                // A clean preflight may never have created or restored an
                // owner. Resolve one lazily only after machine work fails.
                prepareApplicationDialogOwner()
                return terminationContext(
                    DialogPresenter.forApplicationWindow()
                )
            }
            return resolveFreshApplicationContext()
        }

        /// Machine failures are never user cancellation. Require the sole OK
        /// response as proof that AppKit displayed the explanation. `.abort`
        /// means presentation authority was lost, so retry on a freshly
        /// resolved project/application owner. Bound those retries so a broken
        /// presenter cannot trap termination in an endless alert loop.
        @discardableResult
        func presentTerminationFailure(
            _ template: AlertTemplate = .applicationQuitFailure,
            preferredProject: ProjectManager? = nil,
            title: String = Strings.applicationQuitFailureTitle,
            message: String = Strings.applicationQuitFailureMessage
        ) async -> Bool {
            let maximumAttempts = 3
            for attempt in 0..<maximumAttempts {
                guard !Task.isCancelled else { break }
                let context = resolveTerminationFailureContext(
                    preferredProject: preferredProject
                )
                if presentAlert == nil, !hasEligibleOwner(context) {
                    prepareApplicationDialogOwner()
                    if attempt + 1 < maximumAttempts {
                        do {
                            try await Task.sleep(for: .milliseconds(25))
                        } catch {
                            return false
                        }
                    }
                    continue
                }
                let response = await presentTerminationAlert(
                    template,
                    context: context,
                    title: title,
                    message: message
                )
                if response == .alertFirstButtonReturn {
                    return true
                }
                if attempt + 1 < maximumAttempts {
                    Logger.app.error(
                        "Quit failure explanation lost its dialog owner; retrying on a fresh owner"
                    )
                    if presentAlert == nil {
                        prepareApplicationDialogOwner()
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(25))
                    } catch {
                        return false
                    }
                }
            }
            Logger.app.critical(
                "Quit failure explanation could not be presented after bounded retries"
            )
            return false
        }

        func presentTerminationDecision(
            _ template: AlertTemplate,
            preferredProject: ProjectManager? = nil,
            title: String,
            message: String
        ) async -> NSApplication.ModalResponse? {
            let maximumAttempts = 3
            for attempt in 0..<maximumAttempts {
                let context = resolveFreshDecisionContext(
                    preferredProject: preferredProject
                )
                if presentAlert == nil, !hasEligibleOwner(context) {
                    prepareApplicationDialogOwner()
                    if attempt + 1 < maximumAttempts {
                        await Task.yield()
                    }
                    continue
                }
                let response = await presentTerminationAlert(
                    template,
                    context: context,
                    title: title,
                    message: message
                )
                // User cancellation has a template-specific button response.
                // `.abort` is presentation loss and must rebind instead of
                // being mistaken for that user decision.
                if response != .abort {
                    return response
                }
                Logger.app.error(
                    "Quit decision lost its dialog owner; retrying on a fresh owner"
                )
                if presentAlert == nil {
                    prepareApplicationDialogOwner()
                }
                if attempt + 1 < maximumAttempts {
                    await Task.yield()
                }
            }
            await presentTerminationFailure()
            return nil
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
        var quickTerminalAuthorization: TerminalTabCloseAuthorization?
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

        // Pin every Pine launch that contributed to the preflight before the
        // first sheet suspends. Claim TTL bounds detector convergence, not the
        // amount of time a person may spend considering Quit.
        for projectManager in projects {
            let authorization = preflightAgentLaunchAuthorizations[
                ObjectIdentifier(projectManager)
            ] ?? projectManager.terminal
                .capturePineAgentLaunchAuthorization()
            guard projectManager.terminal
                    .pauseAuthorizedAgentLaunchesForTerminationDecision(
                        authorization
                    ) else {
                await presentTerminationFailure()
                return false
            }
            heldAgentLaunchAuthorizations.append((
                projectManager.terminal,
                authorization
            ))
        }

        if requiresAttention {
            guard let response = await presentTerminationDecision(
                .applicationQuitSummary,
                title: Strings.applicationQuitSummaryTitle,
                message: Strings.applicationQuitSummaryMessage(
                    max(attentionItemCount, 1)
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
            quickTerminalAuthorization = preflightQuickTerminalAuthorization
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

                let prompt = TabCloseHelper.unsavedChangesPrompt(
                    fileNames: dirty.map(\.fileName)
                )
                guard let response = await presentTerminationDecision(
                    .unsavedChangesBulk,
                    preferredProject: projectManager,
                    title: prompt.messageText,
                    message: prompt.informativeText
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
                guard projectManager.terminal
                        .pauseAuthorizedAgentLaunchesForTerminationDecision(
                            launchAuthorization
                        ) else {
                    await presentTerminationFailure()
                    return false
                }
                heldAgentLaunchAuthorizations.append((
                    projectManager.terminal,
                    launchAuthorization
                ))
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

            let currentQuickTerminalAuthorization =
                TerminalTabCloseAuthorization.authorizing(
                    tabs: quickTerminalCoordinator.paneState.terminalTabs
                )
            quickTerminalAuthorization = currentQuickTerminalAuthorization
            if currentQuickTerminalAuthorization.requiresConfirmation {
                guard let response = await presentTerminationDecision(
                    .terminalActiveProcessWarning,
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
            quickTerminalAuthorization =
                TerminalTabCloseAuthorization.authorizing(
                    tabs: quickTerminalCoordinator.paneState.terminalTabs
                )
        }

        // Collect every Save-As destination before rebasing the duration.
        // These native panels are human decisions, not bounded machine work.
        var destinationURLs: [URL] = []
        var unplannedOpenURLs: [URL] = []
        var plannedDestinationsByTabID: [UUID: URL] = [:]
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
            destinationURLs = preparedSavePlans.values.flatMap(
                \.standardizedDestinationURLs
            )
            let plannedTabIDs = preparedSavePlans.values.reduce(
                into: Set<UUID>()
            ) { result, plan in
                result.formUnion(plan.plannedTabIDs)
            }
            unplannedOpenURLs = Array(Set(
                registry.openProjects.values.flatMap(\.allTabs).compactMap {
                    plannedTabIDs.contains($0.id)
                        ? nil
                        : $0.fileURL?.standardizedFileURL
                }
            ))
            for plan in preparedSavePlans.values {
                plannedDestinationsByTabID.merge(
                    plan.plannedDestinationURLsByTabID,
                    uniquingKeysWith: { current, _ in current }
                )
            }
        }

        // Capture one app-wide ownership fence only after every human choice.
        // Planned Save As backing transitions are the sole allowed inventory
        // mutation until Quit either commits or rolls back.
        let saveInventoryAuthorization = registry
            .captureApplicationTerminationSaveInventory(
                allowingSaveAs: plannedDestinationsByTabID
            )

        // Rebase the captured duration only after the final human response.
        let terminationDeadline = DispatchTime.now() + .nanoseconds(
            Int(clamping: workBudgetNanoseconds)
        )

        let saveAliasURLs = destinationURLs + unplannedOpenURLs
        var saveAliasAuthorization: [TerminationFileAliasIdentity]?
        if saveAll == nil {
            let aliasResult = await terminationAliasCapture(
                saveAliasURLs,
                terminationDeadline
            )
            guard registry.applicationTerminationSaveInventoryStillMatches(
                saveInventoryAuthorization
            ) else {
                await presentTerminationFailure()
                return false
            }
            switch aliasResult {
            case .captured(let identities):
                saveAliasAuthorization = identities
                let destinationIdentities = Array(
                    identities.prefix(destinationURLs.count)
                )
                let openIdentities = Set(
                    identities.dropFirst(destinationURLs.count)
                )
                guard destinationIdentities.count == destinationURLs.count,
                      Set(destinationIdentities).count
                        == destinationIdentities.count,
                      destinationIdentities.allSatisfy({
                          !openIdentities.contains($0)
                      }) else {
                    await presentTerminationFailure()
                    return false
                }
            case .failed:
                await presentTerminationFailure()
                return false
            case .timedOut:
                terminationDeadlineObserver()
                await presentTerminationFailure()
                return false
            }
        }

        func saveInventoryStillAuthorized() -> Bool {
            registry.applicationTerminationSaveInventoryStillMatches(
                saveInventoryAuthorization
            )
        }

        func cleanupPreparedTerminationSaves(
            excluding protectedArtifacts: [URL] = []
        ) async -> [URL] {
            var retainedArtifacts: [URL] = []
            for (identifier, plan) in preparedTerminationSavePlans {
                guard let projectManager = projects.first(where: {
                    ObjectIdentifier($0) == identifier
                }) else { continue }
                let result = await projectManager.cleanupTerminationSavePlan(
                    plan,
                    excluding: protectedArtifacts,
                    until: terminationDeadline
                )
                if case .failed(let message, let retained) = result {
                    Logger.app.error(
                        "Termination save cleanup failed: \(message, privacy: .public)"
                    )
                    retainedArtifacts.append(contentsOf: retained)
                }
            }
            preparedTerminationSavePlans.removeAll()
            return Array(Set(retainedArtifacts)).sorted {
                $0.path < $1.path
            }
        }

        func presentSaveFailure(
            preferredProject: ProjectManager? = nil,
            internalMessage: String? = nil,
            retainedArtifacts additionalRetainedArtifacts: [URL] = []
        ) async {
            if let internalMessage {
                Logger.app.error(
                    "Termination save failed: \(internalMessage, privacy: .public)"
                )
            }
            let cleanedRetainedArtifacts =
                await cleanupPreparedTerminationSaves(
                    excluding: additionalRetainedArtifacts
                )
            let retainedArtifacts = Array(Set(
                additionalRetainedArtifacts + cleanedRetainedArtifacts
            )).sorted { $0.path < $1.path }
            let retainedPaths = retainedArtifacts.map(\.path).joined(
                separator: "\n"
            )
            let message = retainedPaths.isEmpty
                ? Strings.applicationQuitFailureMessage
                : Strings.applicationQuitFailureMessage
                    + "\n\n"
                    + retainedPaths
            await presentTerminationFailure(
                .fileOperationErrorCritical,
                preferredProject: preferredProject,
                title: Strings.fileOperationErrorTitle,
                message: message
            )
        }

        if let saveAll {
            for projectManager in saveRequests {
                guard saveInventoryStillAuthorized() else {
                    await presentTerminationFailure()
                    return false
                }
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
                guard saveInventoryStillAuthorized(),
                      saveResult == .saved else {
                    await presentTerminationFailure()
                    return false
                }
            }
        } else {
            for projectManager in saveRequests {
                guard saveInventoryStillAuthorized(),
                      let plan = preparedSavePlans[
                    ObjectIdentifier(projectManager)
                ] else {
                    await presentSaveFailure(
                        preferredProject: projectManager
                    )
                    return false
                }
                let (stageResult, stagedPlan) = await projectManager
                    .stagePreparedSaveAllPaneTabsForTermination(
                        plan,
                        until: terminationDeadline
                    )
                guard saveInventoryStillAuthorized() else {
                    await presentSaveFailure(
                        preferredProject: projectManager
                    )
                    return false
                }
                switch stageResult {
                case .ready:
                    guard let stagedPlan else {
                        await presentSaveFailure(
                            preferredProject: projectManager
                        )
                        return false
                    }
                    preparedTerminationSavePlans[
                        ObjectIdentifier(projectManager)
                    ] = stagedPlan
                case .failed(let message, let retainedArtifacts):
                    await presentSaveFailure(
                        preferredProject: projectManager,
                        internalMessage: message,
                        retainedArtifacts: retainedArtifacts
                    )
                    return false
                case .invalidated:
                    await presentSaveFailure(
                        preferredProject: projectManager
                    )
                    return false
                case .timedOut:
                    terminationDeadlineObserver()
                    await presentSaveFailure(
                        preferredProject: projectManager
                    )
                    return false
                }
            }

            // Staging can suspend long enough for a previously missing target
            // parent to be replaced by a symlink. Re-capture the complete
            // app-wide alias vector before the first install; from this point
            // every staged plan pins its exact parent directory inode.
            guard let saveAliasAuthorization else {
                await presentSaveFailure()
                return false
            }
            let currentAliases = await terminationAliasCapture(
                saveAliasURLs,
                terminationDeadline
            )
            guard saveInventoryStillAuthorized() else {
                await presentSaveFailure()
                return false
            }
            switch currentAliases {
            case .captured(let identities):
                guard identities == saveAliasAuthorization else {
                    await presentSaveFailure()
                    return false
                }
            case .failed:
                await presentSaveFailure()
                return false
            case .timedOut:
                terminationDeadlineObserver()
                await presentSaveFailure()
                return false
            }

            // Validate every target before the first destructive install. The
            // atomic installer repeats the check and quarantines the exact
            // authorized inode before a RENAME_EXCL install, closing the
            // remaining pathname race without displacing a replacement.
            for projectManager in saveRequests {
                guard saveInventoryStillAuthorized(),
                      let plan = preparedTerminationSavePlans[
                    ObjectIdentifier(projectManager)
                ] else {
                    await presentSaveFailure(
                        preferredProject: projectManager
                    )
                    return false
                }
                let destinationsStillMatch = await projectManager
                    .terminationSaveDestinationsStillMatch(
                        plan,
                        until: terminationDeadline
                    )
                guard saveInventoryStillAuthorized(),
                      destinationsStillMatch else {
                    await presentSaveFailure(
                        preferredProject: projectManager
                    )
                    return false
                }
            }

            for projectManager in saveRequests {
                guard saveInventoryStillAuthorized(),
                      let plan = preparedTerminationSavePlans[
                    ObjectIdentifier(projectManager)
                ] else {
                    await presentSaveFailure(
                        preferredProject: projectManager
                    )
                    return false
                }
                let commitResult = await projectManager
                    .commitStagedSaveAllPaneTabsForTermination(
                        plan,
                        until: terminationDeadline,
                        inventoryStillAuthorized:
                            saveInventoryStillAuthorized
                    )
                // ProjectManager owns cleanup/reconciliation once commit
                // starts. Do not retry one-shot cleanup through obsolete
                // staging paths in the app-level failure presenter.
                preparedTerminationSavePlans.removeValue(
                    forKey: ObjectIdentifier(projectManager)
                )
                switch commitResult {
                case .saved:
                    guard saveInventoryStillAuthorized() else {
                        await presentSaveFailure(
                            preferredProject: projectManager
                        )
                        return false
                    }
                case .failed(let message, let retainedArtifacts):
                    await presentSaveFailure(
                        preferredProject: projectManager,
                        internalMessage: message,
                        retainedArtifacts: retainedArtifacts
                    )
                    return false
                case .invalidated:
                    await presentSaveFailure(
                        preferredProject: projectManager
                    )
                    return false
                case .timedOut:
                    terminationDeadlineObserver()
                    await presentSaveFailure(
                        preferredProject: projectManager
                    )
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
        quickTerminalCoordinator.freezeAgentTasksForTermination()
        registry.agentTasks.prepareForApplicationTermination()
        func rollbackAgentTasks() async {
            let rollbackWasSaved = await registry.cancelAgentTaskTermination(
                until: terminationDeadline
            )
            quickTerminalCoordinator.cancelAgentTaskTermination()
            guard rollbackWasSaved else {
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

        // A preflight-covered PTY write may acknowledge while the first save
        // is in flight. Wait for every such write, then flush again so a late
        // `acknowledgedBeforeVerification` marker (or a failed-write deletion)
        // is durably newer than that first snapshot.
        for projectManager in projects {
            let identifier = ObjectIdentifier(projectManager)
            guard let authorization = agentLaunchAuthorizations[identifier]
            else { continue }
            guard await projectManager.terminal
                    .waitForAuthorizedAgentLaunchSettlement(
                        authorization,
                        until: forwardDeadline
                    ) else {
                await rollbackAgentTasks()
                await presentTerminationFailure()
                return false
            }
        }
        guard let postSettlementPersistenceBudget =
                remainingTerminationDuration(until: forwardDeadline),
              await registry.agentTasks.flushPersistence(
                  maximumDuration: postSettlementPersistenceBudget
              ) == .saved else {
            Logger.app.error(
                "Post-settlement agent task metadata did not reach a clean persistence barrier"
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
                let currentLaunchAuthorization = projectManager.terminal
                    .capturePineAgentLaunchAuthorization()
                guard authorization.stillCovers(
                    projectManager.terminal.allTerminalTabs,
                    pineAgentLaunches: agentLaunchAuthorizations[identifier],
                    currentPineAgentLaunches: currentLaunchAuthorization
                ) else {
                    Logger.app.error(
                        "Quit aborted: terminal authorization no longer covers the project"
                    )
                    return false
                }
                guard let launchAuthorization =
                        agentLaunchAuthorizations[identifier],
                      launchAuthorization.stillCovers(
                          currentLaunchAuthorization
                      ) else {
                    Logger.app.error(
                        "Quit aborted: Pine agent-launch authorization no longer covers the project"
                    )
                    return false
                }
            }
            guard let quickTerminalAuthorization,
                  quickTerminalAuthorization.stillCovers(
                      quickTerminalCoordinator.paneState.terminalTabs
                  ) else {
                Logger.app.error(
                    "Quit aborted: Quick Terminal authorization no longer covers its running processes"
                )
                return false
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

        // A real application exit destroys the queues that perform terminal
        // process-tree cleanup. Request every authorized stop now and wait
        // off-main under the shared forward deadline, before the synchronous
        // discard/task commit makes Quit irreversible. Cancelled and
        // save-failed Quit paths return before this point, preserving dirty
        // buffers and live terminals.
        var terminalStopControllers: [TerminalProcessTreeController] = []
        var terminalStopTabs: [TerminalTab] = []
        func rollbackAfterRequestedTerminalStops() async {
            await rollbackAgentTasks()
            terminalStopTabs.forEach {
                $0.reportDeferredApplicationTerminationLifecycleEnd()
            }
            guard let remaining = remainingTerminationDuration(
                until: terminationDeadline
            ), await registry.agentTasks.flushPersistence(
                maximumDuration: remaining
            ) == .saved else {
                Logger.app.error(
                    "Terminal-stop rollback did not reach a clean persistence barrier"
                )
                return
            }
        }
        for projectManager in registry.openProjects.values {
            let identifier = ObjectIdentifier(projectManager)
            let tabs = projectManager.terminal.allTerminalTabs
            let authorization: TerminalTabCloseAuthorization
            if let captured = terminalAuthorizations[identifier] {
                authorization = captured
            } else {
                let current = TerminalTabCloseAuthorization.authorizing(
                    tabs: tabs
                )
                guard !current.requiresConfirmation else {
                    await rollbackAfterRequestedTerminalStops()
                    await presentTerminationFailure()
                    return false
                }
                authorization = current
            }
            let capturedLaunches = agentLaunchAuthorizations[identifier]
            let currentLaunches = projectManager.terminal
                .capturePineAgentLaunchAuthorization()
            terminalStopTabs.append(contentsOf: tabs)
            guard let controllers = authorization.requestAuthorizedStops(
                tabs,
                pineAgentLaunches: capturedLaunches,
                currentPineAgentLaunches: currentLaunches
            ) else {
                await rollbackAfterRequestedTerminalStops()
                await presentTerminationFailure()
                return false
            }
            terminalStopControllers.append(contentsOf: controllers)
        }
        terminalStopTabs.append(
            contentsOf: quickTerminalCoordinator.paneState.terminalTabs
        )
        guard let quickTerminalAuthorization,
              let quickTerminalControllers = quickTerminalAuthorization
                .requestAuthorizedStops(
                    quickTerminalCoordinator.paneState.terminalTabs
                ) else {
            await rollbackAfterRequestedTerminalStops()
            await presentTerminationFailure()
            return false
        }
        terminalStopControllers.append(
            contentsOf: quickTerminalControllers
        )
        guard await TerminalTabCloseAuthorization.waitForAuthorizedStops(
            terminalStopControllers,
            until: forwardDeadline
        ) else {
            await rollbackAfterRequestedTerminalStops()
            await presentTerminationFailure()
            return false
        }

        // The waits above suspend the main actor. Reject any process/tab/task
        // generation that appeared before the final synchronous commit.
        guard destructiveAuthorizationsStillCoverCurrentState() else {
            await rollbackAfterRequestedTerminalStops()
            await presentTerminationFailure()
            return false
        }

        // Two-phase destructive commit: no project is mutated until every
        // project/terminal/task and editor authorization above passes.
        for projectManager in registry.openProjects.values {
            let identifier = ObjectIdentifier(projectManager)
            if let authorization = discardAuthorizations[identifier],
               !projectManager.canCommitDiscard(authorization) {
                await rollbackAfterRequestedTerminalStops()
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
                await rollbackAfterRequestedTerminalStops()
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
            await rollbackAfterRequestedTerminalStops()
            await presentTerminationFailure()
            return false
        }

        terminationCommitted = true
        return true
    }
}
