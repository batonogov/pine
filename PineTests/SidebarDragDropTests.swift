//
//  SidebarDragDropTests.swift
//  PineTests
//
//  Tests for dragging files from the sidebar to open in specific editor panes.
//

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Pine

@Suite("Sidebar Drag & Drop Tests")
@MainActor
struct SidebarDragDropTests {

    // MARK: - Helpers

    /// Creates a temporary file for testing.
    private func tempFile(name: String = "test.swift", content: String = "hello") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - SidebarFileDragInfo encoding/decoding

    @Test("SidebarFileDragInfo encodes and decodes round-trip")
    func roundTrip() {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let info = SidebarFileDragInfo(fileURL: url)
        let encoded = info.encoded
        let decoded = SidebarFileDragInfo.decode(from: encoded)

        #expect(decoded != nil)
        #expect(decoded?.fileURL == url)
    }

    @Test("SidebarFileDragInfo decode returns nil for invalid JSON")
    func decodeInvalid() {
        let result = SidebarFileDragInfo.decode(from: "not json")
        #expect(result == nil)
    }

    @Test("SidebarFileDragInfo decode returns nil for empty string")
    func decodeEmpty() {
        let result = SidebarFileDragInfo.decode(from: "")
        #expect(result == nil)
    }

    @Test("SidebarFileDragInfo preserves file URL with spaces")
    func urlWithSpaces() {
        let url = URL(fileURLWithPath: "/tmp/my project/file name.swift")
        let info = SidebarFileDragInfo(fileURL: url)
        let decoded = SidebarFileDragInfo.decode(from: info.encoded)

        #expect(decoded?.fileURL.path == url.path)
    }

    @Test("SidebarFileDragInfo preserves deep nested path")
    func deepNestedPath() {
        let url = URL(fileURLWithPath: "/a/b/c/d/e/f/g.txt")
        let info = SidebarFileDragInfo(fileURL: url)
        let decoded = SidebarFileDragInfo.decode(from: info.encoded)

        #expect(decoded?.fileURL == url)
    }

    // MARK: - UTType

    @Test("sidebarFileDrag UTType is defined")
    func utTypeDefined() {
        let type = UTType.sidebarFileDrag
        #expect(type.identifier == "com.pine.sidebar-file-drag")
    }

    @Test("sidebarFileDrag UTType is distinct from paneTabDrag")
    func utTypeDistinct() {
        #expect(UTType.sidebarFileDrag != UTType.paneTabDrag)
    }

    // MARK: - PaneManager.openFileInPane

    @Test("openFileInPane opens file as tab in the specified pane")
    func openFileInPane() {
        let file = tempFile(name: "sidebar.swift", content: "let x = 1")
        let pm = PaneManager()
        let paneID = pm.activePaneID

        pm.openFileInPane(url: file, paneID: paneID)

        let tm = pm.tabManager(for: paneID)
        #expect(tm?.tabs.count == 1)
        #expect(tm?.activeTab?.url == file)
    }

    @Test("openFileInPane does nothing for nonexistent pane")
    func openFileInNonexistentPane() {
        let file = tempFile()
        let pm = PaneManager()
        let fakePaneID = PaneID()

        pm.openFileInPane(url: file, paneID: fakePaneID)

        // No crash, no tabs opened in active pane
        let tm = pm.tabManager(for: pm.activePaneID)
        #expect(tm?.tabs.isEmpty == true)
    }

    @Test("openFileInPane does not open duplicate tabs")
    func openFileInPaneNoDuplicate() {
        let file = tempFile(name: "dup.swift")
        let pm = PaneManager()
        let paneID = pm.activePaneID
        pm.openFileInPane(url: file, paneID: paneID)

        pm.openFileInPane(url: file, paneID: paneID)

        let tm = pm.tabManager(for: paneID)
        #expect(tm?.tabs.count == 1)
    }

    @Test("openFileInPane does nothing for terminal pane")
    func openFileInTerminalPane() {
        let file = tempFile()
        let pm = PaneManager()
        let termID = pm.createTerminalPaneAtBottom(workingDirectory: nil)

        pm.openFileInPane(url: file, paneID: termID)

        // Terminal panes have no tab manager — file should not open
        let tm = pm.tabManager(for: termID)
        #expect(tm == nil)
    }

    // MARK: - PaneManager.splitAndOpenFile

    @Test("splitAndOpenFile creates horizontal split and opens file")
    func splitAndOpenFileHorizontal() throws {
        let file = tempFile(name: "split.swift", content: "let y = 2")
        let pm = PaneManager()
        let originalPaneID = pm.activePaneID

        let newPaneID = pm.splitAndOpenFile(
            url: file, relativeTo: originalPaneID, axis: .horizontal
        )

        let newID = try #require(newPaneID)
        #expect(pm.root.leafCount == 2)
        let tm = pm.tabManager(for: newID)
        #expect(tm?.tabs.count == 1)
        #expect(tm?.activeTab?.url == file)
    }

    @Test("splitAndOpenFile creates vertical split and opens file")
    func splitAndOpenFileVertical() throws {
        let file = tempFile(name: "split-v.swift")
        let pm = PaneManager()
        let originalPaneID = pm.activePaneID

        let newPaneID = pm.splitAndOpenFile(
            url: file, relativeTo: originalPaneID, axis: .vertical
        )

        let newID = try #require(newPaneID)
        #expect(pm.root.leafCount == 2)
        let tm = pm.tabManager(for: newID)
        #expect(tm?.activeTab?.url == file)
    }

    @Test("splitAndOpenFile returns nil for nonexistent pane")
    func splitAndOpenFileNonexistentPane() {
        let file = tempFile()
        let pm = PaneManager()
        let fakePaneID = PaneID()

        let result = pm.splitAndOpenFile(url: file, relativeTo: fakePaneID, axis: .horizontal)

        #expect(result == nil)
        #expect(pm.root.leafCount == 1)
    }

    @Test("splitAndOpenFile sets new pane as active")
    func splitAndOpenFileSetsActive() {
        let file = tempFile()
        let pm = PaneManager()
        let originalPaneID = pm.activePaneID

        let newPaneID = pm.splitAndOpenFile(
            url: file, relativeTo: originalPaneID, axis: .horizontal
        )

        #expect(pm.activePaneID == newPaneID)
    }

    @Test("splitAndOpenFile preserves existing pane tabs")
    func splitAndOpenFilePreservesExistingTabs() {
        let existingFile = tempFile(name: "existing.swift")
        let newFile = tempFile(name: "new.swift")
        let pm = PaneManager()
        let originalPaneID = pm.activePaneID
        pm.tabManager(for: originalPaneID)?.openTab(url: existingFile)

        _ = pm.splitAndOpenFile(
            url: newFile, relativeTo: originalPaneID, axis: .horizontal
        )

        let originalTM = pm.tabManager(for: originalPaneID)
        #expect(originalTM?.tabs.count == 1)
        #expect(originalTM?.activeTab?.url == existingFile)
    }

    @Test("splitAndOpenFile respects max depth")
    func splitAndOpenFileMaxDepth() {
        let pm = PaneManager()
        var currentPaneID = pm.activePaneID

        // Split until max depth
        for i in 0..<(paneMaxDepth - 1) {
            let file = tempFile(name: "deep\(i).swift")
            if let newID = pm.splitAndOpenFile(
                url: file, relativeTo: currentPaneID, axis: .horizontal
            ) {
                currentPaneID = newID
            }
        }

        // Next split should fail
        let oneMore = tempFile(name: "tooDeep.swift")
        let result = pm.splitAndOpenFile(
            url: oneMore, relativeTo: currentPaneID, axis: .horizontal
        )
        #expect(result == nil)
    }

    // MARK: - PaneManager.activeSidebarDrag

    @Test("activeSidebarDrag is nil by default")
    func activeSidebarDragDefault() {
        let pm = PaneManager()
        #expect(pm.activeSidebarDrag == nil)
    }

    @Test("activeSidebarDrag can be set and read")
    func activeSidebarDragSetAndRead() {
        let pm = PaneManager()
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let info = SidebarFileDragInfo(fileURL: url)

        pm.activeSidebarDrag = info

        #expect(pm.activeSidebarDrag?.fileURL == url)
    }

    @Test("activeSidebarDrag can be cleared")
    func activeSidebarDragClear() {
        let pm = PaneManager()
        pm.activeSidebarDrag = SidebarFileDragInfo(
            fileURL: URL(fileURLWithPath: "/tmp/test.swift")
        )

        pm.activeSidebarDrag = nil

        #expect(pm.activeSidebarDrag == nil)
    }

    // MARK: - Drop zone + sidebar interaction

    @Test("PaneDropZone.zone returns center for middle area")
    func dropZoneCenterForMiddle() {
        let size = CGSize(width: 400, height: 300)
        let location = CGPoint(x: 200, y: 150)

        let zone = PaneDropZone.zone(for: location, in: size)

        #expect(zone == .center)
    }

    @Test("PaneDropZone.zone returns right for right edge")
    func dropZoneRightForRightEdge() {
        let size = CGSize(width: 400, height: 300)
        let location = CGPoint(x: 350, y: 150)

        let zone = PaneDropZone.zone(for: location, in: size)

        #expect(zone == .right)
    }

    @Test("PaneDropZone.zone returns bottom for bottom edge")
    func dropZoneBottomForBottomEdge() {
        let size = CGSize(width: 400, height: 300)
        let location = CGPoint(x: 150, y: 280)

        let zone = PaneDropZone.zone(for: location, in: size)

        #expect(zone == .bottom)
    }

    // MARK: - Integration: sidebar drag to center opens file in pane

    @Test("Center drop from sidebar opens file as tab in target pane")
    func centerDropOpensFile() {
        let file = tempFile(name: "center.swift", content: "// center")
        let pm = PaneManager()
        let paneID = pm.activePaneID

        // Simulate what PaneSplitDropDelegate does for center sidebar drop
        pm.openFileInPane(url: file, paneID: paneID)

        let tm = pm.tabManager(for: paneID)
        #expect(tm?.tabs.count == 1)
        #expect(tm?.activeTab?.url == file)
    }

    // MARK: - Integration: sidebar drag to edge creates split

    @Test("Right edge drop from sidebar creates horizontal split with file")
    func rightEdgeDropCreatesSplit() {
        let file = tempFile(name: "right.swift", content: "// right")
        let pm = PaneManager()
        let paneID = pm.activePaneID

        // Simulate what PaneSplitDropDelegate does for right edge sidebar drop
        let newPaneID = pm.splitAndOpenFile(url: file, relativeTo: paneID, axis: .horizontal)

        #expect(newPaneID != nil)
        #expect(pm.root.leafCount == 2)
    }

    @Test("Bottom edge drop from sidebar creates vertical split with file")
    func bottomEdgeDropCreatesSplit() {
        let file = tempFile(name: "bottom.swift", content: "// bottom")
        let pm = PaneManager()
        let paneID = pm.activePaneID

        let newPaneID = pm.splitAndOpenFile(url: file, relativeTo: paneID, axis: .vertical)

        #expect(newPaneID != nil)
        #expect(pm.root.leafCount == 2)
    }

    // MARK: - Edge: directories should not open as tabs

    @Test("openFileInPane does not open directories")
    func openDirectoryDoesNothing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pm = PaneManager()
        let paneID = pm.activePaneID

        pm.openFileInPane(url: dir, paneID: paneID)

        let tm = pm.tabManager(for: paneID)
        #expect(tm?.tabs.isEmpty == true)
    }

    // MARK: - clearStaleDragState

    @Test("clearStaleDragState clears activeSidebarDrag")
    func clearStaleDragStateClearsSidebar() {
        let pm = PaneManager()
        pm.activeSidebarDrag = SidebarFileDragInfo(
            fileURL: URL(fileURLWithPath: "/tmp/test.swift")
        )

        pm.clearStaleDragState()

        #expect(pm.activeSidebarDrag == nil)
    }

    @Test("clearStaleDragState clears activeDrag")
    func clearStaleDragStateClearsTab() {
        let pm = PaneManager()
        pm.activeDrag = TabDragInfo(
            paneID: pm.activePaneID.id,
            tabID: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/test.swift")
        )

        pm.clearStaleDragState()

        #expect(pm.activeDrag == nil)
    }

    @Test("clearStaleDragState clears both drag states simultaneously")
    func clearStaleDragStateClearsBoth() {
        let pm = PaneManager()
        pm.activeSidebarDrag = SidebarFileDragInfo(
            fileURL: URL(fileURLWithPath: "/tmp/sidebar.swift")
        )
        pm.activeDrag = TabDragInfo(
            paneID: pm.activePaneID.id,
            tabID: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/tab.swift")
        )

        pm.clearStaleDragState()

        #expect(pm.activeSidebarDrag == nil)
        #expect(pm.activeDrag == nil)
    }

    @Test("clearStaleDragState is safe when both are already nil")
    func clearStaleDragStateWhenAlreadyNil() {
        let pm = PaneManager()

        pm.clearStaleDragState()

        #expect(pm.activeSidebarDrag == nil)
        #expect(pm.activeDrag == nil)
    }

    // MARK: - openFileInPane with percent-encoded URLs

    @Test("openFileInPane handles files with spaces in path")
    func openFileWithSpacesInPath() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("my project")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("my file.swift")
        try? "let x = 1".write(to: file, atomically: true, encoding: .utf8)

        let pm = PaneManager()
        let paneID = pm.activePaneID

        pm.openFileInPane(url: file, paneID: paneID)

        let tm = pm.tabManager(for: paneID)
        #expect(tm?.tabs.count == 1)
        #expect(tm?.activeTab?.url == file)
    }

    @Test("openFileInPane skips directory with spaces in path")
    func openDirectoryWithSpacesDoesNothing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("my directory")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let pm = PaneManager()
        let paneID = pm.activePaneID

        pm.openFileInPane(url: dir, paneID: paneID)

        let tm = pm.tabManager(for: paneID)
        #expect(tm?.tabs.isEmpty == true)
    }

    // MARK: - splitAndOpenFile reuses splitPane

    @Test("splitAndOpenFile sets activePaneID to the new pane (via splitPane)")
    func splitAndOpenFileActivePaneViaDelegate() throws {
        let file = tempFile(name: "delegate.swift")
        let pm = PaneManager()
        let originalPaneID = pm.activePaneID

        let newPaneID = pm.splitAndOpenFile(
            url: file, relativeTo: originalPaneID, axis: .horizontal
        )

        let newID = try #require(newPaneID)
        #expect(pm.activePaneID == newID)
        // Verify the new pane has a registered TabManager (created by splitPane)
        #expect(pm.tabManager(for: newID) != nil)
    }

    // MARK: - Multiple files sequentially

    @Test("Opening multiple files in same pane creates multiple tabs")
    func multipleFilesInSamePane() {
        let file1 = tempFile(name: "a.swift")
        let file2 = tempFile(name: "b.swift")
        let file3 = tempFile(name: "c.swift")
        let pm = PaneManager()
        let paneID = pm.activePaneID

        pm.openFileInPane(url: file1, paneID: paneID)
        pm.openFileInPane(url: file2, paneID: paneID)
        pm.openFileInPane(url: file3, paneID: paneID)

        let tm = pm.tabManager(for: paneID)
        #expect(tm?.tabs.count == 3)
        #expect(tm?.activeTab?.url == file3)
    }

    // MARK: - Split then open in new pane

    @Test("Split and open file leaves original pane unchanged")
    func splitDoesNotModifyOriginal() {
        let originalFile = tempFile(name: "original.swift")
        let newFile = tempFile(name: "new.swift")
        let pm = PaneManager()
        let originalPaneID = pm.activePaneID
        pm.tabManager(for: originalPaneID)?.openTab(url: originalFile)

        _ = pm.splitAndOpenFile(url: newFile, relativeTo: originalPaneID, axis: .horizontal)

        let originalTM = pm.tabManager(for: originalPaneID)
        #expect(originalTM?.tabs.count == 1)
        #expect(originalTM?.activeTab?.url == originalFile)
    }
}
