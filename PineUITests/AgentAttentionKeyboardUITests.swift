//
//  AgentAttentionKeyboardUITests.swift
//  PineUITests
//

import XCTest

final class AgentAttentionKeyboardUITests: PineUITestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject()
        app.launchArguments.append("--ui-test-agent-attention")
        launchWithProject(projectURL)
    }

    override func tearDownWithError() throws {
        if let projectURL {
            cleanupProject(projectURL)
        }
        try super.tearDownWithError()
    }

    func testArrowSelectionIsAnnouncedAndReturnRoutesExactTerminal() {
        openAttention()

        XCTAssertTrue(waitingRow.isSelected)
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(executingRow.isSelected)
        XCTAssertFalse(waitingRow.isSelected)

        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(attentionOverlay.waitForExistence(timeout: 1))
        XCTAssertTrue(
            app.buttons["terminalTab_Terminal 2"].firstMatch.isSelected,
            "Return should select the terminal represented by the highlighted row"
        )
    }

    func testEscapeDismissesWithoutChangingTheSelectedTerminal() {
        let originalTab = app.buttons["terminalTab_Terminal 1"].firstMatch
        XCTAssertTrue(originalTab.waitForExistence(timeout: 5))
        originalTab.click()
        XCTAssertTrue(originalTab.isSelected)

        openAttention()
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(attentionOverlay.waitForExistence(timeout: 1))
        XCTAssertTrue(
            originalTab.isSelected,
            "Cancelling Attention must preserve the previous terminal destination"
        )
    }

    private func openAttention() {
        let bell = app.buttons["agentAttentionBell"].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 5))
        bell.click()
        XCTAssertTrue(attentionOverlay.waitForExistence(timeout: 3))
    }

    private var attentionOverlay: XCUIElement {
        app.descendants(matching: .any)["agentAttentionOverlay"].firstMatch
    }

    private var waitingRow: XCUIElement {
        app.buttons[
            "agentAttentionRow_00000000-0000-0000-0000-000000000001"
        ].firstMatch
    }

    private var executingRow: XCUIElement {
        app.buttons[
            "agentAttentionRow_00000000-0000-0000-0000-000000000002"
        ].firstMatch
    }
}
