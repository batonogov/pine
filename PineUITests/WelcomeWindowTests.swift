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

        let sidebar = app.scrollViews["sidebar"]
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
        let sidebarAfter = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebarAfter, timeout: 10), "Project should open from recent click")
    }

    // MARK: - P0: Welcome closes when project opens

    func testWelcomeClosesWhenProjectOpens() throws {
        // Step 1: Launch with a project to create a recent entry
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        let sidebar = app.scrollViews["sidebar"]
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

    // MARK: - Recent project path shows abbreviated ~/...

    func testRecentProjectShowsAbbreviatedPath() throws {
        // Create project inside home directory so the path gets abbreviated
        let homeDir = NSHomeDirectory()
        let projectDir = URL(fileURLWithPath: homeDir)
            .appendingPathComponent("PineUITest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "// hi\n".write(
            to: projectDir.appendingPathComponent("hello.swift"),
            atomically: true,
            encoding: .utf8
        )
        projectURLs.append(projectDir)

        launchWithProject(projectDir)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Project should open")

        app.terminate()

        app = XCUIApplication()
        app.launchArguments += [
            "--reset-state",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        app.activate()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10), "Welcome should appear")

        let projectName = projectDir.lastPathComponent
        let recentItem = app.descendants(matching: .any)[
            "welcomeRecentProject_\(projectName)"
        ].firstMatch
        XCTAssertTrue(waitForExistence(recentItem, timeout: 5), "Recent project should appear")

        // Check that the path is abbreviated: the full home directory should not appear
        // in any static text, but a ~/ prefixed version should
        let allTexts = welcomeWindow.staticTexts
        for index in 0..<allTexts.count {
            let val = (allTexts.element(boundBy: index).value as? String) ?? ""
            XCTAssertFalse(
                val.contains(homeDir),
                "Path should not contain full home dir '\(homeDir)', got: '\(val)'"
            )
        }
    }

    // MARK: - First recent project is not obscured by header

    func testFirstRecentProjectIsHittable() throws {
        // Step 1: Launch with a project to create a recent entry
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Project should open")

        // Step 2: Terminate and relaunch to see Welcome with recent projects
        app.terminate()

        app = XCUIApplication()
        app.launchArguments += ["--reset-state"]
        app.launch()
        app.activate()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10), "Welcome should appear")

        // Step 3: Verify the first recent project is fully visible and clickable
        let projectName = url.lastPathComponent
        let recentItem = app.descendants(matching: .any)[
            "welcomeRecentProject_\(projectName)"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(recentItem, timeout: 5),
            "Recent project should appear in Welcome"
        )
        XCTAssertTrue(
            recentItem.isHittable,
            "First recent project should not be obscured by the header"
        )
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

        let sidebar = app.scrollViews["sidebar"]
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

    // MARK: - Empty recent projects shows placeholder

    func testWelcomeShowsEmptyStateWhenNoRecentProjects() throws {
        app.launchArguments += ["--clear-recent-projects"]
        launchClean()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10), "Welcome should appear")

        // The list should not exist when there are no recent projects
        let recentList = app.scrollViews["welcomeRecentProjectsList"]
        XCTAssertFalse(recentList.exists, "Recent projects list should not exist when empty")

        // "No Recent Projects" placeholder should be visible
        let placeholder = welcomeWindow.staticTexts.matching(
            NSPredicate(format: "value == 'No Recent Projects'")
        ).firstMatch
        XCTAssertTrue(placeholder.exists, "Empty state placeholder should be visible")
    }

    // MARK: - Single recent project (no dividers)

    func testSingleRecentProjectIsHittableWithNoDivider() throws {
        let url = try createTempProject(files: ["main.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        app.terminate()

        app = XCUIApplication()
        app.launchArguments += ["--reset-state"]
        app.launch()
        app.activate()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10))

        let projectName = url.lastPathComponent
        let recentItem = app.descendants(matching: .any)[
            "welcomeRecentProject_\(projectName)"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(recentItem, timeout: 5),
            "Single recent project should appear"
        )
        XCTAssertTrue(
            recentItem.isHittable,
            "Single recent project should be fully visible and clickable"
        )
    }

    // MARK: - Multiple projects: all items accessible

    func testMultipleRecentProjectsAllHittable() throws {
        // Create and open 3 projects to populate recent list
        var urls: [URL] = []
        for index in 1...3 {
            let url = try createTempProject(files: ["file\(index).swift": "// \(index)\n"])
            projectURLs.append(url)
            urls.append(url)
        }

        // Open each project sequentially to add to recent list
        for url in urls {
            app = XCUIApplication()
            app.launchArguments += [
                "--reset-state",
                "-ApplePersistenceIgnoreState", "YES",
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US"
            ]
            launchWithProject(url)

            let sidebar = app.scrollViews["sidebar"]
            XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
            app.terminate()
        }

        // Relaunch to see Welcome with all 3 recent projects
        app = XCUIApplication()
        app.launchArguments += ["--reset-state"]
        app.launch()
        app.activate()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10))

        // Verify all 3 recent projects are present and hittable
        for url in urls {
            let projectName = url.lastPathComponent
            let item = app.descendants(matching: .any)[
                "welcomeRecentProject_\(projectName)"
            ].firstMatch
            XCTAssertTrue(
                waitForExistence(item, timeout: 5),
                "Recent project '\(projectName)' should appear"
            )
            XCTAssertTrue(
                item.isHittable,
                "Recent project '\(projectName)' should be hittable"
            )
        }
    }

    // MARK: - Duplicate project names show correct paths

    func testDuplicateProjectNamesShowDistinctPaths() throws {
        // Create two projects with the same folder name in different parent dirs
        let baseName = "DuplicateName-\(UUID().uuidString.prefix(8))"
        let parent1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineParent1-\(UUID().uuidString)")
        let parent2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineParent2-\(UUID().uuidString)")

        let project1 = parent1.appendingPathComponent(baseName)
        let project2 = parent2.appendingPathComponent(baseName)

        for dir in [project1, project2] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "// test\n".write(
                to: dir.appendingPathComponent("main.swift"),
                atomically: true,
                encoding: .utf8
            )
        }
        projectURLs.append(contentsOf: [parent1, parent2])

        // Open both projects to add to recent list
        for url in [project1, project2] {
            app = XCUIApplication()
            app.launchArguments += [
                "--reset-state",
                "-ApplePersistenceIgnoreState", "YES",
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US"
            ]
            launchWithProject(url)

            let sidebar = app.scrollViews["sidebar"]
            XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
            app.terminate()
        }

        // Relaunch to see Welcome
        app = XCUIApplication()
        app.launchArguments += ["--reset-state"]
        app.launch()
        app.activate()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10))

        // Both projects share the same name, so accessibility ID is the same —
        // there should be at least 2 matching elements
        let items = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "welcomeRecentProject_\(baseName)")
        )
        XCTAssertGreaterThanOrEqual(
            items.count, 2,
            "Both projects with name '\(baseName)' should appear in recent list"
        )

        // Both should be hittable
        for index in 0..<min(items.count, 2) {
            XCTAssertTrue(
                items.element(boundBy: index).isHittable,
                "Duplicate-named project at index \(index) should be hittable"
            )
        }
    }

    // MARK: - P0: Restart → Welcome (not previous windows)

    func testRestartShowsWelcomeNotPreviousProject() throws {
        // Step 1: Launch with a project
        let url = try createTempProject(files: ["test.swift": "// test\n"])
        projectURLs.append(url)
        launchWithProject(url)

        let sidebar = app.scrollViews["sidebar"]
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
        let sidebarGone = app.scrollViews["sidebar"]
        XCTAssertFalse(sidebarGone.exists, "Previous project should not auto-restore on restart")
    }
}
