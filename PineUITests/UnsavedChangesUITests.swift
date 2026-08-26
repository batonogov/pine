//
//  UnsavedChangesUITests.swift
//  PineUITests
//
//  End-to-end coverage for dirty untitled close decisions.
//

import AppKit
import XCTest

final class UnsavedChangesUITests: PineUITestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(
            projectName: "Unsaved Changes Project"
        )
        NSPasteboard.general.clearContents()
    }

    override func tearDownWithError() throws {
        NSPasteboard.general.clearContents()
        if let projectURL {
            cleanupProject(projectURL)
        }
        try super.tearDownWithError()
    }

    func testCancelKeepsDirtyUntitledTabOpen() throws {
        launchWithProject(projectURL)
        let tab = try createDirtyUntitledTab()

        let alert = closeActiveTab()
        alert.buttons["Cancel"].firstMatch.click()

        XCTAssertTrue(
            alert.waitForNonExistence(timeout: 5),
            "Cancel should dismiss the unsaved-changes alert"
        )
        XCTAssertTrue(
            tab.exists,
            "Cancel should keep the dirty untitled tab open"
        )
    }

    func testDontSaveClosesDirtyUntitledTab() throws {
        launchWithProject(projectURL)
        let tab = try createDirtyUntitledTab()

        let alert = closeActiveTab()
        alert.buttons["Don't Save"].firstMatch.click()

        XCTAssertTrue(
            tab.waitForNonExistence(timeout: 5),
            "Don't Save should discard and close the untitled tab"
        )
        XCTAssertTrue(
            app.scrollViews["sidebar"].exists,
            "Discarding a tab should leave its project window open"
        )
    }

    func testSaveOpensDestinationPanelAndCancelKeepsDirtyTab() throws {
        launchWithProject(projectURL)
        let tab = try createDirtyUntitledTab()

        let alert = closeActiveTab()
        let question = unsavedChangesQuestion(in: alert, fileName: "Untitled")
        alert.buttons["Save"].firstMatch.click()
        XCTAssertTrue(
            question.waitForNonExistence(timeout: 5),
            "Save should advance beyond the unsaved-changes alert"
        )

        let savePanel = app.sheets.firstMatch
        XCTAssertTrue(
            savePanel.waitForExistence(timeout: 5),
            "Saving an untitled tab should request a destination"
        )
        XCTAssertTrue(
            savePanel.buttons["Save"].firstMatch.exists,
            "The destination panel should expose its Save action"
        )

        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(
            savePanel.waitForNonExistence(timeout: 5),
            "Cancelling Save As should dismiss the destination panel"
        )
        XCTAssertTrue(
            tab.exists,
            "Cancelling Save As should keep the dirty tab open"
        )
    }

    private func createDirtyUntitledTab() throws -> XCUIElement {
        XCTAssertTrue(
            app.scrollViews["sidebar"].waitForExistence(timeout: 10),
            "The project window should be ready"
        )
        clickMenuBarItem("File")
        app.menuItems["New File"].firstMatch.click()

        let tab = editorTab("Untitled")
        XCTAssertTrue(
            tab.waitForExistence(timeout: 5),
            "New File should create an untitled tab"
        )

        let editor = app.textViews["codeEditor"].firstMatch
        XCTAssertTrue(
            editor.waitForExistence(timeout: 5),
            "The untitled buffer should expose the code editor"
        )
        editor.click()

        XCTAssertTrue(
            NSPasteboard.general.setString(
                "unsaved UI test content\n",
                forType: .string
            ),
            "The test should seed the shared pasteboard"
        )
        clickMenuBarItem("Edit")
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(
            paste.waitForExistence(timeout: 5),
            "Edit should expose Paste"
        )
        XCTAssertTrue(
            paste.isEnabled,
            "Paste should target the focused code editor"
        )
        paste.click()

        return tab
    }

    private func closeActiveTab() -> XCUIElement {
        clickMenuBarItem("File")
        let closeTab = app.menuItems["Close Tab"].firstMatch
        XCTAssertTrue(closeTab.isEnabled)
        closeTab.click()

        let alert = app.sheets.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: 5),
            "Closing a dirty untitled tab should show an owned alert"
        )
        XCTAssertTrue(
            unsavedChangesQuestion(in: alert, fileName: "Untitled").exists,
            "The close decision should name the file it is about to discard"
        )
        return alert
    }
}
