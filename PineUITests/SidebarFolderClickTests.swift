//
//  SidebarFolderClickTests.swift
//  PineUITests
//
//  Tests for #739: clicking a folder row (not just the chevron)
//  toggles expansion in the sidebar file tree.
//

import XCTest

final class SidebarFolderClickTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(
            files: [
                "root-file.swift": "// Root\n",
                "alpha/inside-alpha.swift": "// alpha\n",
                "beta/inside-beta.txt": "beta\n"
            ],
            directories: ["empty-folder"]
        )
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Click on folder row toggles expansion

    func testClickFolderRowExpandsAndCollapses() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let alphaFolder = app.staticTexts["fileNode_alpha"]
        XCTAssertTrue(waitForExistence(alphaFolder, timeout: 5))

        // Child should NOT be visible before expanding.
        let alphaChild = app.staticTexts["fileNode_inside-alpha.swift"]
        XCTAssertFalse(alphaChild.exists, "Folder child should be hidden when collapsed")

        // Click the folder row (not the chevron) — should expand it.
        alphaFolder.click()
        XCTAssertTrue(
            alphaChild.waitForExistence(timeout: 3),
            "Folder child should appear after clicking the folder row"
        )

        // Click again — should collapse.
        alphaFolder.click()
        XCTAssertTrue(
            alphaChild.waitForNonExistence(timeout: 3),
            "Folder child should disappear after clicking the folder row again"
        )
    }

    func testClickEmptyFolderDoesNotCrash() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let emptyFolder = app.staticTexts["fileNode_empty-folder"]
        XCTAssertTrue(waitForExistence(emptyFolder, timeout: 5))

        // Click should not crash; folder is empty so no children appear,
        // but the app must remain responsive.
        emptyFolder.click()
        emptyFolder.click()

        // App still responsive — sidebar still there and we can find the root file.
        XCTAssertTrue(app.staticTexts["fileNode_root-file.swift"].exists)
    }

    // MARK: - Click on file row opens tab (does not toggle anything)

    func testClickFileRowOpensTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let rootFile = app.staticTexts["fileNode_root-file.swift"]
        XCTAssertTrue(waitForExistence(rootFile, timeout: 5))
        rootFile.click()

        let tab = app.buttons["editorTab_root-file.swift"]
        XCTAssertTrue(
            tab.waitForExistence(timeout: 5),
            "Clicking a file row should open it as an editor tab"
        )
    }

    // MARK: - Right-click on folder shows context menu (does not toggle)

    func testRightClickFolderShowsContextMenuWithoutToggling() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let betaFolder = app.staticTexts["fileNode_beta"]
        XCTAssertTrue(waitForExistence(betaFolder, timeout: 5))

        // Folder is collapsed; child should be hidden.
        let betaChild = app.staticTexts["fileNode_inside-beta.txt"]
        XCTAssertFalse(betaChild.exists)

        betaFolder.rightClick()

        // Some context menu item appears (Reveal in Finder is always present).
        let reveal = app.menuItems["Reveal in Finder"]
        XCTAssertTrue(
            reveal.waitForExistence(timeout: 3),
            "Right-click on folder should show context menu"
        )

        // Dismiss menu and verify the folder is still collapsed
        // (right-click must NOT toggle expansion).
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(
            betaChild.exists,
            "Right-click should not expand the folder"
        )
    }
}
