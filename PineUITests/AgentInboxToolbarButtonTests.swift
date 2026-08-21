//
//  AgentInboxToolbarButtonTests.swift
//  PineUITests
//
//  UI coverage for the project-window Agent Inbox toolbar button (#1337).
//  Verifies the button is present in every project window and that clicking
//  it opens the Agent Inbox popover — additive to the existing ⌘⇧I chord
//  and the View menu item.
//

import XCTest

final class AgentInboxToolbarButtonTests: PineUITestCase {
    private var projectURLs: [URL] = []

    private var toolbarButton: XCUIElement {
        app.buttons["agentInboxToolbarButton"].firstMatch
    }

    private var inbox: XCUIElement {
        app.descendants(matching: .any)["agentInbox"].firstMatch
    }

    /// Binds the project window by its title.
    ///
    /// `app.windows.firstMatch` must never be used here: AX window lists run
    /// front to back, so once a popover is open `firstMatch` can resolve to
    /// the popover's own window and a "click outside" would land inside the
    /// Inbox list. A title-bound query can only ever name the project window.
    private func projectWindows(for url: URL) -> XCUIElementQuery {
        app.windows.matching(
            NSPredicate(format: "title == %@", url.lastPathComponent)
        )
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

        XCTAssertTrue(
            waitForExistence(inbox, timeout: 5),
            "Clicking the toolbar button should open the Agent Inbox popover"
        )
        XCTAssertFalse(
            app.windows["Agent Inbox"].exists,
            "Agent Inbox should not create a separate window"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            inbox.waitForNonExistence(timeout: 3),
            "Escape should dismiss the Agent Inbox popover"
        )

        // Escape closes the popover behind SwiftUI's back, and the binding is
        // lowered a runloop turn later. Without that write the anchor still
        // believes it is presenting and silently refuses the next request.
        toolbarButton.click()
        XCTAssertTrue(
            waitForExistence(inbox, timeout: 5),
            "The toolbar button should reopen the Inbox after Escape"
        )
    }

    /// AppKit owns transient dismissal: no unit seam can prove that clicking
    /// outside really closes the popover, that SwiftUI's binding follows it,
    /// or that the window stays usable afterwards.
    ///
    /// It is **not** evidence for #1491's "focus returns to the correct host
    /// after dismissal", and does not claim to be. Host selection prefers the
    /// most recently active project as well as the key window, and
    /// `ProjectRegistry.keyWindowSession()` stays non-nil for the last
    /// registered window whatever AppKit's key status is — so with one project
    /// window open the View menu lands here either way. The click that
    /// dismisses the popover also makes this window key by itself. That
    /// criterion has no production code and no test.
    func testOutsideClickDismissesInboxAndStaysRoutable() throws {
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        let window = projectWindows(for: url).firstMatch
        XCTAssertTrue(waitForExistence(window, timeout: 10))
        XCTAssertTrue(waitForExistence(toolbarButton, timeout: 10))
        toolbarButton.click()

        XCTAssertTrue(
            waitForExistence(inbox, timeout: 5),
            "The toolbar button should open the Agent Inbox popover"
        )

        // Bottom-left of the project window: clear of a 520x540 popover
        // hanging below the trailing-edge toolbar button, and clear of the
        // single file row at the top of the sidebar, so the window keeps its
        // title and this element keeps resolving.
        window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.93)
        ).click()

        XCTAssertTrue(
            inbox.waitForNonExistence(timeout: 5),
            "Clicking outside should dismiss the Agent Inbox popover"
        )

        // If the binding had not followed AppKit's dismissal, the anchor would
        // still believe it is presenting and refuse the next request.
        toolbarButton.click()
        XCTAssertTrue(
            waitForExistence(inbox, timeout: 5),
            "The same window should host the Inbox again after a dismissal"
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(inbox.waitForNonExistence(timeout: 5))

        clickMenuBarItem("View")
        let menuItem = app.menuItems["Agent Inbox"]
        XCTAssertTrue(waitForExistence(menuItem, timeout: 5))
        menuItem.click()

        XCTAssertTrue(
            waitForExistence(inbox, timeout: 10),
            "The window must still be routable after a transient dismissal"
        )
        XCTAssertEqual(
            projectWindows(for: url).count,
            1,
            "Reopening must reuse the project window, not add another"
        )
        XCTAssertFalse(
            app.windows["Agent Inbox"].exists,
            "Agent Inbox should never become a separate window"
        )
    }

    /// The View menu goes through `AppDelegate`'s real host selection rather
    /// than the anchor's own binding, so only a running app can prove that an
    /// application-level command lands in the project window it is issued
    /// from — and reuses it instead of creating Welcome beside it.
    ///
    /// Single-window only. #1491's multi-window criteria are covered at the
    /// `AgentInboxPresentationCoordinator` seam, not end to end.
    func testViewMenuOpensInboxInTheProjectWindowItReuses() throws {
        let url = try createTempProject(files: ["hello.swift": "// hi\n"])
        projectURLs.append(url)
        launchWithProject(url)

        let window = projectWindows(for: url).firstMatch
        XCTAssertTrue(waitForExistence(window, timeout: 10))
        XCTAssertTrue(waitForExistence(toolbarButton, timeout: 10))

        clickMenuBarItem("View")
        let menuItem = app.menuItems["Agent Inbox"]
        XCTAssertTrue(
            waitForExistence(menuItem, timeout: 5),
            "View should expose the Agent Inbox command"
        )
        menuItem.click()

        XCTAssertTrue(
            waitForExistence(inbox, timeout: 10),
            "View > Agent Inbox should open the popover in the project window"
        )
        // Counting *project* windows, not `app.windows`: nothing in this suite
        // establishes how `_NSPopoverWindow` shows up in the AX tree, and the
        // claim under test is that no second project window was opened.
        XCTAssertEqual(
            projectWindows(for: url).count,
            1,
            "Routing must reuse the project window instead of opening another"
        )
        XCTAssertFalse(
            waitForExistence(app.windows["welcome"], timeout: 2),
            "An eligible project window must not be bypassed for Welcome"
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
