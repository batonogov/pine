import XCTest

final class AgentTaskResultUITests: PineUITestCase {
    func testReadyOrderOpeningAndExplicitLaunchNeverAccept() {
        launchResult()

        let sections = [
            "agentTaskResultOutcome", "agentTaskResultTry", "agentTaskResultEvidence",
            "agentTaskResultSnapshots", "agentTaskResultContext",
        ].map { element($0) }
        for section in sections {
            XCTAssertTrue(section.waitForExistence(timeout: 5), section.identifier)
        }
        for (first, second) in zip(sections, sections.dropFirst()) {
            XCTAssertLessThan(first.frame.minY, second.frame.minY)
        }
        XCTAssertFalse(element("agentTaskResultLaunchEvidence").exists)
        XCTAssertTrue(app.staticTexts["Not accepted"].exists)
        XCTAssertTrue(element("agentTaskResultPrimaryAction").isEnabled)

        element("agentTaskResultPrimaryAction").click()
        XCTAssertTrue(element("agentTaskResultLaunchEvidence").waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Not accepted"].exists)
    }

    func testPrimaryActionIsKeyboardReachable() {
        launchResult()
        let primary = element("agentTaskResultPrimaryAction")
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertTrue(primary.isEnabled)

        // On CI the launched app is not frontmost when the walk starts, so
        // key events route nowhere. A mouse click inside the window
        // activates the app and makes its window key; the outcome section
        // is neutral (no control action under the click), the same recipe
        // AgentAttentionKeyboardUITests uses with its bell click.
        element("agentTaskResultOutcome").click()

        // The primary action is the card's default button, so Return
        // activates it once the window is key — no Full Keyboard Access or
        // Tab focus loop required. A first press can land before key
        // status settles, so retry a few times. The launch evidence can
        // only appear through the primary action, so its appearance is
        // proof the key path works.
        let evidence = element("agentTaskResultLaunchEvidence")
        var activated = false
        for _ in 0..<4 {
            app.typeKey(.return, modifierFlags: [])
            if evidence.waitForExistence(timeout: 1) {
                activated = true
                break
            }
        }
        XCTAssertTrue(activated, "Return should reach and activate the primary action")
    }

    func testNeedsDecisionProvidesFreeFormReplyAndNoReadyAction() {
        launchResult(needsDecision: true)
        XCTAssertTrue(app.staticTexts["Needs decision"].exists)
        XCTAssertTrue(app.staticTexts["A required check failed."].exists)
        XCTAssertTrue(app.staticTexts[
            "Required action: correct the failure and repeat the required checks."
        ].exists)
        XCTAssertFalse(element("agentTaskResultPrimaryAction").isEnabled)

        let field = element("agentTaskResultReply")
        field.click()
        field.typeText("Fix the build, then repeat the check")
        let send = element("agentTaskResultSendReply")
        XCTAssertTrue(send.isEnabled)
        send.click()
        XCTAssertEqual(element("agentTaskResultReplyEvidence").value as? String,
                       "Fix the build, then repeat the check")
    }

    func testRussianReadyAndActionLabels() {
        useLaunchLocale(language: "ru", locale: "ru_RU")
        launchResult()
        XCTAssertTrue(app.staticTexts["Готово"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Запустить пример"].exists)
    }

    // MARK: - Revision-bound feedback and comparison (#1758)

    func testFeedbackBindsToViewedRevisionAndOffersTextOnly() {
        launchResultFeedback()

        // The draft names the revision it is about; nothing re-targets it.
        let bound = element("agentFeedbackBoundRevision")
        XCTAssertTrue(bound.waitForExistence(timeout: 5))
        XCTAssertTrue(bound.label.hasPrefix("About revision"), bound.label)
        XCTAssertTrue(app.staticTexts[
            "Images and selections aren’t supported for this result yet. Feedback is sent as text."
        ].exists)
        // The image is kept in the draft, so the explicit text-only path is
        // the default button and a whole-draft send is not offered at all.
        XCTAssertTrue(element("agentFeedbackSendTextOnly").isEnabled)
        XCTAssertFalse(element("agentFeedbackSend").exists)

        // On CI the launched app is not frontmost when the walk starts, so
        // key events route nowhere. A click inside the window makes it key;
        // the title is neutral (no control action under the click).
        app.staticTexts["Give feedback"].click()
        let evidence = element("agentFeedbackSendEvidence")
        var activated = false
        for _ in 0..<4 {
            app.typeKey(.return, modifierFlags: [])
            if evidence.waitForExistence(timeout: 1) {
                activated = true
                break
            }
        }
        XCTAssertTrue(activated, "Return should reach the text-only default button")
        XCTAssertEqual(evidence.value as? String, "text-only")
    }

    func testComparisonDisclosesUnavailableHistory() {
        launchResultFeedback()

        let gap = element("agentRevisionComparisonGap")
        XCTAssertTrue(gap.waitForExistence(timeout: 5))
        XCTAssertTrue(
            gap.label.hasPrefix("No output was kept for this revision"), gap.label
        )
        XCTAssertTrue(element("agentRevisionComparisonBefore").exists)
        XCTAssertTrue(element("agentRevisionComparisonAfter").exists)
        XCTAssertTrue(app.staticTexts[
            "Read-only history. Comparing never runs a command and never restores older code."
        ].exists)
        // Read-only history: nothing in the comparison can run or restore.
        for title in ["Restore", "Roll back", "Run example", "Send feedback"] {
            XCTAssertFalse(app.buttons[title].exists, title)
        }
    }

    private func launchResultFeedback() {
        app.launchArguments.append("--ui-test-agent-result-feedback")
        launchClean()
        XCTAssertTrue(element("agentFeedbackComposer").waitForExistence(timeout: 10))
    }

    private func launchResult(needsDecision: Bool = false) {
        app.launchArguments.append(
            needsDecision ? "--ui-test-agent-result-decision" : "--ui-test-agent-result"
        )
        launchClean()
        XCTAssertTrue(element("agentTaskResult").waitForExistence(timeout: 10))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

}
