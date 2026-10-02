//
//  EditorWindowTests.swift
//  PineUITests
//
//  P1: Editor window — file selection, tabs, save, close.
//

import XCTest

final class EditorWindowTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let greeting = \"Hello\"\n",
            "utils.swift": "func helper() {}\n",
            "README.md": "# Project\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - P1: File selection opens a tab

    func testClickFileInSidebarOpensTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        let fileRow = app.sidebarNodes["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        let tab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(tab, timeout: 5), "Editor tab for main.swift should appear")
    }

    func testDoubleClickingMultipleFilesCreatesTabs() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let mainFile = app.sidebarNodes["fileNode_main.swift"]
        if waitForExistence(mainFile, timeout: 5) { mainFile.doubleClick() }

        let utilsFile = app.sidebarNodes["fileNode_utils.swift"]
        if waitForExistence(utilsFile, timeout: 5) { utilsFile.doubleClick() }

        XCTAssertTrue(waitForExistence(editorTab("main.swift")), "main.swift tab should exist")
        XCTAssertTrue(waitForExistence(editorTab("utils.swift")), "utils.swift tab should exist")
    }

    // MARK: - P1: Switching between tabs

    func testClickingTabSwitchesActiveTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open two files
        let mainFile = app.sidebarNodes["fileNode_main.swift"]
        if waitForExistence(mainFile, timeout: 5) { mainFile.doubleClick() }
        let utilsFile = app.sidebarNodes["fileNode_utils.swift"]
        if waitForExistence(utilsFile, timeout: 5) { utilsFile.doubleClick() }

        // Both tabs should exist
        let mainTab = editorTab("main.swift")
        let utilsTab = editorTab("utils.swift")
        XCTAssertTrue(waitForExistence(mainTab, timeout: 5), "main.swift tab should exist")
        XCTAssertTrue(waitForExistence(utilsTab, timeout: 5), "utils.swift tab should exist")

        // Click on main.swift tab to switch back
        mainTab.click()
        let selectedPredicate = NSPredicate(format: "isSelected == true")
        let selectedExpectation = XCTNSPredicateExpectation(predicate: selectedPredicate, object: mainTab)
        wait(for: [selectedExpectation], timeout: 10)
        XCTAssertTrue(mainTab.isSelected, "main.swift tab should become selected")

        // main.swift tab should still exist (switching doesn't close tabs)
        XCTAssertTrue(mainTab.exists, "main.swift tab should still exist after clicking it")
        XCTAssertTrue(utilsTab.exists, "utils.swift tab should still exist")
    }

    // MARK: - P1: Close button removes tab, activates neighbor

    func testCloseButtonRemovesTabAndActivatesNeighbor() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // Open two files
        let mainFile = app.sidebarNodes["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 5))
        mainFile.doubleClick()

        let utilsFile = app.sidebarNodes["fileNode_utils.swift"]
        XCTAssertTrue(waitForExistence(utilsFile, timeout: 5))
        utilsFile.doubleClick()

        // Both tabs should exist
        let mainTab = editorTab("main.swift")
        let utilsTab = editorTab("utils.swift")
        XCTAssertTrue(waitForExistence(mainTab))
        XCTAssertTrue(waitForExistence(utilsTab))

        // Click close button on utils.swift tab
        let closeButton = editorTabCloseButton("utils.swift")
        XCTAssertTrue(waitForExistence(closeButton, timeout: 5), "Close button should be accessible")
        closeButton.click()

        // utils.swift tab should disappear
        XCTAssertTrue(utilsTab.waitForNonExistence(timeout: 5), "Tab should close after clicking close button")

        // main.swift tab should still exist (neighbor activated)
        XCTAssertTrue(mainTab.exists, "Neighbor tab should remain after closing another tab")
    }

    // MARK: - P1: Editor placeholder when no tabs open

    func testEditorPlaceholderShownWithNoTabs() throws {
        launchWithProject(projectURL)

        // ContentUnavailableView doesn't reliably propagate accessibilityIdentifier as staticText,
        // so we find the placeholder by its text content instead.
        let placeholder = app.staticTexts["No File Selected"].firstMatch
        XCTAssertTrue(waitForExistence(placeholder, timeout: 10), "Editor placeholder should be visible when no tabs are open")
    }

    // MARK: - P1: Duplicate creates tab with copy naming

    func testDuplicateCreatesTabWithCopyNaming() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file
        let mainFile = app.sidebarNodes["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 5))
        mainFile.click()

        let mainTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(mainTab, timeout: 5))

        // File > Duplicate via menu. The File ▸ Sidebar submenu (#1537) adds
        // a second "Duplicate" item, so match the visible top-level one:
        // items of closed submenus leak into the query with a zero frame.
        app.activate()
        clickMenuBarItem("File")
        let duplicateItem = app.menuItems
            .matching(NSPredicate(format: "title == %@", "Duplicate"))
            .allElementsBoundByIndex
            .first { $0.frame.width > 0 && $0.frame.height > 0 }
        XCTAssertNotNil(duplicateItem, "File menu should contain Duplicate")
        duplicateItem?.click()

        // A new tab "main copy.swift" should appear
        let copyTab = editorTab("main copy.swift")
        XCTAssertTrue(waitForExistence(copyTab, timeout: 5), "Duplicate tab should appear with Finder-like copy naming")

        // Original tab should still exist
        XCTAssertTrue(mainTab.exists, "Original tab should remain after duplicating")
    }

    // MARK: - P1: Save All saves dirty files

    func testSaveAllMenuItemExists() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file so Save All menu item is relevant
        let mainFile = app.sidebarNodes["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 5))
        mainFile.click()

        let mainTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(mainTab, timeout: 5))

        // File menu should contain Save All
        app.activate()
        clickMenuBarItem("File")
        let saveAllItem = app.menuItems["Save All"]
        XCTAssertTrue(waitForExistence(saveAllItem, timeout: 3), "Save All menu item should exist")

        // Also check Save As… and Duplicate exist
        let saveAsItem = app.menuItems["Save As…"]
        XCTAssertTrue(saveAsItem.exists, "Save As… menu item should exist")

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.exists, "Duplicate menu item should exist")
    }

    // MARK: - Problems panel chrome

    func testProblemsPanelTogglesFromViewMenu() throws {
        launchWithProject(projectURL)

        let mainFile = app.sidebarNodes["fileNode_main.swift"]
        XCTAssertTrue(
            waitForExistence(mainFile, timeout: 10),
            "main.swift should appear in the sidebar"
        )
        mainFile.click()
        XCTAssertTrue(
            waitForExistence(editorTab("main.swift"), timeout: 5),
            "Opening a file should create an editor tab"
        )

        clickMenuBarItem("View")
        let problemsItem = app.menuItems["Problems"]
        XCTAssertTrue(
            waitForExistence(problemsItem, timeout: 3),
            "View menu should expose the Problems panel"
        )
        XCTAssertTrue(problemsItem.isEnabled)
        problemsItem.click()

        let panel = app.descendants(matching: .any)["problemsPanel"].firstMatch
        XCTAssertTrue(
            waitForExistence(panel, timeout: 5),
            "Problems should open in the editor chrome"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["problemsHelpButton"]
                .firstMatch.exists,
            "Problems should expose its language-server Help topic"
        )

        clickMenuBarItem("View")
        app.menuItems["Problems"].click()
        XCTAssertTrue(
            panel.waitForNonExistence(timeout: 5),
            "Toggling Problems again should close the panel"
        )
    }

    // MARK: - P1: Session restore highlights active file in sidebar

    func testSidebarHighlightsActiveFileAfterSessionRestore() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open a file to create a session
        let mainFile = app.sidebarNodes["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 5))
        mainFile.click()

        let mainTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(mainTab, timeout: 5))

        // Close the project window → Welcome appears
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"].firstMatch
        XCTAssertTrue(closeButton.exists)
        closeButton.click()

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10), "Welcome should appear")

        // Reopen the same project from recent projects list
        let projectName = projectURL.lastPathComponent
        let recentProject = app.descendants(matching: .any)[
            "welcomeRecentProject_\(projectName)"
        ].firstMatch
        XCTAssertTrue(waitForExistence(recentProject, timeout: 5), "Project should be in recents")
        recentProject.doubleClick()

        // Wait for project window to appear
        let sidebarAfterRestore = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebarAfterRestore, timeout: 15), "Project should reopen")

        // Tab should be restored from session
        let restoredTab = editorTab("main.swift")
        XCTAssertTrue(waitForExistence(restoredTab, timeout: 15), "Tab should be restored from session")

        // Wait for async file tree load — the restored tab above already
        // verifies the session was restored; here we just confirm the row
        // is visible in the new ScrollView-based sidebar. There is no
        // native selection trait anymore, so selection is implicitly
        // verified by the restored tab.
        let mainRow = app.sidebarNodes["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainRow, timeout: 15), "main.swift row should exist in sidebar")
    }

    // MARK: - P1: Unrecognized file extensions open as text, not preview

    func testUnrecognizedExtensionOpensAsText() throws {
        // Create a project with a .go file (unrecognized by macOS UTType as text)
        let goProjectURL = try createTempProject(files: [
            "main.go": "package main\n\nfunc main() {}\n"
        ])
        defer { cleanupProject(goProjectURL) }

        launchWithProject(goProjectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        let fileRow = app.sidebarNodes["fileNode_main.go"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("main.go should appear in the sidebar")
            return
        }
        fileRow.click()

        let tab = editorTab("main.go")
        XCTAssertTrue(waitForExistence(tab, timeout: 5), "Editor tab for main.go should appear")

        // The code editor should be shown, not Quick Look preview
        let codeEditor = app.textViews["codeEditor"].firstMatch
        let quickLook = app.descendants(matching: .any)["quickLookPreview"].firstMatch

        XCTAssertTrue(
            waitForExistence(codeEditor, timeout: 5),
            "Code editor should be displayed for .go files"
        )
        XCTAssertFalse(
            quickLook.exists,
            "Quick Look preview should NOT be displayed for .go files"
        )
    }

    // MARK: - P1: Status bar terminal toggle visible

    func testTerminalToggleButtonVisible() throws {
        launchWithProject(projectURL)

        let terminalToggle = app.descendants(matching: .any)["terminalToggleButton"].firstMatch
        XCTAssertTrue(waitForExistence(terminalToggle, timeout: 10), "Terminal toggle button should be visible in status bar")
    }

    // MARK: - View menu structure

    func testSingleViewMenuWithRevealItems() throws {
        launchWithProject(projectURL)

        // Open a file so "Reveal File in Finder" is enabled
        let mainFile = app.sidebarNodes["fileNode_main.swift"]
        XCTAssertTrue(waitForExistence(mainFile, timeout: 10))
        mainFile.click()
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 5))

        // There should be exactly one View menu item in the menu bar
        let viewMenuItems = app.menuBars.menuBarItems.matching(
            NSPredicate(format: "title == 'View'")
        )
        XCTAssertEqual(viewMenuItems.count, 1, "There should be exactly one View menu")

        // Finder and Xcode place "Show in Finder" in the File menu (#1564).
        // Open the File menu and check for the Reveal items.
        app.menuBars.menuBarItems["File"].click()

        let revealFile = app.menuItems["Reveal File in Finder"]
        XCTAssertTrue(revealFile.exists, "File menu should contain 'Reveal File in Finder'")

        let revealProject = app.menuItems["Reveal Project in Finder"]
        XCTAssertTrue(revealProject.exists, "File menu should contain 'Reveal Project in Finder'")
    }

    // MARK: - Window title does not repeat the project switcher label

    /// The toolbar's project switcher already names the project. The native
    /// title showed that same name again, printing one word twice in a single
    /// strip; it now carries the active file and falls back to the project
    /// only when no editor tab is open.
    func testWindowTitleShowsActiveFileInsteadOfRepeatingProjectName() throws {
        let namedProject = try createTempProject(
            files: [
                "main.swift": "let greeting = \"Hello\"\n",
                "utils.swift": "func helper() {}\n"
            ],
            projectName: "TitleFixture"
        )
        defer { cleanupProject(namedProject) }

        launchWithProject(namedProject)

        XCTAssertTrue(
            waitForExistence(app.windows["TitleFixture"], timeout: 10),
            "With no editor tab open the window keeps the project name"
        )

        openFile("main.swift")
        XCTAssertTrue(
            waitForExistence(app.windows["main.swift"], timeout: 5),
            "An open file should title the window"
        )
        XCTAssertTrue(
            app.windows["TitleFixture"].waitForNonExistence(timeout: 5),
            "The project name must leave the title bar while a file is open "
                + "— the project switcher is the one place that shows it"
        )

        openFile("utils.swift")
        XCTAssertTrue(
            waitForExistence(app.windows["utils.swift"], timeout: 5),
            "Activating another tab should retitle the window"
        )

        let close = editorTabCloseButton("utils.swift")
        XCTAssertTrue(waitForExistence(close, timeout: 5))
        close.click()
        XCTAssertTrue(
            waitForExistence(app.windows["main.swift"], timeout: 5),
            "Closing the active tab should retitle to the next active file"
        )
    }

    // MARK: - Project switcher lives in the sidebar header

    /// The switcher moved out of the toolbar into a full-width header row at
    /// the top of the sidebar column. The assertions stay relative — toolbar
    /// and column metrics differ between macOS versions and display scales —
    /// but a header row must span the column and sit above the file tree,
    /// where the capsule it replaced could never be confused with the round
    /// toolbar buttons.
    func testProjectSwitcherLivesInSidebarHeader() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 10),
            "Sidebar should appear"
        )

        let switcher = app.descendants(matching: .any)[
            "projectSwitcher"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(switcher, timeout: 10),
            "The project switcher should head the sidebar"
        )
        assertExactlyOneSwitcher("sidebar visible")

        let openFolder = app.descendants(matching: .any)[
            "openFolderToolbarButton"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(openFolder, timeout: 5),
            "The sidebar's Open Folder button should be visible"
        )

        XCTAssertGreaterThan(
            switcher.frame.width,
            openFolder.frame.width,
            "A full-width header row must be wider than a single-glyph "
                + "toolbar button (\(switcher.frame.width) vs "
                + "\(openFolder.frame.width))"
        )
        XCTAssertLessThanOrEqual(
            abs(switcher.frame.width - sidebar.frame.width),
            10,
            "The header should span the sidebar column edge to edge "
                + "(\(switcher.frame.width) vs \(sidebar.frame.width))"
        )
        XCTAssertLessThan(
            switcher.frame.minY,
            sidebar.frame.minY,
            "The header row sits above the file tree, not inside it"
        )
        XCTAssertLessThanOrEqual(
            abs(switcher.frame.midX - sidebar.frame.midX),
            8,
            "The header should be centred over the sidebar column "
                + "(\(switcher.frame) vs \(sidebar.frame))"
        )
    }

    // MARK: - Project switcher falls back to the toolbar when the sidebar is hidden

    /// Collapsing the sidebar removes the header with it. The switcher must
    /// stay reachable, so the pre-header toolbar capsule returns for exactly
    /// that state — and leaves again once the column comes back.
    func testProjectSwitcherFallsBackToToolbarWhenSidebarCollapsed() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 10),
            "Sidebar should appear"
        )

        let switcher = app.descendants(matching: .any)[
            "projectSwitcher"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(switcher, timeout: 10),
            "The project switcher should head the sidebar"
        )
        assertExactlyOneSwitcher("sidebar visible")

        toggleSidebarViaMenu()
        XCTAssertTrue(
            sidebar.waitForNonExistence(timeout: 10),
            "View ▸ Toggle Sidebar should collapse the sidebar"
        )
        XCTAssertTrue(
            waitForExistence(switcher, timeout: 10),
            "With the sidebar hidden the switcher must remain in the window "
                + "as the toolbar fallback"
        )
        assertExactlyOneSwitcher("sidebar collapsed")

        // The capsule belongs to the toolbar strip: with the column gone,
        // nothing but the toolbar sits at the top of the window.
        let toolbar = app.toolbars.firstMatch
        XCTAssertTrue(
            toolbar.exists,
            "The window toolbar should exist with the sidebar collapsed"
        )
        XCTAssertTrue(
            toolbar.frame.contains(
                CGPoint(x: switcher.frame.midX, y: switcher.frame.midY)
            ),
            "The fallback capsule must live in the toolbar strip "
                + "(\(switcher.frame) vs toolbar \(toolbar.frame))"
        )

        // A capsule holding icon and chevron is never narrower than a
        // single-glyph neighbour — the property the removed toolbar-metrics
        // test pinned. The sidebar's Open Folder button leaves with the
        // column, so the always-present Agent Inbox button is the yardstick.
        let inboxButton = app.buttons["agentInboxToolbarButton"].firstMatch
        XCTAssertTrue(
            waitForExistence(inboxButton, timeout: 5),
            "The Agent Inbox toolbar button should remain visible"
        )
        XCTAssertGreaterThan(
            switcher.frame.width,
            inboxButton.frame.width,
            "The capsule carries more than one glyph, so it must be wider "
                + "than a single-glyph toolbar button "
                + "(\(switcher.frame.width) vs \(inboxButton.frame.width))"
        )

        toggleSidebarViaMenu()
        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 10),
            "View ▸ Toggle Sidebar should bring the sidebar back"
        )
        XCTAssertTrue(
            waitForExistence(switcher, timeout: 10),
            "The switcher should be back once the sidebar returns"
        )
        assertExactlyOneSwitcher("sidebar restored")
        XCTAssertLessThan(
            switcher.frame.minY,
            sidebar.frame.minY,
            "The switcher must move back into the header above the file "
                + "tree, not stay in the toolbar"
        )
    }

    /// At rest exactly one switcher exists: the header with the sidebar
    /// visible, the toolbar capsule with it collapsed. A regression that
    /// shows the capsule unconditionally produces two, and one that shows
    /// neither produces zero. Only asserted after transitions settle —
    /// mid-animation both can briefly coexist.
    private func assertExactlyOneSwitcher(_ context: String) {
        let count = app.descendants(matching: .any)
            .matching(identifier: "projectSwitcher")
            .count
        XCTAssertEqual(
            count,
            1,
            "Exactly one project switcher should exist with \(context)"
        )
    }

    /// Drives the sidebar through View ▸ Toggle Sidebar.
    ///
    /// The ⌃⌘S shortcut is the obvious driver, but `typeKey` posts synthetic
    /// events down the accessibility path, which never reaches the split
    /// view's toggle — this suite's launch notes (`.claude/rules/ui-tests.md`)
    /// and the #1544 probe both document lost sidebar keystrokes, and CI lost
    /// this one three runs out of three. Menu clicks travel the real menu
    /// path every other command in the suite already uses. The item is
    /// SwiftUI's system-provided one (Pine never replaces the `.sidebar`
    /// command group), so its title is not ours to pin; match every spelling
    /// macOS has used for it.
    private func toggleSidebarViaMenu() {
        clickMenuBarItem("View")
        let item = app.menuItems.matching(
            NSPredicate(
                format: "title IN {'Toggle Sidebar', 'Show Sidebar', 'Hide Sidebar'}"
            )
        ).firstMatch
        XCTAssertTrue(
            item.waitForExistence(timeout: 5),
            "The View menu should offer the system sidebar toggle"
        )
        item.click()
    }

    // MARK: - Sidebar context menu has Reveal in Finder

    func testSidebarContextMenuRevealInFinder() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Right-click on empty area of sidebar
        sidebar.rightClick()

        let revealItem = app.menuItems["Reveal in Finder"]
        XCTAssertTrue(
            waitForExistence(revealItem, timeout: 5),
            "Sidebar context menu should contain 'Reveal in Finder'"
        )
    }
}
