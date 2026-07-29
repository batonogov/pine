//
//  AgentActivityFilterUITests.swift
//  PineUITests
//
//  End-to-end coverage for the Activity Panel's attribution-evidence filters.
//

import XCTest

final class AgentActivityFilterUITests: PineUITestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject()
    }

    override func tearDownWithError() throws {
        if let projectURL {
            cleanupProject(projectURL)
        }
        try super.tearDownWithError()
    }

    func testOnlyEvidenceCategoriesPresentInFeedAreOffered() throws {
        app.launchArguments.append("--ui-test-agent-activity-heuristic")
        launchActivityPanel()

        attributionMenu.click()
        XCTAssertFalse(app.menuItems["Session-linked"].exists)
        XCTAssertTrue(
            app.menuItems["Inferred"].exists,
            "The inferred category should be offered when inferred rows exist"
        )
        XCTAssertTrue(
            app.menuItems["Ambiguous"].exists,
            "The ambiguous category should be offered when ambiguous rows exist"
        )
        XCTAssertFalse(app.buttons["Direct"].exists)
        XCTAssertFalse(app.buttons["Verified"].exists)
    }

    func testSessionLinkedFilterIsTruthfulSelectableAndReversible() throws {
        app.launchArguments.append("--ui-test-agent-activity-all")
        launchActivityPanel()

        selectAttribution("Session-linked")

        XCTAssertTrue(
            attributionMenu.isSelected,
            "The active evidence menu should expose the selected AX trait"
        )
        XCTAssertEqual(attributionMenu.value as? String, "Session-linked")
        XCTAssertTrue(sessionLinkedRow.exists)
        XCTAssertFalse(inferredRow.exists)
        XCTAssertFalse(ambiguousRow.exists)

        attributionMenu.click()
        app.menuItems["All evidence"].click()

        XCTAssertFalse(attributionMenu.isSelected)
        XCTAssertTrue(inferredRow.waitForExistence(timeout: 3))
        XCTAssertTrue(ambiguousRow.exists)
    }

    func testFilteredFeedUsesNoMatchesStateAndKeepsSelectedChip() throws {
        app.launchArguments.append("--ui-test-agent-activity-heuristic")
        launchActivityPanel()

        selectAttribution("Inferred")
        XCTAssertTrue(
            attributionMenu.isSelected,
            "The active evidence menu should expose the selected AX trait"
        )
        XCTAssertEqual(attributionMenu.value as? String, "Inferred")
        selectKind("Command")
        XCTAssertTrue(
            kindMenu.isSelected,
            "The active kind menu should expose the selected AX trait"
        )

        XCTAssertTrue(
            noMatchesState.waitForExistence(timeout: 3),
            "A populated feed with no filter matches needs a distinct empty state"
        )
        XCTAssertFalse(emptyFeedState.exists)
        XCTAssertTrue(
            attributionMenu.exists,
            "A selected evidence menu must remain available so it can be cleared"
        )
        XCTAssertTrue(attributionMenu.isSelected)
    }

    func testCommandAndToolRowsWithoutFilesRemainInspectable() throws {
        app.launchArguments += [
            "--ui-test-agent-activity-all",
            "--ui-test-agent-attention"
        ]
        launchActivityPanel()

        commandRow.click()
        XCTAssertTrue(activityDetail.waitForExistence(timeout: 3))
        XCTAssertTrue(detailCopy.waitForExistence(timeout: 3))
        XCTAssertTrue(detailGoToTerminal.waitForExistence(timeout: 3))
        XCTAssertFalse(detailOpenFile.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(activityDetail.waitForExistence(timeout: 1))

        toolRow.click()
        XCTAssertTrue(activityDetail.waitForExistence(timeout: 3))
        XCTAssertTrue(detailCopy.waitForExistence(timeout: 3))
        XCTAssertTrue(detailGoToTerminal.waitForExistence(timeout: 3))
        XCTAssertFalse(detailOpenFile.exists)
    }

    private func launchActivityPanel() {
        launchWithProject(projectURL)
        clickMenuBarItem("View")
        let activityItem = app.menuItems["Agent Activity"]
        XCTAssertTrue(activityItem.waitForExistence(timeout: 3))
        activityItem.click()
        XCTAssertTrue(
            activityPanel.waitForExistence(timeout: 5),
            "The Activity Panel should open from the View menu"
        )
    }

    private var activityPanel: XCUIElement {
        app.descendants(matching: .any)["agentActivityPanel"].firstMatch
    }

    private func selectAttribution(_ label: String) {
        attributionMenu.click()
        let item = app.menuItems[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
    }

    private func selectKind(_ label: String) {
        kindMenu.click()
        let item = app.menuItems[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
    }

    private var attributionMenu: XCUIElement {
        app.descendants(matching: .any)[
            "agentActivityAttributionMenu"
        ].firstMatch
    }

    private var kindMenu: XCUIElement {
        app.descendants(matching: .any)["agentActivityKindMenu"].firstMatch
    }

    private var sessionLinkedRow: XCUIElement {
        app.buttons[
            "agentActivityRow_00000000-0000-0000-0000-000000000101"
        ].firstMatch
    }

    private var inferredRow: XCUIElement {
        app.buttons[
            "agentActivityRow_00000000-0000-0000-0000-000000000102"
        ].firstMatch
    }

    private var ambiguousRow: XCUIElement {
        app.buttons[
            "agentActivityRow_00000000-0000-0000-0000-000000000103"
        ].firstMatch
    }

    private var commandRow: XCUIElement {
        app.buttons[
            "agentActivityRow_00000000-0000-0000-0000-000000000101"
        ].firstMatch
    }

    private var toolRow: XCUIElement {
        app.buttons[
            "agentActivityRow_00000000-0000-0000-0000-000000000104"
        ].firstMatch
    }

    private var activityDetail: XCUIElement {
        app.descendants(matching: .any)["agentActivityDetail"].firstMatch
    }

    private var detailCopy: XCUIElement {
        app.descendants(matching: .any)["agentActivityDetailCopy"].firstMatch
    }

    private var detailGoToTerminal: XCUIElement {
        app.descendants(matching: .any)[
            "agentActivityDetailGoToTerminal"
        ].firstMatch
    }

    private var detailOpenFile: XCUIElement {
        app.descendants(matching: .any)[
            "agentActivityDetailOpenFile"
        ].firstMatch
    }

    private var noMatchesState: XCUIElement {
        // SwiftUI does not reliably preserve a conditional Text's identifier
        // in the macOS 26 accessibility tree. The UI-test locale is forced to
        // English, so its visible label is the stable end-to-end contract.
        app.staticTexts["No matching activity"].firstMatch
    }

    private var emptyFeedState: XCUIElement {
        app.staticTexts["No Active Agents"].firstMatch
    }
}
