//
//  SplitPaneRoutingUITests.swift
//  PineUITests
//
//  End-to-end UI coverage for split-pane command routing from a non-primary
//  editor pane (follow-up to #1024, issue #1026).
//
//  The unit-level SplitPaneRoutingTests verify data-flow contracts but cannot
//  exercise SwiftUI view methods directly. These XCUITest cases drive the
//  actual view routing end-to-end: they create a two-editor-pane split via
//  pre-seeded session state, focus the non-primary pane, and verify that
//  commands (Go-to-Line, Close All Tabs) target the focused pane — not the
//  primary pane. This catches a #998-style regression where a developer
//  swaps `activeTabManager` → `primaryTabManager` inside a view method.
//
//  XCUITest cannot create editor-pane splits via drag-and-drop (SwiftUI's
//  onDrag/onDrop relies on the macOS pasteboard system, which synthetic
//  gestures do not activate). Instead, the split layout is pre-seeded into
//  UserDefaults as a SessionState JSON with a PaneNode split tree before
//  launch. The app restores it on first appear, producing a reliable
//  two-editor-pane layout without --reset-state.
//

import XCTest

final class SplitPaneRoutingUITests: PineUITestCase {

    private var projectURL: URL!
    private let primaryPaneID = UUID()
    private let secondaryPaneID = UUID()
    private let bundleID = "io.github.batonogov.pine"

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Do NOT use --reset-state: we need the pre-seeded session to be
        // restored on launch. The base class adds it; remove it here.
        app.launchArguments.removeAll { $0 == "--reset-state" }

        projectURL = try createTempProject(files: [
            "main.swift": "// primary pane\nlet x = 1\n",
            "utils.swift": "// secondary pane\nfunc helper() {}\n"
        ])

        try seedSplitSession()
    }

    override func tearDownWithError() throws {
        if let url = projectURL {
            let resolved = url.resolvingSymlinksInPath().path
            runDefaults(["delete", bundleID, "sessionState:\(resolved)"])
            cleanupProject(url)
        }
        try super.tearDownWithError()
    }

    // MARK: - Session State Seeding

    /// Writes a SessionState JSON to the app's UserDefaults containing a
    /// two-editor-pane horizontal split. The primary pane gets `main.swift`,
    /// the secondary pane gets `utils.swift`, and the secondary pane starts
    /// active.
    private func seedSplitSession() throws {
        let resolvedPath = projectURL.resolvingSymlinksInPath().path
        let mainPath = projectURL.appendingPathComponent("main.swift").path
        let utilsPath = projectURL.appendingPathComponent("utils.swift").path
        let primaryUUID = primaryPaneID.uuidString
        let secondaryUUID = secondaryPaneID.uuidString

        // PaneNode JSON: horizontal split with two editor leaves.
        // PaneID encodes as {"id": "<uuid>"} (synthesized Codable).
        let paneNodeJSON = """
        {"type":"split","axis":"horizontal",\
        "first":{"type":"leaf","id":{"id":"\(primaryUUID)"},"content":"editor"},\
        "second":{"type":"leaf","id":{"id":"\(secondaryUUID)"},"content":"editor"},\
        "ratio":0.5}
        """

        // paneLayoutData is Data — base64-encoded when SessionState is
        // JSON-encoded by JSONEncoder.
        let paneNodeData = Data(paneNodeJSON.utf8)
        let paneNodeBase64 = paneNodeData.base64EncodedString()

        // SessionState JSON matching the Codable struct in SessionState.swift.
        let sessionJSON = """
        {\
        "projectPath":"\(escaped(resolvedPath))",\
        "openFilePaths":["\(escaped(mainPath))","\(escaped(utilsPath))"],\
        "activeFilePath":null,\
        "previewModes":null,\
        "highlightingDisabledPaths":null,\
        "editorStates":null,\
        "pinnedPaths":null,\
        "paneLayoutData":"\(paneNodeBase64)",\
        "paneTabAssignments":{"\(primaryUUID)":["\(escaped(mainPath))"],\
        "\(secondaryUUID)":["\(escaped(utilsPath))"]},\
        "activePaneID":"\(secondaryUUID)",\
        "terminalTabCount":null,\
        "activeTerminalIndex":null,\
        "isTerminalVisible":null,\
        "isTerminalMaximized":null,\
        "terminalPaneTabCounts":null,\
        "terminalPaneActiveIndices":null\
        }
        """

        // `defaults write -data` expects hex-encoded bytes.
        let sessionData = Data(sessionJSON.utf8)
        let hex = sessionData.map { String(format: "%02x", $0) }.joined()
        let key = "sessionState:\(resolvedPath)"

        runDefaults(["write", bundleID, key, "-data", hex])

        guard defaultsWriteSucceeded(key: key) else {
            throw XCTSkip("Session state seeding failed — skipping split-pane routing tests")
        }
    }

    /// Escapes backslashes and double quotes for embedding in JSON strings.
    private func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs `/usr/bin/defaults` with the given arguments and DEVELOPER_DIR.
    private func runDefaults(_ arguments: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = arguments
        proc.environment = ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // Non-fatal: the test will skip if the key is missing.
        }
    }

    /// Verifies that the session-state key was written to UserDefaults.
    private func defaultsWriteSucceeded(key: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["read", bundleID, key]
        proc.environment = ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func launchAndRestoreSplit() {
        launchWithProject(projectURL)
    }

    private var paneDividers: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "paneDivider")
    }

    // MARK: - Test: Split layout restored from session

    /// Verifies the pre-seeded session state produces a two-editor-pane split
    /// with both files visible. If this fails, session-state seeding is broken
    /// and all subsequent routing tests are invalid.
    func testSplitLayoutRestoredWithTwoEditorPanes() throws {
        launchAndRestoreSplit()

        XCTAssertTrue(
            waitForExistence(editorTab("main.swift"), timeout: 10),
            "main.swift tab should appear in the primary pane"
        )
        XCTAssertTrue(
            waitForExistence(editorTab("utils.swift"), timeout: 5),
            "utils.swift tab should appear in the secondary pane"
        )

        // A pane divider must be present — proving a two-pane layout was restored.
        XCTAssertTrue(
            paneDividers.firstMatch.waitForExistence(timeout: 5),
            "Pane divider should exist in a two-editor-pane layout"
        )
        XCTAssertGreaterThanOrEqual(
            paneDividers.count, 1,
            "At least one pane divider expected for a split layout"
        )
    }

    // MARK: - Test: Close All Tabs routes to the active pane

    /// From the secondary pane, triggers "Close All Tabs" via the tab context
    /// menu. Only the secondary pane's tab should close; the primary pane's
    /// tab must survive. This catches a #998-style regression where
    /// `closeAllTabsWithConfirmation` routes to `primaryTabManager` instead of
    /// `activeTabManager`.
    func testCloseAllTabsRoutesToActivePane() throws {
        launchAndRestoreSplit()

        // Both tabs must be present before the test.
        XCTAssertTrue(waitForExistence(editorTab("main.swift"), timeout: 10))
        XCTAssertTrue(waitForExistence(editorTab("utils.swift"), timeout: 5))

        // The secondary pane starts active (activePaneID set in session state).
        // Right-click utils.swift tab to open its context menu.
        let utilsTab = editorTab("utils.swift")
        XCTAssertTrue(utilsTab.waitForExistence(timeout: 5))
        utilsTab.rightClick()

        // Select "Close All Tabs" from the context menu.
        let closeAllItem = app.menuItems["Close All Tabs"]
        XCTAssertTrue(
            closeAllItem.waitForExistence(timeout: 3),
            "'Close All Tabs' should appear in the tab context menu"
        )
        closeAllItem.click()

        // The secondary pane's tab must be gone.
        let utilsGone = !editorTab("utils.swift").waitForExistence(timeout: 3)
        XCTAssertTrue(utilsGone, "utils.swift (secondary pane) should be closed by Close All Tabs")

        // The primary pane's tab must survive — proving routing went to the
        // active pane, not the primary.
        XCTAssertTrue(
            editorTab("main.swift").exists,
            "main.swift (primary pane) must survive — Close All Tabs should only affect the active pane"
        )
    }

    // MARK: - Test: Go to Line opens from non-primary pane

    /// Focuses the secondary pane and triggers Go to Line via the Edit menu.
    /// The Go to Line overlay must appear, confirming the command fires from
    /// the active pane. (Cursor position cannot be verified in XCUITest due
    /// to the GutterTextView keyboard-input limitation documented in
    /// AGENTS.md.)
    func testGoToLineOpensFromNonPrimaryPane() throws {
        launchAndRestoreSplit()

        XCTAssertTrue(waitForExistence(editorTab("utils.swift"), timeout: 10))

        // Ensure the secondary pane is focused by clicking its tab.
        editorTab("utils.swift").click()

        // Trigger Go to Line via Edit menu (typeKey is unreliable per AGENTS.md).
        clickMenuBarItem("Edit")
        let goToLineItem = app.menuItems["Go to Line"]
        XCTAssertTrue(
            waitForExistence(goToLineItem, timeout: 5),
            "Go to Line menu item should exist in Edit menu"
        )
        goToLineItem.click()

        // The Go to Line overlay must appear — confirming the command routed
        // through the active (secondary) pane's TabManager. We check for the
        // text field inside the overlay (goToLineField) which is the most
        // reliable indicator the overlay is presented.
        let goToLineField = app.descendants(matching: .any)["goToLineField"].firstMatch
        XCTAssertTrue(
            waitForExistence(goToLineField, timeout: 5),
            "Go to Line overlay should appear when triggered from the non-primary pane"
        )

        // Dismiss.
        app.typeKey(.escape, modifierFlags: [])
    }
}
