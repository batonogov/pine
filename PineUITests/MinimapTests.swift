//
//  MinimapTests.swift
//  PineUITests
//
//  UI tests for the minimap panel.
//

import XCTest

final class MinimapTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Create a file with enough content to make the minimap useful
        let lines = (1...50).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        projectURL = try createTempProject(files: [
            "main.swift": lines
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// The minimap element (accessibility role = .group).
    private var minimap: XCUIElement {
        app.groups["minimap"]
    }

    /// Toggles minimap visibility using Cmd+Shift+M keyboard shortcut.
    /// This works because Toggle Minimap is a SwiftUI .keyboardShortcut,
    /// not a local event monitor (which XCUITest's typeKey bypasses).
    private func toggleMinimap() {
        app.typeKey("m", modifierFlags: [.command, .shift])
    }

    // MARK: - Minimap visibility

    func testMinimapVisibleByDefault() throws {
        launchWithProject(projectURL)

        // Open a file to show the editor
        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 10) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        // Minimap should be visible by default
        XCTAssertTrue(
            waitForExistence(minimap, timeout: 5),
            "Minimap should be visible by default when a file is open"
        )
    }

    func testToggleMinimapViaMenu() throws {
        launchWithProject(projectURL)

        // Open a file
        let fileRow = app.staticTexts["fileNode_main.swift"]
        guard waitForExistence(fileRow, timeout: 10) else {
            XCTFail("main.swift should appear in the sidebar")
            return
        }
        fileRow.click()

        XCTAssertTrue(waitForExistence(minimap, timeout: 5), "Minimap should appear")

        // Toggle minimap off
        toggleMinimap()

        // Wait for minimap to disappear (NSView.isHidden removes from accessibility tree)
        let disappeared = minimap.waitForNonExistence(timeout: 3)
        XCTAssertTrue(disappeared, "Minimap should be hidden after toggle off")

        // Toggle minimap back on
        toggleMinimap()

        // Minimap should reappear
        XCTAssertTrue(
            waitForExistence(minimap, timeout: 3),
            "Minimap should reappear after toggle on"
        )
    }
}
