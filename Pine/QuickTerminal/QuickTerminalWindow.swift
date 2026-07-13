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
/// focus. Escape and ⌘W hide the panel rather than closing it (the session
/// is keep-alive — scrollback survives).
///
/// `nonactivatingPanel` keeps the panel from stealing activation from the
/// underlying app while still allowing text input; `canJoinAllSpaces` +
/// `fullScreenAuxiliary` make it appear in every Space and over full-screen
/// apps. The window is owned by `QuickTerminalController`.
final class QuickTerminalWindow: NSPanel {
    /// Called when the user presses Escape or ⌘W inside the panel.
    var onHide: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .titled],
            backing: .buffered,
            defer: false
        )
        // `.titled` is required for `canBecomeKey` to take effect on a
        // borderless panel; hide its chrome so the window looks borderless.
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
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
