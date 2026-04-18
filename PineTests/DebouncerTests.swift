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

// swiftlint:disable type_body_length
@Suite("Debouncer Tests")
struct DebouncerTests {

    // MARK: - Single trigger fires exactly once after delay

    @Test("Single trigger fires callback exactly once after the delay")
    @MainActor
    func singleTriggerFiresOnce() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.05) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()

        // Before delay — should not have fired yet
        try await Task.sleep(for: .milliseconds(20))
        #expect(fireCount == 0, "Callback should not fire before delay elapses")

        // After delay — wait generously for CI
        try await Task.sleep(for: .milliseconds(150))
        #expect(fireCount == 1, "Callback should fire exactly once after delay")
    }

    // MARK: - Multiple rapid triggers coalesce into single fire

    @Test("Multiple rapid triggers coalesce into a single delayed fire")
    @MainActor
    func rapidTriggersCoalesce() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.1) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        // Fire rapidly 10 times
        for _ in 0..<10 {
            debouncer.schedule()
            try await Task.sleep(for: .milliseconds(5))
        }

        // Wait for debounce to settle — 3x delay from last call
        try await Task.sleep(for: .milliseconds(400))

        #expect(
            fireCount == 1,
            "Multiple rapid calls should coalesce into exactly one callback"
        )
    }

    // MARK: - New trigger after delay fires independently

    @Test("A new trigger after the delay window fires independently")
    @MainActor
    func triggerAfterDelayFiresSeparately() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.05) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        // First trigger
        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(200))
        #expect(fireCount == 1, "First trigger should have fired")

        // Second trigger — well after first delay window
        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(200))
        #expect(fireCount == 2, "Second trigger should fire independently")
    }

    // MARK: - Cancel prevents pending fire

    @Test("Cancelling prevents a pending callback from firing")
    @MainActor
    func cancelPreventsFiring() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.1) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(30))

        // Cancel before delay elapses
        debouncer.cancel()

        // Wait 2x past the original delay
        try await Task.sleep(for: .milliseconds(250))
        #expect(fireCount == 0, "Cancelled debouncer should not fire")
    }

    // MARK: - Call after cancel works

    @Test("Calling after cancel schedules a new callback")
    @MainActor
    func callAfterCancelWorks() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.05) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()
        debouncer.cancel()

        // New call after cancel
        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(200))

        #expect(fireCount == 1, "Call after cancel should fire normally")
    }

    // MARK: - Multiple cancels are safe

    @Test("Calling cancel multiple times does not crash")
    @MainActor
    func multipleCancelsAreSafe() {
        let debouncer = Debouncer(delay: 0.1) { }

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
        let debouncer = Debouncer(delay: 0.1) { }
        debouncer.cancel()
        // No crash = pass
    }

    // MARK: - Debouncer resets timer on each call

    @Test("Each call resets the timer, extending the delay")
    @MainActor
    func callResetsTimer() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0.1) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(60))
        #expect(
            fireCount == 0,
            "Should not fire yet — only 60ms of 100ms elapsed"
        )

        // Reset the timer by calling again
        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(60))
        #expect(
            fireCount == 0,
            "Timer was reset — only 60ms since last call"
        )

        // Now wait past the full delay from the last call
        try await Task.sleep(for: .milliseconds(150))
        #expect(
            fireCount == 1,
            "Should fire once after delay from last call"
        )
    }

    // MARK: - Zero delay fires promptly

    @Test("Zero delay fires promptly")
    @MainActor
    func zeroDelayFires() async throws {
        var fireCount = 0
        let debouncer = Debouncer(delay: 0) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer.schedule()

        // Give run loop a chance to process
        try await Task.sleep(for: .milliseconds(50))
        #expect(fireCount == 1, "Zero-delay debouncer should fire quickly")
    }

    // MARK: - Callback captures correct state

    @Test("Callback sees the latest state, not stale captured values")
    @MainActor
    func callbackSeesLatestState() async throws {
        var value = 0
        let debouncer = Debouncer(delay: 0.05) {
            MainActor.assumeIsolated { value += 10 }
        }

        value = 5
        debouncer.schedule()
        value = 20

        try await Task.sleep(for: .milliseconds(200))
        // value should be 20 + 10 = 30
        #expect(value == 30, "Callback should execute with current state")
    }

    // MARK: - Rapid coalesce preserves only last

    @Test("Only the last call in a rapid burst matters for timing")
    @MainActor
    func rapidBurstPreservesLast() async throws {
        var timestamps: [Date] = []
        let debouncer = Debouncer(delay: 0.05) {
            MainActor.assumeIsolated { timestamps.append(Date()) }
        }

        let start = Date()

        // Burst over ~50ms
        for _ in 0..<5 {
            debouncer.schedule()
            try await Task.sleep(for: .milliseconds(10))
        }
        // Last call was at ~40ms

        // Wait 3x delay from last call
        try await Task.sleep(for: .milliseconds(250))

        #expect(timestamps.count == 1, "Should fire exactly once")

        // The fire should happen after last call + delay
        if let fireTime = timestamps.first {
            let elapsed = fireTime.timeIntervalSince(start)
            #expect(elapsed >= 0.07, "Fire should be after last call + delay")
        }
    }

    // MARK: - Deinit behavior

    @Test("Debouncer deinit cancels pending callback")
    @MainActor
    func deinitWithPendingCallback() async throws {
        var fireCount = 0
        var debouncer: Debouncer? = Debouncer(delay: 0.15) {
            MainActor.assumeIsolated { fireCount += 1 }
        }

        debouncer?.schedule()
        try await Task.sleep(for: .milliseconds(30))

        // Release the debouncer while callback is pending
        debouncer = nil

        // Wait 3x past the delay
        try await Task.sleep(for: .milliseconds(500))

        // deinit calls cancel(), so the callback must not fire
        #expect(fireCount == 0, "Cancelled in deinit — callback should not fire")
    }

    // MARK: - Injectable queue for off-main use

    @Test("Debouncer fires callback on an injectable custom queue")
    func injectableQueueFires() async throws {
        let didFire = OSAllocatedUnfairLock(initialState: false)
        let queue = DispatchQueue(label: "com.pine.test.custom-queue")
        let debouncer = Debouncer(delay: 0.05, queue: queue) {
            didFire.withLock { $0 = true }
        }

        debouncer.schedule()

        try await Task.sleep(for: .milliseconds(200))

        #expect(didFire.withLock { $0 }, "Callback should fire on custom queue")

        _ = debouncer
    }

    // MARK: - Generation token / stale-callback guard

    @Test("FileSystemWatcher generation token prevents stale callbacks after stop")
    @MainActor
    func fileSystemWatcherGenerationToken() async throws {
        var callbackCount = 0
        let watcher = FileSystemWatcher(debounceInterval: 0.1) {
            callbackCount += 1
        }

        // Create a temporary directory to watch
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-debouncer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        watcher.watch(directory: tmpDir)

        // Trigger an FS event
        let testFile = tmpDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        // Give FSEvents time to detect the change
        try await Task.sleep(for: .milliseconds(50))

        // Stop immediately — generation token should invalidate pending callbacks
        watcher.stop()

        // Record count at stop time — any callbacks that fired before stop are OK
        let countAtStop = callbackCount

        // Wait well past the debounce interval
        try await Task.sleep(for: .milliseconds(400))

        // No additional callbacks should have been delivered after stop()
        #expect(
            callbackCount == countAtStop,
            "No callbacks should fire after stop() — generation token must guard"
        )

        // Now restart and verify the watcher still works correctly
        callbackCount = 0
        watcher.watch(directory: tmpDir)

        let testFile2 = tmpDir.appendingPathComponent("test2.txt")
        try "world".write(to: testFile2, atomically: true, encoding: .utf8)

        // Wait for the debounced callback (3x interval for CI margin)
        try await Task.sleep(for: .milliseconds(500))

        watcher.stop()

        #expect(callbackCount >= 1, "Watcher should deliver callbacks after restart")
    }
}
// swiftlint:enable type_body_length
