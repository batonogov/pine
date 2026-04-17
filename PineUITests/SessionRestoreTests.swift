//
//  SessionRestoreTests.swift
//  PineUITests
//
//  UI tests for session persistence: tabs restored after close/reopen,
//  multi-tab state preserved across sessions, terminal pane presence
//  after session restore.
//

import XCTest

final class SessionRestoreTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let x = 1\n",
            "helper.swift": "func helper() {}\n",
            "config.json": "{\n  \"key\": \"value\"\n}\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var terminalToggle: XCUIElement {
        app.descendants(matching: .any)["terminalToggleButton"].firstMatch
    }

    /// Closes the app and relaunches with the same project via recent projects.
    private func closeAndReopenProject() {
        // Close the project window
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"].firstMatch
        if closeButton.exists {
            closeButton.click()
        }

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome window should appear after closing project"
        )

        // Reopen via recent projects
        let projectName = projectURL.lastPathComponent
        let recentProject = app.buttons["welcomeRecentProject_\(projectName)"]
        XCTAssertTrue(
            waitForExistence(recentProject, timeout: 5),
            "Project should be in recent projects list"
        )
        recentProject.click()

        // Wait for project to load
        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 15),
            "Project should reopen with sidebar"
        )
    }

    // MARK: - Tests

    func testMultipleTabsRestoredAfterReopen() throws {
        launchWithProject(projectURL)

        // Open multiple files
        openFile("main.swift")
        openFile("helper.swift")
        openFile("config.json")

        // Verify all tabs exist
        XCTAssertTrue(editorTab("main.swift").exists)
        XCTAssertTrue(editorTab("helper.swift").exists)
        XCTAssertTrue(editorTab("config.json").exists)

        // Close and reopen
        closeAndReopenProject()

        // All three tabs should be restored
        XCTAssertTrue(
            waitForExistence(editorTab("main.swift"), timeout: 15),
            "main.swift tab should be restored"
        )
        XCTAssertTrue(
            waitForExistence(editorTab("helper.swift"), timeout: 5),
            "helper.swift tab should be restored"
        )
        XCTAssertTrue(
            waitForExistence(editorTab("config.json"), timeout: 5),
            "config.json tab should be restored"
        )
    }

    func testActiveTabRestoredAfterReopen() throws {
        launchWithProject(projectURL)

        // Open files and select helper.swift as active
        openFile("main.swift")
        openFile("helper.swift")
        // helper.swift should be active (last opened)

        // Close and reopen
        closeAndReopenProject()

        // helper.swift should be the active tab
        let helperTab = editorTab("helper.swift")
        XCTAssertTrue(
            waitForExistence(helperTab, timeout: 15),
            "helper.swift tab should be restored"
        )
        // Verify it is selected
        let selectedPredicate = NSPredicate(format: "isSelected == true")
        let selectedExpectation = XCTNSPredicateExpectation(
            predicate: selectedPredicate, object: helperTab
        )
        wait(for: [selectedExpectation], timeout: 10)
    }

    func testEditorTabRestoredAndClickableAfterSessionRestore() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        closeAndReopenProject()

        // Tab should be restored and clickable
        let mainTab = editorTab("main.swift")
        XCTAssertTrue(
            waitForExistence(mainTab, timeout: 15),
            "Editor tab should be visible after session restore"
        )
        // Click on the restored tab to verify it's interactive
        mainTab.click()
        XCTAssertTrue(mainTab.isSelected, "Restored tab should be selectable")
    }

    func testStatusBarVisibleAfterSessionRestore() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        closeAndReopenProject()

        let statusBar = app.descendants(matching: .any)["statusBar"].firstMatch
        XCTAssertTrue(
            waitForExistence(statusBar, timeout: 15),
            "Status bar should be visible after session restore"
        )
    }
}
