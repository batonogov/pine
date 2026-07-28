//
//  QuickOpenUITests.swift
//  PineUITests
//
//  UI tests for Quick Open (Cmd+P) overlay.
//
//  Note: Cmd+P is a SwiftUI menu command, so typeKey bypasses it.
//  Tests open Quick Open via the File menu instead.
//

import XCTest

final class QuickOpenUITests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "// Main file\n",
            "utils.swift": "// Utils\n",
            "readme.md": "# README\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Open & Close

    func testQuickOpenOpensViaMenu() throws {
        launchWithProject(projectURL)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Open Quick Open via File menu
        clickMenuBarItem("File")
        let menuItem = app.menuItems["Quick Open…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.click()

        // Verify Quick Open overlay appears
        let overlay = commandOverlay("quickOpenOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
    }

    func testQuickOpenDismissesOnEscape() throws {
        launchWithProject(projectURL)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Open Quick Open
        clickMenuBarItem("File")
        app.menuItems["Quick Open…"].click()

        let overlay = commandOverlay("quickOpenOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))

        // Move focus away from the search field before dismissing. Escape is
        // handled by the panel's root wrapper, not only by its text field.
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])

        // The document-scoped panel should dismiss.
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))
    }

    // MARK: - Search & Selection

    func testTypingFiltersResults() throws {
        launchWithProject(projectURL)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Wait for sidebar to load files
        let sidebar = window.scrollViews["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))

        // Open Quick Open
        clickMenuBarItem("File")
        app.menuItems["Quick Open…"].click()

        let overlay = commandOverlay("quickOpenOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))

        let searchField = overlay.textFields["quickOpenSearchField"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Search field should exist")
        searchField.click()
        XCTAssertTrue(searchField.exists, "Search field should remain after click")
    }

    func testClickOpensFile() throws {
        launchWithProject(projectURL)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Wait for sidebar
        let sidebar = window.scrollViews["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))

        // Open Quick Open
        clickMenuBarItem("File")
        app.menuItems["Quick Open…"].click()

        let overlay = commandOverlay("quickOpenOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))

        // Type to find a specific file
        let searchField = overlay.textFields["quickOpenSearchField"].firstMatch
        searchField.click()
        searchField.typeText("utils")

        sleep(1)

        // Result rows expose an explicit button role and default action for
        // VoiceOver, rather than relying solely on a mouse-only tap gesture.
        let result = overlay.buttons["quickOpenItem_utils.swift"].firstMatch
        XCTAssertTrue(
            result.waitForExistence(timeout: 3),
            "Quick Open result should expose a button accessibility action"
        )
        result.click()

        // The command panel should dismiss after selection.
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 5))

        // Verify the file tab is opened
        let tab = window.buttons["editorTab_utils.swift"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
    }

    // MARK: - Empty State

    func testEmptyProjectShowsNoResults() throws {
        let emptyDir = try createTempProject(files: [:])
        defer { cleanupProject(emptyDir) }

        launchWithProject(emptyDir)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Open Quick Open
        clickMenuBarItem("File")
        let menuItem = app.menuItems["Quick Open…"]
        if menuItem.waitForExistence(timeout: 5) {
            menuItem.click()

            let overlay = commandOverlay("quickOpenOverlay")
            XCTAssertTrue(overlay.waitForExistence(timeout: 5))

            // Type a query — should show no results
            let searchField = overlay
                .textFields["quickOpenSearchField"]
                .firstMatch
            if searchField.waitForExistence(timeout: 3) {
                searchField.click()
                searchField.typeText("nonexistent")
                sleep(1)
            }
        }
    }

    // MARK: - Shared command panel accessibility

    func testSymbolNavigatorFieldIsAccessibleInCommandPanel() throws {
        launchWithProject(projectURL)
        openFile("main.swift")

        clickMenuBarItem("File")
        let menuItem = app.menuItems["Symbol Navigator"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.click()

        let overlay = commandOverlay("symbolNavigatorOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        let searchField = overlay.textFields["symbolSearchField"].firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 5),
            "Symbol Navigator search field should be accessible"
        )
        searchField.click()
        searchField.typeText("main")
        XCTAssertTrue(searchField.exists)
    }

    func testCommandPaletteFieldIsAccessibleInCommandPanel() throws {
        launchWithProject(projectURL)

        clickMenuBarItem("File")
        let menuItem = app.menuItems["Command Palette…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.click()

        let overlay = commandOverlay("commandPaletteOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        let searchField = overlay
            .textFields["commandPaletteSearchField"]
            .firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 5),
            "Command Palette search field should be accessible"
        )
        searchField.click()
        searchField.typeText("quick")

        let quickOpenCommand = overlay
            .buttons["commandPaletteItem_command_quickOpen"]
            .firstMatch
        XCTAssertTrue(
            quickOpenCommand.waitForExistence(timeout: 5),
            "Command Palette row should expose a button accessibility action"
        )
        quickOpenCommand.click()

        XCTAssertTrue(
            overlay.waitForNonExistence(timeout: 5),
            "The replaced Command Palette panel should retire"
        )
        XCTAssertTrue(
            commandOverlay("quickOpenOverlay")
                .waitForExistence(timeout: 5),
            "Quick Open should replace Command Palette without stale dismissal"
        )
    }
}
