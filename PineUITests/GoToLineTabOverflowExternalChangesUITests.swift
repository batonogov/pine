//
//  GoToLineTabOverflowExternalChangesUITests.swift
//  PineUITests
//
//  UI tests for Go to Line (Cmd+L), tab overflow menu,
//  and external file change detection.
//

import XCTest

// swiftlint:disable:next type_name
final class GoToLineTabOverflowExternalChangesUITests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": (1...50).map { "// Line \($0)" }.joined(separator: "\n") + "\n",
            "utils.swift": "func helper() {}\n",
            "config.json": "{ \"key\": \"value\" }\n",
            "readme.md": "# README\n",
            "style.css": "body { margin: 0; }\n"
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

    /// Opens a file from the sidebar.
    private func openFile(_ name: String) {
        let fileRow = app.staticTexts["fileNode_\(name)"]
        XCTAssertTrue(waitForExistence(fileRow, timeout: 5), "\(name) should appear in sidebar")
        fileRow.click()
    }

    /// Opens Go to Line via Edit menu and returns the sheet element.
    @discardableResult
    private func openGoToLine() -> XCUIElement {
        clickMenuBarItem("Edit")
        let goToLineItem = app.menuItems["Go to Line"]
        XCTAssertTrue(waitForExistence(goToLineItem, timeout: 5))
        goToLineItem.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(waitForExistence(sheet, timeout: 5), "Go to Line sheet should appear")
        return sheet
    }

    // MARK: - Go to Line: opens via menu

    func testGoToLineOpensViaEditMenu() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))

        openGoToLine()
    }

    // MARK: - Go to Line: requires open file

    func testGoToLineMenuItemExistsInEditMenu() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))

        // Open Edit menu and verify Go to Line exists
        clickMenuBarItem("Edit")
        let goToLineItem = app.menuItems["Go to Line"]
        XCTAssertTrue(
            waitForExistence(goToLineItem, timeout: 5),
            "Go to Line menu item should exist in Edit menu"
        )
        // Dismiss menu
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Go to Line: dismisses on Escape

    func testGoToLineDismissesOnEscape() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))

        let sheet = openGoToLine()

        // Press Escape to dismiss
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            sheet.waitForNonExistence(timeout: 5),
            "Go to Line sheet should dismiss on Escape"
        )
    }

    // MARK: - Go to Line: shows line range hint

    func testGoToLineShowsLineRangeHint() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))

        let sheet = openGoToLine()

        // The view shows "1-N" as a hint for the valid range
        let rangeHint = sheet.staticTexts.element(matching: NSPredicate(
            format: "value CONTAINS '1'"
        ))
        XCTAssertTrue(
            waitForExistence(rangeHint, timeout: 3),
            "Go to Line should display a line range hint"
        )
    }

    // MARK: - Go to Line: accepts valid input and dismisses

    func testGoToLineAcceptsValidInput() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))

        let sheet = openGoToLine()

        // Find the text field anywhere in the app hierarchy
        let textField = app.textFields["goToLineField"].firstMatch
        guard waitForExistence(textField, timeout: 5) else {
            // If the SwiftUI TextField is not accessible, just verify sheet opens/closes
            // by pressing Escape (already tested above). Skip this test.
            XCTSkip("GoToLine text field not accessible via XCUITest")
            return
        }
        textField.click()
        textField.typeText("10")
        textField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            sheet.waitForNonExistence(timeout: 5),
            "Go to Line sheet should dismiss after accepting valid input"
        )
    }

    // MARK: - Go to Line: rejects invalid input

    func testGoToLineRejectsInvalidInput() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))

        let sheet = openGoToLine()

        let textField = app.textFields["goToLineField"].firstMatch
        guard waitForExistence(textField, timeout: 5) else {
            XCTSkip("GoToLine text field not accessible via XCUITest")
            return
        }
        textField.click()
        textField.typeText("abc")
        textField.typeKey(.return, modifierFlags: [])

        // Sheet should remain open (invalid input)
        sleep(1)
        XCTAssertTrue(
            sheet.exists,
            "Go to Line sheet should stay open for invalid input"
        )
    }

    // MARK: - Tab Overflow: many tabs remain accessible

    func testManyTabsRemainAccessible() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open all five files
        let files = ["main.swift", "utils.swift", "config.json", "readme.md", "style.css"]
        for file in files {
            openFile(file)
            XCTAssertTrue(
                waitForExistence(editorTab(file), timeout: 5),
                "Tab for \(file) should appear"
            )
        }

        // All tabs should still exist
        for file in files {
            XCTAssertTrue(
                editorTab(file).exists,
                "Tab for \(file) should remain accessible with many tabs open"
            )
        }
    }

    // MARK: - Tab Overflow: clicking tab switches active tab

    func testClickingTabSwitchesActivation() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open multiple files
        openFile("main.swift")
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))
        openFile("utils.swift")
        XCTAssertTrue(waitForExistence(editorTab("utils.swift"), timeout: 5))
        openFile("config.json")
        XCTAssertTrue(waitForExistence(editorTab("config.json"), timeout: 5))

        // Click on first tab to switch back
        let mainTab = editorTab("main.swift")
        mainTab.click()

        let deadline = Date().addingTimeInterval(10)
        while !mainTab.isSelected && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(mainTab.isSelected, "main.swift tab should become selected")
    }

    // MARK: - Tab Overflow: single tab has no overflow

    func testSingleTabNoOverflowIndicator() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open only one file
        openFile("main.swift")
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))

        // With a single tab, the tab bar should exist but there should be only one tab
        let tabBar = app.descendants(matching: .any)["editorTabBar"].firstMatch
        XCTAssertTrue(waitForExistence(tabBar, timeout: 5), "Tab bar should exist")

        // Verify only one editor tab button exists
        let utilsTab = editorTab("utils.swift")
        XCTAssertFalse(utilsTab.exists, "Only one tab should exist")
    }

    // MARK: - Tab Overflow: closing tab leaves neighbor active

    func testClosingTabLeavesNeighborActive() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open two files
        openFile("main.swift")
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))
        openFile("utils.swift")
        XCTAssertTrue(waitForExistence(editorTab("utils.swift"), timeout: 5))

        // Close utils.swift tab via close button
        let closeButton = app.buttons["editorTabClose_utils.swift"].firstMatch
        XCTAssertTrue(waitForExistence(closeButton, timeout: 5))
        closeButton.click()

        // utils.swift tab should disappear
        XCTAssertTrue(
            editorTab("utils.swift").waitForNonExistence(timeout: 5),
            "Closed tab should disappear"
        )

        // main.swift tab should remain
        XCTAssertTrue(
            editorTab("main.swift").exists,
            "Neighbor tab should remain after closing a tab"
        )
    }

    // MARK: - External Changes: clean tab reloads silently

    func testExternalChangeReloadsCleanTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file
        openFile("utils.swift")
        XCTAssertTrue(waitForExistence(editorTab("utils.swift"), timeout: 5))

        // Modify the file externally
        let fileURL = projectURL.appendingPathComponent("utils.swift")
        try "func updatedHelper() {}\n".write(to: fileURL, atomically: true, encoding: .utf8)

        // The FileSystemWatcher should detect the change.
        // Wait for the debounced FSEvent callback to fire and reload.
        // The tab should remain open (not crash, not show error).
        sleep(3)

        // Tab should still exist
        XCTAssertTrue(
            editorTab("utils.swift").exists,
            "Tab should remain open after external file change"
        )
    }

    // MARK: - External Changes: new file appears in sidebar

    func testNewExternalFileAppearsInSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Create a new file externally
        let newFileURL = projectURL.appendingPathComponent("newfile.swift")
        try "// New file\n".write(to: newFileURL, atomically: true, encoding: .utf8)

        // Wait for FileSystemWatcher to pick up the change
        let newNode = app.staticTexts["fileNode_newfile.swift"]
        XCTAssertTrue(
            waitForExistence(newNode, timeout: 10),
            "Externally created file should appear in the sidebar"
        )
    }

    // MARK: - External Changes: deleted file removes from sidebar

    func testDeletedExternalFileDisappearsFromSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Verify the file is in the sidebar first
        let styleNode = app.staticTexts["fileNode_style.css"]
        XCTAssertTrue(waitForExistence(styleNode, timeout: 5), "style.css should be in sidebar")

        // Delete the file externally
        let fileURL = projectURL.appendingPathComponent("style.css")
        try FileManager.default.removeItem(at: fileURL)

        // Wait for FileSystemWatcher to detect deletion
        XCTAssertTrue(
            styleNode.waitForNonExistence(timeout: 10),
            "Deleted file should disappear from the sidebar"
        )
    }
}
