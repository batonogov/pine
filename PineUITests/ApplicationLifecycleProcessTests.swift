//
//  ApplicationLifecycleProcessTests.swift
//  PineUITests
//
//  Real-process release gate for Quit, failure recovery, crash, and relaunch.
//

import Darwin
import XCTest

final class ApplicationLifecycleProcessTests: PineUITestCase {
    private let bundleID = "io.github.batonogov.pine"
    private var projectURL: URL!
    private var diagnosticsURL: URL!
    private var seededSessionKey: String?
    private var ownedProcessIdentifiers: [pid_t] = []
    private var unrelatedProcess: Process?

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = try createTempProject(
            files: [
                "Sources/App.swift": "let committed = true\n",
                "dirty.swift": "let lifecycleFixtureIsDirty = false\n",
            ],
            projectName: "Pine Lifecycle Fixture"
        )
        diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PineLifecycleDiagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: diagnosticsURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        attachDiagnostics()
        if app.state != .notRunning {
            app.terminate()
            _ = waitForApplicationToStop(timeout: 5)
        }
        for processIdentifier in ownedProcessIdentifiers {
            let stopped = waitForProcessToStop(
                processIdentifier,
                timeout: 3
            )
            if !stopped {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
            XCTAssertTrue(
                stopped,
                "Pine-owned child \(processIdentifier) survived teardown"
            )
        }
        if let unrelatedProcess, unrelatedProcess.isRunning {
            unrelatedProcess.terminate()
            unrelatedProcess.waitUntilExit()
        }
        if let seededSessionKey {
            try? runDefaults(["delete", bundleID, seededSessionKey])
        }
        if let projectURL {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: projectURL.path
            )
            cleanupProject(projectURL)
        }
        if let diagnosticsURL {
            try? FileManager.default.removeItem(at: diagnosticsURL)
        }
        try super.tearDownWithError()
    }

    func testCleanQuitStopsTheRealApplicationProcess() throws {
        launchWithProject(projectURL)
        requestQuit()

        XCTAssertTrue(
            waitForApplicationToStop(timeout: 10),
            "A clean project should quit without a confirmation sheet"
        )
        recordPhase("clean-quit-completed")
    }

    func testCancelGenerationFailureAndRetryPreserveOwnership() throws {
        try launchLifecycleFixture()
        let firstGeneration = try captureOwnedGeneration(1)
        let unrelated = try launchUnrelatedProcess()

        requestQuit()
        clickButton("Cancel")
        recordPhase("quit-cancelled")
        XCTAssertNotEqual(app.state, .notRunning)
        XCTAssertTrue(isProcessAlive(firstGeneration.parent))
        XCTAssertTrue(isProcessAlive(firstGeneration.child))
        XCTAssertTrue(isProcessAlive(unrelated.processIdentifier))
        let dirtyTab = editorTab("dirty.swift")
        dirtyTab.click()
        XCTAssertTrue(
            dirtyTab.isSelected,
            "Cancelled Quit should return the editor to usable input"
        )

        requestQuit()
        XCTAssertTrue(
            app.buttons["Quit Anyway"].firstMatch.waitForExistence(
                timeout: 10
            )
        )
        try Data().write(
            to: diagnosticsURL.appendingPathComponent(
                "request-next-generation"
            ),
            options: .atomic
        )
        let secondGeneration = try captureOwnedGeneration(2)
        clickButton("Quit Anyway")
        XCTAssertTrue(
            app.staticTexts["Pine Couldn’t Quit"].firstMatch
                .waitForExistence(timeout: 15),
            "A process generation born under the sheet must invalidate Quit"
        )
        recordPhase("new-generation-rejected")
        clickButton("OK")
        XCTAssertNotEqual(app.state, .notRunning)

        try setProjectPermissions(0o555)
        requestReviewedSaveAndTerminalShutdown()
        XCTAssertTrue(
            app.staticTexts["Error"].firstMatch
                .waitForExistence(timeout: 15),
            "A denied save should fail closed and return control to Pine"
        )
        recordPhase("save-failure-returned")
        clickButton("OK")
        XCTAssertNotEqual(app.state, .notRunning)

        try setProjectPermissions(0o755)
        requestReviewedSaveAndTerminalShutdown()
        XCTAssertTrue(
            waitForApplicationToStop(timeout: 15),
            "Retrying after the save failure should complete Quit"
        )
        recordPhase("quit-retry-completed")
        XCTAssertEqual(
            try String(
                contentsOf: projectURL.appendingPathComponent("dirty.swift"),
                encoding: .utf8
            ),
            "let lifecycleFixtureIsDirty = true\n"
        )
        for processIdentifier in [
            firstGeneration.parent,
            firstGeneration.child,
            secondGeneration.parent,
            secondGeneration.child,
        ] {
            XCTAssertTrue(
                waitForProcessToStop(processIdentifier, timeout: 5),
                "Confirmed Quit should stop owned process \(processIdentifier)"
            )
        }
        XCTAssertTrue(
            isProcessAlive(unrelated.processIdentifier),
            "Confirmed Quit must leave an unrelated process untouched"
        )
    }

    func testInterruptedSessionWriteRelaunchesLastCommittedState() throws {
        app.launchArguments.removeAll { $0 == "--reset-state" }
        try seedVersionedSessionFixture()
        app.launchArguments.append("--ui-test-lifecycle-process")
        app.launchEnvironment[
            "PINE_LIFECYCLE_DIAGNOSTICS_DIRECTORY"
        ] = diagnosticsURL.path
        app.launchEnvironment["PINE_LIFECYCLE_FIXTURE_DIRTY"] = "0"
        app.launchEnvironment["PINE_PERSISTENCE_FAULT"] = [
            "session",
            "before-atomic-replace",
            "interrupted",
        ].joined(separator: ":")

        launchWithProject(projectURL)
        XCTAssertTrue(
            editorTab("App.swift").waitForExistence(timeout: 15),
            "The last committed fixture should restore before interruption"
        )
        let generation = try captureOwnedGeneration(1)
        requestQuit()
        clickButton("Quit Anyway")

        XCTAssertTrue(
            waitForApplicationToStop(timeout: 15),
            "The controlled checkpoint should kill the real Pine process"
        )
        XCTAssertTrue(
            waitForDiagnostic(
                named: "persistence-interruption.log",
                containing: "session:before-atomic-replace:interrupted",
                timeout: 5
            ),
            "The crash artifact should identify only the controlled phase"
        )
        recordPhase("process-interrupted")
        XCTAssertTrue(waitForProcessToStop(generation.parent, timeout: 5))
        XCTAssertTrue(waitForProcessToStop(generation.child, timeout: 5))

        app.launchArguments.removeAll {
            $0 == "--ui-test-lifecycle-process"
        }
        app.launchEnvironment.removeValue(forKey: "PINE_PERSISTENCE_FAULT")
        app.launchEnvironment.removeValue(
            forKey: "PINE_LIFECYCLE_FIXTURE_DIRTY"
        )
        launchWithProject(projectURL)

        XCTAssertTrue(
            editorTab("App.swift").waitForExistence(timeout: 15),
            "Relaunch should restore the last fully committed session"
        )
        XCTAssertFalse(
            editorTab("dirty.swift").exists,
            "A partial replacement must never become authoritative"
        )
        XCTAssertFalse(
            terminalTab("Terminal 1").exists,
            "Relaunch must not revive stale process ownership"
        )
        recordPhase("relaunch-restored-last-commit")
    }

    private func launchLifecycleFixture() throws {
        app.launchArguments.removeAll { $0 == "--reset-state" }
        app.launchArguments.append("--ui-test-lifecycle-process")
        app.launchEnvironment[
            "PINE_LIFECYCLE_DIAGNOSTICS_DIRECTORY"
        ] = diagnosticsURL.path
        launchWithProject(projectURL)
        XCTAssertTrue(editorTab("dirty.swift").waitForExistence(timeout: 15))
        XCTAssertTrue(terminalTab("Terminal 1").waitForExistence(timeout: 15))
    }

    private func requestQuit() {
        let appMenu = app.menuBars.menuBarItems["Pine"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 10))
        appMenu.click()
        let quit = app.menuItems["Quit Pine"].firstMatch
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.click()
    }

    private func requestReviewedSaveAndTerminalShutdown() {
        requestQuit()
        clickButton("Review…")
        clickButton("Save All")
        clickButton("Quit")
    }

    private func clickButton(
        _ title: String,
        timeout: TimeInterval = 10
    ) {
        let button = app.buttons[title].firstMatch
        XCTAssertTrue(
            button.waitForExistence(timeout: timeout),
            "Expected \(title) button"
        )
        button.click()
    }

    private func terminalTab(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["terminalTab_\(name)"].firstMatch
    }

    private func captureOwnedGeneration(
        _ generation: Int
    ) throws -> (parent: pid_t, child: pid_t) {
        let parent = try waitForPID(
            named: "owned-\(generation).pid",
            timeout: 15
        )
        let child = try waitForPID(
            named: "owned-\(generation)-child.pid",
            timeout: 15
        )
        ownedProcessIdentifiers.append(contentsOf: [parent, child])
        XCTAssertTrue(isProcessAlive(parent))
        XCTAssertTrue(isProcessAlive(child))
        return (parent, child)
    }

    private func waitForPID(
        named name: String,
        timeout: TimeInterval
    ) throws -> pid_t {
        let url = diagnosticsURL.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = try? String(contentsOf: url, encoding: .utf8),
               let processIdentifier = pid_t(value.trimmingCharacters(
                   in: .whitespacesAndNewlines
               )), processIdentifier > 0 {
                return processIdentifier
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func launchUnrelatedProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "trap 'exit 0' HUP INT TERM; while :; do /bin/sleep 60; done",
        ]
        try process.run()
        unrelatedProcess = process
        return process
    }

    private func setProjectPermissions(_ permissions: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: projectURL.path
        )
    }

    private func isProcessAlive(_ processIdentifier: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(processIdentifier, 0) == 0 || errno == EPERM
    }

    private func waitForProcessToStop(
        _ processIdentifier: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isProcessAlive(processIdentifier), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isProcessAlive(processIdentifier)
    }

    private func waitForApplicationToStop(
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while app.state != .notRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return app.state == .notRunning
    }

    private func waitForDiagnostic(
        named name: String,
        containing expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let url = diagnosticsURL.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.contains(expected) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
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
        let hex = Data(fixture.utf8).map {
            String(format: "%02x", $0)
        }.joined()
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

    private func attachDiagnostics() {
        for name in ["phases.log", "persistence-interruption.log"] {
            let url = diagnosticsURL?.appendingPathComponent(name)
            guard let url,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let attachment = XCTAttachment(string: text)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func recordPhase(_ phase: String) {
        let path = diagnosticsURL.appendingPathComponent("phases.log").path
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_APPEND,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }
        let bytes = Array("\(phase)\n".utf8)
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(descriptor, baseAddress, buffer.count)
        }
        _ = Darwin.fsync(descriptor)
    }
}
