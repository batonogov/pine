//
//  SidebarEditStateTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("SidebarEditState Tests")
struct SidebarEditStateTests {

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-sidebar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        // Resolve firmlinks (/var -> /private/var) for consistent path comparison
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - scrollToNodeID

    @Test("createNewItem sets scrollToNodeID for new file")
    @MainActor
    func createNewFileSetsScrollToNodeID() throws {
        let tmpDir = try makeTempDirectory()
        defer { cleanup(tmpDir) }

        let workspace = WorkspaceManager()
        workspace.loadDirectory(url: tmpDir)

        let editState = SidebarEditState()
        editState.createNewItem(in: tmpDir, isDirectory: false, workspace: workspace)

        let scrollID = try #require(editState.scrollToNodeID)
        #expect(scrollID == editState.renamingURL)
        // Verify the file was actually created on disk
        #expect(FileManager.default.fileExists(atPath: scrollID.path))
    }

    @Test("createNewItem sets scrollToNodeID for new folder")
    @MainActor
    func createNewFolderSetsScrollToNodeID() throws {
        let tmpDir = try makeTempDirectory()
        defer { cleanup(tmpDir) }

        let workspace = WorkspaceManager()
        workspace.loadDirectory(url: tmpDir)

        let editState = SidebarEditState()
        editState.createNewItem(in: tmpDir, isDirectory: true, workspace: workspace)

        let scrollID = try #require(editState.scrollToNodeID)
        #expect(scrollID == editState.renamingURL)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: scrollID.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @Test("clear does not reset scrollToNodeID")
    @MainActor
    func clearDoesNotResetScrollToNodeID() {
        let editState = SidebarEditState()
        let testURL = URL(fileURLWithPath: "/tmp/test-node")
        editState.scrollToNodeID = testURL

        editState.clear()

        // scrollToNodeID is managed separately from rename state — clear() should not touch it.
        // The view's onChange handler resets it after scrolling.
        #expect(editState.scrollToNodeID == testURL)
    }

    @Test("scrollToNodeID is nil initially")
    func scrollToNodeIDNilInitially() {
        let editState = SidebarEditState()
        #expect(editState.scrollToNodeID == nil)
    }

    @Test("duplicateItem sets scrollToNodeID")
    @MainActor
    func duplicateItemSetsScrollToNodeID() throws {
        let tmpDir = try makeTempDirectory()
        defer { cleanup(tmpDir) }

        let workspace = WorkspaceManager()
        workspace.loadDirectory(url: tmpDir)

        // Create a source file to duplicate
        let sourceURL = tmpDir.appendingPathComponent("source.txt")
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data("hello".utf8))

        let tabManager = TabManager()
        let editState = SidebarEditState()
        editState.duplicateItem(at: sourceURL, isDirectory: false, workspace: workspace, tabManager: tabManager)

        let scrollID = try #require(editState.scrollToNodeID)
        #expect(scrollID == editState.renamingURL)
        #expect(FileManager.default.fileExists(atPath: scrollID.path))
    }
}
