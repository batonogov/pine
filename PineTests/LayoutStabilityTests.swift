//
//  LayoutStabilityTests.swift
//  PineTests
//
//  Tests for layout stability during project load, sidebar refresh, and tab switching.
//  Covers WorkspaceManager loading states and EditorTabBar width stability.
//

import Foundation
import Testing

@testable import Pine

@Suite("Layout Stability Tests")
@MainActor
struct LayoutStabilityTests {

    // MARK: - WorkspaceManager loading state

    @Test("WorkspaceManager starts with isLoading false")
    func initialLoadingState() {
        let workspace = WorkspaceManager()
        #expect(!workspace.isLoading)
    }

    @Test("WorkspaceManager rootNodes starts empty")
    func initialRootNodes() {
        let workspace = WorkspaceManager()
        #expect(workspace.rootNodes.isEmpty)
    }

    @Test("WorkspaceManager preserves rootNodes during directory load when previous nodes exist")
    func preservesNodesOnReload() {
        let workspace = WorkspaceManager()

        // Simulate pre-existing nodes by setting them directly
        let dummyNode = FileNode(url: URL(fileURLWithPath: "/tmp/test.swift"))
        workspace.rootNodes = [dummyNode]

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // loadDirectory should NOT clear rootNodes to empty — old nodes remain until new ones arrive
        workspace.loadDirectory(url: tmpDir)
        #expect(!workspace.rootNodes.isEmpty)
    }

    @Test("isLoading is true during loadDirectory")
    func isLoadingDuringLoad() {
        let workspace = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        workspace.loadDirectory(url: tmpDir)
        #expect(workspace.isLoading)
    }

    @Test("isLoading becomes false after shallow load completes for empty directory",
          .timeLimit(.minutes(2)))
    func isLoadingFalseAfterEmptyDir() async throws {
        let workspace = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        workspace.loadDirectory(url: tmpDir)

        // After the GCD → Swift Concurrency rewrite (#837), the entire load
        // pipeline lives in `Task.detached` + `await MainActor.run { ... }`,
        // so the continuation resume cannot be starved by an unrelated GCD
        // main-queue block. Local: ~0.08s; CI must stay << 1s.
        await workspace.waitForLoadingComplete()
        #expect(!workspace.isLoading)
    }

    @Test("waitForLoadingComplete returns immediately when no load is in flight")
    func waitForLoadingCompleteIsNoOpWhenIdle() async {
        // Documents the contract used by `isLoadingFalseAfterEmptyDir`:
        // calling `waitForLoadingComplete()` on a fresh manager must not
        // suspend at all.
        let workspace = WorkspaceManager()
        let start = ContinuousClock.now
        await workspace.waitForLoadingComplete()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(100))
    }

    @Test("waitForLoadingComplete resumes sequential waiters within budget",
          .timeLimit(.minutes(2)))
    func waitForLoadingCompleteSequentialWaiters() async throws {
        // Calling `waitForLoadingComplete()` repeatedly must continue to
        // return promptly after the first resume — the continuation array
        // drain logic must leave the manager in a clean idle state.
        let workspace = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-seqwait-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        workspace.loadDirectory(url: tmpDir)
        await workspace.waitForLoadingComplete()
        #expect(!workspace.isLoading)

        // Subsequent waits must be no-ops (idle path).
        let start = ContinuousClock.now
        for _ in 0..<5 {
            await workspace.waitForLoadingComplete()
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(100))
    }

    // MARK: - EditorTabBar width stability

    @Test("Tab width calculation is deterministic for same inputs")
    func tabWidthDeterministic() {
        let width1 = EditorTabBar.inactiveTabWidth(availableWidth: 800, tabCount: 5)
        let width2 = EditorTabBar.inactiveTabWidth(availableWidth: 800, tabCount: 5)
        #expect(width1 == width2)
    }

    @Test("Tab width does not change when switching active tab (count stays same)")
    func tabWidthStableOnSwitch() {
        // Width depends only on available space and count, not which tab is active
        let widthBefore = EditorTabBar.inactiveTabWidth(availableWidth: 900, tabCount: 4)
        let widthAfter = EditorTabBar.inactiveTabWidth(availableWidth: 900, tabCount: 4)
        #expect(widthBefore == widthAfter)
    }

    @Test("Tab width changes smoothly when adding one tab")
    func tabWidthSmoothOnAdd() {
        let width4 = EditorTabBar.inactiveTabWidth(availableWidth: 800, tabCount: 4)
        let width5 = EditorTabBar.inactiveTabWidth(availableWidth: 800, tabCount: 5)
        // Width should decrease, but not jump to min
        #expect(width5 <= width4)
        #expect(width5 >= EditorTabBar.minTabWidth)
    }

    // MARK: - Sidebar content transition stability

    @Test("WorkspaceManager refreshFileTree does not clear rootNodes")
    @MainActor
    func refreshDoesNotClearNodes() async {
        let workspace = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a test file so there's something in the tree
        let testFile = tmpDir.appendingPathComponent("hello.txt")
        try? "hello".write(to: testFile, atomically: true, encoding: .utf8)

        workspace.loadDirectory(url: tmpDir)

        // refreshFileTree is now async (issue #1006): the shallow pass
        // runs off the main thread and lands on the main actor a few
        // milliseconds later. Poll until rootNodes is populated.
        workspace.refreshFileTree()
        for _ in 0..<200 {
            if !workspace.rootNodes.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        // rootNodes should have content (shallow tree of the directory)
        #expect(!workspace.rootNodes.isEmpty)
    }

    // MARK: - Loading state transitions

    @Test("Multiple rapid loadDirectory calls only keep the last one loading")
    func rapidLoadDirectoryCalls() {
        let workspace = WorkspaceManager()
        let tmpDir1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-1-\(UUID().uuidString)")
        let tmpDir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir1, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tmpDir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpDir1)
            try? FileManager.default.removeItem(at: tmpDir2)
        }

        workspace.loadDirectory(url: tmpDir1)
        workspace.loadDirectory(url: tmpDir2)

        // Should reflect the last-loaded project
        #expect(workspace.rootURL == tmpDir2)
        #expect(workspace.projectName == tmpDir2.lastPathComponent)
    }
}
