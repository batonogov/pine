//
//  Debouncer.swift
//  Pine
//
//  A simple coalescing timer that fires a callback after a delay,
//  resetting the timer on every new call. Used by FileSystemWatcher
//  and WorkspaceManager to debounce rapid events into a single action.
//

import Foundation

/// A trailing-edge debouncer: schedules a callback after `delay` seconds,
/// cancelling any previously pending callback so that rapid calls coalesce
/// into a single fire.
///
/// Thread-safety: all methods must be called from the same serial context
/// (e.g. the `queue` passed at init). The callback is dispatched to `queue`.
///
/// Marked `nonisolated` so the class can work with any dispatch queue,
/// not just the main actor (which is the project-wide default isolation).
nonisolated final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let action: @Sendable () -> Void
    // nonisolated(unsafe) allows deinit to cancel the pending work item.
    // Debouncer is not Sendable — all methods must be called from the same
    // serial context, so this is safe in practice.
    nonisolated(unsafe) private var workItem: DispatchWorkItem?

    /// Creates a debouncer.
    /// - Parameters:
    ///   - delay: Seconds to wait after the last `schedule()` before firing.
    ///   - queue: The dispatch queue to fire the callback on (default: `.main`).
    ///   - action: The closure to execute when the debounce fires.
    init(delay: TimeInterval, queue: DispatchQueue = .main, action: @escaping @Sendable () -> Void) {
        self.delay = delay
        self.queue = queue
        self.action = action
    }

    /// Schedules (or reschedules) the debounced callback.
    /// Any previously pending callback is cancelled.
    func schedule() {
        workItem?.cancel()
        let action = self.action
        let item = DispatchWorkItem { action() }
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Cancels any pending callback without firing it.
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }

    deinit {
        workItem?.cancel()
    }
}
