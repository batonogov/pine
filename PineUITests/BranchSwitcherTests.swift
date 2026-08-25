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
//  XCUITest's typeKey() bypasses. Therefore, these tests open the switcher
//  through the Git menu and verify the displayed branch information.
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

    // MARK: - Git menu opens branch switcher

    func testGitMenuOpensBranchSwitcher() throws {
        launchWithProject(projectURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let gitMenu = app.menuBars.menuBarItems["Git"]
        XCTAssertTrue(gitMenu.waitForExistence(timeout: 5), "Git menu should exist in the menu bar")
        gitMenu.click()

        let switchBranch = app.menuItems["Switch Branch…"]
        XCTAssertTrue(
            switchBranch.waitForExistence(timeout: 5),
            "Git menu should contain Switch Branch"
        )
        XCTAssertTrue(switchBranch.isEnabled, "Switch Branch should be enabled for git projects")
        switchBranch.click()

        let searchField = app.textFields["branchSearchField"]
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 5),
            "Switch Branch should open the branch switcher"
        )
    }

    // MARK: - Keyboard escape hatches (#1522)

    /// Opens the switcher through the Git menu (Cmd+Shift+B goes through a
    /// local event monitor that XCUITest's typeKey bypasses).
    private func openBranchSwitcher() {
        let gitMenu = app.menuBars.menuBarItems["Git"]
        XCTAssertTrue(gitMenu.waitForExistence(timeout: 5))
        gitMenu.click()
        let switchBranch = app.menuItems["Switch Branch…"]
        XCTAssertTrue(switchBranch.waitForExistence(timeout: 5))
        switchBranch.click()
        XCTAssertTrue(
            app.textFields["branchSearchField"].waitForExistence(timeout: 5),
            "Branch switcher should open"
        )
    }

    /// The branch the working tree is actually on, read from git itself.
    private func checkedOutBranch() throws -> String {
        try git("rev-parse", "--abbrev-ref", "HEAD", at: projectURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Identifiers of the rows currently carrying the selected trait.
    private func selectedBranchRows() -> [String] {
        ["main", "test-branch", "feature-xyz"].filter {
            app.buttons["branchItem_\($0)"].firstMatch.isSelected
        }
    }

    func testEscapeDismissesSwitcherWithoutSwitchingBranch() throws {
        launchWithProject(projectURL)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try checkedOutBranch(), "main")

        openBranchSwitcher()
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            app.textFields["branchSearchField"].waitForNonExistence(timeout: 5),
            "Escape should dismiss the branch switcher"
        )
        XCTAssertEqual(
            try checkedOutBranch(),
            "main",
            "Escape must never check out a branch"
        )
    }

    func testCancelButtonDismissesWithoutSwitchingBranch() throws {
        launchWithProject(projectURL)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try checkedOutBranch(), "main")

        openBranchSwitcher()
        let cancel = app.buttons["branchCancelButton"].firstMatch
        XCTAssertTrue(
            cancel.waitForExistence(timeout: 5),
            "The switcher must offer a visible Cancel button"
        )
        cancel.click()

        XCTAssertTrue(
            app.textFields["branchSearchField"].waitForNonExistence(timeout: 5),
            "Cancel should dismiss the branch switcher"
        )
        XCTAssertEqual(
            try checkedOutBranch(),
            "main",
            "Cancel must never check out a branch"
        )
    }

    func testArrowKeysMoveBranchSelection() throws {
        launchWithProject(projectURL)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        openBranchSwitcher()

        let initial = selectedBranchRows()
        XCTAssertEqual(
            initial.count,
            1,
            "Exactly one branch row should start selected"
        )

        // Being the checked-out branch must not read as the keyboard
        // selection: VoiceOver would otherwise announce two selected rows.
        let current = app.buttons["branchItem_main"].firstMatch
        XCTAssertEqual(
            current.value as? String,
            "Current branch",
            "The checked-out branch should expose itself as a value, not a trait"
        )

        app.typeKey(.downArrow, modifierFlags: [])
        let afterDown = selectedBranchRows()
        XCTAssertEqual(afterDown.count, 1, "Down should leave one row selected")
        XCTAssertNotEqual(
            afterDown,
            initial,
            "Down should move the selection to the next branch"
        )

        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertEqual(
            selectedBranchRows(),
            initial,
            "Up should move the selection back"
        )

        // Escape still cancels after the selection moved off the current branch.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            app.textFields["branchSearchField"].waitForNonExistence(timeout: 5)
        )
        XCTAssertEqual(try checkedOutBranch(), "main")
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
