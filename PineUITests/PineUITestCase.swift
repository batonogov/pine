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
        // Welcome window doesn't auto-show in XCUITest context —
        // open it via menu so PendingProjectOpener can fire and open the project
        ensureWindowVisible()
        // Wait for project window to appear (Welcome gets dismissed,
        // project window opens via PendingProjectOpener)
        sleep(2)
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
    }

    /// Launches the app in clean state (Welcome window should appear).
    func launchClean() {
        app.launch()
        app.activate()
        ensureWindowVisible()
    }

    /// Ensures at least one window is visible, opening Welcome via menu if needed.
    private func ensureWindowVisible() {
        if app.windows.firstMatch.waitForExistence(timeout: 3) { return }
        // Fallback: open Welcome window via the Window menu
        // The menu bar items have localized titles, so use the menu bar item for "Окно"/"Window"
        let menuBar = app.menuBars.firstMatch
        guard menuBar.exists else { return }

        // Find Window menu by trying known titles
        let windowMenuTitles = ["Окно", "Window"]
        for title in windowMenuTitles {
            let menuItem = menuBar.menuBarItems[title]
            if menuItem.exists {
                menuItem.click()
                // Now find the Welcome item in the open menu
                let welcomePatterns = ["Добро пожаловать", "Welcome"]
                for pattern in welcomePatterns {
                    let predicate = NSPredicate(format: "title CONTAINS[c] %@", pattern)
                    let welcomeItem = app.menuItems.matching(predicate).firstMatch
                    if welcomeItem.waitForExistence(timeout: 2), welcomeItem.isHittable {
                        welcomeItem.click()
                        _ = app.windows.firstMatch.waitForExistence(timeout: 5)
                        return
                    }
                }
                // Close the menu if we didn't find the item
                app.typeKey(.escape, modifierFlags: [])
                return
            }
        }
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
