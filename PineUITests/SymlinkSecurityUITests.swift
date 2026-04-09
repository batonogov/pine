//
//  SymlinkSecurityUITests.swift
//  PineUITests
//
//  UI tests verifying symlink security: outside-root symlinks are not
//  expanded, cycles don't crash, and file operations are blocked.
//

import XCTest

final class SymlinkSecurityUITests: PineUITestCase {

    private var projectURL: URL!
    private var outsideDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Create the outside directory with a secret file
        outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try "secret".write(
            to: outsideDir.appendingPathComponent("secret.txt"),
            atomically: true, encoding: .utf8
        )

        // Create the project with a normal file + symlinks
        projectURL = try createTempProject(files: [
            "normal.swift": "// normal\n"
        ])

        // Symlink pointing outside the project root
        try FileManager.default.createSymbolicLink(
            at: projectURL.appendingPathComponent("external"),
            withDestinationURL: outsideDir
        )

        // Self-referencing symlink cycle: loop -> .
        try FileManager.default.createSymbolicLink(
            atPath: projectURL.appendingPathComponent("loop").path,
            withDestinationPath: "."
        )
    }

    override func tearDownWithError() throws {
        if let url = projectURL { cleanupProject(url) }
        if let url = outsideDir { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Symlink visibility

    func testSymlinkOutsideRootVisibleButNotExpanded() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // The symlink node should appear in the sidebar
        let externalNode = app.staticTexts["fileNode_external"]
        XCTAssertTrue(
            waitForExistence(externalNode, timeout: 5),
            "Symlink 'external' should be visible in the sidebar"
        )

        // The secret file inside the symlink target should NOT appear
        let secretNode = app.staticTexts["fileNode_secret.txt"]
        XCTAssertFalse(
            secretNode.waitForExistence(timeout: 2),
            "Files inside outside-root symlink should not be visible"
        )
    }

    // MARK: - Cycle does not crash

    func testSymlinkCycleDoesNotCrashApp() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // The cycle symlink should appear
        let loopNode = app.staticTexts["fileNode_loop"]
        XCTAssertTrue(
            waitForExistence(loopNode, timeout: 5),
            "Symlink 'loop' should be visible in the sidebar"
        )

        // The normal file should also be visible (app didn't hang loading the tree)
        let normalNode = app.staticTexts["fileNode_normal.swift"]
        XCTAssertTrue(
            waitForExistence(normalNode, timeout: 5),
            "Normal file should be visible — app did not hang on cycle"
        )
    }

    // MARK: - File operations blocked on outside-root symlink

    func testDeleteOnOutsideSymlinkIsBlocked() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let externalNode = app.staticTexts["fileNode_external"]
        XCTAssertTrue(waitForExistence(externalNode, timeout: 5))

        // Right-click to open context menu and select Delete (use SF Symbol to avoid
        // ambiguity with Edit > Delete menu item)
        externalNode.rightClick()
        let deleteItem = app.menuItems["trash"]
        XCTAssertTrue(waitForExistence(deleteItem, timeout: 3))
        deleteItem.click()

        // Wait for potential error alert
        sleep(2)

        // The outside directory should still exist (not deleted)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideDir.path),
            "Outside directory must not be deleted via symlink"
        )
    }

    func testNewFileInsideOutsideSymlinkIsBlocked() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        // The outside symlink is a directory node — its context menu should have New File
        let externalNode = app.staticTexts["fileNode_external"]
        XCTAssertTrue(waitForExistence(externalNode, timeout: 5))

        externalNode.rightClick()
        let newFileItem = app.menuItems["doc.badge.plus"]
        XCTAssertTrue(waitForExistence(newFileItem, timeout: 3))
        newFileItem.click()

        // Wait for potential error alert
        sleep(2)

        // No file should have been created inside the outside directory
        let contents = try? FileManager.default.contentsOfDirectory(atPath: outsideDir.path)
        XCTAssertEqual(
            contents?.count, 1,
            "No new file should be created inside outside-root symlink target (only secret.txt)"
        )
    }

    func testRenameOnOutsideSymlinkIsBlocked() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let externalNode = app.staticTexts["fileNode_external"]
        XCTAssertTrue(waitForExistence(externalNode, timeout: 5))

        // Right-click and select Rename
        externalNode.rightClick()
        let renameItem = app.menuItems["pencil"]
        XCTAssertTrue(waitForExistence(renameItem, timeout: 3))
        renameItem.click()

        // Type a new name and press Enter
        app.typeText("renamed\r")
        sleep(2)

        // The outside directory should still exist under its original name
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideDir.path),
            "Outside directory must not be renamed via symlink"
        )
    }

    func testDuplicateOnOutsideSymlinkIsBlocked() throws {
        launchWithProject(projectURL)

        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(waitForExistence(sidebar, timeout: 10))

        let externalNode = app.staticTexts["fileNode_external"]
        XCTAssertTrue(waitForExistence(externalNode, timeout: 5))

        // Right-click to open context menu and select Duplicate (use SF Symbol to avoid
        // ambiguity with File > Duplicate menu item)
        externalNode.rightClick()
        let duplicateItem = app.menuItems["plus.square.on.square"]
        XCTAssertTrue(waitForExistence(duplicateItem, timeout: 3))
        duplicateItem.click()

        // Wait for potential error alert
        sleep(2)

        // No copy should have been created
        let copyPath = projectURL.appendingPathComponent("external copy").path
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: copyPath),
            "Duplicate of outside-root symlink should be blocked"
        )
    }
}
