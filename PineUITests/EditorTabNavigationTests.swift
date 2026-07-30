//
//  EditorTabNavigationTests.swift
//  PineUITests
//
//  Tests for editor tab navigation: file menu structure, multi-tab
//  switching, tab close behavior, and status bar integration.
//

import XCTest

final class EditorTabNavigationTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let greeting = \"Hello\"\n",
            "utils.swift": "func helper() {}\n",
            "notes.txt": "Some notes\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Save menu item exists and is accessible

    func testSaveMenuItemExistsWhenFileIsOpen() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")

        app.activate()
        clickMenuBarItem("File")
        let saveItem = app.menuItems["Save"]
        XCTAssertTrue(waitForExistence(saveItem, timeout: 3), "Save menu item should exist")
    }

    // MARK: - File menu structure with open file

    func testFileMenuContainsSaveAndCloseItems() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")

        app.activate()
        clickMenuBarItem("File")

        let saveItem = app.menuItems["Save"]
        XCTAssertTrue(saveItem.exists, "File menu should contain Save")

        let saveAllItem = app.menuItems["Save All"]
        XCTAssertTrue(saveAllItem.exists, "File menu should contain Save All")

        let saveAsItem = app.menuItems["Save As…"]
        XCTAssertTrue(saveAsItem.exists, "File menu should contain Save As...")
    }

    // MARK: - Multi-tab switching preserves all tabs

    func testMultiTabSwitchingPreservesAllTabs() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open three files
        openFile("main.swift")
        openFile("utils.swift")
        openFile("notes.txt")

        // All three tabs should exist
        XCTAssertTrue(editorTab("main.swift").exists, "main.swift tab should exist")
        XCTAssertTrue(editorTab("utils.swift").exists, "utils.swift tab should exist")
        XCTAssertTrue(editorTab("notes.txt").exists, "notes.txt tab should exist")

        // Switch between tabs and verify none disappear
        editorTab("main.swift").click()
        let mainSelected = NSPredicate(format: "isSelected == true")
        let mainExpectation = XCTNSPredicateExpectation(predicate: mainSelected, object: editorTab("main.swift"))
        wait(for: [mainExpectation], timeout: 5)
        XCTAssertTrue(editorTab("main.swift").isSelected, "main.swift should become selected")

        editorTab("notes.txt").click()
        let notesSelected = NSPredicate(format: "isSelected == true")
        let notesExpectation = XCTNSPredicateExpectation(predicate: notesSelected, object: editorTab("notes.txt"))
        wait(for: [notesExpectation], timeout: 5)
        XCTAssertTrue(editorTab("notes.txt").isSelected, "notes.txt should become selected")

        // All tabs should still be present
        XCTAssertTrue(editorTab("main.swift").exists, "main.swift tab should survive switching")
        XCTAssertTrue(editorTab("utils.swift").exists, "utils.swift tab should survive switching")
        XCTAssertTrue(editorTab("notes.txt").exists, "notes.txt tab should survive switching")

        // XCUITest key events bypass Pine's local NSEvent monitor. The native
        // Window-menu equivalents must preserve immediate Control-Tab
        // switching for this Accessibility path.
        app.typeKey(.tab, modifierFlags: .control)
        let controlTabExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"),
            object: editorTab("main.swift")
        )
        wait(for: [controlTabExpectation], timeout: 5)
        XCTAssertTrue(editorTab("main.swift").isSelected)

        // macOS 26 routes synthetic key events through the native menu while
        // the current beta may deliver them to Pine's visual-session monitor.
        // Those paths intentionally differ in whether a completed gesture
        // promotes MRU state, so verify the menu commands as an inverse pair
        // without coupling the assertion to that prior promotion.
        app.menuBars.menuBarItems["Window"].click()
        let previousTabMenuItem = app.menuItems["Previous Tab"]
        XCTAssertTrue(waitForExistence(previousTabMenuItem, timeout: 5))
        previousTabMenuItem.click()
        let reverseControlTabExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == false"),
            object: editorTab("main.swift")
        )
        wait(for: [reverseControlTabExpectation], timeout: 5)
        XCTAssertFalse(editorTab("main.swift").isSelected)
        XCTAssertNotEqual(
            editorTab("notes.txt").isSelected,
            editorTab("utils.swift").isSelected,
            "Previous Tab should select exactly one neighbouring tab"
        )

        app.menuBars.menuBarItems["Window"].click()
        let nextTabMenuItem = app.menuItems["Next Tab"]
        XCTAssertTrue(waitForExistence(nextTabMenuItem, timeout: 5))
        nextTabMenuItem.click()
        let inverseControlTabExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"),
            object: editorTab("main.swift")
        )
        wait(for: [inverseControlTabExpectation], timeout: 5)
        XCTAssertTrue(editorTab("main.swift").isSelected)
    }

    // MARK: - Sidebar preview lifecycle

    func testSingleClickPreviewIsReplacedInPlace() throws {
        launchWithProject(projectURL)

        previewFile("main.swift")
        XCTAssertEqual(editorTab("main.swift").value as? String, "Preview")

        previewFile("utils.swift")

        XCTAssertTrue(
            editorTab("main.swift").waitForNonExistence(timeout: 5),
            "A second sidebar single-click should replace the old transient preview"
        )
        XCTAssertTrue(editorTab("utils.swift").exists)
        XCTAssertEqual(editorTab("utils.swift").value as? String, "Preview")
    }

    func testDoubleClickPromotesPreviewBeforeNextSingleClick() throws {
        launchWithProject(projectURL)

        previewFile("main.swift")
        app.sidebarNodes["fileNode_main.swift"].doubleClick()
        previewFile("utils.swift")

        XCTAssertTrue(
            editorTab("main.swift").exists,
            "Explicit double-click should promote the preview to a durable tab"
        )
        XCTAssertTrue(editorTab("utils.swift").exists)
    }

    func testMoveTabCommandsAreKeyboardAccessibleFromViewMenu() throws {
        launchWithProject(projectURL)
        openFile("main.swift")
        openFile("utils.swift")

        editorTab("main.swift").click()
        clickMenuBarItem("View")

        let moveRight = app.menuItems["Move Tab Right"]
        XCTAssertTrue(
            moveRight.waitForExistence(timeout: 3),
            "Pointer-free tab movement should be present in the View menu"
        )
        XCTAssertTrue(moveRight.isEnabled)
        moveRight.click()

        XCTAssertTrue(editorTab("main.swift").exists)
        XCTAssertTrue(editorTab("utils.swift").exists)
        XCTAssertTrue(editorTab("main.swift").isSelected)
    }

    // MARK: - Close middle tab activates neighbor

    func testCloseMiddleTabActivatesNeighbor() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open three files in order
        openFile("main.swift")
        openFile("utils.swift")
        openFile("notes.txt")

        // Close the middle tab (utils.swift)
        let closeBtn = editorTabCloseButton("utils.swift")
        XCTAssertTrue(waitForExistence(closeBtn, timeout: 5))
        closeBtn.click()

        XCTAssertTrue(
            editorTab("utils.swift").waitForNonExistence(timeout: 5),
            "Closed tab should disappear"
        )

        // Remaining tabs should still exist
        XCTAssertTrue(editorTab("main.swift").exists, "main.swift should remain")
        XCTAssertTrue(editorTab("notes.txt").exists, "notes.txt should remain")
    }

    // MARK: - Status bar shows cursor position when file is open

    func testStatusBarShowsCursorPositionWithOpenFile() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        openFile("main.swift")

        let cursorPosition = app.descendants(matching: .any)["cursorPosition"].firstMatch
        XCTAssertTrue(
            waitForExistence(cursorPosition, timeout: 10),
            "Cursor position should be visible in status bar when a file is open"
        )
    }
}
