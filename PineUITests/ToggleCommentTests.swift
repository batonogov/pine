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

        // Wait for the window to be ready
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Window should appear")

        // Verify Edit menu has "Toggle Comment" item — doesn't require a file to be open
        app.menuBars.menuBarItems["Edit"].click()
        let toggleCommentItem = app.menuItems["Toggle Comment"]
        XCTAssertTrue(toggleCommentItem.waitForExistence(timeout: 3), "Toggle Comment menu item should exist")
        // Dismiss menu
        app.typeKey(.escape, modifierFlags: [])
    }
}
