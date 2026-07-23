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
/// and is retried when the host view moves into a window. Once AppKit can
/// actually evaluate the target, transient responder rejection is retried only
/// within a fixed budget so repeated SwiftUI updates cannot steal focus later.
@MainActor
final class AppKitFocusRequestCoordinator {
    static let defaultMaximumAttempts = 2

    private(set) var pendingRequestID: UUID?
    private(set) var attemptCount = 0

    private weak var hostView: NSView?
    private weak var targetView: NSView?
    private var canAttempt: ((UUID) -> Bool)?
    private var onResult: ((UUID, Bool) -> Void)?
    private var attemptScheduled = false
    private var requestGeneration: UInt64 = 0
    private var completedRequestID: UUID?
    private let maximumAttempts: Int

    init(maximumAttempts: Int = defaultMaximumAttempts) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
    }

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
        guard completedRequestID != requestID else { return }
        if pendingRequestID != requestID {
            pendingRequestID = requestID
            attemptCount = 0
            requestGeneration &+= 1
        }
        scheduleAttempt()
    }

    func hostDidMoveToWindow(_ hostView: NSView) {
        self.hostView = hostView
        guard hostView.window != nil else { return }
        scheduleAttempt()
    }

    func cancel() {
        requestGeneration &+= 1
        pendingRequestID = nil
        targetView = nil
        canAttempt = nil
        onResult = nil
        attemptCount = 0
        completedRequestID = nil
    }

    /// Synchronous seam used by lifecycle callbacks and regression tests.
    @discardableResult
    func attemptNow() -> Bool {
        guard let requestID = pendingRequestID else { return false }
        guard canAttempt?(requestID) != false else {
            finish(requestID: requestID, succeeded: false)
            return false
        }
        guard
              let hostView,
              let targetView,
              let window = hostView.window,
              targetView.window === window else {
            return false
        }

        attemptCount += 1
        let accepted = window.makeFirstResponder(targetView)
        let responderMatchesTarget = if window.firstResponder === targetView {
            true
        } else if let responderView = window.firstResponder as? NSView {
            responderView.isDescendant(of: targetView)
        } else {
            false
        }
        let succeeded = accepted && responderMatchesTarget

        if succeeded {
            finish(requestID: requestID, succeeded: true)
        } else if attemptCount < maximumAttempts {
            // AppKit can briefly reject a responder while SwiftUI finishes
            // reparenting. The counter spans automatic retries, lifecycle
            // callbacks, and repeated SwiftUI updates for this request.
            scheduleAttempt()
        } else {
            finish(requestID: requestID, succeeded: false)
        }
        return succeeded
    }

    private func scheduleAttempt() {
        guard pendingRequestID != nil, !attemptScheduled else { return }
        attemptScheduled = true
        let generation = requestGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attemptScheduled = false
            guard self.requestGeneration == generation else {
                // A queued block belongs to a superseded request. Drop it,
                // then ensure the current generation gets its own attempt.
                self.scheduleAttempt()
                return
            }
            self.attemptNow()
        }
    }

    private func finish(requestID: UUID, succeeded: Bool) {
        guard pendingRequestID == requestID else { return }
        let completion = onResult
        requestGeneration &+= 1
        pendingRequestID = nil
        completedRequestID = requestID
        completion?(requestID, succeeded)
    }
}
