//
//  DebouncerTests.swift
//  PineTests
//
//  Direct unit tests for Debouncer — the coalescing timer primitive
//  used by FileSystemWatcher, WorkspaceManager, and RecoveryManager
//  for debouncing rapid events. Covers issue #805.
//

import Foundation
import os
import Testing

@testable import Pine

/// Virtual-time scheduler for exercising Debouncer without wall-clock waits.
/// It retains submitted work items exactly like a dispatch queue would; an
/// advance executes only uncancelled items whose deadlines have been reached.
nonisolated private final class ManualDebouncerScheduler: Sendable {
    private struct SendableWorkItem: @unchecked Sendable {
        let value: DispatchWorkItem
    }

    private struct Entry: Sendable {
        let deadline: TimeInterval
        let order: Int
        let workItem: SendableWorkItem
    }

    private struct State: Sendable {
        var now: TimeInterval = 0
        var nextOrder = 0
        var entries: [Entry] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: TimeInterval {
        state.withLock { $0.now }
    }

    func makeDebouncer(
        delay: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> Debouncer {
        Debouncer(
            delay: delay,
            scheduleWorkItem: { [self] delay, workItem in
                schedule(after: delay, workItem: workItem)
            },
            action: action
        )
    }

    func advance(by interval: TimeInterval) {
        precondition(interval >= 0)
        let ready = state.withLock { state in
            state.now += interval
            let now = state.now
            var ready: [Entry] = []
            state.entries.removeAll { entry in
                guard entry.deadline <= now else { return false }
                ready.append(entry)
                return true
            }
            return ready.sorted { lhs, rhs in
                if lhs.deadline == rhs.deadline {
                    return lhs.order < rhs.order
                }
                return lhs.deadline < rhs.deadline
            }
        }

        for entry in ready where !entry.workItem.value.isCancelled {
            entry.workItem.value.perform()
        }
    }

    private func schedule(after delay: TimeInterval, workItem: DispatchWorkItem) {
        let sendableWorkItem = SendableWorkItem(value: workItem)
        state.withLock { state in
            state.entries.append(Entry(
                deadline: state.now + delay,
                order: state.nextOrder,
                workItem: sendableWorkItem
            ))
            state.nextOrder += 1
        }
    }
}

// swiftlint:disable type_body_length
@Suite("Debouncer Tests")
struct DebouncerTests {

    // MARK: - Single trigger fires exactly once after delay

    @Test("Single trigger fires callback exactly once after the delay")
    @MainActor
    func singleTriggerFiresOnce() {
        var fireCount = 0
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0.05) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()

        scheduler.advance(by: 0.049)
        #expect(fireCount == 0, "Callback should not fire before delay elapses")

        scheduler.advance(by: 0.002)
        #expect(fireCount == 1, "Callback should fire exactly once after delay")

        scheduler.advance(by: 1)
        #expect(fireCount == 1, "A scheduled callback should not fire more than once")
    }

    // MARK: - Multiple rapid triggers coalesce into single fire

    @Test("Multiple rapid triggers coalesce into a single delayed fire")
    @MainActor
    func rapidTriggersCoalesce() {
        var fireCount = 0
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0.1) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        for index in 0..<10 {
            debouncer.schedule()
            if index < 9 {
                scheduler.advance(by: 0.005)
            }
        }

        scheduler.advance(by: 0.099)
        #expect(fireCount == 0, "The last trigger should start a fresh delay window")

        scheduler.advance(by: 0.002)

        #expect(
            fireCount == 1,
            "Multiple rapid calls should coalesce into exactly one callback"
        )
    }

    // MARK: - New trigger after delay fires independently

    @Test("A new trigger after the delay window fires independently")
    @MainActor
    func triggerAfterDelayFiresSeparately() {
        var fireCount = 0
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0.05) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()
        scheduler.advance(by: 0.051)
        #expect(fireCount == 1, "First trigger should have fired")

        debouncer.schedule()
        scheduler.advance(by: 0.051)
        #expect(fireCount == 2, "Second trigger should fire independently")
    }

    // MARK: - Cancel prevents pending fire

    @Test("Cancelling prevents a pending callback from firing")
    @MainActor
    func cancelPreventsFiring() {
        var fireCount = 0
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0.1) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()
        scheduler.advance(by: 0.03)
        debouncer.cancel()

        scheduler.advance(by: 1)
        #expect(fireCount == 0, "Cancelled debouncer should not fire")
    }

    // MARK: - Call after cancel works

    @Test("Calling after cancel schedules a new callback")
    @MainActor
    func callAfterCancelWorks() {
        var fireCount = 0
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0.05) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()
        debouncer.cancel()

        debouncer.schedule()
        scheduler.advance(by: 0.051)

        #expect(fireCount == 1, "Call after cancel should fire normally")
    }

    // MARK: - Multiple cancels are safe

    @Test("Calling cancel multiple times does not crash")
    @MainActor
    func multipleCancelsAreSafe() {
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0.1) { }

        debouncer.cancel()
        debouncer.cancel()
        debouncer.schedule()
        debouncer.cancel()
        debouncer.cancel()
        // No crash = pass
    }

    // MARK: - Cancel without call is safe

    @Test("Cancelling without a prior call does not crash")
    @MainActor
    func cancelWithoutCallIsSafe() {
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0.1) { }
        debouncer.cancel()
        // No crash = pass
    }

    // MARK: - Debouncer resets timer on each call

    @Test("Each call resets the timer, extending the delay")
    @MainActor
    func callResetsTimer() {
        var fireCount = 0
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0.1) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()
        scheduler.advance(by: 0.06)
        #expect(
            fireCount == 0,
            "Should not fire yet — only 60ms of 100ms elapsed"
        )

        debouncer.schedule()
        scheduler.advance(by: 0.06)
        #expect(
            fireCount == 0,
            "Timer was reset — only 60ms since last call"
        )

        scheduler.advance(by: 0.041)
        #expect(
            fireCount == 1,
            "Should fire once after delay from last call"
        )
    }

    // MARK: - Zero delay fires promptly

    @Test("Zero delay fires promptly")
    @MainActor
    func zeroDelayFires() {
        var fireCount = 0
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()
        scheduler.advance(by: 0)
        #expect(fireCount == 1, "Zero-delay debouncer should fire quickly")
    }

    // MARK: - Callback captures correct state

    @Test("Callback sees the latest state, not stale captured values")
    @MainActor
    func callbackSeesLatestState() {
        var value = 0
        let scheduler = ManualDebouncerScheduler()
        let debouncer = scheduler.makeDebouncer(delay: 0.05) {
            MainActor.assumeIsolated { value += 10 }
        }

        value = 5
        debouncer.schedule()
        value = 20

        scheduler.advance(by: 0.051)
        #expect(value == 30, "Callback should execute with current state")
    }

    // MARK: - Rapid coalesce preserves only last

    @Test("Only the last call in a rapid burst matters for timing")
    @MainActor
    func rapidBurstPreservesLast() {
        let scheduler = ManualDebouncerScheduler()
        var fireTimes: [TimeInterval] = []
        let debouncer = scheduler.makeDebouncer(delay: 0.05) {
            MainActor.assumeIsolated { fireTimes.append(scheduler.now) }
        }

        for _ in 0..<5 {
            debouncer.schedule()
            scheduler.advance(by: 0.01)
        }

        scheduler.advance(by: 0.039)
        #expect(fireTimes.isEmpty, "No callback should fire before the last call's deadline")

        scheduler.advance(by: 0.002)
        #expect(fireTimes.count == 1, "Should fire exactly once")

        if let fireTime = fireTimes.first {
            #expect(fireTime >= 0.09, "Fire should be after the last call plus its delay")
        }
    }

    // MARK: - Deinit behavior

    @Test("Debouncer deinit cancels pending callback")
    @MainActor
    func deinitWithPendingCallback() {
        var fireCount = 0
        let scheduler = ManualDebouncerScheduler()
        var debouncer: Debouncer? = scheduler.makeDebouncer(delay: 0.15) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer?.schedule()
        scheduler.advance(by: 0.03)

        debouncer = nil
        scheduler.advance(by: 1)

        // deinit calls cancel(), so the callback must not fire
        #expect(fireCount == 0, "Cancelled in deinit — callback should not fire")
    }

    // MARK: - Injectable queue for off-main use

    @Test("Debouncer fires callback on an injectable custom queue")
    func injectableQueueFires() async {
        let queue = DispatchQueue(label: "com.pine.test.custom-queue")
        let (events, eventContinuation) = AsyncStream.makeStream(of: Bool.self)
        let debouncer = Debouncer(delay: 0, queue: queue) {
            dispatchPrecondition(condition: .onQueue(queue))
            eventContinuation.yield(true)
            eventContinuation.finish()
        }

        debouncer.schedule()

        var iterator = events.makeAsyncIterator()
        let didFire = await iterator.next()
        withExtendedLifetime(debouncer) { }

        #expect(didFire == true, "Callback should fire on custom queue")
    }
}
// swiftlint:enable type_body_length
