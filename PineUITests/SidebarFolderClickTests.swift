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

    private func waitForSelection(
        _ element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"),
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
            files: [
                "-flags": "flags\n",
                ".env": "KEY=value\n",
                "_config": "config\n",
                "Éclair.swift": "// Unicode\n",
                "😀notes.md": "# Emoji\n",
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

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let alphaFolder = app.sidebarNodes["fileNode_alpha"]
        XCTAssertTrue(waitForExistence(alphaFolder, timeout: 5))

        // Child should NOT be visible before expanding.
        let alphaChild = app.sidebarNodes["fileNode_inside-alpha.swift"]
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

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let emptyFolder = app.sidebarNodes["fileNode_empty-folder"]
        XCTAssertTrue(waitForExistence(emptyFolder, timeout: 5))

        // Click should not crash; folder is empty so no children appear,
        // but the app must remain responsive.
        emptyFolder.click()
        emptyFolder.click()

        // App still responsive — sidebar still there and we can find the root file.
        XCTAssertTrue(app.sidebarNodes["fileNode_root-file.swift"].exists)
    }

    // MARK: - Click on file row opens tab (does not toggle anything)

    func testClickFileRowOpensTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let rootFile = app.sidebarNodes["fileNode_root-file.swift"]
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

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let betaFolder = app.sidebarNodes["fileNode_beta"]
        XCTAssertTrue(waitForExistence(betaFolder, timeout: 5))

        // Folder is collapsed; child should be hidden.
        let betaChild = app.sidebarNodes["fileNode_inside-beta.txt"]
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

    // MARK: - Finder-style keyboard and VoiceOver matrix (#1238)

    func testKeyboardNavigationTypeSelectAndOutlineSemantics() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
        let alpha = app.sidebarNodes["fileNode_alpha"]
        let child = app.sidebarNodes["fileNode_inside-alpha.swift"]
        XCTAssertTrue(waitForExistence(alpha, timeout: 5))

        // Native row role, disclosure value, selection, Left/Right, and
        // parent navigation all travel through the shared transition model.
        XCTAssertEqual(alpha.elementType, .outlineRow)
        XCTAssertEqual(alpha.value as? String, "collapsed")
        alpha.click()
        XCTAssertTrue(child.waitForExistence(timeout: 3))
        XCTAssertTrue(alpha.isSelected)
        XCTAssertEqual(alpha.value as? String, "expanded")

        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(child.waitForNonExistence(timeout: 3))
        XCTAssertTrue(alpha.isSelected)

        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(child.waitForExistence(timeout: 3))
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(child.isSelected, "Right on an expanded folder enters its first child")
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(alpha.isSelected, "Left on a child returns to its parent")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(child.isSelected)
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(alpha.isSelected)

        // Home/End/Page remain handled by the sidebar and always leave one
        // row selected.
        app.typeKey(.end, modifierFlags: [])
        XCTAssertEqual(
            sidebar.descendants(matching: .outlineRow)
                .matching(NSPredicate(format: "isSelected == true")).count,
            1
        )
        app.typeKey(.home, modifierFlags: [])
        XCTAssertTrue(alpha.isSelected)
        app.typeKey(.pageDown, modifierFlags: [])
        XCTAssertEqual(
            sidebar.descendants(matching: .outlineRow)
                .matching(NSPredicate(format: "isSelected == true")).count,
            1
        )
        app.typeKey(.pageUp, modifierFlags: [])
        XCTAssertEqual(
            sidebar.descendants(matching: .outlineRow)
                .matching(NSPredicate(format: "isSelected == true")).count,
            1
        )

        // Type-select does not open a file. Command-Return does, then a
        // pointer click explicitly restores sidebar focus for the next matrix.
        app.typeText("r")
        let rootFile = app.sidebarNodes["fileNode_root-file.swift"]
        XCTAssertTrue(waitForSelection(rootFile))
        let rootTab = app.buttons["editorTab_root-file.swift"]
        XCTAssertFalse(rootTab.exists)
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(rootTab.waitForExistence(timeout: 5))
        rootFile.click()

        // Space opens a transient preview and preserves sidebar focus. The
        // following punctuation selection is therefore also a focus-transfer
        // assertion, not just a matching assertion.
        app.typeText("_")
        XCTAssertTrue(
            waitForSelection(app.sidebarNodes["fileNode__config"])
        )
        let configTab = app.buttons["editorTab__config"]
        XCTAssertFalse(configTab.exists)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(configTab.waitForExistence(timeout: 5))
        app.typeText(".")
        XCTAssertTrue(
            waitForSelection(app.sidebarNodes["fileNode_.env"])
        )

        rootFile.click()
        // The first "e" legitimately matches empty-folder. The second
        // character makes the prefix unambiguous and proves that "ec"
        // matches the diacritic filename "Éclair".
        app.typeText("ec")
        XCTAssertTrue(
            waitForSelection(app.sidebarNodes["fileNode_Éclair.swift"])
        )

        // Cancelling inline rename must restore the sidebar responder while
        // preserving the edited row's selection. Alpha is still expanded
        // from the earlier matrix; collapse it with the pointer, cancel
        // Return-to-rename, then prove Right still targets Alpha.
        alpha.click()
        XCTAssertTrue(child.waitForNonExistence(timeout: 3))
        app.typeKey(.return, modifierFlags: [])
        let renameField = app.textFields["inlineRenameTextField"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(renameField.waitForNonExistence(timeout: 3))
        XCTAssertTrue(alpha.isSelected)
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(
            child.waitForExistence(timeout: 3),
            "Right should expand the still-selected row after rename cancel"
        )
    }
}
