//
//  NativeFileWindowMenuUITests.swift
//  PineUITests
//
//  Mouse-driven acceptance coverage for issue #1275.
//

import AppKit
import XCTest

final class NativeFileWindowMenuUITests: PineUITestCase {
    private var projectURL: URL!
    private var secondProjectURL: URL!

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

    /// Polls for the first hittable text field within `timeout`.
    ///
    /// `NSOpenPanel`'s "Go to Folder" sheet animates its path field in
    /// asynchronously, and `app.typeKey` can race the field's appearance on
    /// CI runners. Polling avoids `XCTUnwrap` failing fast before the sheet is
    /// fully interactive (stabilizes #1291, #1295).
    private func firstHittableTextField(
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let field = app.textFields.allElementsBoundByIndex.first(
                where: { $0.isHittable }
            ) {
                return field
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return app.textFields.allElementsBoundByIndex.first {
            $0.isHittable
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(
            files: ["main.swift": "let value = 1\n"],
            projectName: "Native Menu Project"
        )
        secondProjectURL = try createTempProject(
            files: ["second.swift": "let second = true\n"],
            projectName: "Second Native Menu Project"
        )
    }

    override func tearDownWithError() throws {
        if let projectURL {
            cleanupProject(projectURL)
        }
        if let secondProjectURL {
            cleanupProject(secondProjectURL)
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

            let cancelButton = openPanel.buttons["Cancel"].firstMatch
            XCTAssertTrue(
                cancelButton.waitForExistence(timeout: 5),
                "The owned folder picker should expose a mouse-driven Cancel action"
            )
            cancelButton.click()
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

    func testOpenFolderToolbarPresentsReusableOwnedPanel() {
        launchWithProject(projectURL)
        let openFolder = app.buttons["openFolderToolbarButton"].firstMatch
        XCTAssertTrue(
            openFolder.waitForExistence(timeout: 10),
            "The sidebar toolbar should expose Open Folder"
        )

        for attempt in 1...2 {
            openFolder.click()
            let openPanel = app.sheets.firstMatch
            XCTAssertTrue(
                openPanel.waitForExistence(timeout: 5),
                "Toolbar Open Folder should present an owned sheet on attempt \(attempt)"
            )
            XCTAssertTrue(openPanel.buttons["Open"].firstMatch.exists)
            let cancelButton = openPanel.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
            cancelButton.click()
            XCTAssertTrue(openPanel.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.scrollViews["sidebar"].firstMatch.exists)
        }
    }

    func testOpenFolderToolbarRecoversWithActiveAgentAndRemainsReusable() throws {
        NSPasteboard.general.clearContents()
        defer { NSPasteboard.general.clearContents() }
        app.launchArguments.append("--ui-test-live-agent")
        launchWithProject(projectURL)

        let agentTerminal = app.descendants(matching: .any)[
            "terminalTab_Terminal 1"
        ].firstMatch
        XCTAssertTrue(
            agentTerminal.waitForExistence(timeout: 10),
            "The project should contain the deterministic live-agent terminal"
        )
        let agentStatus = app.buttons["agentStatusBar"].firstMatch
        XCTAssertTrue(
            agentStatus.waitForExistence(timeout: 5),
            "The fixture must activate an agent after the project window mounts"
        )
        XCTAssertTrue(agentStatus.label.contains("Executing"))

        // Exercise the exact post-close-confirmation lifecycle from #1407:
        // create dirty editor content, request a whole-window close by mouse,
        // then cancel its project-owned sheet before opening another folder.
        clickMenuBarItem("File")
        app.menuItems["New File"].firstMatch.click()
        let editor = app.textViews["codeEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        XCTAssertTrue(
            NSPasteboard.general.setString(
                "keep this project open\n",
                forType: .string
            )
        )
        clickMenuBarItem("Edit")
        app.menuItems["Paste"].firstMatch.click()
        clickMenuBarItem("Window")
        app.menuItems["Close Window"].firstMatch.click()
        let closeConfirmation = app.sheets.firstMatch
        XCTAssertTrue(closeConfirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(
            closeConfirmation.staticTexts["Unsaved Changes"].firstMatch.exists
        )
        closeConfirmation.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(closeConfirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(agentTerminal.exists)
        XCTAssertTrue(
            agentStatus.waitForExistence(timeout: 5),
            "Cancelling window close must preserve the active agent"
        )
        XCTAssertTrue(agentStatus.label.contains("Executing"))

        let openFolder = app.buttons["openFolderToolbarButton"].firstMatch
        XCTAssertTrue(
            openFolder.waitForExistence(timeout: 10),
            "The sidebar toolbar should expose Open Folder"
        )

        for attempt in 1...2 {
            openFolder.click()
            let openPanel = app.sheets.firstMatch
            XCTAssertTrue(
                openPanel.waitForExistence(timeout: 5),
                "Toolbar Open Folder should present a project-owned sheet on attempt \(attempt)"
            )
            let cancelButton = openPanel.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
            cancelButton.click()
            XCTAssertTrue(openPanel.waitForNonExistence(timeout: 5))
            XCTAssertTrue(
                agentTerminal.exists,
                "Cancelling Open Folder must preserve the active agent terminal"
            )
            XCTAssertTrue(
                agentStatus.waitForExistence(timeout: 5),
                "Open Folder attempt \(attempt) must keep the agent active"
            )
            XCTAssertTrue(agentStatus.label.contains("Executing"))
        }

        // Remove only the dirty editor tab, then exercise a full native
        // window close/reopen while the terminal-backed agent remains owned
        // by the background ProjectManager.
        clickMenuBarItem("File")
        app.menuItems["Close Tab"].firstMatch.click()
        let discardAlert = app.sheets.firstMatch
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 5))
        discardAlert.buttons["Don't Save"].firstMatch.click()
        XCTAssertTrue(discardAlert.waitForNonExistence(timeout: 5))

        clickMenuBarItem("Window")
        app.menuItems["Close Window"].firstMatch.click()
        XCTAssertTrue(
            app.scrollViews["sidebar"].waitForNonExistence(timeout: 5),
            "Window close should background active work without a terminal warning"
        )
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertTrue(app.windows["welcome"].waitForExistence(timeout: 10))

        clickMenuBarItem("File")
        app.menuItems["Open Recent"].firstMatch.click()
        let recentPrefix = "\(projectURL.lastPathComponent) — "
        let recentProject = try XCTUnwrap(
            visibleMenuItem(matching: NSPredicate(
                format: "title BEGINSWITH %@",
                recentPrefix
            ))
        )
        recentProject.click()
        XCTAssertTrue(app.scrollViews["sidebar"].waitForExistence(timeout: 10))
        XCTAssertTrue(agentTerminal.waitForExistence(timeout: 10))
        XCTAssertTrue(agentStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(agentStatus.label.contains("Executing"))

        let reopenedOpenFolder = app.buttons[
            "openFolderToolbarButton"
        ].firstMatch
        XCTAssertTrue(reopenedOpenFolder.waitForExistence(timeout: 5))
        reopenedOpenFolder.click()
        let reopenedPanel = app.sheets.firstMatch
        XCTAssertTrue(
            reopenedPanel.waitForExistence(timeout: 5),
            "Open Folder should survive active-agent window close/reopen"
        )
        reopenedPanel.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(reopenedPanel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(agentStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(agentStatus.label.contains("Executing"))
    }

    func testOpenFolderSelectsDirectoryAndRoutesCommandToNewWindow() throws {
        launchWithProject(projectURL)
        let firstWindow = app.windows[projectURL.lastPathComponent].firstMatch
        XCTAssertTrue(
            firstWindow.waitForExistence(timeout: 10),
            "The original project window should be visible"
        )

        clickMenuBarItem("File")
        let openFolder = app.menuItems["Open Folder…"].firstMatch
        XCTAssertTrue(openFolder.waitForExistence(timeout: 5))
        openFolder.click()

        let openPanel = app.sheets.firstMatch
        XCTAssertTrue(
            openPanel.waitForExistence(timeout: 5),
            "Open Folder should present a directory picker"
        )

        // Wait for the open panel to become interactive (it animates in),
        // then route Cmd+Shift+G to the sheet itself so the "Go to Folder"
        // path field reliably appears. Sending the shortcut to `app` can race
        // the panel gaining first-responder on CI (#1291, #1295).
        _ = XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "isHittable == true"),
                    object: openPanel
                )
            ],
            timeout: 5
        )
        openPanel.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = try XCTUnwrap(
            firstHittableTextField(timeout: 5),
            "Go to Folder should expose a hittable path field"
        )
        pathField.typeText(secondProjectURL.path)
        pathField.typeKey(.return, modifierFlags: [])

        let openButton = openPanel.buttons["Open"].firstMatch
        XCTAssertTrue(
            waitForEnabled(openButton, timeout: 5),
            "Resolving the directory should enable Open"
        )
        openButton.click()

        let secondWindow = app.windows[
            secondProjectURL.lastPathComponent
        ].firstMatch
        XCTAssertTrue(
            secondWindow.waitForExistence(timeout: 10),
            "Selecting a directory should open its project window"
        )
        XCTAssertTrue(
            secondWindow.descendants(matching: .any)[
                "fileNode_second.swift"
            ].firstMatch.waitForExistence(timeout: 10),
            "The new window should display the selected project"
        )

        clickMenuBarItem("File")
        app.menuItems["New File"].firstMatch.click()

        XCTAssertTrue(
            secondWindow.buttons["editorTab_Untitled"]
                .firstMatch.waitForExistence(timeout: 5),
            "File > New File should route to the newly focused project"
        )
        XCTAssertFalse(
            firstWindow.buttons["editorTab_Untitled"].firstMatch.exists,
            "The command must not mutate the background project"
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

    func testFileMenuContainsActionsNotEditorPreferences() throws {
        launchWithProject(projectURL)
        XCTAssertTrue(
            waitForExistence(app.scrollViews["sidebar"], timeout: 10)
        )

        clickMenuBarItem("File")

        XCTAssertFalse(app.menuItems["Auto Save"].exists)
        XCTAssertFalse(app.menuItems["Format on Save"].exists)
        XCTAssertFalse(app.menuItems["Smart List Continuation"].exists)
        XCTAssertTrue(app.menuItems["Save"].exists)
        XCTAssertTrue(app.menuItems["Save As…"].exists)
    }
}
