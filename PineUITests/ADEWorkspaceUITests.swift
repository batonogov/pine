//
//  ADEWorkspaceUITests.swift
//  PineUITests
//
//  The Pine 3 project window (#1760): one project column with its task
//  rows, a view-only selection that survives relaunch, and the composer's
//  explicit Request/Command modes with their truthful captions. The
//  `--ui-test-ade-workspace` fixture seeds presentation-only tasks with
//  fixed IDs; no provider, grant, acceptance, or process is involved.
//

import XCTest

final class ADEWorkspaceUITests: PineUITestCase {
    private static let readyRowID =
        "workspaceTaskRow_0ADE0000-0000-4000-8000-000000000001"
    private static let decisionRowID =
        "workspaceTaskRow_0ADE0000-0000-4000-8000-000000000002"

    /// Launches into the Pine 3 workspace with the fixture project and
    /// returns its path — the value `PINE_OPEN_PROJECT` consumes.
    private func launchWorkspace() -> String {
        let project = (try? createTempProject(
            files: ["tracked.txt": "tracked\n"],
            projectName: "WorkspaceFixture"
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PineUITest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("WorkspaceFixture", isDirectory: true)
        let projectPath = project.path
        launchEnvironmentFixtures.append(projectPath)
        app.launchArguments.append("--ui-test-ade-workspace")
        app.launchEnvironment["PINE_OPEN_PROJECT"] = projectPath
        app.launch()
        app.activate()
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
        return projectPath
    }

    /// Opened fixture projects, removed on teardown.
    private var launchEnvironmentFixtures: [String] = []

    override func tearDownWithError() throws {
        for path in launchEnvironmentFixtures where path.contains("PineUITest-") {
            try? FileManager.default.removeItem(atPath: path)
        }
        launchEnvironmentFixtures.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Rows

    func testTaskRowsRenderInEveryState() throws {
        _ = launchWorkspace()

        let list = app.descendants(matching: .any)
            .matching(identifier: "workspaceTaskList").firstMatch
        XCTAssertTrue(waitForExistence(list, timeout: 15), "the task list should mount")

        for goal in [
            "Ready fixture task", "Decision fixture task", "Running fixture task",
            "Failed fixture task", "Cancelled fixture task",
            "Unverified fixture task", "Unstarted fixture task",
        ] {
            let row = list.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", goal)).firstMatch
            XCTAssertTrue(
                waitForExistence(row, timeout: 10),
                "a row for \(goal) should be listed"
            )
        }
    }

    func testRowLabelsCarryTheirStateForVoiceOver() throws {
        _ = launchWorkspace()

        let list = app.descendants(matching: .any)
            .matching(identifier: "workspaceTaskList").firstMatch
        XCTAssertTrue(waitForExistence(list, timeout: 15))

        let ready = list.descendants(matching: .any)
            .matching(identifier: Self.readyRowID).firstMatch
        XCTAssertTrue(waitForExistence(ready, timeout: 10))
        XCTAssertTrue(
            ready.label.contains("Ready fixture task")
                && ready.label.contains("Ready"),
            "the spoken row names the goal and the state, got: \(ready.label)"
        )

        let decision = list.descendants(matching: .any)
            .matching(identifier: Self.decisionRowID).firstMatch
        XCTAssertTrue(waitForExistence(decision, timeout: 10))
        XCTAssertTrue(
            decision.label.contains("Decision fixture task"),
            "the decision row names its goal, got: \(decision.label)"
        )
    }

    // MARK: - Selection

    func testSelectionSurvivesRelaunch() throws {
        let projectPath = launchWorkspace()

        let readyRow = app.descendants(matching: .any)
            .matching(identifier: Self.readyRowID).firstMatch
        XCTAssertTrue(waitForExistence(readyRow, timeout: 15), "the ready row should mount")
        readyRow.click()

        let goal = app.descendants(matching: .any)
            .matching(identifier: "workspaceTaskGoal").firstMatch
        XCTAssertTrue(
            waitForExistence(goal, timeout: 10),
            "selecting a row shows the task in the main area"
        )
        XCTAssertEqual(goal.value as? String ?? goal.label, "Ready fixture task")

        app.terminate()

        // The relaunch reuses the same isolated state namespace (the base
        // class re-applies it to the replacement app) and the same fixture
        // (fixed task IDs), so the stored selection can be honored.
        relaunchIsolatedApp { [weak self] app in
            app.launchArguments.append("--ui-test-ade-workspace")
            app.launchEnvironment["PINE_OPEN_PROJECT"] = projectPath
            self?.launchEnvironmentFixtures.append(projectPath)
        }

        let restoredGoal = app.descendants(matching: .any)
            .matching(identifier: "workspaceTaskGoal").firstMatch
        XCTAssertTrue(
            waitForExistence(restoredGoal, timeout: 15),
            "the restored selection should show the task again"
        )
        XCTAssertEqual(
            restoredGoal.value as? String ?? restoredGoal.label,
            "Ready fixture task",
            "the same task is selected after relaunch; nothing was sent or run"
        )
    }

    // MARK: - Composer modes

    func testCommandModeShowsTruthfulUnavailableCaption() throws {
        _ = launchWorkspace()

        let input = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerInput").firstMatch
        XCTAssertTrue(waitForExistence(input, timeout: 15), "the overview composer should mount")

        let modePicker = app.descendants(matching: .any)
            .matching(identifier: "workspaceInputMode").firstMatch
        XCTAssertTrue(waitForExistence(modePicker, timeout: 5))

        // SwiftUI's segmented Picker exposes its segments as radio buttons.
        let commandSegment = modePicker.radioButtons["Command"].firstMatch
        XCTAssertTrue(waitForExistence(commandSegment, timeout: 5), "the mode control has a Command segment")
        commandSegment.click()

        input.click()
        input.typeText("swift build")

        let send = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerSend").firstMatch
        XCTAssertTrue(waitForExistence(send, timeout: 5))
        XCTAssertFalse(
            send.isEnabled,
            "Command mode without an execution lane never sends; nothing runs"
        )

        let notice = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerNotice").firstMatch
        XCTAssertTrue(waitForExistence(notice, timeout: 5), "the unavailable state is explained")
        XCTAssertEqual(notice.label, "Running commands is not available yet. Pine has not run anything.")
    }

    func testRequestModeOnSettledTaskDoesNotResumeAnything() throws {
        _ = launchWorkspace()

        // Select a settled fixture task: no live session, nothing may resume.
        let unstartedRow = app.descendants(matching: .any)
            .matching(identifier: "workspaceTaskRow_0ADE0000-0000-4000-8000-000000000007")
            .firstMatch
        XCTAssertTrue(waitForExistence(unstartedRow, timeout: 15))
        unstartedRow.click()

        let input = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerInput").firstMatch
        XCTAssertTrue(waitForExistence(input, timeout: 10))
        input.click()
        input.typeText("continue this task")

        let send = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerSend").firstMatch
        XCTAssertTrue(waitForExistence(send, timeout: 5))
        XCTAssertFalse(
            send.isEnabled,
            "selection is view-only: Pine does not resume a session to send"
        )

        let notice = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerNotice").firstMatch
        XCTAssertTrue(waitForExistence(notice, timeout: 5))
        XCTAssertTrue(
            notice.label.contains("not running"),
            "the caption says the session is not running and will not be resumed, got: \(notice.label)"
        )
    }

    func testKeyboardPathFocusesComposerAndArmsSend() throws {
        _ = launchWorkspace()

        let newTaskButton = app.descendants(matching: .any)
            .matching(identifier: "workspaceNewTaskButton").firstMatch
        XCTAssertTrue(waitForExistence(newTaskButton, timeout: 15))
        newTaskButton.click()

        // The new-task affordance moves focus to the overview composer.
        let input = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerInput").firstMatch
        XCTAssertTrue(waitForExistence(input, timeout: 10))
        // The focus request lands asynchronously; fall back to clicking the
        // field so the remainder still exercises real keyboard entry.
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let focusExpectation = expectation(for: focused, evaluatedWith: input)
        wait(for: [focusExpectation], timeout: 5)
        if !input.hasKeyboardFocus {
            input.click()
        }
        app.typeText("Add a regression test")

        let send = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerSend").firstMatch
        XCTAssertTrue(waitForExistence(send, timeout: 5))
        XCTAssertTrue(
            send.isEnabled,
            "well-formed Request text on the overview arms Send"
        )
    }

    func testRequestSubmitCreatesOneTaskViaRegistry() throws {
        _ = launchWorkspace()

        let input = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerInput").firstMatch
        XCTAssertTrue(waitForExistence(input, timeout: 15))
        input.click()
        input.typeText("Add a regression test")

        let send = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerSend").firstMatch
        XCTAssertTrue(waitForExistence(send, timeout: 5))
        send.click()

        // The registry creates the durable task; the row appears in the list.
        let list = app.descendants(matching: .any)
            .matching(identifier: "workspaceTaskList").firstMatch
        let newRow = list.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Add a regression test"))
            .firstMatch
        XCTAssertTrue(
            waitForExistence(newRow, timeout: 20),
            "the submitted request became a durable task in the project's list"
        )

        // The launch is honestly unconfirmed here (the fixture project is not
        // a git repository, so no agent is started): the composer says so.
        let notice = app.descendants(matching: .any)
            .matching(identifier: "workspaceComposerNotice").firstMatch
        XCTAssertTrue(
            waitForExistence(notice, timeout: 10),
            "the unconfirmed launch is explained, not hidden"
        )

        // One task only: sending again never duplicates the created task.
        send.click()
        let matches = list.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Add a regression test"))
        XCTAssertEqual(
            waitForExistence(matches.firstMatch, timeout: 5)
                ? matches.count : 0,
            1,
            "a retry continues the created task, never a second one"
        )
    }
}
