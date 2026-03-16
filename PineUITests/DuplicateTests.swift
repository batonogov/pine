//
//  DuplicateTests.swift
//  PineUITests
//
//  Tests for file and directory duplication via sidebar context menu.
//

import XCTest

final class DuplicateTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(
            files: [
                "hello.swift": "// Hello\n",
                "docs/readme.txt": "Docs\n"
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

    /// Right-clicks a sidebar node and selects "Duplicate" from context menu.
    private func duplicateViaSidebar(_ nodeName: String) {
        let node = app.staticTexts["fileNode_\(nodeName)"]
        XCTAssertTrue(waitForExistence(node, timeout: 5), "\(nodeName) should appear in sidebar")
        node.rightClick()

        // The context menu "Duplicate" has identifier "plus.square.on.square"
        // (from the SF Symbol in the Label). Use this to distinguish from
        // the File menu "Duplicate" which has a different identifier.
        let duplicateItem = app.menuItems["plus.square.on.square"]
        XCTAssertTrue(waitForExistence(duplicateItem, timeout: 3), "Duplicate menu item should appear")
        duplicateItem.click()

        // Wait for the file tree to refresh after duplication
        sleep(2)
    }

    // MARK: - Duplicate file via context menu

    func testDuplicateFileViaSidebarCreatesFileCopy() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        duplicateViaSidebar("hello.swift")

        // The copy should appear in the sidebar
        let copyNode = app.staticTexts["fileNode_hello copy.swift"]
        XCTAssertTrue(
            waitForExistence(copyNode, timeout: 5),
            "hello copy.swift should appear in sidebar after duplicating"
        )

        // The copy should be opened in an editor tab
        let copyTab = app.buttons["editorTab_hello copy.swift"].firstMatch
        XCTAssertTrue(
            waitForExistence(copyTab, timeout: 5),
            "Duplicated file should open in an editor tab"
        )

        // The copy should exist on disk
        let copyPath = projectURL.appendingPathComponent("hello copy.swift").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: copyPath),
            "Copy file should exist on disk"
        )
    }

    // MARK: - Duplicate directory via context menu

    func testDuplicateDirectoryViaSidebarCreatesFolderCopy() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        duplicateViaSidebar("docs")

        // The copy should appear in the sidebar
        let copyNode = app.staticTexts["fileNode_docs copy"]
        XCTAssertTrue(
            waitForExistence(copyNode, timeout: 5),
            "docs copy should appear in sidebar after duplicating"
        )

        // The copy should exist on disk as a directory
        let copyPath = projectURL.appendingPathComponent("docs copy").path
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: copyPath, isDirectory: &isDir)
        XCTAssertTrue(exists, "Copy directory should exist on disk")
        XCTAssertTrue(isDir.boolValue, "Copy should be a directory")

        // Contents should be copied recursively
        let copiedFile = projectURL.appendingPathComponent("docs copy/readme.txt").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: copiedFile),
            "Files inside the directory should be copied recursively"
        )
    }

    // MARK: - Duplicate increments name when copy exists

    func testDuplicateIncrementsNameWhenCopyExists() throws {
        // Pre-create "hello copy.swift" so the next copy gets "hello copy 2.swift"
        let existingCopy = projectURL.appendingPathComponent("hello copy.swift")
        try "// existing copy\n".write(to: existingCopy, atomically: true, encoding: .utf8)

        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        duplicateViaSidebar("hello.swift")

        // Should get "hello copy 2.swift" since "hello copy.swift" already exists
        let copy2Node = app.staticTexts["fileNode_hello copy 2.swift"]
        XCTAssertTrue(
            waitForExistence(copy2Node, timeout: 5),
            "Second duplicate should be named 'hello copy 2.swift'"
        )
    }

    // MARK: - Duplicate menu appears for both files and directories

    func testDuplicateMenuItemAppearsForFile() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileNode = app.staticTexts["fileNode_hello.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5))
        fileNode.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(
            waitForExistence(duplicateItem, timeout: 3),
            "Duplicate should appear in file context menu"
        )
        // Dismiss the context menu
        app.typeKey(.escape, modifierFlags: [])
    }

    func testDuplicateMenuItemAppearsForDirectory() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let dirNode = app.staticTexts["fileNode_docs"]
        XCTAssertTrue(waitForExistence(dirNode, timeout: 5))
        dirNode.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(
            waitForExistence(duplicateItem, timeout: 3),
            "Duplicate should appear in directory context menu"
        )
        // Dismiss the context menu
        app.typeKey(.escape, modifierFlags: [])
    }
}
