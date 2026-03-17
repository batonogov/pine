//
//  FontSizeTests.swift
//  PineUITests
//
//  UI tests for editor font size zoom (Cmd+Plus/Minus/0).
//

import XCTest

final class FontSizeTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let greeting = \"Hello\"\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - View menu font size items exist

    func testViewMenuContainsFontSizeItems() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open View menu — use the last "View" menu bar item (ours, not macOS standard)
        app.activate()
        sleep(1)
        let viewMenuItems = app.menuBars.menuBarItems.matching(identifier: "View")
        let viewMenu = viewMenuItems.element(boundBy: viewMenuItems.count - 1)
        viewMenu.click()

        let increaseItem = app.menuItems["Increase Font Size"]
        XCTAssertTrue(waitForExistence(increaseItem, timeout: 3), "Increase Font Size menu item should exist")

        let decreaseItem = app.menuItems["Decrease Font Size"]
        XCTAssertTrue(decreaseItem.exists, "Decrease Font Size menu item should exist")

        let resetItem = app.menuItems["Reset Font Size"]
        XCTAssertTrue(resetItem.exists, "Reset Font Size menu item should exist")
    }

    // MARK: - Increase font size via menu

    func testIncreaseFontSizeViaMenu() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file to have an editor
        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        let tab = app.buttons["editorTab_main.swift"].firstMatch
        XCTAssertTrue(waitForExistence(tab, timeout: 5))

        // Click Increase Font Size from View menu
        app.activate()
        sleep(1)
        let viewMenuItems = app.menuBars.menuBarItems.matching(identifier: "View")
        let viewMenu = viewMenuItems.element(boundBy: viewMenuItems.count - 1)
        viewMenu.click()
        app.menuItems["Increase Font Size"].click()

        // Verify the menu item is still available (can increase again)
        sleep(1)
        viewMenu.click()
        let increaseItem = app.menuItems["Increase Font Size"]
        XCTAssertTrue(increaseItem.exists, "Increase Font Size should still be available")
    }
}
