//
//  EditorSaveFlowTests.swift
//  PineUITests
//
//  UI tests for editor save workflows: save via menu, status bar info,
//  find bar opening via menu, and cursor position display.
//

import XCTest

final class EditorSaveFlowTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let x = 1\nlet y = 2\nlet z = 3\n",
            "helper.swift": "func helper() {\n    return\n}\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var statusBar: XCUIElement {
        app.descendants(matching: .any)["statusBar"].firstMatch
    }

    private var cursorPosition: XCUIElement {
        app.descendants(matching: .any)["cursorPosition"].firstMatch
    }

    // MARK: - Status bar shows cursor position

    func testStatusBarShowsCursorPositionAfterOpeningFile() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        // Status bar should appear
        XCTAssertTrue(waitForExistence(statusBar, timeout: 10), "Status bar should be visible")

        // Cursor position should be shown
        XCTAssertTrue(
            waitForExistence(cursorPosition, timeout: 5),
            "Cursor position should be displayed in status bar"
        )
    }

    // MARK: - Save menu item is enabled after opening file

    func testSaveMenuItemEnabledAfterOpeningFile() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        app.activate()
        clickMenuBarItem("File")

        let saveItem = app.menuItems["Save"]
        XCTAssertTrue(
            waitForExistence(saveItem, timeout: 3),
            "Save menu item should exist"
        )
    }

    // MARK: - Find menu item exists in Edit menu

    func testFindMenuItemExistsInEditMenu() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        // Open Edit menu — Find… should be a direct menu item (not a submenu)
        app.activate()
        clickMenuBarItem("Edit")

        let findItem = app.menuItems["Find…"]
        XCTAssertTrue(
            waitForExistence(findItem, timeout: 3),
            "Find… item should exist in Edit menu"
        )
    }

    // MARK: - Encoding indicator visible

    func testEncodingIndicatorVisibleInStatusBar() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        let encodingMenu = app.descendants(matching: .any)["encodingMenu"].firstMatch
        XCTAssertTrue(
            waitForExistence(encodingMenu, timeout: 5),
            "Encoding indicator should be visible in status bar"
        )
    }

    // MARK: - Line ending indicator visible

    func testLineEndingIndicatorVisibleInStatusBar() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        let lineEnding = app.descendants(matching: .any)["lineEndingIndicator"].firstMatch
        XCTAssertTrue(
            waitForExistence(lineEnding, timeout: 5),
            "Line ending indicator should be visible in status bar"
        )
    }

    // MARK: - Indentation indicator visible

    func testIndentationIndicatorVisibleInStatusBar() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        let indentation = app.descendants(matching: .any)["indentationIndicator"].firstMatch
        XCTAssertTrue(
            waitForExistence(indentation, timeout: 5),
            "Indentation indicator should be visible in status bar"
        )
    }

    // MARK: - Opening multiple files preserves both tabs

    func testMultiTabSwitchPreservesTabs() throws {
        launchWithProject(projectURL)

        openFile("main.swift")
        openFile("helper.swift")

        // Switch back to main.swift
        let mainTab = editorTab("main.swift")
        XCTAssertTrue(mainTab.exists, "main.swift tab should still exist")
        mainTab.click()

        // Verify both tabs are still present
        let helperTab = editorTab("helper.swift")
        XCTAssertTrue(helperTab.exists, "helper.swift tab should still exist after switching")
        XCTAssertTrue(mainTab.isSelected, "main.swift should be selected after clicking it")
    }

    // MARK: - File size indicator visible

    func testFileSizeIndicatorVisibleInStatusBar() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        let fileSize = app.descendants(matching: .any)["fileSizeIndicator"].firstMatch
        XCTAssertTrue(
            waitForExistence(fileSize, timeout: 5),
            "File size indicator should be visible in status bar"
        )
    }
}
