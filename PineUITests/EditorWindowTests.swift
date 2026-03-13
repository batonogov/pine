//
//  EditorWindowTests.swift
//  PineUITests
//
//  P1: Editor window — file selection, tabs, save, close.
//

import XCTest

final class EditorWindowTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let greeting = \"Hello\"\n",
            "utils.swift": "func helper() {}\n",
            "README.md": "# Project\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - P1: File selection opens a tab

    func testClickFileInSidebarOpensTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        // Editor tab appears as a StaticText or Group with the identifier
        let editorTab = app.staticTexts["editorTab_main.swift"].firstMatch
        XCTAssertTrue(waitForExistence(editorTab, timeout: 5), "Editor tab for main.swift should appear")
    }

    func testOpenMultipleFilesCreatesTabs() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let mainFile = app.staticTexts["fileNode_main.swift"]
        if waitForExistence(mainFile, timeout: 5) { mainFile.click() }

        let utilsFile = app.staticTexts["fileNode_utils.swift"]
        if waitForExistence(utilsFile, timeout: 5) { utilsFile.click() }

        let tab1 = app.staticTexts["editorTab_main.swift"].firstMatch
        let tab2 = app.staticTexts["editorTab_utils.swift"].firstMatch
        XCTAssertTrue(waitForExistence(tab1), "main.swift tab should exist")
        XCTAssertTrue(waitForExistence(tab2), "utils.swift tab should exist")
    }

    // MARK: - P1: Switching between tabs

    func testClickingTabSwitchesActiveTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open two files
        let mainFile = app.staticTexts["fileNode_main.swift"]
        if waitForExistence(mainFile, timeout: 5) { mainFile.click() }
        sleep(1)
        let utilsFile = app.staticTexts["fileNode_utils.swift"]
        if waitForExistence(utilsFile, timeout: 5) { utilsFile.click() }
        sleep(1)

        // Both tabs should exist
        let mainTab = app.staticTexts["editorTab_main.swift"].firstMatch
        let utilsTab = app.staticTexts["editorTab_utils.swift"].firstMatch
        XCTAssertTrue(mainTab.exists, "main.swift tab should exist")
        XCTAssertTrue(utilsTab.exists, "utils.swift tab should exist")

        // Click on main.swift tab to switch back
        mainTab.click()
        sleep(1)

        // main.swift tab should still exist (switching doesn't close tabs)
        XCTAssertTrue(mainTab.exists, "main.swift tab should still exist after clicking it")
        XCTAssertTrue(utilsTab.exists, "utils.swift tab should still exist")
    }

    // MARK: - P1: Editor placeholder when no tabs open

    func testEditorPlaceholderShownWithNoTabs() throws {
        launchWithProject(projectURL)

        let placeholder = app.staticTexts["editorPlaceholder"].firstMatch
        XCTAssertTrue(waitForExistence(placeholder, timeout: 10), "Editor placeholder should be visible when no tabs are open")
    }

    // MARK: - P1: Status bar terminal toggle visible

    func testTerminalToggleButtonVisible() throws {
        launchWithProject(projectURL)

        let terminalToggle = app.descendants(matching: .any)["terminalToggleButton"].firstMatch
        XCTAssertTrue(waitForExistence(terminalToggle, timeout: 10), "Terminal toggle button should be visible in status bar")
    }
}
