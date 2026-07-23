//
//  AppKitFocusRequestCoordinator.swift
//  Pine
//
//  Retains destination-focus requests until AppKit confirms first responder.
//

import AppKit

/// Bridges an observable tab-focus request to an AppKit view lifecycle.
///
/// SwiftUI may call `updateNSView` before a newly split destination is attached
/// to a window. The request therefore remains pending after a failed attempt
/// and is retried when the host view moves into a window.
@MainActor
final class AppKitFocusRequestCoordinator {
    private(set) var pendingRequestID: UUID?

    private weak var hostView: NSView?
    private weak var targetView: NSView?
    private var canAttempt: ((UUID) -> Bool)?
    private var onResult: ((UUID, Bool) -> Void)?
    private var attemptScheduled = false
    private var scheduledTransientRetry = false

    func update(
        requestID: UUID?,
        hostView: NSView,
        targetView: NSView?,
        canAttempt: ((UUID) -> Bool)? = nil,
        onResult: ((UUID, Bool) -> Void)?
    ) {
        self.hostView = hostView
        self.targetView = targetView
        self.canAttempt = canAttempt
        self.onResult = onResult

        guard let requestID else {
            cancel()
            return
        }
        if pendingRequestID != requestID {
            pendingRequestID = requestID
            scheduledTransientRetry = false
        }
        scheduleAttempt()
    }

    func hostDidMoveToWindow(_ hostView: NSView) {
        self.hostView = hostView
        guard hostView.window != nil else { return }
        scheduleAttempt()
    }

    func cancel() {
        pendingRequestID = nil
        targetView = nil
        canAttempt = nil
        onResult = nil
        scheduledTransientRetry = false
    }

    /// Synchronous seam used by lifecycle callbacks and regression tests.
    @discardableResult
    func attemptNow() -> Bool {
        guard let requestID = pendingRequestID else { return false }
        guard canAttempt?(requestID) != false else {
            pendingRequestID = nil
            scheduledTransientRetry = false
            onResult?(requestID, false)
            return false
        }
        guard
              let hostView,
              let targetView,
              let window = hostView.window,
              targetView.window === window else {
            onResult?(requestID, false)
            return false
        }

        let accepted = window.makeFirstResponder(targetView)
        let responderMatchesTarget = if window.firstResponder === targetView {
            true
        } else if let responderView = window.firstResponder as? NSView {
            responderView.isDescendant(of: targetView)
        } else {
            false
        }
        let succeeded = accepted && responderMatchesTarget
        onResult?(requestID, succeeded)

        if succeeded {
            pendingRequestID = nil
            scheduledTransientRetry = false
        } else if !scheduledTransientRetry {
            // AppKit can briefly reject a responder while SwiftUI finishes
            // reparenting. Retry once on the next runloop; later view updates
            // and `viewDidMoveToWindow` remain additional retry opportunities.
            scheduledTransientRetry = true
            scheduleAttempt()
        }
        return succeeded
    }

    private func scheduleAttempt() {
        guard pendingRequestID != nil, !attemptScheduled else { return }
        attemptScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attemptScheduled = false
            self.attemptNow()
        }
    }
}
