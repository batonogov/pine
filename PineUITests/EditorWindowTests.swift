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
        let utilsFile = app.staticTexts["fileNode_utils.swift"]
        if waitForExistence(utilsFile, timeout: 5) { utilsFile.click() }

        // Both tabs should exist
        let mainTab = editorTab("main.swift")
        let utilsTab = editorTab("utils.swift")
        XCTAssertTrue(waitForExistence(mainTab, timeout: 5), "main.swift tab should exist")
        XCTAssertTrue(waitForExistence(utilsTab, timeout: 5), "utils.swift tab should exist")

        // Click on main.swift tab to switch back
        mainTab.click()
        let deadline = Date().addingTimeInterval(10)
        while !mainTab.isSelected && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(mainTab.isSelected, "main.swift tab should become selected")

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

        // File > Duplicate via menu
        app.activate()
        clickMenuBarItem("File")
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
        clickMenuBarItem("File")
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
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file to create a session
        let mainFile = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 5))
        mainFile.click()

        let mainTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(mainTab, timeout: 5))

        // Close the project window → Welcome appears
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"].firstMatch
        XCTAssertTrue(closeButton.exists)
        closeButton.click()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10), "Welcome should appear")

        // Reopen the same project from recent projects list
        let projectName = projectURL.lastPathComponent
        let recentProject = app.buttons["welcomeRecentProject_\(projectName)"]
        XCTAssertTrue(waitForExistence(recentProject, timeout: 5), "Project should be in recents")
        recentProject.click()

        // Wait for project window to appear
        let sidebarAfterRestore = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebarAfterRestore, timeout: 15), "Project should reopen")

        // Tab should be restored from session
        let restoredTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(restoredTab, timeout: 15), "Tab should be restored from session")

        // Wait for async file tree load + syncSidebarSelection via onChange(of: rootNodes)
        let mainRow = sidebarAfterRestore.cells.containing(
            .staticText, identifier: "fileNode_main.swift"
        ).firstMatch
        XCTAssertTrue(waitForExistence(mainRow, timeout: 15), "main.swift row should exist in sidebar")

        let deadline2 = Date().addingTimeInterval(10)
        while !mainRow.isSelected && Date() < deadline2 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(mainRow.isSelected, "main.swift row should be selected in sidebar")
    }

    // MARK: - P1: Unrecognized file extensions open as text, not preview

    func testUnrecognizedExtensionOpensAsText() throws {
        // Create a project with a .go file (unrecognized by macOS UTType as text)
        let goProjectURL = try createTempProject(files: [
            "main.go": "package main\n\nfunc main() {}\n"
        ])
        defer { cleanupProject(goProjectURL) }

        launchWithProject(goProjectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        let fileRow = app.staticTexts["fileNode_main.go"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("main.go should appear in the sidebar")
            return
        }
        fileRow.click()

        let tab = editorTab("main.go")
        XCTAssertTrue(waitForExistence(tab, timeout: 5), "Editor tab for main.go should appear")

        // The code editor should be shown, not Quick Look preview
        let codeEditor = app.textViews["codeEditor"].firstMatch
        let quickLook = app.descendants(matching: .any)["quickLookPreview"].firstMatch

        XCTAssertTrue(
            waitForExistence(codeEditor, timeout: 5),
            "Code editor should be displayed for .go files"
        )
        XCTAssertFalse(
            quickLook.exists,
            "Quick Look preview should NOT be displayed for .go files"
        )
    }

    // MARK: - P1: Status bar terminal toggle visible

    func testTerminalToggleButtonVisible() throws {
        launchWithProject(projectURL)

        let terminalToggle = app.descendants(matching: .any)["terminalToggleButton"].firstMatch
        XCTAssertTrue(waitForExistence(terminalToggle, timeout: 10), "Terminal toggle button should be visible in status bar")
    }

    // MARK: - View menu structure

    func testSingleViewMenuWithRevealItems() throws {
        launchWithProject(projectURL)

        // Open a file so "Reveal File in Finder" is enabled
        let mainFile = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 10))
        mainFile.click()
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))

        // There should be exactly one View menu item in the menu bar
        let viewMenuItems = app.menuBars.menuBarItems.matching(
            NSPredicate(format: "title == 'View'")
        )
        XCTAssertEqual(viewMenuItems.count, 1, "There should be exactly one View menu")

        // Open View menu and check for Reveal items
        app.menuBars.menuBarItems["View"].click()

        let revealFile = app.menuItems["Reveal File in Finder"]
        XCTAssertTrue(revealFile.exists, "View menu should contain 'Reveal File in Finder'")

        let revealProject = app.menuItems["Reveal Project in Finder"]
        XCTAssertTrue(revealProject.exists, "View menu should contain 'Reveal Project in Finder'")
    }

    // MARK: - Sidebar context menu has Reveal in Finder

    func testSidebarContextMenuRevealInFinder() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Right-click on empty area of sidebar
        sidebar.rightClick()

        let revealItem = app.menuItems["Reveal in Finder"]
        XCTAssertTrue(
            waitForExistence(revealItem, timeout: 5),
            "Sidebar context menu should contain 'Reveal in Finder'"
        )
    }
}
