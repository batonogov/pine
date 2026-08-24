//
//  SidebarLoadingFlickerTests.swift
//  PineTests
//
//  Tests that the progress indicator does not flicker during incremental
//  file tree refreshes triggered by the file system watcher (issue #877).
//

import Foundation
import Testing

@testable import Pine

@Suite("Sidebar Loading Flicker Tests (issue #877)")
@MainActor
struct SidebarLoadingFlickerTests {

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-flicker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - refreshFileTreeAsync must NOT trigger progress indicator

    @Test("refreshFileTreeAsync does not activate progress tracker")
    func refreshFileTreeAsyncNoProgress() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "hello".write(
            to: dir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        let tracker = ProgressTracker()
        manager.progressTracker = tracker

        // Initial load — should use progress tracker
        manager.loadDirectory(url: dir)
        #expect(tracker.isLoading, "Initial loadDirectory should activate progress tracker")

        // Waiting on `WorkspaceManager.isLoading` is not the same signal as
        // the tracker: the load ends on one main-actor hop and the progress
        // operation is ended on another, so the tracker can still be lit when
        // the load reports done. This test used to read the tracker straight
        // after `waitForLoadingComplete()` and blame the *refresh* below for
        // progress the initial load had not yet put down — one failed run in
        // three on CI, at both assertions (#1518).
        await manager.waitForLoadingComplete()
        #expect(
            await waitUntilIdle(tracker),
            "Progress tracker should be idle after initial load"
        )

        // Simulate watcher-triggered refresh (what happens on file save, git status, etc.)
        manager.refreshFileTreeAsync()

        // Progress tracker must NOT activate for incremental refresh
        #expect(
            !tracker.isLoading,
            "refreshFileTreeAsync must not activate progress tracker (causes flicker)"
        )

        // …and it must stay down while the refresh actually runs, not merely
        // in the instant after it was asked for.
        await manager.waitForLoadingComplete()
        #expect(
            !tracker.isLoading,
            "Progress tracker must remain idle after incremental refresh completes"
        )
    }

    /// Waits for the progress tracker to go idle on a wall-clock deadline.
    ///
    /// Returns `false` on timeout so the caller reports a real failure rather
    /// than hanging the suite.
    private func waitUntilIdle(
        _ tracker: ProgressTracker,
        within duration: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if !tracker.isLoading { return true }
            try? await clock.sleep(for: .milliseconds(5))
        }
        return !tracker.isLoading
    }

    @Test("refreshFileTree (sync) does not activate progress tracker")
    func refreshFileTreeSyncNoProgress() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "hello".write(
            to: dir.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        let tracker = ProgressTracker()
        manager.progressTracker = tracker

        manager.loadDirectory(url: dir)
        // Reset tracker state by simulating initial load completion
        // (loadDirectory fires async — we don't need to wait, just need rootURL set)

        // Now do sync refresh — must not trigger progress
        manager.refreshFileTree()

        // Progress tracker should still reflect only the initial loadDirectory,
        // NOT the refreshFileTree call
        // Note: loadDirectory's progress may still be active (async) — that's fine.
        // The point is refreshFileTree itself does NOT add a new operation.
        #expect(
            tracker.activeOperationCount <= 1,
            "refreshFileTree must not add its own progress operation"
        )
    }

    @Test("loadDirectory activates progress tracker")
    func loadDirectoryActivatesProgress() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        let tracker = ProgressTracker()
        manager.progressTracker = tracker

        #expect(!tracker.isLoading)

        manager.loadDirectory(url: dir)
        #expect(tracker.isLoading, "loadDirectory must activate progress tracker")
    }

    @Test("isLoading stays false during refreshFileTreeAsync after initial load")
    func isLoadingStaysFalseDuringRefresh() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "content".write(
            to: dir.appendingPathComponent("test.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()

        #expect(!manager.isLoading)

        // Watcher-triggered refresh
        manager.refreshFileTreeAsync()

        // isLoading must NOT flip to true for incremental refresh
        #expect(
            !manager.isLoading,
            "isLoading must stay false during incremental refresh (causes sidebar flicker)"
        )
    }

    @Test("Multiple rapid refreshFileTreeAsync calls do not activate progress tracker")
    func rapidRefreshesNoProgress() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "data".write(
            to: dir.appendingPathComponent("data.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        let tracker = ProgressTracker()
        manager.progressTracker = tracker

        manager.loadDirectory(url: dir)
        await manager.waitForLoadingComplete()
        #expect(await waitUntilIdle(tracker))

        // Simulate rapid watcher events (e.g., npm install creating many files)
        for _ in 0..<10 {
            manager.refreshFileTreeAsync()
        }

        #expect(
            !tracker.isLoading,
            "Rapid incremental refreshes must not activate progress tracker"
        )
    }

    @Test("loadDirectory after refresh correctly shows progress")
    func loadDirectoryAfterRefreshShowsProgress() async throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        let manager = WorkspaceManager()
        let tracker = ProgressTracker()
        manager.progressTracker = tracker

        // Initial load of dir1
        manager.loadDirectory(url: dir1)
        await manager.waitForLoadingComplete()
        #expect(await waitUntilIdle(tracker))

        // Incremental refresh — no progress
        manager.refreshFileTreeAsync()
        #expect(!tracker.isLoading)

        // Load a new project — MUST show progress
        manager.loadDirectory(url: dir2)
        #expect(tracker.isLoading, "Loading a new project must show progress indicator")
    }
}
