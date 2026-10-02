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
/// pill already says. Same one-window bridge pattern as
/// ``RepresentedFileTracker``.
struct WindowTitleVisibilityTracker: NSViewRepresentable {
    let showsTitle: Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.titleVisibility = showsTitle ? .visible : .hidden
    }
}
