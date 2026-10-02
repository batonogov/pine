//
//  WindowTitleVisibilityTracker.swift
//  Pine
//
//  Mirrors WindowChromePresentation.showsTitle onto NSWindow.titleVisibility.
//

import AppKit
import SwiftUI

/// Hides the title-bar text without clearing `NSWindow.title`: the string
/// stays the window's identity for the Window menu, Mission Control, and
/// window cycling while the title bar stops repeating what the switcher
/// pill already says.
struct WindowTitleVisibilityTracker: NSViewRepresentable {
    let showsTitle: Bool

    func makeNSView(context: Context) -> NSView {
        TitleVisibilityAnchorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TitleVisibilityAnchorView)?.showsTitle = showsTitle
    }
}

/// Applies the last requested visibility as soon as — and whenever — the
/// view sits in a window.
///
/// `updateNSView` can run before the representable is attached, where
/// `nsView.window` is nil and a direct write would vanish. In the scenario
/// that matters — a window opening straight into a project with no file —
/// the value never changes afterwards, so no second update would ever
/// repair the loss and the duplicate title stayed visible forever.
/// Replaying from `viewDidMoveToWindow` (the pattern
/// `WindowCaptureSentinel` uses) closes that race; the `didSet` covers the
/// reverse one, an update arriving after the window is already there.
///
/// No observation of `NSWindow.title`: assigning `title` does not touch
/// `titleVisibility` in AppKit, and SwiftUI's `.navigationTitle` machinery
/// has no code path that writes it — pinned by
/// `WindowTitleVisibilityTrackerTests`.
final class TitleVisibilityAnchorView: NSView {
    /// Last value SwiftUI asked for. Reapplied on every change and on every
    /// window attachment.
    var showsTitle = true {
        didSet { applyTitleVisibility() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTitleVisibility()
    }

    private func applyTitleVisibility() {
        guard let window else { return }
        let visibility: NSWindow.TitleVisibility = showsTitle
            ? .visible
            : .hidden
        guard window.titleVisibility != visibility else { return }
        window.titleVisibility = visibility
    }
}
