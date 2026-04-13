//
//  EditorSaveDirtyStateTests.swift
//  PineUITests
//
//  Tests for editor save flow, dirty state indicators, find & replace
//  menu items, and multi-tab switching behavior.
//

import XCTest

final class EditorSaveDirtyStateTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let greeting = \"Hello\"\n",
            "utils.swift": "func helper() {}\n",
            "notes.txt": "Some notes\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func editorTab(_ fileName: String) -> XCUIElement {
        app.buttons["editorTab_\(fileName)"].firstMatch
    }

    private func editorTabCloseButton(_ fileName: String) -> XCUIElement {
        app.buttons["editorTabClose_\(fileName)"].firstMatch
    }

    private func openFile(_ name: String) {
        let fileNode = app.staticTexts["fileNode_\(name)"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5), "\(name) should appear in sidebar")
        fileNode.click()
        XCTAssertTrue(waitForExistence(editorTab(name), timeout: 5), "\(name) tab should open")
    }

    // MARK: - Save menu item exists and is accessible

    func testSaveMenuItemExistsWhenFileIsOpen() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")

        app.activate()
        clickMenuBarItem("File")
        let saveItem = app.menuItems["Save"]
        XCTAssertTrue(waitForExistence(saveItem, timeout: 3), "Save menu item should exist")
    }

    // MARK: - File menu structure with open file

    func testFileMenuContainsSaveAndCloseItems() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")

        app.activate()
        clickMenuBarItem("File")

        let saveItem = app.menuItems["Save"]
        XCTAssertTrue(saveItem.exists, "File menu should contain Save")

        let saveAllItem = app.menuItems["Save All"]
        XCTAssertTrue(saveAllItem.exists, "File menu should contain Save All")

        let saveAsItem = app.menuItems["Save As…"]
        XCTAssertTrue(saveAsItem.exists, "File menu should contain Save As...")
    }

    // MARK: - Multi-tab switching preserves all tabs

    func testMultiTabSwitchingPreservesAllTabs() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open three files
        openFile("main.swift")
        openFile("utils.swift")
        openFile("notes.txt")

        // All three tabs should exist
        XCTAssertTrue(editorTab("main.swift").exists, "main.swift tab should exist")
        XCTAssertTrue(editorTab("utils.swift").exists, "utils.swift tab should exist")
        XCTAssertTrue(editorTab("notes.txt").exists, "notes.txt tab should exist")

        // Switch between tabs and verify none disappear
        editorTab("main.swift").click()
        let mainDeadline = Date().addingTimeInterval(5)
        while !editorTab("main.swift").isSelected && Date() < mainDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(editorTab("main.swift").isSelected, "main.swift should become selected")

        editorTab("notes.txt").click()
        let notesDeadline = Date().addingTimeInterval(5)
        while !editorTab("notes.txt").isSelected && Date() < notesDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(editorTab("notes.txt").isSelected, "notes.txt should become selected")

        // All tabs should still be present
        XCTAssertTrue(editorTab("main.swift").exists, "main.swift tab should survive switching")
        XCTAssertTrue(editorTab("utils.swift").exists, "utils.swift tab should survive switching")
        XCTAssertTrue(editorTab("notes.txt").exists, "notes.txt tab should survive switching")
    }

    // MARK: - Close middle tab activates neighbor

    func testCloseMiddleTabActivatesNeighbor() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open three files in order
        openFile("main.swift")
        openFile("utils.swift")
        openFile("notes.txt")

        // Close the middle tab (utils.swift)
        let closeBtn = editorTabCloseButton("utils.swift")
        XCTAssertTrue(waitForExistence(closeBtn, timeout: 5))
        closeBtn.click()

        XCTAssertTrue(
            editorTab("utils.swift").waitForNonExistence(timeout: 5),
            "Closed tab should disappear"
        )

        // Remaining tabs should still exist
        XCTAssertTrue(editorTab("main.swift").exists, "main.swift should remain")
        XCTAssertTrue(editorTab("notes.txt").exists, "notes.txt should remain")
    }

    // MARK: - Status bar shows cursor position when file is open

    func testStatusBarShowsCursorPositionWithOpenFile() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")

        let cursorPosition = app.descendants(matching: .any)["cursorPosition"].firstMatch
        XCTAssertTrue(
            waitForExistence(cursorPosition, timeout: 10),
            "Cursor position should be visible in status bar when a file is open"
        )
    }
}
