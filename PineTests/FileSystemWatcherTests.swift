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

    @Test("Restarting watch increments generation and cancels pending debounce")
    @MainActor
    func staleGenerationDiscarded() async throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        // Use two separate counters to distinguish dir1 vs dir2 callbacks.
        // We verify that after switching to dir2, any callback that fires
        // is from the new generation (dir2), not the old one (dir1).
        var callbackCount = 0
        let watcher = FileSystemWatcher(debounceInterval: 0.3) {
            callbackCount += 1
        }

        // Watch dir1, create event — starts a debounce timer
        watcher.watch(directory: dir1)
        try "old".write(
            to: dir1.appendingPathComponent("old.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Switch to dir2 — this calls stopOnQueue (cancels debounce,
        // increments generation) then starts a new stream on dir2.
        watcher.watch(directory: dir2)

        // Record count after switching — any dir1 debounce should be cancelled
        let countAfterSwitch = callbackCount

        // Create event in dir2 to get a reliable callback from the new generation
        try "new".write(
            to: dir2.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await Task.sleep(for: .milliseconds(800))

        watcher.stop()

        // We should see at most one callback from dir2.
        // The dir1 event should have been cancelled by the generation bump.
        // (Without generation protection, we'd see 2+ callbacks)
        #expect(callbackCount - countAfterSwitch <= 1)
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
}
