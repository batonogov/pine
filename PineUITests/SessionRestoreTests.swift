//
//  SessionRestoreTests.swift
//  PineUITests
//
//  UI tests for session persistence: tabs restored after close/reopen,
//  multi-tab state preserved across sessions, terminal pane presence
//  after session restore.
//

import XCTest

final class SessionRestoreTests: PineUITestCase {

    private var projectURL: URL!
    private var seededSessionKey: String?
    private let bundleID = "io.github.batonogov.pine"

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(files: [
            "main.swift": "let x = 1\n",
            "helper.swift": "func helper() {}\n",
            "config.json": "{\n  \"key\": \"value\"\n}\n"
        ])
    }

    override func tearDownWithError() throws {
        if let seededSessionKey {
            try? runDefaults(["delete", bundleID, seededSessionKey])
        }
        if let url = projectURL { cleanupProject(url) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Closes the app and relaunches with the same project via recent projects.
    private func closeAndReopenProject() {
        // Close the project window
        let closeButton = app.windows.firstMatch.buttons["_XCUI:CloseWindow"].firstMatch
        if closeButton.exists {
            closeButton.click()
        }

        let welcomeWindow = app.windows["welcome"]
        XCTAssertTrue(
            waitForExistence(welcomeWindow, timeout: 10),
            "Welcome window should appear after closing project"
        )

        // Reopen via recent projects
        let projectName = projectURL.lastPathComponent
        let recentProject = app.descendants(matching: .any)[
            "welcomeRecentProject_\(projectName)"
        ].firstMatch
        XCTAssertTrue(
            waitForExistence(recentProject, timeout: 5),
            "Project should be in recent projects list"
        )
        recentProject.doubleClick()

        // Wait for project to load
        let sidebar = app.scrollViews["sidebar"]
        XCTAssertTrue(
            waitForExistence(sidebar, timeout: 15),
            "Project should reopen with sidebar"
        )
    }

    // MARK: - Tests

    func testMultipleTabsRestoredAfterReopen() throws {
        launchWithProject(projectURL)

        // Open multiple files
        openFile("main.swift")
        openFile("helper.swift")
        openFile("config.json")

        // Verify all tabs exist
        XCTAssertTrue(editorTab("main.swift").exists)
        XCTAssertTrue(editorTab("helper.swift").exists)
        XCTAssertTrue(editorTab("config.json").exists)

        // Close and reopen
        closeAndReopenProject()

        // All three tabs should be restored
        XCTAssertTrue(
            waitForExistence(editorTab("main.swift"), timeout: 15),
            "main.swift tab should be restored"
        )
        XCTAssertTrue(
            waitForExistence(editorTab("helper.swift"), timeout: 5),
            "helper.swift tab should be restored"
        )
        XCTAssertTrue(
            waitForExistence(editorTab("config.json"), timeout: 5),
            "config.json tab should be restored"
        )
    }

    func testActiveTabRestoredAfterReopen() throws {
        launchWithProject(projectURL)

        // Open files and select helper.swift as active
        openFile("main.swift")
        openFile("helper.swift")
        // helper.swift should be active (last opened)

        // Close and reopen
        closeAndReopenProject()

        // helper.swift should be the active tab
        let helperTab = editorTab("helper.swift")
        XCTAssertTrue(
            waitForExistence(helperTab, timeout: 15),
            "helper.swift tab should be restored"
        )
        // Verify it is selected
        let selectedPredicate = NSPredicate(format: "isSelected == true")
        let selectedExpectation = XCTNSPredicateExpectation(
            predicate: selectedPredicate, object: helperTab
        )
        wait(for: [selectedExpectation], timeout: 10)
    }

    func testEditorTabRestoredAndClickableAfterSessionRestore() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        closeAndReopenProject()

        // Tab should be restored and clickable
        let mainTab = editorTab("main.swift")
        XCTAssertTrue(
            waitForExistence(mainTab, timeout: 15),
            "Editor tab should be visible after session restore"
        )
        // Click on the restored tab to verify it's interactive
        mainTab.click()
        XCTAssertTrue(mainTab.isSelected, "Restored tab should be selectable")
    }

    func testStatusBarVisibleAfterSessionRestore() throws {
        launchWithProject(projectURL)

        openFile("main.swift")

        closeAndReopenProject()

        let statusBar = app.descendants(matching: .any)["statusBar"].firstMatch
        XCTAssertTrue(
            waitForExistence(statusBar, timeout: 15),
            "Status bar should be visible after session restore"
        )
    }

    func testFixtureSurvivesInjectedWriteFailureAndProcessRelaunch() throws {
        cleanupProject(projectURL)
        projectURL = try createTempProject(files: [
            "Sources/App.swift": "let fixture = true\n",
            "helper.swift": "let replacement = true\n",
        ])
        app.launchArguments.removeAll { $0 == "--reset-state" }
        try seedVersionedSessionFixture()
        app.launchEnvironment["PINE_PERSISTENCE_FAULT"] = [
            "session",
            "before-atomic-replace",
            "atomic-rename",
        ].joined(separator: ":")

        launchWithProject(projectURL)
        XCTAssertTrue(
            waitForExistence(editorTab("App.swift"), timeout: 15),
            "The shared versioned fixture should restore App.swift"
        )
        openFile("helper.swift")

        let closeButton = app.windows.firstMatch
            .buttons["_XCUI:CloseWindow"].firstMatch
        XCTAssertTrue(closeButton.exists)
        closeButton.click()
        XCTAssertTrue(
            waitForExistence(app.windows["welcome"], timeout: 10),
            "Closing the project should attempt the injected session save"
        )
        app.terminate()

        app.launchEnvironment.removeValue(forKey: "PINE_PERSISTENCE_FAULT")
        launchWithProject(projectURL)
        XCTAssertTrue(
            waitForExistence(editorTab("App.swift"), timeout: 15),
            "Relaunch should consume the original last-known-good fixture"
        )
        XCTAssertFalse(
            editorTab("helper.swift").exists,
            "The failed replacement must not become the restored session"
        )
    }

    private func seedVersionedSessionFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "PineTests/Fixtures/Persistence/session-v0.json"
            )
        let fixture = try String(
            contentsOf: fixtureURL,
            encoding: .utf8
        ).replacingOccurrences(
            of: "{{PROJECT_PATH}}",
            with: projectURL.resolvingSymlinksInPath().path
        )
        let data = Data(fixture.utf8)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let key = "sessionState:\(projectURL.resolvingSymlinksInPath().path)"
        try runDefaults(["write", bundleID, key, "-data", hex])
        seededSessionKey = key
    }

    private func runDefaults(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

}
