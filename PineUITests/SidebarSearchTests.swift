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

    // MARK: - Search field exists in sidebar

    func testSearchFieldVisibleInSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // .searchable creates a native NSSearchField in the sidebar
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            waitForExistence(searchField, timeout: 5),
            "Search field should be visible in the sidebar"
        )
    }

    // MARK: - Typing in search shows results

    func testSearchShowsResults() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(waitForExistence(searchField, timeout: 5))

        // Type a query that matches content in test files
        searchField.click()
        searchField.typeText("greeting")

        // Search results list should appear
        let resultsList = app.scrollViews["projectSearchResultsList"].firstMatch
        XCTAssertTrue(
            waitForExistence(resultsList, timeout: 5),
            "Search results should appear when typing a query"
        )
    }

    // MARK: - Clearing search returns to file tree

    func testClearSearchReturnsToFileTree() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(waitForExistence(searchField, timeout: 5))

        // Type a query
        searchField.click()
        searchField.typeText("greeting")

        // Wait for results to appear
        let resultsList = app.scrollViews["projectSearchResultsList"].firstMatch
        XCTAssertTrue(waitForExistence(resultsList, timeout: 5))

        // Clear the search field — press Escape to dismiss search
        searchField.typeKey(.escape, modifierFlags: [])
        sleep(1)

        // File tree should be visible again
        let fileNode = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(
            waitForExistence(fileNode, timeout: 5),
            "File tree should return after clearing search"
        )
    }

    // MARK: - No results message for unmatched query

    func testNoResultsMessageForUnmatchedQuery() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(waitForExistence(searchField, timeout: 5))

        searchField.click()
        searchField.typeText("zzz_nonexistent_zzz")
        sleep(1)

        // "No results" text should appear
        let noResults = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'no results' OR label CONTAINS[c] 'Ничего не найдено'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(noResults, timeout: 5),
            "No results message should appear for unmatched query"
        )
    }

    // MARK: - Magnifying glass toolbar button exists

    func testMagnifyingGlassButtonExists() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // The toolbar should contain a magnifying glass button
        let toolbarButton = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'search' OR label CONTAINS[c] 'поиск'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(toolbarButton, timeout: 5),
            "Magnifying glass button should exist in toolbar"
        )
    }

    // MARK: - Cmd+Shift+F reveals sidebar

    func testCmdShiftFRevealsSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Use Find > Find in Project menu item (Cmd+Shift+F)
        app.menuBars.menuBarItems["Find"].click()
        let findInProject = app.menuItems["Find in Project…"]
        XCTAssertTrue(
            waitForExistence(findInProject, timeout: 3),
            "Find in Project menu item should exist"
        )
        findInProject.click()

        // Sidebar should be visible
        XCTAssertTrue(sidebar.exists, "Sidebar should remain visible after Find in Project")

        // Search field should exist
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            waitForExistence(searchField, timeout: 5),
            "Search field should be available after Find in Project"
        )
    }

    // MARK: - Clicking search result opens file

    func testClickingSearchResultOpensFile() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(waitForExistence(searchField, timeout: 5))

        // Search for content that exists in utils.swift
        searchField.click()
        searchField.typeText("helper")

        // Wait for results
        let resultsList = app.scrollViews["projectSearchResultsList"].firstMatch
        XCTAssertTrue(waitForExistence(resultsList, timeout: 5))

        // Click on first result
        let firstResult = resultsList.buttons.firstMatch
        XCTAssertTrue(waitForExistence(firstResult, timeout: 3))
        firstResult.click()

        // An editor tab should open for utils.swift
        let tab = app.buttons["editorTab_utils.swift"].firstMatch
        XCTAssertTrue(
            waitForExistence(tab, timeout: 5),
            "Clicking a search result should open the file in an editor tab"
        )
    }
}
