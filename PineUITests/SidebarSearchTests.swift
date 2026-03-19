//
//  SidebarSearchTests.swift
//  PineUITests
//
//  UI tests for sidebar search (.searchable integration).
//

import XCTest

final class SidebarSearchTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "import Foundation\nlet greeting = \"Hello\"\n",
            "utils.swift": "func helper() {}\nfunc greeting() {}\n",
            "notes.txt": "just a text file\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    /// Waits for search field to be ready and types a query, then waits for debounce + search.
    private func typeSearchQuery(_ query: String) {
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(waitForExistence(searchField, timeout: 10),
                       "Search field should exist")
        searchField.click()
        sleep(1) // Wait for focus
        searchField.typeText(query)
        sleep(2) // Wait for debounce (300ms) + async search
    }

    // MARK: - Search field exists

    func testSearchFieldVisibleInSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            waitForExistence(searchField, timeout: 10),
            "Search field should be visible"
        )
    }

    // MARK: - Typing in search shows results

    func testSearchShowsResults() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        typeSearchQuery("greeting")

        let resultsList = app.scrollViews["projectSearchResultsList"].firstMatch
        XCTAssertTrue(
            waitForExistence(resultsList, timeout: 10),
            "Search results should appear when typing a query"
        )
    }

    // MARK: - Clearing search returns to file tree

    func testClearSearchReturnsToFileTree() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        typeSearchQuery("greeting")

        let resultsList = app.scrollViews["projectSearchResultsList"].firstMatch
        XCTAssertTrue(waitForExistence(resultsList, timeout: 10))

        // Clear the search field — select all and delete
        let searchField = app.searchFields.firstMatch
        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(.delete, modifierFlags: [])
        searchField.typeKey(.escape, modifierFlags: [])
        sleep(2)

        // File tree should be visible again
        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 10),
            "Sidebar should return after clearing search"
        )
    }

    // MARK: - No results message for unmatched query

    func testNoResultsMessageForUnmatchedQuery() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        typeSearchQuery("zzz_nonexistent_zzz")

        // "No results" / "No Results" / "Нет результатов"
        let noResults = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'no results' OR label CONTAINS[c] 'Нет результатов'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(noResults, timeout: 10),
            "No results message should appear for unmatched query"
        )
    }

    // MARK: - Magnifying glass toolbar button exists

    func testMagnifyingGlassButtonExists() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let toolbarButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'search' OR label CONTAINS[c] 'поиск'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(toolbarButton, timeout: 10),
            "Magnifying glass button should exist in toolbar"
        )
    }

    // MARK: - Cmd+Shift+F opens search

    func testCmdShiftFOpensSearch() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Find in Project is in the Edit menu
        app.menuBars.menuBarItems["Edit"].click()
        let findInProject = app.menuItems["Find in Project…"]
        if waitForExistence(findInProject, timeout: 3) {
            findInProject.click()
        } else {
            // Menu item may have different name — try keyboard shortcut
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey("f", modifierFlags: [.command, .shift])
        }

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            waitForExistence(searchField, timeout: 10),
            "Search field should be available after Find in Project"
        )
    }

    // MARK: - Clicking search result opens file

    func testClickingSearchResultOpensFile() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        typeSearchQuery("helper")

        let resultsList = app.scrollViews["projectSearchResultsList"].firstMatch
        XCTAssertTrue(waitForExistence(resultsList, timeout: 10))

        let firstResult = resultsList.buttons.firstMatch
        XCTAssertTrue(waitForExistence(firstResult, timeout: 5))
        firstResult.click()

        let tab = app.buttons["editorTab_utils.swift"].firstMatch
        XCTAssertTrue(
            waitForExistence(tab, timeout: 10),
            "Clicking a search result should open the file in an editor tab"
        )
    }
}
