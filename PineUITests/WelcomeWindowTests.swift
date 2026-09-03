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

    func testAgentInboxOpensFromWelcomeWithoutClosingWelcome() throws {
        launchClean()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow))
        let inboxButton = app.buttons["welcomeAgentInboxButton"]
        XCTAssertTrue(
            waitForExistence(inboxButton),
            "Agent Inbox should be available before a project is open"
        )

        inboxButton.click()

        let inbox = app.descendants(matching: .any)["agentInbox"]
            .firstMatch
        XCTAssertTrue(waitForExistence(inbox), "Agent Inbox should open")
        // ContentUnavailableView doesn't reliably expose a modifier-applied
        // accessibilityIdentifier on macOS. The test locale is forced to English,
        // so assert the rendered empty-state text within the popover instead.
        XCTAssertTrue(
            waitForExistence(
                inbox.staticTexts["No agent tasks"].firstMatch
            ),
            "A fresh Inbox should show its empty state"
        )
        XCTAssertFalse(
            app.windows["Agent Inbox"].exists,
            "Agent Inbox should not create a separate window"
        )
        XCTAssertTrue(
            welcomeWindow.exists,
            "Opening Agent Inbox must not switch or close projects implicitly"
        )
    }

    func testAgentInboxOpensFromWindowMenuInProject() throws {
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        // Auxiliary panels conventionally live in the Window menu (#1564).
        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(waitForExistence(windowMenu))
        windowMenu.click()
        let inboxItem = windowMenu.menus.menuItems["Agent Inbox"].firstMatch
        XCTAssertTrue(waitForExistence(inboxItem))
        inboxItem.click()

        let inbox = app.descendants(matching: .any)["agentInbox"]
            .firstMatch
        XCTAssertTrue(
            waitForExistence(inbox),
            "Agent Inbox should be available from every project window"
        )
        XCTAssertTrue(app.scrollViews["sidebar"].exists)
    }

    func testRecoveredTaskRequiresExplicitChoiceAndRoutesNewSession() throws {
        let url = try createTempProject(
            files: ["release.md": "# Pine 2.0\n"]
        )
        projectURLs.append(url)
        app.launchArguments.append("--ui-test-agent-recovery")
        launchWithProject(url)

        openAgentInbox()
        let firstLaunchRow = recoveryRow
        XCTAssertTrue(
            firstLaunchRow.waitForExistence(timeout: 8),
            "The first launch should create the durable recovery fixture"
        )
        let recoveryActions = app.descendants(matching: .any)[
            "agentInboxRecoveryActions"
        ].firstMatch
        let newSessionButton = app.buttons[
            "agentInboxNewSession"
        ].firstMatch
        let terminal = app.buttons["terminalTab_Terminal 1"].firstMatch
        XCTAssertFalse(recoveryActions.exists)
        XCTAssertFalse(terminal.exists)

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            recoveryActions.waitForExistence(timeout: 3),
            "The first Return must reveal recovery choices"
        )
        XCTAssertTrue(newSessionButton.exists)
        XCTAssertFalse(app.buttons["agentInboxResumeSession"].exists)
        XCTAssertTrue(app.buttons["agentInboxMarkReviewed"].exists)
        XCTAssertTrue(app.buttons["agentInboxCopyObjective"].exists)
        XCTAssertTrue(app.buttons["agentInboxDismissTask"].exists)
        XCTAssertFalse(
            terminal.exists,
            "Revealing recovery choices must not create a terminal"
        )

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(
            recoveryActions.waitForExistence(timeout: 1),
            "Escape must close the recovery choice without closing Inbox"
        )
        XCTAssertTrue(app.descendants(matching: .any)["agentInbox"].exists)
        XCTAssertFalse(terminal.exists)

        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        openAgentInbox()
        let restoredRow = recoveryRow
        XCTAssertTrue(
            restoredRow.waitForExistence(timeout: 8),
            "The second launch should load the persisted recovery card"
        )
        restoredRow.click()
        let restoredNewSession = app.buttons[
            "agentInboxNewSession"
        ].firstMatch
        XCTAssertTrue(
            restoredNewSession.waitForExistence(timeout: 3),
            "A pointer selection must expose the same explicit actions"
        )
        XCTAssertFalse(
            terminal.exists,
            "Restoring task metadata must not launch a terminal automatically"
        )
        restoredNewSession.click()

        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.buttons.matching(identifier: "terminalTab_Terminal 1").count,
            1,
            "One explicit recovery action must create one exact terminal"
        )
    }

    func testVendorResumeIsVisibleAndIsTheKeyboardDefault() throws {
        let url = try createTempProject(
            files: ["release.md": "# Pine 2.0\n"]
        )
        projectURLs.append(url)
        app.launchArguments.append("--ui-test-agent-recovery")
        app.launchArguments.append("--ui-test-agent-vendor-recovery")
        launchWithProject(url)

        openAgentInbox()
        XCTAssertTrue(recoveryRow.waitForExistence(timeout: 8))
        let terminal = app.buttons["terminalTab_Terminal 1"].firstMatch
        XCTAssertFalse(terminal.exists)

        app.typeKey(.return, modifierFlags: [])

        let resumeSession = app.buttons[
            "agentInboxResumeSession"
        ].firstMatch
        XCTAssertTrue(
            resumeSession.waitForExistence(timeout: 3),
            "A validated vendor identity must expose Resume Session"
        )
        XCTAssertTrue(app.buttons["agentInboxNewSession"].exists)
        XCTAssertFalse(terminal.exists)

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "agentInboxNavigationStatus"
            ].firstMatch.waitForExistence(timeout: 5),
            "Return must attempt the visible Resume default, not a new shell"
        )
        XCTAssertFalse(
            terminal.exists,
            "A failed vendor resume must not fall back to New Session"
        )
        XCTAssertTrue(resumeSession.exists)
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

    private func openAgentInbox() {
        clickMenuBarItem("Window")
        let inboxItem = app.menuBars.menuBarItems["Window"]
            .menus.menuItems["Agent Inbox"].firstMatch
        XCTAssertTrue(inboxItem.waitForExistence(timeout: 3))
        inboxItem.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["agentInbox"]
                .firstMatch.waitForExistence(timeout: 5)
        )
    }

    private var recoveryRow: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Recovery fixture'")
        ).firstMatch
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

    func testOpenFolderPanelCancelsWithCommandPeriod() throws {
        launchClean()

        let openFolderButton = app.buttons["welcomeOpenFolderButton"]
        XCTAssertTrue(waitForExistence(openFolderButton))
        openFolderButton.click()

        let openPanel = app.sheets.firstMatch
        XCTAssertTrue(
            openPanel.waitForExistence(timeout: 5),
            "Open panel should be attached to the Welcome window"
        )

        app.typeKey(".", modifierFlags: .command)

        XCTAssertTrue(
            openPanel.waitForNonExistence(timeout: 5),
            "Command-. should cancel the attached panel"
        )
        XCTAssertTrue(app.windows["welcome"].exists)
    }

    // MARK: - P0: Recent project selection → project opens

    func testSingleClickSelectsAndDoubleClickOpensRecentProject() throws {
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

        // Step 4: Single click selects without opening.
        recentItem.click()
        XCTAssertTrue(recentItem.isSelected)
        XCTAssertTrue(welcomeWindow.exists)
        XCTAssertFalse(
            app.scrollViews["sidebar"].exists,
            "Selection must not open a recent project"
        )

        // Double click performs the explicit open action.
        recentItem.doubleClick()

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

        // Step 4: Double-click the selected recent project
        let projectName = url.lastPathComponent
        let recentItem = app.descendants(matching: .any)[
            "welcomeRecentProject_\(projectName)"
        ].firstMatch
        XCTAssertTrue(waitForExistence(recentItem, timeout: 5))
        recentItem.doubleClick()

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
        XCTAssertEqual(recentItem.label, projectName)
        XCTAssertEqual(
            recentItem.value as? String,
            "~" + String(projectDir.path.dropFirst(homeDir.count)),
            "VoiceOver should receive the project name and abbreviated path separately"
        )

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

        let mainFile = app.sidebarNodes["fileNode_main.swift"]
        if waitForExistence(mainFile, timeout: 5) { mainFile.click() }
        let utilsFile = app.sidebarNodes["fileNode_utils.swift"]
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
        recentItem.doubleClick()

        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 10),
            "Project should reopen from Welcome"
        )

        let mainFile2 = app.sidebarNodes["fileNode_main.swift"]
        if waitForExistence(mainFile2, timeout: 5) { mainFile2.click() }
        let utilsFile2 = app.sidebarNodes["fileNode_utils.swift"]
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
        recentItem.click()
        XCTAssertTrue(recentItem.isSelected)

        let openButton = app.buttons["welcomeRecentProjectOpen"]
        let revealButton = app.buttons["welcomeRecentProjectReveal"]
        let removeButton = app.buttons["welcomeRecentProjectRemove"]
        for button in [openButton, revealButton, removeButton] {
            XCTAssertTrue(button.exists, "Recent project actions should be visible")
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(button.isHittable)
        }

        openButton.click()
        XCTAssertTrue(
            waitForExistence(app.scrollViews["sidebar"], timeout: 10),
            "The visible Open action should open the selected project"
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

        let displayedURLs = Array(urls.reversed())
        let items = displayedURLs.map { url in
            let projectName = url.lastPathComponent
            return app.descendants(matching: .any)[
                "welcomeRecentProject_\(projectName)"
            ].firstMatch
        }

        // Verify all 3 recent projects are present and hittable.
        for (url, item) in zip(displayedURLs, items) {
            XCTAssertTrue(
                waitForExistence(item, timeout: 5),
                "Recent project '\(url.lastPathComponent)' should appear"
            )
            XCTAssertTrue(
                item.isHittable,
                "Recent project '\(url.lastPathComponent)' should be hittable"
            )
        }

        // Native list focus owns one stable selection and supports boundaries.
        items[0].click()
        XCTAssertTrue(items[0].isSelected)
        app.typeKey(.end, modifierFlags: [])
        XCTAssertTrue(items[2].isSelected)
        app.typeKey(.home, modifierFlags: [])
        XCTAssertTrue(items[0].isSelected)
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(items[1].isSelected)

        // Return opens exactly the keyboard-selected project.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForExistence(app.scrollViews["sidebar"], timeout: 10),
            "Return should open the keyboard-selected recent project"
        )
    }

    func testFilteringAndRemovingRecentProjectKeepsNearestSelection() throws {
        let alpha = try createTempProject(
            files: ["alpha.swift": "// alpha\n"],
            projectName: "Alpha Recent"
        )
        let beta = try createTempProject(
            files: ["beta.swift": "// beta\n"],
            projectName: "Beta Recent"
        )
        projectURLs.append(contentsOf: [alpha, beta])

        for url in [alpha, beta] {
            app = XCUIApplication()
            app.launchArguments += [
                "--reset-state",
                "-ApplePersistenceIgnoreState", "YES",
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US"
            ]
            launchWithProject(url)
            XCTAssertTrue(
                waitForExistence(app.scrollViews["sidebar"], timeout: 10)
            )
            app.terminate()
        }

        app = XCUIApplication()
        app.launchArguments += ["--reset-state"]
        app.launch()
        app.activate()

        let alphaRow = app.descendants(matching: .any)[
            "welcomeRecentProject_Alpha Recent"
        ].firstMatch
        let betaRow = app.descendants(matching: .any)[
            "welcomeRecentProject_Beta Recent"
        ].firstMatch
        XCTAssertTrue(betaRow.waitForExistence(timeout: 10))
        XCTAssertTrue(alphaRow.exists)

        app.buttons["welcomeSearchToggle"].click()
        let search = app.searchFields["welcomeSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("Alpha")
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 3))
        // The filter is debounced, so the non-matching row leaves a moment
        // after the matching one is confirmed.
        XCTAssertTrue(betaRow.waitForNonExistence(timeout: 3))
        XCTAssertTrue(alphaRow.isSelected)

        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(betaRow.waitForExistence(timeout: 3))
        XCTAssertTrue(
            alphaRow.isSelected,
            "Clearing a filter should preserve the still-visible selection"
        )

        betaRow.click()
        XCTAssertTrue(betaRow.isSelected)
        app.buttons["welcomeRecentProjectRemove"].click()
        XCTAssertTrue(betaRow.waitForNonExistence(timeout: 3))
        XCTAssertTrue(
            alphaRow.isSelected,
            "Removing the final row should select its nearest predecessor"
        )

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForExistence(app.scrollViews["sidebar"], timeout: 10),
            "Removal must restore List focus so Return opens the replacement selection"
        )
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
