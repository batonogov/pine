//
//  MultiWindowTests.swift
//  PineUITests
//
//  P2: Multi-window scenarios.
//

import XCTest

final class MultiWindowTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: ["a.swift": "// A\n"])
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - P2: Single project opens in its own window

    func testOpenProjectShowsEditorWindow() throws {
        launchWithProject(projectURL)

        let projectWindow = app.windows.firstMatch
        XCTAssertTrue(
            waitForExistence(projectWindow, timeout: 10),
            "Project window should appear"
        )

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 5), "Sidebar should be present")
    }

    // MARK: - P2: Sidebar shows project files

    func testSidebarShowsProjectFiles() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileNode = app.staticTexts["fileNode_a.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5), "a.swift should appear in sidebar")
    }
}
