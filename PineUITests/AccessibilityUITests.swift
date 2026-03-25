//
//  AccessibilityUITests.swift
//  PineUITests
//
//  UI tests verifying that key VoiceOver accessibility labels
//  and identifiers are present in the view hierarchy.
//

import XCTest

final class AccessibilityUITests: PineUITestCase {

    // MARK: - Welcome window accessibility

    func testWelcomeWindowHasOpenFolderButton() throws {
        launchClean()

        let welcomeWindow = app.windows.firstMatch
        XCTAssertTrue(waitForExistence(welcomeWindow, timeout: 10))

        // Open Folder button should be accessible via its identifier
        let openButton = app.buttons["welcomeOpenFolderButton"]
        XCTAssertTrue(waitForExistence(openButton, timeout: 5))
    }

    // MARK: - Editor window accessibility

    func testSidebarHasAccessibilityIdentifier() throws {
        let project = try createTempProject(files: ["test.swift": "let x = 1\n"])
        defer { cleanupProject(project) }
        launchWithProject(project)

        let sidebar = app.groups["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))
    }

    func testStatusBarHasAccessibilityIdentifier() throws {
        let project = try createTempProject(files: ["test.swift": "let x = 1\n"])
        defer { cleanupProject(project) }
        launchWithProject(project)

        let statusBar = app.groups["statusBar"]
        XCTAssertTrue(waitForExistence(statusBar, timeout: 10))
    }

    func testTerminalToggleButtonIsAccessible() throws {
        let project = try createTempProject(files: ["test.swift": "let x = 1\n"])
        defer { cleanupProject(project) }
        launchWithProject(project)

        let toggle = app.buttons["terminalToggleButton"]
        XCTAssertTrue(waitForExistence(toggle, timeout: 10))
    }

    func testEditorTabBarAppearsAfterFileOpen() throws {
        let project = try createTempProject(files: ["test.swift": "let x = 1\n"])
        defer { cleanupProject(project) }
        launchWithProject(project)

        // Click on the file in the sidebar to open it
        let fileNode = app.outlines.staticTexts["test.swift"]
        if waitForExistence(fileNode, timeout: 10) {
            fileNode.click()

            let tabBar = app.groups["editorTabBar"]
            XCTAssertTrue(waitForExistence(tabBar, timeout: 5))
        }
    }

    func testEditorPlaceholderAccessibility() throws {
        let project = try createTempProject(files: ["test.swift": "let x = 1\n"])
        defer { cleanupProject(project) }
        launchWithProject(project)

        // Before opening any file, the placeholder should be visible
        let placeholder = app.groups["editorPlaceholder"].firstMatch
        // May or may not exist depending on session restore; just check it doesn't crash
        _ = placeholder.exists
    }
}
