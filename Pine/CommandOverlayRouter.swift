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
    /// Capturing the first responder is idempotent: if a responder was already
    /// captured by a previous (still-active) presentation, it is preserved so
    /// that focus restoration always targets the editor, not an intermediate
    /// overlay that was replaced.
    func present(_ presentation: CommandOverlayPresentation) {
        if capturedResponder == nil {
            captureResponder()
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

    // MARK: - First responder capture/restore

    private func captureResponder() {
        guard let window = NSApp.keyWindow ?? capturedWindow else { return }
        capturedWindow = window
        // Only capture text-editing responders (editor, terminal, search field).
        // Capturing arbitrary responders (e.g. buttons) can cause focus to jump
        // unexpectedly on restore.
        let responder = window.firstResponder
        if responder is NSTextView || responder is NSControl {
            capturedResponder = responder
        }
    }

    private func restoreResponderIfNeeded() {
        defer {
            capturedResponder = nil
            capturedWindow = nil
        }
        guard let responder = capturedResponder,
              let window = capturedWindow ?? (responder as? NSView)?.window,
              window.firstResponder !== responder else {
            return
        }
        // Defer to the next runloop: dismissal runs inside the SwiftUI update
        // pass, and AppKit rejects `makeFirstResponder` while a responder is
        // still resigning. One runloop tick is enough for AppKit to settle.
        DispatchQueue.main.async { [weak window, weak responder] in
            guard let window, let responder else { return }
            _ = window.makeFirstResponder(responder)
        }
    }
}
