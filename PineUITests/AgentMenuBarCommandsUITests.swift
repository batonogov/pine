//
//  AgentMenuBarCommandsUITests.swift
//  PineUITests
//
//  Issue #1525: starting an agent in a worktree, and moving between the
//  projects a window holds, lived at exactly one place in the UI — a submenu
//  inside the toolbar's project switcher. No menu-bar item, no Command
//  Palette entry, no shortcut. This test fails if either ever leaves the
//  menu bar again.
//

import XCTest

final class AgentMenuBarCommandsUITests: PineUITestCase {
    private var projectURL: URL!

    /// Titles that must be reachable from the menu bar, per menu.
    private static let viewMenuTitles = ["New Agent…"]
    private static let windowMenuTitles = [
        "Switch Project",
        "Next Project",
        "Previous Project",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject()
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Existence, not enablement: a CI runner with no agent CLI on `PATH` and
    /// a project that is not a git repository dims both commands, and the
    /// point of this test is that they are *there* to be dimmed.
    private func assertMenuItems(_ titles: [String], in menu: String) {
        clickMenuBarItem(menu)
        for title in titles {
            let item = app.menuItems[title].firstMatch
            XCTAssertTrue(
                waitForExistence(item, timeout: 3),
                "\(menu) ▸ \(title) should be reachable from the menu bar"
            )
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Tests

    func testAgentAndProjectCommandsExistInTheMenuBar() throws {
        launchWithProject(projectURL)

        assertMenuItems(Self.viewMenuTitles, in: "View")
        assertMenuItems(Self.windowMenuTitles, in: "Window")
    }
}
