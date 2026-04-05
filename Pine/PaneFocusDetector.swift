//
//  PaneFocusDetector.swift
//  Pine
//
//  Detects mouse-down events on any pane and sets it as the active pane.
//

import SwiftUI

// MARK: - Pane Focus Detector

/// Detects mouse-down events on any pane and sets it as the active pane.
/// Uses `NSView.hitTest`-based approach instead of `.onTapGesture`, which
/// would block clicks on the code editor and tab bar buttons.
struct PaneFocusDetector: NSViewRepresentable {
    let paneID: PaneID
    let paneManager: PaneManager

    func makeNSView(context: Context) -> PaneFocusNSView {
        PaneFocusNSView(paneID: paneID, paneManager: paneManager)
    }

    func updateNSView(_ nsView: PaneFocusNSView, context: Context) {
        nsView.paneID = paneID
        nsView.paneManager = paneManager
    }
}

/// NSView subclass that overrides `mouseDown` to detect clicks within this
/// pane and set it as active. Using `mouseDown` instead of a local event
/// monitor means only one handler fires per pane (not N monitors for N panes).
final class PaneFocusNSView: NSView {
    var paneID: PaneID
    weak var paneManager: PaneManager?

    init(paneID: PaneID, paneManager: PaneManager) {
        self.paneID = paneID
        self.paneManager = paneManager
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            paneManager?.activePaneID = paneID
        }
        super.mouseDown(with: event)
    }

    /// Accept first mouse so clicks activate the pane even when the window
    /// is in the background (consistent with Xcode split pane behavior).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
