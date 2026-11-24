import XCTest

/// Opt-in real-model in-app journey (#1811 acceptance, GUI stage): ONE task
/// through Pine's actual UI dispatch against the installed real OpenCode CLI
/// and an authenticated real model — request → observed activity → a real
/// form question answered in the UI → a real one-shot write permission
/// allowed in the UI → a real unverified result → same-session feedback that
/// recalls the conversation context. Bounded: one task, trivial prompts, no
/// model quota beyond that. Skips unless opted in, and it needs the real
/// `opencode` binary resolvable on the test host's PATH (the app resolves it
/// from the environment, the same way production does).
final class OpenCodeRealModelJourneyUITests: PineUITestCase {
    private static let optedIn =
        ProcessInfo.processInfo.environment["PINE_RUN_OPENCODE_ACP_SMOKE"] == "1"
        || FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-opencode-acp-smoke").path)

    /// Default is the authenticated model present on the milestone machine;
    /// native OpenCode credential handling is inherited, never copied.
    private static let model =
        ProcessInfo.processInfo.environment["PINE_OPENCODE_MODEL"] ?? "oso/local-qwen38-27b-large"

    func testRealModelRequestQuestionPermissionResultAndFeedback() throws {
        guard Self.optedIn else {
            throw XCTSkip("Opt-in required: PINE_RUN_OPENCODE_ACP_SMOKE=1 or the $TMPDIR/pine-opencode-acp-smoke marker")
        }
        // Project-level OpenCode config: the pinned model, one-shot edit
        // permission, no third-party plugins. Committed so the reserved task
        // worktree carries it.
        let project = try createTempProject(files: [
            "tracked.txt": "tracked\n",
            "opencode.json": "{\"model\":\"\(Self.model)\",\"permission\":{\"edit\":\"ask\",\"bash\":\"ask\"},\"plugins\":[]}"
        ])
        defer { cleanupProject(project) }
        try Self.makeGitProject(project)
        launchWithProject(project)

        let toolbar = app.buttons["openCodeTaskToolbarButton"].firstMatch
        XCTAssertTrue(waitForExistence(toolbar, timeout: 15))
        toolbar.click()
        let input = app.textViews["openCodeTaskInput"].firstMatch
        XCTAssertTrue(waitForExistence(input, timeout: 10))
        let codeword = "PINE1811UI-\(UUID().uuidString.prefix(8).uppercased())"
        input.click()
        input.typeText(
            "Remember the codeword \(codeword). Ask me a form question with exactly one field "
            + "named 'choice' with options 'keep' and 'drop'. After I answer, create the file "
            + "note.txt containing exactly the text ok. Reply with exactly: REMEMBERED"
        )
        let send = app.buttons["openCodeTaskSend"].firstMatch
        XCTAssertTrue(waitForExistence(send, timeout: 10))
        XCTAssertTrue(waitForEnabled(send, timeout: 10), "Send Request must arm after input")
        send.click()

        // Observed activity: the turn is seen working before anything asks.
        let status = app.staticTexts["openCodeTaskStatus"].firstMatch
        XCTAssertTrue(waitForLabel(status, containing: "Working…", timeout: 240),
                      "Expected observed Working… activity")

        // A real question arrives; the UI preselects the first choice.
        XCTAssertTrue(waitForLabel(status, containing: "Answer needed", timeout: 300))
        let answer = app.buttons["Answer"].firstMatch
        XCTAssertTrue(waitForEnabled(answer, timeout: 120), "Answer must arm on the preselected choice")
        answer.click()

        // A real one-shot write permission; allow it exactly once.
        let allow = app.buttons["Allow Once"].firstMatch
        XCTAssertTrue(waitForEnabled(allow, timeout: 300), "Expected a real write permission request")
        allow.click()

        // A real unverified result, explicitly not Ready.
        XCTAssertTrue(waitForLabel(status, containing: "Result received", timeout: 300))
        let result = app.staticTexts["openCodeTaskResult"].firstMatch
        XCTAssertTrue(waitForLabel(result, containing: "REMEMBERED", timeout: 120))
        XCTAssertTrue(waitForLabel(result, containing: "Unverified result", timeout: 30))

        // Same-session feedback: the exact session recalls the codeword
        // (note.txt holds only "ok"; no file contains the codeword).
        input.click()
        input.typeText("What was the codeword I gave you in this conversation? Reply with only the codeword.")
        let feedback = app.buttons["openCodeTaskSend"].firstMatch
        XCTAssertTrue(waitForEnabled(feedback, timeout: 10), "Send Feedback must arm after input")
        feedback.click()
        XCTAssertTrue(waitForLabel(status, containing: "Working…", timeout: 240))
        XCTAssertTrue(waitForLabel(status, containing: "Result received", timeout: 300))
        XCTAssertTrue(waitForLabel(result, containing: codeword, timeout: 180),
                      "The exact same session must recall the codeword from context")
        // Journey complete: app teardown (tearDownWithError) terminates the
        // task's owned ACP process. The permission-approved file write is
        // additionally asserted in the in-process real-model tests, which can
        // read the reserved worktree directly.
    }

    /// Polls an element's label until it contains the text or the timeout.
    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        _ = element.waitForExistence(timeout: 1)
        while Date() < deadline {
            if element.exists, element.label.contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.exists && element.label.contains(text)
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        _ = element.waitForExistence(timeout: 1)
        while Date() < deadline {
            if element.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.isEnabled
    }

    /// The reserved task worktree is a git worktree, so the fixture project
    /// must be a repository with one commit.
    private static func makeGitProject(_ project: URL) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        for args in [
            ["init", "-b", "main"],
            ["add", "."],
            ["-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid",
             "commit", "-m", "fixture"]
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = project
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "OpenCodeRealModelJourney", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed"])
            }
        }
    }
}
