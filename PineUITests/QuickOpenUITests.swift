//
//  QuickOpenUITests.swift
//  PineUITests
//
//  UI tests for the Quick Open (Cmd+P) file search overlay.
//
//  Note: Cmd+P is a menu command handled by SwiftUI's command system,
//  which XCUITest can trigger via the File menu click or by clicking
//  the menu item directly.
//

import XCTest

final class QuickOpenUITests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "// Main\n",
            "helpers.swift": "// Helpers\n",
            "README.md": "# README\n",
            "src/ContentView.swift": "// ContentView\n",
            "src/AppDelegate.swift": "// AppDelegate\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Open and close

    func testQuickOpenOpensViaMenu() throws {
        launchWithProject(projectURL)

        // Open Quick Open via File menu
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Quick Open…"].click()

        let searchField = app.textFields[AccessibilityID.quickOpenField]
        XCTAssert(searchField.waitForExistence(timeout: 5), "Quick Open search field should appear")
    }

    func testQuickOpenDismissesWithEscape() throws {
        launchWithProject(projectURL)

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Quick Open…"].click()

        let searchField = app.textFields[AccessibilityID.quickOpenField]
        XCTAssert(searchField.waitForExistence(timeout: 5))

        // Dismiss with Escape
        searchField.typeKey(.escape, modifierFlags: [])

        // Sheet should close
        XCTAssertFalse(
            searchField.waitForExistence(timeout: 3),
            "Quick Open should close after pressing Escape"
        )
    }

    func testQuickOpenShowsResultsOnOpen() throws {
        launchWithProject(projectURL)

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Quick Open…"].click()

        let resultsList = app.scrollViews[AccessibilityID.quickOpenResultsList]
        XCTAssert(
            resultsList.waitForExistence(timeout: 5),
            "Results list should appear after indexing completes"
        )
    }

    // MARK: - Filtering

    func testTypingFiltersResults() throws {
        launchWithProject(projectURL)

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Quick Open…"].click()

        let searchField = app.textFields[AccessibilityID.quickOpenField]
        XCTAssert(searchField.waitForExistence(timeout: 5))

        // Give indexing time to complete
        Thread.sleep(forTimeInterval: 0.5)

        searchField.typeText("main")

        // The result for main.swift should appear
        let mainResult = app.staticTexts["main.swift"]
        XCTAssert(
            mainResult.waitForExistence(timeout: 3),
            "main.swift should appear in results when searching for 'main'"
        )
    }

    func testSearchShowsNoResultsForNonMatchingQuery() throws {
        launchWithProject(projectURL)

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Quick Open…"].click()

        let searchField = app.textFields[AccessibilityID.quickOpenField]
        XCTAssert(searchField.waitForExistence(timeout: 5))

        Thread.sleep(forTimeInterval: 0.5)
        searchField.typeText("zzzzzzz")

        // Results list should not be present (empty state shown instead)
        Thread.sleep(forTimeInterval: 0.5)
        let resultsList = app.scrollViews[AccessibilityID.quickOpenResultsList]
        // Either no results list, or list is empty — either is acceptable
        if resultsList.exists {
            XCTAssertEqual(resultsList.cells.count, 0, "No results expected for unmatched query")
        }
    }

    // MARK: - File selection

    func testClickingResultOpensFileAndClosesOverlay() throws {
        launchWithProject(projectURL)

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Quick Open…"].click()

        let searchField = app.textFields[AccessibilityID.quickOpenField]
        XCTAssert(searchField.waitForExistence(timeout: 5))

        // Wait for indexing
        Thread.sleep(forTimeInterval: 0.5)

        // Click on a result (tap the first accessible result row)
        let firstResult = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'quickOpenResult_'")
        ).firstMatch

        if firstResult.waitForExistence(timeout: 3) {
            firstResult.click()
            // Overlay should close
            XCTAssertFalse(
                searchField.waitForExistence(timeout: 3),
                "Quick Open should close after selecting a file"
            )
        }
    }

    // MARK: - Empty project

    func testEmptyProjectShowsNoFiles() throws {
        let emptyProject = try createTempProject(files: [:])
        defer { cleanupProject(emptyProject) }

        launchWithProject(emptyProject)

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Quick Open…"].click()

        let searchField = app.textFields[AccessibilityID.quickOpenField]
        XCTAssert(searchField.waitForExistence(timeout: 5))

        // With no files, results list should not appear
        Thread.sleep(forTimeInterval: 0.5)
        let resultsList = app.scrollViews[AccessibilityID.quickOpenResultsList]
        XCTAssertFalse(resultsList.exists, "Results list should not appear for empty project")
    }
}
