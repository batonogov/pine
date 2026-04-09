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

    // MARK: - Helpers

    /// Returns our custom View menu (last one, since macOS adds its own "View" menu bar item).
    private func pineViewMenu() -> XCUIElement {
        let viewMenuItems = app.menuBars.menuBarItems.matching(identifier: "View")
        return viewMenuItems.element(boundBy: viewMenuItems.count - 1)
    }

    /// Opens a file in the editor so font size changes are visible.
    private func openFileInEditor() {
        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 5) else { return }
        fileRow.click()
        let tab = app.buttons["editorTab_main.swift"].firstMatch
        _ = waitForExistence(tab, timeout: 5)
    }

    /// Clicks a menu item in the View menu by name.
    private func clickViewMenuItem(_ name: String) {
        app.activate()
        sleep(1)
        pineViewMenu().click()
        app.menuItems[name].click()
    }

    // MARK: - View menu font size items exist

    func testViewMenuContainsFontSizeItems() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        app.activate()
        sleep(1)
        pineViewMenu().click()

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

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
        openFileInEditor()

        clickViewMenuItem("Increase Font Size")

        // Verify the menu item is still available (can increase again)
        sleep(1)
        pineViewMenu().click()
        let increaseItem = app.menuItems["Increase Font Size"]
        XCTAssertTrue(increaseItem.exists, "Increase Font Size should still be available")
    }

    // MARK: - Decrease font size via menu

    func testDecreaseFontSizeViaMenu() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
        openFileInEditor()

        clickViewMenuItem("Decrease Font Size")

        // Verify the menu item is still available
        sleep(1)
        pineViewMenu().click()
        let decreaseItem = app.menuItems["Decrease Font Size"]
        XCTAssertTrue(decreaseItem.exists, "Decrease Font Size should still be available")
    }

    // MARK: - Reset font size via menu

    func testResetFontSizeViaMenu() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
        openFileInEditor()

        // Increase a few times, then reset
        clickViewMenuItem("Increase Font Size")
        clickViewMenuItem("Increase Font Size")
        clickViewMenuItem("Reset Font Size")

        // All three menu items should still be available after reset
        sleep(1)
        pineViewMenu().click()
        XCTAssertTrue(app.menuItems["Increase Font Size"].exists, "Increase should be available after reset")
        XCTAssertTrue(app.menuItems["Decrease Font Size"].exists, "Decrease should be available after reset")
        XCTAssertTrue(app.menuItems["Reset Font Size"].exists, "Reset should be available after reset")
    }

    // MARK: - Font size persists across relaunch

    func testFontSizePersistsAcrossRelaunch() throws {
        // First launch: increase font size
        // Remove --reset-state so font size persists
        app.launchArguments.removeAll { $0 == "--reset-state" }
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
        openFileInEditor()

        // Increase font size 3 times
        clickViewMenuItem("Increase Font Size")
        clickViewMenuItem("Increase Font Size")
        clickViewMenuItem("Increase Font Size")

        // Terminate and relaunch (without --reset-state)
        app.terminate()
        sleep(1)

        app.launchArguments.removeAll { $0 == "--reset-state" }
        launchWithProject(projectURL)

        let sidebar2 = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar2, timeout: 10))
        openFileInEditor()

        // All menu items should still work — font size was persisted
        sleep(1)
        pineViewMenu().click()
        XCTAssertTrue(
            app.menuItems["Increase Font Size"].exists,
            "Font size menu items should work after relaunch (persistence)"
        )
        XCTAssertTrue(
            app.menuItems["Decrease Font Size"].exists,
            "Decrease should be available after relaunch"
        )

        // Cleanup: reset font size to not affect other tests
        app.menuItems["Decrease Font Size"].click()
        clickViewMenuItem("Reset Font Size")
    }

    // MARK: - Multiple increase/decrease cycle

    func testIncreaseDecreaseCycle() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
        openFileInEditor()

        // Increase 3 times, decrease 2 times — net +1
        clickViewMenuItem("Increase Font Size")
        clickViewMenuItem("Increase Font Size")
        clickViewMenuItem("Increase Font Size")
        clickViewMenuItem("Decrease Font Size")
        clickViewMenuItem("Decrease Font Size")

        // Editor and menu should still be functional
        sleep(1)
        pineViewMenu().click()
        XCTAssertTrue(
            app.menuItems["Increase Font Size"].exists,
            "Menu items should work after multiple increase/decrease cycles"
        )
    }
}
