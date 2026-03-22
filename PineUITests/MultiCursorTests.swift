//
//  MultiCursorTests.swift
//  PineUITests
//

import XCTest

final class MultiCursorTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "test.swift": "let foo = 1\nlet bar = 2\nlet foo = 3\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Menu items exist

    func testSelectNextOccurrenceMenuItemExists() throws {
        launchWithProject(projectURL)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        app.menuBars.menuBarItems["Edit"].click()
        let menuItem = app.menuItems["Select Next Occurrence"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3),
                      "Select Next Occurrence menu item should exist in Edit menu")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSplitSelectionIntoLinesMenuItemExists() throws {
        launchWithProject(projectURL)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        app.menuBars.menuBarItems["Edit"].click()
        let menuItem = app.menuItems["Split Selection into Lines"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3),
                      "Split Selection into Lines menu item should exist in Edit menu")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Menu items disabled without open file

    func testMultiCursorMenuItemsDisabledWithoutFile() throws {
        launchWithProject(projectURL)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Don't open any file — menu items should be disabled
        app.menuBars.menuBarItems["Edit"].click()
        let selectNext = app.menuItems["Select Next Occurrence"]
        XCTAssertTrue(selectNext.waitForExistence(timeout: 3))
        XCTAssertFalse(selectNext.isEnabled,
                       "Select Next Occurrence should be disabled without an open file")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Menu items enabled with open file

    func testMultiCursorMenuItemsEnabledWithFile() throws {
        launchWithProject(projectURL)
        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileRow = app.staticTexts["fileNode_test.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("test.swift should appear in sidebar")
            return
        }
        fileRow.click()

        let tab = app.buttons["editorTab_test.swift"]
        XCTAssertTrue(waitForExistence(tab, timeout: 5))

        app.menuBars.menuBarItems["Edit"].click()
        let selectNext = app.menuItems["Select Next Occurrence"]
        XCTAssertTrue(selectNext.waitForExistence(timeout: 3))
        XCTAssertTrue(selectNext.isEnabled,
                      "Select Next Occurrence should be enabled with an open file")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Cmd+D via menu click

    func testSelectNextOccurrenceViaMenuClick() throws {
        launchWithProject(projectURL)
        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileRow = app.staticTexts["fileNode_test.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("test.swift should appear in sidebar")
            return
        }
        fileRow.click()

        let tab = app.buttons["editorTab_test.swift"]
        XCTAssertTrue(waitForExistence(tab, timeout: 5))

        // Click "Select Next Occurrence" from Edit menu — should not crash
        app.menuBars.menuBarItems["Edit"].click()
        let selectNext = app.menuItems["Select Next Occurrence"]
        XCTAssertTrue(selectNext.waitForExistence(timeout: 3))
        if selectNext.isEnabled {
            selectNext.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        // App should still be running (no crash)
        XCTAssertTrue(app.windows.firstMatch.exists, "App should not crash after Select Next Occurrence")
    }

    // MARK: - Split Selection via menu click

    func testSplitSelectionIntoLinesViaMenuClick() throws {
        launchWithProject(projectURL)
        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileRow = app.staticTexts["fileNode_test.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("test.swift should appear in sidebar")
            return
        }
        fileRow.click()

        let tab = app.buttons["editorTab_test.swift"]
        XCTAssertTrue(waitForExistence(tab, timeout: 5))

        // Click "Split Selection into Lines" from Edit menu — should not crash
        app.menuBars.menuBarItems["Edit"].click()
        let splitLines = app.menuItems["Split Selection into Lines"]
        XCTAssertTrue(splitLines.waitForExistence(timeout: 3))
        if splitLines.isEnabled {
            splitLines.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        XCTAssertTrue(app.windows.firstMatch.exists, "App should not crash after Split Selection into Lines")
    }
}
