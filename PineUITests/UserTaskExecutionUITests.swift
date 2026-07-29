//
//  UserTaskExecutionUITests.swift
//  PineUITests
//
//  End-to-end coverage for the project-scoped task execution surface.
//

import AppKit
import XCTest

final class UserTaskExecutionUITests: PineUITestCase {
    private var projectURL: URL!
    private var tasksFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject()
        tasksFileURL = projectURL.appendingPathComponent(
            ".pine-ui-tasks.json",
            isDirectory: false
        )
        NSPasteboard.general.clearContents()
    }

    override func tearDownWithError() throws {
        NSPasteboard.general.clearContents()
        if let projectURL {
            cleanupProject(projectURL)
        }
        try super.tearDownWithError()
    }

    func testRunningTaskShowsLiveElapsedProgressAndCancellation() throws {
        try launchWithTask(
            id: "ui-progress",
            label: "UI Progress Task",
            command: "trap '' TERM; printf 'started'; sleep 30"
        )

        let panel = app.descendants(matching: .any)[
            "userTaskOutputPanel"
        ].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))

        let status = app.staticTexts.matching(
            identifierBeginningWith: "userTaskStatus_"
        ).firstMatch
        XCTAssertTrue(
            waitForAccessibleText("Running", on: status, timeout: 5)
        )

        let elapsed = app.staticTexts.matching(
            identifierBeginningWith: "userTaskElapsed_"
        ).firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let initialElapsed = accessibleText(of: elapsed)
        XCTAssertTrue(
            waitForDifferentAccessibleText(
                from: initialElapsed,
                on: elapsed,
                timeout: 3
            ),
            "Elapsed time should update while the task is running"
        )
        let progress = app.descendants(matching: .any).matching(
            identifierBeginningWith: "userTaskProgress_"
        ).firstMatch
        XCTAssertTrue(
            progress.waitForExistence(timeout: 3),
            "An active task should expose a progress indicator"
        )

        let cancel = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "userTaskCancel_"
            )
        ).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.click()

        XCTAssertTrue(
            waitForOneOfAccessibleTexts(
                ["Cancelling", "Cancelled"],
                on: status,
                timeout: 3
            ),
            "Accepted cancellation should enter cleanup or finish cancelled"
        )
        XCTAssertTrue(
            !cancel.exists || !cancel.isEnabled,
            "Cancel should disable during cleanup or disappear after completion"
        )
        XCTAssertTrue(
            waitForAccessibleText("Cancelled", on: status, timeout: 5),
            "The task should reach a terminal cancelled state"
        )
        XCTAssertFalse(cancel.exists)
        XCTAssertTrue(waitForNonExistence(progress, timeout: 3))
    }

    func testSuccessfulTaskCopiesExactCombinedOutputWithoutModal() throws {
        let stdout = String(repeating: "x", count: 20_000)
        let expectedOutput = stdout + "\nsuccess-err"
        try launchWithTask(
            id: "ui-success",
            label: "UI Success Task",
            command: """
            /usr/bin/perl -e \
            'print "x" x 20000; print STDERR "success-err"'
            """
        )

        let status = app.staticTexts.matching(
            identifierBeginningWith: "userTaskStatus_"
        ).firstMatch
        XCTAssertTrue(
            waitForAccessibleText("Succeeded", on: status, timeout: 8)
        )

        let output = app.staticTexts.matching(
            identifierBeginningWith: "userTaskOutputText_"
        ).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 3))
        let outputText = accessibleText(of: output)
        let diagnosticPrefix = "success-err\n"
        let expectedPreview = diagnosticPrefix + String(
            repeating: "x",
            count: 16 * 1_024 - diagnosticPrefix.utf8.count
        )
        XCTAssertEqual(outputText.utf8.count, 16 * 1_024)
        XCTAssertEqual(outputText, expectedPreview)
        XCTAssertLessThan(outputText.utf8.count, expectedOutput.utf8.count)

        let truncationNotice = app.staticTexts.matching(
            identifierBeginningWith: "userTaskOutputTruncation_"
        ).firstMatch
        XCTAssertTrue(truncationNotice.waitForExistence(timeout: 3))
        XCTAssertEqual(
            accessibleText(of: truncationNotice),
            """
            Preview truncated. Copy Output includes the complete captured output.
            """
        )
        XCTAssertFalse(
            app.dialogs.firstMatch.exists,
            "Ordinary task success should not present a modal alert"
        )

        let copy = app.buttons.matching(
            identifierBeginningWith: "userTaskCopyOutput_"
        ).firstMatch
        clickCenter(of: copy)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            expectedOutput
        )
        XCTAssertFalse(app.dialogs.firstMatch.exists)
    }

    func testFailedTaskPersistsCopyAndOpenActionsAfterReopeningOutput() throws {
        let expectedOutput = "failure-out\nfailure-err"
        try launchWithTask(
            id: "ui-failure",
            label: "UI Failure Task",
            command: """
            printf 'failure-out'; printf 'failure-err' >&2; exit 7
            """
        )

        let status = app.staticTexts.matching(
            identifierBeginningWith: "userTaskStatus_"
        ).firstMatch
        XCTAssertTrue(
            waitForAccessibleText("Exit 7", on: status, timeout: 8)
        )

        let copy = app.buttons.matching(
            identifierBeginningWith: "userTaskCopyOutput_"
        ).firstMatch
        clickCenter(of: copy)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            expectedOutput
        )

        let panel = app.descendants(matching: .any)[
            "userTaskOutputPanel"
        ].firstMatch
        let close = app.buttons["userTaskCloseOutputButton"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.click()
        XCTAssertTrue(
            waitForNonExistence(panel, timeout: 3),
            "Close Output should hide the durable task history"
        )

        let show = app.buttons["userTaskShowOutputButton"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 3))
        show.click()
        XCTAssertTrue(
            panel.waitForExistence(timeout: 3),
            "Open Output should restore the same task history"
        )
        XCTAssertTrue(
            waitForAccessibleText("Exit 7", on: status, timeout: 3)
        )

        NSPasteboard.general.clearContents()
        clickCenter(of: copy)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            expectedOutput,
            "The reopened history should retain the exact failure output"
        )
        XCTAssertFalse(
            app.dialogs.firstMatch.exists,
            "Ordinary task failure should use the output surface, not a modal"
        )
    }

    private func launchWithTask(
        id: String,
        label: String,
        command: String
    ) throws {
        let document: [String: Any] = [
            "tasks": [
                [
                    "id": id,
                    "label": label,
                    "command": command,
                    "scope": "project",
                    "replaces_file_content": false,
                    "require_confirmation": false,
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: tasksFileURL, options: .atomic)

        app.launchEnvironment["PINE_USER_TASKS_FILE"] = tasksFileURL.path
        launchWithProject(projectURL)

        clickMenuBarItem("Tasks")
        let taskItem = app.menuItems[label]
        XCTAssertTrue(
            taskItem.waitForExistence(timeout: 5),
            "The task from PINE_USER_TASKS_FILE should appear in the Tasks menu"
        )
        taskItem.click()
    }

    private func waitForAccessibleText(
        _ expected: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ OR value == %@",
                expected,
                expected
            ),
            object: element
        )
        let result = XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        )
        if result != .completed {
            print(
                "Expected accessible text \(expected), actual label: "
                    + "\(element.label.debugDescription), value: "
                    + "\(String(describing: element.value)), exists: "
                    + "\(element.exists); \(element.debugDescription)"
            )
        }
        return result == .completed
    }

    private func waitForOneOfAccessibleTexts(
        _ expected: [String],
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label IN %@ OR value IN %@",
                expected,
                expected
            ),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func waitForDifferentAccessibleText(
        from original: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: """
                (label != %@ AND value != %@)
                AND (label != '' OR value != nil)
                """,
                original,
                original
            ),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func accessibleText(of element: XCUIElement) -> String {
        if !element.label.isEmpty {
            return element.label
        }
        return element.value as? String ?? ""
    }

    private func clickCenter(
        of element: XCUIElement,
        timeout: TimeInterval = 3
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        XCTAssertFalse(element.frame.isEmpty)
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
    }

    private func waitForNonExistence(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }
}

private extension XCUIElementQuery {
    func matching(
        identifierBeginningWith prefix: String
    ) -> XCUIElementQuery {
        matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                prefix
            )
        )
    }
}
