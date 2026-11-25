//
//  EditorContainerViews.swift
//  Pine
//
//  Extracted from CodeEditorView.swift on 2026-04-09 (issue #755).
//
//  Hosts EditorContainerView — the NSView that lays out the scroll view and
//  LineNumberView without relying on autoresizingMask.
//
//  Also hosts GoToRequest — the unique navigation request value used by
//  CodeEditorView's updateNSView to scroll to a specific offset exactly once.
//

import AppKit

// MARK: - Editor container that manages scroll view + gutter layout

/// Custom container view that lays out the scroll view and line-number gutter.
final class EditorContainerView: NSView {
    // Match NSScrollView's flipped coordinate system.
    override var isFlipped: Bool { true }
    let destinationFocusCoordinator = AppKitFocusRequestCoordinator()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        destinationFocusCoordinator.hostDidMoveToWindow(self)
    }

    override func layout() {
        super.layout()
        for sub in subviews {
            if sub is NSScrollView {
                sub.frame = NSRect(
                    x: 0, y: 0,
                    width: bounds.width,
                    height: bounds.height
                )
            } else {
                sub.frame = NSRect(
                    x: 0, y: 0,
                    width: sub.frame.width,
                    height: bounds.height
                )
            }
        }
    }
}

// MARK: - Navigation request

/// A unique navigation request so each "go to" action is processed exactly once.
/// Each instance gets a unique `id`, so two requests to the same offset are distinct.
struct GoToRequest {
    let offset: Int
    let id: UUID = UUID()
}
