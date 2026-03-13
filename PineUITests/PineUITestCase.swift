//
//  PineUITestCase.swift
//  PineUITests
//
//  Base class for Pine UI tests with common helpers.
//

import XCTest

/// Base class providing common setup and helpers for Pine UI tests.
class PineUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--reset-state"]
    }

    // MARK: - Helpers

    /// Creates a temporary project directory with sample files for testing.
    @discardableResult
    func createTempProject(files: [String: String] = ["main.swift": "// Hello\n"]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineUITest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (name, content) in files {
            let file = dir.appendingPathComponent(name)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }

        return dir
    }

    /// Launches the app with `--open-project` pointing to the given directory.
    func launchWithProject(_ projectURL: URL) {
        app.launchArguments += ["--open-project", projectURL.path]
        app.launch()
        app.activate()
        // Welcome appears via .defaultLaunchBehavior(.presented),
        // PendingProjectOpener opens the project and dismisses Welcome
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
    }

    /// Launches the app in clean state (Welcome window should appear).
    func launchClean() {
        app.launch()
        app.activate()
    }

    /// Waits for an element to exist with a timeout.
    @discardableResult
    func waitForExistence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Cleans up a temporary project directory.
    func cleanupProject(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
