//
//  MultiWindowTests.swift
//  PineUITests
//
//  P2: Multi-window scenarios.
//

import XCTest

final class MultiWindowTests: PineUITestCase {

    private var projectURL: URL!
    private var projectURL2: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: ["a.swift": "// A\n"])
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        if let url = projectURL2 { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - P2: Single project opens in its own window

    func testOpenProjectShowsEditorWindow() throws {
        launchWithProject(projectURL)

        let projectWindow = app.windows.firstMatch
        XCTAssertTrue(
            waitForExistence(projectWindow, timeout: 10),
            "Project window should appear"
        )

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 5), "Sidebar should be present")
    }

    // MARK: - P2: Sidebar shows project files

    func testSidebarShowsProjectFiles() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileNode = app.staticTexts["fileNode_a.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5), "a.swift should appear in sidebar")
    }

    // MARK: - P2: Close last project → Welcome appears

    func testCloseLastProjectShowsWelcome() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Project should open")

        // Close the project window via the close button
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"].firstMatch
        XCTAssertTrue(closeButton.exists, "Window close button should exist")
        closeButton.click()

        // Welcome window should appear
        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome should appear after closing last project"
        )
    }

    // MARK: - P2: Close project with open tab → tab closes first, then window

    func testCloseProjectWithTabClosesTabFirst() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file to create a tab
        let fileNode = app.staticTexts["fileNode_a.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5))
        fileNode.click()

        let tab = app.buttons["editorTab_a.swift"].firstMatch
        XCTAssertTrue(waitForExistence(tab, timeout: 5), "Tab should open")

        // Click window close button — should close the tab, not the window
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"].firstMatch
        closeButton.click()

        // Tab should be gone
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5), "Tab should close first")

        // Sidebar should still be present (window not closed)
        XCTAssertTrue(sidebar.exists, "Window should remain open after tab close")

        // Click close again — now window should close and Welcome appears
        closeButton.click()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome should appear after closing window with no tabs"
        )
    }
}
