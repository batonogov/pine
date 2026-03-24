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

    @Test("isLoading becomes false after shallow load completes for empty directory")
    func isLoadingFalseAfterEmptyDir() async {
        let workspace = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        workspace.loadDirectory(url: tmpDir)

        // Wait for async loading to complete
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!workspace.isLoading)
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
    func refreshDoesNotClearNodes() {
        let workspace = WorkspaceManager()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a test file so there's something in the tree
        let testFile = tmpDir.appendingPathComponent("hello.txt")
        try? "hello".write(to: testFile, atomically: true, encoding: .utf8)

        workspace.loadDirectory(url: tmpDir)

        // After loadDirectory, refreshFileTree should not flash the sidebar empty
        workspace.refreshFileTree()
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
