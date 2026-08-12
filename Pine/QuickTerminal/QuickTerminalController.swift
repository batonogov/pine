//
//  QuickTerminalController.swift
//  Pine
//
//  Owns the single global quick-terminal session: a keep-alive
//  `QuickTerminalWindow` hosting one `TerminalTab`. Toggled by a
//  system-wide hotkey (#1113).
//
//  The session reuses the in-window terminal stack and consumes the shared
//  process snapshots used by project terminals, while retaining a distinct
//  routing surface and keep-alive lifecycle.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class QuickTerminalController {
    private struct AgentScope {
        let project: AgentTaskProjectIdentity
        let surface: AgentTaskTerminalSurface
    }

    /// Per-pane state reused as the quick terminal's tab container. Holds
    /// exactly one `TerminalTab` for the quick-terminal session.
    let paneState: TerminalPaneState

    /// `true` while the quick-terminal window is on screen.
    private(set) var isVisible = false

    /// Project registry used to resolve the working directory (frontmost
    /// open project → recent project → home). Weakly held; the registry
    /// outlives the coordinator (owned by AppDelegate).
    weak var registry: ProjectRegistry? {
        didSet {
            guard registry !== oldValue else { return }
            if isAgentDetectionSubscribed {
                oldValue?.unsubscribeQuickTerminalAgentSnapshots(
                    agentDetection
                )
                isAgentDetectionSubscribed = false
            }
            if agentScope == nil, let agentScopeTarget {
                cancelAgentScopeResolution()
                beginAgentScopeResolution(agentScopeTarget)
            } else {
                startAgentDetectionIfNeeded()
            }
        }
    }

    /// User-facing preferences (hotkey, geometry, display). Read live so
    /// the panel tracks the current edge / size / display on every show.
    let settings: QuickTerminalSettings

    private var window: QuickTerminalWindow?
    private let agentRouteOwnerID = UUID()
    private let agentDetection: QuickTerminalAgentDetection
    private var agentScope: AgentScope?
    private var agentScopeTarget: (
        workingDirectory: URL,
        surface: AgentTaskTerminalSurface
    )?
    private var agentScopeResolutionTask: Task<Void, Never>?
    private var agentScopeResolutionGeneration: UInt64 = 0
    private let agentScopeResolver: @MainActor (
        ProjectRegistry,
        URL,
        AgentTaskTerminalSurface
    ) async -> QuickTerminalAgentScopeRegistration?
    private var isAgentDetectionSubscribed = false
    private var areAgentTaskCallbacksFrozen = false
    private var isPermanentlyShutDown = false
    /// See `TerminalTab.themeChangeObserver`: the observer token is created
    /// on the main actor and only removed from nonisolated `deinit`.
    @ObservationIgnored
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored
    nonisolated(unsafe) private var windowResignObserver: NSObjectProtocol?
    private let settingsNotificationCenter: NotificationCenter
    private let windowNotificationCenter = NotificationCenter.default

    /// Read-only seam for geometry integration tests. Production callers use
    /// `show`/`hide`; exposing the frame avoids reaching into the NSPanel.
    var presentedFrame: NSRect? { window?.frame }

    /// Injection seam for the application-level process snapshot source. This
    /// controller never owns a timer or invokes `ps` itself (#1421 boundary).
    var agentSnapshotConsumer: any AgentProcessSnapshotConsuming {
        agentDetection
    }

    var agentDetector: AgentDetector { agentDetection.detector }

    var agentTerminalTabs: [TerminalTab] { paneState.terminalTabs }

    #if DEBUG
    var isAgentDetectionSubscribedForTesting: Bool {
        isAgentDetectionSubscribed
    }

    var receivedAgentSnapshotCountForTesting: Int {
        agentDetection.receivedSnapshotCountForTesting
    }

    var isAgentScopeReadyForTesting: Bool { agentScope != nil }

    var agentScopeSurfaceForTesting: AgentTaskTerminalSurface? {
        agentScope?.surface
    }

    func waitForAgentScopeResolutionForTesting() async {
        await agentScopeResolutionTask?.value
    }
    #endif

    init(
        settings: QuickTerminalSettings = .shared,
        themeSettings: TerminalThemeSettings = .shared,
        cursorSettings: TerminalCursorSettings = .shared,
        agentScopeResolver: @escaping @MainActor (
            ProjectRegistry,
            URL,
            AgentTaskTerminalSurface
        ) async -> QuickTerminalAgentScopeRegistration? = { registry, workingDirectory, surface in
            await registry.resolveQuickTerminalAgentScope(
                workingDirectory: workingDirectory,
                surface: surface
            )
        }
    ) {
        self.settings = settings
        self.paneState = TerminalPaneState(
            themeSettings: themeSettings,
            cursorSettings: cursorSettings
        )
        self.agentDetection = QuickTerminalAgentDetection()
        self.agentScopeResolver = agentScopeResolver
        self.settingsNotificationCenter = settings.notificationCenter
        self.settingsObserver = settings.notificationCenter.addObserver(
            forName: QuickTerminalSettings.didChangeNotification,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettingsChange()
            }
        }
        self.agentDetection.bind(controller: self)
        self.paneState.onTabCreated = { [weak self] tab in
            self?.configureAgentLifecycle(for: tab)
            tab.configureWorkingDirectoryValidation { [weak self] directory in
                guard let self else { return false }
                return await self.validateWorkingDirectoryForProcessStart(
                    directory
                )
            }
        }
    }

    deinit {
        if let settingsObserver {
            settingsNotificationCenter.removeObserver(settingsObserver)
        }
        if let windowResignObserver {
            windowNotificationCenter.removeObserver(windowResignObserver)
        }
    }

    // MARK: - Public

    /// Shows the quick terminal if hidden, hides it if visible. Bound to the
    /// global hotkey and the menu command.
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !isPermanentlyShutDown else { return }
        guard settings.enabled else {
            hide()
            return
        }
        presentKeepAliveWindow()
    }

    private func presentKeepAliveWindow() {
        guard !isPermanentlyShutDown else { return }
        ensureWindow()
        repositionDropDown()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    /// Applies settings to an already-visible panel without recreating its
    /// terminal view or process. Hiding on disable and frame updates therefore
    /// preserve the keep-alive session and its scrollback.
    private func applySettingsChange() {
        guard settings.enabled else {
            hide()
            return
        }
        guard isVisible else { return }
        repositionDropDown()
    }

    /// Applies the focus-loss policy after AppKit has completed the key-window
    /// transition. Kept internal so the policy can be verified without asking
    /// a unit test to steal focus from the developer's active application.
    func handleWindowDidResignKey() {
        guard isVisible, settings.hideOnFocusLoss else { return }
        hide()
    }

    /// Stops the terminal session and closes the window. Called at app
    /// termination so the PTY child does not outlive Pine, matching
    /// `registry.destroyAllProjects()` for project windows (#1113 review).
    func shutdown() {
        guard !isPermanentlyShutDown else { return }
        isPermanentlyShutDown = true
        cancelAgentScopeResolution()
        unsubscribeAgentDetection()
        agentDetection.stop()
        for tab in paneState.terminalTabs { tab.stop() }
        if let windowResignObserver {
            windowNotificationCenter.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        window?.close()
        window = nil
        isVisible = false
    }

    /// Freezes injected detector callbacks before the durable application-quit
    /// snapshot. Hide/show deliberately never calls this method.
    func freezeAgentTasksForTermination() {
        guard !areAgentTaskCallbacksFrozen,
              !isPermanentlyShutDown else { return }
        areAgentTaskCallbacksFrozen = true
        if agentScope == nil {
            cancelAgentScopeResolution()
        }
        agentDetection.freezeForTermination()
        unsubscribeAgentDetection()
    }

    /// Restores snapshot consumption after the user cancels Quit.
    func cancelAgentTaskTermination() {
        guard areAgentTaskCallbacksFrozen,
              !isPermanentlyShutDown else { return }
        areAgentTaskCallbacksFrozen = false
        agentDetection.cancelTermination()
        if agentScope == nil, let agentScopeTarget {
            beginAgentScopeResolution(agentScopeTarget)
        } else {
            startAgentDetectionIfNeeded()
        }
    }

    // MARK: - Window lifecycle

    /// Lazily creates the keep-alive window and its terminal session. Called
    /// on the first `show()`; subsequent shows reuse the same window + shell
    /// (scrollback survives between toggles).
    private func ensureWindow() {
        guard window == nil else { return }

        // Seed the terminal tab if this is the first show. The tab starts its
        // PTY lazily from `TerminalContainerView.layout()` once the view has
        // real bounds (issue #661 guard).
        if paneState.terminalTabs.isEmpty {
            let target = resolveSessionTarget()
            agentScopeTarget = target
            paneState.addTab(workingDirectory: target.workingDirectory)
            beginAgentScopeResolution(target)
        }
        startAgentDetectionIfNeeded()

        let rect = dropDownRect()
        let win = QuickTerminalWindow(contentRect: rect)
        win.onHide = { [weak self] in self?.hide() }
        windowResignObserver = windowNotificationCenter.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWindowDidResignKey()
            }
        }

        // Host the shared terminal content below the same truthful agent badge
        // used by project terminal tabs. The NSViewRepresentable still starts
        // the PTY lazily after it receives real window bounds.
        win.contentView = NSHostingView(
            rootView: QuickTerminalContentView(paneState: paneState)
        )

        window = win
    }

    private func startAgentDetectionIfNeeded() {
        guard !isAgentDetectionSubscribed,
              !areAgentTaskCallbacksFrozen,
              !isPermanentlyShutDown,
              agentScope != nil,
              !paneState.terminalTabs.isEmpty,
              let registry else { return }
        isAgentDetectionSubscribed = registry
            .subscribeQuickTerminalAgentSnapshots(agentDetection)
    }

    private func unsubscribeAgentDetection() {
        guard isAgentDetectionSubscribed else { return }
        registry?.unsubscribeQuickTerminalAgentSnapshots(agentDetection)
        isAgentDetectionSubscribed = false
    }

    /// Recomputes the drop-down frame against the current screen so the
    /// panel tracks display changes (retina ↔ external, resolution change).
    private func repositionDropDown() {
        guard let window else { return }
        window.setFrame(dropDownRect(), display: true)
    }

    /// Resolves which `NSScreen` the panel should appear on, honoring the
    /// `targetDisplay` preference. AppKit defines `NSScreen.main` as the
    /// keyboard-focus screen; the menu-bar display is `NSScreen.screens[0]`.
    private func targetScreen() -> NSScreen? {
        Self.resolveTargetScreen(
            target: settings.targetDisplay,
            keyWindowScreen: NSApp.keyWindow?.screen,
            focusedScreen: NSScreen.main,
            primaryScreen: NSScreen.screens.first
        )
    }

    /// Pure selection seam so display semantics can be tested without relying
    /// on the test host's physical monitor configuration.
    static func resolveTargetScreen<Screen>(
        target: QuickTerminalTargetDisplay,
        keyWindowScreen: Screen?,
        focusedScreen: Screen?,
        primaryScreen: Screen?
    ) -> Screen? {
        switch target {
        case .main:
            primaryScreen ?? focusedScreen ?? keyWindowScreen
        case .active:
            keyWindowScreen ?? focusedScreen ?? primaryScreen
        }
    }

    /// Panel frame derived from the selected screen, edge, and size fraction.
    private func dropDownRect() -> NSRect {
        let screen = targetScreen()
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 600)
        let fraction = CGFloat(settings.heightFraction)

        switch settings.screenEdge {
        case .top:
            let height = (screenFrame.height * fraction).rounded()
            return NSRect(
                x: screenFrame.minX,
                y: screenFrame.maxY - height,
                width: screenFrame.width,
                height: height
            )
        case .bottom:
            let height = (screenFrame.height * fraction).rounded()
            return NSRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: screenFrame.width,
                height: height
            )
        case .left:
            let width = (screenFrame.width * fraction).rounded()
            return NSRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: width,
                height: screenFrame.height
            )
        case .right:
            let width = (screenFrame.width * fraction).rounded()
            return NSRect(
                x: screenFrame.maxX - width,
                y: screenFrame.minY,
                width: width,
                height: screenFrame.height
            )
        }
    }

    /// Working directory for the quick terminal: the root of the **key
    /// window's** open Pine project, else the most-recent project, else
    /// `$HOME`.
    ///
    /// Resolving via the key window (rather than `openProjects.keys.first`,
    /// whose order is unspecified) means the quick terminal opens in the
    /// project the user is actually looking at, not an arbitrary one.
    private func resolveSessionTarget() -> (
        workingDirectory: URL,
        surface: AgentTaskTerminalSurface
    ) {
        // 1. The key window's project root — the project the user is
        //    currently working in. Resolved via the window delegate that
        //    Pine installs on every project window (CloseDelegate).
        if let keyProject = keyWindowProjectRoot() {
            return (keyProject, .quickTerminalProject)
        }
        // 2. Fall back to the most-recent project.
        if let recent = registry?.recentProjects.first {
            return (recent, .quickTerminalProject)
        }
        // 3. Last resort: home directory.
        return (
            URL(fileURLWithPath: NSHomeDirectory()),
            .quickTerminalStandalone
        )
    }

    private func beginAgentScopeResolution(
        _ target: (
            workingDirectory: URL,
            surface: AgentTaskTerminalSurface
        )
    ) {
        guard agentScope == nil,
              agentScopeResolutionTask == nil,
              !areAgentTaskCallbacksFrozen,
              !isPermanentlyShutDown,
              let registry else { return }
        agentScopeResolutionGeneration &+= 1
        let generation = agentScopeResolutionGeneration
        let resolver = agentScopeResolver
        agentScopeResolutionTask = Task { @MainActor [weak self, weak registry] in
            guard let registry else { return }
            let registration = await resolver(
                registry,
                target.workingDirectory,
                target.surface
            )
            guard let self,
                  generation == self.agentScopeResolutionGeneration else {
                return
            }
            defer {
                if generation == self.agentScopeResolutionGeneration {
                    self.agentScopeResolutionTask = nil
                }
            }
            guard !Task.isCancelled,
                  !self.areAgentTaskCallbacksFrozen,
                  !self.isPermanentlyShutDown,
                  self.registry === registry,
                  self.agentScopeTarget?.workingDirectory
                    == target.workingDirectory,
                  self.agentScopeTarget?.surface == target.surface,
                  let registration else { return }
            guard await registry.commitQuickTerminalAgentScope(
                registration,
                workingDirectory: target.workingDirectory,
                requestedSurface: target.surface
            ), generation == self.agentScopeResolutionGeneration,
                !Task.isCancelled,
                !self.areAgentTaskCallbacksFrozen,
                !self.isPermanentlyShutDown,
                self.registry === registry,
                self.agentScopeTarget?.workingDirectory
                    == target.workingDirectory,
                self.agentScopeTarget?.surface == target.surface else {
                return
            }
            self.agentScope = AgentScope(
                project: registration.project,
                surface: registration.surface
            )
            self.startAgentDetectionIfNeeded()
        }
    }

    private func cancelAgentScopeResolution() {
        agentScopeResolutionGeneration &+= 1
        agentScopeResolutionTask?.cancel()
        agentScopeResolutionTask = nil
    }

    private func configureAgentLifecycle(for tab: TerminalTab) {
        tab.onLifecycleEnded = { [weak self] terminalID in
            guard let self, let agentScope else { return }
            registry?.agentTasks.markTerminalClosed(
                terminalID: terminalID,
                project: agentScope.project,
                surface: agentScope.surface
            )
        }
    }

    private func validateWorkingDirectoryForProcessStart(
        _ directory: URL
    ) async -> Bool {
        let resolution = agentScopeResolutionTask
        await resolution?.value
        guard !Task.isCancelled,
              !areAgentTaskCallbacksFrozen,
              !isPermanentlyShutDown,
              let registry,
              let agentScope,
              let target = agentScopeTarget,
              target.workingDirectory.standardizedFileURL
                == directory.standardizedFileURL else { return false }
        return await registry.validateQuickTerminalAgentScope(
            QuickTerminalAgentScopeRegistration(
                project: agentScope.project,
                surface: agentScope.surface
            ),
            workingDirectory: directory
        )
    }

    func bridgeQuickTerminalAgentSession(
        _ session: AgentSession,
        replacing previous: AgentSession?,
        in tab: TerminalTab
    ) {
        guard let registry,
              let agentScope,
              paneState.terminalTabs.contains(where: { $0 === tab }) else {
            return
        }
        registry.agentTasks.bridge(
            session,
            replacing: previous,
            context: AgentTaskBridgeContext(
                project: agentScope.project,
                route: AgentTaskRoute(
                    surface: agentScope.surface,
                    paneID: agentRouteOwnerID,
                    tabID: tab.id,
                    terminalID: tab.id
                ),
                presentationContext: AgentTaskPresentationContext(
                    terminalStableLabel: Strings.quickTerminalText()
                ),
                origin: .discoveredInTerminal
            )
        )
    }

    func refreshQuickTerminalAgentTasks(sessions: [AgentSession]) {
        registry?.agentTasks.refresh(sessions: sessions)
    }

    func markQuickTerminalAgentEvidenceUnavailable(sessionIDs: [UUID]) {
        registry?.agentTasks.markEvidenceUnavailable(sessionIDs: sessionIDs)
    }

    /// Returns the project root URL associated with the current key window,
    /// if any. Walks the window's delegate (Pine's `CloseDelegate`) to find
    /// the `projectURL`, then confirms it is still in the open-projects map.
    private func keyWindowProjectRoot() -> URL? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        // Pine's project windows carry their project URL on the delegate.
        let candidate: URL?
        if let closeDelegate = keyWindow.delegate as? CloseDelegate {
            candidate = closeDelegate.projectURL
        } else {
            candidate = nil
        }
        guard let url = candidate,
              let registry else { return nil }
        // Only return it if the project is actually open (not just a stale
        // delegate reference on a closing window). Canonicalize so the key
        // matches what was stored (trailing slash + symlink resolution).
        let canonical = registry.canonicalProjectURL(url)
        guard registry.openProjects[canonical] != nil else { return nil }
        return url
    }
}

extension QuickTerminalController: QuickTerminalAgentRouting {
    func resolveQuickTerminalAgentRoute(
        for task: AgentTask
    ) -> AgentTaskRoute? {
        guard task.route.surface.isQuickTerminal,
              let registry,
              let agentScope,
              task.project == agentScope.project,
              task.route.surface == agentScope.surface,
              task.route.paneID == agentRouteOwnerID,
              task.route.tabID == task.route.terminalID,
              let tab = paneState.terminalTabs.first(where: {
                $0.id == task.route.terminalID
              }),
              let session = tab.agentSession,
              let run = task.runs.last,
              task.lifecycle == .active,
              task.route.availability == .available,
              run.id == session.id,
              run.terminalID == tab.id,
              run.liveness == .live,
              run.endedAt == nil,
              session.liveness == .live,
              session.agentType == task.descriptor.agentType,
              let evidence = session.processEvidence,
              run.process.identifiesSameProcess(as: evidence),
              registry.agentTasks.isExactLiveOwner(
                taskID: task.id,
                terminalID: tab.id,
                runID: session.id
              ) else {
            return nil
        }
        return task.route
    }

    func revealQuickTerminalAgentRoute(
        for task: AgentTask
    ) -> AgentTaskRoute? {
        guard let route = resolveQuickTerminalAgentRoute(for: task) else {
            return nil
        }
        // An explicit Inbox/notification action remains able to reveal a live
        // keep-alive process even when the global hotkey preference is off.
        presentKeepAliveWindow()
        guard resolveQuickTerminalAgentRoute(for: task) == route else {
            return nil
        }
        return route
    }

    func isQuickTerminalAgentTaskPresented(_ task: AgentTask) -> Bool {
        isVisible
            && window?.isVisible == true
            && window?.isKeyWindow == true
            && resolveQuickTerminalAgentRoute(for: task) != nil
    }
}
