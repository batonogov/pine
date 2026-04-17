//
//  SplitPaneLifecycleTests.swift
//  PineUITests
//
//  Tests for split pane lifecycle: creating terminal panes via menu,
//  verifying pane dividers, closing panes, and session restore behavior.
//

import XCTest

final class SplitPaneLifecycleTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let x = 1\n",
            "test.swift": "let y = 2\n",
            "config.json": "{}\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func terminalTab(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["terminalTab_\(name)"].firstMatch
    }

    private var terminalToggle: XCUIElement {
        app.descendants(matching: .any)["terminalToggleButton"].firstMatch
    }

    private var newTerminalButton: XCUIElement {
        app.descendants(matching: .any)["newTerminalButton"].firstMatch
    }

    private var hideButton: XCUIElement {
        app.descendants(matching: .any)["hideTerminalButton"].firstMatch
    }

    private var paneDividers: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "paneDivider")
    }

    private func createTerminalViaMenu() {
        clickMenuBarItem("Terminal")
        app.menuItems["New Tab"].click()
    }

    private func launchAndWaitForLoad() {
        launchWithProject(projectURL)
        guard waitForExistence(terminalToggle, timeout: 10) else {
            XCTFail("Window failed to load")
            return
        }
    }

    // MARK: - Terminal toggle creates and removes split

    func testTerminalToggleCreatesSplitWithDivider() throws {
        launchAndWaitForLoad()
        openFile("main.swift")

        // No divider initially
        XCTAssertEqual(paneDividers.count, 0, "No pane divider should exist initially")

        // Click terminal toggle to create terminal pane
        terminalToggle.click()

        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Terminal should appear after toggle"
        )

        // Divider should now exist
        let divider = paneDividers.firstMatch
        XCTAssertTrue(
            waitForExistence(divider, timeout: 5),
            "Pane divider should appear between editor and terminal"
        )
    }

    // MARK: - Hide terminal restores single pane

    func testHideTerminalRestoresSinglePane() throws {
        launchAndWaitForLoad()
        openFile("main.swift")

        // Create terminal
        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(terminalTab("Terminal 1"), timeout: 10),
            "Terminal 1 should appear"
        )

        // Hide terminal
        hideButton.click()

        // Wait for divider to disappear
        let divider = paneDividers.firstMatch
        let predicate = NSPredicate(format: "exists == false")
        let dividerGone = XCTNSPredicateExpectation(predicate: predicate, object: divider)
        wait(for: [dividerGone], timeout: 5)
        XCTAssertFalse(divider.exists, "Pane divider should disappear after closing terminal")

        // Editor tab should still be there
        XCTAssertTrue(
            editorTab("main.swift").exists,
            "Editor tab should survive terminal close"
        )
    }

    // MARK: - Multiple terminal tabs via plus button in split pane

    func testMultipleTerminalTabsInSplitPane() throws {
        launchAndWaitForLoad()
        openFile("main.swift")

        // Create terminal pane
        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Terminal should appear"
        )

        // Add second and third tabs
        newTerminalButton.click()
        XCTAssertTrue(
            waitForExistence(terminalTab("Terminal 2"), timeout: 5),
            "Terminal 2 should appear"
        )

        newTerminalButton.click()
        XCTAssertTrue(
            waitForExistence(terminalTab("Terminal 3"), timeout: 5),
            "Terminal 3 should appear"
        )

        // All tabs should coexist
        XCTAssertTrue(terminalTab("Terminal 1").exists, "Terminal 1 should exist")
        XCTAssertTrue(terminalTab("Terminal 2").exists, "Terminal 2 should exist")
        XCTAssertTrue(terminalTab("Terminal 3").exists, "Terminal 3 should exist")

        // Editor tab should also still be visible
        XCTAssertTrue(
            editorTab("main.swift").exists,
            "Editor tab should remain visible alongside terminal tabs"
        )
    }

    // MARK: - Session restore preserves open tabs

    func testSessionRestorePreservesOpenTabs() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open two files
        openFile("main.swift")
        openFile("test.swift")

        // Both tabs should exist
        XCTAssertTrue(editorTab("main.swift").exists, "main.swift tab should exist")
        XCTAssertTrue(editorTab("test.swift").exists, "test.swift tab should exist")

        // Close the window to trigger session save
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"].firstMatch
        XCTAssertTrue(closeButton.exists)
        closeButton.click()

        // Wait for Welcome window
        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10), "Welcome should appear")

        // Reopen from recent projects
        let projectName = projectURL.lastPathComponent
        let recentProject = app.buttons["welcomeRecentProject_\(projectName)"]
        XCTAssertTrue(
            waitForExistence(recentProject, timeout: 5),
            "Project should be in recents"
        )
        recentProject.click()

        // Wait for project to reopen
        let sidebarAfterRestore = app.scrollViews["sidebar"]
        XCTAssertTrue(
            waitForExistence(sidebarAfterRestore, timeout: 15),
            "Project should reopen"
        )

        // Both tabs should be restored
        let restoredMain = editorTab("main.swift")
        XCTAssertTrue(
            waitForExistence(restoredMain, timeout: 15),
            "main.swift tab should be restored from session"
        )

        let restoredTest = editorTab("test.swift")
        XCTAssertTrue(
            waitForExistence(restoredTest, timeout: 15),
            "test.swift tab should be restored from session"
        )
    }

    // MARK: - Editor and terminal coexist after sidebar file click

    func testEditorAndTerminalCoexistAfterSidebarClick() throws {
        launchAndWaitForLoad()

        // Create terminal first (without opening any file)
        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(terminalTab("Terminal 1"), timeout: 10),
            "Terminal 1 should appear"
        )

        // Now click a file in sidebar — should create editor pane alongside terminal
        openFile("main.swift")

        // Both should be visible
        XCTAssertTrue(
            editorTab("main.swift").exists,
            "Editor tab should be visible"
        )
        XCTAssertTrue(
            terminalTab("Terminal 1").exists,
            "Terminal tab should still exist"
        )

        // Divider should exist between them
        let divider = paneDividers.firstMatch
        XCTAssertTrue(
            waitForExistence(divider, timeout: 5),
            "Pane divider should exist between editor and terminal"
        )
    }

    // MARK: - Reopen project shows correct file tree

    func testReopenProjectShowsCorrectFileTree() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Verify all files appear in sidebar
        let mainNode = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainNode, timeout: 5), "main.swift should appear")

        let testNode = app.staticTexts["fileNode_test.swift"]
        XCTAssertTrue(waitForExistence(testNode, timeout: 5), "test.swift should appear")

        let configNode = app.staticTexts["fileNode_config.json"]
        XCTAssertTrue(waitForExistence(configNode, timeout: 5), "config.json should appear")

        // Close and reopen
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"].firstMatch
        closeButton.click()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10))

        let projectName = projectURL.lastPathComponent
        let recentProject = app.buttons["welcomeRecentProject_\(projectName)"]
        XCTAssertTrue(waitForExistence(recentProject, timeout: 5))
        recentProject.click()

        // File tree should be intact
        let sidebarAfter = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebarAfter, timeout: 15))

        XCTAssertTrue(
            waitForExistence(app.staticTexts["fileNode_main.swift"], timeout: 10),
            "main.swift should appear after reopen"
        )
        XCTAssertTrue(
            waitForExistence(app.staticTexts["fileNode_test.swift"], timeout: 10),
            "test.swift should appear after reopen"
        )
        XCTAssertTrue(
            waitForExistence(app.staticTexts["fileNode_config.json"], timeout: 10),
            "config.json should appear after reopen"
        )
    }
}
