//
//  AgentInboxToolbarLayoutTracker.swift
//  Pine
//
//  Pins the Agent Inbox toolbar button into the trailing cluster (#1665).
//

import AppKit
import SwiftUI

/// The layout rule, held pure for testability.
///
/// The window's title is permanently hidden (#1643), and on macOS 26/27 a
/// hidden title collapses the region `.primaryAction` used to anchor into:
/// the inbox button packs into the leading cluster beside the
/// project-switcher pill, while the `NSSearchToolbarItem` from `.searchable`
/// keeps its trailing anchoring alone. A flexible space immediately before
/// the button restores the trailing cluster — but no SwiftUI declaration
/// produces one there: on a split-view toolbar `ToolbarSpacer` always sorts
/// after `.primaryAction` items, and a `Spacer()` inside a `ToolbarItem`
/// additionally emits a second flex before the search field, which would
/// float the button mid-window (all verified against a live toolbar).
nonisolated enum AgentInboxToolbarLayout {
    /// One step towards the pinned order. Applying corrections until nil is
    /// returned normalizes every reachable state.
    enum Correction: Equatable {
        case insertFlexibleSpace(at: Int)
        case removeFlexibleSpace(at: Int)
    }

    /// Computes the next correction, or nil once exactly one flexible space
    /// sits immediately before the trailing content item.
    ///
    /// The trailing content item is the first non-flexible item left of the
    /// search field — today the inbox button, the only `.primaryAction`. The
    /// rule deliberately never names identifiers: SwiftUI's toolbar item
    /// identifiers are random per session.
    static func correction(in items: [NSToolbarItem]) -> Correction? {
        guard let searchIndex = items.firstIndex(where: {
            $0 is NSSearchToolbarItem
        }) else { return nil }
        let isFlex = { items[$0].itemIdentifier == .flexibleSpace }
        // First non-flexible item left of the search field.
        var content = searchIndex - 1
        while content > 0, isFlex(content) { content -= 1 }
        guard content >= 1, !isFlex(content) else { return nil }
        // A stray flexible space between the content item and the search
        // field (SwiftUI's sort puts declared spacers there) goes first:
        // removing and re-deriving moves it rather than multiplying it.
        for index in (content + 1)..<searchIndex where isFlex(index) {
            return .removeFlexibleSpace(at: index)
        }
        if isFlex(content - 1) { return nil }
        return .insertFlexibleSpace(at: content)
    }

    /// Applies corrections to the fixed point. Each pass is a no-op once the
    /// order holds, so calling this from every rebuild signal is safe.
    @MainActor
    static func pin(toolbar: NSToolbar) {
        // Bounded so a pathological toolbar — or a delegate whose vendored
        // items defeat the rule's termination — can never spin the main
        // actor. A normalize needs at most one removal per misplaced flex
        // plus one insertion.
        var passes = 0
        let passLimit = toolbar.items.count + 1
        while let correction = correction(in: toolbar.items),
              passes < passLimit {
            switch correction {
            case .insertFlexibleSpace(let index):
                toolbar.insertItem(
                    withItemIdentifier: .flexibleSpace, at: index
                )
            case .removeFlexibleSpace(let index):
                toolbar.removeItem(at: index)
            }
            passes += 1
        }
    }
}

/// Applies the pin while the view sits in a window, then keeps it applied.
///
/// Attachment alone is not enough: SwiftUI rebuilds the toolbar when the
/// window's state changes (an inbox badge toggle is enough), and every
/// rebuild re-syncs the items from the view tree, undoing the insertion.
/// The `WindowTitleVisibilityTracker` precedent applies — pin on attachment,
/// then re-pin on every toolbar change notification, so the correction lands
/// again one runloop turn after each rebuild rather than fighting SwiftUI
/// inside its own mutation.
final class AgentInboxToolbarLayoutAnchorView: NSView {
    private var toolbarObservation: NSKeyValueObservation?
    /// The toolbar the notification observers are attached to; a change
    /// detected at pin time re-subscribes even if the KVO missed it.
    private weak var observedToolbar: NSToolbar?
    private var notificationObservers: [NSObjectProtocol] = []
    /// Coalesces the deferred re-pins a rebuild's notification burst causes.
    private var isPinScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        toolbarObservation = nil
        removeNotificationObservers()
        guard let window else { return }
        // The toolbar and its items materialize after the anchor attaches.
        pinToolbar(of: window)
        schedulePin()
        toolbarObservation = window.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
            self?.resubscribe()
        }
        resubscribe()
    }

    override func layout() {
        super.layout()
        // A toolbar rebuild that posts no notification still relayouts.
        schedulePin()
    }

    private func removeNotificationObservers() {
        notificationObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        notificationObservers = []
    }

    private func resubscribe() {
        removeNotificationObservers()
        guard let toolbar = window?.toolbar else {
            observedToolbar = nil
            return
        }
        observedToolbar = toolbar
        notificationObservers = [
            NSToolbar.willAddItemNotification,
            NSToolbar.didRemoveItemNotification
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: toolbar, queue: .main
            ) { [weak self] _ in
                self?.schedulePin()
            }
        }
        schedulePin()
    }

    private func schedulePin() {
        guard !isPinScheduled else { return }
        isPinScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPinScheduled = false
            if let window = self.window {
                self.pinToolbar(of: window)
            }
        }
    }

    private func pinToolbar(of window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        // The KVO on `window.toolbar` is the primary signal for the toolbar
        // object being replaced; this identity check is the fallback for a
        // replacement that posts no KVO change.
        if toolbar !== observedToolbar { resubscribe() }
        AgentInboxToolbarLayout.pin(toolbar: toolbar)
    }
}

struct AgentInboxToolbarLayoutTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        AgentInboxToolbarLayoutAnchorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
