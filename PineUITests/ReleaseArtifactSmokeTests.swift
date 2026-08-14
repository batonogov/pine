//
//  ReleaseArtifactSmokeTests.swift
//  PineUITests
//

import AppKit
import Foundation
import XCTest

/// Release-only coverage for the exact signed application extracted from the
/// final DMG. The normal UI shards intentionally skip this class: the release
/// workflow supplies paths to signed artifacts and a locally served appcast.
final class ReleaseArtifactSmokeTests: PineUITestCase {
    private static let bundleIdentifier = "io.github.batonogov.pine"
    private static let fixtureFileName = "ReleaseSmoke.swift"

    private var activeApplication: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let activeApplication,
           activeApplication.state != .notRunning {
            activeApplication.terminate()
        }
        activeApplication = nil
        super.tearDown()
    }

    func testSignedDMGLifecycleAndSparkleUpdate() throws {
        let configuration = try ReleaseSmokeConfiguration.fromEnvironment()

        let candidateHome = configuration.userRoot.appendingPathComponent(
            "candidate-home",
            isDirectory: true
        )
        let updateHome = configuration.userRoot.appendingPathComponent(
            "update-home",
            isDirectory: true
        )
        try prepareHome(candidateHome)
        try prepareHome(updateHome)

        var application = try launchThroughLaunchServices(
            configuration.candidateApplication,
            home: candidateHome,
            project: nil,
            logName: "candidate-welcome",
            configuration: configuration
        )
        XCTAssertTrue(
            application.buttons["welcomeOpenFolderButton"]
                .waitForExistence(timeout: 20),
            "The signed candidate must present its Welcome window"
        )
        try quitNormally(application)

        application = try launchThroughLaunchServices(
            configuration.candidateApplication,
            home: candidateHome,
            project: configuration.project,
            logName: "candidate-project",
            configuration: configuration
        )
        try permanentlyOpenFixture(in: application)
        try quitNormally(application)

        application = try launchThroughLaunchServices(
            configuration.candidateApplication,
            home: candidateHome,
            project: configuration.project,
            logName: "candidate-relaunch",
            configuration: configuration
        )
        XCTAssertTrue(
            editorTab(in: application).waitForExistence(timeout: 20),
            "The signed candidate must restore its durable editor session"
        )
        try quitNormally(application)

        application = try launchThroughLaunchServices(
            configuration.updateApplication,
            home: updateHome,
            project: configuration.project,
            logName: "previous-version",
            configuration: configuration
        )
        try permanentlyOpenFixture(in: application)
        try quitNormally(application)

        try installUpdate(configuration)
        try verifyInstalledCandidate(configuration)

        application = try launchThroughLaunchServices(
            configuration.updateApplication,
            home: updateHome,
            project: configuration.project,
            logName: "updated-version",
            configuration: configuration
        )
        XCTAssertTrue(
            editorTab(in: application).waitForExistence(timeout: 20),
            "Sparkle update must retain the previous version's session"
        )
        try quitNormally(application)
    }

    private func prepareHome(_ home: URL) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func launchThroughLaunchServices(
        _ applicationURL: URL,
        home: URL,
        project: URL?,
        logName: String,
        configuration: ReleaseSmokeConfiguration
    ) throws -> XCUIApplication {
        let standardOutput = configuration.logs.appendingPathComponent(
            "\(logName).stdout.log"
        )
        let standardError = configuration.logs.appendingPathComponent(
            "\(logName).stderr.log"
        )
        let temporaryDirectory = home.appendingPathComponent(
            "tmp",
            isDirectory: true
        )
        _ = FileManager.default.createFile(
            atPath: standardOutput.path,
            contents: nil
        )
        _ = FileManager.default.createFile(
            atPath: standardError.path,
            contents: nil
        )
        var arguments = [
            "-n",
            "-F",
            "-a", applicationURL.path,
            "--stdout", standardOutput.path,
            "--stderr", standardError.path,
            "--env", "HOME=\(home.path)",
            "--env", "CFFIXED_USER_HOME=\(home.path)",
            "--env", "TMPDIR=\(temporaryDirectory.path)",
            "--env", "PINE_DISABLE_AGENT_DETECTION=1",
            "--env", "PINE_DISABLE_METAL=1",
            "--env", "PINE_DISABLE_QUICK_TERMINAL=1"
        ]
        if let project {
            arguments += ["--env", "PINE_OPEN_PROJECT=\(project.path)"]
        }
        arguments += [
            "--args",
            "--disable-agent-detection",
            "--disable-metal",
            "--disable-quick-terminal",
            "--disable-terminal-seeding",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]

        let launch = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: arguments,
            timeout: 20,
            logURL: configuration.logs.appendingPathComponent(
                "\(logName).launch.log"
            )
        )
        guard launch == 0 else {
            throw ReleaseSmokeError.commandFailed(
                command: "open",
                status: launch
            )
        }

        let application = XCUIApplication(
            bundleIdentifier: Self.bundleIdentifier
        )
        activeApplication = application
        XCTAssertTrue(
            application.wait(for: .runningForeground, timeout: 20),
            "The signed app must reach the foreground"
        )
        XCTAssertTrue(
            application.windows.firstMatch.waitForExistence(timeout: 20),
            "The signed app must expose a window"
        )
        try assertExactBundle(applicationURL)
        return application
    }

    private func assertExactBundle(_ expectedURL: URL) throws {
        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        )
        XCTAssertEqual(
            runningApplications.count,
            1,
            "Exactly one Pine process must be running during release smoke"
        )
        let runningApplication = try XCTUnwrap(
            runningApplications.first
        )
        let actualURL = try XCTUnwrap(runningApplication.bundleURL)
        XCTAssertEqual(
            actualURL.resolvingSymlinksInPath().path,
            expectedURL.resolvingSymlinksInPath().path,
            "XCUITest must attach to the app extracted from the tested DMG"
        )
    }

    private func permanentlyOpenFixture(
        in application: XCUIApplication
    ) throws {
        let sidebar = application.scrollViews["sidebar"]
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: 20),
            "The fixture project must open with its sidebar"
        )
        let file = application.sidebarNodes[
            "fileNode_\(Self.fixtureFileName)"
        ]
        XCTAssertTrue(
            file.waitForExistence(timeout: 20),
            "The release fixture file must appear in the sidebar"
        )
        file.doubleClick()
        XCTAssertTrue(
            editorTab(in: application).waitForExistence(timeout: 20),
            "Opening the fixture must create a permanent editor tab"
        )
    }

    private func editorTab(
        in application: XCUIApplication
    ) -> XCUIElement {
        application.descendants(matching: .any)[
            "editorTab_\(Self.fixtureFileName)"
        ].firstMatch
    }

    private func quitNormally(_ application: XCUIApplication) throws {
        let applicationMenu = application.menuBars.menuBarItems["Pine"]
        XCTAssertTrue(
            applicationMenu.waitForExistence(timeout: 10),
            "Pine application menu must be available"
        )
        applicationMenu.click()
        let quitItem = application.menuItems["Quit Pine"]
        XCTAssertTrue(
            quitItem.waitForExistence(timeout: 10),
            "Quit Pine must be available"
        )
        quitItem.click()
        XCTAssertTrue(
            application.wait(for: .notRunning, timeout: 30),
            "Pine must complete a normal application termination"
        )
        activeApplication = nil
    }

    private func installUpdate(
        _ configuration: ReleaseSmokeConfiguration
    ) throws {
        var environment = ProcessInfo.processInfo.environment
        let updateHome = configuration.userRoot.appendingPathComponent(
            "update-home",
            isDirectory: true
        )
        environment["HOME"] = updateHome.path
        environment["CFFIXED_USER_HOME"] = updateHome.path
        environment["TMPDIR"] = updateHome.appendingPathComponent(
            "tmp",
            isDirectory: true
        ).path

        let status = try runProcess(
            executable: configuration.sparkleCLI,
            arguments: [
                configuration.updateApplication.path,
                "--application", configuration.updateApplication.path,
                "--check-immediately",
                "--allow-major-upgrades",
                "--feed-url", configuration.appcastURL.absoluteString,
                "--user-agent-name", "PineReleaseArtifactSmoke",
                "--verbose"
            ],
            timeout: 180,
            logURL: configuration.logs.appendingPathComponent(
                "sparkle-update.log"
            ),
            environment: environment
        )
        guard status == 0 else {
            throw ReleaseSmokeError.commandFailed(
                command: "sparkle-cli",
                status: status
            )
        }
    }

    private func verifyInstalledCandidate(
        _ configuration: ReleaseSmokeConfiguration
    ) throws {
        let infoPlist = configuration.updateApplication
            .appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoPlist)
        let rawPlist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        let plist = try XCTUnwrap(rawPlist as? [String: Any])
        XCTAssertEqual(
            plist["CFBundleShortVersionString"] as? String,
            configuration.expectedVersion
        )
        XCTAssertEqual(
            plist["CFBundleVersion"] as? String,
            configuration.expectedBuild
        )

        for (name, executable, arguments) in [
            (
                "codesign",
                URL(fileURLWithPath: "/usr/bin/codesign"),
                ["--verify", "--deep", "--strict", "--verbose=2",
                 configuration.updateApplication.path]
            ),
            (
                "stapler",
                URL(fileURLWithPath: "/usr/bin/xcrun"),
                ["stapler", "validate", configuration.updateApplication.path]
            ),
            (
                "gatekeeper",
                URL(fileURLWithPath: "/usr/sbin/spctl"),
                ["--assess", "--type", "execute", "--verbose=4",
                 configuration.updateApplication.path]
            )
        ] {
            let status = try runProcess(
                executable: executable,
                arguments: arguments,
                timeout: 30,
                logURL: configuration.logs.appendingPathComponent(
                    "updated-\(name).log"
                )
            )
            guard status == 0 else {
                throw ReleaseSmokeError.commandFailed(
                    command: name,
                    status: status
                )
            }
        }
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        logURL: URL,
        environment: [String: String]? = nil
    ) throws -> Int32 {
        _ = FileManager.default.createFile(
            atPath: logURL.path,
            contents: nil
        )
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if process.isRunning {
            process.terminate()
            _ = process.waitUntilExit(timeout: 5)
            XCTFail("Timed out running \(executable.lastPathComponent)")
            return -1
        }
        return process.terminationStatus
    }
}

private struct ReleaseSmokeConfiguration {
    let candidateApplication: URL
    let updateApplication: URL
    let sparkleCLI: URL
    let appcastURL: URL
    let expectedVersion: String
    let expectedBuild: String
    let userRoot: URL
    let project: URL
    let logs: URL

    static func fromEnvironment() throws -> ReleaseSmokeConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PINE_RELEASE_SMOKE_ENABLED"] == "1" else {
            throw XCTSkip(
                "Signed release artifacts are available only in release CI"
            )
        }

        func required(_ key: String) throws -> String {
            try XCTUnwrap(
                environment[key],
                "Missing release smoke environment value: \(key)"
            )
        }

        let appcastURLString = try required(
            "PINE_RELEASE_SMOKE_APPCAST_URL"
        )
        let appcastURL = try XCTUnwrap(URL(string: appcastURLString))
        let configuration = ReleaseSmokeConfiguration(
            candidateApplication: URL(
                fileURLWithPath: try required(
                    "PINE_RELEASE_SMOKE_CANDIDATE_APP"
                ),
                isDirectory: true
            ),
            updateApplication: URL(
                fileURLWithPath: try required(
                    "PINE_RELEASE_SMOKE_UPDATE_APP"
                ),
                isDirectory: true
            ),
            sparkleCLI: URL(
                fileURLWithPath: try required(
                    "PINE_RELEASE_SMOKE_SPARKLE_CLI"
                )
            ),
            appcastURL: appcastURL,
            expectedVersion: try required(
                "PINE_RELEASE_SMOKE_EXPECTED_VERSION"
            ),
            expectedBuild: try required(
                "PINE_RELEASE_SMOKE_EXPECTED_BUILD"
            ),
            userRoot: URL(
                fileURLWithPath: try required(
                    "PINE_RELEASE_SMOKE_USER_ROOT"
                ),
                isDirectory: true
            ),
            project: URL(
                fileURLWithPath: try required(
                    "PINE_RELEASE_SMOKE_PROJECT"
                ),
                isDirectory: true
            ),
            logs: URL(
                fileURLWithPath: try required(
                    "PINE_RELEASE_SMOKE_LOGS"
                ),
                isDirectory: true
            )
        )
        try configuration.validate()
        return configuration
    }

    private func validate() throws {
        let fileManager = FileManager.default
        for application in [candidateApplication, updateApplication] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: application.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw ReleaseSmokeError.invalidConfiguration(
                    "Missing release smoke app: \(application.path)"
                )
            }
        }
        guard fileManager.isExecutableFile(atPath: sparkleCLI.path) else {
            throw ReleaseSmokeError.invalidConfiguration(
                "sparkle-cli must be executable"
            )
        }
        guard project.resolvingSymlinksInPath().path.hasPrefix(
            userRoot.resolvingSymlinksInPath().path + "/"
        ) else {
            throw ReleaseSmokeError.invalidConfiguration(
                "Release fixture must remain inside the isolated user root"
            )
        }
        guard appcastURL.scheme == "http",
              appcastURL.host == "127.0.0.1" else {
            throw ReleaseSmokeError.invalidConfiguration(
                "The isolated appcast must use loopback HTTP"
            )
        }
    }
}

private enum ReleaseSmokeError: LocalizedError {
    case commandFailed(command: String, status: Int32)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status):
            "\(command) failed with status \(status)"
        case let .invalidConfiguration(message):
            message
        }
    }
}

private extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isRunning
    }
}
