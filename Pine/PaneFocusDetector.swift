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

/// NSView subclass that uses a local event monitor to detect mouse-down events
/// within this view's frame and set the corresponding pane as active.
final class PaneFocusNSView: NSView {
    var paneID: PaneID
    weak var paneManager: PaneManager?
    /// nonisolated(unsafe): accessed from deinit (nonisolated) to remove event monitor.
    nonisolated(unsafe) private var monitor: Any?

    init(paneID: PaneID, paneManager: PaneManager) {
        self.paneID = paneID
        self.paneManager = paneManager
        super.init(frame: .zero)
        installMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
            return event // Always pass through — never consume
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let window = self.window, event.window === window else { return }
        let locationInView = convert(event.locationInWindow, from: nil)
        guard bounds.contains(locationInView) else { return }
        MainActor.assumeIsolated {
            paneManager?.activePaneID = paneID
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
