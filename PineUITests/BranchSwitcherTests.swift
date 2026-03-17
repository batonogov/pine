//
//  BranchSwitcherTests.swift
//  PineUITests
//
//  Tests for branch switching UI.
//
//  Note: The branch subtitle is made clickable via an AppKit gesture
//  recognizer (BranchSubtitleClickHandler), which XCUITest cannot
//  interact with directly (window chrome is not an accessibility element).
//  Cmd+Shift+B is handled via NSEvent.addLocalMonitorForEvents, which
//  XCUITest's typeKey() bypasses. Therefore, these tests verify the
//  display of branch information and external branch switch detection.
//

import XCTest

final class BranchSwitcherTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createGitProject()
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Creates a temporary git project with three branches: main, test-branch, feature-xyz.
    private func createGitProject() throws -> URL {
        let dir = try createTempProject(files: [
            "main.swift": "// Hello\n"
        ])
        try git("init", at: dir)
        try git("config", "user.email", "test@test.com", at: dir)
        try git("config", "user.name", "Test", at: dir)
        try git("add", ".", at: dir)
        try git("commit", "-m", "initial", at: dir)
        try git("branch", "test-branch", at: dir)
        try git("branch", "feature-xyz", at: dir)
        return dir
    }

    /// Path to git binary, bypassing the xcrun shim which fails in App Sandbox.
    private let gitPath = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"

    /// Runs a git command in the given directory.
    /// Uses the direct git binary path to avoid xcrun sandbox issues.
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
                domain: "ShellError",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""]
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Title bar shows branch name

    func testTitleBarShowsBranchName() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let branchText = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'main'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(branchText, timeout: 10),
            "Title bar should display the current branch name"
        )
    }

    // MARK: - Subtitle contains clickable indicator

    func testSubtitleShowsBranchIndicator() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Subtitle should contain the branch indicator "▾"
        let indicator = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS '▾'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(indicator, timeout: 10),
            "Subtitle should contain ▾ indicator showing it is clickable"
        )
    }

    // MARK: - Git menu exists in menu bar

    func testGitMenuExists() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let gitMenu = app.menuBars.menuBarItems["Git"]
        XCTAssertTrue(gitMenu.exists, "Git menu should exist in the menu bar")
    }

    // MARK: - External branch switch updates subtitle

    func testExternalBranchSwitchUpdatesSubtitle() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Verify initial branch is main
        let mainText = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'main'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(mainText, timeout: 10),
            "Initial branch should be main"
        )

        // Switch branch externally via git
        try git("switch", "test-branch", at: projectURL)

        // The app polls git status periodically — subtitle should update
        let testBranchText = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'test-branch'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(testBranchText, timeout: 15),
            "Subtitle should update to show test-branch after external switch"
        )
    }
}
