//
//  WelcomeWindowTests.swift
//  PineUITests
//
//  P0: Welcome window appearance and basic interactions.
//

import XCTest

final class WelcomeWindowTests: PineUITestCase {

    private var projectURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in projectURLs { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - P0: Launch → Welcome window visible

    func testLaunchShowsWelcomeWindow() throws {
        launchClean()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow), "Welcome window should appear on clean launch")
    }

    func testWelcomeWindowShowsOpenFolderButton() throws {
        launchClean()

        let openFolderButton = app.buttons["welcomeOpenFolderButton"]
        XCTAssertTrue(waitForExistence(openFolderButton), "Open Folder button should be visible")
    }

    func testWelcomeWindowShowsPineTitle() throws {
        launchClean()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow))

        let pineTitle = welcomeWindow.staticTexts.matching(
            NSPredicate(format: "value == 'Pine'")
        ).firstMatch
        XCTAssertTrue(pineTitle.exists, "Pine title should be visible in Welcome window")
    }

    // MARK: - P0: Open Folder → NSOpenPanel appears

    func testOpenFolderButtonShowsOpenPanel() throws {
        launchClean()

        let openFolderButton = app.buttons["welcomeOpenFolderButton"]
        XCTAssertTrue(waitForExistence(openFolderButton))
        openFolderButton.click()

        // NSOpenPanel shows as a sheet or separate window with an "Open" button
        let openPanel = app.sheets.firstMatch
        let openPanelWindow = app.dialogs.firstMatch
        let panelAppeared = openPanel.waitForExistence(timeout: 5)
            || openPanelWindow.waitForExistence(timeout: 2)
        XCTAssertTrue(panelAppeared, "NSOpenPanel should appear after clicking Open Folder")

        // Dismiss the panel by pressing Escape
        app.typeKey(.escape, modifierFlags: [])

        // Welcome window should still be visible after cancelling
        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(welcomeWindow.exists, "Welcome should remain after cancelling Open Folder")
    }

    // MARK: - P0: Recent project click → project opens

    func testClickRecentProjectOpensProject() throws {
        // Step 1: Launch with a project to create a recent entry
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Project should open")

        // Step 2: Terminate and relaunch with --reset-state (clears sessions, preserves recent projects)
        app.terminate()

        app = XCUIApplication()
        app.launchArguments += ["--reset-state"]
        app.launch()
        app.activate()

        // Step 3: Welcome should show with recent projects
        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10), "Welcome should appear on relaunch")

        let projectName = url.lastPathComponent
        let recentItem = app.descendants(matching: .any)[
            "welcomeRecentProject_\(projectName)"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(recentItem, timeout: 5),
            "Recent project '\(projectName)' should appear in Welcome"
        )

        // Step 4: Click the recent project
        recentItem.click()

        // Project window should open with sidebar
        let sidebarAfter = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebarAfter, timeout: 10), "Project should open from recent click")
    }

    // MARK: - P0: Welcome closes when project opens

    func testWelcomeClosesWhenProjectOpens() throws {
        // Step 1: Launch with a project to create a recent entry
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Project should open")

        // Step 2: Terminate and relaunch clean
        app.terminate()

        app = XCUIApplication()
        app.launchArguments += ["--reset-state"]
        app.launch()
        app.activate()

        // Step 3: Welcome should appear
        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10), "Welcome should appear on relaunch")

        // Step 4: Click recent project
        let projectName = url.lastPathComponent
        let recentItem = app.descendants(matching: .any)[
            "welcomeRecentProject_\(projectName)"
        ].firstMatch
        XCTAssertTrue(waitForExistence(recentItem, timeout: 5))
        recentItem.click()

        // Step 5: Welcome window should disappear
        let welcomeGone = welcomeWindow.waitForNonExistence(timeout: 10)
        XCTAssertTrue(welcomeGone, "Welcome window should close after opening a project")
    }

    // MARK: - P0: Close project → Welcome reappears

    func testWelcomeReappearsAfterClosingProjectWindow() throws {
        // Realistic workflow: open project, work with files, close, reopen from Welcome, close again.
        // The bug manifests on the second cycle when openWindow stops working after dismissWindow.
        let url = try createTempProject(files: [
            "main.swift": "let x = 1\n",
            "utils.swift": "func helper() {}\n"
        ])
        projectURLs.append(url)

        // --- Cycle 1: open project via env var, open files, close ---
        launchWithProject(url)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Project should open")

        let mainFile = app.staticTexts["fileNode_main.swift"]
        if waitForExistence(mainFile, timeout: 5) { mainFile.click() }
        let utilsFile = app.staticTexts["fileNode_utils.swift"]
        if waitForExistence(utilsFile, timeout: 5) { utilsFile.click() }

        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome should reappear after closing project (cycle 1)"
        )

        // --- Cycle 2: reopen same project from recent list, open files, close ---
        let projectName = url.lastPathComponent
        let recentItem = app.descendants(matching: .any)[
            "welcomeRecentProject_\(projectName)"
        ].firstMatch
        XCTAssertTrue(waitForExistence(recentItem, timeout: 5), "Project should be in recent list")
        recentItem.click()

        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 10),
            "Project should reopen from Welcome"
        )

        let mainFile2 = app.staticTexts["fileNode_main.swift"]
        if waitForExistence(mainFile2, timeout: 5) { mainFile2.click() }
        let utilsFile2 = app.staticTexts["fileNode_utils.swift"]
        if waitForExistence(utilsFile2, timeout: 5) { utilsFile2.click() }

        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()

        // This is where the bug manifests — Welcome doesn't appear on second cycle
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome should reappear after closing project (cycle 2)"
        )
    }

    // MARK: - P0: Restart → Welcome (not previous windows)

    func testRestartShowsWelcomeNotPreviousProject() throws {
        // Step 1: Launch with a project
        let url = try createTempProject(files: ["test.swift": "// test\n"])
        projectURLs.append(url)
        launchWithProject(url)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Project should open")

        // Step 2: Terminate the app
        app.terminate()

        // Step 3: Relaunch with --reset-state (simulates clean restart)
        app = XCUIApplication()
        app.launchArguments += ["--reset-state"]
        app.launch()
        app.activate()

        // Welcome should appear, not the previous project
        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome window should appear on restart, not previous project"
        )

        // Sidebar should NOT be present (no project window)
        let sidebarGone = app.outlines["sidebar"]
        XCTAssertFalse(sidebarGone.exists, "Previous project should not auto-restore on restart")
    }
}
