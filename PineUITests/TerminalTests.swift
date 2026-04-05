//
//  TerminalTests.swift
//  PineUITests
//
//  Comprehensive UI tests for terminal-in-split-panes feature.
//

import XCTest

final class TerminalTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject()
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func terminalTab(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["terminalTab_\(name)"].firstMatch
    }

    private var terminalTabBar: XCUIElement {
        app.descendants(matching: .any)["terminalTabBar"].firstMatch
    }

    private var newTerminalButton: XCUIElement {
        app.descendants(matching: .any)["newTerminalButton"].firstMatch
    }

    private var maximizeButton: XCUIElement {
        app.descendants(matching: .any)["maximizeTerminalButton"].firstMatch
    }

    private var hideButton: XCUIElement {
        app.descendants(matching: .any)["hideTerminalButton"].firstMatch
    }

    private var terminalToggle: XCUIElement {
        app.descendants(matching: .any)["terminalToggleButton"].firstMatch
    }

    private var editorTabBar: XCUIElement {
        app.descendants(matching: .any)["editorTabBar"].firstMatch
    }

    private var editorPlaceholder: XCUIElement {
        app.descendants(matching: .any)["editorPlaceholder"].firstMatch
    }

    private var paneDividers: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "paneDivider")
    }

    private func createTerminalViaMenu() {
        clickMenuBarItem("Terminal")
        app.menuItems["New Tab"].click()
    }

    private func launchAndWaitForLoad() {
        launchWithProject(projectURL)
        guard waitForExistence(terminalToggle, timeout: 10) else {
            XCTFail("Window failed to load — terminal toggle not found in status bar")
            return
        }
    }

    // MARK: - Basic Terminal Creation

    /// Terminal -> New Tab creates a terminal pane with "Terminal 1" tab.
    func testNewTerminalTabViaMenu() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()

        let tab1 = terminalTab("Terminal 1")
        XCTAssertTrue(
            waitForExistence(tab1, timeout: 10),
            "Terminal 1 tab should appear after Terminal -> New Tab"
        )

        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 5),
            "Terminal tab bar buttons should be visible"
        )
    }

    /// Two Terminal -> New Tab creates "Terminal 1" and "Terminal 2" in the same pane.
    func testSecondTerminalTabViaMenu() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()

        let tab1 = terminalTab("Terminal 1")
        XCTAssertTrue(
            waitForExistence(tab1, timeout: 10),
            "Terminal 1 tab should appear"
        )

        createTerminalViaMenu()

        let tab2 = terminalTab("Terminal 2")
        XCTAssertTrue(
            waitForExistence(tab2, timeout: 10),
            "Terminal 2 tab should appear after second New Tab"
        )

        // Both tabs should coexist
        XCTAssertTrue(tab1.exists, "Terminal 1 should still exist alongside Terminal 2")
    }

    /// After creating a terminal, a pane divider appears indicating split layout.
    func testTerminalPaneAppearsInSplitLayout() throws {
        launchAndWaitForLoad()

        // No divider before terminal
        XCTAssertEqual(paneDividers.count, 0, "No pane divider should exist initially")

        createTerminalViaMenu()

        // Wait for the terminal tab to confirm it was created
        XCTAssertTrue(
            waitForExistence(terminalTab("Terminal 1"), timeout: 10),
            "Terminal tab should appear"
        )

        // A divider should now separate editor from terminal
        let divider = app.descendants(matching: .any)["paneDivider"].firstMatch
        XCTAssertTrue(
            waitForExistence(divider, timeout: 5),
            "Pane divider should appear between editor and terminal"
        )
    }

    // MARK: - Terminal Tab Bar Buttons

    /// Click plus button adds a new terminal tab.
    func testNewTerminalButtonAddsTab() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Plus button should be visible"
        )

        // Click plus to add second tab
        newTerminalButton.click()

        let tab2 = terminalTab("Terminal 2")
        XCTAssertTrue(
            waitForExistence(tab2, timeout: 5),
            "Terminal 2 should appear after clicking plus button"
        )
    }

    /// Click maximize button hides the editor, only terminal visible.
    func testMaximizeTerminalPane() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(maximizeButton, timeout: 10),
            "Maximize button should be visible"
        )

        maximizeButton.click()

        // After maximize, pane divider should disappear (single pane fills area)
        let divider = app.descendants(matching: .any)["paneDivider"].firstMatch
        let deadline = Date().addingTimeInterval(5)
        while divider.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(divider.exists, "Pane divider should disappear when terminal is maximized")

        // Terminal tab should still be visible
        XCTAssertTrue(
            terminalTab("Terminal 1").exists,
            "Terminal tab should remain visible when maximized"
        )

        // Editor placeholder or tab bar should not be hittable
        XCTAssertFalse(
            editorPlaceholder.isHittable,
            "Editor placeholder should not be hittable when terminal is maximized"
        )
    }

    /// Maximize then restore brings back both panes.
    func testRestoreFromMaximize() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(maximizeButton, timeout: 10),
            "Maximize button should exist"
        )

        // Maximize
        maximizeButton.click()

        // Wait for divider to disappear
        let divider = app.descendants(matching: .any)["paneDivider"].firstMatch
        let disappearDeadline = Date().addingTimeInterval(5)
        while divider.exists && Date() < disappearDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Restore — the button toggles between maximize and restore
        maximizeButton.click()

        // Pane divider should reappear
        XCTAssertTrue(
            waitForExistence(divider, timeout: 5),
            "Pane divider should reappear after restoring from maximize"
        )

        // Both terminal and editor should be visible
        XCTAssertTrue(
            terminalTab("Terminal 1").exists,
            "Terminal tab should be visible after restore"
        )
        XCTAssertTrue(
            editorPlaceholder.exists || editorTabBar.exists,
            "Editor area should be visible after restore"
        )
    }

    /// Click hide/close button removes the terminal pane entirely.
    func testHideTerminalPane() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(hideButton, timeout: 10),
            "Hide button should be visible"
        )

        hideButton.click()

        // Terminal tab bar should disappear
        let tabBar = terminalTabBar
        let deadline = Date().addingTimeInterval(5)
        while tabBar.isHittable && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(
            tabBar.isHittable,
            "Terminal tab bar should not be hittable after hiding"
        )

        // Pane divider should also disappear
        let divider = app.descendants(matching: .any)["paneDivider"].firstMatch
        XCTAssertFalse(divider.exists, "Pane divider should disappear after hiding terminal")
    }

    // MARK: - Tab Management

    /// Close a terminal tab using the X button on the tab itself.
    func testCloseTerminalTabViaCloseButton() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Terminal should appear"
        )

        // Add a second tab so closing one doesn't remove the pane
        newTerminalButton.click()
        let tab2 = terminalTab("Terminal 2")
        XCTAssertTrue(
            waitForExistence(tab2, timeout: 5),
            "Terminal 2 should appear"
        )

        // The close button (xmark) is inside the tab — find the first button descendant
        // within the Terminal 1 tab element
        let tab1 = terminalTab("Terminal 1")
        // Click on tab1 first to make it active (close button is visible on hover/active)
        tab1.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Find the xmark button inside tab1
        let closeBtn = tab1.buttons.firstMatch
        if closeBtn.exists && closeBtn.isHittable {
            closeBtn.click()
        } else {
            // Hover to reveal the close button then click
            tab1.hover()
            Thread.sleep(forTimeInterval: 0.3)
            if closeBtn.exists && closeBtn.isHittable {
                closeBtn.click()
            } else {
                XCTFail("Close button on Terminal 1 tab is not accessible")
                return
            }
        }

        // Terminal 1 should disappear
        let deadline = Date().addingTimeInterval(5)
        while tab1.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(tab1.exists, "Terminal 1 tab should be removed after closing")

        // Terminal 2 should remain
        XCTAssertTrue(tab2.exists, "Terminal 2 should still exist")
    }

    /// Closing the only terminal tab removes the entire terminal pane.
    func testCloseLastTabRemovesPane() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        let tab1 = terminalTab("Terminal 1")
        XCTAssertTrue(
            waitForExistence(tab1, timeout: 10),
            "Terminal 1 should appear"
        )

        // Use hide button to close the pane (closes all tabs)
        hideButton.click()

        // Pane divider should disappear
        let divider = app.descendants(matching: .any)["paneDivider"].firstMatch
        let deadline = Date().addingTimeInterval(5)
        while divider.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(divider.exists, "Pane divider should disappear when last tab is closed")

        // Terminal tab should no longer exist
        XCTAssertFalse(tab1.exists, "Terminal 1 tab should be gone")
    }

    /// Click different terminal tabs to switch between them.
    func testSwitchBetweenTerminalTabs() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Terminal should appear"
        )

        // Add second tab
        newTerminalButton.click()
        let tab2 = terminalTab("Terminal 2")
        XCTAssertTrue(
            waitForExistence(tab2, timeout: 5),
            "Terminal 2 should appear"
        )

        // Terminal 2 should be active (just created)
        // Click Terminal 1 to switch
        let tab1 = terminalTab("Terminal 1")
        tab1.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Click Terminal 2 again
        tab2.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Both tabs should still exist after switching
        XCTAssertTrue(tab1.exists, "Terminal 1 should still exist after switching")
        XCTAssertTrue(tab2.exists, "Terminal 2 should still exist after switching")
    }

    // MARK: - Multiple Terminal Panes

    /// Create terminal, close it, create another — verify it works correctly.
    func testMultipleTerminalPanesViaMenu() throws {
        launchAndWaitForLoad()

        // Create first terminal
        createTerminalViaMenu()
        let tab1 = terminalTab("Terminal 1")
        XCTAssertTrue(
            waitForExistence(tab1, timeout: 10),
            "First Terminal 1 should appear"
        )

        // Close terminal pane
        hideButton.click()
        let deadline = Date().addingTimeInterval(5)
        while tab1.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(tab1.exists, "Terminal should be gone after hide")

        // Create terminal again
        createTerminalViaMenu()
        let newTab1 = terminalTab("Terminal 1")
        XCTAssertTrue(
            waitForExistence(newTab1, timeout: 10),
            "New Terminal 1 should appear after re-creating terminal"
        )

        // Verify pane divider exists again
        let divider = app.descendants(matching: .any)["paneDivider"].firstMatch
        XCTAssertTrue(
            waitForExistence(divider, timeout: 5),
            "Pane divider should reappear with new terminal"
        )
    }

    // MARK: - Edge Cases

    /// Status bar shows terminal toggle button, and it is present when terminal pane exists.
    func testTerminalIndicatorInStatusBar() throws {
        launchAndWaitForLoad()

        // Terminal toggle should exist in status bar even before terminal is created
        XCTAssertTrue(
            terminalToggle.exists,
            "Terminal toggle should exist in status bar"
        )

        // Create terminal
        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(terminalTab("Terminal 1"), timeout: 10),
            "Terminal should be created"
        )

        // Status bar toggle should still exist
        XCTAssertTrue(
            terminalToggle.exists,
            "Terminal toggle should remain in status bar when terminal pane is open"
        )
    }

    /// Terminal pane persists after interacting with the editor area.
    func testTerminalPersistsAfterEditorInteraction() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        let tab1 = terminalTab("Terminal 1")
        XCTAssertTrue(
            waitForExistence(tab1, timeout: 10),
            "Terminal 1 should appear"
        )

        // Click on the editor placeholder (or editor area) to move focus away
        let placeholder = editorPlaceholder
        if placeholder.exists && placeholder.isHittable {
            placeholder.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Terminal should still exist
        XCTAssertTrue(
            tab1.exists,
            "Terminal 1 should persist after clicking in editor area"
        )

        // Pane divider should still exist
        let divider = app.descendants(matching: .any)["paneDivider"].firstMatch
        XCTAssertTrue(
            divider.exists,
            "Pane divider should persist after editor interaction"
        )
    }

    /// Creating multiple terminal tabs via plus button works incrementally.
    func testMultipleTabsViaNewButton() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Terminal should appear"
        )

        // Add tab 2 and tab 3 via plus button
        newTerminalButton.click()
        let tab2 = terminalTab("Terminal 2")
        XCTAssertTrue(
            waitForExistence(tab2, timeout: 5),
            "Terminal 2 should appear"
        )

        newTerminalButton.click()
        let tab3 = terminalTab("Terminal 3")
        XCTAssertTrue(
            waitForExistence(tab3, timeout: 5),
            "Terminal 3 should appear"
        )

        // All three tabs should coexist
        XCTAssertTrue(terminalTab("Terminal 1").exists, "Terminal 1 should exist")
        XCTAssertTrue(tab2.exists, "Terminal 2 should exist")
        XCTAssertTrue(tab3.exists, "Terminal 3 should exist")
    }

    /// Terminal toggle in status bar can show and hide the terminal pane.
    func testTerminalToggleViaStatusBarButton() throws {
        launchAndWaitForLoad()

        // Click toggle to show terminal
        terminalToggle.click()

        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 10),
            "Terminal should become visible after toggle click"
        )

        // Click toggle again to hide
        terminalToggle.click()

        let deadline = Date().addingTimeInterval(5)
        while newTerminalButton.isHittable && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(
            newTerminalButton.isHittable,
            "Terminal should be hidden after toggling off"
        )
    }

    /// Maximize then hide should cleanly remove the terminal pane.
    func testMaximizeThenHide() throws {
        launchAndWaitForLoad()

        createTerminalViaMenu()
        XCTAssertTrue(
            waitForExistence(maximizeButton, timeout: 10),
            "Maximize button should be visible"
        )

        // Maximize
        maximizeButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Hide while maximized
        hideButton.click()

        // Terminal should be fully gone
        let tab1 = terminalTab("Terminal 1")
        let deadline = Date().addingTimeInterval(5)
        while tab1.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(tab1.exists, "Terminal should be removed after hide while maximized")

        // Editor should be back
        let placeholderOrEditor = editorPlaceholder.exists || editorTabBar.exists
        // Give editor a moment to appear
        if !placeholderOrEditor {
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(
            editorPlaceholder.exists || editorTabBar.exists,
            "Editor area should be restored after hiding maximized terminal"
        )
    }
}
