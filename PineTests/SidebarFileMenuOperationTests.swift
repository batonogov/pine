//
//  SidebarFileMenuOperationTests.swift
//  PineTests
//
//  Tests for the File ▸ Sidebar menu command targeting (#1537): the menu
//  posts an operation, the sidebar applies it to the selected row, and
//  New Folder resolves its parent directory from that selection.
//

import Foundation
import Testing

@testable import Pine

@Suite("Sidebar file menu operations")
@MainActor
struct SidebarFileMenuOperationTests {

    private func makeTempDirectory() throws -> URL {
        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-sidebar-menu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        // Resolve firmlinks (/var -> /private/var) for consistent path comparison
        guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("New Folder without a selection targets the project root")
    func newFolderWithoutSelectionTargetsRoot() throws {
        let root = try makeTempDirectory()
        defer { cleanup(root) }

        #expect(
            SidebarMenuOperationTarget.newItemParent(
                selection: nil,
                rootURL: root
            ) == root
        )
        #expect(
            SidebarMenuOperationTarget.newItemParent(
                selection: nil,
                rootURL: nil
            ) == nil
        )
    }

    @Test("New Folder targets the selected folder, or the selected file's parent")
    func newFolderTargetsSelection() throws {
        let root = try makeTempDirectory()
        defer { cleanup(root) }

        let folderURL = root.appendingPathComponent("folder")
        let fileURL = folderURL.appendingPathComponent("file.swift")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        let rootNode = FileNode(url: root)
        let folder = try #require(rootNode.children?.first { $0.name == "folder" })
        let file = try #require(folder.children?.first { $0.name == "file.swift" })

        #expect(
            SidebarMenuOperationTarget.newItemParent(
                selection: folder,
                rootURL: root
            ) == folder.url
        )
        #expect(
            SidebarMenuOperationTarget.newItemParent(
                selection: file,
                rootURL: root
            ) == folder.url
        )
    }

    @Test("Operations are distinct and equatable for notification payloads")
    func operationPayloads() {
        #expect(SidebarFileMenuOperation.rename == .rename)
        #expect(SidebarFileMenuOperation.moveToTrash != .duplicate)
    }
}
