//
//  RepresentedFileTracker.swift
//  Pine
//
//  Sets NSWindow.representedURL to provide the native proxy icon and path menu.
//

import AppKit
import SwiftUI

struct RepresentedFileTracker: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.representedURL = url
    }
}
