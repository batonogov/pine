//
//  TerminalSession.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI
import SwiftTerm

/// Pine-specific terminal view wrapper.
///
/// SwiftTerm's CoreGraphics renderer only paints cells that have an explicit
/// background attribute; cells with the default terminal background rely on
/// the view/layer background. When a TUI briefly paints a colored rectangle
/// and then returns those cells to the default background, stale pixels can
/// remain in the layer. Pine addresses this in `forceFullRedraw()` (called
/// at every re-parent / layout / backing-store-invalidation boundary) by
/// dropping the stale layer contents before a synchronous repaint.
///
/// `setNeedsDisplay` is overridden to promote partial invalidations to
/// full-bounds redraws (so SwiftTerm repaints as many cells as possible),
/// but deliberately does NOT zero `layer.contents` — see issue #1094.
final class PineTerminalView: LocalProcessTerminalView {
    private var redrawBackgroundColor: CGColor?

    /// Enables SwiftTerm's Metal renderer once the view lands in a window.
    ///
    /// Metal replaces the layer-backed CoreGraphics raster (`layer.contents`
    /// = CGImage) with a GPU swapchain (`CAMetalLayer` drawables owned by an
    /// embedded `MTKView`). That eliminates the entire class of black-screen
    /// bugs where AppKit purges `layer.contents` and a subsequent no-op
    /// `displayIfNeeded()` leaves the terminal black — #64, #661, #871, #918,
    /// #923, #966, #1094 (#1108). Under Metal, SwiftTerm's `draw(_:)` returns
    /// early (`if metalView != nil { return }`), so the CoreGraphics raster
    /// path — and the "zeroed contents + no-op displayIfNeeded" race —
    /// ceases to exist.
    ///
    /// Idempotent: `setUseMetal(_:)` no-ops when already in the requested
    /// mode, and the `isUsingMetalRenderer` / `window != nil` guards make
    /// repeated calls (re-parenting on tab switch, pane split,
    /// maximize/restore) safe. On failure — a headless CI VM, an old GPU, a
    /// virtual display without a Metal device —
    /// `MTLCreateSystemDefaultDevice()` returns nil and
    /// `MetalError.deviceUnavailable` is thrown; we swallow it and SwiftTerm
    /// keeps using CoreGraphics with no behavioural change.
    func enableMetalRendererIfNeeded() {
        guard !Self.isMetalExplicitlyDisabled else { return }
        guard window != nil else { return }
        guard !isUsingMetalRenderer else { return }
        do {
            try setUseMetal(true)
        } catch {
            // Metal unavailable (e.g. headless CI VM, old GPU). SwiftTerm
            // keeps using CoreGraphics — no action needed.
        }
    }

    /// `true` when Metal is explicitly disabled via the `--disable-metal`
    /// launch argument or the `PINE_DISABLE_METAL` environment variable. Used
    /// by the UI-test harness on macOS-26 virtual displays (where Metal may
    /// be unavailable) and as a production escape hatch. Mirrors the
    /// `--disable-agent-detection` / `PINE_DISABLE_AGENT_DETECTION` pattern
    /// from `TerminalManager`.
    static var isMetalExplicitlyDisabled: Bool {
        CommandLine.arguments.contains("--disable-metal")
            || ProcessInfo.processInfo.environment["PINE_DISABLE_METAL"] != nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftTerm's `setUseMetal(_:)` must be called only once the view is
        // in a window — it needs a Metal device, which is nil when headless
        // (GPURendering.md). Re-parenting (tab switch, pane split, drag-drop)
        // fires `viewDidMoveToWindow` again, but `enableMetalRendererIfNeeded`
        // is idempotent, so the second call is a cheap no-op.
        enableMetalRendererIfNeeded()
    }

    func prepareLayerForRedraw(background: NSColor? = nil) {
        // Under the Metal renderer `layer.contents` holds no terminal raster
        // (the MTKView owns the swapchain), so zeroing it is at best a no-op
        // and at worst a source of flicker. Skip entirely when Metal is active.
        if isUsingMetalRenderer { return }
        if let background {
            redrawBackgroundColor = background.cgColor
        }
        if let redrawBackgroundColor {
            layer?.backgroundColor = redrawBackgroundColor
        }
        layer?.contents = nil
    }

    /// Promotes partial invalidations to full-bounds redraws so default-
    /// background cells are repainted (SwiftTerm only paints cells with
    /// explicit background attributes).
    ///
    /// IMPORTANT: do NOT call `prepareLayerForRedraw()` here. Zeroing
    /// `layer.contents` on every `setNeedsDisplay` call (including cursor
    /// blink, single-char input) creates a race: between `contents = nil`
    /// and the actual display cycle, AppKit may coalesce or cancel the
    /// pending `needsDisplay`, leaving the layer permanently black (issue
    /// #1094). Only clear `contents` from `forceFullRedraw()`, where the
    /// nil is immediately followed by a synchronous `displayIfNeeded()`.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(bounds.isEmpty ? invalidRect : bounds)
    }
}

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

    /// Working directory of the active terminal tab. Used to resolve
    /// relative `file:line` references when the user Cmd+clicks terminal
    /// output (issue #949). Set by `TerminalContainerView.showTab`.
    var workingDirectory: URL?

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
        // Cmd+click: detect and open file:line references in terminal output (issue #949).
        // When the Command modifier is held, the click is interpreted as a
        // navigation gesture rather than terminal input. If a file:line
        // reference is found under the cursor, the file is opened in the
        // editor; otherwise the click falls through to the terminal.
        if event.modifierFlags.contains(.command), handleFileLinkClick(event) {
            return
        }
        isMouseDown = true
        stopAutoScroll()
        if let tv = terminalView {
            window?.makeFirstResponder(tv)
            tv.mouseDown(with: event)
        }
    }

    // MARK: - File link click handling (issue #949)

    /// Attempts to open a `file:line` reference under the cursor.
    ///
    /// Maps the click point to a terminal grid cell, extracts the full row
    /// text from SwiftTerm's buffer, runs it through ``TerminalOutputParser``,
    /// and if a link spans the clicked column, posts an ``.openFileAtLine``
    /// notification that `ContentView` observes to open the file.
    ///
    /// - Parameter event: The mouse-down event (expected to carry `.command`).
    /// - Returns: `true` if a file link was found and the notification was posted,
    ///   `false` if no link was under the cursor (caller should fall through
    ///   to normal terminal mouse handling).
    @discardableResult
    internal func handleFileLinkClick(_ event: NSEvent) -> Bool {
        guard let terminalView, let workingDirectory else { return false }
        let term = terminalView.getTerminal()

        // Map the click location to terminal grid coordinates.
        let point = convert(event.locationInWindow, from: nil)
        let grid = MouseScrollForwarder.gridPosition(
            point: point,
            viewBounds: terminalView.bounds,
            cols: term.cols,
            rows: term.rows,
            isFlipped: terminalView.isFlipped
        )

        // Extract the text of the clicked row from SwiftTerm's buffer.
        guard let line = term.getLine(row: grid.row) else { return false }
        let rowText = line.translateToString()
        guard !rowText.isEmpty else { return false }

        // Parse file:line references in the row text.
        let links = TerminalOutputParser.parseFilePaths(
            in: rowText,
            workingDirectory: workingDirectory
        )
        guard !links.isEmpty else { return false }

        // Find the link that spans the clicked column.
        guard let link = TerminalOutputParser.link(atColumn: grid.col, in: links) else {
            return false
        }

        // Post the notification — ContentView observes this and opens the file.
        var userInfo: [String: Any] = [
            "url": link.fileURL,
            "line": link.line,
        ]
        if let column = link.column {
            userInfo["column"] = column
        }
        NotificationCenter.default.post(
            name: .openFileAtLine,
            object: nil,
            userInfo: userInfo
        )
        return true
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
    /// Dedicated accumulator for the mouse-reporting branch of
    /// `installScrollMonitor` (the `term.mouseMode != .off` path). Kept
    /// separate from `accumulatedScrollDelta` — which is shared by the
    /// alternate-screen and normal-mode branches — so this change stays
    /// cleanly mergeable with the sibling PR for issue #979 that reworks
    /// the alternate-screen branch.
    private var mouseReportingAccumulatedDelta: CGFloat = 0
    /// Notification observer that re-renders the active terminal when the
    /// host window regains key focus. After a long Cmd+Tab into another app
    /// AppKit may discard the layer's backing store; without this observer
    /// the TUI alternate-screen content would stay blank until the next
    /// keystroke or process tick.
    private var becomeKeyObserver: NSObjectProtocol?
    /// The window we are currently observing for `didBecomeKey`. Tracked
    /// separately because `NSObjectProtocol` does not expose its target,
    /// so without this we would tear down and re-install the observer on
    /// every `viewDidMoveToWindow` even when the window did not change.
    private weak var observedWindow: NSWindow?
    /// Notification observer that re-renders the active terminal when the
    /// host window moves to a different screen (e.g. external display with
    /// a different backingScaleFactor). The backing store may be invalidated
    /// in this case, leaving the terminal black (issue #1094).
    private var didChangeScreenObserver: NSObjectProtocol?
    /// Defensive repaint when the window becomes visible again after being
    /// fully occluded. macOS suppresses drawing for occluded windows; if a
    /// pending redraw was dropped or the cached frame is stale on reveal,
    /// this forces a fresh paint so the terminal is never left black
    /// (issue #1094 family). Coalesced (occlusion can toggle in bursts).
    private var didChangeOcclusionStateObserver: NSObjectProtocol?
    /// Defensive repaint on app reactivation (Cmd+H hide → reveal, Spaces /
    /// Mission Control return). `didBecomeKey` does NOT fire if the window
    /// was already key before the hide, so this covers the gap. App-level
    /// (`object: nil`); coalesced since it can fire in bursts (issue #1094 family).
    private var didBecomeActiveObserver: NSObjectProtocol?
    /// Defensive repaint when the window is restored from the Dock, in case
    /// the cached frame is stale after minimization (issue #1094 family).
    private var didDeminiaturizeObserver: NSObjectProtocol?
    /// Trailing-edge coalescer for the burst-prone observer recovery repaints
    /// (occlusion toggling during Mission Control / Stage Manager, app
    /// reactivation). Collapses a flurry of visibility transitions into a
    /// single `forceFullRedraw()` (a synchronous full-buffer `displayIfNeeded()`).
    /// Lazily created; captures `self` weakly. See `scheduleCoalescedRecovery()`
    /// and `UITimings.Debounce.terminalRecovery`.
    private var recoveryDebouncer: Debouncer?

    func showTab(_ tab: TerminalTab?) {
        guard let tab else {
            // Tab cleared (terminal pane closed) — kill any in-flight
            // auto-scroll so it cannot tick against a now-detached view.
            scrollInterceptor.handleActiveTabChange()
            subviews.forEach { $0.removeFromSuperview() }
            currentTabID = nil
            scrollInterceptor.terminalView = nil
            scrollInterceptor.workingDirectory = nil
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
            scrollInterceptor.workingDirectory = tab.workingDirectoryURL
            addSubview(scrollInterceptor)

            tab.terminalView.needsLayout = true

            // Adding a second tab to an existing pane does not change the
            // container's bounds, so AppKit does NOT call `layout()` on its
            // own — and `layout()` is the only place where `startIfNeeded()`
            // runs (issue #918). Without this, the new tab's PTY never spawns
            // and its `LocalProcessTerminalView` paints empty until the user
            // resizes the pane (which forces a fresh layout pass). Kick the
            // process directly here using the frame we just installed.
            //
            // Only start when the container has REAL bounds — when the
            // container is zero-sized (first SwiftUI layout pass) we
            // intentionally use the default fallback frame for `effectiveBounds`
            // but we must NOT spawn the PTY yet, because the fallback size
            // is just a placeholder. The next `layout()` with real bounds
            // will both update the frame and call `startIfNeeded()`.
            if bounds.size.width > 0, bounds.size.height > 0 {
                tab.startIfNeeded()
            }
            self.needsLayout = true
            self.needsDisplay = true

            // Force a synchronous full repaint from the SwiftTerm display
            // buffer (and raise SIGWINCH on alternate-screen TUIs so the
            // child itself redraws — see `refreshAfterReparent` docs).
            tab.refreshAfterReparent()
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

            // Resolve the scroll delta, gesture/momentum phase boundaries, and
            // the "should this event reach the per-branch logic" decision in
            // one testable place (`TerminalScrollEventInfo`). See that type for
            // the full rationale on phase-boundary handling and delta selection.
            let scrollInfo = TerminalScrollEventInfo(event: event)
            let scrollDelta = scrollInfo.delta
            let phaseBegan = scrollInfo.phaseBegan
            let phaseEnded = scrollInfo.phaseEnded
            guard scrollInfo.shouldIntercept else { return event }

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

                let velocity = MouseScrollForwarder.mouseReportingScrollEvents(
                    accumulatedDelta: self.mouseReportingAccumulatedDelta,
                    newDelta: scrollDelta,
                    isPrecise: scrollInfo.isPrecise,
                    phaseBegan: phaseBegan
                )
                self.mouseReportingAccumulatedDelta = velocity.remainingDelta
                // Forward exactly one VT100 mouse-button event per accumulated
                // threshold crossing (trackpad) or one per tick (mouse wheel),
                // using the SwiftTerm pixel overload so SGR-pixel-capable TUIs
                // (mode 1016) can do sub-row scrolling.
                for _ in 0..<velocity.events {
                    term.sendEvent(
                        buttonFlags: buttonFlags,
                        x: pos.col,
                        y: pos.row,
                        pixelX: Int(locationInTerminal.x),
                        pixelY: Int(locationInTerminal.y)
                    )
                }
                // On gesture/momentum end, flush residual delta above the settle
                // threshold so the final partial threshold crossing is committed
                // instead of being silently dropped (Ghostty/iTerm2 behavior).
                if phaseEnded {
                    let residual = self.mouseReportingAccumulatedDelta
                    let flushCount = MouseScrollForwarder.flushResidual(accumulatedDelta: residual)
                    self.mouseReportingAccumulatedDelta = 0
                    if flushCount > 0 {
                        // Direction comes from the residual sign, not scrollDelta,
                        // because .ended markers often carry a zero delta.
                        let flushButtonFlags = MouseScrollForwarder.encodeScrollButton(
                            deltaY: residual,
                            shift: modifiers.contains(.shift),
                            option: modifiers.contains(.option),
                            control: modifiers.contains(.control)
                        )
                        for _ in 0..<flushCount {
                            term.sendEvent(
                                buttonFlags: flushButtonFlags,
                                x: pos.col,
                                y: pos.row,
                                pixelX: Int(locationInTerminal.x),
                                pixelY: Int(locationInTerminal.y)
                            )
                        }
                    }
                }
                return nil
            }

            if term.isCurrentBufferAlternate {
                // Alternate screen (k9s, htop, vim, etc.) without mouse reporting —
                // convert scroll to arrow keys like Ghostty/WezTerm/iTerm2.
                // Reuse the shared `normalScrollLines` helper so the arrow-key
                // cadence matches normal-mode scrollback (1 arrow per
                // `trackpadLineThreshold` = 10 points) and residual delta is
                // preserved via `remainingDelta` (no lost overshoot).
                let arrowKey = MouseScrollForwarder.arrowKeyForScroll(deltaY: scrollDelta)
                let result = MouseScrollForwarder.normalScrollLines(
                    accumulatedDelta: self.accumulatedScrollDelta,
                    newDelta: scrollDelta,
                    isPrecise: scrollInfo.isPrecise,
                    phaseBegan: phaseBegan
                )
                self.accumulatedScrollDelta = result.remainingDelta
                let arrowCount = MouseScrollForwarder.arrowKeyCount(for: result)
                for _ in 0..<arrowCount {
                    term.sendResponse(text: arrowKey)
                }
                // On gesture/momentum end, flush residual delta above the settle
                // threshold so the final partial line is committed instead of
                // being silently dropped (Ghostty/iTerm2 behavior).
                if phaseEnded {
                    let residual = self.accumulatedScrollDelta
                    let flushCount = MouseScrollForwarder.flushResidual(accumulatedDelta: residual)
                    self.accumulatedScrollDelta = 0
                    if flushCount > 0 {
                        // Direction comes from the residual sign, not scrollDelta,
                        // because .ended markers often carry a zero delta.
                        let flushKey = MouseScrollForwarder.arrowKeyForScroll(deltaY: residual)
                        for _ in 0..<flushCount {
                            term.sendResponse(text: flushKey)
                        }
                    }
                }
                return nil
            }

            // Normal mode — controlled scrollback instead of SwiftTerm's raw
            // velocity which jumps to full-page scrolls at delta > 9.
            let result = MouseScrollForwarder.normalScrollLines(
                accumulatedDelta: self.accumulatedScrollDelta,
                newDelta: scrollDelta,
                isPrecise: scrollInfo.isPrecise,
                phaseBegan: phaseBegan
            )
            self.accumulatedScrollDelta = result.remainingDelta
            if result.lines > 0 {
                if scrollDelta > 0 {
                    terminalView.scrollUp(lines: result.lines)
                } else {
                    terminalView.scrollDown(lines: result.lines)
                }
            }
            // On gesture/momentum end, flush residual delta above the settle
            // threshold so the final partial line is committed instead of
            // being silently dropped (Ghostty/iTerm2 behavior).
            if phaseEnded {
                let residual = self.accumulatedScrollDelta
                let flushCount = MouseScrollForwarder.flushResidual(accumulatedDelta: residual)
                self.accumulatedScrollDelta = 0
                if flushCount > 0 {
                    // Direction comes from the residual sign, not scrollDelta,
                    // because .ended markers often carry a zero delta.
                    if residual > 0 {
                        terminalView.scrollUp(lines: flushCount)
                    } else {
                        terminalView.scrollDown(lines: flushCount)
                    }
                }
            }
            return nil
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
        removeWindowObservers()
        super.removeFromSuperview()
    }

    /// Tears down every window/app-level notification observer registered in
    /// ``viewDidMoveToWindow()``. Called on superview removal and whenever the
    /// host window changes, so observers registered for a previous window
    /// cannot fire against the new one (issue #1094 recovery-trigger family).
    private func removeWindowObservers() {
        if let observer = becomeKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            becomeKeyObserver = nil
        }
        if let observer = didChangeScreenObserver {
            NotificationCenter.default.removeObserver(observer)
            didChangeScreenObserver = nil
        }
        if let observer = didChangeOcclusionStateObserver {
            NotificationCenter.default.removeObserver(observer)
            didChangeOcclusionStateObserver = nil
        }
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
        if let observer = didDeminiaturizeObserver {
            NotificationCenter.default.removeObserver(observer)
            didDeminiaturizeObserver = nil
        }
        // Cancel any pending coalesced recovery so it cannot fire against a
        // detached container or a new host window (issue #1094 family).
        recoveryDebouncer?.cancel()
        observedWindow = nil
    }

    /// Repaints the active terminal (and for TUI apps in alternate screen
    /// raises SIGWINCH so the child redraws). Used by `viewDidMoveToWindow`
    /// and the window-become-key observer.
    private func refreshActiveTerminalAfterReparent() {
        guard let tab = terminalPaneState?.activeTab,
              tab.terminalView.superview === self else { return }
        tab.refreshAfterReparent()
    }

    /// Schedules a trailing-edge-coalesced recovery repaint for the burst-prone
    /// observer triggers (`didChangeOcclusionState`, `didBecomeActive`). A
    /// flurry of visibility transitions within one animation (Mission Control,
    /// Stage Manager, app reactivation) collapses into a single
    /// `forceFullRedraw()` — a synchronous full-buffer `displayIfNeeded()` —
    /// instead of firing N times. The delay is `UITimings.Debounce.terminalRecovery`
    /// (~50 ms: imperceptible for recovery, collapses a burst). Low-frequency
    /// observers (`becomeKey`, `didChangeScreen`, `didDeminiaturize`) and the
    /// lifecycle hooks (`viewDidMoveToWindow`, `viewDidChangeBackingProperties`)
    /// call `refreshActiveTerminalAfterReparent()` directly for a prompt paint.
    private func scheduleCoalescedRecovery() {
        if recoveryDebouncer == nil {
            recoveryDebouncer = Debouncer(delay: UITimings.Debounce.terminalRecovery) { [weak self] in
                MainActor.assumeIsolated {
                    self?.refreshActiveTerminalAfterReparent()
                }
            }
        }
        recoveryDebouncer?.schedule()
    }

    /// Requests first responder on the terminal view.
    /// Always deferred via async dispatch so that the focus request lands
    /// *after* SwiftUI finishes its layout pass — otherwise SwiftUI can
    /// restore first-responder to the editor's GutterTextView, undoing
    /// the terminal focus requested by Cmd+T / Cmd+`.
    private func focusTerminalView(_ terminalView: LocalProcessTerminalView) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(terminalView)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit may call this method multiple times for the same window —
        // skip the observer dance when nothing has actually changed.
        guard window !== observedWindow else { return }
        removeWindowObservers()
        guard let win = window else { return }
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.refreshActiveTerminalAfterReparent()
        }
        // Re-render when the window moves to a different screen — the backing
        // scale factor may differ, invalidating the layer's contents (issue #1094).
        didChangeScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.refreshActiveTerminalAfterReparent()
        }
        // Defensive repaint when the window becomes visible again after being
        // fully occluded. macOS suppresses (not purges) drawing for occluded
        // windows, so a pending redraw may have been dropped or the cached
        // frame may be stale on reveal — this guarantees a fresh paint. It
        // repaints only when the resulting occlusion state contains `.visible`
        // (skips becoming fully occluded, which is off-screen) and is coalesced
        // because occlusion can toggle repeatedly during Mission Control / window
        // drag (issue #1094 family).
        didChangeOcclusionStateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: win,
            queue: .main
        ) { [weak self, weak win] _ in
            guard let win,
                  Self.shouldRecoverAfterOcclusionChange(occlusionState: win.occlusionState) else { return }
            self?.scheduleCoalescedRecovery()
        }
        // Defensive repaint on app reactivation (Cmd+H hide → reveal, Spaces /
        // Mission Control return). `didBecomeKey` does NOT fire if the window
        // was already key before the hide, so this covers the gap. App-level
        // (`object: nil`) and coalesced: it can fire in bursts (reactivation
        // while occlusion is also settling), so route through the coalesced
        // recovery path (issue #1094 family).
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleCoalescedRecovery()
        }
        // Defensive repaint when the window is restored from the Dock, in case
        // the cached frame is stale after minimization. Low-frequency, so kept
        // synchronous (not coalesced) (issue #1094 family).
        didDeminiaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.refreshActiveTerminalAfterReparent()
        }
        observedWindow = win
        // First repaint after attaching to the window — `displayIfNeeded`
        // inside `showTab` is a no-op when the container had no window yet,
        // so this is the first chance to actually paint the SwiftTerm view.
        refreshActiveTerminalAfterReparent()
    }

    override func layout() {
        super.layout()
        guard let terminalPaneState, let tab = terminalPaneState.activeTab else { return }
        // Do not start the process or update frames until the container has a real size.
        // SwiftTerm derives cols/rows from the frame; a zero-size frame produces a 0×0
        // terminal which renders as a blank screen (issue #661).
        guard bounds.size.width > 0, bounds.size.height > 0 else { return }
        if tab.terminalView.superview === self {
            // Terminal view is already in the hierarchy — update its frame.
            // Track whether the frame actually changed so we can force a
            // redraw afterwards; SwiftTerm only emits SIGWINCH when cols/rows
            // change, so a layout pass that shifts pixels by less than one
            // cell would otherwise leave a TUI app's alternate screen blank.
            let frameChanged = tab.terminalView.frame.size != bounds.size
            tab.terminalView.frame = bounds
            tab.terminalView.needsLayout = true
            scrollInterceptor.frame = bounds
            tab.startIfNeeded()
            if frameChanged {
                tab.refreshAfterReparent()
            }
        } else {
            // Terminal view was removed (e.g. tab switch race) — re-add it.
            // `showTab` already starts the PTY, marks needsLayout, and calls
            // `refreshAfterReparent`, so nothing else to do here.
            showTab(tab)
        }
    }

    override var isFlipped: Bool { true }

    // MARK: - Backing store invalidation (issue #1094)

    /// AppKit calls this when the view's backing properties change — display
    /// scale (Retina ↔ external), Liquid Glass layer management, memory
    /// pressure purge, screen sleep/wake. In all these cases the layer's
    /// backing store may be discarded, leaving a black terminal. Force a
    /// synchronous repaint from SwiftTerm's displayBuffer to recover.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshActiveTerminalAfterReparent()
    }

    /// Whether the container should repaint after a window occlusion-state
    /// change. Only repaint when the window is at least partially visible
    /// again — repainting while fully occluded (off-screen) is wasteful, since
    /// macOS suppresses drawing for occluded windows anyway. Internal so unit
    /// tests can pin the visible-edge decision without a live window
    /// (issue #1094 family).
    internal static func shouldRecoverAfterOcclusionChange(
        occlusionState: NSWindow.OcclusionState
    ) -> Bool {
        occlusionState.contains(.visible)
    }
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

    // MARK: - Agent tracking (#951)

    /// The AI agent session detected in this tab, if any. Set by
    /// `AgentDetectionCoordinator` when the tab's foreground process matches
    /// a known agent CLI. `nil` when no agent is running or the process has
    /// exited. Drives the agent badge in `TerminalNativeTabItem`.
    var agentSession: AgentSession?

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

    /// KVO observation token for `NSApp.effectiveAppearance` — re-applies
    /// palette and background when the user switches between light/dark mode.
    private var appearanceObservation: NSKeyValueObservation?

    init(name: String, shellSettings: ShellSettings = .shared) {
        self.name = name
        self.stableLabel = name
        self.shellSettings = shellSettings
        self.terminalView = PineTerminalView(frame: TerminalContainerView.defaultTerminalFrame)
        self.delegate = TerminalTabDelegate()
        self.delegate.tab = self
        self.terminalView.processDelegate = self.delegate

        // Настраиваем внешний вид сразу — шрифт определяет размер ячейки
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Match Ghostty / modern terminal behaviour: do NOT auto-promote bold
        // text to the bright color variant. SwiftTerm's default of `true`
        // doubles up the brightness of any bold ANSI segment, which was a
        // major contributor to Pine's terminal looking visibly louder than
        // native macOS terminals (issue #733).
        terminalView.useBrightColors = false

        applyCurrentTerminalAppearance(forceRedraw: false)

        // Re-apply palette and background when system appearance changes.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: .new) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.applyCurrentTerminalAppearance(forceRedraw: true)
            }
        }
    }

    /// Applies Pine's appearance-aware terminal colors and keeps SwiftTerm's
    /// layer background in sync with the terminal model. SwiftTerm only sets
    /// `layer.backgroundColor` during initial setup, so Pine must refresh it
    /// when the app moves between light and dark appearances.
    ///
    /// `internal` (not `private`) so unit tests can pin the invariant that
    /// this method does NOT clear `layer.contents` without a synchronous
    /// repaint (issue #1107).
    internal func applyCurrentTerminalAppearance(forceRedraw: Bool) {
        let background = TerminalPalette.currentBackgroundColor()
        terminalView.nativeForegroundColor = .textColor
        terminalView.nativeBackgroundColor = background
        // Sync the layer's background colour WITHOUT clearing `contents`.
        // `prepareLayerForRedraw()` nils `layer.contents`, which is only safe
        // from `forceFullRedraw()` — where the nil is immediately followed by
        // a synchronous `displayIfNeeded()`. Calling it here unconditionally
        // (including the `forceRedraw == false` init path) leaves the layer
        // black when the subsequent repaint is a no-op: window minimized /
        // occluded / view detached, e.g. an appearance change firing while
        // the window is hidden (issue #1107, #1094 invariant).
        // `forceFullRedraw()` already syncs the background and clears contents
        // itself, so the explicit `prepareLayerForRedraw` here was both racy
        // and redundant on the `forceRedraw == true` path.
        terminalView.layer?.backgroundColor = background.cgColor

        // Apply Pine's terminal palette (issue #816, #931).
        // Centralised in `TerminalPalette` so it can be unit-tested
        // independently of the SwiftTerm view and kept as a single source of
        // truth. The palette adapts to the current system appearance.
        TerminalPalette.install(on: terminalView)

        if forceRedraw {
            forceFullRedraw()
        }
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

    /// The configured working directory URL, or `nil` if none was set.
    /// Used by the file-link click handler to resolve relative `file:line`
    /// references in terminal output (issue #949).
    var workingDirectoryURL: URL? { workingDirectory }

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

    /// Forces SwiftTerm to mark the entire visible buffer as dirty and the
    /// view to redraw synchronously.
    ///
    /// Used after re-parenting the terminal view (tab switch, pane split,
    /// maximize/restore, drag-and-drop) and when the host window regains
    /// key focus. AppKit may have dropped the layer's backing store while
    /// the view was detached, leaving a black frame after re-attach.
    /// `setNeedsDisplay(bounds)` + `displayIfNeeded()` is enough to
    /// repaint from `displayBuffer`, since SwiftTerm's `draw(_:)` paints
    /// the full visible buffer for any `dirtyRect` it receives.
    /// `terminal.updateFullScreen()` additionally seeds the dirty range
    /// in case SwiftTerm's own throttled `updateDisplay` is the next path
    /// to fire (e.g. on incoming PTY data).
    ///
    /// Safe to call when the view is detached from a window — AppKit
    /// silently no-ops `displayIfNeeded()` in that state.
    func forceFullRedraw() {
        if let pineTerminalView = terminalView as? PineTerminalView {
            pineTerminalView.prepareLayerForRedraw(background: terminalView.nativeBackgroundColor)
        } else {
            terminalView.layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        }
        let term = terminalView.getTerminal()
        term.updateFullScreen()
        terminalView.setNeedsDisplay(terminalView.bounds)
        terminalView.displayIfNeeded()
    }

    /// Sends the current PTY window size again via `TIOCSWINSZ`, which
    /// raises `SIGWINCH` in the child process.
    ///
    /// Most TUI applications (k9s, htop, vim, less +F, tmux, btop) repaint
    /// their entire alternate screen in response to `SIGWINCH`. After
    /// re-parenting the terminal view, the alternate-screen buffer that
    /// SwiftTerm holds may be empty (the TUI hasn't sent anything since
    /// the last input) — `forceFullRedraw()` alone would just paint the
    /// empty buffer. This method nudges the TUI to redraw itself.
    ///
    /// No-op when the process isn't running or the PTY fd is invalid.
    /// Idempotent — sending the same winsize twice is harmless.
    ///
    /// There is a benign race window between the `isProcessRunning` check
    /// and the `setWinSize` call: the child can exit in between, leaving
    /// `childfd` closed. The ioctl on a closed fd returns `EBADF` which we
    /// intentionally swallow — the result is the same as a normal no-op.
    func kickPTYWindowSize() {
        guard isProcessRunning else { return }
        let fd = terminalView.process.childfd
        guard fd >= 0 else { return }
        var size = terminalView.getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(
            masterPtyDescriptor: fd,
            windowSize: &size
        )
    }

    /// Convenience wrapper: repaint the buffer and, for alternate-screen
    /// TUIs, raise SIGWINCH so the child redraws. Used by every re-parent
    /// site in `TerminalContainerView` (`showTab`, `viewDidMoveToWindow`,
    /// `layout` on frame change, become-key observer).
    func refreshAfterReparent() {
        forceFullRedraw()
        if terminalView.getTerminal().isCurrentBufferAlternate {
            kickPTYWindowSize()
        }
    }

    /// Whether the shell process is still running.
    var isProcessRunning: Bool {
        !isTerminated && processStarted && terminalView.process.running
    }

    /// Whether a foreground process (child of the shell) is currently running.
    /// Returns true if tcgetpgrp reports a different process group than the shell.
    var hasForegroundProcess: Bool {
        foregroundProcessID > 0
    }

    /// The process group ID of the foreground process in this terminal, or
    /// `-1` if the shell itself is in the foreground or the process is not
    /// running. Used by `AgentDetectionCoordinator` (#951).
    var foregroundProcessID: Int32 {
        guard isProcessRunning else { return -1 }
        let fd = terminalView.process.childfd
        guard fd >= 0 else { return -1 }
        let foregroundPgid = tcgetpgrp(fd)
        let shellPid = terminalView.process.shellPid
        guard foregroundPgid > 0, foregroundPgid != shellPid else { return -1 }
        return foregroundPgid
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

        // Search off main thread. The match-finding algorithm lives in the
        // pure `TerminalBufferSearch` helper so it can be unit-tested without
        // a live SwiftTerm terminal; this closure just decodes the buffer and
        // delegates to it.
        let searchQuery = query
        let isCaseSensitive = caseSensitive
        let (matches, totalRows) = await Task.detached(priority: .userInitiated) {
            guard let bufferText = String(data: bufferData, encoding: .utf8) else {
                return ([TerminalSearchMatch](), 0)
            }
            return TerminalBufferSearch.scan(
                bufferText: bufferText,
                query: searchQuery,
                caseSensitive: isCaseSensitive
            )
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
