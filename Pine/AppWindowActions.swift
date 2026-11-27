//
//  AppWindowActions.swift
//  Pine
//
//  The one app-lifetime host of SwiftUI's window actions.
//

import AppKit
import SwiftUI
import os

/// Opens the app's scenes from AppKit.
///
/// `openWindow` exists only inside a SwiftUI view, and every scene view dies
/// with its window. This host is a window the app delegate owns for the whole
/// run and never shows, so opening a project — or the Welcome scene — never
/// depends on another window being alive.
@MainActor
final class AppWindowActions {
    /// The scene routes, as SwiftUI reports them from inside the host.
    struct Routes {
        let openProject: (URL) -> Void
        let openNamed: (String) -> Void
    }

    private(set) var routes: Routes?
    private var window: NSWindow?

    /// `nil` until the host has rendered once and reported its routes.
    var projectOpener: ((URL) -> Void)? { routes?.openProject }

    /// Creates the host once. `reporting` turns the raw window actions into
    /// the app's routes; it is called whenever the host re-reports them.
    func install(
        reporting: @escaping (
            @escaping (URL) -> Void, @escaping (String) -> Void
        ) -> Routes
    ) {
        guard window == nil else { return }
        let host = NSWindow(contentViewController: NSHostingController(
            rootView: WindowActionBridge { [weak self] openProject, openNamed in
                self?.routes = reporting(openProject, openNamed)
            }
        ))
        host.isReleasedWhenClosed = false
        host.identifier = NSUserInterfaceItemIdentifier("pine.windowActionsHost")
        window = host
        // The window is never ordered on screen, so drive the first layout
        // and display pass by hand: that is when the bridge reports. This
        // first pass is the load-bearing assumption of the whole host —
        // every AppDelegate-only open (Open panel, Open Recent, notification
        // presentation) depends on the routes existing from here on.
        host.contentView?.layoutSubtreeIfNeeded()
        host.contentView?.displayIfNeeded()
        #if DEBUG
        if routes == nil {
            Logger.app.fault(
                "AppWindowActions: the hidden host did not report its routes \
                after the first layout/display pass; app-lifetime opens will \
                fail closed until a view re-reports them."
            )
        }
        #endif
    }

    @discardableResult
    func openProject(_ url: URL) -> Bool {
        guard let routes else { return false }
        routes.openProject(url)
        return true
    }

    @discardableResult
    func openNamed(_ id: String) -> Bool {
        guard let routes else { return false }
        routes.openNamed(id)
        return true
    }
}

/// The SwiftUI side of the host: reads the window actions out of the
/// environment they exist in and hands them to the owner.
private struct WindowActionBridge: NSViewRepresentable {
    let report: (@escaping (URL) -> Void, @escaping (String) -> Void) -> Void
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let openWindow = openWindow
        report({ openWindow(value: $0) }, { openWindow(id: $0) })
    }
}
