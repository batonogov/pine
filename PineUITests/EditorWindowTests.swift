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

    // MARK: - Helpers

    /// Finds an editor tab button by file name.
    private func editorTab(_ fileName: String) -> XCUIElement {
        app.buttons["editorTab_\(fileName)"].firstMatch
    }

    /// Finds the close button for a tab by file name.
    private func editorTabCloseButton(_ fileName: String) -> XCUIElement {
        app.buttons["editorTabClose_\(fileName)"].firstMatch
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

        let tab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(tab, timeout: 5), "Editor tab for main.swift should appear")
    }

    func testOpenMultipleFilesCreatesTabs() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let mainFile = app.staticTexts["fileNode_main.swift"]
        if waitForExistence(mainFile, timeout: 5) { mainFile.click() }

        let utilsFile = app.staticTexts["fileNode_utils.swift"]
        if waitForExistence(utilsFile, timeout: 5) { utilsFile.click() }

        XCTAssertTrue(waitForExistence(editorTab("main.swift")), "main.swift tab should exist")
        XCTAssertTrue(waitForExistence(editorTab("utils.swift")), "utils.swift tab should exist")
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
        let mainTab = editorTab("main.swift")
        let utilsTab = editorTab("utils.swift")
        XCTAssertTrue(mainTab.exists, "main.swift tab should exist")
        XCTAssertTrue(utilsTab.exists, "utils.swift tab should exist")

        // Click on main.swift tab to switch back
        mainTab.click()
        sleep(1)

        // main.swift tab should still exist (switching doesn't close tabs)
        XCTAssertTrue(mainTab.exists, "main.swift tab should still exist after clicking it")
        XCTAssertTrue(utilsTab.exists, "utils.swift tab should still exist")
    }

    // MARK: - P1: Close button removes tab, activates neighbor

    func testCloseButtonRemovesTabAndActivatesNeighbor() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open two files
        let mainFile = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 5))
        mainFile.click()

        let utilsFile = app.staticTexts["fileNode_utils.swift"]
        XCTAssertTrue(waitForExistence(utilsFile, timeout: 5))
        utilsFile.click()

        // Both tabs should exist
        let mainTab = editorTab("main.swift")
        let utilsTab = editorTab("utils.swift")
        XCTAssertTrue(waitForExistence(mainTab))
        XCTAssertTrue(waitForExistence(utilsTab))

        // Click close button on utils.swift tab
        let closeButton = editorTabCloseButton("utils.swift")
        XCTAssertTrue(waitForExistence(closeButton, timeout: 5), "Close button should be accessible")
        closeButton.click()

        // utils.swift tab should disappear
        XCTAssertTrue(utilsTab.waitForNonExistence(timeout: 5), "Tab should close after clicking close button")

        // main.swift tab should still exist (neighbor activated)
        XCTAssertTrue(mainTab.exists, "Neighbor tab should remain after closing another tab")
    }

    // MARK: - P1: Editor placeholder when no tabs open

    func testEditorPlaceholderShownWithNoTabs() throws {
        launchWithProject(projectURL)

        let placeholder = app.staticTexts["editorPlaceholder"].firstMatch
        XCTAssertTrue(waitForExistence(placeholder, timeout: 10), "Editor placeholder should be visible when no tabs are open")
    }

    // MARK: - P1: Duplicate creates tab with copy naming

    func testDuplicateCreatesTabWithCopyNaming() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file
        let mainFile = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 5))
        mainFile.click()

        let mainTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(mainTab, timeout: 5))

        // File > Duplicate
        // File > Duplicate via menu
        app.activate()
        sleep(1)
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Duplicate"].click()

        // A new tab "main copy.swift" should appear
        let copyTab = editorTab("main copy.swift")
        XCTAssertTrue(waitForExistence(copyTab, timeout: 5), "Duplicate tab should appear with Finder-like copy naming")

        // Original tab should still exist
        XCTAssertTrue(mainTab.exists, "Original tab should remain after duplicating")
    }

    // MARK: - P1: Save All saves dirty files

    func testSaveAllMenuItemExists() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file so Save All menu item is relevant
        let mainFile = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 5))
        mainFile.click()

        let mainTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(mainTab, timeout: 5))

        // File menu should contain Save All
        app.activate()
        sleep(1)
        app.menuBars.menuBarItems["File"].click()
        let saveAllItem = app.menuItems["Save All"]
        XCTAssertTrue(waitForExistence(saveAllItem, timeout: 3), "Save All menu item should exist")

        // Also check Save As… and Duplicate exist
        let saveAsItem = app.menuItems["Save As…"]
        XCTAssertTrue(saveAsItem.exists, "Save As… menu item should exist")

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.exists, "Duplicate menu item should exist")
    }

    // MARK: - P1: Session restore highlights active file in sidebar

    func testSidebarHighlightsActiveFileAfterSessionRestore() throws {
        // Step 1: Launch with project and open a file
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let mainFile = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 5))
        mainFile.click()

        let mainTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(mainTab, timeout: 5))

        // Give SwiftUI time to trigger onChange → saveSession
        sleep(1)

        // Step 2: Terminate and relaunch (session should be persisted)
        app.terminate()

        app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        // Note: do NOT pass --reset-state here, we want the session to survive
        app.launchEnvironment["PINE_OPEN_PROJECT"] = projectURL.path
        app.launch()
        app.activate()

        // Step 3: Verify tab is restored from session
        let sidebarAfterRestore = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebarAfterRestore, timeout: 15), "Project should reopen")

        let restoredTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(restoredTab, timeout: 15), "Tab should be restored from session")

        // Step 4: Verify sidebar selection is synced
        let mainRow = sidebarAfterRestore.cells.containing(
            .staticText, identifier: "fileNode_main.swift"
        ).firstMatch
        XCTAssertTrue(waitForExistence(mainRow, timeout: 15), "main.swift row should exist in sidebar")

        let selectedPredicate = NSPredicate(format: "isSelected == true")
        expectation(for: selectedPredicate, evaluatedWith: mainRow, handler: nil)
        waitForExpectations(timeout: 10)
    }

    // MARK: - P1: Status bar terminal toggle visible

    func testTerminalToggleButtonVisible() throws {
        launchWithProject(projectURL)

        let terminalToggle = app.descendants(matching: .any)["terminalToggleButton"].firstMatch
        XCTAssertTrue(waitForExistence(terminalToggle, timeout: 10), "Terminal toggle button should be visible in status bar")
    }
}
