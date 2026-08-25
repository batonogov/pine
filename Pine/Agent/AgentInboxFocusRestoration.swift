//
//  AgentInboxFocusRestoration.swift
//  Pine
//
//  Where keyboard focus goes when the Agent Inbox popover closes (#1491).
//

import AppKit

/// Why an Inbox popover went away.
///
/// It is the only thing that decides whether the window that hosted it takes
/// keyboard focus back, so it is recorded per presentation rather than
/// inferred at close time — by then the popover has already been key and the
/// window system no longer remembers who asked.
enum AgentInboxDismissalCause: Equatable {
    /// Escape, a click outside, the toolbar button, ⇧⌘I. The user is still
    /// exactly where they were, so the host takes focus back.
    case userDismissedInPlace
    /// A successful navigation or recovery moved the user to another session
    /// (``AgentInboxActionOutcome/dismiss``). The window they were sent to
    /// owns focus now.
    case navigatedAway
    /// The anchor was demounted with the popover open — the window is closing,
    /// or SwiftUI rebuilt the toolbar. There is no host left to return to.
    case anchorDetached
}

/// The window a closing Inbox popover may hand keyboard focus back to,
/// reduced to what the anchor does with it.
///
/// `NSWindow` conforms, so production restores focus in the very window the
/// popover was anchored in. Tests substitute a double: the unit test host is a
/// background application with no key window, where `makeKeyAndOrderFront` and
/// first-responder changes driven by key status cannot be observed at all.
@MainActor
protocol AgentInboxFocusHost: AnyObject {
    /// False once the host has left the screen — closed, hidden, or
    /// miniaturized — while the Inbox was open. Focus is never forced into one.
    var canTakeFocus: Bool { get }
    /// The responder worth returning to when the popover closes, read before
    /// the popover takes key.
    func captureFocusedResponder() -> NSResponder?
    /// Makes the host key again and puts keyboard focus back on `responder`
    /// when it is still a legitimate target inside this window.
    func returnFocus(to responder: NSResponder?)
}

extension NSWindow: AgentInboxFocusHost {
    /// The same on-screen rule every other in-place routing decision uses. A
    /// window in the Dock is deliberately refused here even though the Inbox
    /// *presentation* path accepts one (#1507): presenting deminiaturizes its
    /// host first and shows the user where the work landed, while pulling a
    /// window out of the Dock merely to give it focus back undoes a choice the
    /// user made while the popover was open.
    var canTakeFocus: Bool {
        WindowRoutingReach.onScreenOnly.admitsWindow(
            isVisible: isVisible,
            isMiniaturized: isMiniaturized
        )
    }

    func captureFocusedResponder() -> NSResponder? {
        AgentInboxFocusRestoration.restorableResponder(
            firstResponder,
            in: self
        )
    }

    func returnFocus(to responder: NSResponder?) {
        // Ordering the host front is the whole restoration when nothing
        // focusable was recorded: AppKit already returns key to a transient
        // popover's parent, and this makes that explicit for the paths — a
        // deminiaturized host, a host raised past an auxiliary window — where
        // the popover's parent is not where the user came from.
        makeKeyAndOrderFront(nil)
        guard let target = AgentInboxFocusRestoration.restorableResponder(
            responder,
            in: self
        ) else { return }
        makeFirstResponder(target)
    }
}

/// The two rules behind returning focus after the Inbox closes: whether to
/// return it at all, and what inside the host is still a legitimate target.
enum AgentInboxFocusRestoration {
    enum Decision: Equatable {
        /// Make the host key again and put focus back where it was.
        case restoreHostFocus
        /// Leave focus exactly where the dismissal put it.
        case leaveFocusAlone
    }

    /// - Parameters:
    ///   - cause: why the popover closed. Only an in-place dismissal restores;
    ///     a navigation is the user asking to be somewhere else, and a detach
    ///     has no host left.
    ///   - hostCanTakeFocus: whether the host is still on screen. A window the
    ///     user closed, hid, or minimized while the Inbox was open must not be
    ///     ordered back to the front to receive focus.
    ///   - isApplicationActive: whether Pine is still frontmost. A `.transient`
    ///     popover also closes when the user clicks into another application,
    ///     and `makeKeyAndOrderFront` on an inactive app marks the window to
    ///     become key on the next activation — so restoring here would take
    ///     focus the moment the user comes back, after they chose to leave.
    static func decision(
        cause: AgentInboxDismissalCause,
        hostCanTakeFocus: Bool,
        isApplicationActive: Bool
    ) -> Decision {
        guard cause == .userDismissedInPlace,
              hostCanTakeFocus,
              isApplicationActive else { return .leaveFocusAlone }
        return .restoreHostFocus
    }

    /// The responder focus may be handed to inside `window`, or `nil` when
    /// there is none worth restoring.
    ///
    /// Two things are filtered out. A view that is no longer in this exact
    /// window: SwiftUI rebuilds view trees freely and the Inbox stays open
    /// across those passes, so a recorded view can be demounted or moved to
    /// another window by the time the popover closes, and
    /// `makeFirstResponder` on it would put keyboard focus somewhere the user
    /// cannot see. And a field editor: while a control is being edited the
    /// window's first responder is the one shared `NSTextView` AppKit lends
    /// out, not the control, so the control it is currently installed in is
    /// the stable target — AppKit re-lends the editor to it.
    ///
    /// The window itself is not a target. That is simply "nothing was
    /// focused", which ``AgentInboxFocusHost/returnFocus(to:)`` already
    /// produces by ordering the window front.
    static func restorableResponder(
        _ responder: NSResponder?,
        in window: NSWindow
    ) -> NSResponder? {
        guard let view = responder as? NSView, view.window === window else {
            return nil
        }
        guard let editor = view as? NSTextView, editor.isFieldEditor else {
            return view
        }
        return enclosingControl(of: editor)
    }

    /// The control a field editor is currently installed in. AppKit nests the
    /// shared editor inside the control's own clip view, so the owner is found
    /// by walking up — and every ancestor of a view already established to be
    /// in `window` is in that same window.
    private static func enclosingControl(of view: NSView) -> NSControl? {
        var candidate = view.superview
        while let current = candidate {
            if let control = current as? NSControl { return control }
            candidate = current.superview
        }
        return nil
    }
}
