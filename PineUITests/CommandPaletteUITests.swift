//
//  CommandPaletteUITests.swift
//  PineUITests
//
//  UI tests for the Command Palette overlay.
//

import XCTest

final class CommandPaletteUITests: PineUITestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "func main() {}\n",
            "utils.swift": "// Utils\n",
            "readme.md": "# README\n"
        ])
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    func testCommandPaletteFieldIsAccessibleInCommandPanel() throws {
        launchWithProject(projectURL)

        clickMenuBarItem("File")
        let menuItem = app.menuItems["Command Palette…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.click()

        let overlay = commandOverlay("commandPaletteOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        let searchField = overlay
            .textFields["commandPaletteSearchField"]
            .firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 5),
            "Command Palette search field should be accessible"
        )
        searchField.click()

        let disabledSaveCommand = overlay
            .buttons["commandPaletteItem_command_save"]
            .firstMatch
        XCTAssertTrue(
            disabledSaveCommand.waitForExistence(timeout: 5),
            "Disabled Command Palette rows should remain discoverable"
        )
        XCTAssertFalse(
            disabledSaveCommand.isEnabled,
            "Save should be disabled when no file is active"
        )
        XCTAssertTrue(
            disabledSaveCommand.label.contains("Requires an active file."),
            "Disabled Command Palette rows should explain their requirement"
        )

        searchField.click()
        searchField.typeText("save all")
        XCTAssertEqual(
            searchField.value as? String,
            "save all",
            "Command Palette query should reach the native search field"
        )

        let saveAllCommand = overlay
            .buttons["commandPaletteItem_command_saveAll"]
            .firstMatch
        XCTAssertTrue(
            saveAllCommand.waitForExistence(timeout: 5),
            "Command Palette row should expose a button accessibility action"
        )
        XCTAssertTrue(
            saveAllCommand.isSelected,
            "Command Palette should expose its keyboard-selected result"
        )
        saveAllCommand.click()

        XCTAssertTrue(
            overlay.waitForNonExistence(timeout: 5),
            "Invoking a command should dismiss Command Palette"
        )
    }
}
