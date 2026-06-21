//
//  SidebarExpandedRefreshTests.swift
//  PineTests
//
//  Regression tests for issue #1041: new files in expanded folders don't
//  appear until the user manually collapses/expands. The fix adds a
//  `rootNodesRevision` counter that bumps on every `rootNodes` assignment,
//  enabling SidebarView to force a SwiftUI re-render via `.id()`.
//

import Foundation
import Testing

@testable import Pine

@Suite("Sidebar Expanded Folder Refresh — Issue #1041")
struct SidebarExpandedRefreshTests {

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-sidebar-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - rootNodesRevision increments on refresh

    @Test("rootNodesRevision starts at zero")
    @MainActor
    func revisionStartsAtZero() {
        let manager = WorkspaceManager()
        #expect(manager.rootNodesRevision == 0)
    }

    @Test("rootNodesRevision increments after loadDirectory")
    @MainActor
    func revisionIncrementsAfterLoad() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for the async load to set rootNodes (and bump revision).
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if manager.rootNodesRevision > 0 { break }
        }

        #expect(manager.rootNodesRevision > 0, "rootNodesRevision should increment after loadDirectory")
    }

    @Test("rootNodesRevision increments after refreshFileTreeAsync")
    @MainActor
    func revisionIncrementsAfterAsyncRefresh() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for initial load
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if manager.rootNodesRevision > 0 { break }
        }

        let revisionBeforeRefresh = manager.rootNodesRevision

        // Simulate an external FSEvents-triggered refresh
        manager.refreshFileTreeAsync()

        // Wait for the async refresh to complete
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if manager.rootNodesRevision > revisionBeforeRefresh { break }
        }

        #expect(
            manager.rootNodesRevision > revisionBeforeRefresh,
            "rootNodesRevision should increment after refreshFileTreeAsync"
        )
    }

    // MARK: - New files appear in rootNodes after external refresh

    @Test("New file in subfolder appears in rootNodes children after refreshFileTreeAsync")
    @MainActor
    func newFileInSubfolderAppearsAfterAsyncRefresh() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        // Create initial structure: project/src/existing.swift
        let srcDir = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "existing".write(
            to: srcDir.appendingPathComponent("existing.swift"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for initial load to complete
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if !manager.rootNodes.isEmpty { break }
        }

        // Verify src/ is loaded with existing.swift
        let srcNode = manager.rootNodes.first { $0.name == "src" }
        #expect(srcNode != nil, "src directory should be in rootNodes")
        let initialChildren = srcNode?.children ?? []
        #expect(initialChildren.contains { $0.name == "existing.swift" })

        // Simulate external change: agent creates a new file in src/
        try "new content".write(
            to: srcDir.appendingPathComponent("new_agent_file.swift"),
            atomically: true,
            encoding: .utf8
        )

        // Trigger the same path the FileSystemWatcher would take
        manager.refreshFileTreeAsync()

        // Wait for the async refresh to complete and pick up the new file
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(25))
            let src = manager.rootNodes.first { $0.name == "src" }
            if let children = src?.children,
               children.contains(where: { $0.name == "new_agent_file.swift" }) {
                break
            }
        }

        // Verify the new file appears in src/'s children
        let refreshedSrcNode = manager.rootNodes.first { $0.name == "src" }
        let refreshedChildren = refreshedSrcNode?.children ?? []
        #expect(
            refreshedChildren.contains { $0.name == "new_agent_file.swift" },
            "New file created in expanded subfolder should appear in rootNodes children after refresh"
        )
        #expect(
            refreshedChildren.contains { $0.name == "existing.swift" },
            "Existing file should still be present after refresh"
        )
    }

    @Test("New file in deeply nested folder appears after refreshFileTreeAsync")
    @MainActor
    func newFileInDeepFolderAppearsAfterAsyncRefresh() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        // Create: project/a/b/c/file.swift (depth 3, within shallowDepth=3)
        let deepDir = dir
            .appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        try "original".write(
            to: deepDir.appendingPathComponent("original.swift"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for initial load
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if !manager.rootNodes.isEmpty { break }
        }

        // Simulate agent creating a new file deep in the tree
        try "agent output".write(
            to: deepDir.appendingPathComponent("agent_new.swift"),
            atomically: true,
            encoding: .utf8
        )

        manager.refreshFileTreeAsync()

        // Wait for refresh and navigate the tree to find the new file
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(25))
            let aNode = manager.rootNodes.first { $0.name == "a" }
            let bNode = aNode?.children?.first { $0.name == "b" }
            let cNode = bNode?.children?.first { $0.name == "c" }
            if let cChildren = cNode?.children,
               cChildren.contains(where: { $0.name == "agent_new.swift" }) {
                break
            }
        }

        // Navigate to verify
        let aNode = manager.rootNodes.first { $0.name == "a" }
        let bNode = aNode?.children?.first { $0.name == "b" }
        let cNode = bNode?.children?.first { $0.name == "c" }
        let cChildren = cNode?.children ?? []
        #expect(
            cChildren.contains { $0.name == "agent_new.swift" },
            "New file in deeply nested folder should appear after refresh"
        )
    }

    @Test("rootNodesRevision increments for each phase (shallow + full)")
    @MainActor
    func revisionIncrementsForEachPhase() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        // Create a deep structure that triggers Phase 2 (full load)
        let deepDir = dir
            .appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
            .appendingPathComponent("d")
            .appendingPathComponent("e")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        try "deep".write(to: deepDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Wait for both phases to complete
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            if !manager.isLoading && manager.rootNodesRevision >= 2 { break }
        }

        // For a deep project: Phase 1 (shallow) sets rootNodes (revision=1),
        // Phase 2 (full) sets rootNodes again (revision=2).
        // Both phases increment the revision, ensuring the sidebar re-renders
        // after each phase — the fix for issue #1041.
        #expect(
            manager.rootNodesRevision >= 2,
            "Deep project should have at least 2 revision increments (shallow + full phases)"
        )
    }
}
