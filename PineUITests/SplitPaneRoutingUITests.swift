//
//  SplitPaneRoutingUITests.swift
//  PineUITests
//
//  UI smoke coverage for split-pane command availability from a non-primary
//  editor pane (follow-up to #1024, issue #1026).
//
//  ⚠️ These are SMOKE tests, not routing-verification tests.
//
//  Routing itself (active TabManager vs primary TabManager) is verified at
//  the unit level by `PineTests/SplitPaneRoutingTests.swift` — 20+ tests
//  that pin every routing primitive (pendingGoToLine, close*, inline diff,
//  change navigation, status bar, recovery) and FAIL if routing regresses
//  from active→primary. Those unit tests are the regression gate for #998.
//
//  These XCUITest cases complement the unit suite by verifying the USER-
//  FACING layer: that commands are reachable and functional when a non-
//  primary pane is focused, session-restore produces a valid two-pane
//  layout, and the tab context menu operates per-pane as expected. They do
//  NOT — and cannot — verify routing through XCUITest, because:
//
//    1. The tab context menu binds to the per-pane `tabManager` (PaneLeafView),
//       not `activeTabManager` — so Close All Tabs from a context menu is
//       per-pane by construction, independent of routing.
//    2. The Go-to-Line overlay appears whenever any tab is active, so its
//       presence does not prove routing — and cursor movement (the actual
//       routing effect) is unverifiable via XCUITest due to the
//       GutterTextView keyboard-input limitation (see .claude/rules/ui-tests.md).
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
            throw XCTSkip("Session state seeding failed — skipping split-pane smoke tests")
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
    /// and all subsequent smoke tests are invalid.
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

    // MARK: - Test: Close All Tabs from non-primary pane (per-pane smoke)

    /// Smoke test: triggers "Close All Tabs" via the tab context menu from the
    /// secondary pane. Verifies the command is reachable and operates per-pane
    /// (the context menu binds to the pane's own `tabManager` via PaneLeafView,
    /// not `activeTabManager`). This is a UI availability + per-pane isolation
    /// check — routing through `activeTabManager` is verified at the unit level
    /// by `SplitPaneRoutingTests.closeAllTabsRoutesToActivePaneOnly`.
    func testCloseAllTabsFromNonPrimaryPane() throws {
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

        // The primary pane's tab must survive — the tab context menu binds to
        // the pane's own `tabManager` (PaneLeafView), so Close All Tabs only
        // affects the pane whose tab was right-clicked.
        XCTAssertTrue(
            editorTab("main.swift").exists,
            "main.swift (primary pane) must survive — the context menu operates per-pane"
        )
    }

    // MARK: - Test: Go to Line opens from non-primary pane (availability smoke)

    /// Smoke test: focuses the secondary pane and triggers Go to Line via the
    /// Edit menu, verifying the overlay is reachable from a non-primary pane.
    /// This is a UI availability check — the overlay appears whenever any tab
    /// is active, so its presence does not prove routing. The actual routing
    /// (pendingGoToLine lands in the active pane, not primary) is verified at
    /// the unit level by `SplitPaneRoutingTests.goToLineOnGoToRoutesToActivePane`.
    func testGoToLineAvailableFromNonPrimaryPane() throws {
        launchAndRestoreSplit()

        XCTAssertTrue(waitForExistence(editorTab("utils.swift"), timeout: 10))

        // Ensure the secondary pane is focused by clicking its tab.
        editorTab("utils.swift").click()

        // Trigger Go to Line via Edit menu (typeKey is unreliable, see ui-tests.md).
        clickMenuBarItem("Edit")
        let goToLineItem = app.menuItems["Go to Line"]
        XCTAssertTrue(
            waitForExistence(goToLineItem, timeout: 5),
            "Go to Line menu item should exist in Edit menu"
        )
        goToLineItem.click()

        // The NSPanel-backed command overlay must appear. This is an
        // availability check, not a routing proof (see file header).
        let overlay = commandOverlay("goToLineOverlay")
        XCTAssertTrue(
            waitForExistence(overlay, timeout: 5),
            "Go to Line overlay should be reachable from the non-primary pane"
        )

        // Dismiss.
        app.typeKey(.escape, modifierFlags: [])
    }
}
