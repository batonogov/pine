//
//  BranchSwitcherTests.swift
//  PineUITests
//
//  Tests for branch switching via title bar dropdown and Cmd+Shift+B sheet.
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

    /// Creates a temporary git project with two branches: main and test-branch.
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

    // MARK: - Title bar shows branch name

    func testTitleBarShowsBranchName() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // The navigation subtitle should contain the branch name.
        // On macOS the subtitle appears as a static text in the title bar.
        let branchText = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'main'")
        ).firstMatch
        XCTAssertTrue(
            waitForExistence(branchText, timeout: 10),
            "Title bar should display the current branch name"
        )
    }

    // MARK: - Cmd+Shift+B opens branch switcher sheet

    func testCmdShiftBOpensBranchSwitcherSheet() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sleep(2)

        // Press Cmd+Shift+B to open branch switcher
        app.typeKey("b", modifierFlags: [.command, .shift])
        sleep(1)

        // The search field should appear in the sheet
        let searchField = app.textFields["branchSearchField"]
        XCTAssertTrue(
            waitForExistence(searchField, timeout: 5),
            "Branch switcher sheet should appear with search field"
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

    // MARK: - Branch switcher sheet: search filters branches

    func testBranchSwitcherSearchFiltersBranches() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sleep(2)

        // Open branch switcher
        app.typeKey("b", modifierFlags: [.command, .shift])
        sleep(1)

        let searchField = app.textFields["branchSearchField"]
        XCTAssertTrue(waitForExistence(searchField, timeout: 5))

        // Type "test" to filter
        searchField.click()
        searchField.typeText("test")
        sleep(1)

        // test-branch should be visible, feature-xyz should not
        let testBranch = app.descendants(matching: .any)["branchItem_test-branch"].firstMatch
        let featureBranch = app.descendants(matching: .any)["branchItem_feature-xyz"].firstMatch
        XCTAssertTrue(testBranch.exists, "test-branch should match filter")
        XCTAssertFalse(featureBranch.exists, "feature-xyz should be filtered out")
    }

    // MARK: - Switch branch via sheet updates title

    func testSwitchBranchViaSheetUpdatesTitle() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        sleep(2)

        // Open branch switcher
        app.typeKey("b", modifierFlags: [.command, .shift])
        sleep(1)

        // Click on test-branch
        let testBranch = app.descendants(matching: .any)["branchItem_test-branch"].firstMatch
        XCTAssertTrue(waitForExistence(testBranch, timeout: 5))
        testBranch.click()
        sleep(2)

        // Sheet should dismiss and branch should change
        let searchField = app.textFields["branchSearchField"]
        XCTAssertTrue(
            searchField.waitForNonExistence(timeout: 5),
            "Sheet should dismiss after branch switch"
        )

        // Title bar should now show test-branch
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
