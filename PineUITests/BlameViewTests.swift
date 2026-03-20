//
//  BlameViewTests.swift
//  PineUITests
//

import XCTest

final class BlameViewTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let x = 1\nlet y = 2\n"
        ])
        // Initialize git repo and create a commit so blame has data
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = projectURL
        process.arguments = ["init"]
        process.environment = ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]
        try process.run()
        process.waitUntilExit()

        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        addProcess.currentDirectoryURL = projectURL
        addProcess.arguments = ["add", "."]
        addProcess.environment = ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]
        try addProcess.run()
        addProcess.waitUntilExit()

        let commitProcess = Process()
        commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commitProcess.currentDirectoryURL = projectURL
        commitProcess.arguments = [
            "-c", "user.name=Test", "-c", "user.email=test@test.com",
            "commit", "-m", "Initial commit"
        ]
        commitProcess.environment = ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]
        try commitProcess.run()
        commitProcess.waitUntilExit()
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Toggle blame via View menu

    func testToggleBlameViaMenu() throws {
        launchWithProject(projectURL)

        // Open file to get editor visible
        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 10) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        // Wait for editor to appear
        let editor = app.textViews["codeEditor"]
        guard waitForExistence(editor, timeout: 5) else {
            XCTFail("Code editor should appear")
            return
        }

        // Toggle blame ON via View menu
        app.menuBars.menuBarItems["View"].click()
        let toggleItem = app.menuItems["Toggle Git Blame"]
        guard waitForExistence(toggleItem, timeout: 3) else {
            XCTFail("Toggle Git Blame menu item should exist")
            return
        }
        toggleItem.click()

        // Toggle blame OFF via View menu
        app.menuBars.menuBarItems["View"].click()
        let toggleItemOff = app.menuItems["Toggle Git Blame"]
        guard waitForExistence(toggleItemOff, timeout: 3) else {
            XCTFail("Toggle Git Blame menu item should still exist")
            return
        }
        toggleItemOff.click()

        // Verify the editor is still functional after toggling
        XCTAssertTrue(editor.exists, "Editor should still be visible after blame toggle")
    }
}
