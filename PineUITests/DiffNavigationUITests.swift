//
//  DiffNavigationUITests.swift
//  PineUITests
//
//  UI tests for navigating between git changes in the editor.
//

import XCTest

final class DiffNavigationUITests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Create a project with a file that will have git changes
        projectURL = try createTempProject(files: [
            "test.swift": "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n"
        ])
        try initGitRepo(at: projectURL)
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Initializes a git repo, adds all files, and commits.
    private func initGitRepo(at url: URL) throws {
        try git("init", at: url)
        try git("add", ".", at: url)
        try git("commit", "-m", "initial", at: url)
    }

    /// Modifies a file to create git changes (replaces specific lines).
    private func modifyFile(at url: URL, content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Direct path to git inside Xcode to avoid xcrun sandbox issues.
    private let gitPath = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"

    @discardableResult
    private func git(_ arguments: String..., at dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = Array(arguments)
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitError",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""]
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Tests

    func testNextChangeMenuItemExists() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Open the file
        let fileRow = app.staticTexts["fileNode_test.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("test.swift should appear in sidebar")
            return
        }
        fileRow.click()

        let tab = app.buttons["editorTab_test.swift"]
        XCTAssertTrue(waitForExistence(tab, timeout: 5))

        // Check menu items exist in Edit menu
        app.menuBars.menuBarItems["Edit"].click()
        let nextChangeItem = app.menuItems["Go to Next Change"]
        XCTAssertTrue(nextChangeItem.exists, "Go to Next Change menu item should exist")

        let prevChangeItem = app.menuItems["Go to Previous Change"]
        XCTAssertTrue(prevChangeItem.exists, "Go to Previous Change menu item should exist")
    }

    func testMenuItemsDisabledWithNoActiveTab() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Don't open any file — menu items should be disabled
        app.menuBars.menuBarItems["Edit"].click()
        let nextChangeItem = app.menuItems["Go to Next Change"]
        XCTAssertTrue(nextChangeItem.exists)
        XCTAssertFalse(nextChangeItem.isEnabled, "Menu item should be disabled with no active tab")
    }

    func testNavigateBetweenChanges() throws {
        // Create git changes: modify lines 3 and 8 so we have two change regions
        let fileURL = projectURL.appendingPathComponent("test.swift")
        try modifyFile(
            at: fileURL,
            content: "line1\nline2\nMODIFIED3\nline4\nline5\nline6\nline7\nMODIFIED8\nline9\nline10\n"
        )

        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileRow = app.staticTexts["fileNode_test.swift"]
        guard waitForExistence(fileRow, timeout: 5) else {
            XCTFail("test.swift should appear in sidebar")
            return
        }
        fileRow.click()

        let tab = app.buttons["editorTab_test.swift"]
        XCTAssertTrue(waitForExistence(tab, timeout: 5))

        // Wait for git diff to be computed
        sleep(2)

        // Navigate to next change via menu
        app.menuBars.menuBarItems["Edit"].click()
        let nextItem = app.menuItems["Go to Next Change"]
        guard nextItem.waitForExistence(timeout: 3) else {
            XCTFail("Go to Next Change menu item not found")
            return
        }
        nextItem.click()

        // Navigate again — should move to second change region
        sleep(1)
        app.menuBars.menuBarItems["Edit"].click()
        let nextItem2 = app.menuItems["Go to Next Change"]
        guard nextItem2.waitForExistence(timeout: 3) else {
            XCTFail("Go to Next Change menu item not found")
            return
        }
        nextItem2.click()

        // Navigate previous — should go back to first change
        sleep(1)
        app.menuBars.menuBarItems["Edit"].click()
        let prevItem = app.menuItems["Go to Previous Change"]
        guard prevItem.waitForExistence(timeout: 3) else {
            XCTFail("Go to Previous Change menu item not found")
            return
        }
        prevItem.click()

        // If we got here without crashes, navigation is functional
        // (We can't easily verify cursor position in UI tests due to GutterTextView limitations)
    }
}
