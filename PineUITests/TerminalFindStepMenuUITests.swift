//
//  TerminalFindStepMenuUITests.swift
//  PineUITests
//
//  Issue #1581 — Find Next / Find Previous enablement lives inside a
//  SwiftUI `Commands` body that unit tests cannot reach. This suite pins
//  the wiring in a terminal-only window: the menu items are disabled with
//  no addressee, flip on when the terminal search bar opens, a menu click
//  steps the search, and closing the bar flips them off again.
//

import XCTest

final class TerminalFindStepMenuUITests: PineUITestCase {

    private static let bundleIdentifier = "io.github.batonogov.pine"

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Delete first so an interrupted earlier run cannot leak a stale
        // shell override into this one. On a fresh runner the defaults
        // domain itself may not exist yet; `runDefaults` tolerates a
        // `delete` that fails only because the domain or key is missing.
        try runDefaults(["delete", Self.bundleIdentifier, "terminalShellPath"])
        try runDefaults(["delete", Self.bundleIdentifier, "terminalShellArgs"])

        // The terminal's scrollback must contain repeatable matches without
        // depending on this machine's shell prompt. `/usr/bin/yes sunny`
        // floods the pty with "sunny" lines, so the query typed below always
        // has many matches. Launch arguments store values as strings, but
        // ShellSettings reads a string and a string array, so plain
        // `defaults write` carries both keys.
        try runDefaults([
            "write",
            Self.bundleIdentifier,
            "terminalShellPath",
            "/usr/bin/yes"
        ])
        try runDefaults([
            "write",
            Self.bundleIdentifier,
            "terminalShellArgs",
            "-array",
            "sunny"
        ])

        projectURL = try createTempProject()
    }

    override func tearDownWithError() throws {
        try runDefaults(["delete", Self.bundleIdentifier, "terminalShellPath"])
        try runDefaults(["delete", Self.bundleIdentifier, "terminalShellArgs"])
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Runs `/usr/bin/defaults`, inheriting the runner's environment so
    /// `DEVELOPER_DIR` stays visible to sandboxed tooling. Fails the test
    /// when the tool itself errors — a silently skipped override would
    /// surface later as an unrelated missing-match-counter failure. The one
    /// exception: a `delete` whose stderr says the domain or key does not
    /// exist is tolerated, since on a fresh runner the app has not written
    /// any defaults yet and `defaults delete` exits non-zero with
    /// "Domain ... not found" even though there is nothing to clean up.
    private func runDefaults(_ arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = arguments
        proc.environment = ProcessInfo.processInfo.environment
        let errorPipe = Pipe()
        proc.standardError = errorPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            // Output is a single line, so reading after waitUntilExit
            // cannot deadlock on a full pipe buffer.
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            if arguments.first == "delete",
               errorOutput.contains("not found")
                || errorOutput.contains("Could not find") {
                return
            }
            throw NSError(
                domain: "TerminalFindStepMenuUITests.defaults",
                code: Int(proc.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "defaults \(arguments.joined(separator: " ")) failed: \(errorOutput)"
                ]
            )
        }
    }

    private var terminalSearchBar: XCUIElement {
        app.descendants(matching: .any)["terminalSearchBar"].firstMatch
    }

    private var terminalSearchField: XCUIElement {
        app.descendants(matching: .any)["terminalSearchField"].firstMatch
    }

    private var terminalSearchClose: XCUIElement {
        app.descendants(matching: .any)["terminalSearchClose"].firstMatch
    }

    private var newTerminalButton: XCUIElement {
        app.descendants(matching: .any)["newTerminalButton"].firstMatch
    }

    /// Opens the Edit menu and returns its Find Next / Find Previous items.
    /// The menu stays open; callers read `isEnabled` and close it with
    /// `dismissOpenMenu()`.
    private func openEditMenuFindItems() -> (next: XCUIElement, previous: XCUIElement) {
        clickMenuBarItem("Edit")
        let next = app.menuItems["Find Next"]
        XCTAssertTrue(
            next.waitForExistence(timeout: 3),
            "Find Next should be in the Edit menu"
        )
        let previous = app.menuItems["Find Previous"]
        XCTAssertTrue(
            previous.waitForExistence(timeout: 3),
            "Find Previous should be in the Edit menu"
        )
        return (next, previous)
    }

    private func dismissOpenMenu() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The "n of m" counter inside the terminal search bar. SwiftUI exposes
    /// the text as the element's value, not its label.
    private var matchCounter: XCUIElement {
        terminalSearchBar.staticTexts.matching(
            NSPredicate(format: "value MATCHES %@", "^[0-9]+ of [0-9]+$")
        ).firstMatch
    }

    /// Parses "current" out of the counter's "n of m" value.
    private func currentMatchIndex(_ counterValue: String) -> Int? {
        let parts = counterValue.split(separator: " ")
        guard parts.count == 3, let index = Int(parts[0]) else { return nil }
        return index
    }

    /// Polls until the counter's current index grows past `previous`.
    /// The total keeps changing while `yes` feeds the pty, so comparing the
    /// whole value would pass on total growth alone — only the current
    /// index proves the step happened.
    private func waitForMatchIndexAdvance(
        past previous: Int,
        timeout: TimeInterval = 10
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = matchCounter.value as? String ?? ""
            if let index = currentMatchIndex(value), index > previous {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail(
            "Match counter did not advance past \(previous); "
                + "last value: '\(matchCounter.value as? String ?? "")'"
        )
    }

    // MARK: - Terminal-only window

    func testFindNextMenuItemFlipsAndStepsTerminalSearch() throws {
        // Production first-launch seeding replaces the empty editor leaf
        // with a terminal pane: a true terminal-only window (#1251), the
        // headline scenario of #1551 / #1581.
        enableInitialTerminalSeeding()
        launchWithProject(projectURL)

        XCTAssertTrue(
            waitForExistence(newTerminalButton, timeout: 20),
            "Seeded terminal pane should appear"
        )
        let editorTabs = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'editorTab_'")
        )
        XCTAssertEqual(
            editorTabs.count, 0,
            "A seeded window has no editor tabs — Find Next must rely on the terminal"
        )

        // 1. No search bar visible: no addressee, both items disabled.
        var findItems = openEditMenuFindItems()
        XCTAssertFalse(
            findItems.next.isEnabled,
            "Find Next must be disabled with no editor tab and no terminal search"
        )
        XCTAssertFalse(
            findItems.previous.isEnabled,
            "Find Previous must be disabled with no editor tab and no terminal search"
        )
        dismissOpenMenu()

        // 2. Open the terminal search bar (the ⌘F path from #1523).
        clickMenuBarItem("Terminal")
        let findInTerminal = app.menuItems["Find in Terminal…"]
        XCTAssertTrue(waitForExistence(findInTerminal, timeout: 3))
        XCTAssertTrue(
            findInTerminal.isEnabled,
            "Find in Terminal must be enabled in a terminal-only window"
        )
        findInTerminal.click()
        XCTAssertTrue(
            waitForExistence(terminalSearchBar, timeout: 5),
            "Terminal search bar should appear"
        )

        // 3. The visible bar is an addressee: both items flip on.
        findItems = openEditMenuFindItems()
        XCTAssertTrue(
            findItems.next.isEnabled,
            "Find Next must be enabled while the terminal search bar is visible"
        )
        XCTAssertTrue(
            findItems.previous.isEnabled,
            "Find Previous must be enabled while the terminal search bar is visible"
        )
        dismissOpenMenu()

        // 4. A menu click steps the search. Type a query that matches the
        // seeded scrollback, wait for the counter, then click Find Next.
        XCTAssertTrue(waitForExistence(terminalSearchField, timeout: 5))
        terminalSearchField.click()
        terminalSearchField.typeText("sunny")
        XCTAssertTrue(
            matchCounter.waitForExistence(timeout: 10),
            "Match counter should appear for a query that matches the scrollback"
        )
        let counterValue = matchCounter.value as? String ?? ""
        let indexBefore = try XCTUnwrap(
            currentMatchIndex(counterValue),
            "Counter should parse as 'n of m', got '\(counterValue)'"
        )
        findItems = openEditMenuFindItems()
        findItems.next.click()

        waitForMatchIndexAdvance(past: indexBefore)

        // 5. Closing the bar removes the addressee: disabled again.
        terminalSearchClose.click()
        XCTAssertTrue(
            terminalSearchBar.waitForNonExistence(timeout: 3),
            "Terminal search bar should close"
        )
        findItems = openEditMenuFindItems()
        XCTAssertFalse(
            findItems.next.isEnabled,
            "Find Next must be disabled again once the search bar is closed"
        )
        XCTAssertFalse(
            findItems.previous.isEnabled,
            "Find Previous must be disabled again once the search bar is closed"
        )
        dismissOpenMenu()
    }
}
