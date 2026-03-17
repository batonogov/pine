//
//  ToggleCommentTests.swift
//  PineUITests
//

import XCTest

final class ToggleCommentTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "hello.swift": "let x = 1\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    func testToggleCommentMenuItemExists() throws {
        launchWithProject(projectURL)

        // Click on the file in the sidebar to open it
        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        let fileRow = app.staticTexts["fileNode_hello.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("hello.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        // Verify the editor tab appeared
        let tab = app.buttons["editorTab_hello.swift"].firstMatch
        XCTAssertTrue(waitForExistence(tab, timeout: 5), "Editor tab should appear")

        // Verify Edit menu has "Toggle Comment" item
        app.menuBars.menuBarItems["Edit"].click()
        let toggleCommentItem = app.menuItems["Toggle Comment"]
        XCTAssertTrue(toggleCommentItem.waitForExistence(timeout: 3), "Toggle Comment menu item should exist")
        // Dismiss menu
        app.typeKey(.escape, modifierFlags: [])
    }
}
