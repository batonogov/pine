//
//  TerminalTests.swift
//  PineUITests
//
//  P3: Terminal toggle, tab creation.
//

import XCTest

final class TerminalTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject()
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - New Terminal Tab via menu

    func testNewTerminalTabViaMenu() throws {
        launchWithProject(projectURL)

        // Wait for window to fully load
        let toggle = app.descendants(matching: .any)["terminalToggleButton"].firstMatch
        guard waitForExistence(toggle, timeout: 10) else {
            XCTFail("Terminal toggle should exist in status bar")
            return
        }

        // Create first terminal tab via menu — this also shows the terminal
        clickMenuBarItem("Terminal")
        app.menuItems["New Tab"].click()

        // Wait for terminal to become visible
        let newTerminalButton = app.descendants(matching: .any)["newTerminalButton"].firstMatch
        guard waitForExistence(newTerminalButton, timeout: 10) else {
            XCTFail("Terminal should become visible after New Tab")
            return
        }

        // Create second terminal tab via menu
        clickMenuBarItem("Terminal")
        app.menuItems["New Tab"].click()

        // Verify second terminal tab appeared — tab bar should have "Terminal 2"
        let secondTab = app.descendants(matching: .any)["terminalTab_Terminal 2"].firstMatch
        XCTAssertTrue(
            waitForExistence(secondTab, timeout: 10),
            "Second terminal tab should appear after Terminal → New Tab"
        )
    }

    func testNewTerminalTabShowsTerminalIfHidden() throws {
        launchWithProject(projectURL)

        // Wait for window to load
        let toggle = app.descendants(matching: .any)["terminalToggleButton"].firstMatch
        guard waitForExistence(toggle, timeout: 10) else {
            XCTFail("Terminal toggle should exist in status bar")
            return
        }

        // Terminal should be hidden by default — new terminal button should not be hittable
        let newTerminalButton = app.descendants(matching: .any)["newTerminalButton"].firstMatch
        XCTAssertFalse(newTerminalButton.isHittable, "Terminal should be hidden initially")

        // Create new terminal tab via menu — should make terminal visible
        clickMenuBarItem("Terminal")
        app.menuItems["New Tab"].click()

        // Terminal should now be visible
        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10) && newTerminalButton.isHittable,
            "Terminal should become visible after New Tab command"
        )
    }

    // MARK: - P3: Terminal toggle via status bar

    func testTerminalToggleViaStatusBarButton() throws {
        launchWithProject(projectURL)

        // Find terminal toggle — plain buttonStyle may render as .other
        let toggle = app.descendants(matching: .any)["terminalToggleButton"].firstMatch
        guard waitForExistence(toggle, timeout: 10) else {
            XCTFail("Terminal toggle should exist in status bar")
            return
        }

        // Click to show terminal
        toggle.click()

        // New terminal button also uses plain buttonStyle — search in all descendants
        let newTerminalButton = app.descendants(matching: .any)["newTerminalButton"].firstMatch
        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "New terminal button should appear after showing terminal"
        )

        // Click toggle again to hide
        toggle.click()

        // Wait for terminal to become hidden (button no longer hittable)
        let deadline = Date().addingTimeInterval(10)
        while newTerminalButton.isHittable && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(newTerminalButton.isHittable, "Terminal should be hidden after toggling off")
    }
}
