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

    // MARK: - Search shows results (via env var)

    func testSearchShowsResults() throws {
        launchWithProjectAndSearch(projectURL, query: "greeting")

        // Search results appear inside the sidebar ScrollView as Buttons.
        // The inner "projectSearchResultsList" ScrollView is merged into
        // the NavigationSplitView sidebar in the accessibility tree.
        let sidebar = app.scrollViews["sidebar"].firstMatch
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let resultButton = sidebar.buttons.firstMatch
        XCTAssertTrue(
            waitForExistence(resultButton, timeout: 10),
            "Search results should appear when typing a query"
        )
    }

    // MARK: - No results message for unmatched query

    func testNoResultsMessageForUnmatchedQuery() throws {
        launchWithProjectAndSearch(projectURL, query: "zzz_nonexistent_zzz")

        // The "No Results" text gets identifier "sidebar" from the parent
        // SidebarSearchableContent wrapper, so match by value instead.
        let noResults = app.staticTexts["sidebar"].firstMatch
        XCTAssertTrue(
            waitForExistence(noResults, timeout: 10),
            "No results message should appear for unmatched query"
        )
        XCTAssertEqual(noResults.value as? String, "No Results")
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
        launchWithProjectAndSearch(projectURL, query: "helper")

        let sidebar = app.scrollViews["sidebar"].firstMatch
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let firstResult = sidebar.buttons.firstMatch
        XCTAssertTrue(waitForExistence(firstResult, timeout: 5))
        firstResult.click()

        let tab = app.buttons["editorTab_utils.swift"].firstMatch
        XCTAssertTrue(
            waitForExistence(tab, timeout: 10),
            "Clicking a search result should open the file in an editor tab"
        )
    }

    // MARK: - Clearing search returns to file tree

    func testClearSearchReturnsToFileTree() throws {
        launchWithProjectAndSearch(projectURL, query: "greeting")

        let sidebar = app.scrollViews["sidebar"].firstMatch
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Verify results are showing
        let resultButton = sidebar.buttons.firstMatch
        XCTAssertTrue(waitForExistence(resultButton, timeout: 5))

        // Clear the search field — select all and delete
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(waitForExistence(searchField, timeout: 5))
        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(.delete, modifierFlags: [])
        searchField.typeKey(.escape, modifierFlags: [])
        sleep(2)

        // File tree (Outline) should be visible again
        let fileTree = app.outlines["sidebar"]
        XCTAssertTrue(
            waitForExistence(fileTree, timeout: 10),
            "Sidebar should return to file tree after clearing search"
        )
    }
}
