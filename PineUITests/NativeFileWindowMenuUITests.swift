//
//  NativeFileWindowMenuUITests.swift
//  PineUITests
//
//  Mouse-driven acceptance coverage for issue #1275.
//

import XCTest

final class NativeFileWindowMenuUITests: PineUITestCase {
    private var projectURL: URL!

    private var canonicalProjectURL: URL {
        projectURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private var recentProjectMenuIdentifier: String {
        "openRecentProjectMenuItem_\(canonicalProjectURL.path)"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(
            files: ["main.swift": "let value = 1\n"],
            projectName: "Native Menu Project"
        )
    }

    override func tearDownWithError() throws {
        if let projectURL {
            cleanupProject(projectURL)
        }
        try super.tearDownWithError()
    }

    func testFileMenuCreatesAndClosesUntitledTabByMouse() throws {
        launchWithProject(projectURL)
        XCTAssertTrue(
            waitForExistence(app.scrollViews["sidebar"], timeout: 10),
            "The project window should be ready before opening File"
        )

        clickMenuBarItem("File")
        let newFile = app.menuItems["New File"].firstMatch
        let openFile = app.menuItems["Open…"].firstMatch
        let openRecent = app.menuItems["Open Recent"].firstMatch
        let closeTabBeforeOpen = app.menuItems["Close Tab"].firstMatch
        XCTAssertTrue(newFile.exists)
        XCTAssertTrue(newFile.isEnabled)
        XCTAssertTrue(openFile.exists)
        XCTAssertTrue(openFile.isEnabled)
        XCTAssertTrue(openRecent.exists)
        XCTAssertTrue(closeTabBeforeOpen.exists)
        XCTAssertFalse(closeTabBeforeOpen.isEnabled)

        newFile.click()
        let untitledTab = editorTab("Untitled")
        XCTAssertTrue(
            waitForExistence(untitledTab, timeout: 5),
            "File > New File should create an untitled editor tab"
        )

        clickMenuBarItem("File")
        let closeTab = app.menuItems["Close Tab"].firstMatch
        XCTAssertTrue(closeTab.exists)
        XCTAssertTrue(closeTab.isEnabled)
        closeTab.click()

        XCTAssertTrue(
            untitledTab.waitForNonExistence(timeout: 5),
            "File > Close Tab should close the active untitled tab"
        )
        XCTAssertTrue(
            app.scrollViews["sidebar"].exists,
            "Close Tab must leave the project window open"
        )

        clickMenuBarItem("File")
        let openFileAfterClose = app.menuItems["Open…"].firstMatch
        XCTAssertTrue(openFileAfterClose.isEnabled)
        openFileAfterClose.click()

        let openPanel = app.sheets.firstMatch
        XCTAssertTrue(
            openPanel.waitForExistence(timeout: 5),
            "File > Open… should present a project-window-owned sheet"
        )
        let mainFile = openPanel.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "label == %@ OR identifier == %@ OR value == %@",
                "main.swift",
                "main.swift",
                "main.swift"
            )
        ).firstMatch
        XCTAssertTrue(
            mainFile.waitForExistence(timeout: 5),
            "The project-root file should be selectable in Open…"
        )
        mainFile.click()
        let openButton = openPanel.buttons["Open"].firstMatch
        XCTAssertTrue(openButton.exists)
        XCTAssertTrue(openButton.isEnabled)
        openButton.click()
        XCTAssertTrue(
            waitForExistence(editorTab("main.swift"), timeout: 5),
            "Open… should open the selected file in an editor tab"
        )
    }

    func testWindowCloseAndOpenRecentRouteByMouse() throws {
        launchWithProject(projectURL)
        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 10),
            "The project window should be ready before opening Window"
        )

        clickMenuBarItem("Window")
        let closeWindow = app.menuItems["Close Window"].firstMatch
        XCTAssertTrue(closeWindow.exists)
        XCTAssertTrue(closeWindow.isEnabled)
        closeWindow.click()

        XCTAssertTrue(
            sidebar.waitForNonExistence(timeout: 5),
            "Window > Close Window should close the entire project window"
        )
        XCTAssertTrue(
            waitForExistence(app.windows["welcome"], timeout: 10),
            "Closing the last project window should reveal Welcome"
        )

        clickMenuBarItem("File")
        let openRecent = app.menuItems["Open Recent"].firstMatch
        XCTAssertTrue(openRecent.exists)
        XCTAssertTrue(openRecent.isEnabled)
        openRecent.click()

        let recentProject =
            app.menuItems[recentProjectMenuIdentifier].firstMatch
        XCTAssertTrue(
            recentProject.waitForExistence(timeout: 5),
            "Open Recent should expose the retained project"
        )
        recentProject.click()
        XCTAssertTrue(
            waitForExistence(app.scrollViews["sidebar"], timeout: 10),
            "Open Recent should restore the project window"
        )
    }

    func testOpenRecentClearMenuByMouse() throws {
        launchWithProject(projectURL)
        XCTAssertTrue(
            waitForExistence(app.scrollViews["sidebar"], timeout: 10)
        )

        clickMenuBarItem("File")
        let openRecent = app.menuItems["Open Recent"].firstMatch
        XCTAssertTrue(openRecent.exists)
        XCTAssertTrue(openRecent.isEnabled)
        openRecent.click()

        let clearMenu =
            app.menuItems["clearRecentProjectsMenuItem"].firstMatch
        XCTAssertTrue(
            clearMenu.waitForExistence(timeout: 5),
            "Open Recent should expose Clear Menu"
        )
        XCTAssertTrue(clearMenu.isEnabled)
        clearMenu.click()
        XCTAssertTrue(clearMenu.waitForNonExistence(timeout: 5))

        clickMenuBarItem("File")
        let clearedOpenRecent = app.menuItems["Open Recent"].firstMatch
        XCTAssertTrue(clearedOpenRecent.exists)
        XCTAssertFalse(
            clearedOpenRecent.isEnabled,
            "Clear Menu should disable an empty Open Recent submenu"
        )
    }
}
