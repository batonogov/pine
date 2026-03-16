//
//  BranchSwitcherTests.swift
//  PineUITests
//
//  Tests for branch switching via status bar button and popover.
//
//  Note: Cmd+Shift+B opens the full branch sheet but is handled via
//  NSEvent.addLocalMonitorForEvents, which XCUITest's typeKey() bypasses.
//  These tests use the status bar branch button instead.
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

    /// Finds and returns the branch switcher button in the status bar.
    private var branchButton: XCUIElement {
        app.descendants(matching: .any)["branchSwitcherButton"].firstMatch
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

    // MARK: - Branch button visible in status bar

    func testBranchButtonVisibleInStatusBar() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        XCTAssertTrue(
            waitForExistence(branchButton, timeout: 10),
            "Branch switcher button should be visible in status bar"
        )
    }

    // MARK: - Branch button opens popover with branches

    func testBranchButtonOpensPopoverWithBranches() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sleep(2)

        // Click branch button to open popover
        XCTAssertTrue(waitForExistence(branchButton, timeout: 10))
        branchButton.click()
        sleep(1)

        // Search field should appear in the popover
        let searchField = app.textFields["branchSearchField"]
        XCTAssertTrue(
            waitForExistence(searchField, timeout: 5),
            "Branch popover should show search field"
        )

        // Branch items should be visible
        let mainBranch = app.descendants(matching: .any)["branchItem_main"].firstMatch
        let testBranch = app.descendants(matching: .any)["branchItem_test-branch"].firstMatch
        XCTAssertTrue(
            waitForExistence(mainBranch, timeout: 5),
            "main branch should appear in branch list"
        )
        XCTAssertTrue(
            waitForExistence(testBranch, timeout: 5),
            "test-branch should appear in branch list"
        )
    }

    // MARK: - Search filters branches

    func testSearchFiltersBranches() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sleep(2)

        XCTAssertTrue(waitForExistence(branchButton, timeout: 10))
        branchButton.click()
        sleep(1)

        let searchField = app.textFields["branchSearchField"]
        XCTAssertTrue(waitForExistence(searchField, timeout: 5))

        // Type "test" to filter
        searchField.click()
        searchField.typeText("test")
        sleep(1)

        let testBranch = app.descendants(matching: .any)["branchItem_test-branch"].firstMatch
        let featureBranch = app.descendants(matching: .any)["branchItem_feature-xyz"].firstMatch
        XCTAssertTrue(testBranch.exists, "test-branch should match filter")
        XCTAssertFalse(featureBranch.exists, "feature-xyz should be filtered out")
    }

    // MARK: - Switch branch via popover updates UI

    func testSwitchBranchViaPopoverUpdatesUI() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sleep(2)

        XCTAssertTrue(waitForExistence(branchButton, timeout: 10))
        branchButton.click()
        sleep(1)

        // Click on test-branch
        let testBranch = app.descendants(matching: .any)["branchItem_test-branch"].firstMatch
        XCTAssertTrue(waitForExistence(testBranch, timeout: 5))
        testBranch.click()
        sleep(2)

        // Popover should dismiss
        let searchField = app.textFields["branchSearchField"]
        XCTAssertTrue(
            searchField.waitForNonExistence(timeout: 5),
            "Popover should dismiss after branch switch"
        )

        // Title bar subtitle should update
        let branchText = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'test-branch'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(branchText, timeout: 5),
            "Title bar should update to show test-branch"
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
