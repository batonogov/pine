//
//  TerminalSession.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI
import SwiftTerm

// MARK: - Click interceptor overlay for terminal focus management

/// Transparent overlay NSView placed on top of `LocalProcessTerminalView`.
///
/// This overlay forwards mouse clicks to the terminal view and ensures
/// the terminal becomes first responder when clicked. It sits above the
/// terminal in the view hierarchy and wins the AppKit hit-test.
///
/// Scroll events are handled separately via `NSEvent.addLocalMonitorForEvents`
/// on `TerminalContainerView` because AppKit on macOS 26 does not dispatch
/// `scrollWheel` to overlay views — events go directly to SwiftTerm's view.
///
/// While the user drags a selection past the top/bottom edges, the
/// interceptor runs an auto-scroll timer that scrolls SwiftTerm's
/// scrollback and replays the last drag event so the selection keeps
/// extending — restoring the standard macOS `NSTextView` behaviour
/// missing from SwiftTerm 1.13.0 (issue #915).
class TerminalScrollInterceptor: NSView {

    /// The terminal view underneath this overlay.
    weak var terminalView: LocalProcessTerminalView?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return self
    }

    // MARK: - Auto-scroll-on-drag state

    private var autoScrollTimer: Timer?
    private var lastDragEvent: NSEvent?
    private var isMouseDown = false

    /// Global mouse-up monitor installed only while auto-scroll is active.
    ///
    /// AppKit only delivers `mouseUp` to a view when the press began inside
    /// it AND the release happens while the app is key. If the user drags
    /// past the window, releases over another app (Cmd+Tab, Mission Control,
    /// the menu bar), or releases over a different window, the local
    /// `mouseUp` override never fires and the auto-scroll timer would spin
    /// forever. A global monitor catches the release in those cases.
    private var globalMouseUpMonitor: Any?

    /// Window-resign-key observer installed only while auto-scroll is active.
    ///
    /// Belt-and-braces alongside `globalMouseUpMonitor`: if focus moves to
    /// another app (Mission Control, Spotlight, screen saver), the global
    /// monitor may not see the release at all. Losing key status is a
    /// reliable upper bound — there is nothing useful auto-scroll can do
    /// against an unfocused window.
    private var windowResignKeyObserver: NSObjectProtocol?

    /// Test hook: whether the auto-scroll timer is currently running.
    /// Internal so `@testable import Pine` can assert lifecycle correctness
    /// without coupling tests to private state.
    internal var isAutoScrollActive: Bool { autoScrollTimer != nil }

    #if DEBUG
    /// Test-only entry point that starts the auto-scroll timer (and the
    /// associated safety-net subscriptions) without requiring a real
    /// terminal view, NSEvent, or scrollback buffer. Tests use this to
    /// verify that the various stop paths (window resign key, global mouse
    /// up, active tab change, mouseUp, drag back into bounds) actually tear
    /// the timer down. Production code never calls this.
    internal func startAutoScrollForTesting() {
        isMouseDown = true
        if autoScrollTimer == nil {
            startAutoScrollTimer()
        }
    }
    #endif

    override func mouseDown(with event: NSEvent) {
        isMouseDown = true
        stopAutoScroll()
        if let tv = terminalView {
            window?.makeFirstResponder(tv)
            tv.mouseDown(with: event)
        }
    }
    override func mouseUp(with event: NSEvent) {
        isMouseDown = false
        stopAutoScroll()
        terminalView?.mouseUp(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        terminalView?.mouseDragged(with: event)
        updateAutoScroll(for: event)
    }
    override func mouseMoved(with event: NSEvent) { terminalView?.mouseMoved(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        if let tv = terminalView {
            window?.makeFirstResponder(tv)
            tv.rightMouseDown(with: event)
        }
    }
    override func rightMouseUp(with event: NSEvent) { terminalView?.rightMouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { terminalView?.otherMouseDown(with: event) }
    override func otherMouseUp(with event: NSEvent) { terminalView?.otherMouseUp(with: event) }
    override func keyDown(with event: NSEvent) { terminalView?.keyDown(with: event) }
    override func keyUp(with event: NSEvent) { terminalView?.keyUp(with: event) }
    override func flagsChanged(with event: NSEvent) { terminalView?.flagsChanged(with: event) }

    override var acceptsFirstResponder: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Window detach (tab close, app quit) — drop the timer so it cannot
        // fire against a dangling terminal view.
        if newWindow == nil {
            stopAutoScroll()
            isMouseDown = false
        }
    }

    /// Called when the active terminal tab changes, so an in-flight
    /// auto-scroll on the outgoing tab cannot keep ticking against the
    /// incoming tab's coordinates. Internal so the container view and
    /// tests can both invoke it deterministically.
    internal func handleActiveTabChange() {
        isMouseDown = false
        stopAutoScroll()
    }

    /// Test hook for the global mouse-up safety net. Calling this directly
    /// is equivalent to a `leftMouseUp` arriving while focus is elsewhere
    /// (Mission Control, Cmd+Tab, the menu bar, another app).
    internal func handleGlobalMouseUp() {
        isMouseDown = false
        stopAutoScroll()
    }

    /// Test hook for the window-resign-key safety net. Calling this directly
    /// is equivalent to the host window losing key status while a drag is
    /// in flight.
    internal func handleWindowResignKey() {
        isMouseDown = false
        stopAutoScroll()
    }

    // No `deinit` cleanup is required: `viewWillMove(toWindow: nil)` is the
    // last call AppKit makes before the view is torn down (tab close, app
    // quit), and we invalidate the timer there. Touching `autoScrollTimer`
    // from a nonisolated `deinit` would require unsafe Sendable hops; the
    // window-detach path is sufficient because the timer always retains
    // `self`, so this view cannot deallocate while the timer is alive.

    // MARK: - Auto-scroll-on-drag implementation

    /// Updates the auto-scroll timer in response to a `mouseDragged` event.
    ///
    /// - Stores the latest event for the next timer tick to replay.
    /// - Starts/keeps the timer running while the cursor is outside the
    ///   bounds AND the terminal can actually scroll in that direction.
    /// - Stops the timer the moment the cursor returns to the bounds, the
    ///   user enters the alternate screen / a TUI app with mouse reporting,
    ///   or the scrollback hits the corresponding edge.
    private func updateAutoScroll(for event: NSEvent) {
        lastDragEvent = event
        guard let terminalView, isMouseDown else {
            stopAutoScroll()
            return
        }

        // Disable for TUI apps / alternate screen — selection there is
        // app-driven and an auto-scroll would corrupt mouse reporting.
        let term = terminalView.getTerminal()
        if term.mouseMode != .off || term.isCurrentBufferAlternate {
            stopAutoScroll()
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let direction = TerminalAutoScroll.direction(forPoint: point, in: bounds) else {
            stopAutoScroll()
            return
        }

        // Already pinned to the edge of scrollback in this direction —
        // running a timer would just burn CPU. Bail out.
        if !canScroll(direction: direction, in: terminalView) {
            stopAutoScroll()
            return
        }

        if autoScrollTimer == nil {
            startAutoScrollTimer()
        }
    }

    private func startAutoScrollTimer() {
        let timer = Timer(
            timeInterval: TerminalAutoScroll.tickInterval,
            target: self,
            selector: #selector(autoScrollTick(_:)),
            userInfo: nil,
            repeats: true
        )
        // Common run-loop mode keeps the timer firing during mouse tracking
        // (default mode pauses while AppKit drives an event-tracking loop).
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
        installLostMouseUpSafetyNets()
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        removeLostMouseUpSafetyNets()
    }

    /// Installs the global mouse-up monitor and window-resign-key observer
    /// so the auto-scroll loop cannot leak past the end of the user's drag.
    /// Idempotent — repeated calls do not stack monitors.
    private func installLostMouseUpSafetyNets() {
        if globalMouseUpMonitor == nil {
            globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
                // `addGlobalMonitorForEvents` callbacks fire on the main
                // thread per AppKit docs; safe to mutate UI state directly.
                self?.handleGlobalMouseUp()
            }
        }
        if windowResignKeyObserver == nil, let win = window {
            windowResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                self?.handleWindowResignKey()
            }
        }
    }

    /// Removes both safety-net subscriptions if installed. Idempotent.
    private func removeLostMouseUpSafetyNets() {
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }
        if let observer = windowResignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowResignKeyObserver = nil
        }
    }

    @objc private func autoScrollTick(_ timer: Timer) {
        guard let terminalView, let event = lastDragEvent, isMouseDown else {
            stopAutoScroll()
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let direction = TerminalAutoScroll.direction(forPoint: point, in: bounds) else {
            stopAutoScroll()
            return
        }

        let term = terminalView.getTerminal()
        if term.mouseMode != .off || term.isCurrentBufferAlternate {
            stopAutoScroll()
            return
        }

        guard canScroll(direction: direction, in: terminalView) else {
            stopAutoScroll()
            return
        }

        let distance = TerminalAutoScroll.edgeDistance(forPoint: point, in: bounds)
        let lines = TerminalAutoScroll.linesPerTick(forDistance: distance)
        guard lines > 0 else { return }

        switch direction {
        case .up:
            terminalView.scrollUp(lines: lines)
        case .down:
            terminalView.scrollDown(lines: lines)
        }

        // Replay the last drag event so SwiftTerm's mouseDragged recomputes
        // the buffer row from the new yDisp and extends the selection to the
        // freshly revealed line. Without this, selection would clip at the
        // last buffer row computed before the scroll.
        terminalView.mouseDragged(with: event)
    }

    /// Whether SwiftTerm has any scrollback to consume in the given
    /// direction. Used to avoid spinning the timer for nothing once the
    /// user has dragged all the way to the top or bottom of the buffer.
    private func canScroll(direction: TerminalAutoScrollDirection,
                           in terminalView: LocalProcessTerminalView) -> Bool {
        guard terminalView.canScroll else { return false }
        switch direction {
        case .up:
            return terminalView.scrollPosition > 0
        case .down:
            return terminalView.scrollPosition < 1
        }
    }
}

// MARK: - NSViewRepresentable обёртка для SwiftTerm

/// Единый NSViewRepresentable для терминала.
/// Создаётся один раз и никогда не пересоздаётся SwiftUI.
/// Переключение терминальных табов происходит на уровне AppKit.
struct TerminalContentView: NSViewRepresentable {
    let terminalPaneState: TerminalPaneState

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.terminalPaneState = terminalPaneState
        container.showTab(terminalPaneState.activeTab)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.showTab(terminalPaneState.activeTab)
    }
}

/// Контейнер NSView, который управляет размером LocalProcessTerminalView.
/// SwiftTerm ожидает ручное управление frame (как в официальном примере),
/// а не Auto Layout constraints.
///
/// With internal editor tabs there is only one window,
/// so no multi-window reclaim logic is needed.
class TerminalContainerView: NSView {
    /// Default frame used when the container has zero bounds (e.g. before the first
    /// SwiftUI layout pass). Gives SwiftTerm a reasonable cols/rows so the terminal
    /// is not blank when it first appears. The real size replaces this in `layout()`.
    static let defaultTerminalFrame = NSRect(x: 0, y: 0, width: 800, height: 300)

    var terminalPaneState: TerminalPaneState?
    private var currentTabID: UUID?
    private let scrollInterceptor = TerminalScrollInterceptor()
    private var scrollMonitor: Any?
    private var accumulatedScrollDelta: CGFloat = 0

    func showTab(_ tab: TerminalTab?) {
        guard let tab else {
            // Tab cleared (terminal pane closed) — kill any in-flight
            // auto-scroll so it cannot tick against a now-detached view.
            scrollInterceptor.handleActiveTabChange()
            subviews.forEach { $0.removeFromSuperview() }
            currentTabID = nil
            scrollInterceptor.terminalView = nil
            return
        }
        let tabChanged = tab.id != currentTabID || tab.terminalView.superview !== self
        if tabChanged {
            // Auto-scroll started against the *outgoing* tab — stop it before
            // we swap the underlying terminalView so the next tick cannot
            // scroll the freshly-installed tab using stale coordinates.
            scrollInterceptor.handleActiveTabChange()
            subviews.forEach { $0.removeFromSuperview() }
            currentTabID = tab.id
            let effectiveBounds = bounds.size.width > 0 && bounds.size.height > 0
                ? bounds : Self.defaultTerminalFrame
            tab.terminalView.frame = effectiveBounds
            addSubview(tab.terminalView)

            // Place click interceptor on top of the terminal view
            scrollInterceptor.frame = effectiveBounds
            scrollInterceptor.terminalView = tab.terminalView
            addSubview(scrollInterceptor)

            tab.terminalView.needsLayout = true
            tab.terminalView.needsDisplay = true
        }

        installScrollMonitor()

        // Focus the terminal view when requested by TerminalPaneState
        if let pending = terminalPaneState?.pendingFocusTabID, pending == tab.id {
            terminalPaneState?.pendingFocusTabID = nil
            focusTerminalView(tab.terminalView)
        }
    }

    // MARK: - Scroll event monitor for TUI mouse reporting

    /// Installs a global-to-app scroll event monitor that intercepts scroll wheel
    /// events over the terminal view when a TUI app has enabled mouse reporting.
    ///
    /// This replaces the previous overlay-based `scrollWheel` approach which does
    /// not work on macOS 26 — AppKit dispatches scroll events directly to SwiftTerm's
    /// view, bypassing overlay hitTest entirely.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let paneState = self.terminalPaneState else { return event }
            guard let tab = paneState.activeTab else { return event }
            let terminalView = tab.terminalView

            // Only intercept if event is in our window and over the terminal
            guard event.window === self.window else { return event }
            let locationInSelf = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(locationInSelf) else { return event }

            // Use scrollingDeltaY for trackpad (precise), deltaY for mouse wheel
            let scrollDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            guard scrollDelta != 0 else { return event }

            let term = terminalView.getTerminal()

            if term.mouseMode != .off {
                // TUI mouse reporting active — encode as VT100 mouse button events
                let modifiers = event.modifierFlags
                let buttonFlags = MouseScrollForwarder.encodeScrollButton(
                    deltaY: scrollDelta,
                    shift: modifiers.contains(.shift),
                    option: modifiers.contains(.option),
                    control: modifiers.contains(.control)
                )

                let locationInTerminal = terminalView.convert(event.locationInWindow, from: nil)
                let pos = MouseScrollForwarder.gridPosition(
                    point: locationInTerminal,
                    viewBounds: terminalView.bounds,
                    cols: term.cols,
                    rows: term.rows,
                    isFlipped: terminalView.isFlipped
                )

                let velocity = MouseScrollForwarder.scrollVelocity(delta: scrollDelta)
                for _ in 0..<velocity {
                    term.sendEvent(buttonFlags: buttonFlags, x: pos.col, y: pos.row)
                }
                return nil
            }

            if term.isCurrentBufferAlternate {
                // Alternate screen (k9s, htop, vim, etc.) without mouse reporting —
                // convert scroll to arrow keys like Ghostty/WezTerm/iTerm2.
                // Accumulate trackpad deltas and emit 1 arrow key per threshold.
                let arrowKey: String = scrollDelta > 0 ? "\u{1b}OA" : "\u{1b}OB"
                if event.hasPreciseScrollingDeltas {
                    self.accumulatedScrollDelta += scrollDelta
                    // Reset accumulator on gesture start
                    if event.phase == .began {
                        self.accumulatedScrollDelta = scrollDelta
                    }
                    let threshold: CGFloat = 25
                    if abs(self.accumulatedScrollDelta) >= threshold {
                        term.sendResponse(text: arrowKey)
                        self.accumulatedScrollDelta = 0
                    }
                } else {
                    // Mouse wheel: 1 arrow key per tick
                    term.sendResponse(text: arrowKey)
                }
                return nil
            }

            // Normal mode — let SwiftTerm handle scrollback
            return event
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    override func removeFromSuperview() {
        removeScrollMonitor()
        super.removeFromSuperview()
    }

    /// Requests first responder on the terminal view.
    /// If the view is not yet in a window, defers the call via async dispatch.
    private func focusTerminalView(_ terminalView: LocalProcessTerminalView) {
        if let win = window {
            win.makeFirstResponder(terminalView)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(terminalView)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        guard let terminalPaneState, let tab = terminalPaneState.activeTab else { return }
        if tab.terminalView.superview === self {
            tab.terminalView.needsLayout = true
            tab.terminalView.needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        guard let terminalPaneState, let tab = terminalPaneState.activeTab else { return }
        // Do not start the process or update frames until the container has a real size.
        // SwiftTerm derives cols/rows from the frame; a zero-size frame produces a 0×0
        // terminal which renders as a blank screen (issue #661).
        guard bounds.size.width > 0, bounds.size.height > 0 else { return }
        if tab.terminalView.superview === self {
            // Terminal view is already in the hierarchy — just update its frame.
            tab.terminalView.frame = bounds
            tab.terminalView.needsLayout = true
            tab.terminalView.needsDisplay = true
            scrollInterceptor.frame = bounds
            tab.startIfNeeded()
        } else {
            // Terminal view was removed (e.g. tab switch race) — re-add it.
            // Always set needsDisplay here because showTab just inserted a fresh
            // subview that has never been drawn at this container's size.
            showTab(tab)
            tab.terminalView.needsLayout = true
            tab.terminalView.needsDisplay = true
            tab.startIfNeeded()
        }
    }

    override var isFlipped: Bool { true }
}

// MARK: - Terminal search

/// A match found in the terminal scrollback buffer.
struct TerminalSearchMatch {
    let row: Int
    let col: Int
    let length: Int
}

// MARK: - Модель вкладки терминала

/// Одна вкладка терминала. Содержит SwiftTerm LocalProcessTerminalView.
/// class (не struct), чтобы view не копировался при передаче.
@MainActor
@Observable
final class TerminalTab: Identifiable, Hashable {
    /// Environment keys that describe the parent terminal emulator rather than
    /// Pine's embedded terminal. Leaving these in place makes TUI behaviour
    /// depend on how Pine itself was launched (Finder/Dock vs a host terminal).
    private static let hostTerminalEnvironmentKeys: Set<String> = [
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "TERM_SESSION_ID",
        "LC_TERMINAL",
        "LC_TERMINAL_VERSION",
        "TERMINAL_EMULATOR",
        "VTE_VERSION",
    ]

    /// Prefixes for terminal-emulator-specific integration variables that
    /// should not leak into Pine's own embedded terminal session.
    private static let hostTerminalEnvironmentPrefixes: [String] = [
        "GHOSTTY_",
        "ITERM_",
        "KITTY_",
        "VTE_",
        "WEZTERM_",
    ]

    let id = UUID()
    /// Display name shown in the tab. Updated by the shell when it
    /// reports a new terminal title via escape sequences.
    var name: String
    /// Stable label assigned at creation (e.g. "Terminal 1").
    /// Used for accessibility identifiers so UI tests can find tabs reliably
    /// regardless of what the shell sets as the dynamic title.
    let stableLabel: String
    let terminalView: LocalProcessTerminalView
    fileprivate(set) var isTerminated = false

    // MARK: - Search state

    /// All matches found by the most recent search.
    var searchMatches: [TerminalSearchMatch] = []
    /// Index into `searchMatches` for the currently highlighted match, or -1 if none.
    var currentMatchIndex: Int = -1
    /// Total number of lines from the last search (used for scroll positioning).
    private var searchTotalRows: Int = 0

    private let delegate: TerminalTabDelegate
    private let shellSettings: ShellSettings
    private var processStarted = false
    private var workingDirectory: URL?

    init(name: String, shellSettings: ShellSettings = .shared) {
        self.name = name
        self.stableLabel = name
        self.shellSettings = shellSettings
        self.terminalView = LocalProcessTerminalView(frame: TerminalContainerView.defaultTerminalFrame)
        self.delegate = TerminalTabDelegate()
        self.delegate.tab = self
        self.terminalView.processDelegate = self.delegate

        // Настраиваем внешний вид сразу — шрифт определяет размер ячейки
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // One Dark canonical background (#282C34) gives proper contrast
        // for the ANSI palette. The system `textBackgroundColor` (~#1E1E1E
        // in dark mode) is too grey and washes out TUI colors.
        // Foreground stays semantic so it adapts to light/dark appearance.
        terminalView.nativeForegroundColor = .textColor
        terminalView.nativeBackgroundColor = NSColor(srgbRed: 0x28 / 255.0,
                                                      green: 0x2C / 255.0,
                                                       blue: 0x34 / 255.0,
                                                      alpha: 1.0)

        // Match Ghostty / modern terminal behaviour: do NOT auto-promote bold
        // text to the bright color variant. SwiftTerm's default of `true`
        // doubles up the brightness of any bold ANSI segment, which was a
        // major contributor to Pine's terminal looking visibly louder than
        // native macOS terminals (issue #733).
        terminalView.useBrightColors = false

        // Apply Pine's One Dark terminal palette (issue #816).
        // Centralised in `TerminalPalette` so it can be unit-tested
        // independently of the SwiftTerm view and kept as a single source of
        // truth. See `TerminalPalette.swift` for rationale (issues #733, #765).
        TerminalPalette.install(on: terminalView)
    }

    /// Сохраняет рабочую директорию для отложенного запуска
    func configure(workingDirectory: URL?) {
        self.workingDirectory = workingDirectory
    }

    /// Builds the environment dictionary for the terminal child process.
    ///
    /// Starts from the current process environment, removes host-terminal-
    /// specific capability markers, and adds:
    /// - `PINE_TERMINAL=1` — marker so scripts can detect Pine's terminal
    /// - `TERM=xterm-256color` — standard 256-color terminal type
    /// - `COLORTERM=truecolor` — advertises 24-bit color support to TUIs
    func buildEnvironment() -> [String: String] {
        Self.normalizedEnvironment(
            from: ProcessInfo.processInfo.environment,
            workingDirectory: workingDirectory
        )
    }

    /// Normalizes the host process environment for Pine's embedded terminal.
    ///
    /// This makes terminal child processes deterministic regardless of whether
    /// Pine was launched from Finder/Dock/Spotlight/Xcode or from another
    /// terminal emulator. In particular, TUIs such as k9s/tcell use
    /// `COLORTERM=truecolor` to enable 24-bit colors, while host-specific
    /// variables like `TERM_PROGRAM` or `GHOSTTY_*` can trigger different
    /// feature paths that do not apply inside Pine.
    static func normalizedEnvironment(
        from baseEnvironment: [String: String],
        workingDirectory: URL?
    ) -> [String: String] {
        var env = baseEnvironment

        for key in env.keys where shouldStripHostTerminalEnvironmentKey(key) {
            env.removeValue(forKey: key)
        }

        env["PINE_TERMINAL"] = "1"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"

        if let wd = workingDirectory {
            env["PINE_PROJECT_ROOT"] = wd.path
            let hash = ContextFileWriter.hashedFileName(for: wd)
            let contextsDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(ContextFileWriter.contextsDirName)
            env["PINE_CONTEXT_FILE"] = contextsDir
                .appendingPathComponent(hash).path
        }

        return env
    }

    private static func shouldStripHostTerminalEnvironmentKey(_ key: String) -> Bool {
        if hostTerminalEnvironmentKeys.contains(key) {
            return true
        }
        return hostTerminalEnvironmentPrefixes.contains { key.hasPrefix($0) }
    }

    /// Resolves the working directory for the terminal process.
    ///
    /// Returns the configured `workingDirectory` path, or falls back to `$HOME`, then `/`.
    func resolveWorkingDirectory() -> String {
        workingDirectory?.path ?? (ProcessInfo.processInfo.environment["HOME"] ?? "/")
    }

    /// Запускает процесс если ещё не запущен и view добавлен в иерархию.
    /// The terminal view must have a non-zero frame so SwiftTerm can calculate
    /// the correct column/row count for the PTY. Starting with a zero frame
    /// causes a blank terminal (issue #661).
    func startIfNeeded() {
        guard !processStarted else { return }
        guard terminalView.frame.size.width > 0,
              terminalView.frame.size.height > 0 else { return }
        processStarted = true

        let env = buildEnvironment()
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let dir = resolveWorkingDirectory()

        terminalView.startProcess(
            executable: shellSettings.resolvedShellPath,
            args: shellSettings.shellArgs,
            environment: envStrings,
            execName: nil,
            currentDirectory: dir
        )
    }

    func stop() {
        guard !isTerminated else { return }
        isTerminated = true
        terminalView.terminate()
    }

    /// Whether the shell process is still running.
    var isProcessRunning: Bool {
        !isTerminated && processStarted && terminalView.process.running
    }

    /// Whether a foreground process (child of the shell) is currently running.
    /// Returns true if tcgetpgrp reports a different process group than the shell.
    var hasForegroundProcess: Bool {
        guard isProcessRunning else { return false }
        let fd = terminalView.process.childfd
        guard fd >= 0 else { return false }
        let foregroundPgid = tcgetpgrp(fd)
        let shellPid = terminalView.process.shellPid
        return foregroundPgid > 0 && foregroundPgid != shellPid
    }

    // MARK: - Search

    /// Searches the terminal scrollback buffer for `query` and stores matches.
    /// The heavy work runs off the main actor; only the final state update
    /// and scroll happen on main.
    ///
    /// Uses SwiftTerm's public `getBufferAsData()` to extract the full buffer
    /// content without accessing internal `buffer.lines`.
    @MainActor
    func search(for query: String, caseSensitive: Bool = false) async {
        guard !query.isEmpty else {
            searchMatches = []
            currentMatchIndex = -1
            searchTotalRows = 0
            return
        }

        // Store for SwiftTerm findNext/findPrevious highlight calls
        lastSearchQuery = query
        lastSearchOptions = SearchOptions(caseSensitive: caseSensitive)

        // Extract full buffer text via public API on main thread
        let terminal = terminalView.getTerminal()
        let bufferData = terminal.getBufferAsData()

        // Search off main thread
        let searchQuery = query
        let isCaseSensitive = caseSensitive
        let (matches, totalRows) = await Task.detached(priority: .userInitiated) {
            guard let bufferText = String(data: bufferData, encoding: .utf8) else {
                return ([TerminalSearchMatch](), 0)
            }
            let lines = bufferText.split(separator: "\n", omittingEmptySubsequences: false)
            let needle = isCaseSensitive ? searchQuery : searchQuery.lowercased()
            var result: [TerminalSearchMatch] = []
            for (row, line) in lines.enumerated() {
                let haystack = isCaseSensitive ? String(line) : String(line).lowercased()
                var searchStart = haystack.startIndex
                while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
                    let col = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                    let length = haystack.distance(from: range.lowerBound, to: range.upperBound)
                    result.append(TerminalSearchMatch(row: row, col: col, length: length))
                    searchStart = range.upperBound
                }
            }
            return (result, lines.count)
        }.value

        guard !Task.isCancelled else { return }

        searchMatches = matches
        searchTotalRows = totalRows
        if matches.isEmpty {
            currentMatchIndex = -1
            terminalView.clearSearch()
        } else {
            currentMatchIndex = 0
            highlightCurrentMatch()
        }
    }

    /// Advances to the next match, highlights it via SwiftTerm selection, and scrolls to it.
    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % searchMatches.count
        highlightCurrentMatch()
    }

    /// Goes back to the previous match, highlights it, and scrolls to it.
    func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        terminalView.findPrevious(lastSearchQuery, options: lastSearchOptions)
    }

    /// Clears search results, resets state, and removes selection highlight.
    func clearSearch() {
        searchMatches = []
        currentMatchIndex = -1
        searchTotalRows = 0
        lastSearchQuery = ""
        terminalView.clearSearch()
    }

    /// Last query/options used for findNext/findPrevious calls.
    private var lastSearchQuery = ""
    private var lastSearchOptions = SearchOptions()

    /// Highlights the current match using SwiftTerm's built-in find (which sets selection)
    /// and scrolls to it.
    private func highlightCurrentMatch() {
        guard currentMatchIndex >= 0, currentMatchIndex < searchMatches.count else { return }
        // SwiftTerm's findNext/findPrevious iterates through matches and highlights via selection.
        // We call the appropriate one to move SwiftTerm's internal cursor to our target match.
        terminalView.findNext(lastSearchQuery, options: lastSearchOptions)
    }

    // MARK: - Send text to terminal

    /// Sends the given text to the terminal process as keyboard input.
    /// The text is written to the PTY as if the user typed it.
    func sendText(_ text: String) {
        guard isProcessRunning else { return }
        let data = Array(text.utf8)
        terminalView.process.send(data: data[...])
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Делегат SwiftTerm

class TerminalTabDelegate: NSObject, LocalProcessTerminalViewDelegate {
    weak var tab: TerminalTab?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        tab?.name = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        tab?.isTerminated = true
    }
}
