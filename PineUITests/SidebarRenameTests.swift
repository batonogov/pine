//
//  SidebarRenameTests.swift
//  PineUITests
//
//  End-to-end tests for Finder-style Enter-to-rename in the sidebar (#737).
//

import XCTest

final class SidebarRenameTests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(
            files: [
                "hello.swift": "// Hello\n",
                "notes.txt": "Notes\n",
                "docs/readme.txt": "Docs\n"
            ]
        )
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Happy path: Enter starts rename, Enter commits

    func testEnterOnSelectedFileStartsAndCommitsRename() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileNode = app.staticTexts["fileNode_hello.swift"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5))
        fileNode.click() // Select in sidebar

        // Enter triggers inline rename
        app.typeKey(.return, modifierFlags: [])

        // Type a new stem (extension is preserved by stem-selection)
        // We type the full new name to be robust whether stem-selection landed.
        app.typeKey("a", modifierFlags: [.command]) // Select all in field editor
        app.typeText("renamed.swift")
        app.typeKey(.return, modifierFlags: [])

        // Wait for refresh
        sleep(2)

        let renamedPath = projectURL.appendingPathComponent("renamed.swift").path
        let oldPath = projectURL.appendingPathComponent("hello.swift").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: renamedPath),
            "Renamed file should exist on disk"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldPath),
            "Old file should no longer exist"
        )
    }

    // MARK: - Esc cancels rename

    func testEscapeCancelsRename() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let fileNode = app.staticTexts["fileNode_notes.txt"]
        XCTAssertTrue(waitForExistence(fileNode, timeout: 5))
        fileNode.click()

        app.typeKey(.return, modifierFlags: [])
        app.typeKey("a", modifierFlags: [.command])
        app.typeText("should-not-apply.txt")
        app.typeKey(.escape, modifierFlags: [])

        sleep(1)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("notes.txt").path),
            "Original file should still exist after Escape"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("should-not-apply.txt").path),
            "Cancelled name should not be written"
        )
    }

    // MARK: - Folder rename

    func testEnterRenamesFolder() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let dirNode = app.staticTexts["fileNode_docs"]
        XCTAssertTrue(waitForExistence(dirNode, timeout: 5))
        dirNode.click()

        app.typeKey(.return, modifierFlags: [])
        app.typeKey("a", modifierFlags: [.command])
        app.typeText("documents")
        app.typeKey(.return, modifierFlags: [])

        sleep(2)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("documents").path),
            "Renamed folder should exist on disk"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent("documents/readme.txt").path
            ),
            "Nested file should be moved with the folder"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("docs").path),
            "Old folder name should be gone"
        )
    }

    // MARK: - Negative: Enter with no selection is a no-op

    func testEnterWithNothingSelectedIsNoOp() throws {
        launchWithProject(projectURL)

        let sidebar = app.outlines["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // Click sidebar header area then Enter — should not crash, no rename starts.
        sidebar.click()
        app.typeKey(.escape, modifierFlags: []) // Clear any selection
        app.typeKey(.return, modifierFlags: [])

        // App should still be responsive — verify sidebar is still present.
        XCTAssertTrue(sidebar.exists, "Sidebar should still exist after Enter with no selection")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("hello.swift").path),
            "No file should be modified"
        )
    }
}
