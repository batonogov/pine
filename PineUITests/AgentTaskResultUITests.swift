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
        launchResult("--ui-test-agent-result-decision")
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

    func testNeedsDecisionShowsTheFindingTextAndTheReplyScope() {
        launchResult("--ui-test-agent-result-decision")
        // The reviewer's finding is shown as text, never as its reference hash.
        XCTAssertTrue(app.staticTexts[
            "Unresolved finding: The example exits with code 1 when it is run without arguments."
        ].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", String(repeating: "9", count: 64))
        ).firstMatch.exists)
        // No adapter transmits visual references yet: the reply field says so.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Only the reply text is sent.")
        ).firstMatch.exists)
    }

    func testStaleDecisionCannotBeAnswered() {
        launchResult("--ui-test-agent-result-decision-stale")
        XCTAssertTrue(app.staticTexts["Previous decision request"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "This request belongs to an earlier result and can no longer be answered."
        ].exists)
        let reply = element("agentTaskResultReply")
        XCTAssertTrue(reply.waitForExistence(timeout: 2))
        XCTAssertFalse(reply.isEnabled)
        XCTAssertFalse(element("agentTaskResultSendReply").isEnabled)
        XCTAssertFalse(element("agentTaskResultReplyEvidence").exists)
    }

    func testReadyIsPresentedOnFirstOpenWithoutChoosingAResultAction() {
        launchResult("--ui-test-agent-result-first-open")
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Not accepted"].exists)
        XCTAssertTrue(app.staticTexts["No project result action is selected."].exists)
        // Ready does not depend on a recipe: nothing is selected or launched by opening.
        XCTAssertFalse(element("agentTaskResultPrimaryAction").exists)
        XCTAssertFalse(element("agentTaskResultLaunchEvidence").exists)
    }

    private func launchResult(_ argument: String = "--ui-test-agent-result") {
        app.launchArguments.append(argument)
        launchClean()
        XCTAssertTrue(element("agentTaskResult").waitForExistence(timeout: 10))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

}
