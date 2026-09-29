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

    @Test("Sidebar focus restoration is an explicit monotonic request")
    func sidebarFocusRestorationRequest() {
        let editState = SidebarEditState()
        #expect(editState.focusRestorationGeneration == 0)

        editState.clear()
        #expect(editState.focusRestorationGeneration == 0)

        editState.requestSidebarFocusRestoration()
        #expect(editState.focusRestorationGeneration == 1)
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

    // MARK: - Reveal intent (#1537)

    @Test("createNewItem and duplicateItem reveal intentionally")
    @MainActor
    func createAndDuplicateRevealIntentionally() throws {
        let tmpDir = try makeTempDirectory()
        defer { cleanup(tmpDir) }

        let workspace = WorkspaceManager()
        workspace.loadDirectory(url: tmpDir)

        let editState = SidebarEditState()
        #expect(editState.scrollRevealIntent == .intentional)
        editState.createNewItem(in: tmpDir, isDirectory: true, workspace: workspace)
        #expect(editState.scrollRevealIntent == .intentional)

        let sourceURL = tmpDir.appendingPathComponent("source.txt")
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data("hello".utf8))
        editState.duplicateItem(
            at: sourceURL,
            isDirectory: false,
            workspace: workspace,
            tabManager: TabManager()
        )
        #expect(editState.scrollRevealIntent == .intentional)
    }

    @Test("requestScroll pairs the target with its intent")
    @MainActor
    func requestScrollPairsIntent() {
        let editState = SidebarEditState()
        let url = URL(fileURLWithPath: "/tmp/renamed.swift")

        editState.requestScroll(to: url, intent: .minimal)

        #expect(editState.scrollToNodeID == url)
        #expect(editState.scrollRevealIntent == .minimal)
    }

    // MARK: - deleteItem (#1537)

    @Test("deleteItem trashes a file inside the project root")
    @MainActor
    func deleteItemTrashesFile() throws {
        let tmpDir = try makeTempDirectory()
        defer { cleanup(tmpDir) }

        let workspace = WorkspaceManager()
        workspace.loadDirectory(url: tmpDir)

        let fileURL = tmpDir.appendingPathComponent("doomed.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("bye".utf8))

        SidebarEditState().deleteItem(at: fileURL, workspace: workspace)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("deleteItem refuses paths outside the project root")
    @MainActor
    func deleteItemRefusesOutsideRoot() throws {
        let tmpDir = try makeTempDirectory()
        let outsideDir = try makeTempDirectory()
        defer {
            cleanup(tmpDir)
            cleanup(outsideDir)
        }

        let workspace = WorkspaceManager()
        workspace.loadDirectory(url: tmpDir)

        let outsideFile = outsideDir.appendingPathComponent("safe.txt")
        FileManager.default.createFile(atPath: outsideFile.path, contents: Data("keep".utf8))

        SidebarEditState().deleteItem(at: outsideFile, workspace: workspace)

        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }
}
