//
//  ToastManager.swift
//  Pine
//
//  Manages a queue of non-blocking toast notifications.
//  Toasts slide in from the top and auto-dismiss after a timeout.
//

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

    /// Pending auto-dismiss work item.
    private var dismissWorkItem: DispatchWorkItem?

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
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentToast = nil

        if !queue.isEmpty {
            let next = queue.removeFirst()
            // Small delay between toasts for visual separation
            let work = DispatchWorkItem { [weak self] in
                self?.present(next)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
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
        currentToast = toast
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: work)
    }
}
