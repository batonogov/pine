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
        sleep(2)

        // New terminal button also uses plain buttonStyle — search in all descendants
        let newTerminalButton = app.descendants(matching: .any)["newTerminalButton"].firstMatch
        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "New terminal button should appear after showing terminal"
        )

        // Click toggle again to hide
        toggle.click()
        sleep(2)

        // New terminal button should no longer be hittable
        XCTAssertFalse(newTerminalButton.isHittable, "Terminal should be hidden after second toggle click")
    }
}
