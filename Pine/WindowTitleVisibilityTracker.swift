//
//  WindowTitleVisibilityTracker.swift
//  Pine
//
//  Hides the window's visible title for good while NSWindow.title keeps
//  naming the window for the system.
//

import AppKit
import SwiftUI

/// Hides the title-bar text permanently: `NSWindow.title` stays set — it is
/// the window's identity for the Window menu, Mission Control, and window
/// cycling — but the title bar never renders it. On the strip, identity is
/// split the Safari way: the switcher pill names the project, the branch
/// toolbar button names the checkout, and editor tabs name files.
///
/// The hiding costs the whole native title block, subtitle and document
/// proxy icon included (verified empirically: `titleVisibility = .hidden`
/// removes both text fields from the theme frame). That is exactly why the
/// branch moved out of `.navigationSubtitle` into a first-class toolbar
/// control, and why the proxy icon's Cmd+click path menu is gone — an
/// accepted trade-off; `RepresentedFileTracker` still sets `representedURL`
/// so the rest of AppKit keeps a correct file reference.
struct WindowTitleVisibilityTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleVisibilityAnchorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Applies the hidden visibility as soon as the view sits in a window.
///
/// A plain `updateNSView` write races attachment (`nsView.window` is still
/// nil), and with a constant value no later update would repair the loss —
/// the first iteration of this tracker shipped exactly that bug. Replaying
/// from `viewDidMoveToWindow` (the `WindowCaptureSentinel` pattern) makes
/// the application reliable at window creation, and assigning `title`
/// afterwards never resets `titleVisibility` (pinned by
/// `WindowTitleVisibilityTrackerTests`).
final class TitleVisibilityAnchorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.titleVisibility != .hidden else { return }
        window.titleVisibility = .hidden
    }
}
