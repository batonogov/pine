//
//  NativeFileWindowMenuUITests.swift
//  PineUITests
//
//  Mouse-driven acceptance coverage for issue #1275.
//

import XCTest

final class NativeFileWindowMenuUITests: PineUITestCase {
    private var projectURL: URL!

    private func visibleMenuItem(
        matching predicate: NSPredicate
    ) -> XCUIElement? {
        app.menuItems
            .matching(predicate)
            .allElementsBoundByIndex
            .first(
                where: {
                    $0.frame.width > 0 && $0.frame.height > 0
                }
            )
    }

    private func waitForEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func waitForDisabled(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
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
        let viewOptions = openPanel.menuButtons["View Options"].firstMatch
        XCTAssertTrue(viewOptions.exists)
        viewOptions.click()
        let listView = app.menuItems["List"].firstMatch
        XCTAssertTrue(listView.exists)
        listView.click()

        let mainFilePredicate = NSPredicate(
            format: "value == %@",
            "main.swift"
        )
        let mainFile = openPanel.textFields
            .matching(mainFilePredicate)
            .firstMatch
        XCTAssertTrue(
            mainFile.waitForExistence(timeout: 5),
            "The project-root file should be selectable in Open…"
        )
        mainFile.coordinate(
            withNormalizedOffset: CGVector(dx: -0.2, dy: 0.5)
        ).click()
        let openButton = openPanel.buttons["Open"].firstMatch
        XCTAssertTrue(
            waitForEnabled(openButton, timeout: 5),
            "Selecting the file should enable Open"
        )
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

        let recentPrefix = "\(projectURL.lastPathComponent) — "
        let recentProject = try XCTUnwrap(
            visibleMenuItem(
                matching: NSPredicate(
                    format: "title BEGINSWITH %@",
                    recentPrefix
                )
            ),
            "Open Recent should expose the retained project"
        )
        recentProject.click()
        XCTAssertTrue(
            waitForExistence(app.scrollViews["sidebar"], timeout: 10),
            "Open Recent should restore the project window"
        )
    }

    func testOpenFolderFromProjectMenuPresentsReusableOwnedPanel() throws {
        launchWithProject(projectURL)
        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 10),
            "The project window should be ready before opening File"
        )

        for attempt in 1...2 {
            clickMenuBarItem("File")
            let openFolder = app.menuItems["Open Folder…"].firstMatch
            XCTAssertTrue(
                openFolder.waitForExistence(timeout: 5),
                "File should expose Open Folder…"
            )
            XCTAssertTrue(openFolder.isEnabled)
            openFolder.click()

            let openPanel = app.sheets.firstMatch
            XCTAssertTrue(
                openPanel.waitForExistence(timeout: 5),
                "File > Open Folder… should present a project-window-owned sheet on attempt \(attempt)"
            )
            XCTAssertTrue(
                openPanel.buttons["Open"].firstMatch.exists,
                "The owned folder picker should expose its Open action"
            )

            app.typeKey(".", modifierFlags: .command)
            XCTAssertTrue(
                openPanel.waitForNonExistence(timeout: 5),
                "Cancelling the folder picker should dismiss the owned sheet"
            )
            XCTAssertTrue(
                sidebar.exists,
                "Cancelling Open Folder must leave the current project open"
            )
        }
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

        let clearMenu = try XCTUnwrap(
            visibleMenuItem(
                matching: NSPredicate(
                    format: "title == %@",
                    "Clear Menu"
                )
            ),
            "Open Recent should expose Clear Menu"
        )
        XCTAssertTrue(clearMenu.isEnabled)
        clearMenu.click()

        clickMenuBarItem("File")
        let clearedOpenRecent = app.menuItems["Open Recent"].firstMatch
        XCTAssertTrue(clearedOpenRecent.exists)
        XCTAssertTrue(
            waitForDisabled(clearedOpenRecent, timeout: 5),
            "Clear Menu should disable an empty Open Recent submenu"
        )
    }
}
