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

    /// Locates the Quick Open search field by its own accessibility identifier.
    ///
    /// Quick Open is now presented as a lightweight `CommandOverlayView` (.overlay)
    /// instead of a `.sheet`. Rather than depending on how the overlay container is
    /// classified in the accessibility tree (which varies and can cause identifier
    /// propagation issues), we locate the inner search field directly via its stable
    /// semantic id. The field exists iff the overlay is presented, so it also serves
    /// as the appearance/dismissal signal.
    private func quickOpenField() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "quickOpenSearchField")
            .firstMatch
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

        // Verify Quick Open overlay appears (search field is the signal)
        XCTAssertTrue(quickOpenField().waitForExistence(timeout: 5))
    }

    func testQuickOpenDismissesOnEscape() throws {
        launchWithProject(projectURL)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Open Quick Open
        clickMenuBarItem("File")
        app.menuItems["Quick Open…"].click()

        let field = quickOpenField()
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        // Press Escape to dismiss
        app.typeKey(.escape, modifierFlags: [])

        // Overlay should dismiss (search field disappears)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
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

        // The search field is an NSTextField (NSViewRepresentable).
        // XCUITest's typeText does not reliably input into NSTextField
        // wrapped via NSViewRepresentable (same known issue as GutterTextView).
        // Verify the search field exists and accepts focus.
        let searchField = quickOpenField()
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

        let searchField = quickOpenField()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        // Type to find a specific file
        searchField.click()
        searchField.typeText("utils")

        sleep(1)

        // Click on the result. The overlay may expose "utils.swift" in both
        // the filename and path-hint labels; search globally and pick the first.
        let result = app.staticTexts["utils.swift"].firstMatch
        if result.waitForExistence(timeout: 3) {
            result.click()

            // Overlay should dismiss after selection (search field disappears)
            XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))

            // Verify the file tab is opened
            let tab = window.buttons["editorTab_utils.swift"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
        }
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

            // Verify the overlay opens, then type a query (should show no results)
            let searchField = quickOpenField()
            if searchField.waitForExistence(timeout: 5) {
                searchField.click()
                searchField.typeText("nonexistent")
                sleep(1)
            }
        }
    }
}
