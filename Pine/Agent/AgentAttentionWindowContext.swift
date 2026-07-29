//
//  AgentAttentionWindowContext.swift
//  Pine
//
//  Owner-window bridge for Agent Attention focus and accessibility routing.
//

import AppKit
import SwiftUI

/// Weakly tracks the project window that owns one `ContentView`.
///
/// Agent Attention must never consult `NSApp.keyWindow`: another project can
/// become key between presentation, keyboard movement, and dismissal. This
/// context gives focus restoration and VoiceOver announcements the same stable
/// owner without extending the lifetime of that window.
@MainActor
final class AgentAttentionWindowContext {
    typealias AnnouncementPoster = @MainActor (NSWindow, String) -> Void

    private weak var trackedView: NSView?
    private let announcementPoster: AnnouncementPoster

    private(set) weak var window: NSWindow?

    init(
        announcementPoster: @escaping AnnouncementPoster = { window, announcement in
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [.announcement: announcement]
            )
        }
    ) {
        self.announcementPoster = announcementPoster
    }

    /// Marks one SwiftUI sentinel as current and records its host window.
    func install(_ view: NSView) {
        trackedView = view
        window = view.window
    }

    /// Accepts lifecycle updates only from the current sentinel. An older
    /// sentinel can receive `viewDidMoveToWindow` after its replacement was
    /// installed; that stale callback must not clear or retarget the owner.
    func updateWindow(for view: NSView) {
        guard trackedView === view else { return }
        window = view.window
    }

    /// Clears only the sentinel that is still current. SwiftUI can install a
    /// replacement before dismantling the old representable; the old teardown
    /// must not erase the replacement's owner.
    func untrack(_ view: NSView) {
        guard trackedView === view else { return }
        trackedView = nil
        window = nil
    }

    /// Posts to the exact owning project window and fails closed if it is gone.
    @discardableResult
    func announce(_ announcement: String) -> Bool {
        guard let window else { return false }
        announcementPoster(window, announcement)
        return true
    }
}

/// Zero-size AppKit bridge that reports the actual host window of a
/// `ContentView` to its `AgentAttentionWindowContext`.
struct AgentAttentionWindowReader: NSViewRepresentable {
    let windowContext: AgentAttentionWindowContext

    func makeNSView(context: Context) -> AgentAttentionWindowSentinel {
        let view = AgentAttentionWindowSentinel(
            windowContext: windowContext
        )
        windowContext.install(view)
        return view
    }

    func updateNSView(
        _ nsView: AgentAttentionWindowSentinel,
        context: Context
    ) {
        if nsView.windowContext !== windowContext {
            nsView.windowContext.untrack(nsView)
        }
        nsView.windowContext = windowContext
        windowContext.install(nsView)
    }

    static func dismantleNSView(
        _ nsView: AgentAttentionWindowSentinel,
        coordinator: Void
    ) {
        nsView.windowContext.untrack(nsView)
    }
}

final class AgentAttentionWindowSentinel: NSView {
    var windowContext: AgentAttentionWindowContext

    init(windowContext: AgentAttentionWindowContext) {
        self.windowContext = windowContext
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowContext.updateWindow(for: self)
    }
}
