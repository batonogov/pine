//
//  QuickTerminalWindow.swift
//  Pine
//
//  The floating, borderless panel that hosts the quick terminal (#1113).
//  Drop-down style: full screen width, ~40% height, anchored to the top.
//

import AppKit
import Carbon.HIToolbox

/// Borderless floating panel for the quick terminal. Stays above normal
/// windows (`level = .floating`), joins all Spaces, and accepts key input
/// (`canBecomeKey = true`) so the embedded SwiftTerm view receives keyboard
/// focus. Escape, ⌘W, and the close button hide the panel rather than
/// closing it (the session is keep-alive — scrollback survives); the panel
/// is resizable so the user can adjust its size (#1648).
///
/// `nonactivatingPanel` keeps the panel from stealing activation from the
/// underlying app while still allowing text input; `canJoinAllSpaces` +
/// `fullScreenAuxiliary` make it appear in every Space and over full-screen
/// apps. The window is owned by `QuickTerminalController`.
final class QuickTerminalWindow: NSPanel {
    /// Called when the user presses Escape or ⌘W or clicks the close button.
    var onHide: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .borderless, .nonactivatingPanel, .titled,
                .closable, .resizable,
            ],
            backing: .buffered,
            defer: false
        )
        // `.titled` is required for `canBecomeKey` to take effect on a
        // borderless panel; hide its chrome so the window looks borderless.
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // A floating drop-down has no meaningful zoom/full-screen state
        // (#1648): keep the green button disabled and never add
        // `.fullScreenPrimary` to `collectionBehavior` below.
        standardWindowButton(.zoomButton)?.isEnabled = false
        // Floor the live-resize range so the panel can't be dragged to a
        // sliver.
        contentMinSize = NSSize(width: 480, height: 160)
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Zooming (green button, titlebar double-click) fights the edge-anchored
    /// drop-down geometry, so the panel never zooms.
    override func zoom(_ sender: Any?) {}

    /// User-initiated close (the close button or the system Window → Close
    /// item) hides the panel instead of tearing it down — the keep-alive
    /// session survives. ⌘W and Escape reach `keyDown(with:)` instead (see
    /// below). Programmatic teardown still goes through `close()` (see
    /// `QuickTerminalController.shutdown()`).
    override func performClose(_ sender: Any?) {
        onHide?()
    }

    override func keyDown(with event: NSEvent) {
        // Escape — hide the panel (keep the session alive).
        if event.keyCode == UInt16(kVK_Escape) {
            onHide?()
            return
        }
        // ⌘W — hide rather than close, matching the keep-alive model.
        if event.modifierFlags.contains(.command), event.keyCode == UInt16(kVK_ANSI_W) {
            onHide?()
            return
        }
        super.keyDown(with: event)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
