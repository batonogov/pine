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

        XCTAssertFalse(
            sessionLinkedChip.exists,
            "A session-linked chip must not appear without session-linked rows"
        )
        XCTAssertTrue(
            inferredChip.exists,
            "The inferred category should be offered when inferred rows exist"
        )
        XCTAssertTrue(
            ambiguousChip.exists,
            "The ambiguous category should be offered when ambiguous rows exist"
        )
        XCTAssertFalse(app.buttons["Direct"].exists)
        XCTAssertFalse(app.buttons["Verified"].exists)
    }

    func testSessionLinkedFilterIsTruthfulSelectableAndReversible() throws {
        app.launchArguments.append("--ui-test-agent-activity-all")
        launchActivityPanel()

        XCTAssertTrue(sessionLinkedChip.exists)
        XCTAssertEqual(sessionLinkedChip.label, "Session-linked")
        XCTAssertFalse(app.buttons["Direct"].exists)
        XCTAssertFalse(app.buttons["Verified"].exists)

        sessionLinkedChip.click()

        XCTAssertTrue(
            sessionLinkedChip.isSelected,
            "The active evidence chip should expose the selected AX trait"
        )
        XCTAssertTrue(sessionLinkedRow.exists)
        XCTAssertFalse(inferredRow.exists)
        XCTAssertFalse(ambiguousRow.exists)

        sessionLinkedChip.click()

        XCTAssertFalse(sessionLinkedChip.isSelected)
        XCTAssertTrue(inferredRow.waitForExistence(timeout: 3))
        XCTAssertTrue(ambiguousRow.exists)
    }

    func testFilteredFeedUsesNoMatchesStateAndKeepsSelectedChip() throws {
        app.launchArguments.append("--ui-test-agent-activity-heuristic")
        launchActivityPanel()

        inferredChip.click()
        XCTAssertTrue(commandsChip.waitForExistence(timeout: 3))
        commandsChip.click()

        XCTAssertTrue(
            noMatchesState.waitForExistence(timeout: 3),
            "A populated feed with no filter matches needs a distinct empty state"
        )
        XCTAssertFalse(emptyFeedState.exists)
        XCTAssertTrue(
            inferredChip.exists,
            "A selected evidence chip must remain available so it can be cleared"
        )
        XCTAssertTrue(inferredChip.isSelected)
        XCTAssertTrue(
            commandsChip.isSelected,
            "The active kind chip should expose the selected AX trait"
        )
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

    private var sessionLinkedChip: XCUIElement {
        app.buttons["agentActivityFilterSessionLinked"].firstMatch
    }

    private var inferredChip: XCUIElement {
        app.buttons["agentActivityFilterInferred"].firstMatch
    }

    private var ambiguousChip: XCUIElement {
        app.buttons["agentActivityFilterAmbiguous"].firstMatch
    }

    private var commandsChip: XCUIElement {
        app.buttons["agentActivityFilterCommands"].firstMatch
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

    private var noMatchesState: XCUIElement {
        app.staticTexts["agentActivityNoMatches"].firstMatch
    }

    private var emptyFeedState: XCUIElement {
        app.staticTexts["agentActivityEmpty"].firstMatch
    }
}
