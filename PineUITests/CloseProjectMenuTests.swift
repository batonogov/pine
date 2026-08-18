//
//  CloseProjectMenuTests.swift
//  PineUITests
//
//  UI coverage for the Close Project command surfaces.
//

import XCTest

final class CloseProjectMenuTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let greeting = \"Hello\"\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    /// Pine's own File menu, not the one AppKit contributes.
    private func pineFileMenu() -> XCUIElement {
        let items = app.menuBars.menuBarItems.matching(identifier: "File")
        return items.element(boundBy: items.count - 1)
    }

    func testFileMenuOffersCloseProject() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 10),
            "Sidebar should appear"
        )

        app.activate()
        sleep(1)
        pineFileMenu().click()

        let closeProject = app.menuItems["Close Project"]
        XCTAssertTrue(
            waitForExistence(closeProject, timeout: 3),
            "File menu should offer Close Project"
        )
        // Enabled with a single project too: closing the last one is a window
        // close, which the command performs rather than refuses.
        XCTAssertTrue(
            closeProject.isEnabled,
            "Close Project should be available while a project is open"
        )
        // Distinct from Close Window, which lives beside it.
        XCTAssertTrue(
            app.menuItems["Close Window"].exists,
            "Close Window should remain its own item"
        )
    }

    func testProjectSwitcherOffersCloseForTheOpenProject() throws {
        launchWithProject(projectURL)

        // The switcher is a SwiftUI Menu, which XCUITest does not surface as a
        // plain button — matching any descendant by identifier is how the
        // other switcher tests reach it.
        let switcher = app.descendants(matching: .any)["projectSwitcher"]
            .firstMatch
        XCTAssertTrue(
            waitForExistence(switcher, timeout: 10),
            "Project switcher should appear in the toolbar"
        )
        switcher.click()

        let closeItem = app.descendants(matching: .any)[
            "projectSwitcherCloseProject"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(closeItem, timeout: 5),
            "Switcher menu should offer to close the active project"
        )
    }
}
