//
//  ToastManager.swift
//  Pine
//
//  Manages a queue of non-blocking toast notifications.
//  Toasts slide in from the top and auto-dismiss after a timeout.
//
//  Issue #1247: toasts are non-blocking (the overlay layer does not intercept
//  clicks — see ToastOverlay), an accessibility announcement is posted when a
//  toast appears, and queued toasts never overlap or trap focus because only
//  one toast is ever `currentToast` at a time and auto-dismiss is keyed to a
//  monotonic generation counter so a stale DispatchWorkItem cannot dismiss a
//  newer toast.
//

import AppKit
import Foundation

/// Represents a single toast notification.
struct ToastItem: Identifiable, Equatable {
    let id: UUID
    let message: String
    let kind: Kind

    enum Kind: Equatable {
        case filesReloaded
        case info
    }

    init(message: String, kind: Kind = .info) {
        self.id = UUID()
        self.message = message
        self.kind = kind
    }
}

/// Posts a VoiceOver/screen-reader announcement. Extracted as a typealias so
/// tests can inject a recorder without reaching into `NSAccessibility` (which
/// is a no-op outside an app process). Always invoked on the main actor.
typealias ToastAnnouncer = @Sendable (String) -> Void

/// Manages a FIFO queue of toast notifications with auto-dismiss.
@MainActor
@Observable
final class ToastManager {
    /// Currently visible toast, if any.
    private(set) var currentToast: ToastItem?

    /// Queued toasts waiting to be shown.
    private var queue: [ToastItem] = []

    /// Auto-dismiss delay in seconds.
    var dismissDelay: TimeInterval = 3.0

    /// Small gap between consecutive toasts, in seconds. Kept constant so
    /// timing stays predictable regardless of queue depth (issue #1247).
    var interToastDelay: TimeInterval = UITimings.Delay.standard

    /// Pending auto-dismiss work item.
    private var dismissWorkItem: DispatchWorkItem?

    /// Pending work item that advances the queue after `interToastDelay`.
    private var advanceWorkItem: DispatchWorkItem?

    /// Monotonic counter bumped every time a toast is presented. Auto-dismiss
    /// work items capture the value they were scheduled with and no-op if it
    /// no longer matches, so a stale timer can never dismiss a newer toast.
    private var presentGeneration: UInt64 = 0

    /// Posts a VoiceOver announcement when a toast appears. Defaults to
    /// posting via `NSAccessibility`; tests inject a recorder closure.
    var announce: ToastAnnouncer = { message in
        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
    }

    /// Whether to prefix the spoken message with a localized "Notification:"
    /// label. Tests turn this off to assert on the raw message.
    var prefixesAnnouncements: Bool = true

    /// Shows a toast. If another toast is visible, queues this one.
    func show(_ toast: ToastItem) {
        if currentToast != nil {
            queue.append(toast)
        } else {
            present(toast)
        }
    }

    /// Convenience: show a toast for reloaded files.
    func showFilesReloaded(_ fileNames: [String]) {
        guard !fileNames.isEmpty else { return }
        let message: String
        if fileNames.count == 1 {
            message = String(localized: "toast.fileReloaded \(fileNames[0])")
        } else {
            let names = fileNames.prefix(3).joined(separator: ", ")
            let remaining = fileNames.count - 3
            if remaining > 0 {
                message = String(localized: "toast.filesReloaded.more \(fileNames.count) \(names) \(remaining)")
            } else {
                message = String(localized: "toast.filesReloaded \(fileNames.count) \(names)")
            }
        }
        show(ToastItem(message: message, kind: .filesReloaded))
    }

    /// Dismisses the current toast and shows the next one in queue.
    func dismiss() {
        cancelPendingWork()
        currentToast = nil

        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        // Small delay between toasts for visual separation. The advance work
        // item is stored so a subsequent manual dismiss() can cancel it,
        // preventing two toasts from being presented simultaneously.
        let generation = presentGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.advanceToNext(generation: generation, toast: next)
        }
        advanceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interToastDelay, execute: work)
    }

    /// Whether a toast is currently visible (for testing).
    var isShowingToast: Bool {
        currentToast != nil
    }

    /// Number of queued toasts (for testing).
    var queueCount: Int {
        queue.count
    }

    // MARK: - Private

    private func present(_ toast: ToastItem) {
        presentGeneration &+= 1
        currentToast = toast
        announceAppearance(of: toast)
        scheduleDismiss()
    }

    /// Called by the inter-toast advance work item. Guards against the work
    /// item firing after a newer presentation has bumped the generation
    /// counter (defensive — `dismiss()` also cancels pending work).
    private func advanceToNext(generation: UInt64, toast: ToastItem) {
        guard generation == presentGeneration else { return }
        advanceWorkItem = nil
        present(toast)
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let scheduledGeneration = presentGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only auto-dismiss if no newer toast has replaced this one.
            guard scheduledGeneration == self.presentGeneration else { return }
            self.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: work)
    }

    private func cancelPendingWork() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        advanceWorkItem?.cancel()
        advanceWorkItem = nil
    }

    private func announceAppearance(of toast: ToastItem) {
        let spoken = prefixesAnnouncements
            ? "\(Strings.a11yToastAnnouncementPrefix) \(toast.message)"
            : toast.message
        announce(spoken)
    }
}
