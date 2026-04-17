//
//  DebouncerTests.swift
//  PineTests
//
//  Direct unit tests for Debouncer — the coalescing timer primitive
//  used by FileSystemWatcher and WorkspaceManager for sidebar refresh.
//  Covers issue #805.
//

import Foundation
import Testing

@testable import Pine

@Suite("Debouncer Tests")
struct DebouncerTests {

    // MARK: - Single trigger fires exactly once after delay

    @Test("Single trigger fires callback exactly once after the delay")
    @MainActor
    func singleTriggerFiresOnce() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.1) {
            fireCount += 1
        }

        debouncer.call()

        // Before delay — should not have fired yet
        try await Task.sleep(for: .milliseconds(50))
        #expect(fireCount == 0, "Callback should not fire before delay elapses")

        // After delay — should fire exactly once
        try await Task.sleep(for: .milliseconds(100))
        #expect(fireCount == 1, "Callback should fire exactly once after delay")
    }

    // MARK: - Multiple rapid triggers coalesce into single fire

    @Test("Multiple rapid triggers coalesce into a single delayed fire")
    @MainActor
    func rapidTriggersCoalesce() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.15) {
            fireCount += 1
        }

        // Fire rapidly 10 times
        for _ in 0..<10 {
            debouncer.call()
            try await Task.sleep(for: .milliseconds(10))
        }

        // Wait for debounce to settle (last call + delay)
        try await Task.sleep(for: .milliseconds(250))

        #expect(fireCount == 1, "Multiple rapid calls should coalesce into exactly one callback")
    }

    // MARK: - New trigger after delay fires independently

    @Test("A new trigger after the delay window fires independently")
    @MainActor
    func triggerAfterDelayFiresSeparately() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.1) {
            fireCount += 1
        }

        // First trigger
        debouncer.call()
        try await Task.sleep(for: .milliseconds(150))
        #expect(fireCount == 1, "First trigger should have fired")

        // Second trigger — well after first delay window
        debouncer.call()
        try await Task.sleep(for: .milliseconds(150))
        #expect(fireCount == 2, "Second trigger should fire independently")
    }

    // MARK: - Cancel prevents pending fire

    @Test("Cancelling prevents a pending callback from firing")
    @MainActor
    func cancelPreventsFiring() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.1) {
            fireCount += 1
        }

        debouncer.call()
        try await Task.sleep(for: .milliseconds(50))

        // Cancel before delay elapses
        debouncer.cancel()

        // Wait past the original delay
        try await Task.sleep(for: .milliseconds(100))
        #expect(fireCount == 0, "Cancelled debouncer should not fire")
    }

    // MARK: - Call after cancel works

    @Test("Calling after cancel schedules a new callback")
    @MainActor
    func callAfterCancelWorks() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.1) {
            fireCount += 1
        }

        debouncer.call()
        debouncer.cancel()

        // New call after cancel
        debouncer.call()
        try await Task.sleep(for: .milliseconds(150))

        #expect(fireCount == 1, "Call after cancel should fire normally")
    }

    // MARK: - Multiple cancels are safe

    @Test("Calling cancel multiple times does not crash")
    @MainActor
    func multipleCancelsAreSafe() async throws {
        let debouncer = Debouncer(delay: 0.1) { }

        debouncer.cancel()
        debouncer.cancel()
        debouncer.call()
        debouncer.cancel()
        debouncer.cancel()
        // No crash = pass
    }

    // MARK: - Cancel without call is safe

    @Test("Cancelling without a prior call does not crash")
    @MainActor
    func cancelWithoutCallIsSafe() async throws {
        let debouncer = Debouncer(delay: 0.1) { }
        debouncer.cancel()
        // No crash = pass
    }

    // MARK: - Debouncer resets timer on each call

    @Test("Each call resets the timer, extending the delay")
    @MainActor
    func callResetsTimer() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.15) {
            fireCount += 1
        }

        debouncer.call()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fireCount == 0, "Should not fire yet — only 100ms of 150ms elapsed")

        // Reset the timer by calling again
        debouncer.call()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fireCount == 0, "Timer was reset — only 100ms since last call")

        // Now wait for the full delay from the last call
        try await Task.sleep(for: .milliseconds(100))
        #expect(fireCount == 1, "Should fire once after delay from last call")
    }

    // MARK: - Zero delay fires on next run loop iteration

    @Test("Zero delay fires on the next run loop iteration")
    @MainActor
    func zeroDelayFires() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0) {
            fireCount += 1
        }

        debouncer.call()

        // Give run loop a chance to process
        try await Task.sleep(for: .milliseconds(50))
        #expect(fireCount == 1, "Zero-delay debouncer should fire quickly")
    }

    // MARK: - Callback captures correct state

    @Test("Callback sees the latest state, not stale captured values")
    @MainActor
    func callbackSeesLatestState() async throws {
        var value = 0
        let debouncer = Debouncer(delay: 0.1) {
            // Reads `value` at fire time, not at schedule time
            value += 10
        }

        value = 5
        debouncer.call()
        value = 20

        try await Task.sleep(for: .milliseconds(150))
        // value should be 20 + 10 = 30
        #expect(value == 30, "Callback should execute with current state")
    }

    // MARK: - Rapid coalesce preserves only last

    @Test("Only the last call in a rapid burst matters for timing")
    @MainActor
    func rapidBurstPreservesLast() async throws {
        var timestamps: [Date] = []
        let debouncer = Debouncer(delay: 0.1) {
            timestamps.append(Date())
        }

        let start = Date()

        // Burst over 100ms
        for _ in 0..<5 {
            debouncer.call()
            try await Task.sleep(for: .milliseconds(20))
        }
        // Last call was at ~80ms

        try await Task.sleep(for: .milliseconds(150))

        #expect(timestamps.count == 1, "Should fire exactly once")

        // The fire should happen ~100ms after the last call (~80ms + 100ms = ~180ms from start)
        if let fireTime = timestamps.first {
            let elapsed = fireTime.timeIntervalSince(start)
            #expect(elapsed >= 0.15, "Fire should be at least 150ms from start (last call + delay)")
        }
    }

    // MARK: - Deinit behavior

    @Test("Debouncer can be deallocated while a callback is pending")
    @MainActor
    func deinitWithPendingCallback() async throws {
        var fireCount = 0
        var debouncer: Debouncer? = Debouncer(delay: 0.2) {
            fireCount += 1
        }

        debouncer?.call()
        try await Task.sleep(for: .milliseconds(50))

        // Release the debouncer while callback is pending
        debouncer = nil

        // Wait past the delay
        try await Task.sleep(for: .milliseconds(250))

        // Work item was cancelled in deinit, or if it fires, it's harmless
        // The main invariant: no crash
        #expect(fireCount <= 1, "Should fire at most once (or zero if cancelled in deinit)")
    }
}
