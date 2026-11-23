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

        for _ in 0..<16 {
            if hasFocus(primary) { break }
            app.typeKey(.tab, modifierFlags: [])
        }
        XCTAssertTrue(hasFocus(primary))
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(element("agentTaskResultLaunchEvidence").waitForExistence(timeout: 2))
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

    private func hasFocus(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"), object: element
        )], timeout: 0.1) == .completed
    }
}
