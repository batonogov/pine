//
//  ProgressTrackerLeakTests.swift
//  PineTests
//
//  Verifies that ProgressTracker operations are always cleaned up,
//  even when loading tasks are cancelled mid-flight.
//

import Foundation
import Testing

@testable import Pine

@Suite("ProgressTracker Leak Tests")
struct ProgressTrackerLeakTests {

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-progress-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        return rawDir.resolvingSymlinksInPath()
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - ProgressTracker unit tests

    @Test("beginOperation increments count, endOperation decrements it")
    @MainActor
    func beginEndOperationBasic() {
        let tracker = ProgressTracker()
        #expect(tracker.activeOperationCount == 0)
        #expect(!tracker.isLoading)

        let id1 = tracker.beginOperation("Op 1")
        #expect(tracker.activeOperationCount == 1)
        #expect(tracker.isLoading)
        #expect(tracker.message == "Op 1")

        let id2 = tracker.beginOperation("Op 2")
        #expect(tracker.activeOperationCount == 2)
        #expect(tracker.message == "Op 2")

        tracker.endOperation(id1)
        #expect(tracker.activeOperationCount == 1)
        #expect(tracker.message == "Op 2")

        tracker.endOperation(id2)
        #expect(tracker.activeOperationCount == 0)
        #expect(!tracker.isLoading)
    }

    @Test("endOperation with unknown ID is a no-op")
    @MainActor
    func endOperationUnknownID() {
        let tracker = ProgressTracker()
        let id = tracker.beginOperation("Op")
        tracker.endOperation(UUID()) // unknown ID
        #expect(tracker.activeOperationCount == 1)
        tracker.endOperation(id)
        #expect(tracker.activeOperationCount == 0)
    }

    @Test("endOperation called twice with same ID is a no-op on second call")
    @MainActor
    func endOperationIdempotent() {
        let tracker = ProgressTracker()
        let id = tracker.beginOperation("Op")
        tracker.endOperation(id)
        #expect(tracker.activeOperationCount == 0)
        tracker.endOperation(id) // second call — should not underflow
        #expect(tracker.activeOperationCount == 0)
    }

    // MARK: - WorkspaceManager + ProgressTracker integration

    @Test("Normal load completes and cleans up progress operation")
    @MainActor
    func normalLoadCleansUpProgress() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "hello".write(
            to: dir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let tracker = ProgressTracker()
        let manager = WorkspaceManager()
        manager.progressTracker = tracker

        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        #expect(!manager.isLoading)
        #expect(
            tracker.activeOperationCount == 0,
            "Progress operation must be cleaned up after normal load completes"
        )
    }

    // NOTE: On a fast machine dir1 may complete before the second loadDirectory
    // call cancels it, so the cancellation path is not always exercised.
    // The test still validates correctness — it just may not exercise the fix
    // on every run. A synthetic delay in the loader would make it deterministic
    // but adds complexity not warranted here.
    @Test("Cancelled load cleans up progress operation (no leak)")
    @MainActor
    func cancelledLoadCleansUpProgress() async throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        // Create deeply nested structure in dir1 to make Phase 2 slow enough to cancel
        let deep = dir1
            .appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
            .appendingPathComponent("d")
            .appendingPathComponent("e")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "deep".write(
            to: deep.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        try "simple".write(
            to: dir2.appendingPathComponent("simple.txt"),
            atomically: true,
            encoding: .utf8
        )

        let tracker = ProgressTracker()
        let manager = WorkspaceManager()
        manager.progressTracker = tracker

        // Start loading dir1 (triggers beginOperation)
        manager.loadDirectory(url: dir1)

        // Immediately load dir2 — this cancels dir1's task
        manager.loadDirectory(url: dir2)

        // Wait for dir2's load to complete
        await manager.waitForLoadingComplete()

        // The cancelled dir1 task's cleanup runs asynchronously on MainActor;
        // wait for its endOperation to land under a generous ceiling (#1568).
        let cleanupLanded = await waitUntilMainActor {
            tracker.activeOperationCount == 0
        }
        #expect(
            cleanupLanded,
            "Cancelled load must not leak progress operations; found \(tracker.activeOperationCount) active"
        )
    }

    @Test("Multiple rapid refreshFileTreeAsync calls do not leak progress operations")
    @MainActor
    func rapidRefreshDoesNotLeakProgress() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        // Create some files to load
        for i in 0..<5 {
            try "content\(i)".write(
                to: dir.appendingPathComponent("file\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let tracker = ProgressTracker()
        let manager = WorkspaceManager()
        manager.progressTracker = tracker

        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        #expect(tracker.activeOperationCount == 0, "Initial load must clean up")

        // Fire multiple rapid async refreshes — each cancels the previous
        for _ in 0..<10 {
            manager.refreshFileTreeAsync()
        }

        // Wait for the last refresh to settle
        await manager.waitForLoadingComplete()

        // Cancelled-refresh cleanup lands on MainActor; wait under a
        // generous ceiling (#1568).
        let cleanupLanded = await waitUntilMainActor {
            tracker.activeOperationCount == 0
        }
        #expect(
            cleanupLanded,
            "Rapid refreshes must not leak progress operations; found \(tracker.activeOperationCount) active"
        )
    }

    @Test("loadDirectory followed by refreshFileTreeAsync does not leak")
    @MainActor
    func loadThenRefreshDoesNotLeak() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "a".write(
            to: dir.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )

        let tracker = ProgressTracker()
        let manager = WorkspaceManager()
        manager.progressTracker = tracker

        // Load directory then immediately refresh — both create progress operations
        manager.loadDirectory(url: dir)
        manager.refreshFileTreeAsync()

        await manager.waitForLoadingComplete()

        // Cancelled-task cleanup lands on MainActor; wait under a generous
        // ceiling (#1568).
        let cleanupLanded = await waitUntilMainActor {
            tracker.activeOperationCount == 0
        }
        #expect(
            cleanupLanded,
            "loadDirectory + refreshFileTreeAsync must not leak; found \(tracker.activeOperationCount) active"
        )
    }

    @Test("Progress tracker without progressTracker set does not crash")
    @MainActor
    func noTrackerDoesNotCrash() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "content".write(
            to: dir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        // progressTracker is nil — should not crash

        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        #expect(!manager.isLoading)
        #expect(manager.rootNodes.contains { $0.name == "file.txt" })
    }
}
