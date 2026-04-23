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
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
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

        // Wait for async load to complete
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if !manager.isLoading { break }
        }

        #expect(!manager.isLoading)
        #expect(
            tracker.activeOperationCount == 0,
            "Progress operation must be cleaned up after normal load completes"
        )
    }

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
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if !manager.isLoading && manager.rootNodes.contains(where: { $0.name == "simple.txt" }) {
                break
            }
        }

        // Both the cancelled dir1 operation and completed dir2 operation
        // must have called endOperation. At most one operation should remain
        // (dir2's if it's still finishing), but typically zero.
        // Give a bit more time for cleanup of cancelled task.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if tracker.activeOperationCount == 0 { break }
        }

        #expect(
            tracker.activeOperationCount == 0,
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

        // Wait for initial load
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if !manager.isLoading { break }
        }

        #expect(tracker.activeOperationCount == 0, "Initial load must clean up")

        // Fire multiple rapid async refreshes — each cancels the previous
        for _ in 0..<10 {
            manager.refreshFileTreeAsync()
        }

        // Wait for the last refresh to settle
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if tracker.activeOperationCount == 0 { break }
        }

        #expect(
            tracker.activeOperationCount == 0,
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

        // Wait for everything to settle
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if tracker.activeOperationCount == 0 && !manager.isLoading { break }
        }

        #expect(
            tracker.activeOperationCount == 0,
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

        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if !manager.isLoading { break }
        }

        #expect(!manager.isLoading)
        #expect(manager.rootNodes.contains { $0.name == "file.txt" })
    }
}
