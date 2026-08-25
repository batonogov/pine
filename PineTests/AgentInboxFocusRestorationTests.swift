//
//  AgentInboxFocusRestorationTests.swift
//  PineTests
//
//  Where keyboard focus lands once the Agent Inbox popover goes away (#1491).
//
//  Two halves, both pure enough to run without a window server: the rule that
//  decides whether the host takes focus back at all, and the rule that decides
//  which responder inside it is still a legitimate target.
//

import AppKit
import Testing

@testable import Pine

@Suite("Agent Inbox focus restoration rule")
@MainActor
struct AgentInboxFocusRestorationRuleTests {
    /// The whole truth table, so no combination is decided by accident.
    ///
    /// Only one row restores: the user dismissed the Inbox in place, the host
    /// window is still on screen, and Pine is still the active application.
    /// Every other row leaves focus exactly where the dismissal put it.
    @Test(
        "the host takes focus back only for an in-place dismissal it can serve",
        arguments: [
            (AgentInboxDismissalCause.userDismissedInPlace, true, true,
             AgentInboxFocusRestoration.Decision.restoreHostFocus),
            (.userDismissedInPlace, true, false, .leaveFocusAlone),
            (.userDismissedInPlace, false, true, .leaveFocusAlone),
            (.userDismissedInPlace, false, false, .leaveFocusAlone),
            (.navigatedAway, true, true, .leaveFocusAlone),
            (.navigatedAway, true, false, .leaveFocusAlone),
            (.navigatedAway, false, true, .leaveFocusAlone),
            (.navigatedAway, false, false, .leaveFocusAlone),
            (.anchorDetached, true, true, .leaveFocusAlone),
            (.anchorDetached, true, false, .leaveFocusAlone),
            (.anchorDetached, false, true, .leaveFocusAlone),
            (.anchorDetached, false, false, .leaveFocusAlone),
        ]
    )
    func focusDecisionTruthTable(
        cause: AgentInboxDismissalCause,
        hostCanTakeFocus: Bool,
        isApplicationActive: Bool,
        expected: AgentInboxFocusRestoration.Decision
    ) {
        #expect(
            AgentInboxFocusRestoration.decision(
                cause: cause,
                hostCanTakeFocus: hostCanTakeFocus,
                isApplicationActive: isApplicationActive
            ) == expected,
            """
            \(cause), canTakeFocus=\(hostCanTakeFocus), \
            active=\(isApplicationActive)
            """
        )
    }

    /// The one row that is easy to get backwards.
    ///
    /// A successful navigation or recovery has just moved the user into
    /// another project window. Returning focus to the window that hosted the
    /// popover would take it straight back off the session they asked for —
    /// the popover's own dismissal undoing the action that caused it.
    @Test("a navigating dismissal never pulls focus off its destination")
    func navigationKeepsItsDestination() {
        #expect(
            AgentInboxFocusRestoration.decision(
                cause: .navigatedAway,
                hostCanTakeFocus: true,
                isApplicationActive: true
            ) == .leaveFocusAlone
        )
    }

    /// A transient popover closes when the user clicks into another
    /// application. `makeKeyAndOrderFront` on an inactive app marks the window
    /// to become key on the next activation, so restoring here would hand
    /// Pine's window focus the moment the user comes back — after they chose
    /// to leave.
    @Test("a dismissal that left the app never reclaims focus")
    func inactiveApplicationIsLeftAlone() {
        #expect(
            AgentInboxFocusRestoration.decision(
                cause: .userDismissedInPlace,
                hostCanTakeFocus: true,
                isApplicationActive: false
            ) == .leaveFocusAlone
        )
    }

    /// A host that closed, hid, or went to the Dock while the Inbox was open
    /// is not a focus destination: raising it would resurrect a window the
    /// user has just put away.
    @Test("a host that left the screen is never raised to take focus back")
    func offScreenHostIsNeverRaised() {
        #expect(
            AgentInboxFocusRestoration.decision(
                cause: .userDismissedInPlace,
                hostCanTakeFocus: false,
                isApplicationActive: true
            ) == .leaveFocusAlone
        )
    }
}

@Suite("Agent Inbox focus restoration targets", .serialized)
@MainActor
struct AgentInboxFocusRestorationTargetTests {
    /// The ordinary case: the editor, sidebar, or terminal view that owned
    /// keyboard focus when the Inbox opened is still in its window.
    @Test("a responder still installed in the window is restorable")
    func liveResponderIsRestorable() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let view = fixture.addContentView()

        #expect(
            AgentInboxFocusRestoration.restorableResponder(
                view,
                in: fixture.window
            ) === view
        )
    }

    /// SwiftUI rebuilds view trees freely, and the Inbox stays open across
    /// those passes. `makeFirstResponder` on a demounted view moves keyboard
    /// focus to an object that is no longer on screen — the window then has a
    /// first responder the user cannot see or type into.
    @Test("a responder demounted while the Inbox was open is refused")
    func demountedResponderIsRefused() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let view = fixture.addContentView()
        view.removeFromSuperview()

        #expect(
            AgentInboxFocusRestoration.restorableResponder(
                view,
                in: fixture.window
            ) == nil
        )
    }

    /// The multi-window guard. A view that moved into another window belongs
    /// to that window's responder chain now, and focusing it from here would
    /// be this window reaching into another one.
    @Test("a responder that moved to another window is refused")
    func responderInAnotherWindowIsRefused() {
        let fixture = Fixture()
        let other = Fixture()
        defer {
            fixture.cleanup()
            other.cleanup()
        }
        let view = other.addContentView()

        #expect(
            AgentInboxFocusRestoration.restorableResponder(
                view,
                in: fixture.window
            ) == nil
        )
    }

    /// "Nothing was focused" is a real state — a window whose first responder
    /// is the window itself. It must not be restored as if it were a view,
    /// because raising the window already produces exactly that.
    @Test("the window itself is not a restoration target")
    func theWindowItselfIsNotATarget() {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        #expect(
            AgentInboxFocusRestoration.restorableResponder(
                fixture.window,
                in: fixture.window
            ) == nil
        )
    }

    @Test("nothing to restore stays nothing")
    func nilResponderStaysNil() {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        #expect(
            AgentInboxFocusRestoration.restorableResponder(
                nil,
                in: fixture.window
            ) == nil
        )
    }

    /// The case a naive `firstResponder` round-trip gets wrong.
    ///
    /// While the user is typing in a text field — project search, inline
    /// rename, the branch filter — the window's first responder is the shared
    /// field editor, not the field. AppKit lends that one text view to
    /// whichever control is editing, so restoring the editor object hands
    /// focus to a view the window may have already re-lent elsewhere. The
    /// control that hosts it is the stable target, and AppKit re-installs the
    /// editor into it.
    @Test("a field editor is restored through the control that hosts it")
    func fieldEditorIsRestoredThroughItsControl() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let field = fixture.addTextField()
        let editor = fixture.installFieldEditor(in: field)

        #expect(
            AgentInboxFocusRestoration.restorableResponder(
                editor,
                in: fixture.window
            ) === field
        )
    }

    /// The same rule with nothing to redirect to. A field editor that is not
    /// inside a control has no stable owner, so focus is left alone rather
    /// than pinned to a text view AppKit is free to move.
    @Test("a field editor with no control behind it is refused")
    func fieldEditorWithoutAControlIsRefused() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let editor = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 80, height: 20)
        )
        editor.isFieldEditor = true
        fixture.window.contentView?.addSubview(editor)

        #expect(
            AgentInboxFocusRestoration.restorableResponder(
                editor,
                in: fixture.window
            ) == nil
        )
    }

    /// A plain `NSTextView` — Pine's own editor — is not a field editor and is
    /// restored directly. Without the `isFieldEditor` test the rule would
    /// redirect every editor focus through a delegate that is not a view.
    @Test("a document text view is restored directly, not through a delegate")
    func documentTextViewIsRestoredDirectly() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        fixture.window.contentView?.addSubview(textView)

        #expect(
            AgentInboxFocusRestoration.restorableResponder(
                textView,
                in: fixture.window
            ) === textView
        )
    }

    // MARK: - The NSWindow conformance

    /// `canTakeFocus` is the production reading of "this host is still a place
    /// focus can go". An off-screen window — closed or hidden — is not.
    @Test("an off-screen window reports it cannot take focus")
    func offScreenWindowCannotTakeFocus() {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        #expect(!fixture.window.isVisible)
        #expect(!fixture.window.canTakeFocus)
    }

    /// The other side of the same rule, so "cannot take focus" is not simply
    /// what this type always answers.
    @Test("a window on screen reports it can take focus")
    func onScreenWindowCanTakeFocus() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.window.orderFront(nil)

        #expect(fixture.window.canTakeFocus)
    }

    /// The deliberate divergence from Inbox host *selection*.
    ///
    /// Presenting the Inbox accepts a window in the Dock and deminiaturizes it
    /// first (#1507), which shows the user where the work landed. Returning
    /// focus after a dismissal shows nothing, so pulling a window the user
    /// minimized *while the Inbox was open* back out would undo that choice
    /// silently. `isVisible` alone cannot express this — AppKit reports
    /// `false` for a Dock window and for a closed one alike.
    @Test("a window the user sent to the Dock cannot take focus back")
    func dockedWindowCannotTakeFocus() {
        let window = DockableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        #expect(window.canTakeFocus)

        window.isInDock = true

        #expect(window.isMiniaturized)
        #expect(!window.canTakeFocus)
    }

    /// Returning focus orders the host front even when nothing focusable was
    /// recorded. A host raised past an auxiliary window, or restored from the
    /// Dock, is not necessarily the window AppKit hands key back to when a
    /// transient popover closes.
    @Test("returning focus orders the host window front")
    func returningFocusOrdersTheHostFront() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        #expect(!fixture.window.isVisible)

        fixture.window.returnFocus(to: nil)

        #expect(fixture.window.isVisible)
    }

    /// The window's own capture reads through the same restorability rule, so
    /// a window with nothing focused records nothing rather than recording
    /// itself.
    @Test("a window with nothing focused captures nothing")
    func idleWindowCapturesNothing() {
        let fixture = Fixture()
        defer { fixture.cleanup() }

        #expect(fixture.window.firstResponder === fixture.window)
        #expect(fixture.window.captureFocusedResponder() == nil)
    }

    /// The round trip production actually performs: capture the focused view
    /// before presenting, hand focus to something else, and put it back.
    @Test("a captured view is the one focus returns to")
    func capturedViewIsReturnedTo() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let view = fixture.addFocusableView()
        let other = fixture.addFocusableView()

        #expect(fixture.window.makeFirstResponder(view))
        let captured = try #require(fixture.window.captureFocusedResponder())
        #expect(captured === view)

        #expect(fixture.window.makeFirstResponder(other))
        fixture.window.returnFocus(to: captured)

        #expect(fixture.window.firstResponder === view)
    }

    /// A view that went away while the Inbox was open must not be forced back
    /// into the responder chain; the window is simply left as it is.
    @Test("returning focus to a demounted view changes nothing")
    func returningToADemountedViewIsANoOp() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let view = fixture.addFocusableView()
        let survivor = fixture.addFocusableView()

        #expect(fixture.window.makeFirstResponder(view))
        view.removeFromSuperview()
        #expect(fixture.window.makeFirstResponder(survivor))

        fixture.window.returnFocus(to: view)

        #expect(fixture.window.firstResponder === survivor)
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let window: NSWindow

        init() {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSView(
                frame: NSRect(x: 0, y: 0, width: 320, height: 240)
            )
        }

        @discardableResult
        func addContentView() -> NSView {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            window.contentView?.addSubview(view)
            return view
        }

        @discardableResult
        func addFocusableView() -> NSView {
            let view = FocusableView(
                frame: NSRect(x: 0, y: 0, width: 40, height: 20)
            )
            window.contentView?.addSubview(view)
            return view
        }

        @discardableResult
        func addTextField() -> NSTextField {
            let field = NSTextField(
                frame: NSRect(x: 0, y: 0, width: 80, height: 20)
            )
            window.contentView?.addSubview(field)
            return field
        }

        /// Reproduces the hierarchy AppKit builds while a control is being
        /// edited — the shared field editor nested inside the control's own
        /// clip view — without depending on a key window to start editing.
        func installFieldEditor(in control: NSControl) -> NSTextView {
            let clip = NSClipView(frame: control.bounds)
            let editor = NSTextView(frame: control.bounds)
            editor.isFieldEditor = true
            clip.documentView = editor
            control.addSubview(clip)
            return editor
        }

        func cleanup() {
            window.orderOut(nil)
        }
    }

    /// A view AppKit will actually hand first-responder status to without a
    /// key window behind it.
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// A window that can be put in the Dock without a window server, matching
    /// what AppKit reports there: `isMiniaturized == true` and
    /// `isVisible == false`. Measured on macOS 27.0 and recorded in
    /// ``WindowRoutingReach``.
    private final class DockableWindow: NSWindow {
        var isInDock = false

        override var isMiniaturized: Bool { isInDock }

        override var isVisible: Bool { isInDock ? false : super.isVisible }
    }
}
