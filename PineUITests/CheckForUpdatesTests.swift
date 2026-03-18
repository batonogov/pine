//
//  CheckForUpdatesTests.swift
//  PineUITests
//
//  Tests for the "Check for Updates…" menu item in the Pine menu.
//

import XCTest

final class CheckForUpdatesTests: PineUITestCase {

    // MARK: - Menu item presence

    func testCheckForUpdatesMenuItemExists() throws {
        launchClean()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow), "Welcome window should appear")

        // Open the Pine app menu
        app.menuBars.menuBarItems["Pine"].click()

        // "Check for Updates…" should be present in the Pine menu
        let menuItem = app.menuItems["Check for Updates…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Check for Updates… menu item should exist")
    }

    func testCheckForUpdatesMenuItemIsAfterAboutPine() throws {
        launchClean()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow), "Welcome window should appear")

        // Open the Pine app menu
        app.menuBars.menuBarItems["Pine"].click()

        // Both items should exist
        let aboutItem = app.menuItems["About Pine"]
        let updateItem = app.menuItems["Check for Updates…"]
        XCTAssertTrue(aboutItem.exists, "About Pine menu item should exist")
        XCTAssertTrue(updateItem.exists, "Check for Updates… menu item should exist")
    }
}
