//
//  AgentInboxToolbarButtonTests.swift
//  PineUITests
//
//  UI coverage for the project-window Agent Inbox toolbar button (#1337).
//  Verifies the button is present in every project window and that clicking
//  it opens the Agent Inbox window — additive to the existing ⌘⇧I chord
//  and the Window menu item.
//

import XCTest

final class AgentInboxToolbarButtonTests: PineUITestCase {
    private var projectURLs: [URL] = []

    private var toolbarButton: XCUIElement {
        app.buttons["agentInboxToolbarButton"].firstMatch
    }

    override func tearDownWithError() throws {
        for url in projectURLs { cleanupProject(url) }
        try super.tearDownWithError()
    }

    func testToolbarButtonPresentInProjectWindow() throws {
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        XCTAssertTrue(
            waitForExistence(toolbarButton, timeout: 10),
            "The Agent Inbox toolbar button should be present in every project window"
        )
    }

    func testToolbarButtonOpensAgentInbox() throws {
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        XCTAssertTrue(
            waitForExistence(toolbarButton, timeout: 10),
            "The Agent Inbox toolbar button should be present"
        )
        toolbarButton.click()

        let inboxWindow = app.windows["Agent Inbox"]
        XCTAssertTrue(
            waitForExistence(inboxWindow, timeout: 5),
            "Clicking the toolbar button should open the Agent Inbox window"
        )
    }

    func testAgentInboxExposesContextualHelp() throws {
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        XCTAssertTrue(waitForExistence(toolbarButton, timeout: 10))
        toolbarButton.click()

        let helpButton = app.buttons[
            "agentInboxHelpButton"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(helpButton, timeout: 5),
            "Agent Inbox should expose its task-specific Apple Help topic"
        )
    }
}
