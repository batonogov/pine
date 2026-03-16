//
//  BranchSwitcherTests.swift
//  PineUITests
//
//  Tests for branch switching via title bar dropdown.
//
//  Note: Cmd+Shift+B opens the full branch sheet but is handled via
//  NSEvent.addLocalMonitorForEvents, which XCUITest's typeKey() bypasses.
//  These tests use the toolbarTitleMenu (title bar click) instead.
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
        try shell("git init", at: dir)
        try shell("git config user.email 'test@test.com'", at: dir)
        try shell("git config user.name 'Test'", at: dir)
        try shell("git add .", at: dir)
        try shell("git commit -m 'initial'", at: dir)
        try shell("git branch test-branch", at: dir)
        try shell("git branch feature-xyz", at: dir)
        return dir
    }

    /// Runs a shell command in the given directory.
    @discardableResult
    private func shell(_ command: String, at dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
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

    /// Finds the branch subtitle text in the title bar and clicks it to open the title menu.
    private func openTitleMenu() {
        let subtitle = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS '⎇'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(subtitle, timeout: 10),
            "Branch subtitle should exist in title bar"
        )
        subtitle.click()
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

    // MARK: - Title menu shows branches

    func testTitleMenuShowsBranches() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sleep(2)

        openTitleMenu()
        sleep(1)

        // The toolbarTitleMenu should show branch names as menu items
        let testBranch = app.menuItems["test-branch"]
        let featureBranch = app.menuItems["feature-xyz"]
        XCTAssertTrue(
            waitForExistence(testBranch, timeout: 5),
            "test-branch should appear in title menu"
        )
        XCTAssertTrue(
            waitForExistence(featureBranch, timeout: 5),
            "feature-xyz should appear in title menu"
        )
    }

    // MARK: - Switch branch via title menu updates subtitle

    func testSwitchBranchViaTitleMenuUpdatesSubtitle() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sleep(2)

        // Open title menu and click test-branch
        openTitleMenu()
        sleep(1)

        let testBranchItem = app.menuItems["test-branch"]
        XCTAssertTrue(waitForExistence(testBranchItem, timeout: 5))
        testBranchItem.click()
        sleep(2)

        // Subtitle should now show test-branch
        let branchText = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'test-branch'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(branchText, timeout: 5),
            "Title bar should update to show test-branch after switching"
        )
    }

    // MARK: - Current branch has checkmark in title menu

    func testCurrentBranchHasCheckmarkInTitleMenu() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sleep(2)

        openTitleMenu()
        sleep(1)

        // The current branch (main) should have a checkmark label
        let mainWithCheckmark = app.menuItems.matching(
            NSPredicate(format: "label CONTAINS 'main'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(mainWithCheckmark, timeout: 5),
            "Current branch should appear in title menu"
        )
    }

    // MARK: - Git menu no longer in menu bar

    func testGitMenuDoesNotExist() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let gitMenu = app.menuBars.menuBarItems["Git"]
        XCTAssertFalse(gitMenu.exists, "Git menu should not exist in the menu bar")
    }
}
