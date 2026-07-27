//
//  DialogPresentationContext.swift
//  Pine
//
//  Resolves the NSWindow that owns a document dialog so alerts, open/save
//  panels, and confirmation sheets attach to a single project window instead
//  of running application-modal (issue #1241).
//
//  Pine is multiwindow: a save failure, unsaved-change decision, or file
//  picker in one project must not block unrelated project windows. Every
//  dialog flow resolves a presentation anchor through this type before
//  showing UI. When no anchor is available (headless tests, background
//  dispatch), the modal `runModal()` fallback is used so behavior is
//  preserved without a window.
//

import AppKit

/// The window (or absence of one) that a dialog should attach to.
///
/// Carried through close, save, open, external-change, and task flows so
/// each dialog is scoped to its originating project window. Sendable so it
/// can cross actor boundaries safely; the wrapped `NSWindow` is only ever
/// touched on the main actor.
struct DialogPresentationContext: Sendable {
    /// The owning project window. `nil` when no window is available —
    /// callers fall back to the application-modal path.
    private let window: NSWindow?

    /// Creates a context bound to the given window. Pass `nil` when the
    /// initiating window is unknown (tests, background dispatch).
    init(window: NSWindow?) {
        self.window = window
    }

    /// A context with no attached window. Dialogs presented against it
    /// fall back to application-modal `runModal()`.
    static let unscoped = DialogPresentationContext(window: nil)

    /// The resolved window, or `nil` if none is attached.
    var nsWindow: NSWindow? { window }
}

@MainActor
enum DialogPresenter {
    /// Resolves the key project window for the currently focused project.
    /// Returns `nil` if no project window is key (e.g. only the Welcome
    /// window or Settings is visible).
    static func keyProjectWindow() -> NSWindow? {
        guard let window = NSApp.keyWindow else { return nil }
        // Only treat actual project windows (those with a CloseDelegate) as
        // dialog anchors. The Welcome window and Settings panels are excluded
        // so a dialog never attaches to the wrong surface.
        guard window.delegate is CloseDelegate else { return nil }
        return window
    }

    /// Convenience: a context anchored to the key project window, or
    /// `.unscoped` if none exists.
    static func forKeyProject() -> DialogPresentationContext {
        DialogPresentationContext(window: keyProjectWindow())
    }
}

// MARK: - NSAlert + window-scoped sheet

extension NSAlert {
    /// Presents this ad-hoc `NSAlert` as a sheet attached to the window
    /// resolved from `context`. Falls back to application-modal `runModal()`
    /// when no window is available (issue #1241).
    ///
    /// Use ``AlertTemplate/runSheet(on:messageText:informativeText:)`` for
    /// templated alerts; this extension is for the few ad-hoc `NSAlert`
    /// constructions that do not map to a template (user-task confirmation).
    @discardableResult
    func runSheet(on context: DialogPresentationContext) async -> NSApplication.ModalResponse {
        guard let window = context.nsWindow, window.isVisible else {
            return runModal()
        }
        return await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}

// MARK: - NSSavePanel / NSOpenPanel + window-scoped sheet

extension NSSavePanel {
    /// Presents this save panel as a sheet attached to the window resolved
    /// from `context`. Returns `.cancel` if the user cancels or no window is
    /// available. Falls back to application-modal `runModal()` when the
    /// context has no window (issue #1241).
    func runSheet(on context: DialogPresentationContext) async -> NSApplication.ModalResponse {
        guard let window = context.nsWindow, window.isVisible else {
            return runModal()
        }
        return await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
