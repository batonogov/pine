//
//  QuickLookPreviewView.swift
//  Pine
//
//  Created by Claude on 15.03.2026.
//

import QuickLookUI
import SwiftUI

/// Wraps QLPreviewView to display non-text files (images, PDFs, etc.) inside an editor tab.
///
/// On macOS 26, QuickLookUI can crash (`EXC_BAD_ACCESS` in `_updateOverlayBorder`) when
/// `previewItem` is assigned before the view is fully installed in a window hierarchy.
/// To work around this framework bug (#673), we defer the initial `previewItem` assignment
/// to the next runloop iteration via the Coordinator, giving AppKit time to finish
/// embedding the view.
struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> QLPreviewView {
        // swiftlint:disable:next force_unwrapping
        let view = QLPreviewView(frame: .zero, style: .normal)!
        context.coordinator.currentURL = url
        // Defer previewItem assignment to the next runloop iteration so the view
        // is fully embedded in the window hierarchy before QuickLookUI attempts
        // its internal overlay/border update (#673).
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil else { return }
            view.previewItem = PreviewItem(url: url)
        }
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        // Guard against updating a QLPreviewView that has been closed/deactivated
        // or when the preview item would be nil — prevents crash on tab switching (#618)
        guard nsView.window != nil else { return }

        let current = context.coordinator.currentURL
        if current != url {
            context.coordinator.currentURL = url
            let newItem = PreviewItem(url: url)
            guard newItem.previewItemURL != nil else { return }
            // Defer update as well to avoid the same _updateOverlayBorder crash (#673)
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, nsView.window != nil else { return }
                nsView.previewItem = newItem
            }
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: Coordinator) {
        // Clear the preview item before the view is torn down to prevent
        // QuickLookUI from accessing stale internal state during deallocation (#673).
        nsView.previewItem = nil
    }

    /// Coordinator tracks the currently-requested URL so we can detect changes
    /// without reading back from `QLPreviewView.previewItem` (which may be stale
    /// due to deferred assignment).
    final class Coordinator {
        var currentURL: URL?
    }
}

/// Simple QLPreviewItem wrapper for a file URL.
class PreviewItem: NSObject, QLPreviewItem {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    var previewItemURL: URL? { url }
}
