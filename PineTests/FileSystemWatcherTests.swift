//
//  FileSystemWatcherTests.swift
//  PineTests
//
//  Tests for FileSystemWatcher debouncing, generation staleness, and lifecycle.
//

import Foundation
import Testing

@testable import Pine

@Suite("FileSystemWatcher Tests")
struct FileSystemWatcherTests {

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-fswatcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Debounce coalescing

    @Test("Rapid filesystem events are coalesced into a single callback")
    @MainActor
    func debounceCoalescesEvents() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        var callbackCount = 0
        let watcher = FileSystemWatcher(debounceInterval: 0.3) {
            callbackCount += 1
        }
        watcher.watch(directory: dir)

        // Create multiple files rapidly — should coalesce into one callback
        for i in 0..<5 {
            try "content\(i)".write(
                to: dir.appendingPathComponent("file\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        // Wait for debounce to fire
        try await Task.sleep(for: .milliseconds(800))

        watcher.stop()

        // All rapid events should coalesce into a single (or very few) callback(s)
        #expect(callbackCount >= 1)
        #expect(callbackCount <= 2)
    }

    // MARK: - stop() prevents delivery

    @Test("stop() prevents callback delivery for pending events")
    @MainActor
    func stopPreventsDelivery() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        var callbackCount = 0
        let watcher = FileSystemWatcher(debounceInterval: 0.5) {
            callbackCount += 1
        }
        watcher.watch(directory: dir)

        // Create a file to trigger an event
        try "content".write(
            to: dir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Stop immediately — before debounce fires
        watcher.stop()

        // Wait longer than debounce interval
        try await Task.sleep(for: .milliseconds(800))

        // Callback should not have been delivered
        #expect(callbackCount == 0)
    }

    // MARK: - Stale generation is discarded

    /// Restarting the watch must cancel the old directory's pending debounce
    /// and stop delivering its events, while the new directory still works.
    ///
    /// This used to assert "at most one callback in the 800 ms after the
    /// switch", which is not a property FSEvents offers: one write can surface
    /// as several events far enough apart to survive a 300 ms debounce, and it
    /// did — `callbackCount - countAfterSwitch → 2` on CI, one run in three
    /// (#1518). Counting callbacks in a time box measures the filesystem's
    /// mood, so each half is now asserted on its own and waited for by
    /// condition rather than by clock.
    ///
    /// **What this covers, and what it does not.** `stopOnQueue()` defends
    /// delivery twice: `debounceWorkItem?.cancel()` drops a work item that has
    /// not run, and the `activeGeneration` check drops one that was already
    /// dequeued and is running. Only the first is observable from here —
    /// deleting the generation check leaves this test green, which is worth
    /// knowing rather than implying otherwise. Reaching the second would mean
    /// stopping the watcher in the instant between `asyncAfter` firing the
    /// work item and its body reading the generation, which no test can hit
    /// deliberately without a seam in `FileSystemWatcher`. The name says
    /// "cancels the pending debounce" because that is what is proved.
    @Test("Restarting watch cancels the old directory's pending debounce")
    @MainActor
    func staleGenerationDiscarded() async throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        var callbackCount = 0
        let watcher = FileSystemWatcher(debounceInterval: 0.3) {
            callbackCount += 1
        }
        defer { watcher.stop() }

        // Phase A — prove the stream on dir1 is live. Without this the rest
        // of the test could pass by watching nothing at all.
        watcher.watch(directory: dir1)
        try "first".write(
            to: dir1.appendingPathComponent("first.txt"),
            atomically: true,
            encoding: .utf8
        )
        #expect(
            await waitForCallback(atLeast: 1, count: { callbackCount }),
            "The watcher must deliver events for the directory it watches"
        )

        // Phase B — an event on dir1 immediately followed by a switch. The
        // pending debounce belongs to the old generation and must never fire,
        // however long we wait.
        let countBeforeSwitch = callbackCount
        try "stale".write(
            to: dir1.appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )
        watcher.watch(directory: dir2)

        // Comfortably past the 300 ms debounce: if the old generation were
        // still armed, this is when it would fire.
        try await Task.sleep(for: .milliseconds(900))
        #expect(
            callbackCount == countBeforeSwitch,
            "A debounce pending on the old directory fired after the switch"
        )

        // Phase C — the watcher is not merely dead: the new directory still
        // delivers. (Phase B alone would also pass on a broken watcher.)
        try "new".write(
            to: dir2.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )
        #expect(
            await waitForCallback(
                atLeast: countBeforeSwitch + 1,
                count: { callbackCount }
            ),
            "Events in the newly watched directory must still be delivered"
        )
    }

    /// Waits until the callback counter reaches `atLeast`, on a wall-clock
    /// deadline. Returns `false` on timeout so the caller records the failure.
    ///
    /// The deadline is generous on purpose. FSEvents delivery is not prompt
    /// under load — the stream carries its own latency (the debounce interval
    /// passed to `FSEventStreamCreate`) on top of a daemon shared with every
    /// other suite in the run. A 5-second deadline failed once during a full
    /// local `PineTests` run while passing every isolated run, which is the
    /// same trap this file's tests were in to begin with. Waiting on a
    /// condition costs nothing when the event arrives on time; only a genuine
    /// regression pays the full deadline.
    @MainActor
    private func waitForCallback(
        atLeast target: Int,
        within duration: Duration = .seconds(20),
        count: @MainActor () -> Int
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if count() >= target { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return count() >= target
    }

    // MARK: - Stale generation is discarded mid-delivery

    /// A `stop()` that lands *after* the debounce work item has started
    /// running must still suppress the callback.
    ///
    /// This is the half of `stopOnQueue()` the test above cannot reach.
    /// `debounceWorkItem?.cancel()` drops an item that has not started; the
    /// `activeGeneration` check drops one that is already in flight. Deleting
    /// the generation check left this suite green both before and after
    /// #1521, because the window is a few instructions wide and no amount of
    /// sleeping lands inside it. `debounceDeliverySeam` holds the work item
    /// open there, which is what #1518 asked for.
    ///
    /// The `stop()` comes from a background queue on purpose, and that is not
    /// a convenience: it is the only shape this race has. Every generation
    /// bump happens inside `queue.sync`, so a `stop()` issued from the main
    /// thread cannot interleave with a work item that is already running on
    /// the main queue — it would wait its turn. The guard exists for the
    /// off-main callers `FileSystemWatcher` advertises by being a
    /// `nonisolated` type with a `queue.sync`-based `stop()`. Pinning that
    /// here means a later change cannot quietly drop the guard on the grounds
    /// that "nothing calls stop() off main today".
    @Test("A stop() landing mid-delivery drops the stale callback")
    func stopDuringDeliveryDropsCallback() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let counter = WatcherCallbackCounter()
        let handle = WatcherHandle()
        let gate = DebounceDeliveryGate { handle.stop() }

        let watcher = FileSystemWatcher(debounceInterval: 0.1) {
            counter.increment()
        }
        defer { watcher.stop() }
        handle.adopt(watcher)
        watcher.debounceDeliverySeam = { gate.park() }
        watcher.watch(directory: dir)

        try "poke".write(
            to: dir.appendingPathComponent("poke.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Awaiting frees the main queue, which is what lets the work item run
        // and park. The gate then stops the watcher from its own queue and
        // releases the item, all without needing the main thread back.
        try #require(
            await gate.waitUntilParked(),
            "The debounce work item never reached the delivery seam"
        )
        #expect(
            gate.didStopWhileParked,
            "The gate must stop the watcher while the work item is parked"
        )

        // Well past the 100 ms debounce: a delivery that survived the stop
        // would have landed by now.
        try await Task.sleep(for: .milliseconds(600))
        #expect(
            counter.value == 0,
            "A work item delivered its callback after stop() made it stale"
        )
    }

    // MARK: - Retained self lifecycle

    @Test("FileSystemWatcher can be deallocated after stop()")
    func retainedSelfReleasedAfterStop() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        weak var weakWatcher: FileSystemWatcher?

        do {
            let watcher = FileSystemWatcher { }
            weakWatcher = watcher
            watcher.watch(directory: dir)

            // While watching, the watcher retains itself
            #expect(weakWatcher != nil)

            watcher.stop()
        }

        // After stop() and scope exit, watcher should be deallocated
        #expect(weakWatcher == nil)
    }

    @Test("FileSystemWatcher retains itself via internal reference while stream is active")
    func retainedSelfWhileActive() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        weak var weakWatcher: FileSystemWatcher?

        // Create watcher inside a scope so the only strong reference
        // is the internal retainedSelf set during watch().
        do {
            let watcher = FileSystemWatcher { }
            weakWatcher = watcher
            watcher.watch(directory: dir)
            // watcher goes out of scope here — only retainedSelf keeps it alive
        }

        // Watcher should still be alive via its internal self-reference
        #expect(weakWatcher != nil)

        // Clean up
        weakWatcher?.stop()
    }

    // MARK: - Callback fires on main thread

    @Test("Callback is delivered on the main thread")
    @MainActor
    func callbackOnMainThread() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        var wasMainThread = false
        let watcher = FileSystemWatcher(debounceInterval: 0.1) {
            wasMainThread = Thread.isMainThread
        }
        watcher.watch(directory: dir)

        try "trigger".write(
            to: dir.appendingPathComponent("trigger.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await Task.sleep(for: .milliseconds(500))

        watcher.stop()

        #expect(wasMainThread == true)
    }

    // MARK: - Multiple stop() calls are safe

    @Test("Calling stop() multiple times does not crash")
    func multipleStopCallsSafe() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let watcher = FileSystemWatcher { }
        watcher.watch(directory: dir)

        // Multiple stops should be safe
        watcher.stop()
        watcher.stop()
        watcher.stop()
    }

    // MARK: - stop() without watch is safe

    @Test("Calling stop() without watch does not crash")
    func stopWithoutWatch() {
        let watcher = FileSystemWatcher { }
        watcher.stop()
    }

    // MARK: - Generation token / stale-callback guard

    @Test("Generation token prevents stale callbacks after stop")
    @MainActor
    func generationTokenPreventsStaleCallbacks() async throws {
        // Verify that stopping a FileSystemWatcher increments the generation
        // token so that callbacks enqueued before stop() are discarded.
        var callbackCount = 0
        let watcher = FileSystemWatcher(debounceInterval: 0.1) {
            callbackCount += 1
        }

        let tmpDir = try makeTempDirectory()
        defer { cleanup(tmpDir) }

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

// MARK: - Delivery-seam helpers

/// Holds the debounce work item on the main queue at the seam, runs
/// `whileParked` on a background queue, and only then lets the item go.
///
/// Blocking is the point: the work item has to still be sitting between its
/// dequeue and its `activeGeneration` read while the watcher is stopped, and
/// a `DispatchWorkItem` body is a synchronous context that cannot `await`.
/// The wait is bounded — an unbounded one here would hang the whole
/// `PineTests` process rather than fail a test (#1506).
///
/// Only the first delivery parks. A later work item that was enqueued before
/// the stop passes straight through, so a regression that lets it deliver
/// shows up in the callback count instead of deadlocking the suite.
nonisolated private final class DebounceDeliveryGate: @unchecked Sendable {
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didPark = false
    private var didStop = false
    private let whileParked: @Sendable () -> Void

    init(whileParked: @escaping @Sendable () -> Void) {
        self.whileParked = whileParked
    }

    /// Called from the work item body, on the main queue.
    func park() {
        let isFirstDelivery = lock.withLock {
            guard !didPark else { return false }
            didPark = true
            return true
        }
        guard isFirstDelivery else { return }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            whileParked()
            lock.withLock { didStop = true }
            released.signal()
        }
        _ = released.wait(timeout: .now() + 20)
    }

    /// Whether a delivery ever reached the seam. Polled rather than blocking:
    /// the caller is on the main actor, and the main queue is exactly what
    /// `park()` is holding.
    func waitUntilParked(within duration: Duration = .seconds(20)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if lock.withLock({ didPark }) { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return lock.withLock { didPark }
    }

    var didStopWhileParked: Bool { lock.withLock { didStop } }
}

/// Lets a background queue call `stop()` on a watcher that does not exist yet
/// when the gate is built.
///
/// `@unchecked` because `FileSystemWatcher` is not `Sendable`, while the one
/// method used here is explicitly thread-safe: `stop()` does all of its work
/// inside `queue.sync`.
nonisolated private final class WatcherHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var watcher: FileSystemWatcher?

    func adopt(_ watcher: FileSystemWatcher) {
        lock.withLock { self.watcher = watcher }
    }

    func stop() {
        lock.withLock { watcher }?.stop()
    }
}

/// Callback tally readable from any thread, because the test that reads it is
/// not the main actor hop that writes it.
nonisolated private final class WatcherCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
