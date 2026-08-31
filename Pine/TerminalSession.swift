//
//  TerminalSession.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import Darwin
import Dispatch
import SwiftUI
import SwiftTerm
import os

/// Owns the exact PTY open-file description Pine received from SwiftTerm.
///
/// A `(device, inode, file type)` snapshot is not a lifetime token: after
/// SwiftTerm closes its public `childfd`, another PTY can reuse both the file
/// descriptor and the same `stat` values. Duplicating once, immediately after
/// `startProcess`, pins the original open-file description instead. Every
/// acknowledged write is then duplicated from this Pine-owned descriptor,
/// never from SwiftTerm's later, borrowed integer.
nonisolated final class PinePTYDescriptorLease: @unchecked Sendable {
    final class WriteDescriptor: @unchecked Sendable {
        let rawValue: Int32
        private let owner: PinePTYDescriptorLease
        private let lock = NSLock()
        private var isFinished = false

        fileprivate init(
            rawValue: Int32,
            owner: PinePTYDescriptorLease
        ) {
            self.rawValue = rawValue
            self.owner = owner
        }

        func finish() {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            lock.unlock()
            owner.releaseWriteDescriptor(rawValue)
        }

        deinit {
            finish()
        }
    }

    private let lock = NSLock()
    private var ownedDescriptor: Int32 = -1
    private var writeDescriptors: Set<Int32> = []
    private var isInvalidated = false

    /// Pins the borrowed descriptor exactly once for this terminal lifecycle.
    /// The duplicate happens synchronously before `startIfNeeded()` returns.
    func acquire(borrowing borrowedDescriptor: Int32) -> Bool {
        guard borrowedDescriptor >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated, ownedDescriptor < 0 else { return false }
        let descriptor = Darwin.fcntl(
            borrowedDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard descriptor >= 0 else { return false }
        ownedDescriptor = descriptor
        return true
    }

    /// Duplicates only the Pine-owned lease, synchronously, before an async
    /// write can suspend. The returned token closes exactly once even when
    /// terminal teardown invalidates all outstanding writes first.
    func acquireWriteDescriptor() -> WriteDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated, ownedDescriptor >= 0 else { return nil }
        let descriptor = Darwin.fcntl(
            ownedDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard descriptor >= 0 else { return nil }
        writeDescriptors.insert(descriptor)
        return WriteDescriptor(rawValue: descriptor, owner: self)
    }

    /// Closes the persistent lease and rejects new writes before SwiftTerm
    /// terminates its process. An already-acquired write descriptor remains
    /// owned until its DispatchIO completion: closing it early would let the
    /// integer be reused and recreate the very ABA write-redirection hazard
    /// this lease prevents. Those small launch writes are the only bounded
    /// lifetime by which Pine can extend the PTY master after invalidation.
    func invalidate() {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        isInvalidated = true
        let descriptor = ownedDescriptor
        ownedDescriptor = -1
        lock.unlock()

        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    #if DEBUG
    var isActiveForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isInvalidated && ownedDescriptor >= 0
    }
    #endif

    private func releaseWriteDescriptor(_ descriptor: Int32) {
        lock.lock()
        let wasOwned = writeDescriptors.remove(descriptor) != nil
        lock.unlock()
        if wasOwned {
            Darwin.close(descriptor)
        }
    }

    deinit {
        invalidate()
    }
}

nonisolated enum AcknowledgedPTYWriter {
    /// The caller acquires the exact descriptor synchronously on MainActor;
    /// the I/O itself is deliberately nonisolated because DispatchIO invokes
    /// its completion on the supplied background queue.
    static func write(
        _ bytes: [UInt8],
        to descriptor: PinePTYDescriptorLease.WriteDescriptor
    ) async -> Bool {
        let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        return await withCheckedContinuation { continuation in
            DispatchIO.write(
                toFileDescriptor: descriptor.rawValue,
                data: data,
                runningHandlerOn: DispatchQueue.global(qos: .userInitiated)
            ) { remaining, error in
                descriptor.finish()
                continuation.resume(returning:
                    AcknowledgedPTYWriter.acknowledgesCompletion(
                        error: error,
                        remainingByteCount: remaining?.count ?? 0
                    )
                )
            }
        }
    }

    static func acknowledgesCompletion(
        error: Int32,
        remainingByteCount: Int
    ) -> Bool {
        error == 0 && remainingByteCount == 0
    }

}

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
    /// Supplies the terminal's spoken name on demand (#1533).
    ///
    /// Read at query time so a shell title change or a newly detected agent
    /// is announced without anyone having to push a fresh label.
    var accessibilityLabelProvider: (() -> String?)?

    override func accessibilityLabel() -> String? {
        accessibilityLabelProvider?() ?? super.accessibilityLabel()
    }

    private var redrawBackgroundColor: CGColor?
    private var initialMetalRedrawWorkItems: [DispatchWorkItem] = []
    /// Serializes Pine's cursor policy with SwiftTerm's PTY parser. Process
    /// output may arrive away from MainActor while Settings changes arrive on
    /// the main thread, so both the streaming parser and preferred style live
    /// behind the same lock as the corresponding Terminal mutation.
    private let cursorStyleLock = NSLock()
    private var cursorSequenceTracker = DECSCUSRStreamTracker()
    private var preferredCursorStyle: CursorStyle?
    private var activeCursorDirective: DECSCUSRStreamTracker.Directive?
    #if DEBUG
    /// Per-view seam for exercising the production CoreGraphics fallback
    /// without mutating process-wide launch arguments or environment.
    var metalRendererDisabledForTesting = false
    #endif
    /// SwiftTerm 1.15 rebuilds its nested `MTKView` only when the `NSWindow`
    /// identity changes. Pine also reparents a terminal between AppKit hosts
    /// inside the same project window (pane maximize/restore and tab moves).
    /// That can leave the old `CAMetalLayer` bound to a retired presentation
    /// host even though the window pointer is unchanged.
    ///
    /// TerminalContainerView owns the presentation generation because AppKit
    /// can move either this view, the whole container, or an ancestor subtree.
    /// Immediate-superview/window identity alone misses at least one of those
    /// paths. Recreate only after the generation actually changes; ordinary
    /// resize, focus, and tab hide/show keep the same renderer and glyph atlas.
    private var presentationHostGeneration: UUID?
    private var metalRendererNeedsRecreationOnAttach = false
    /// The attachment retry batch can finish before a slow interactive shell
    /// emits its first prompt. Re-arm it once, after the first PTY chunk that
    /// actually changes visible buffer content, so an earlier OSC title does
    /// not consume recovery before there is anything to present.
    private let firstVisibleContentLock = NSLock()
    private var didObserveFirstVisibleContent = false

    /// Lightweight snapshot of the visible cells SwiftTerm would render.
    /// Buffer-line generations change on cell/attribute mutations, while OSC
    /// metadata such as title and working directory leaves this state intact.
    private struct VisibleContentState: Equatable {
        struct Line: Equatable {
            let identity: ObjectIdentifier?
            let generation: UInt64
        }

        let bufferIdentity: ObjectIdentifier
        let displayOffset: Int
        let totalLinesTrimmed: Int
        let lines: [Line]

        init(terminal: Terminal) {
            let buffer = terminal.buffer
            bufferIdentity = ObjectIdentifier(buffer)
            displayOffset = buffer.yDisp
            totalLinesTrimmed = buffer.totalLinesTrimmed
            lines = (0..<terminal.rows).map { row in
                guard let line = terminal.getLine(row: row) else {
                    return Line(identity: nil, generation: 0)
                }
                return Line(identity: ObjectIdentifier(line), generation: line.generation)
            }
        }
    }

    #if DEBUG
    /// Test hook that observes every backend-aware redraw request without
    /// replacing the production AppKit/Metal behavior.
    var backendRedrawRequestObserver: (() -> Void)?
    /// Test hook for the Metal-specific SwiftTerm compatibility bridge.
    var metalRedrawBridgeObserver: (() -> Void)?
    /// Test hook immediately before SwiftTerm's synchronous Metal draw API.
    var metalImmediateDrawObserver: (() -> Void)?
    #endif

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
    /// `MetalError.deviceUnavailable` is thrown; SwiftTerm keeps using
    /// CoreGraphics and Pine records the concrete failure for diagnostics.
    func enableMetalRendererIfNeeded() {
        #if DEBUG
        guard !metalRendererDisabledForTesting else { return }
        #endif
        guard !Self.isMetalExplicitlyDisabled else { return }
        guard window != nil else { return }
        guard !isUsingMetalRenderer else { return }
        do {
            try setUseMetal(true)
        } catch {
            Logger.terminal.error(
                "SwiftTerm Metal renderer unavailable; falling back to CoreGraphics: \(String(describing: error), privacy: .public)"
            )
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

    /// Binds the renderer to one committed AppKit presentation generation.
    ///
    /// The first binding records identity only. Later generations rebuild the
    /// nested MTKView while preserving the Terminal, PTY, display buffer, and
    /// scrollback. If the hierarchy is temporarily detached, the pending
    /// rebuild runs after the next real window attachment.
    func bindPresentationHost(generation: UUID) {
        guard presentationHostGeneration != generation else { return }
        if presentationHostGeneration != nil, isUsingMetalRenderer {
            metalRendererNeedsRecreationOnAttach = true
        }
        presentationHostGeneration = generation
        recreateMetalRendererAfterHostChangeIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            cancelInitialMetalRedrawRetries()
            return
        }
        // SwiftTerm's `setUseMetal(_:)` must be called only once the view is
        // in a window — it needs a Metal device, which is nil when headless
        // (GPURendering.md). Re-parenting (tab switch, pane split, drag-drop)
        // fires `viewDidMoveToWindow` again, but `enableMetalRendererIfNeeded`
        // is idempotent, so the second call is a cheap no-op.
        enableMetalRendererIfNeeded()
        recreateMetalRendererAfterHostChangeIfNeeded()

        // `MTKView` is on-demand (`isPaused = true`) and its CAMetalLayer may
        // not have a drawable during the first display request. SwiftTerm
        // 1.14.0 marks that frame pending, but the pending flag is consumed
        // only by a successfully submitted command buffer — which does not
        // exist in this bootstrap failure. Retry after every real attachment,
        // including a detach/reattach within the same window: re-parenting
        // replaces the CAMetalLayer presentation context and can reproduce
        // the same drawable bootstrap race. The sequence is bounded and
        // cancelled on the next detach (issue #1128).
        if isUsingMetalRenderer {
            scheduleInitialMetalRedrawRetries()
        }
    }

    /// Recreates SwiftTerm's renderer after an AppKit presentation-generation
    /// change, including whole-container or ancestor detach/reattach inside
    /// the same `NSWindow`.
    ///
    /// SwiftTerm exposes no public rebind API in 1.15, so the supported
    /// `setUseMetal(false/true)` pair is the narrow compatibility bridge.
    /// It replaces only the nested `MTKView` and renderer; `Terminal` and the
    /// local process stay alive. Ordinary resize/focus/occlusion redraws never
    /// enter this path because they do not move the view between hosts.
    private func recreateMetalRendererAfterHostChangeIfNeeded() {
        guard metalRendererNeedsRecreationOnAttach,
              superview != nil,
              window != nil else { return }
        metalRendererNeedsRecreationOnAttach = false
        guard isUsingMetalRenderer else { return }

        do {
            try setUseMetal(false)
            try setUseMetal(true)
        } catch {
            Logger.terminal.error(
                "SwiftTerm Metal renderer recreation after host reparent failed: \(String(describing: error), privacy: .public)"
            )
        }

        if isUsingMetalRenderer {
            // Reuse the bounded first-draw recovery window for the newly
            // created CAMetalLayer. viewDidMoveToWindow may immediately
            // schedule the same batch again; the helper cancels/restarts it,
            // so a host transition never creates parallel retry loops.
            scheduleInitialMetalRedrawRetries()
        } else {
            // Enabling Metal failed after the old renderer was removed.
            // Repaint synchronously through the CoreGraphics fallback.
            requestRendererDisplay()
        }
    }

    /// Rebuilds the presentation layer on explicit user request, recovering a
    /// terminal whose renderer stopped presenting frames.
    ///
    /// SwiftTerm's Metal renderer re-requests a dropped frame only from the
    /// completion handler of a *submitted* command buffer. Both refusal paths
    /// in `MetalTerminalRenderer.draw(in:)` — a busy frame semaphore and a
    /// missing drawable/render-pass descriptor — set the pending-redraw flag
    /// without submitting anything, so nothing ever consumes it. The view then
    /// keeps accepting input and PTY output while never presenting a frame,
    /// and no invalidation from Pine recovers it: `setNeedsDisplay` and
    /// `drawMetalFrameNow()` both re-enter the same refusal.
    ///
    /// Recreating the renderer is the only escape — it installs a fresh
    /// `MTKView`, semaphore, and drawable chain while `Terminal`, the PTY, and
    /// the scrollback stay untouched. CoreGraphics has no such trap, so a
    /// repaint through the backend-aware bridge is both necessary and
    /// sufficient there.
    ///
    /// No-op while detached: `viewDidMoveToWindow` rebuilds and repaints on
    /// the next real attachment anyway.
    func recoverRendererNow() {
        guard window != nil else { return }

        if isUsingMetalRenderer {
            do {
                try setUseMetal(false)
                try setUseMetal(true)
            } catch {
                Logger.terminal.error(
                    "SwiftTerm Metal renderer recreation during display recovery failed: \(String(describing: error), privacy: .public)"
                )
            }
            if isUsingMetalRenderer {
                // A freshly created CAMetalLayer can miss its first drawable
                // exactly like one created on attach; reuse the same bounded
                // retry batch instead of betting recovery on a single frame.
                scheduleInitialMetalRedrawRetries()
            }
        }

        requestRendererDisplay()
    }

    /// Re-arms first-frame recovery when visible terminal content first
    /// changes, rather than relying solely on the earlier view-attachment
    /// window. This matters for shells whose startup takes longer than the
    /// bounded attachment retries: OSC title/working-directory sequences can
    /// arrive well before the prompt and must not consume the one-shot.
    ///
    /// `super` must run first so the bytes (including the prompt) are already
    /// represented in SwiftTerm's display buffer before Pine requests a frame.
    /// SwiftTerm may deliver process output away from the main queue, so the
    /// recovery hop keeps the AppKit/Metal work main-thread-safe.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        let shouldInspectContent = firstVisibleContentLock.withLock {
            !didObserveFirstVisibleContent
        }
        let contentBefore = slice.isEmpty || !shouldInspectContent
            ? nil
            : VisibleContentState(terminal: getTerminal())
        feedTrackingCursorStyle(slice: slice)
        guard let contentBefore,
              VisibleContentState(terminal: getTerminal()) != contentBefore,
              claimFirstVisibleContent() else { return }

        if Thread.isMainThread {
            scheduleFirstVisibleContentRecoveryIfNeeded()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleFirstVisibleContentRecoveryIfNeeded()
            }
        }
    }

    /// Atomically updates Pine's cached preference and SwiftTerm's live
    /// cursor. A settings change also becomes the current authority until a
    /// later valid explicit DECSCUSR command arrives.
    func applyPreferredCursorStyle(_ style: CursorStyle) {
        cursorStyleLock.lock()
        defer { cursorStyleLock.unlock() }
        preferredCursorStyle = style
        activeCursorDirective = .preferred
        getTerminal().setCursorStyle(style)
    }

    /// Runs SwiftTerm and Pine's cursor-policy resolution on the exact same
    /// delivery path. Enforcing the last valid directive after `super` avoids
    /// an asynchronous repair frame and also prevents unsupported or embedded
    /// lookalikes from superseding a valid reset/explicit command.
    private func feedTrackingCursorStyle(slice: ArraySlice<UInt8>) {
        cursorStyleLock.lock()
        defer { cursorStyleLock.unlock() }

        if let directive = cursorSequenceTracker.consume(slice) {
            activeCursorDirective = directive
        }
        super.dataReceived(slice: slice)

        switch activeCursorDirective {
        case .preferred:
            if let preferredCursorStyle {
                getTerminal().setCursorStyle(preferredCursorStyle)
            }
        case .explicit(let parameter):
            if let style = Self.cursorStyle(forDECSCUSRParameter: parameter) {
                getTerminal().setCursorStyle(style)
            }
        case nil:
            break
        }
    }

    private static func cursorStyle(
        forDECSCUSRParameter parameter: Int
    ) -> CursorStyle? {
        switch parameter {
        case 1:
            return .blinkBlock
        case 2:
            return .steadyBlock
        case 3:
            return .blinkUnderline
        case 4:
            return .steadyUnderline
        case 5:
            return .blinkBar
        case 6:
            return .steadyBar
        default:
            return nil
        }
    }

    /// Claims the one-shot on SwiftTerm's delivery queue. This makes all
    /// later PTY chunks bypass the visible-row snapshots; only the first real
    /// cell mutation pays that bounded O(rows) comparison cost.
    private func claimFirstVisibleContent() -> Bool {
        firstVisibleContentLock.withLock {
            guard !didObserveFirstVisibleContent else { return false }
            didObserveFirstVisibleContent = true
            return true
        }
    }

    /// Requests a display through the renderer that actually owns the pixels.
    ///
    /// SwiftTerm's CoreGraphics path draws in this outer NSView, so the
    /// synchronous `setNeedsDisplay` + `displayIfNeeded` sequence remains the
    /// right recovery operation. Under Metal, however, outer `draw(_:)`
    /// returns immediately and a private nested `MTKView` owns presentation.
    /// SwiftTerm does not expose `requestMetalDisplay()` publicly, so Pine
    /// combines its public immediate-frame API with the existing invalidation
    /// bridge:
    ///
    /// - `selectionChanged(source:)` marks the full visible Metal range dirty
    ///   and queues a display, ensuring cached rows are rebuilt when needed.
    /// - `drawMetalFrameNow()` attempts a frame synchronously while this
    ///   recovery boundary still has a drawable. This closes the gap where an
    ///   on-demand `setNeedsDisplay` is coalesced or discarded by AppKit.
    /// - same-size `setFrameSize(_:)` is harmless (`processSizeChange` no-ops
    ///   when cols/rows are unchanged) and queues a trailing request through
    ///   SwiftTerm's internal `requestMetalDisplay()` if the immediate draw
    ///   could not acquire a drawable.
    ///
    /// Together they provide an immediate request plus a coalesced trailing
    /// request. Replace this compatibility bridge once SwiftTerm exposes a
    /// public backend-aware display API (issue #1128).
    func requestRendererDisplay() {
        #if DEBUG
        backendRedrawRequestObserver?()
        #endif

        if isUsingMetalRenderer {
            #if DEBUG
            metalRedrawBridgeObserver?()
            #endif
            selectionChanged(source: getTerminal())
            #if DEBUG
            metalImmediateDrawObserver?()
            #endif
            drawMetalFrameNow()
            setFrameSize(frame.size)
        } else {
            setNeedsDisplay(bounds)
            displayIfNeeded()
        }
    }

    private func scheduleInitialMetalRedrawRetries() {
        cancelInitialMetalRedrawRetries()
        initialMetalRedrawWorkItems = UITimings.Render.terminalFirstFrameRetryDelays.map { delay in
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.window != nil, self.isUsingMetalRenderer else { return }
                self.requestRendererDisplay()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    private func scheduleFirstVisibleContentRecoveryIfNeeded() {
        // If content arrived while detached, the next viewDidMoveToWindow()
        // starts the same bounded attachment batch, so no separate work is
        // needed here.
        guard window != nil else { return }

        if isUsingMetalRenderer {
            // Restart (rather than append to) the bounded batch. If shell
            // startup overlaps the attachment batch, this moves the whole
            // recovery window to the point where drawable content exists.
            scheduleInitialMetalRedrawRetries()
        } else {
            // CoreGraphics does not need Metal's retry loop. Route exactly
            // one request through the existing backend-aware bridge, which
            // repaints synchronously without clearing layer.contents.
            requestRendererDisplay()
        }
    }

    private func cancelInitialMetalRedrawRetries() {
        initialMetalRedrawWorkItems.forEach { $0.cancel() }
        initialMetalRedrawWorkItems.removeAll()
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

    // MARK: - OSC 8 hyperlinks (#1114)

    /// SwiftTerm calls this on ⌘+click of a hover-underlined link (explicit
    /// OSC 8 or an implicit URL it detected). `LocalProcessTerminalView`
    /// installs `self` as its own `terminalDelegate`, so this concrete
    /// method on the subclass is the witness that runs INSTEAD of SwiftTerm's
    /// default `requestOpenLink` (which calls `NSWorkspace.shared.open(url)`
    /// and would LAUNCH a `file://` link pointing at an `.app`/`.command`
    /// bundle — exactly what #1114 exists to prevent).
    ///
    /// The decision lives in the pure, unit-tested ``TerminalLinkOpener``:
    /// `file://` (local host) → reveal in Finder (no launch),
    /// `http(s)`/`mailto` → open externally, foreign-host `file://` and
    /// unknown schemes → ignore. The implicit `path:line` path (#949) is
    /// resolved earlier by `TerminalScrollInterceptor.handleFileLinkClick`
    /// on `mouseDown` and does not flow through here.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let action = TerminalLinkOpener.action(for: link) else { return }
        switch action {
        case .revealInFinder(let url):
            // Selects the entry in Finder WITHOUT launching it — safe even
            // when the link points at an `.app` / `.command` bundle.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
        }
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
                // `queue: .main` guarantees main-thread delivery; assert main
                // actor isolation to cross the @Sendable observer boundary.
                MainActor.assumeIsolated {
                    self?.handleWindowResignKey()
                }
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
    let canAttemptFocusRequest: (UUID) -> Bool

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        let didRebind = container.bind(to: terminalPaneState)
        container.canAttemptFocusRequest = canAttemptFocusRequest
        container.showTab(
            terminalPaneState.activeTab,
            forcePresentationClaim: didRebind && container.window != nil
        )
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        let didRebind = container.bind(to: terminalPaneState)
        container.canAttemptFocusRequest = canAttemptFocusRequest
        container.showTab(
            terminalPaneState.activeTab,
            forcePresentationClaim: didRebind && container.window != nil
        )
    }

    static func dismantleNSView(
        _ container: TerminalContainerView,
        coordinator: Coordinator
    ) {
        container.prepareForDismantle()
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

    /// Changes only when the actual AppKit presentation host changes. Every
    /// active PineTerminalView binds to this token, covering direct terminal
    /// moves, whole-container reparenting, and ancestor detach/reattach while
    /// keeping ordinary tab switches and resizes renderer-stable.
    private var presentationGeneration = UUID()
    /// Full AppKit ancestry of this container, excluding the container itself.
    /// A direct move of an ancestor within the same window leaves both this
    /// view's immediate superview and NSWindow unchanged, but AppKit still
    /// calls `viewDidMoveToWindow()` on descendants. Comparing the complete
    /// chain there catches that otherwise invisible presentation-host change.
    private var presentationAncestorChain: [ObjectIdentifier] = []
    private var hasAttachedToWindow = false
    private var isAttachedToWindow = false
    var terminalPaneState: TerminalPaneState?
    var canAttemptFocusRequest: ((UUID) -> Bool)?
    private var currentTabID: UUID?
    private weak var currentTab: TerminalTab?
    let destinationFocusCoordinator = AppKitFocusRequestCoordinator()
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

    /// Associates this AppKit host with one pane state. SwiftUI can reuse an
    /// NSViewRepresentable at the same structural position for a different
    /// pane, so release the old pane/tab leases before switching models.
    @discardableResult
    func bind(to paneState: TerminalPaneState) -> Bool {
        guard terminalPaneState !== paneState else { return false }
        showTab(nil)
        terminalPaneState = paneState
        return true
    }

    func showTab(
        _ tab: TerminalTab?,
        forcePresentationClaim: Bool = false
    ) {
        guard let tab else {
            // Tab cleared (terminal pane closed) — kill any in-flight
            // auto-scroll so it cannot tick against a now-detached view.
            scrollInterceptor.handleActiveTabChange()
            releaseTabPresentationOwnershipIfNeeded()
            releasePanePresentationOwnershipIfNeeded()
            subviews.forEach { $0.removeFromSuperview() }
            currentTabID = nil
            currentTab = nil
            destinationFocusCoordinator.cancel()
            scrollInterceptor.terminalView = nil
            scrollInterceptor.workingDirectory = nil
            return
        }

        // A structural SwiftUI transition can temporarily keep two
        // TerminalContainerViews for the same pane alive. The newly attached
        // host claims explicitly from viewDidMoveToWindow; ordinary
        // update/layout passes must not let an outgoing host steal the single
        // model-owned NSView back.
        guard canClaimPresentation(of: tab, force: forcePresentationClaim) else {
            suspendPresentationWhileOwnedElsewhere()
            return
        }

        let tabChanged = tab.id != currentTabID || tab.terminalView.superview !== self
        if tabChanged {
            // Auto-scroll started against the *outgoing* tab — stop it before
            // we swap the underlying terminalView so the next tick cannot
            // scroll the freshly-installed tab using stale coordinates.
            scrollInterceptor.handleActiveTabChange()
            releaseTabPresentationOwnershipIfNeeded()
            subviews.forEach { $0.removeFromSuperview() }
            currentTabID = tab.id
            currentTab = tab
            tab.presentationOwner = self
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

        } else if tab.presentationOwner !== self {
            // Repair a stale lease without touching the already-correct view
            // hierarchy (for example after an interrupted transition).
            currentTab = tab
            tab.presentationOwner = self
        }

        if let pineTerminalView = tab.terminalView as? PineTerminalView {
            pineTerminalView.bindPresentationHost(generation: presentationGeneration)
        }
        if tabChanged {
            // Bind the new presentation generation before repainting so the
            // redraw targets the replacement MTKView, not a retired layer.
            tab.refreshAfterReparent()
        }

        installScrollMonitor()

        let tabID = tab.id
        let focusRequestID = terminalPaneState?.pendingFocusTabID == tabID
            ? terminalPaneState?.pendingFocusRequestID
            : nil
        destinationFocusCoordinator.update(
            requestID: focusRequestID,
            hostView: self,
            targetView: tab.terminalView,
            canAttempt: { [weak self, weak state = terminalPaneState] requestID in
                state?.activeTerminalID == tabID
                    && state?.pendingFocusTabID == tabID
                    && state?.pendingFocusRequestID == requestID
                    && self?.canAttemptFocusRequest?(requestID) != false
            },
            onResult: { [weak state = terminalPaneState] requestID, succeeded in
                state?.acknowledgeFocusRequest(
                    requestID: requestID,
                    for: tabID,
                    succeeded: succeeded
                )
            }
        )
    }

    /// Returns whether this container may present the pane without stealing
    /// it from another live host. The lease belongs to the pane rather than
    /// the active tab: otherwise a stale outgoing host could reclaim the next
    /// tab when both representables observe an active-tab change.
    ///
    /// A force claim is reserved for a container that has just attached or
    /// moved to a new presentation host. Detached incoming representables
    /// cannot take the terminal away from a visible owner before SwiftUI
    /// commits their attachment.
    private func canClaimPresentation(
        of tab: TerminalTab,
        force: Bool
    ) -> Bool {
        guard let terminalPaneState else {
            guard let owner = tab.presentationOwner else { return true }
            return owner === self
                || (window != nil && (force || owner.window == nil))
        }

        if terminalPaneState.presentationOwner === self {
            return true
        }

        // An off-window representable is not yet a committed presentation
        // host. It may claim an entirely unowned initial pane, but must not
        // pull a moved tab or pane away from a live/detached predecessor.
        if window == nil {
            guard terminalPaneState.presentationOwner == nil,
                  tab.presentationOwner == nil else { return false }
            terminalPaneState.presentationOwner = self
            return true
        }

        let displacedPaneOwner = terminalPaneState.presentationOwner
        if let paneOwner = displacedPaneOwner,
           paneOwner !== self,
           !force,
           paneOwner.window != nil {
            return false
        }

        if let tabOwner = tab.presentationOwner,
           tabOwner !== self,
           !force,
           tabOwner.window != nil,
           tabOwner.terminalPaneState?.activeTab?.id == tab.id {
            return false
        }

        terminalPaneState.presentationOwner = self
        if let displacedPaneOwner, displacedPaneOwner !== self {
            displacedPaneOwner.suspendPresentationWhileOwnedElsewhere()
        }
        return true
    }

    private func releaseTabPresentationOwnershipIfNeeded() {
        guard let currentTab, currentTab.presentationOwner === self else { return }
        currentTab.presentationOwner = nil
    }

    private func releasePanePresentationOwnershipIfNeeded() {
        guard terminalPaneState?.presentationOwner === self else { return }
        terminalPaneState?.presentationOwner = nil
    }

    /// Tears down event/focus plumbing in an outgoing host after another live
    /// container has claimed the terminal. Keep `currentTabID` intact so late
    /// update/layout callbacks remain identifiable as stale and cannot turn
    /// into a fresh-tab claim.
    private func suspendPresentationWhileOwnedElsewhere() {
        scrollInterceptor.handleActiveTabChange()
        subviews.forEach { $0.removeFromSuperview() }
        destinationFocusCoordinator.cancel()
        scrollInterceptor.terminalView = nil
        scrollInterceptor.workingDirectory = nil
        removeScrollMonitor()
    }

    /// Releases the presentation lease and AppKit resources owned by this
    /// representable. The PTY and TerminalTab intentionally remain alive.
    func prepareForDismantle() {
        showTab(nil)
        removeScrollMonitor()
        removeWindowObservers()
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
        prepareForDismantle()
        super.removeFromSuperview()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else { return }
        let newAncestorChain = currentPresentationAncestorChain()
        let movedDirectlyInsideWindow = isAttachedToWindow
            && !presentationAncestorChain.isEmpty
            && presentationAncestorChain != newAncestorChain
        presentationAncestorChain = newAncestorChain
        if movedDirectlyInsideWindow {
            advancePresentationGeneration()
        }
        guard window != nil,
              let activeTab = terminalPaneState?.activeTab else { return }
        // AppKit can move an existing view directly between two parents in
        // the same NSWindow without calling our removeFromSuperview override.
        // viewDidMoveToWindow then sees the same observed window and returns
        // early, so claim at the actual superview boundary as well.
        showTab(activeTab, forcePresentationClaim: true)
        if movedDirectlyInsideWindow {
            // CoreGraphics also loses presentation state on this boundary.
            // Metal recreation schedules its own frame, but the shared redraw
            // keeps both renderer paths correct and preserves the fallback.
            refreshActiveTerminalAfterReparent()
        }
    }

    private func advancePresentationGeneration() {
        presentationGeneration = UUID()
    }

    private func currentPresentationAncestorChain() -> [ObjectIdentifier] {
        var chain: [ObjectIdentifier] = []
        var ancestor = superview
        while let view = ancestor {
            chain.append(ObjectIdentifier(view))
            ancestor = view.superview
        }
        return chain
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let isNowAttached = window != nil
        let reattachedAfterHierarchyDetach = isNowAttached
            && hasAttachedToWindow
            && !isAttachedToWindow
        let newAncestorChain = isNowAttached
            ? currentPresentationAncestorChain()
            : presentationAncestorChain
        let ancestorMovedInsideWindow = isNowAttached
            && isAttachedToWindow
            && !presentationAncestorChain.isEmpty
            && presentationAncestorChain != newAncestorChain
        isAttachedToWindow = isNowAttached
        if isNowAttached {
            presentationAncestorChain = newAncestorChain
            if reattachedAfterHierarchyDetach || ancestorMovedInsideWindow {
                advancePresentationGeneration()
            }
            hasAttachedToWindow = true
        }
        destinationFocusCoordinator.hostDidMoveToWindow(self)
        if ancestorMovedInsideWindow,
           let activeTab = terminalPaneState?.activeTab {
            // AppKit reports a direct ancestor-subtree move with the same
            // non-nil NSWindow. Reclaim before the same-window observer fast
            // path below; otherwise an outgoing representable can keep the
            // model-owned terminal view in a retired presentation subtree.
            showTab(activeTab, forcePresentationClaim: true)
            refreshActiveTerminalAfterReparent()
        }
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
            MainActor.assumeIsolated {
                self?.refreshActiveTerminalAfterReparent()
            }
        }
        // Re-render when the window moves to a different screen — the backing
        // scale factor may differ, invalidating the layer's contents (issue #1094).
        didChangeScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshActiveTerminalAfterReparent()
            }
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
            MainActor.assumeIsolated {
                guard let win,
                      Self.shouldRecoverAfterOcclusionChange(occlusionState: win.occlusionState) else { return }
                self?.scheduleCoalescedRecovery()
            }
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
            MainActor.assumeIsolated {
                self?.scheduleCoalescedRecovery()
            }
        }
        // Defensive repaint when the window is restored from the Dock, in case
        // the cached frame is stale after minimization. Low-frequency, so kept
        // synchronous (not coalesced) (issue #1094 family).
        didDeminiaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshActiveTerminalAfterReparent()
            }
        }
        observedWindow = win
        if let activeTab = terminalPaneState?.activeTab {
            // This container has just become a real presentation host. It may
            // legitimately reclaim the model-owned view from an outgoing
            // maximize/restore container; later ordinary update/layout calls
            // cannot steal it back while this lease remains live.
            showTab(activeTab, forcePresentationClaim: true)
        }
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

/// Optional first child for a terminal tab. Keeping the executable and argv
/// separate prevents recovery and extension launches from passing through a
/// login shell or re-parsing opaque values.
nonisolated struct TerminalInitialProcess: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
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
    private var didReportLifecycleEnd = false
    private var deferredTerminationLifecycleEnd = false
    /// The AppKit container currently presenting `terminalView`.
    ///
    /// A pane maximize/restore can keep outgoing and incoming SwiftUI
    /// representables alive in the same animation transaction. Since an
    /// `NSView` can have only one superview, stale containers must not steal
    /// the model-owned terminal view back from the newly attached host.
    /// Presentation ownership is UI plumbing, not observable tab state.
    @ObservationIgnored
    weak var presentationOwner: TerminalContainerView?

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
    private let agentHandoffSettings: AgentHandoffSettings
    private var processStarted = false
    /// The most recent start attempt was refused by the working-directory
    /// admission validator, so the shell will not spawn until a later
    /// `startIfNeeded()` revalidates successfully. `launchAgentInNewTerminal`
    /// fast-fails on this instead of burning its whole wait budget on a tab
    /// that has already been told "no" (issue #1590).
    private(set) var processStartAdmissionRefused = false
    /// Identity-qualified ownership for the exact shell generation and every
    /// observed descendant launched through this tab's real PTY.
    private var processTreeController: TerminalProcessTreeController?
    private var processStartValidationTask: Task<Void, Never>?
    private var processStartValidationGeneration = UUID()
    private var workingDirectoryValidator:
        (@Sendable (URL) async -> Bool)?
    #if DEBUG
    var validationCommitSeamForTesting:
        @Sendable () async -> Void = {}
    var isStartValidationPendingForTesting: Bool {
        processStartValidationTask != nil
    }
    #endif
    /// Stable Pine-owned duplicate of SwiftTerm's master PTY. The holder has
    /// its own lock so nonisolated `deinit` can close it safely as a final
    /// lifecycle backstop.
    private let acknowledgedPTYLease = PinePTYDescriptorLease()
    private var workingDirectory: URL?
    private var initialProcess: TerminalInitialProcess?

    /// Value-only diagnostic used to prove that recovery keeps argv separate
    /// before SwiftTerm starts the child.
    var configuredInitialProcess: TerminalInitialProcess? { initialProcess }

    /// KVO observation token for `NSApp.effectiveAppearance` — re-applies
    /// palette and background when the user switches between light/dark mode.
    private var appearanceObservation: NSKeyValueObservation?

    /// Observer for `terminalThemeChanged` — re-applies the selected theme's
    /// colors immediately when the user picks a new theme or appearance
    /// policy in Settings (issue #1244). Lives for the tab's lifetime.
    ///
    /// `nonisolated(unsafe)`: the token is set once during `init` (on the main
    /// actor) and read only in `deinit`, which is implicitly `nonisolated` and
    /// therefore cannot touch a MainActor-isolated stored property. The token
    /// itself is a plain `NSObjectProtocol` value with no actor affinity.
    @ObservationIgnored
    nonisolated(unsafe) private var themeChangeObserver: NSObjectProtocol?

    /// Observer for explicit cursor preference changes. Kept separate from
    /// theme repainting so appearance changes never override DECSCUSR styles
    /// selected by shells and full-screen terminal applications (#1409).
    @ObservationIgnored
    nonisolated(unsafe) private var cursorStyleChangeObserver: NSObjectProtocol?

    /// The theme/appearance settings source. Defaults to the shared singleton
    /// but is injectable so unit tests can drive resolution deterministically.
    private let themeSettings: TerminalThemeSettings
    /// Stored separately so the nonisolated `deinit` can remove the observer
    /// from the exact center that registered it.
    private let themeNotificationCenter: NotificationCenter
    /// Independent cursor settings source and observer center. Keeping this
    /// separate from theme repainting preserves TUI-issued cursor styles.
    private let cursorSettings: TerminalCursorSettings
    private let cursorNotificationCenter: NotificationCenter
    /// Value-only lifecycle callback installed by the terminal coordinator.
    /// The tab never exposes its process or view to the durable task registry.
    @ObservationIgnored
    var onLifecycleEnded: ((UUID) -> Void)?

    init(
        name: String,
        shellSettings: ShellSettings = .shared,
        agentHandoffSettings: AgentHandoffSettings = .shared,
        themeSettings: TerminalThemeSettings = .shared,
        cursorSettings: TerminalCursorSettings = .shared
    ) {
        self.name = name
        self.stableLabel = name
        self.shellSettings = shellSettings
        self.agentHandoffSettings = agentHandoffSettings
        self.themeSettings = themeSettings
        self.themeNotificationCenter = themeSettings.notificationCenter
        self.cursorSettings = cursorSettings
        self.cursorNotificationCenter = cursorSettings.notificationCenter
        let terminalView = PineTerminalView(
            frame: TerminalContainerView.defaultTerminalFrame,
            options: TerminalOptions(cursorStyle: cursorSettings.cursorStyle)
        )
        terminalView.applyPreferredCursorStyle(cursorSettings.cursorStyle)
        self.terminalView = terminalView
        self.terminalView.setAccessibilityElement(true)
        self.terminalView.setAccessibilityRole(.textArea)
        self.terminalView.setAccessibilityIdentifier(AccessibilityID.terminalSurface)
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
        // Only the "Follow System" policy responds to this; Always Light /
        // Always Dark are independent of the system appearance (#1244).
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: .new) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.applyCurrentTerminalAppearance(forceRedraw: true)
            }
        }

        // Re-apply colors immediately when the user changes the selected
        // theme or appearance policy in Settings → Terminal (issue #1244).
        themeChangeObserver = themeNotificationCenter.addObserver(
            forName: .terminalThemeChanged,
            object: themeSettings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyCurrentTerminalAppearance(forceRedraw: true)
            }
        }

        cursorStyleChangeObserver = cursorNotificationCenter.addObserver(
            forName: .terminalCursorStyleChanged,
            object: cursorSettings,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPreferredCursorStyle()
            }
        }

        // The terminal had a role and an identifier but no name at all, so
        // VoiceOver announced every terminal in the window as "text area".
        // Supplied as a closure rather than a pushed string because both
        // halves of the name move on their own: the shell renames the tab
        // through OSC, and agent detection attaches a session later. Anything
        // pushed would be stale by the time it was read.
        terminalView.accessibilityLabelProvider = { [weak self] in
            guard let self else { return nil }
            return TerminalTabIdentityLabel.accessibilityLabel(for: self)
        }
    }

    deinit {
        acknowledgedPTYLease.invalidate()
        if let themeChangeObserver {
            themeNotificationCenter.removeObserver(themeChangeObserver)
        }
        if let cursorStyleChangeObserver {
            cursorNotificationCenter.removeObserver(cursorStyleChangeObserver)
        }
    }

    /// Applies the user's preference at tab creation and when that preference
    /// explicitly changes. This method is deliberately not called from theme
    /// or system-appearance updates: terminal applications may use DECSCUSR to
    /// own the cursor until the next user-initiated settings change.
    internal func applyPreferredCursorStyle() {
        guard let terminalView = terminalView as? PineTerminalView else {
            terminalView.getTerminal().setCursorStyle(cursorSettings.cursorStyle)
            return
        }
        terminalView.applyPreferredCursorStyle(cursorSettings.cursorStyle)
    }

    /// Applies the terminal's appearance-aware colors and keeps SwiftTerm's
    /// layer background in sync with the terminal model. SwiftTerm only sets
    /// `layer.backgroundColor` during initial setup, so Pine must refresh it
    /// when the app moves between light and dark appearances.
    ///
    /// Resolves the active color scheme from `TerminalThemeSettings` (the
    /// selected theme + appearance policy vs. the system's effective
    /// appearance) and applies every slot: background, foreground, cursor,
    /// selection, link, and the 16 ANSI colors (issue #1244).
    ///
    /// `internal` (not `private`) so unit tests can pin the invariant that
    /// this method does NOT clear `layer.contents` without a synchronous
    /// repaint (issue #1107).
    internal func applyCurrentTerminalAppearance(forceRedraw: Bool) {
        let scheme = themeSettings.currentScheme()
        let background = scheme.backgroundColor()

        terminalView.nativeForegroundColor = scheme.foregroundColor()
        terminalView.nativeBackgroundColor = background
        terminalView.caretColor = scheme.cursorColor()
        terminalView.selectedTextBackgroundColor = scheme.selectionColor()

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

        // Install the theme's 16 ANSI colors (issue #816, #931, #1244).
        // The palette is resolved from the theme so the user's selection
        // takes effect immediately without restarting the shell or losing
        // scrollback. True-color `\e[38;2;R;G;Bm` output and TUI-owned colors
        // are untouched — only the 16 ANSI slots are replaced.
        TerminalPalette.install(palette: scheme.ansiColors, on: terminalView)

        if forceRedraw {
            forceFullRedraw()
        }
    }

    /// Сохраняет рабочую директорию для отложенного запуска
    func configure(
        workingDirectory: URL?,
        initialProcess: TerminalInitialProcess? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.initialProcess = initialProcess
    }

    /// Installs the project admission validator used immediately before a
    /// lazy PTY launch. The validator performs filesystem work off-main and
    /// its generation is rotated so an older suspended result cannot start a
    /// process after the tab was rebound or torn down.
    func configureWorkingDirectoryValidation(
        _ validator: (@Sendable (URL) async -> Bool)?
    ) {
        processStartValidationGeneration = UUID()
        processStartValidationTask?.cancel()
        processStartValidationTask = nil
        // A new validator is a new set of rules; a refusal recorded against
        // the old one must not fast-fail a launch that this one would admit.
        processStartAdmissionRefused = false
        workingDirectoryValidator = validator
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
            workingDirectory: workingDirectory,
            readOnlyContextEnabled: agentHandoffSettings
                .isReadOnlyContextEnabled
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
        workingDirectory: URL?,
        readOnlyContextEnabled: Bool = false
    ) -> [String: String] {
        var env = baseEnvironment

        for key in env.keys where shouldStripHostTerminalEnvironmentKey(key) {
            env.removeValue(forKey: key)
        }

        env["PINE_TERMINAL"] = "1"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Never inherit a handoff capability or project scope from the
        // process that launched Pine. This terminal gets only its own scope.
        env.removeValue(forKey: "PINE_CONTEXT_FILE")
        env.removeValue(forKey: "PINE_PROJECT_ROOT")

        if let wd = workingDirectory {
            env["PINE_PROJECT_ROOT"] = wd.path
            if readOnlyContextEnabled {
                let hash = ContextFileWriter.hashedFileName(for: wd)
                let contextsDir = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(ContextFileWriter.contextsDirName)
                env["PINE_CONTEXT_FILE"] = contextsDir
                    .appendingPathComponent(hash).path
            } else {
                env.removeValue(forKey: "PINE_CONTEXT_FILE")
            }
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
        // Final project reclamation may race a delayed NSViewRepresentable
        // update. A terminated tab is a tombstone and must never fork again.
        guard !isTerminated, !processStarted,
              processStartValidationTask == nil else { return }
        guard terminalView.frame.size.width > 0,
              terminalView.frame.size.height > 0 else { return }
        if let workingDirectory, let workingDirectoryValidator {
            let generation = processStartValidationGeneration
            // The mark describes the *last* outcome; a fresh attempt is now
            // underway, so it must not read as a standing refusal while this
            // validation is pending.
            processStartAdmissionRefused = false
            processStartValidationTask = Task { @MainActor [weak self] in
                guard await workingDirectoryValidator(workingDirectory) else {
                    self?.processStartValidationTask = nil
                    self?.markProcessStartRefused()
                    return
                }
                #if DEBUG
                await self?.validationCommitSeamForTesting()
                #endif
                let valid = await workingDirectoryValidator(workingDirectory)
                guard let self else { return }
                self.processStartValidationTask = nil
                guard valid else {
                    self.markProcessStartRefused()
                    return
                }
                guard !Task.isCancelled,
                      !self.isTerminated,
                      !self.processStarted,
                      self.processStartValidationGeneration == generation,
                      self.workingDirectory == workingDirectory else { return }
                self.startProcessNow()
            }
            return
        }
        startProcessNow()
    }

    /// A refused start is a dead end for this attempt, not a pause: surface it
    /// for callers and for the log, so an agent launch that can never come up
    /// fails in one hop instead of after a full wait budget.
    private func markProcessStartRefused() {
        guard !processStartAdmissionRefused else { return }
        processStartAdmissionRefused = true
        Logger.terminal.error(
            "Terminal shell start refused by working-directory admission at \(self.workingDirectory?.path ?? "?", privacy: .public)"
        )
    }

    private func startProcessNow() {
        guard !isTerminated, !processStarted else { return }
        processStarted = true
        processStartAdmissionRefused = false

        let env = buildEnvironment()
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        let dir = resolveWorkingDirectory()

        let executable = initialProcess?.executablePath
            ?? shellSettings.resolvedShellPath
        let arguments = initialProcess?.arguments ?? shellSettings.shellArgs
        terminalView.startProcess(
            executable: executable,
            args: arguments,
            environment: envStrings,
            execName: nil,
            currentDirectory: dir
        )
        processTreeController = TerminalProcessTreeController(
            rootProcessID: terminalView.process.shellPid
        )
        _ = acknowledgedPTYLease.acquire(
            borrowing: terminalView.process.childfd
        )
    }

    func stop() {
        if !didReportLifecycleEnd {
            didReportLifecycleEnd = true
            onLifecycleEnded?(id)
        }
        guard !isTerminated else { return }
        isTerminated = true
        processStartValidationGeneration = UUID()
        processStartValidationTask?.cancel()
        processStartValidationTask = nil
        processTreeController?.requestTermination()
        acknowledgedPTYLease.invalidate()
        terminalView.terminate()
    }

    /// Starts final application-termination cleanup and returns the exact
    /// process-tree owner whose bounded completion must be observed before
    /// the Pine process is allowed to exit. Ordinary tab closes remain
    /// asynchronous; only the app-wide Quit transaction waits for this
    /// handle, because exiting the parent would otherwise abandon its cleanup
    /// queue and could leave foreground/background descendants alive.
    func stopForApplicationTermination() -> TerminalProcessTreeController? {
        let controller = processTreeController
        if !didReportLifecycleEnd {
            didReportLifecycleEnd = true
            deferredTerminationLifecycleEnd = true
        }
        stop()
        return controller
    }

    /// A failed application-Quit transaction keeps the process stopped but
    /// returns Pine to normal task ownership. Publish the lifecycle end only
    /// after the durable termination snapshot has been rolled back, so an
    /// acknowledged launch cannot disappear from that snapshot mid-commit.
    func reportDeferredApplicationTerminationLifecycleEnd() {
        guard deferredTerminationLifecycleEnd else { return }
        deferredTerminationLifecycleEnd = false
        onLifecycleEnded?(id)
    }

    func processDidTerminate() {
        if !didReportLifecycleEnd {
            didReportLifecycleEnd = true
            onLifecycleEnded?(id)
        }
        processTreeController?.requestTermination()
        isTerminated = true
        acknowledgedPTYLease.invalidate()
    }

    /// Forces SwiftTerm to mark the entire visible buffer as dirty and asks
    /// the active renderer to present it immediately.
    ///
    /// Used after re-parenting the terminal view (tab switch, pane split,
    /// maximize/restore, drag-and-drop) and when the host window regains
    /// key focus. AppKit may have dropped the layer's backing store while
    /// the view was detached, leaving a black frame after re-attach.
    /// On CoreGraphics, `setNeedsDisplay(bounds)` + `displayIfNeeded()`
    /// repaints from `displayBuffer`. On Metal, the outer SwiftTerm view does
    /// not draw; `PineTerminalView.requestRendererDisplay()` routes the
    /// recovery request to the nested `MTKView` instead (issue #1128).
    /// `terminal.updateFullScreen()` additionally seeds the dirty range
    /// in case SwiftTerm's own throttled `updateDisplay` is the next path
    /// to fire (e.g. on incoming PTY data).
    ///
    /// Safe to call when the view is detached from a window — AppKit and
    /// SwiftTerm retain or safely coalesce the pending display request.
    func forceFullRedraw() {
        if let pineTerminalView = terminalView as? PineTerminalView {
            pineTerminalView.prepareLayerForRedraw(background: terminalView.nativeBackgroundColor)
        } else {
            terminalView.layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        }
        let term = terminalView.getTerminal()
        term.updateFullScreen()
        if let pineTerminalView = terminalView as? PineTerminalView {
            pineTerminalView.requestRendererDisplay()
        } else {
            terminalView.setNeedsDisplay(terminalView.bounds)
            terminalView.displayIfNeeded()
        }
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

    /// User-invoked escape hatch for a terminal that renders nothing while its
    /// shell is demonstrably alive (Terminal ▸ Recover Display).
    ///
    /// Unlike `refreshAfterReparent()`, this rebuilds the renderer itself
    /// rather than only repainting: the failure it targets is a Metal
    /// presentation chain that refuses every frame, where repainting re-enters
    /// the same refusal (see `PineTerminalView.recoverRendererNow()`).
    ///
    /// SIGWINCH is raised unconditionally rather than only for the alternate
    /// screen. A stuck renderer leaves Pine unable to tell whether the primary
    /// buffer still matches what the child last drew, and the signal is
    /// harmless to an ordinary shell — it simply reprints its prompt.
    ///
    /// A terminated tab keeps its scrollback and is still worth repainting,
    /// but has no child to signal.
    func recoverDisplay() {
        (terminalView as? PineTerminalView)?.recoverRendererNow()
        forceFullRedraw()
        kickPTYWindowSize()
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
    #if DEBUG
    var foregroundProcessIDOverrideForTesting: Int32?
    var foregroundProcessIDResolverForTesting: (() -> Int32)?
    var foregroundStartOverrideForTesting:
        TerminalProcessStartIdentity?
    var agentProcessIdentityResolverForTesting:
        ((pid_t) -> TerminalProcessStartIdentity?)?
    #endif

    var foregroundProcessID: Int32 {
        readForegroundProcessID()
    }

    /// Samples the foreground group before and after resolving an exact live
    /// member. A group switch in between is uncertainty, not proof that either
    /// the old or new job belongs to the prior agent session.
    func foregroundProcessSnapshot() -> TerminalForegroundProcessSnapshot {
        let before = readForegroundProcessID()
        guard before > 0 else { return .idle }
        guard let identity = foregroundProcessIdentity(in: before) else {
            return .unavailable
        }
        let after = readForegroundProcessID()
        guard after == before else { return .unavailable }
        return .running(processGroupID: before, identity: identity)
    }

    private func readForegroundProcessID() -> Int32 {
        guard !isTerminated else { return -1 }
        #if DEBUG
        if let foregroundProcessIDResolverForTesting {
            return foregroundProcessIDResolverForTesting()
        }
        if let foregroundProcessIDOverrideForTesting {
            return foregroundProcessIDOverrideForTesting
        }
        #endif
        guard isProcessRunning else { return -1 }
        let fd = terminalView.process.childfd
        guard fd >= 0 else { return -1 }
        let foregroundPgid = tcgetpgrp(fd)
        let shellPid = terminalView.process.shellPid
        guard foregroundPgid > 0, foregroundPgid != shellPid else { return -1 }
        return foregroundPgid
    }

    func foregroundProcessIdentity(
        in processGroupID: pid_t
    ) -> TerminalProcessStartIdentity? {
        guard processGroupID > 1 else { return nil }
        #if DEBUG
        if foregroundProcessIDOverrideForTesting != nil {
            return foregroundStartOverrideForTesting
        }
        #endif

        let processIDs: [pid_t]
        switch UserTaskProcessInspector.processIDs(inGroup: processGroupID) {
        case .known(let members):
            // Prefer the leader while it exists, but retain a concrete live
            // member as the generation witness after a pipeline's leader has
            // exited and been reaped.
            processIDs = Array(Set(members + [processGroupID])).sorted {
                if $0 == processGroupID { return true }
                if $1 == processGroupID { return false }
                return $0 < $1
            }
        case .unknown:
            processIDs = [processGroupID]
        }

        return processIDs.lazy.compactMap { processID in
            Self.processIdentity(
                processID: processID,
                processGroupID: processGroupID
            )
        }.first
    }

    func foregroundProcessIdentityStillMatches(
        _ identity: TerminalProcessStartIdentity,
        in processGroupID: pid_t
    ) -> Bool {
        #if DEBUG
        if foregroundProcessIDOverrideForTesting != nil {
            return foregroundStartOverrideForTesting == identity
        }
        #endif
        return Self.processIdentity(
            processID: identity.processID,
            processGroupID: processGroupID
        ) == identity
    }

    func agentProcessIdentityStillMatches(
        _ identity: TerminalProcessStartIdentity
    ) -> Bool {
        #if DEBUG
        if let agentProcessIdentityResolverForTesting {
            return agentProcessIdentityResolverForTesting(
                identity.processID
            ) == identity
        }
        #endif
        guard let current = UserTaskProcessInspector.identity(
            for: identity.processID
        ) else { return false }
        return current.processID == identity.processID
            && current.startSeconds == identity.seconds
            && current.startMicroseconds == identity.microseconds
    }

    nonisolated private static func processIdentity(
        processID: pid_t,
        processGroupID: pid_t
    ) -> TerminalProcessStartIdentity? {
        guard processID > 1,
              Darwin.getpgid(processID) == processGroupID,
              let identity = UserTaskProcessInspector.identity(for: processID),
              Darwin.getpgid(processID) == processGroupID,
              UserTaskProcessInspector.identity(for: processID) == identity else {
            return nil
        }
        return TerminalProcessStartIdentity(
            processID: identity.processID,
            seconds: identity.startSeconds,
            microseconds: identity.startMicroseconds
        )
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

    #if DEBUG
    /// Captures the exact tab-level write in routing tests without starting a
    /// shell or touching a real PTY.
    @ObservationIgnored
    var sendTextOverrideForTesting: ((String) -> Bool)?
    #endif

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
    @discardableResult
    func sendText(_ text: String) -> Bool {
        #if DEBUG
        if let sendTextOverrideForTesting {
            return sendTextOverrideForTesting(text)
        }
        #endif
        guard isProcessRunning else { return false }
        let data = Array(text.utf8)
        terminalView.process.send(data: data[...])
        return true
    }

    /// Duplicates SwiftTerm's public PTY descriptor before suspension, writes
    /// launch input through that owned lease, and resumes only after DispatchIO
    /// reports that every byte was accepted. SwiftTerm may close its descriptor
    /// while the write is pending without redirecting bytes after descriptor reuse.
    func sendTextAcknowledged(_ text: String) async -> Bool {
        guard isProcessRunning,
              let descriptor = acknowledgedPTYLease
                .acquireWriteDescriptor() else { return false }
        let bytes = Array(text.utf8)
        return await AcknowledgedPTYWriter.write(
            bytes,
            to: descriptor
        )
    }

    #if DEBUG
    var hasAcknowledgedPTYLeaseForTesting: Bool {
        acknowledgedPTYLease.isActiveForTesting
    }

    var processTreeControllerForTesting: TerminalProcessTreeController? {
        processTreeController
    }
    #endif

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
        tab?.processDidTerminate()
    }
}
