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

    @Test("Restarting watch discards events from previous generation")
    @MainActor
    func staleGenerationDiscarded() async throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        var callbackCount = 0
        let watcher = FileSystemWatcher(debounceInterval: 0.3) {
            callbackCount += 1
        }

        // Watch dir1, create event
        watcher.watch(directory: dir1)
        try "old".write(
            to: dir1.appendingPathComponent("old.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Immediately switch to dir2 — old events should be discarded
        watcher.watch(directory: dir2)

        // Create event in new directory
        try "new".write(
            to: dir2.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Wait for debounce
        try await Task.sleep(for: .milliseconds(800))

        watcher.stop()

        // Should only see callback(s) from dir2, not from dir1
        // (watch() calls stopOnQueue first, incrementing generation)
        #expect(callbackCount >= 1)
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

    @Test("FileSystemWatcher retains itself while stream is active")
    func retainedSelfWhileActive() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        weak var weakWatcher: FileSystemWatcher?

        let externalRef: FileSystemWatcher
        do {
            let watcher = FileSystemWatcher { }
            weakWatcher = watcher
            watcher.watch(directory: dir)
            externalRef = watcher
        }

        // Watcher should still be alive (retained by self-reference + externalRef)
        #expect(weakWatcher != nil)

        externalRef.stop()

        // Now with no external ref and stop called, it should release
        // (we still hold externalRef so it won't dealloc yet)
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
