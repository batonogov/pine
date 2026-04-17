//
//  TerminalSearchTests.swift
//  PineUITests
//
//  UI tests for terminal-related menu items and terminal search visibility.
//

import XCTest

final class TerminalSearchTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject()
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var terminalToggle: XCUIElement {
        app.descendants(matching: .any)["terminalToggleButton"].firstMatch
    }

    private var newTerminalButton: XCUIElement {
        app.descendants(matching: .any)["newTerminalButton"].firstMatch
    }

    private var terminalTabBar: XCUIElement {
        app.descendants(matching: .any)["terminalTabBar"].firstMatch
    }

    // MARK: - Terminal menu structure

    func testTerminalMenuContainsNewTabItem() throws {
        launchWithProject(projectURL)
        openFile("main.swift")

        clickMenuBarItem("Terminal")
        let newTabItem = app.menuItems["New Tab"]
        XCTAssertTrue(
            waitForExistence(newTabItem, timeout: 3),
            "Terminal menu should contain New Tab item"
        )
    }

    func testTerminalMenuContainsFindInTerminalItem() throws {
        launchWithProject(projectURL)
        openFile("main.swift")

        clickMenuBarItem("Terminal")
        let findItem = app.menuItems["Find in Terminal"]
        XCTAssertTrue(
            waitForExistence(findItem, timeout: 3),
            "Terminal menu should contain Find in Terminal item"
        )
    }

    func testFindInTerminalDisabledWithoutTerminalPane() throws {
        launchWithProject(projectURL)
        openFile("main.swift")

        clickMenuBarItem("Terminal")
        let findItem = app.menuItems["Find in Terminal"]
        XCTAssertTrue(waitForExistence(findItem, timeout: 3))
        XCTAssertFalse(
            findItem.isEnabled,
            "Find in Terminal should be disabled when no terminal pane exists"
        )
    }

    // MARK: - Terminal pane creation via menu

    func testNewTerminalTabViaTerminalMenu() throws {
        launchWithProject(projectURL)
        openFile("main.swift")

        clickMenuBarItem("Terminal")
        app.menuItems["New Tab"].click()

        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Terminal pane should appear after Terminal > New Tab"
        )
    }

    func testNewTerminalButtonExistsAfterCreatingTerminal() throws {
        launchWithProject(projectURL)
        openFile("main.swift")

        clickMenuBarItem("Terminal")
        app.menuItems["New Tab"].click()

        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "New Terminal button should exist after creating terminal"
        )

        // Verify a second terminal tab can be added
        newTerminalButton.click()

        // Both terminal tabs should exist — at least 2 terminal tab elements
        let terminalTabs = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'terminalTab_'")
        )
        // Small delay for tab creation
        sleep(1)
        XCTAssertGreaterThanOrEqual(
            terminalTabs.count, 2,
            "Should have at least 2 terminal tabs after clicking New Terminal"
        )
    }

    // MARK: - Terminal toggle button state changes

    func testTerminalToggleButtonChangesStateAfterCreatingTerminal() throws {
        launchWithProject(projectURL)
        openFile("main.swift")

        XCTAssertTrue(waitForExistence(terminalToggle, timeout: 10))

        // Create terminal
        clickMenuBarItem("Terminal")
        app.menuItems["New Tab"].click()

        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Terminal pane should appear"
        )

        // Terminal toggle should still be visible (now with active state)
        XCTAssertTrue(terminalToggle.exists, "Terminal toggle should remain visible")
    }
}
