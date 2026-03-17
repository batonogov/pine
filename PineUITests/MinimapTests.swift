//
//  MinimapTests.swift
//  PineUITests
//
//  UI tests for the minimap panel.
//

import XCTest

final class MinimapTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Create a file with enough content to make the minimap useful
        let lines = (1...50).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        projectURL = try createTempProject(files: [
            "main.swift": lines
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// The minimap element (accessibility role = .group).
    private var minimap: XCUIElement {
        app.groups["minimap"]
    }

    // MARK: - Minimap visibility

    func testMinimapVisibleByDefault() throws {
        launchWithProject(projectURL)

        // Open a file to show the editor
        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 10) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        // Minimap should be visible by default
        XCTAssertTrue(
            waitForExistence(minimap, timeout: 5),
            "Minimap should be visible by default when a file is open"
        )
    }

    func testToggleMinimapViaMenu() throws {
        launchWithProject(projectURL)

        // Open a file
        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 10) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        XCTAssertTrue(waitForExistence(minimap, timeout: 5), "Minimap should appear")

        // Toggle minimap off via View menu
        // Use firstMatch to avoid "multiple matching elements" when system adds duplicate menu bars
        app.menuBars.firstMatch.menuBarItems["View"].click()
        let toggleItem = app.menuItems["Toggle Minimap"]
        guard waitForExistence(toggleItem, timeout: 3) else {
            XCTFail("Toggle Minimap menu item should exist")
            return
        }
        toggleItem.click()

        // Give UI time to update
        Thread.sleep(forTimeInterval: 0.5)

        // Minimap should be hidden — NSView.isHidden removes it from accessibility tree
        XCTAssertFalse(minimap.exists, "Minimap should be hidden after toggle off")

        // Toggle minimap back on via View menu
        app.menuBars.firstMatch.menuBarItems["View"].click()
        let toggleItemAgain = app.menuItems["Toggle Minimap"]
        guard waitForExistence(toggleItemAgain, timeout: 3) else {
            XCTFail("Toggle Minimap menu item should still exist")
            return
        }
        toggleItemAgain.click()

        // Minimap should reappear
        XCTAssertTrue(
            waitForExistence(minimap, timeout: 3),
            "Minimap should reappear after toggle on"
        )
    }
}
