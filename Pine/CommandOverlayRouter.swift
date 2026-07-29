//
//  CommandOverlayRouter.swift
//  Pine
//
//  Document-scoped router that presents at most one ephemeral command overlay
//  per project window (#975). Replaces the document-modal .sheet presentations
//  used by Quick Open, Symbol Navigator, Go to Line, and Command Palette with
//  a lightweight, shared overlay container.
//
//  Routing through a single router enforces two invariants that per-view
//  @State booleans cannot:
//    1. At most one overlay is active per window.
//    2. Opening one flow deterministically replaces/dismisses another.
//
//  The router also captures the previous AppKit first responder before
//  presenting and restores it on dismissal, so Escape/cancel returns keyboard
//  focus to the editor (not the window default) without mutating document
//  state.
//

import AppKit
import SwiftUI

/// Observable router that owns the active command overlay presentation for a
/// single project window.
@Observable
final class CommandOverlayRouter {

    /// The presentation currently shown, or `nil` when no overlay is active.
    private(set) var activePresentation: CommandOverlayPresentation?

    /// The AppKit first responder captured before the overlay took focus.
    /// Restored when the overlay is dismissed via cancel/backdrop.
    private(set) var capturedResponder: NSResponder?

    /// The window the captured responder belongs to. Held weakly so a closed
    /// window does not keep the router alive longer than the document.
    private weak var capturedWindow: NSWindow?

    /// Indicates whether any overlay is currently presented.
    var isPresented: Bool { activePresentation != nil }

    /// Presents the given flow, replacing any overlay that is already active.
    ///
    /// Capturing the first responder is idempotent for one presentation
    /// session: while any flow is active, replacement preserves the original
    /// capture (including the valid "no responder" result) so focus restoration
    /// never targets an intermediate overlay.
    ///
    /// Production entry point. The current key window is captured only when a
    /// new overlay session begins; replacements keep the original responder.
    func present(_ presentation: CommandOverlayPresentation) {
        present(presentation, in: NSApp.keyWindow)
    }

    /// Presents from an explicitly supplied document window.
    ///
    /// Passing `nil` intentionally captures no AppKit state. Keeping this
    /// distinct from the production entry point gives model-level tests a
    /// deterministic seam and avoids consulting unrelated global key windows.
    func present(
        _ presentation: CommandOverlayPresentation,
        in window: NSWindow?
    ) {
        if activePresentation == nil {
            captureResponder(in: window)
        }
        activePresentation = presentation
    }

    /// Dismisses the active presentation and restores the captured responder.
    ///
    /// Safe to call when no overlay is active (no-op).
    func dismiss() {
        activePresentation = nil
        restoreResponderIfNeeded()
    }

    /// Dismisses only if the given presentation is the active one. Used by
    /// individual flow views to cancel themselves without affecting a newer
    /// presentation that replaced them.
    func dismiss(ifMatching presentation: CommandOverlayPresentation) {
        guard activePresentation == presentation else { return }
        dismiss()
    }

    /// Dismisses the matching presentation, restores its document window, and
    /// invokes `action` only after AppKit has had a runloop turn to retire the
    /// panel. Commands selected from Command Palette use this path so
    /// key-window-gated responders (find, comment, folding, and similar
    /// editor commands) see the document window rather than the outgoing
    /// command panel.
    func dismiss(
        ifMatching presentation: CommandOverlayPresentation,
        then action: @escaping @MainActor () -> Void
    ) {
        guard activePresentation == presentation else { return }
        dismiss()
        // `dismiss()` first queues owner-window and responder restoration.
        // Use one additional turn before dispatching so SwiftUI can dismantle
        // the panel and AppKit can finish its key-window transition.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                action()
            }
        }
    }

    // MARK: - First responder capture/restore

    private func captureResponder(in window: NSWindow?) {
        guard let window else { return }
        capturedWindow = window
        // Preserve the actual responder, not only Cocoa text controls.
        // SwiftTerm's LocalProcessTerminalView and several Pine keyboard
        // responders are plain NSView subclasses; filtering them out loses
        // terminal/sidebar focus after Escape.
        capturedResponder = window.firstResponder
    }

    private func restoreResponderIfNeeded() {
        let responder = capturedResponder
        let window = capturedWindow ?? (responder as? NSView)?.window
        defer {
            capturedResponder = nil
            capturedWindow = nil
        }
        guard let window else { return }
        // Defer to the next runloop: dismissal runs inside the SwiftUI update
        // pass, and AppKit rejects `makeFirstResponder` while a responder is
        // still resigning. One runloop tick is enough for AppKit to settle.
        DispatchQueue.main.async { [weak window, weak responder] in
            guard let window else { return }
            if window.isVisible && !window.isKeyWindow {
                window.makeKey()
            }
            if let responder, window.firstResponder !== responder {
                _ = window.makeFirstResponder(responder)
            }
        }
    }
}
