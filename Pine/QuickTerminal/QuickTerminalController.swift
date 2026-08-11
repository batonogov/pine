//
//  QuickTerminalController.swift
//  Pine
//
//  Owns the single global quick-terminal session: a keep-alive
//  `QuickTerminalWindow` hosting one `TerminalTab` inside a
//  `TerminalContainerView`. Toggled by a system-wide hotkey (#1113).
//
//  The session reuses the in-window terminal stack (`TerminalPaneState` +
//  `TerminalTab` + `TerminalContainerView`), so agent detection (#950),
//  file:line links (#949), and search (#308) work identically.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class QuickTerminalController {
    /// Per-pane state reused as the quick terminal's tab container. Holds
    /// exactly one `TerminalTab` for the quick-terminal session.
    let paneState: TerminalPaneState

    /// `true` while the quick-terminal window is on screen.
    private(set) var isVisible = false

    /// Project registry used to resolve the working directory (frontmost
    /// open project → recent project → home). Weakly held; the registry
    /// outlives the coordinator (owned by AppDelegate).
    weak var registry: ProjectRegistry?

    /// User-facing preferences (hotkey, geometry, display). Read live so
    /// the panel tracks the current edge / size / display on every show.
    let settings: QuickTerminalSettings

    private var window: QuickTerminalWindow?
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

    init(
        settings: QuickTerminalSettings = .shared,
        themeSettings: TerminalThemeSettings = .shared,
        cursorSettings: TerminalCursorSettings = .shared
    ) {
        self.settings = settings
        self.paneState = TerminalPaneState(
            themeSettings: themeSettings,
            cursorSettings: cursorSettings
        )
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
        guard settings.enabled else {
            hide()
            return
        }
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
        for tab in paneState.terminalTabs { tab.stop() }
        if let windowResignObserver {
            windowNotificationCenter.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        window?.close()
        window = nil
        isVisible = false
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
            paneState.addTab(workingDirectory: resolveCwd())
        }

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

        // Host the same NSView the in-window terminal panes use. Setting it
        // as contentView triggers `viewDidMoveToWindow` → observer install +
        // `layout()` → `showTab(activeTab)` → `startIfNeeded()`.
        let container = TerminalContainerView(frame: rect)
        container.bind(to: paneState)
        win.contentView = container
        // Explicit `showTab` matches the in-window pattern
        // (`TerminalContentView.updateNSView`) and makes the PTY-spawn path
        // robust against future changes to `TerminalContainerView.layout()`'s
        // contract — `layout()`'s else-branch already calls `showTab`, but
        // only when the container has real bounds on that specific pass.
        container.showTab(paneState.activeTab)

        window = win
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
    private func resolveCwd() -> URL? {
        // 1. The key window's project root — the project the user is
        //    currently working in. Resolved via the window delegate that
        //    Pine installs on every project window (CloseDelegate).
        if let keyProject = keyWindowProjectRoot() {
            return keyProject
        }
        // 2. Fall back to the most-recent project.
        if let recent = registry?.recentProjects.first {
            return recent
        }
        // 3. Last resort: home directory.
        return URL(fileURLWithPath: NSHomeDirectory())
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
