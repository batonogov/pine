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

    // MARK: - P2: Close button closes window even with open tabs

    func testCloseButtonClosesWindowWithOpenTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file to create a tab
        let fileNode = app.staticTexts["fileNode_a.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5))
        fileNode.click()

        let tab = app.buttons["editorTab_a.swift"].firstMatch
        XCTAssertTrue(waitForExistence(tab, timeout: 5), "Tab should open")

        // Click window close button — should close the window, not just the tab
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"].firstMatch
        closeButton.click()

        // Welcome window should appear (window closed entirely)
        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome should appear after closing window with open tab"
        )
    }

    // MARK: - P2: Tab close button closes tab, not window

    func testTabCloseButtonClosesTabNotWindow() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file to create a tab
        let fileNode = app.staticTexts["fileNode_a.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5))
        fileNode.click()

        let tab = app.buttons["editorTab_a.swift"].firstMatch
        XCTAssertTrue(waitForExistence(tab, timeout: 5), "Tab should open")

        // Click the tab's close button (X) — should close only the tab
        let tabCloseButton = app.buttons["editorTabClose_a.swift"].firstMatch
        XCTAssertTrue(waitForExistence(tabCloseButton, timeout: 5))
        tabCloseButton.click()

        // Tab should be gone
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5), "Tab should close")

        // Window should remain open (sidebar still visible)
        XCTAssertTrue(sidebar.exists, "Window should remain open after closing tab")
    }

    // Note: Cmd+W tab closing is handled by NSEvent.addLocalMonitorForEvents
    // in AppDelegate, but XCUITest's typeKey bypasses the app's event queue
    // (uses Accessibility APIs instead), so Cmd+W cannot be reliably UI-tested.
}
