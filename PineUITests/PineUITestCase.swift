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
        app.launchArguments += ["--reset-state", "-ApplePersistenceIgnoreState", "YES"]
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

    /// Launches the app with the given project directory.
    /// Uses environment variable instead of launch arguments to avoid
    /// macOS interpreting the path as a file-open request.
    func launchWithProject(_ projectURL: URL) {
        app.launchEnvironment["PINE_OPEN_PROJECT"] = projectURL.path
        app.launch()
        app.activate()
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
