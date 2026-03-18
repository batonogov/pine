//
//  DeleteTests.swift
//  PineUITests
//
//  Tests for file and directory deletion via sidebar context menu.
//  Regression tests for issue #210 (SIGSEGV when deleting folder).
//

import XCTest

final class DeleteTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(
            files: [
                "keep.swift": "// Keep\n",
                "delete-me.swift": "// Delete me\n",
                "subfolder/nested.txt": "Nested file\n"
            ]
        )
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Right-clicks a sidebar node and selects "Delete" from context menu.
    private func deleteViaSidebar(_ nodeName: String) {
        let node = app.staticTexts["fileNode_\(nodeName)"]
        XCTAssertTrue(waitForExistence(node, timeout: 5), "\(nodeName) should appear in sidebar")
        node.rightClick()

        let deleteItem = app.menuItems["trash"]
        XCTAssertTrue(waitForExistence(deleteItem, timeout: 3), "Delete menu item should appear")
        deleteItem.click()
    }

    // MARK: - Delete file via context menu

    func testDeleteFileViaSidebarRemovesFromSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Verify file exists before deletion
        let fileNode = app.staticTexts["fileNode_delete-me.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5))

        deleteViaSidebar("delete-me.swift")

        // File should disappear from sidebar
        XCTAssertTrue(
            fileNode.waitForNonExistence(timeout: 5),
            "Deleted file should disappear from sidebar"
        )

        // Other files should still be there
        let keepNode = app.staticTexts["fileNode_keep.swift"]
        XCTAssertTrue(keepNode.exists, "Other files should remain after deletion")

        // File should be removed from disk (moved to Trash)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("delete-me.swift").path),
            "Deleted file should not exist on disk"
        )
    }

    // MARK: - Delete folder via context menu (issue #210 regression)

    func testDeleteFolderViaSidebarDoesNotCrash() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let folderNode = app.staticTexts["fileNode_subfolder"]
        XCTAssertTrue(waitForExistence(folderNode, timeout: 5))

        deleteViaSidebar("subfolder")

        // The app should NOT crash — this is the main regression check.
        // Verify the app is still running by checking a known element.
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: 5),
            "App should still be running after folder deletion (no SIGSEGV)"
        )

        // Folder should disappear from sidebar
        XCTAssertTrue(
            folderNode.waitForNonExistence(timeout: 5),
            "Deleted folder should disappear from sidebar"
        )

        // Folder should be removed from disk
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("subfolder").path),
            "Deleted folder should not exist on disk"
        )
    }

    // MARK: - Delete file that is open in a tab

    func testDeleteOpenFileClosesTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open file in editor
        let fileNode = app.staticTexts["fileNode_delete-me.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5))
        fileNode.click()

        let tab = app.buttons["editorTab_delete-me.swift"].firstMatch
        XCTAssertTrue(waitForExistence(tab, timeout: 5), "File should open in a tab")

        // Delete the file via context menu
        deleteViaSidebar("delete-me.swift")

        // Tab should be closed
        XCTAssertTrue(
            tab.waitForNonExistence(timeout: 5),
            "Tab for deleted file should be closed"
        )

        // App should still be running
        XCTAssertTrue(sidebar.exists, "App should still be running")
    }

    // MARK: - Delete menu item appears

    func testDeleteMenuItemAppearsForFile() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileNode = app.staticTexts["fileNode_keep.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5))
        fileNode.rightClick()

        let deleteItem = app.menuItems["Delete"]
        XCTAssertTrue(
            waitForExistence(deleteItem, timeout: 3),
            "Delete should appear in file context menu"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    func testDeleteMenuItemAppearsForDirectory() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let dirNode = app.staticTexts["fileNode_subfolder"]
        XCTAssertTrue(waitForExistence(dirNode, timeout: 5))
        dirNode.rightClick()

        let deleteItem = app.menuItems["Delete"]
        XCTAssertTrue(
            waitForExistence(deleteItem, timeout: 3),
            "Delete should appear in directory context menu"
        )
        app.typeKey(.escape, modifierFlags: [])
    }
}
