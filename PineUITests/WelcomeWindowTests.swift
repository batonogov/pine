//
//  WelcomeWindowTests.swift
//  PineUITests
//
//  P0: Welcome window appearance and basic interactions.
//

import XCTest

final class WelcomeWindowTests: PineUITestCase {

    // MARK: - P0: Launch → Welcome window visible

    func testLaunchShowsWelcomeWindow() throws {
        launchClean()

        // Welcome window has identifier "welcome" (set by SwiftUI Window scene id)
        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow), "Welcome window should appear on clean launch")
    }

    func testWelcomeWindowShowsOpenFolderButton() throws {
        launchClean()

        let openFolderButton = app.buttons["welcomeOpenFolderButton"]
        XCTAssertTrue(waitForExistence(openFolderButton), "Open Folder button should be visible")
    }

    func testWelcomeWindowShowsPineTitle() throws {
        launchClean()

        // Pine title is a StaticText with value "Pine" inside the Welcome window
        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow))

        let pineTitle = welcomeWindow.staticTexts.matching(
            NSPredicate(format: "value == 'Pine'")
        ).firstMatch
        XCTAssertTrue(pineTitle.exists, "Pine title should be visible in Welcome window")
    }
}
