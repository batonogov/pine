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

/// Minimal first-responder surface used by the command-overlay router.
///
/// Keeping the session bookkeeping behind this protocol lets the router tests
/// exercise deferred restoration without constructing and closing real AppKit
/// windows inside the concurrently running Swift Testing host.
@MainActor
protocol CommandOverlayResponderHost: AnyObject {
    var commandOverlayFirstResponder: NSResponder? { get }
    func restoreCommandOverlayResponder(_ responder: NSResponder?)
    func postCommandOverlayAnnouncement(_ announcement: String)
}

extension NSWindow: CommandOverlayResponderHost {
    var commandOverlayFirstResponder: NSResponder? {
        firstResponder
    }

    func restoreCommandOverlayResponder(_ responder: NSResponder?) {
        guard CommandOverlayFocusRestorationPolicy.shouldRestore(
            owner: self,
            keyWindow: NSApp.keyWindow
        ) else {
            return
        }
        if isVisible && !isKeyWindow {
            makeKey()
        }
        if let responder, firstResponder !== responder {
            makeFirstResponder(responder)
        }
    }

    func postCommandOverlayAnnouncement(_ announcement: String) {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement]
        )
    }
}

/// Prevents a deferred overlay dismissal from stealing focus back from a
/// different project window.
///
/// Clicking project B while project A's panel is key first resigns A's panel,
/// then runs responder restoration on the next runloop turn. At that point B
/// is already key and must remain so. A nil key document still permits the
/// normal Escape/backdrop path to make the original owner key again.
@MainActor
enum CommandOverlayFocusRestorationPolicy {
    static func shouldRestore(
        owner: NSWindow,
        keyWindow: NSWindow?
    ) -> Bool {
        permitsRestore(
            owner: owner,
            activeDocument: CommandOverlayOwnerResolver.documentWindow(
                for: keyWindow
            )
        )
    }

    nonisolated static func permitsRestore<Window: AnyObject>(
        owner: Window,
        activeDocument: Window?
    ) -> Bool {
        activeDocument == nil || activeDocument === owner
    }
}

/// Observable router that owns the active command overlay presentation for a
/// single project window.
@MainActor
@Observable
final class CommandOverlayRouter {

    /// The presentation currently shown, or `nil` when no overlay is active.
    private(set) var activePresentation: CommandOverlayPresentation? {
        didSet {
            if oldValue != activePresentation {
                announcementGeneration &+= 1
            }
        }
    }

    /// The AppKit first responder captured before the overlay took focus.
    /// Restored when the overlay is dismissed via cancel/backdrop.
    @ObservationIgnored
    private(set) var capturedResponder: NSResponder?

    /// The host the captured responder belongs to. Held weakly so a closed
    /// document window does not keep the router alive longer than its project.
    @ObservationIgnored
    private weak var capturedHost: (any CommandOverlayResponderHost)?

    /// Identifies the active presentation session. A new session invalidates
    /// any responder restoration queued by an earlier dismissal.
    @ObservationIgnored
    private var sessionGeneration = 0

    /// Identifies the exact mounted presentation, including replacements
    /// within one focus-restoration session. Unlike `sessionGeneration`, this
    /// deliberately changes for A → B → A so an old sink cannot become valid
    /// again when its enum case reappears.
    @ObservationIgnored
    private var announcementGeneration = 0

    /// Resolves the active document host only when a new overlay session starts.
    @ObservationIgnored
    private let responderHostProvider:
        @MainActor () -> (any CommandOverlayResponderHost)?

    init(
        responderHostProvider:
            @escaping @MainActor () -> (any CommandOverlayResponderHost)? = {
                nil
            }
    ) {
        self.responderHostProvider = responderHostProvider
    }

    /// Indicates whether any overlay is currently presented.
    var isPresented: Bool { activePresentation != nil }

    /// Presents the given flow, replacing any overlay that is already active.
    ///
    /// Capturing the first responder is idempotent for one presentation
    /// session: while any flow is active, replacement preserves the original
    /// capture (including the valid "no responder" result) so focus restoration
    /// never targets an intermediate overlay.
    ///
    /// The current key window is captured only when a new overlay session
    /// begins; replacements keep the original responder.
    func present(_ presentation: CommandOverlayPresentation) {
        if activePresentation == nil {
            sessionGeneration &+= 1
            captureResponder(in: responderHostProvider())
        }
        activePresentation = presentation
    }

    /// Captures the concrete document window immediately before its command
    /// panel becomes key.
    ///
    /// Production presentation resolves this host from the attachment view's
    /// `window`, never from `NSApp.keyWindow`. The latter may belong to a
    /// different project when a targeted command is delivered to a background
    /// window. Tests may still inject a responder host through the initializer;
    /// an existing capture always wins so replacement flows preserve the
    /// original session.
    func preparePresentation(
        in host: (any CommandOverlayResponderHost)?
    ) {
        guard activePresentation != nil, capturedHost == nil else { return }
        captureResponder(in: host)
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

    /// Dismisses after focus has already moved outside the command panel.
    ///
    /// `NSPanel.windowDidResignKey` represents a real external focus
    /// transition: the user may have clicked another editor, sidebar, terminal,
    /// or project window. Restoring the pre-overlay responder in this path
    /// would overwrite that click target. Escape, backdrop, and explicit
    /// cancellation continue to use ``dismiss()`` and restore normally.
    func dismissForExternalFocusChange(
        ifMatching presentation: CommandOverlayPresentation
    ) {
        guard activePresentation == presentation else { return }
        activePresentation = nil
        sessionGeneration &+= 1
        capturedResponder = nil
        capturedHost = nil
    }

    /// Completes a flow whose action deliberately moves focus to a new
    /// destination.
    ///
    /// Agent Attention uses this after selecting a terminal. Restoring the
    /// responder captured before presentation would race the explicit
    /// terminal focus request and send keyboard input back to the old editor.
    /// A stale flow cannot complete a newer replacement.
    func complete(
        ifMatching presentation: CommandOverlayPresentation
    ) {
        guard activePresentation == presentation else { return }
        activePresentation = nil
        sessionGeneration &+= 1
        capturedResponder = nil
        capturedHost = nil
    }

    /// Posts a VoiceOver announcement to the exact document owner captured
    /// for this presentation. Fails closed until the attachment view resolves
    /// an owner and never falls back to `NSApp.keyWindow`.
    @discardableResult
    func announce(_ announcement: String) -> Bool {
        guard activePresentation != nil, let capturedHost else {
            return false
        }
        capturedHost.postCommandOverlayAnnouncement(announcement)
        return true
    }

    /// Posts only while the originating flow is still active. Search-result
    /// announcements are intentionally delayed, so a replaced overlay must not
    /// speak through the replacement's still-captured document owner.
    @discardableResult
    func announce(
        _ announcement: String,
        ifMatching presentation: CommandOverlayPresentation
    ) -> Bool {
        guard activePresentation == presentation else { return false }
        return announce(announcement)
    }

    /// Captures both the flow and its exact presentation generation. Two
    /// consecutive Quick Open sessions have the same enum value, but delayed
    /// results from the dismissed owner must still fail closed after reopen.
    func announcementSink(
        for presentation: CommandOverlayPresentation
    ) -> CommandOverlayAnnouncementSink {
        let capturedGeneration = announcementGeneration
        return { [weak self] announcement in
            guard let self,
                  self.announcementGeneration == capturedGeneration else {
                return false
            }
            return self.announce(
                announcement,
                ifMatching: presentation
            )
        }
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
        let dispatchGeneration = sessionGeneration
        // `dismiss()` first queues owner-window and responder restoration.
        // Use one additional turn before dispatching so SwiftUI can dismantle
        // the panel and AppKit can finish its key-window transition.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == dispatchGeneration,
                      self.activePresentation == nil else {
                    return
                }
                action()
            }
        }
    }

    // MARK: - First responder capture/restore

    private func captureResponder(
        in host: (any CommandOverlayResponderHost)?
    ) {
        guard capturedHost == nil, let host else { return }
        capturedHost = host
        // Preserve the actual responder, not only Cocoa text controls.
        // SwiftTerm's LocalProcessTerminalView and several Pine keyboard
        // responders are plain NSView subclasses; filtering them out loses
        // terminal/sidebar focus after Escape.
        capturedResponder = host.commandOverlayFirstResponder
    }

    private func restoreResponderIfNeeded() {
        let responder = capturedResponder
        let host = capturedHost
        let restoringGeneration = sessionGeneration
        defer {
            capturedResponder = nil
            capturedHost = nil
        }
        guard host != nil else { return }
        // Defer to the next runloop: dismissal runs inside the SwiftUI update
        // pass, and AppKit rejects `makeFirstResponder` while a responder is
        // still resigning. One runloop tick is enough for AppKit to settle.
        DispatchQueue.main.async { [weak self, weak host, weak responder] in
            guard let self,
                  self.sessionGeneration == restoringGeneration,
                  self.activePresentation == nil,
                  let host else {
                return
            }
            host.restoreCommandOverlayResponder(responder)
        }
    }
}
