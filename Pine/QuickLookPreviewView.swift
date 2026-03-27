//
//  QuickLookPreviewView.swift
//  Pine
//
//  Created by Claude on 15.03.2026.
//

import QuickLookUI
import SwiftUI

/// Wraps QLPreviewView to display non-text files (images, PDFs, etc.) inside an editor tab.
struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // swiftlint:disable:next force_unwrapping
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = PreviewItem(url: url)
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        // Guard against updating a QLPreviewView that has been closed/deactivated
        // or when the preview item would be nil — prevents crash on tab switching (#618)
        guard nsView.window != nil else { return }

        let current = (nsView.previewItem as? PreviewItem)?.previewItemURL
        if current != url {
            let newItem = PreviewItem(url: url)
            guard newItem.previewItemURL != nil else { return }
            nsView.previewItem = newItem
        }
    }
}

/// Simple QLPreviewItem wrapper for a file URL.
private class PreviewItem: NSObject, QLPreviewItem {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    var previewItemURL: URL? { url }
}
