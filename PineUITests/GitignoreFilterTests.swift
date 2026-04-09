//
//  GitignoreFilterTests.swift
//  PineUITests
//
//  UI tests verifying that gitignored directories appear dimmed in the sidebar
//  (visible and expandable via shallow-loading) while gitignored files also remain visible.
//

import XCTest

final class GitignoreFilterTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Create a git repo with .gitignore, a normal file,
        // a gitignored directory, and a gitignored file.
        projectURL = try createTempProject(files: [
            "main.swift": "// Hello\n",
            ".gitignore": "node_modules/\n.env\n.claude/\n",
            "node_modules/express/index.js": "module.exports = {};\n",
            ".env": "SECRET=123\n",
            ".claude/settings.json": "{}\n"
        ])

        // Initialize git so gitProvider picks up .gitignore
        try git("init", at: projectURL)
        try git("config", "user.email", "test@test.com", at: projectURL)
        try git("config", "user.name", "Test", at: projectURL)
        try git("add", ".", at: projectURL)
        try git("commit", "-m", "init", at: projectURL)
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Path to git binary, bypassing the xcrun shim which fails in App Sandbox.
    private let gitPath = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"

    @discardableResult
    private func git(_ arguments: String..., at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = Array(arguments)
        process.currentDirectoryURL = directory
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

    func testGitignoredDirectoryVisibleInSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // main.swift should be visible
        let mainFile = app.staticTexts["fileNode_main.swift"]
        XCTAssertTrue(
            waitForExistence(mainFile, timeout: 5),
            "main.swift should appear in sidebar"
        )

        // node_modules directory should be visible (gitignored but shown dimmed)
        let nodeModules = app.staticTexts["fileNode_node_modules"]
        XCTAssertTrue(
            waitForExistence(nodeModules, timeout: 5),
            "node_modules should appear in sidebar (gitignored directories are visible but dimmed)"
        )
    }

    func testGitignoredDotDirectoryVisibleInSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // .claude directory should be visible (gitignored but shown dimmed)
        let claudeDir = app.staticTexts["fileNode_.claude"]
        XCTAssertTrue(
            waitForExistence(claudeDir, timeout: 5),
            ".claude should appear in sidebar (gitignored directories are visible but dimmed)"
        )
    }

    func testGitignoredFileRemainsInSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // .env should be visible (gitignored file, not directory)
        let envFile = app.staticTexts["fileNode_.env"]
        XCTAssertTrue(
            waitForExistence(envFile, timeout: 5),
            ".env should remain visible in sidebar (gitignored files are kept)"
        )
    }

    func testGitignoredDirectoryCanBeExpanded() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // node_modules should be visible
        let nodeModules = app.staticTexts["fileNode_node_modules"]
        XCTAssertTrue(
            waitForExistence(nodeModules, timeout: 5),
            "node_modules should appear in sidebar"
        )

        // Gitignored folders with children should have a disclosure triangle.
        // Try multiple expansion strategies — SwiftUI List on macOS 26 is finicky.
        expandFolder(nodeModules, in: sidebar)

        // Child directory "express" should appear after expanding
        let express = app.staticTexts["fileNode_express"]
        XCTAssertTrue(
            waitForExistence(express, timeout: 5),
            "express should appear inside expanded node_modules (gitignored dirs are expandable)"
        )
    }

    func testGitignoredDotDirectoryCanBeExpanded() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // .claude should be visible
        let claudeDir = app.staticTexts["fileNode_.claude"]
        XCTAssertTrue(
            waitForExistence(claudeDir, timeout: 5),
            ".claude should appear in sidebar"
        )

        expandFolder(claudeDir, in: sidebar)

        // Child file "settings.json" should appear after expanding
        let settingsFile = app.staticTexts["fileNode_settings.json"]
        XCTAssertTrue(
            waitForExistence(settingsFile, timeout: 5),
            "settings.json should appear inside expanded .claude (gitignored dirs are expandable)"
        )
    }

    /// Tries to expand a folder row in the sidebar.
    /// The new ScrollView-based sidebar uses a single-tap gesture on the
    /// row to toggle expansion (see `SidebarDisclosureGroupStyle`).
    private func expandFolder(_ row: XCUIElement, in sidebar: XCUIElement) {
        row.click()
        sleep(1)
    }

    func testNonIgnoredDirectoryRemainsInSidebar() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10), "Sidebar should appear")

        // .gitignore should be visible
        let gitignore = app.staticTexts["fileNode_.gitignore"]
        XCTAssertTrue(
            waitForExistence(gitignore, timeout: 5),
            ".gitignore should appear in sidebar"
        )
    }
}
